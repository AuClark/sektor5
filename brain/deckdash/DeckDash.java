import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import org.deepsymmetry.beatlink.*;
import org.deepsymmetry.beatlink.data.*;

import java.awt.Color;
import java.io.IOException;
import java.io.OutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Deck dashboard: joins the Pro DJ Link network as a virtual CDJ (via beat-link),
 * gathers everything the players share, and serves it as a live web page.
 *
 *   GET /                 dashboard (web/index.html, re-read on every request)
 *   GET /api/state        JSON snapshot
 *   GET /api/events       Server-Sent Events, state pushed ~10x per second
 *   GET /api/art/N        album art for player N (JPEG)
 *   GET /api/waveform/N   waveform preview for player N (JSON)
 *   /api/library..., /api/deck   library browser and deck commands (Library.java)
 */
public class DeckDash {
    static final int PORT = Integer.getInteger("port", 8080);
    static final Path WEB = Path.of(System.getProperty("web", "web"));
    /** Work-in-progress copy of the page, served at /preview/ against the same live data. */
    static final Path PREVIEW = Path.of(System.getProperty("preview", "preview"));
    static final Map<Integer, Long> lastBeat = new ConcurrentHashMap<>();
    static final Map<Integer, Integer> beatCount = new ConcurrentHashMap<>();
    static final List<SseClient> sseClients = new CopyOnWriteArrayList<>();
    static final long started = System.currentTimeMillis();

    public static void main(String[] args) throws Exception {
        DeviceFinder.getInstance().start();
        BeatFinder.getInstance().start();
        brainSock = new DatagramSocket();
        startMixerListener();
        BeatFinder.getInstance().addBeatListener(beat -> {
            long now = System.currentTimeMillis();
            lastBeat.put(beat.getDeviceNumber(), now);
            beatCount.merge(beat.getDeviceNumber(), 1, Integer::sum);
            toBrain(new Json().obj().str("t", "beat").num("player", beat.getDeviceNumber())
                    .num("bwb", beat.getBeatWithinBar()).num("bpm", round(beat.getEffectiveTempo(), 3))
                    .num("nextBeatMs", beat.getNextBeat())
                    // isTempoMaster() needs the VirtualCdj, which isn't up for the first second or so.
                    .bool("master", VirtualCdj.getInstance().isRunning() && beat.isTempoMaster()).num("ts", now).end().toString());
        });

        VirtualCdj vcdj = VirtualCdj.getInstance();
        vcdj.setDeviceName("Sektor5");
        // Stay off the real players' numbers; metadata comes from the USB export via CrateDigger.
        vcdj.setUseStandardPlayerNumber(false);
        TempoMaster.configure(vcdj);            // -Dtempo=on: a standard number, so the Pi can be master
        HttpServer http = HttpServer.create(new InetSocketAddress(PORT), 0);
        http.setExecutor(Executors.newCachedThreadPool());
        http.createContext("/", DeckDash::index);
        http.createContext("/preview/", DeckDash::preview);
        Sim.proxied(http.createContext("/api/state", ex -> send(ex, 200, "application/json", state().getBytes(StandardCharsets.UTF_8))));
        Sim.proxied(http.createContext("/api/events", DeckDash::events));
        http.createContext("/api/auth", Auth::handle);
        http.createContext("/s5auth.js", ex -> send(ex, 200, "text/javascript", Files.readAllBytes(WEB.resolve("s5auth.js"))));
        http.createContext("/s5system.js", ex -> send(ex, 200, "text/javascript", Files.readAllBytes(WEB.resolve("s5system.js"))));
        http.createContext("/s5audio.js", ex -> send(ex, 200, "text/javascript", Files.readAllBytes(WEB.resolve("s5audio.js"))));
        http.createContext("/shell", ex -> send(ex, 200, "text/html; charset=utf-8", Files.readAllBytes(WEB.resolve("s5shell.html"))));   // the sim's sound player
        http.createContext("/api/system", ex -> send(ex, 200, "application/json", SystemInfo.json().getBytes(StandardCharsets.UTF_8)));
        http.createContext("/api/system/tailscale", Tailscale::handle);
        http.createContext("/api/sim", Sim::handle);
        // Real tracks' audio in simulation (fakerig /api/audio/ID, for s5audio.js); nothing without the sim.
        Sim.proxied(http.createContext("/api/audio/", ex -> send(ex, 404, "application/json", "{\"error\":\"only in simulation\"}".getBytes(StandardCharsets.UTF_8))));
        Sim.proxied(http.createContext("/api/art/", DeckDash::art));
        Sim.proxied(http.createContext("/api/waveform/", DeckDash::waveform));
        Sim.proxied(http.createContext("/api/wavedetail/", DeckDash::waveDetail));
        Sim.proxied(http.createContext("/api/timeline/", ex -> {
            String t = Timeline.forPlayer(playerFrom(ex));
            if (t == null) send(ex, 404, "application/json", "{}".getBytes());
            else send(ex, 200, "application/json", t.getBytes(StandardCharsets.UTF_8));
        }));
        Library.register(http);
        Proxy.register(http);                   // /lighting/, /projection/, /visuals/: every page via this address
        TempoMaster.start(http);
        http.start();
        log("dashboard on http://0.0.0.0:" + PORT + "/");
        SystemInfo.start();

        ScheduledExecutorService tick = Executors.newScheduledThreadPool(2);
        // A scheduled task that throws is cancelled for good, silently, so neither may let anything escape:
        // an early exception here used to stop every dashboard's live updates (and could stop showbrain's feed).
        tick.scheduleAtFixedRate(() -> {
            try { toBrain(brainStatus()); } catch (Throwable t) { logOnce("brain status", t); }
        }, 0, 50, TimeUnit.MILLISECONDS);
        tick.scheduleAtFixedRate(() -> {
            try {
                if (sseClients.isEmpty()) return;
                byte[] msg = ("data: " + state() + "\n\n").getBytes(StandardCharsets.UTF_8);
                for (SseClient c : sseClients) c.send(msg);
            } catch (Throwable t) {
                logOnce("sse push", t);
            }
        }, 0, 100, TimeUnit.MILLISECONDS);

        // Join the decks last: the dashboard, API and System view are up without them (decks off,
        // a new brain on the bench), and the players appear whenever the DJ Link network does.
        joinDecks(vcdj);
        // beat-link shuts the virtual CDJ down when the network goes from under it (an Ethernet blip,
        // a USB hub resetting, the computer sleeping) and never starts it again by itself; it also stays
        // on the network it joined when the decks move to another (they took self-assigned 169.254
        // addresses, then got the router's after a replug). Rejoining in the same process gets the beat
        // back but not the track info (the metadata finders don't pick the loaded tracks up again), so
        // exit with REJOIN and let the supervisor start us fresh: ./run.sh's loop on a Mac, systemd's
        // Restart=always on the brain. A fresh start is back with everything in about 5 s.
        long offSince = 0;
        Set<String> warned = new HashSet<>();
        while (true) {
            Thread.sleep(2000);
            if (!vcdj.isRunning()) {
                log("lost the DJ Link network (Ethernet dropped?): restarting to rejoin");
                System.exit(REJOIN);
            }
            List<DeviceAnnouncement> ds = new ArrayList<>(DeviceFinder.getInstance().getCurrentDevices());
            boolean wrongSide = selfAssigned(vcdj.getLocalAddress()) && ds.stream().anyMatch(d -> !selfAssigned(d.getAddress()));
            if (!ds.isEmpty() && (wrongSide || ds.stream().noneMatch(d -> onOurNetwork(vcdj, d.getAddress())))) {
                if (offSince == 0) offSince = System.currentTimeMillis();
                else if (System.currentTimeMillis() - offSince > 6000) {
                    log("the decks are on another network now (" + seenDecks() + "): restarting to rejoin on it");
                    System.exit(REJOIN);
                }
            } else offSince = 0;
            // A deck on a self-assigned address can be heard (beat, tempo, play state: the lights follow
            // it), but this computer's requests for its track info go from its main address, which the
            // deck can't answer: no titles, waveforms, beat grids or drops. Say so once per address.
            for (DeviceAnnouncement d : ds) {
                String a = d.getAddress().getHostAddress();
                if (a.startsWith("169.254.") && warned.add(d.getDeviceNumber() + "@" + a))
                    log(d.getDeviceName() + " #" + d.getDeviceNumber() + " is on a self-assigned address (" + a + "): it missed "
                            + "the router's DHCP. Beat and play state work, but no track info (titles, waveforms, drops) until "
                            + "its Ethernet is replugged with the router on");
            }
        }
    }

    static boolean selfAssigned(java.net.InetAddress a) {
        return a != null && a.getHostAddress().startsWith("169.254.");
    }

    /** Whether ADDR is on the network the virtual CDJ joined. */
    static boolean onOurNetwork(VirtualCdj vcdj, java.net.InetAddress addr) {
        try {
            java.net.InetAddress local = vcdj.getLocalAddress();
            java.net.NetworkInterface ni = java.net.NetworkInterface.getByInetAddress(local);
            if (ni == null) return false;
            for (java.net.InterfaceAddress ia : ni.getInterfaceAddresses()) {
                if (!local.equals(ia.getAddress())) continue;
                byte[] x = local.getAddress(), y = addr.getAddress();
                if (x.length != y.length) return false;
                int bits = ia.getNetworkPrefixLength();
                for (int i = 0; i < x.length; i++) {
                    int m = bits >= 8 ? 0xff : bits <= 0 ? 0 : (0xff << (8 - bits)) & 0xff;
                    if ((x[i] & m) != (y[i] & m)) return false;
                    bits -= 8;
                }
                return true;
            }
        } catch (Exception ignored) {
        }
        return true;                                   // can't tell: leave it be
    }

    /** Exit code asking the supervisor (./run.sh, systemd) for a fresh start to rejoin the decks. */
    static final int REJOIN = 75;

    /** Join the DJ Link network (retrying until there is one) and start the data finders. */
    static void joinDecks(VirtualCdj vcdj) throws Exception {
        log("waiting for DJ Link devices...");
        String lastSeen = null;
        DeviceFinder finder = DeviceFinder.getInstance();
        finder.start();
        while (true) {
            // With some decks on the router's addresses and some self-assigned (they missed its DHCP),
            // join the router's side: only there do we get track info, and the others join it once
            // replugged. The virtual CDJ joins the network of whichever deck it hears first, so keep
            // the self-assigned ones out of its sight while it joins.
            Thread.sleep(1500);                            // hear the decks that are there
            List<java.net.InetAddress> hidden = new ArrayList<>();
            List<DeviceAnnouncement> now = new ArrayList<>(finder.getCurrentDevices());
            if (now.stream().anyMatch(d -> !selfAssigned(d.getAddress())))
                for (DeviceAnnouncement d : now)
                    if (selfAssigned(d.getAddress())) { finder.addIgnoredAddress(d.getAddress()); hidden.add(d.getAddress()); }
            boolean ok = vcdj.start();
            for (java.net.InetAddress a : hidden) finder.removeIgnoredAddress(a);    // heard again: for the warning
            if (ok) break;
            String seen = seenDecks();
            if (!seen.equals(lastSeen)) {                  // say what's wrong once, not every 5 s
                lastSeen = seen;
                if (seen.isEmpty()) log("no DJ Link network yet (no decks heard), retrying every 5 s. If the decks are on and "
                        + "can see each other, they may be on self-assigned 169.254 addresses this computer can't hear: "
                        + "give its rig Ethernet one too (sudo brain/tools/mac_rig_ethernet.sh), or replug the decks' Ethernet");
                else if (seen.contains("169.254.")) log("decks heard (" + seen + ") on self-assigned addresses: they missed "
                        + "the router's DHCP (on before the router was up?). Unplug and replug each deck's Ethernet, or "
                        + "restart the decks with the router already on. Retrying every 5 s");
                else log("decks heard (" + seen + ") but no network interface of this computer is on their subnet; "
                        + "retrying every 5 s");
            }
            Thread.sleep(5000);
        }
        log("joined as device " + vcdj.getDeviceNumber() + " on " + vcdj.getLocalAddress());

        for (String name : List.of("MetadataFinder", "CrateDigger", "ArtFinder", "WaveformFinder",
                                   "BeatGridFinder", "TimeFinder")) {
            try {
                switch (name) {
                    case "MetadataFinder" -> MetadataFinder.getInstance().start();
                    case "CrateDigger" -> CrateDigger.getInstance().start();
                    case "ArtFinder" -> ArtFinder.getInstance().start();
                    case "WaveformFinder" -> {
                        WaveformFinder.getInstance().setColorPreferred(true);
                        WaveformFinder.getInstance().setFindDetails(true);  // needed by the timeline analyser
                        WaveformFinder.getInstance().start();
                    }
                    case "BeatGridFinder" -> BeatGridFinder.getInstance().start();
                    case "TimeFinder" -> TimeFinder.getInstance().start();
                }
                log(name + " started");
            } catch (Exception e) {
                log(name + " failed to start: " + e);
            }
        }
    }

    /** The DJ Link devices heard so far, "name #n at address, ...", for the join diagnostics. */
    static String seenDecks() {
        DeviceFinder f = DeviceFinder.getInstance();
        if (!f.isRunning()) return "";
        StringBuilder b = new StringBuilder();
        for (DeviceAnnouncement d : f.getCurrentDevices()) {
            if (b.length() > 0) b.append(", ");
            b.append(d.getDeviceName()).append(" #").append(d.getDeviceNumber()).append(" at ").append(d.getAddress().getHostAddress());
        }
        return b.toString();
    }

    // ---------- HTTP ----------

    static void index(HttpExchange ex) throws IOException {
        Path f = WEB.resolve("index.html");
        send(ex, 200, "text/html; charset=utf-8", Files.readAllBytes(f));
    }

    static void preview(HttpExchange ex) throws IOException {
        Path root = PREVIEW.toAbsolutePath().normalize();
        String rel = ex.getRequestURI().getPath().substring("/preview/".length());
        Path f = root.resolve(rel.isEmpty() ? "index.html" : rel).normalize();
        if (!f.startsWith(root) || !Files.isRegularFile(f)) {
            send(ex, 404, "text/plain", "not found".getBytes());
            return;
        }
        String name = f.getFileName().toString();
        String type = name.endsWith(".html") ? "text/html; charset=utf-8" : name.endsWith(".js") ? "text/javascript"
                : name.endsWith(".css") ? "text/css" : name.endsWith(".svg") ? "image/svg+xml"
                : name.endsWith(".png") ? "image/png" : "application/octet-stream";
        send(ex, 200, type, Files.readAllBytes(f));
    }

    static void events(HttpExchange ex) throws IOException {
        ex.getResponseHeaders().add("Access-Control-Allow-Origin", "*");
        ex.getResponseHeaders().add("Content-Type", "text/event-stream");
        ex.getResponseHeaders().add("Cache-Control", "no-cache");
        ex.sendResponseHeaders(200, 0);
        sseClients.add(new SseClient(ex));
    }

    /** One dashboard's event stream, written on its own thread so a stalled browser can't hold up the rest. */
    static final class SseClient {
        final HttpExchange ex;
        final OutputStream out;
        final AtomicInteger pending = new AtomicInteger();
        final ExecutorService writer = Executors.newSingleThreadExecutor(r -> {
            Thread t = new Thread(r, "sse-writer");
            t.setDaemon(true);
            return t;
        });

        SseClient(HttpExchange ex) { this.ex = ex; this.out = ex.getResponseBody(); }

        void send(byte[] msg) {
            if (pending.incrementAndGet() > 20) { close(); return; }     // ~2 s behind: gone or stalled, drop it
            writer.execute(() -> {
                try {
                    out.write(msg);
                    out.flush();
                } catch (IOException e) {
                    close();
                } finally {
                    pending.decrementAndGet();
                }
            });
        }

        void close() {
            if (sseClients.remove(this)) {
                writer.shutdownNow();
                ex.close();
            }
        }
    }

    static final Map<String, String> lastErr = new ConcurrentHashMap<>();

    /** Log a repeating failure once per distinct message instead of at 10-20 Hz. */
    static void logOnce(String where, Throwable t) {
        String m = String.valueOf(t);
        if (!m.equals(lastErr.put(where, m))) log(where + ": " + m);
    }

    static int playerFrom(HttpExchange ex) {
        String p = ex.getRequestURI().getPath();
        return Integer.parseInt(p.substring(p.lastIndexOf('/') + 1));
    }

    static void art(HttpExchange ex) throws IOException {
        AlbumArt art = ArtFinder.getInstance().isRunning() ? ArtFinder.getInstance().getLatestArtFor(playerFrom(ex)) : null;
        if (art == null) {
            send(ex, 404, "text/plain", "no art".getBytes());
            return;
        }
        ByteBuffer b = art.getRawBytes();
        byte[] bytes = new byte[b.remaining()];
        b.get(bytes);
        send(ex, 200, "image/jpeg", bytes);
    }

    static void waveform(HttpExchange ex) throws IOException {
        WaveformPreview wf = WaveformFinder.getInstance().isRunning()
                ? WaveformFinder.getInstance().getLatestPreviewFor(playerFrom(ex)) : null;
        if (wf == null) {
            send(ex, 404, "application/json", "{}".getBytes());
            return;
        }
        StringBuilder h = new StringBuilder(), c = new StringBuilder();
        for (int i = 0; i < wf.segmentCount; i++) {
            if (i > 0) { h.append(','); c.append(','); }
            h.append(wf.segmentHeight(i, true));
            c.append('"').append(hex(wf.segmentColor(i, true))).append('"');
        }
        String json = "{\"segments\":" + wf.segmentCount + ",\"maxHeight\":" + wf.maxHeight
                + ",\"color\":" + wf.isColor + ",\"heights\":[" + h + "],\"colors\":[" + c + "]}";
        send(ex, 200, "application/json", json.getBytes(StandardCharsets.UTF_8));
    }

    static final Map<String, byte[]> waveDetailCache = new ConcurrentHashMap<>();

    /** Detailed colour waveform, 150 frames/s, 4 bytes per frame: height (0-31), r, g, b. */
    static void waveDetail(HttpExchange ex) throws IOException {
        WaveformDetail wd = WaveformFinder.getInstance().isRunning()
                ? WaveformFinder.getInstance().getLatestDetailFor(playerFrom(ex)) : null;
        if (wd == null) {
            send(ex, 404, "text/plain", "no detail".getBytes());
            return;
        }
        byte[] body = waveDetailCache.computeIfAbsent(String.valueOf(wd.dataReference), k -> {
            int n = wd.getFrameCount();
            byte[] b = new byte[n * 4];
            for (int f = 0; f < n; f++) {
                Color c = wd.segmentColor(f, 1);
                b[f * 4] = (byte) Math.min(255, wd.segmentHeight(f, 1));
                b[f * 4 + 1] = (byte) c.getRed();
                b[f * 4 + 2] = (byte) c.getGreen();
                b[f * 4 + 3] = (byte) c.getBlue();
            }
            return b;
        });
        ex.getResponseHeaders().add("X-Wave-Key", String.valueOf(wd.dataReference));
        send(ex, 200, "application/octet-stream", body);
    }

    static void send(HttpExchange ex, int code, String type, byte[] body) throws IOException {
        cors(ex);
        ex.getResponseHeaders().add("Content-Type", type);
        ex.getResponseHeaders().add("Cache-Control", "no-cache");
        ex.sendResponseHeaders(code, body.length);
        try (OutputStream out = ex.getResponseBody()) {
            out.write(body);
        }
    }

    /** Any origin can read; the rig's own pages on other ports (same host) can also send the admin
     *  cookie, e.g. the System view's Tailscale buttons on the Lighting page. */
    static void cors(HttpExchange ex) {
        String origin = ex.getRequestHeaders().getFirst("Origin"), host = ex.getRequestHeaders().getFirst("Host");
        if (origin != null && host != null && sameHost(origin, host)) {
            ex.getResponseHeaders().add("Access-Control-Allow-Origin", origin);
            ex.getResponseHeaders().add("Access-Control-Allow-Credentials", "true");
            ex.getResponseHeaders().add("Vary", "Origin");
        } else {
            ex.getResponseHeaders().add("Access-Control-Allow-Origin", "*");
        }
    }

    static boolean sameHost(String origin, String host) {
        try {
            String o = java.net.URI.create(origin).getHost();
            String h = host.replaceAll(":\\d+$", "").replaceAll("^\\[|\\]$", "");
            return o != null && o.equalsIgnoreCase(h);
        } catch (IllegalArgumentException e) {
            return false;
        }
    }

    // ---------- state ----------

    static String state() {
        Json j = new Json().obj();
        long now = System.currentTimeMillis();
        j.num("now", now).num("uptimeSec", (now - started) / 1000);
        VirtualCdj v = VirtualCdj.getInstance();
        boolean up = v.isRunning();             // false until the decks' DJ Link network appears
        j.bool("djlink", up);
        j.key("self").obj().num("deviceNumber", up ? v.getDeviceNumber() : 0).str("name", "Sektor5")
                .str("address", up ? String.valueOf(v.getLocalAddress()) : null).end();

        DeviceUpdate master = up ? v.getTempoMaster() : null;
        j.key("master").obj();
        if (master != null) j.num("player", master.getDeviceNumber()).str("name", master.getDeviceName());
        j.num("bpm", up ? round(v.getMasterTempo(), 2) : 0).end();

        j.key("devices").arr();
        List<DeviceAnnouncement> devs = new ArrayList<>(DeviceFinder.getInstance().getCurrentDevices());
        devs.sort(Comparator.comparingInt(DeviceAnnouncement::getDeviceNumber));
        for (DeviceAnnouncement d : devs) {
            j.obj().num("number", d.getDeviceNumber()).str("name", d.getDeviceName())
                    .str("address", d.getAddress().getHostAddress()).str("mac", mac(d.getHardwareAddress()))
                    .num("seenMsAgo", now - d.getTimestamp()).end();
        }
        j.end();

        j.key("media").arr();
        if (MetadataFinder.getInstance().isRunning()) {
            for (MediaDetails m : MetadataFinder.getInstance().getMountedMediaDetails()) {
                j.obj().num("player", m.slotReference.player).str("slot", String.valueOf(m.slotReference.slot))
                        .str("name", m.name).str("created", m.creationDate).num("tracks", m.trackCount)
                        .num("playlists", m.playlistCount).num("totalBytes", m.totalSize)
                        .num("freeBytes", m.freeSpace).str("type", String.valueOf(m.mediaType)).end();
            }
        }
        j.end();

        boolean mixerFresh = mixerJson != null && now - mixerRx < 2000;
        j.raw("mixer", mixerFresh ? mixerJson : "{\"connected\":false}");
        String show = showState();
        j.raw("show", show != null ? show : "null");
        j.raw("tempo", TempoMaster.json());

        j.key("players").arr();
        for (DeviceAnnouncement d : devs) {
            DeviceUpdate u = v.getLatestStatusFor(d.getDeviceNumber());
            if (u instanceof CdjStatus s) player(j, d, s, now);
        }
        j.end();
        return j.end().toString();
    }

    static void player(Json j, DeviceAnnouncement d, CdjStatus s, long now) {
        int n = s.getDeviceNumber();
        j.obj().num("number", n).str("name", s.getDeviceName()).str("address", d.getAddress().getHostAddress())
                .str("firmware", s.getFirmwareVersion());
        j.key("status").obj()
                .bool("trackLoaded", s.isTrackLoaded()).bool("playing", s.isPlaying()).bool("paused", s.isPaused())
                .bool("cued", s.isCued()).bool("searching", s.isSearching()).bool("looping", s.isLooping())
                .bool("atEnd", s.isAtEnd()).bool("reverse", s.isPlayingBackwards())
                .bool("onAir", s.isOnAir()).bool("synced", s.isSynced()).bool("bpmSynced", s.isBpmOnlySynced())
                .bool("tempoMaster", s.isTempoMaster()).bool("busy", s.isBusy())
                .str("playState1", String.valueOf(s.getPlayState1())).str("playState2", String.valueOf(s.getPlayState2()))
                .str("playState3", String.valueOf(s.getPlayState3()))
                .num("trackBpm", s.getBpm() == 0xffff ? 0 : s.getBpm() / 100.0)
                .num("pitchPct", round(Util.pitchToPercentage(s.getPitch()), 2))
                .num("effectiveBpm", round(s.getEffectiveTempo(), 2))
                .num("beatWithinBar", s.getBeatWithinBar()).num("beatNumber", s.getBeatNumber())
                .str("cueCountdown", s.formatCueCountdown())
                .num("trackSourcePlayer", s.getTrackSourcePlayer()).str("trackSourceSlot", String.valueOf(s.getTrackSourceSlot()))
                .str("trackType", String.valueOf(s.getTrackType())).num("rekordboxId", s.getRekordboxId())
                .num("trackNumber", s.getTrackNumber()).num("syncNumber", s.getSyncNumber())
                .bool("usbLoaded", s.isLocalUsbLoaded()).bool("sdLoaded", s.isLocalSdLoaded())
                .bool("linkMediaAvailable", s.isLinkMediaAvailable())
                .num("loopBeats", s.canReportLooping() ? s.getActiveLoopBeats() : -1)
                .num("packetNumber", s.getPacketNumber()).end();

        Long lb = lastBeat.get(n);
        j.key("beat").obj().num("msSinceLast", lb == null ? -1 : now - lb).num("count", beatCount.getOrDefault(n, 0)).end();

        if (TimeFinder.getInstance().isRunning()) {
            TrackPositionUpdate pos = TimeFinder.getInstance().getLatestPositionFor(n);
            if (pos != null) {
                j.key("position").obj().num("ms", TimeFinder.getInstance().getTimeFor(n))
                        .bool("definitive", pos.definitive).bool("precise", pos.precise).end();
            }
        }

        TrackMetadata md = MetadataFinder.getInstance().isRunning() ? MetadataFinder.getInstance().getLatestMetadataFor(n) : null;
        if (md != null) {
            j.key("track").obj().str("title", md.getTitle()).str("artist", label(md.getArtist()))
                    .str("album", label(md.getAlbum())).str("genre", label(md.getGenre())).str("key", label(md.getKey()))
                    .str("label", label(md.getLabel())).str("remixer", label(md.getRemixer()))
                    .str("originalArtist", label(md.getOriginalArtist())).str("comment", md.getComment())
                    .num("durationSec", md.getDuration()).num("bpm", md.getTempo() / 100.0).num("rating", md.getRating())
                    .num("year", md.getYear()).num("bitRate", md.getBitRate()).str("dateAdded", md.getDateAdded())
                    .num("artworkId", md.getArtworkId())
                    .str("color", md.getColor() == null ? null : md.getColor().colorName)
                    .str("colorHex", md.getColor() == null || ColorItem.isNoColor(md.getColor().color) ? null : hex(md.getColor().color))
                    .str("ref", String.valueOf(md.trackReference));
            CueList cues = md.getCueList();
            j.key("cues").arr();
            if (cues != null) {
                for (CueList.Entry e : cues.entries) {
                    j.obj().num("hotCue", e.hotCueNumber).bool("loop", e.isLoop).num("ms", e.cueTime)
                            .num("loopMs", e.isLoop ? e.loopTime : 0).str("comment", e.comment)
                            .str("color", e.getColor() == null ? null : hex(e.getColor())).end();
                }
            }
            j.end().end();
        }

        BeatGrid grid = BeatGridFinder.getInstance().isRunning() ? BeatGridFinder.getInstance().getLatestBeatGridFor(n) : null;
        if (grid != null) {
            int beat = Math.max(1, Math.min(grid.beatCount, s.getBeatNumber()));
            j.key("grid").obj().num("beats", grid.beatCount).num("bar", s.getBeatNumber() > 0 ? grid.getBarNumber(beat) : 0)
                    .num("bars", grid.getBarNumber(grid.beatCount)).end();
        }
        boolean hasArt = ArtFinder.getInstance().isRunning() && ArtFinder.getInstance().getLatestArtFor(n) != null;
        WaveformPreview wf = WaveformFinder.getInstance().isRunning() ? WaveformFinder.getInstance().getLatestPreviewFor(n) : null;
        j.bool("hasArt", hasArt).str("waveformKey", wf == null ? null : String.valueOf(wf.dataReference));
        WaveformDetail wd = WaveformFinder.getInstance().isRunning() ? WaveformFinder.getInstance().getLatestDetailFor(n) : null;
        j.str("timelineKey", wd == null || grid == null ? null : String.valueOf(wd.dataReference));
        j.end();
    }

    // ---------- mixer feed (UDP from brain/mixer on localhost:9101) ----------

    static volatile String mixerJson = null;
    static volatile long mixerRx = 0;

    static void startMixerListener() {
        Thread t = new Thread(() -> {
            try (DatagramSocket s = new DatagramSocket(new InetSocketAddress("127.0.0.1", 9101))) {
                byte[] buf = new byte[8192];
                while (true) {
                    DatagramPacket pk = new DatagramPacket(buf, buf.length);
                    s.receive(pk);
                    mixerJson = new String(pk.getData(), 0, pk.getLength(), StandardCharsets.UTF_8);
                    mixerRx = System.currentTimeMillis();
                }
            } catch (Exception e) {
                log("mixer listener stopped: " + e);
            }
        }, "mixer-listener");
        t.setDaemon(true);
        t.start();
    }

    /** showbrain's live state, fetched from :8090 at most every 200 ms. */
    static volatile String showJson = null;
    static volatile long showFetched = 0;

    static String showState() {
        long now = System.currentTimeMillis();
        if (now - showFetched > 200) {
            showFetched = now;
            try {
                java.net.HttpURLConnection c = (java.net.HttpURLConnection) new java.net.URL("http://127.0.0.1:8090/api/state").openConnection();
                c.setConnectTimeout(150);
                c.setReadTimeout(250);
                try (java.io.InputStream in = c.getInputStream()) {
                    showJson = new String(in.readAllBytes(), StandardCharsets.UTF_8);
                }
            } catch (Exception e) {
                showJson = null;
            }
        }
        return showJson;
    }

    // ---------- show brain feed (UDP to localhost:9100) ----------

    static DatagramSocket brainSock;
    static final InetSocketAddress BRAIN = new InetSocketAddress("127.0.0.1", Integer.getInteger("brainPort", 9100));

    static void toBrain(String json) {
        if (Sim.on()) return;                   // fakerig sends showbrain the synthetic feed
        try {
            byte[] b = json.getBytes(StandardCharsets.UTF_8);
            brainSock.send(new DatagramPacket(b, b.length, BRAIN));
        } catch (Exception ignored) {
        }
    }

    /** Compact status for the show engine: position, beat, state and track per player. */
    static String brainStatus() {
        long now = System.currentTimeMillis();
        VirtualCdj v = VirtualCdj.getInstance();
        Json j = new Json().obj().str("t", "status").num("ts", now);
        DeviceUpdate m = v.isRunning() ? v.getTempoMaster() : null;
        j.num("master", m == null ? 0 : m.getDeviceNumber()).key("players").arr();
        // Look up each announced device directly (same path as the dashboard). getLatestStatus()
        // can come back empty after the clock jumps at boot (no RTC; NTP sync moves time forward).
        for (DeviceAnnouncement da : DeviceFinder.getInstance().getCurrentDevices()) {
            DeviceUpdate u = v.getLatestStatusFor(da.getDeviceNumber());
            if (!(u instanceof CdjStatus s)) continue;
            int n = s.getDeviceNumber();
            TrackMetadata md = MetadataFinder.getInstance().isRunning() ? MetadataFinder.getInstance().getLatestMetadataFor(n) : null;
            long pos = TimeFinder.getInstance().isRunning() ? TimeFinder.getInstance().getTimeFor(n) : -1;
            j.obj().num("n", n).bool("playing", s.isPlaying()).bool("paused", s.isPaused()).bool("cued", s.isCued())
                    .bool("looping", s.isLooping()).bool("master", s.isTempoMaster()).bool("loaded", s.isTrackLoaded())
                    .bool("onAir", s.isOnAir()).bool("atEnd", s.isAtEnd())
                    .num("bpm", round(s.getEffectiveTempo(), 3)).num("pitch", round(Util.pitchToPercentage(s.getPitch()), 3))
                    .num("beat", s.getBeatNumber()).num("pos", pos)
                    .str("ref", md == null ? null : String.valueOf(md.trackReference))
                    .str("title", md == null ? null : md.getTitle())
                    .str("key", md == null ? null : label(md.getKey())).end();
        }
        return j.end().end().toString();
    }

    // ---------- helpers ----------

    static String label(SearchableItem i) { return i == null ? null : i.label; }
    static double round(double v, int dp) { double m = Math.pow(10, dp); return Math.round(v * m) / m; }
    static String hex(Color c) { return c == null ? null : String.format("#%02x%02x%02x", c.getRed(), c.getGreen(), c.getBlue()); }
    static String mac(byte[] b) {
        StringBuilder s = new StringBuilder();
        for (int i = 0; b != null && i < b.length; i++) s.append(i > 0 ? ":" : "").append(String.format("%02x", b[i]));
        return s.toString();
    }
    static void log(String m) { System.out.println(new java.util.Date() + "  " + m); System.out.flush(); }

    /** Tiny streaming JSON writer, enough for this. */
    static class Json {
        final StringBuilder b = new StringBuilder();
        final Deque<Character> closers = new ArrayDeque<>();
        final Deque<Boolean> first = new ArrayDeque<>();
        boolean afterKey = false;

        void sep() {
            if (afterKey) { afterKey = false; return; }
            if (!first.isEmpty()) {
                if (!first.pop()) b.append(',');
                first.push(false);
            }
        }
        Json obj() { sep(); b.append('{'); closers.push('}'); first.push(true); return this; }
        Json arr() { sep(); b.append('['); closers.push(']'); first.push(true); return this; }
        Json end() { first.pop(); b.append(closers.pop()); return this; }
        Json key(String k) { sep(); quote(k); b.append(':'); afterKey = true; return this; }
        Json str(String k, String v) { key(k); afterKey = false; if (v == null) b.append("null"); else quote(v); return this; }
        Json num(String k, double v) {
            key(k); afterKey = false;
            if (Double.isNaN(v) || Double.isInfinite(v)) b.append("null");
            else if (v == Math.rint(v) && Math.abs(v) < 1e15) b.append((long) v);
            else b.append(v);
            return this;
        }
        Json bool(String k, boolean v) { key(k); afterKey = false; b.append(v); return this; }
        /** A bare number inside an array. */
        Json item(long v) { sep(); b.append(v); return this; }
        /** Write a pre-serialised JSON value (e.g. a number array) under key k. */
        Json raw(String k, String json) { key(k); afterKey = false; b.append(json); return this; }
        void quote(String s) {
            b.append('"');
            for (char c : s.toCharArray()) {
                switch (c) {
                    case '"' -> b.append("\\\"");
                    case '\\' -> b.append("\\\\");
                    case '\n' -> b.append("\\n");
                    case '\r' -> b.append("\\r");
                    case '\t' -> b.append("\\t");
                    default -> { if (c < 0x20) b.append(String.format("\\u%04x", (int) c)); else b.append(c); }
                }
            }
            b.append('"');
        }
        public String toString() { return b.toString(); }
    }
}
