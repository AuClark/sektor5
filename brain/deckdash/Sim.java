import com.sun.net.httpserver.Filter;
import com.sun.net.httpserver.HttpContext;
import com.sun.net.httpserver.HttpExchange;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.Socket;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.TimeUnit;

/**
 * Simulation mode: with no decks connected, run the synthetic rig (brain/sim/fakerig.py, see
 * docs/sim.md) on the brain, so the whole app and the real lights run on a generated DJ set.
 *
 * deckdash stays in charge (page, admin PIN, System view, Tailscale). It runs fakerig on a private
 * port, passes the deck data API through to it, and stops sending its own (empty) deck feed to
 * showbrain; fakerig sends the synthetic one. The mixer service is paused meanwhile (with no DJM it
 * would keep telling showbrain the mixer is unplugged). Nothing persists: a restart or reboot is
 * back on the real decks.
 */
public class Sim {
    static final int PORT = 8079;
    static final Path FAKERIG = Path.of(System.getProperty("user.home"), "sim", "fakerig.py");
    static volatile Process proc;
    static volatile double bpm = 126;
    static volatile long startedAt = 0;

    static boolean on() {
        Process p = proc;
        return p != null && p.isAlive();
    }

    static boolean available() {
        return Files.isRegularFile(FAKERIG);
    }

    /** For /api/system and /api/sim. */
    static String json() {
        boolean dj = org.deepsymmetry.beatlink.VirtualCdj.getInstance().isRunning();
        int devices = realDecks();
        return new DeckDash.Json().obj().bool("on", on()).bool("available", available()).num("bpm", bpm)
                .num("since", on() ? startedAt : 0).bool("djlink", dj).num("decks", devices).num("selfAssigned", selfAssigned())
                .num("uptime_s", (System.currentTimeMillis() - DeckDash.started) / 1000).end().toString();
    }

    /** GET /api/sim; POST {"on": true|false, "bpm": 126} (admin). */
    static void handle(HttpExchange ex) throws IOException {
        if ("POST".equals(ex.getRequestMethod())) {
            if (!Auth.require(ex)) return;
            String body = new String(ex.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
            java.util.regex.Matcher m = java.util.regex.Pattern.compile("\"bpm\"\\s*:\\s*([0-9.]+)").matcher(body);
            if (m.find()) bpm = Math.max(80, Math.min(180, Double.parseDouble(m.group(1))));
            String err = body.matches("(?s).*\"on\"\\s*:\\s*true.*") ? start() : body.matches("(?s).*\"on\"\\s*:\\s*false.*") ? stop() : "send {\"on\": true|false}";
            if (err != null) {
                DeckDash.send(ex, 400, "application/json", ("{\"error\":\"" + err + "\"}").getBytes(StandardCharsets.UTF_8));
                return;
            }
        }
        DeckDash.send(ex, 200, "application/json", json().getBytes(StandardCharsets.UTF_8));
    }

    /** Decks on self-assigned (169.254) addresses: heard, but no track info for them. */
    static int selfAssigned() {
        org.deepsymmetry.beatlink.DeviceFinder f = org.deepsymmetry.beatlink.DeviceFinder.getInstance();
        if (!f.isRunning()) return 0;
        int n = 0;
        for (org.deepsymmetry.beatlink.DeviceAnnouncement d : f.getCurrentDevices())
            if (d.getAddress().getHostAddress().startsWith("169.254.")) n++;
        return n;
    }

    /** Real Pro DJ Link gear on the network (players, mixers). */
    static int realDecks() {
        org.deepsymmetry.beatlink.DeviceFinder f = org.deepsymmetry.beatlink.DeviceFinder.getInstance();
        return f.isRunning() ? f.getCurrentDevices().size() : 0;
    }

    // Never simulate over real decks: when any turn up, the simulation switches itself off.
    static {
        Thread t = new Thread(() -> {
            while (true) {
                try {
                    Thread.sleep(2000);
                    if (on() && realDecks() > 0) {
                        DeckDash.log("real decks connected: simulation off");
                        stop();
                    }
                } catch (Throwable ignored) {
                }
            }
        }, "sim-guard");
        t.setDaemon(true);
        t.start();
    }

    static synchronized String start() {
        if (on()) return null;
        if (realDecks() > 0) return "real decks are connected: the show is on them";
        if (!available()) return "the simulator isn't installed (brain/deploy.sh deckdash copies it)";
        SystemInfo.exec(10, "sudo", "-n", "systemctl", "stop", "mixer");
        try {
            proc = new ProcessBuilder("python3", "-u", FAKERIG.toString(), "--port", String.valueOf(PORT),
                    "--feed", "9100", "--bpm", String.valueOf(bpm))
                    .redirectErrorStream(true).redirectOutput(ProcessBuilder.Redirect.appendTo(new File("/tmp/fakerig.log"))).start();
        } catch (IOException e) {
            SystemInfo.exec(10, "sudo", "-n", "systemctl", "start", "mixer");
            return "couldn't start the simulator: " + e.getMessage();
        }
        for (int i = 0; i < 50 && on(); i++) {                // wait for its API (up to 5 s)
            try (Socket s = new Socket("127.0.0.1", PORT)) {
                break;
            } catch (IOException e) {
                try { Thread.sleep(100); } catch (InterruptedException ie) { break; }
            }
        }
        if (!on()) {
            SystemInfo.exec(10, "sudo", "-n", "systemctl", "start", "mixer");
            return "the simulator exited at start (see /tmp/fakerig.log)";
        }
        startedAt = System.currentTimeMillis();
        DeckDash.log("simulation on (" + bpm + " BPM)");
        refresh();
        return null;
    }

    static synchronized String stop() {
        Process p = proc;
        proc = null;
        if (p != null) {
            p.destroy();
            try {
                if (!p.waitFor(3, TimeUnit.SECONDS)) p.destroyForcibly();
            } catch (InterruptedException ignored) {
            }
            DeckDash.log("simulation off");
        }
        SystemInfo.exec(10, "sudo", "-n", "systemctl", "start", "mixer");
        refresh();
        return null;
    }

    /** Pages reload right after a switch: make /api/system show it straight away. */
    static void refresh() {
        try {
            SystemInfo.snapshot = SystemInfo.sample();
        } catch (Throwable ignored) {
        }
    }

    // ---------------------------------------------------------------- pass-through

    /** Add to a deck-data context: in simulation its requests go to fakerig instead. */
    static HttpContext proxied(HttpContext c) {
        c.getFilters().add(FILTER);
        return c;
    }

    static final Filter FILTER = new Filter() {
        @Override
        public void doFilter(HttpExchange ex, Chain chain) throws IOException {
            if (!on()) {
                chain.doFilter(ex);
                return;
            }
            String method = ex.getRequestMethod();
            if (!"GET".equals(method) && !"HEAD".equals(method) && !Auth.require(ex)) return;   // changes stay admin-only
            forward(ex);
        }

        @Override
        public String description() {
            return "simulation pass-through";
        }
    };

    static void forward(HttpExchange ex) throws IOException {
        boolean stream = ex.getRequestURI().getPath().equals("/api/events");
        HttpURLConnection c;
        try {
            c = (HttpURLConnection) URI.create("http://127.0.0.1:" + PORT + ex.getRequestURI()).toURL().openConnection();
            c.setRequestMethod(ex.getRequestMethod());
            c.setConnectTimeout(2000);
            c.setReadTimeout(stream ? 0 : 15000);
            String ct = ex.getRequestHeaders().getFirst("Content-Type");
            if (ct != null) c.setRequestProperty("Content-Type", ct);
            if ("POST".equals(ex.getRequestMethod())) {
                c.setDoOutput(true);
                try (OutputStream o = c.getOutputStream()) {
                    ex.getRequestBody().transferTo(o);
                }
            }
            int code = c.getResponseCode();
            InputStream in = code >= 400 ? c.getErrorStream() : c.getInputStream();
            String type = c.getContentType() == null ? "application/json" : c.getContentType();
            if (!stream) {
                DeckDash.send(ex, code, type, in == null ? new byte[0] : in.readAllBytes());
                return;
            }
            DeckDash.cors(ex);
            ex.getResponseHeaders().add("Content-Type", type);
            ex.getResponseHeaders().add("Cache-Control", "no-cache");
            ex.sendResponseHeaders(code, 0);
            try (OutputStream out = ex.getResponseBody(); InputStream src = in) {
                byte[] buf = new byte[8192];
                for (int n; src != null && (n = src.read(buf)) > 0; ) {
                    out.write(buf, 0, n);
                    out.flush();
                }
            } catch (IOException closed) {
                // the browser went away, or simulation stopped
            } finally {
                c.disconnect();
            }
        } catch (IOException e) {
            DeckDash.send(ex, 502, "application/json", "{\"error\":\"simulator not responding\"}".getBytes(StandardCharsets.UTF_8));
        }
    }
}
