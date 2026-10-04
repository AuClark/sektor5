# Projector (projection mapping)

A projector running Chrome, showing the brain's projection-mapping page full-screen. Content is warped onto real-world surfaces and beat-locked to the show engine. Code: [`brain/projector/`](../../brain/projector/). Service: `projector` on the brain, port **8100**.

**Status (27 Sep 2026):** phase 1 running: surfaces with corner-pin warping, masks, seven content types, a live editor and presets. Phase 2 (camera auto-calibration) not started.

## Pages

| URL | For | What it does |
|---|---|---|
| `http://sektor5.local:8100/` | The projector | Full-screen output. Tap/click or press F / Enter for fullscreen. T toggles the test pattern, I shows an info HUD. `?test=1` and `?hud=1` do the same from the URL. |
| `http://sektor5.local:8100/edit` | A phone or laptop | The mapping editor, with a live preview of the output at the projector's aspect ratio |

## Setting up a room (about 5 minutes)

1. Open `/` on the projector and make it full-screen.
2. Open `/edit` on your phone. Turn on **Handles on wall** so the corner dots show on the wall too.
3. For each wall, panel or object: **+ Surface** (four corners) or **+ Triangle** (three: the apex, then the base right and base left, for the faces of a pyramid), then drag its corner dots onto the real corners. A triangle shows its content's square cropped to the triangle, apex at the top centre. **+ Diamond** (four corners: top, right, bottom, left) keeps the picture upright and centred and crops it to the diamond (the square's edge midpoints land on the diamond's corners), so a sketch doesn't turn 45° the way it would on a rotated four-corner surface. Each corner has its own colour: red top-left, green top-right, blue bottom-right, yellow bottom-left. Drag inside a surface to move it. On a laptop, arrow keys nudge the selected corner by 1 px (Shift = 10 px); **Next corner** picks which one.
4. **Test pattern** on: every surface shows a grid, border and circle. Adjust until the lines look straight and the circle round on the real surface.
5. Pick what each surface shows (the picker on its row under **Surfaces**), and draw **masks** over anything that shouldn't be lit (doorways, the DJ, speakers): **+ Draw mask**, tap points around it, then **Finish mask**.
6. Set **Latency compensation** with the Test pattern still on: its centre circle flashes on every beat (red on beat 1). Move the slider until the flash lands on the kick, by ear, or film the projection next to a deck's beat counter in slow motion. Then turn off Handles and Test pattern, and **Save** a preset (e.g. `workshop-back-wall`).

Layouts are saved on the brain in `~/projector/layouts/`: `current.json` plus presets. They aren't in git.

### Mapping from the Stage view

The [Stage view](../stage.md) models each projector as a camera: its lens is 16:9 with **Throw** as the horizontal angle, and it throws its picture exactly as the real one would. So you can map there before you're on site, and check the result:

- **MAP ONTO** (Stage → select a projector → *Map onto*, e.g. `Pyramid`): works out where each flat face of that part of the set lands in the projector's picture and adds a surface for each (a triangle for each face of a pyramid, a quad for a four-cornered face), named `Pyramid · left face` and so on, each with a different generative sketch. Mapping again replaces those surfaces but keeps the content you gave them. It only uses faces the projector sees completely; it doesn't know about things in the way.
- **SEND TO EDITOR** renders the set through the projector's lens, with work lights on, and sends it to the Projection editor as that projector's **Backdrop** (toolbar: *Backdrop*, and its strength). Drag corners onto the shapes in it. The backdrop is only in the editor; the projector never shows it.
- **LOOK THROUGH** puts the Stage camera at the lens, so you see what the projector sees.

On site, the real projector needs the same position, aim and throw as in the Stage view for the mapping to land; then fine-tune the corners with the projector on. The centre pyramid in the outdoor venue is a half-pyramid against the front of the table: the mapping projector on the front crossbar sees its two front faces.

## Content

| Content | Look |
|---|---|
| `show` | Follows the scene engine. Groove: a pulse and ring on every beat, whiter on beat 1. Breakdown: dim two-colour plasma with sparse sparkles on the eighth notes. Build: strobe that speeds up, fill rising, washing to white. Pre-drop: blackout. Drop: white hit, then rings that alternate colour. |
| `pulse` | Whole surface flashes in the track's key colour on each beat |
| `tunnel` | Rings flowing inward on the beat |
| `bars` | Beat-driven bars scaled by the bar's energy |
| `title` | Current track title, glowing on the beat |
| `solid` | Key colour |
| `test` | Alignment grid for that surface |
| `gen` (generative) | **Focus**: the look the [visuals service](../visuals.md) on :8110 is playing (the Visuals page, Shuffle), or a sketch of its own |

**Picking it:** every surface on the projector has one row under **Surfaces** with its name and a single picker: **Focus** first, then every sketch by theme (by title), then the built-in contents at the bottom (**Built in**: Lights' colours = `show`, Beat flash, Tunnel, Bars, Track name, Solid colour, Test grid). A surface given its own sketch gets a second picker for its preset (**As last left** = the values it was last left at on the Visuals page). So which sketch is on which surface reads at a glance, and changes in one tap. The handles on the preview label each surface the same way.

Every surface has its own opacity and hue shift, so neighbouring surfaces can use complementary colours.

**Picture position and zoom:** a surface's **Picture across** and **Picture up / down** shift the picture inside it without moving its corners, up to half its width or height (`off_x`, `off_y` in the layout; + is right / down). **Picture zoom** scales it about the surface's centre, 50% to 250% (`zoom`, 1 = as made). **Reset picture** puts both back. **Each sketch keeps its own place on a surface:** what you adjust belongs to the sketch on the surface now (`off_for`), and **Keep for SKETCH** saves it for that sketch (`fit`: `{sketch: [x, y, zoom]}`; a built-in content keys by its name). When the surface changes sketch (by hand, Next look, Shuffle on a Focus surface) the new one sits where it was kept, or centred, and an unkept adjustment goes. **Forget** drops a kept one. It's handy when the interesting part of a sketch doesn't land in the middle of an odd-shaped face. Focus's Projection screen has the same as a d-pad and a drag pad.

**Corners and borders:** each surface also has a **corner radius** (0 = square, up to fully round) and an optional **border**: a bright band just inside the edge, with the content inside it. Border controls: width, brightness (up to 200%), colour (white through to the show's colour) and beat pulse (0 = steady, 1 = flashes on the beat).

## How it works

- `projector.py` serves the pages and pushes showbrain's state to every open page about 20 times a second (Server-Sent Events, `/api/events`). Layout changes from the editor are saved and pushed to all pages immediately.
- `web/render.js` is the shared WebGL renderer. For each surface it computes the homography from the unit square to the surface's corners, and the fragment shader maps every pixel back through the inverse. The content is therefore perspective-correct on angled surfaces, with no mesh or texture resampling. Masks and edit handles go on a 2D overlay.
- `render.js` also holds the live track's waveform (a `wave` event from the visuals service) as a texture, so sketches can call `wave(beat)`; see [docs/visuals.md](../visuals.md#the-live-tracks-waveform).
- Beat position is extrapolated locally between updates, and shifted by the layout's latency compensation (`lead_ms`). The page counts each update's age from showbrain's timestamp and removes showbrain's own `lead_ms` (which is for the LEDs' Wi-Fi), so the projector's `lead_ms` is only its own output delay: GPU, HDMI and the projector's processing. If the page's clock is more than a second off showbrain's (another machine without NTP), it counts from when each update arrives.
- **Frame rate and resolution:** the projector's GPU is weak. With **Render resolution** on *auto* (Output card), the output page renders below full resolution when its frame rate drops under 45 fps, and climbs back when it's above 57 fps. The canvas is always stretched to the full screen. Pick a fixed 100–35% to override. The page reports its frame rate, render scale and GPU name every 2 s, and the editor shows them in the strip under the preview (red below 40 fps). Each surface is drawn only over its bounding box, so small surfaces are cheap.
- **Auto-reload:** each service sends a `hello` with a version of its page code when a page connects. After a deploy the service restarts, the page reconnects, sees a new version and reloads itself, so the projector never needs a hard refresh.
- The output page reports its real resolution (`/api/screen`) so the editor matches its aspect ratio. Opening `/` on another device will overwrite that, so only open `/` on the projector.

## API (on :8100)

`GET /api/events` (SSE: `state`, `layout`, `screen`, `backdrop`), `GET/POST /api/layout`, `GET /api/layouts`, `GET/POST /api/layouts/NAME`, `POST /api/layouts/NAME/load`, `POST /api/screen`, `POST /api/colour` (from the first projector's output page: the picture's main colour `{"hue","sat"}` or `{"hue": null}`, passed on to showbrain for the lights' Visuals palette, see [show-engine.md](../show-engine.md)), `GET/POST /api/backdrop?p=PROJECTOR` (a JPEG, the editor's backdrop; POST needs the admin PIN).

## Next (phase 2)

- **Camera auto-calibration:** project Gray-code patterns, film them on a phone at `/calibrate`, decode the projector-to-camera mapping, and snap surfaces to detected edges.
- **Mesh warp** for curved surfaces (a grid of control points per surface).
- More content, and a per-surface "follow deck" option.

## Several projectors, and a sketch per surface

- **Projectors:** the editor's projector picker (on the strip under the preview) adds, renames and removes projectors. Each surface and mask belongs to the projector that was picked when it was made. Open each projector's output page with its id: `http://sektor5.local:8100/?p=right` (hover the picker for the exact address; the first projector needs no `?p`). The preview takes each projector's own screen size, and each reports its own frame rate.
- **A sketch per surface:** a surface shows **Focus** (whatever the Visuals page is showing) or a sketch of its own, optionally with one of that sketch's **presets**. A sketch of its own runs with the values it was last left at on the Visuals page (or the preset's), ridden by the knob player when it's on ([visuals-live.md](../visuals-live.md#play-the-knobs)). Tweaks on the Visuals page show straight away on every surface using the sketch that's live there.
- **Cost:** the projector's GPU pays for each surface's pixels times how heavy its sketch is, not for how many different sketches there are. Five sketches on five surfaces cost about the same as one sketch over the same area. Overlapping surfaces pay twice, and ray-marched sketches (diamond, horizon…) are the heavy ones. Loading a sketch compiles it once (a brief hitch). Render resolution *auto* covers slowdowns.
