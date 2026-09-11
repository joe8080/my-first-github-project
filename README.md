# 🌐 God's Eye View · Worthing Edition

A spy-satellite simulator in your browser, pointed at **Worthing, West Sussex**.
Live planes over Worthing and Shoreham, Channel shipping, satellites, earthquakes
and public cameras on a photorealistic 3D globe, with the same tactical HUD,
scope reticle, CRT / NVG / FLIR looks, cockpit view and voice control as the
original.

This is Joe Moyo's fork of [God's Eye View](https://github.com/bilawalsidhu/gods-eye-view)
by Bilawal Sidhu (MIT licence, kept in [LICENSE](LICENSE)). The app code is the
upstream app. What this fork adds:

- **WORTHING SKIES** first-run tile. One click frames the Worthing coast and
  turns on live flights, military flights and live vessels.
- **Worthing** in the location tray, first pill, with five points of interest:
  Worthing Pier, Shoreham Airport (EGKA), Shoreham Harbour, Rampion Wind Farm
  and Cissbury Ring. Keys `Q` `W` `E` `R` `T` jump between them.
- [docs/VIDEO-LINKS.md](docs/VIDEO-LINKS.md), every link from the walkthrough
  video's description, ready to paste into a YouTube description.
- [docs/VIDEO-RECREATION-PACK.md](docs/VIDEO-RECREATION-PACK.md), the visual
  style, chapter structure and a Worthing shot list for recreating the video.

Upstream's full README is kept at [docs/UPSTREAM-README.md](docs/UPSTREAM-README.md).

---

## ⚡ Quick start (no terminal, no keys)

1. Install or update [Pinokio](https://desktop.pinokio.co/) to **8.2 or later**.
2. In Pinokio, choose **Download from URL** and paste this repository's URL.
3. Click **Install**, then **Start**, then **Open God's Eye View**.
4. On the first-launch card, click **WORTHING SKIES**.

You will see Worthing from the sea, with live aircraft (white) and military
traffic (yellow) already moving. No API keys are needed for that.

If you would rather use the official upstream listing, it is
[God's Eye View on Pinokio](https://pinokio.co/apps/github-com-bilawalsidhu-gods-eye-view).
That installs the original without the Worthing tile.

## ⚡ Quick start (coding agent)

Paste this into Claude Code, Codex, Cursor or any coding agent that runs on your
computer:

> Set up God's Eye View Worthing Edition from this repository on my computer.
> Read the README, check the prerequisites (Node.js 24.14+ or 26), run
> `npm ci`, `npm run doctor` and `npm run dev`, then open http://localhost:4173.
> Then walk me through the POWER UP panel so I can add a free AISstream key for
> live ships and a free Cesium ion token for photorealistic 3D. Keep API keys
> local; don't ask me to paste them into this chat.

Or by hand:

```bash
npm ci
npm run doctor
npm run dev
```

Open **http://localhost:4173** and click **WORTHING SKIES**.

---

## 🔑 Keys that make Worthing better (all optional)

Add keys inside the app: click the **POWER UP** chip, bottom-right, paste, then
**SAVE KEYS**. Nothing goes into a file by hand.

| Layer | Key | Cost | Why |
| --- | --- | --- | --- |
| Ships in the Channel | `AISSTREAM_API_KEY` from [aisstream.io](https://aisstream.io) | Free | The WORTHING SKIES tile requests vessels. Without this key the vessels row reads KEY REQUIRED and planes still work. |
| Photorealistic 3D | `CESIUM_ION_TOKEN` from [cesium.com/ion](https://cesium.com/ion) | Free for eligible personal, non-commercial use | Google 3D tiles for the seafront, pier and airport. |
| Voice control | `OPENAI_API_KEY` | Metered | "Take me to Shoreham Airport and follow the nearest aircraft." |
| Traffic on the A27 | `TOMTOM_API_KEY` | Free tier | Colour-coded road traffic. |

Provider terms and quotas apply. See [Keys & Costs](docs/UPSTREAM-README.md#-api-keys)
and [SECURITY.md](SECURITY.md) before sharing the app on a network.

---

## 🛩️ What to try first over Worthing

1. Click **WORTHING SKIES**, wait for the coast to frame.
2. Press `H` for the tactical HUD and `D` for the detection boxes.
3. Click any aircraft. The camera locks on and draws its trail.
4. Press `C` for cockpit view and ride a Gatwick arrival along the coast.
5. Press `2` for CRT, `3` for NVG, `4` for FLIR.
6. Open the location tray and press `W` to jump to Shoreham Airport.
7. Turn on **Satellites** and click the ISS as it passes over the Channel.

Keyboard: `1`–`7` visual styles · `H` HUD · `D` detection · `C` cockpit · `Esc` out.

---

## 📺 The video this recreates

Bilawal Sidhu, *God's Eye View Blew Up. Here's What You Can Do With It.*
https://youtu.be/o_FJ1NIH9yw

All of the links from that video's description are collected in
[docs/VIDEO-LINKS.md](docs/VIDEO-LINKS.md).

---

## 🧪 Checks

```bash
npm test        # 2,700+ unit tests, including the Worthing mission tests
npm run build   # production build
```

## 🙏 Credits

God's Eye View is by [Bilawal Sidhu](https://bilawal.ai) and contributors, MIT
licensed. Data sources and attribution are listed in
[DATA_SOURCES.md](DATA_SOURCES.md). This fork changes the home location, the
first-run tile and the documentation only.

---

## 📁 The learning files

This repository started as a GitHub learning project. Those files are still here
untouched: `hello.py`, `notes.txt` and `ideas/future-projects.txt`.
