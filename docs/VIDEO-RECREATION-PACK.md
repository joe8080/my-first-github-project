# Video recreation pack · God's Eye View over Worthing

A production sheet for recreating Bilawal Sidhu's walkthrough
(https://youtu.be/o_FJ1NIH9yw) as a Worthing-first video, using the same visual
system. The app itself already renders the same HUD, reticle and sensor looks,
so the screen recordings match by default. This sheet covers the parts that are
edited in, not rendered by the app.

## 1. Visual template (taken from the original)

**Colour palette**

| Role | Colour |
| --- | --- |
| Base | Space black `#050811`, `#000000` |
| Primary accent | Cyber cyan `#00F0FF`, `#1BE7FF` |
| Tactical green | `#00FF66` |
| Alert red | `#FF3344` |
| Amber | `#FFCC00` |

**Typography**

- Headings and chapter cards: bold, extended, uppercase sans-serif
  (Eurostile / Microgramma / Orbitron family).
- HUD data, captions and section tags: monospace (JetBrains Mono / Roboto Mono).

**Recurring graphic elements**

- Lower-left section pill tag in square brackets, monospace, e.g.
  `[ THE INTERFACE ]`, `[ COCKPIT VIEW ]`, `[ VESSEL TRACKING ]`.
- Full-screen chapter title cards: centred bold white uppercase text on a dark
  textured carbon / topographic background, on screen for about 2 seconds.
- Bracketed numbered lists on a dark HUD graphic with red accent underlines,
  e.g. `[1] How do I run it?` `[2] What can it do?`
- Crosshairs, telemetry reticles and CRT scanlines carried over from the app.
- Rounded glass dialog boxes for pop-ups.
- Auto-generated bold sans-serif captions, centred in the lower frame.
- Social-proof montage: vertical clips sliding in over a dark grid, with big
  white uppercase headings and dark drop shadows.

**Editing rhythm**

- Intro and hooks: fast cuts, 2 to 3 seconds per shot.
- Demos: long uninterrupted screen recordings with animated zoom-ins on the
  control being clicked.
- Faceless version: drop the webcam inset entirely. The original pins it
  bottom-right; the bottom-right corner is where the POWER UP chip sits, so
  keep that corner clear in the recordings.

**End screen**

- High-contrast HUD background with a bold futuristic title, e.g.
  `WORTHING · PART 2 [COMING SOON]`.

## 2. Chapter structure for the Worthing version

Mirror the original's order so the video sits alongside it. Keep the run time
around 15 to 20 minutes for a first version.

| # | Chapter | Section tag | What to record |
| --- | --- | --- | --- |
| 0 | Cold open | none | Globe spins into Worthing, planes already moving. Chapter card: `A SPY SATELLITE OVER WORTHING`. |
| 1 | Install | `[ INSTALL ]` | Pinokio: Download from URL, Install, Start. Then the coding-agent prompt from the README. |
| 2 | Worthing Skies | `[ THE INTERFACE ]` | Click WORTHING SKIES on the first-launch card. Show the map source chips, location tray, display settings. |
| 3 | Planes over the coast | `[ FLIGHT TRACKING ]` | White = commercial, yellow = military. Click a Gatwick arrival over the Channel, watch the trail draw. |
| 4 | Shoreham Airport | `[ CONTACTS MODE ]` | Press `W` in the location tray. Open Contacts, step through the 250 km roster. |
| 5 | Cockpit | `[ COCKPIT VIEW ]` | Press `C` on a tracked aircraft, switch NVG to FLIR mid-flight. |
| 6 | Ships | `[ VESSEL TRACKING ]` | With the AISstream key in, turn on vessels. Shoreham Harbour, Rampion service boats, ferries off Newhaven. Explain coverage is best near shore. |
| 7 | Sensor looks | `[ DISPLAY MODES ]` | Keys `1` to `7`: CRT, NVG, FLIR, Noir, Snow over Worthing Pier. |
| 8 | Voice (optional) | `[ VOICE MODE ]` | "Take me to Worthing Pier." "Draw the route from the pier to Shoreham Airport." "Fly that route." |
| 9 | Satellites | `[ ORBIT ]` | ISS pass over the Channel. |
| 10 | Scene recording | `[ SCENE / VIDEO RECORDING ]` | Capture three shots: Pier, Airport, Wind Farm. Play back. |
| 11 | Wrap | none | Links in the description. Ask what to track next. End screen. |

## 3. Shot list, Worthing points of interest

All five are wired into the location tray under **Worthing**.

| Key | POI | Latitude | Longitude | Suggested framing |
| --- | --- | --- | --- | --- |
| Q | Worthing Pier | 50.8092 | -0.3701 | 1.8 km range, pitch -30, looking north from the sea |
| W | Shoreham Airport (EGKA) | 50.8356 | -0.2972 | 2.2 km range, pitch -35, heading 20 |
| E | Shoreham Harbour | 50.8290 | -0.2450 | 1.6 km range, pitch -30, heading east |
| R | Rampion Wind Farm | 50.6650 | -0.2700 | 6 km range, pitch -30, looking south |
| T | Cissbury Ring | 50.8608 | -0.3806 | 1.4 km range, pitch -35, looking south over the town |

The WORTHING SKIES tile uses the overview bounds (50.72 to 50.92 N, -0.56 to
-0.14 E), which is wide enough to hold Littlehampton, Worthing, Shoreham and the
western edge of Brighton in one frame.

## 4. Title and thumbnail ideas

Titles (score them in vidIQ before choosing):

1. I Turned a Spy Satellite on Worthing (It's Free and Open Source)
2. Every Plane and Ship Over Worthing, Live, in Your Browser
3. God's Eye View Over the Sussex Coast

Thumbnail: the tactical HUD over Worthing Pier with one tracked aircraft, a red
box around it, cyan telemetry, and the text `LIVE · WORTHING` in bold extended
uppercase. Keep faces out, per the faceless channel format.

## 5. Description template

```
Every plane and ship over Worthing, live, on a photorealistic 3D globe. This is
God's Eye View, the open-source spy-satellite simulator by Bilawal Sidhu, set up
for the Sussex coast.

Worthing Edition (this fork) → <your repository URL>
Original project → https://github.com/bilawalsidhu/gods-eye-view
One-click installer (original) → https://pinokio.co/apps/github-com-bilawalsidhu-gods-eye-view
Get Pinokio (8.2+) → https://desktop.pinokio.co/
Original walkthrough video → https://youtu.be/o_FJ1NIH9yw

Free keys used in this video:
Ships (AIS) → https://aisstream.io
Photorealistic 3D → https://cesium.com/ion

CHAPTERS
0:00 A spy satellite over Worthing
...
```

The full set of original description links is in [VIDEO-LINKS.md](VIDEO-LINKS.md).

## 6. Policy notes for a clean, education-first upload

- All data shown is public and already attributed in DATA_SOURCES.md. Say so on
  screen, as the original does.
- Do not zoom into private property or identify people from CCTV frames.
- Keep API keys off screen. The POWER UP panel masks them, but blur the panel
  during any key entry anyway.
