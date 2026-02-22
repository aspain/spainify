# Overview
A Raspberry Pi home media hub for Spotify/Sonos now-playing display, Sonos controls, local weather at a glance, and more.

**Examples:**
<p align="center">
  <img src="assets/images/dead.jpeg" alt="now playing - dead" width="300" />
  <img src="assets/images/herbie.jpeg" alt="now playing - herbie" width="170" />
  <img src="assets/images/weather.jpeg" alt="weather dashboard" width="170" />
</p>

This project contains a set of locally hosted apps and services with features including:
- Sonos and Spotify now-playing LCD: displays artist, track title and album artwork with a vibrant, dynamic background color chosen from the album artwork
- Local weather dashboard: displays local forecast during a scheduled window, via free OpenWeather API
- Custom local network endpoints: add the currently-playing song to a Spotify playlist which can be set up as a single-click iOS shortcut, and includes de-dupe to prevent the same song from being added multiple times
- Full Sonos controls: group/ungroup rooms, adjust volume, play/pause/skip tracks, etc. via iOS shortcuts, no longer need to use the clunky Sonos app
- Sonos presets: combine multiple actions (group rooms, set volume, add playlist to queue, play in shuffle, etc) all into a single iOS shortcut
- Auto display sleep/wake behavior: based on playback and schedule

## Hardware Requirements

* Raspberry Pi - I used a [Raspberry Pi 4](https://www.amazon.com/dp/B07TC2BK1X?th=1) and a separate [power adapter](https://www.amazon.com/dp/B07VFDYNL4)
* LCD Screen - I used a [7.9" Waveshare](https://www.waveshare.com/7.9inch-hdmi-lcd.htm) / [Amazon](https://www.amazon.com/dp/B087CNJYB4)
* [Micro SD Card](https://www.amazon.com/dp/B08J4HJ98L?th=1)

---

## First-Time Setup

See [Setting up Pi from Scratch](#setting-up-pi-from-scratch) to prepare your Pi for install.

Use this from your laptop/desktop terminal (recommended):

```bash
git clone https://github.com/aspain/spainify.git
cd spainify
./scripts/setup-remote.sh <pi-user>@<pi-ip> --fresh
```

This is the main setup command. It connects to the Pi over SSH, runs the setup wizard, and runs redeploy.
If `media-actions-api` is enabled, it also handles Spotify auth through the tunneled login URL automatically.

Now-playing works without Spotify credentials.
Spotify credentials are only required for add-to-playlist and optional metadata enrichment (via `media-actions-api`).

Before running setup, gather API credentials:

1. OpenWeather (weather-dashboard)
   - Create/sign in and generate an API key at https://home.openweathermap.org/api_keys
   - Paste that value into the `OpenWeather API key` setup prompt.
   - Setup then prompts for location input with three modes:
     - US mode: enter city, then 2-letter state code
     - International mode: enter city, then 2-letter country code
     - Advanced mode: enter a raw OpenWeather location query

2. Spotify (media-actions-api)
   - Create/sign in to Spotify Developer and open the dashboard: https://developer.spotify.com/dashboard
   - Create an app and add both redirect URIs:
     - `http://127.0.0.1:8888/callback`
     - `http://<your-pi-ip-address>:8888/callback`
   - Copy `Client ID` and `Client Secret` into setup prompts.

Optional: run setup directly on the Pi (for local desktop use):

```bash
cd ~/spainify
./setup.sh
```

`setup.sh` is the core setup wizard used by `setup-remote.sh`.

To change service choices later, just re-run setup:

```bash
./scripts/setup-remote.sh <pi-user>@<pi-host-or-ip>
```

---

## Apps and Services

- `media-actions-api.service` — add-to-playist + metadata + Sonos grouping API
- `display-controller.service` — Python display controller (power, browser, mode switching)
- `sonify-ui.service` — powers the now-playing web UI host
- `sonos-http-api.service` — Sonos HTTP API backend, allows for one-click iOS shortcut presets
- `weather-dashboard.service` — weather forecast web UI host
- Source app directories live under `apps/` (for example `apps/media-actions-api`, `apps/display-controller`, `apps/sonify-ui`)
- `systemd/` — service unit templates
- `scripts/redeploy.sh` — deploy/restart enabled services for this Pi

## Default Ports

- Sonify UI: `http://localhost:5000`
- Weather dashboard: `http://localhost:3000`
- Sonos HTTP API: `http://localhost:5005`
- Media actions API: `http://localhost:3030`
- Spotify auth helper (setup flow only): `http://127.0.0.1:8888/login` (via tunnel)

## iOS Shortcut: Add Current Track to Playlist

This shortcut hits the local `media-actions-api` and adds the currently playing track to your configured Spotify playlist with a single tap in iOS (it can be placed on the lock screen, in widgets, etc.).
This avoids opening the Spotify or Sonos app and manually adding the song to a playlist.
It prefers Spotify playback when available and automatically falls back to Sonos playback when needed.

- Import shortcut: [add-current shortcut](https://www.icloud.com/shortcuts/511ff5126be2452d8369935922f43e97)
- In the first `Get Contents of` action, replace the host IP with your Pi IP and use `http://<pi-ip>:3030/media-actions-smart`.
- `/media-actions-smart` checks Spotify current playback first.
- If Spotify is empty, it falls back to the best active Sonos zone and extracts Spotify track URI/ID.
- In default `music` mode, it ignores TV/line-in sources.
- It applies de-duplication (recent-add memory + playlist membership check) before adding.
- It adds to the playlist configured by setup prompt `Spotify playlist link or ID for media-actions-api (/media-actions-smart)`.

## Redeploy / Update Workflow

Use this after code changes to pull and redeploy enabled services on a configured Pi:

```bash
ssh <pi-user>@<pi-host-or-ip> 'cd ~/spainify && git pull --ff-only && ./scripts/redeploy.sh'
```

Use setup when you need to change service enablement, room selection, or other setup-driven config:

```bash
cd /path/to/spainify
./scripts/setup-remote.sh <pi-user>@<pi-host-or-ip>
```

For multi-Pi setups, run these commands on each Pi.

## Setting up Pi from Scratch

1. Put the microSD card in your laptop (directly or with a microSD-to-SD/USB adapter), open [Raspberry Pi Imager](https://www.raspberrypi.com/software/), choose `Raspberry Pi OS (64-bit) (Recommended)`, and write it to the card. Then insert that card into the Pi and boot it.
2. On first boot on the Pi, create your username/password and connect to Wi-Fi (or Ethernet).
3. Enable SSH on the Pi (Preferences -> Control Center -> Interfaces -> SSH -> Enable).
4. Continue with [First-Time Setup](#first-time-setup) and use `user@ip` in the setup command. Get the IP on the Pi with `hostname -I` (use the first value), for example: `alex@192.168.1.42`.

## Command Cheat Sheet

Use these for checks and troubleshooting after setup.

```bash
# Run full post-deploy healthcheck
ssh <pi-user>@<pi-host-or-ip> 'cd ~/spainify && ./scripts/healthcheck.sh'

# Check service status quickly
ssh <pi-user>@<pi-host-or-ip> 'for s in media-actions-api display-controller weather-dashboard sonos-http-api sonify-ui; do printf "%-20s active=%-8s enabled=%s\n" "$s" "$(systemctl is-active "$s".service)" "$(systemctl is-enabled "$s".service)"; done'

# Restart one service
ssh <pi-user>@<pi-host-or-ip> 'sudo systemctl restart display-controller.service'

# Restart all core services
ssh <pi-user>@<pi-host-or-ip> 'sudo systemctl restart media-actions-api.service display-controller.service weather-dashboard.service sonos-http-api.service sonify-ui.service'

# Tail logs for a specific service
ssh <pi-user>@<pi-host-or-ip> 'journalctl -u media-actions-api.service -f -n 100'

# API smoke checks from Pi
ssh <pi-user>@<pi-host-or-ip> 'curl -sS http://127.0.0.1:3030/health; echo'
ssh <pi-user>@<pi-host-or-ip> 'curl -sS -o /dev/null -w "%{http_code}\n" -X OPTIONS http://127.0.0.1:3030/media-actions-smart'
```

---

## Recognition

Huge shoutout to the authors of [Nowify](https://github.com/jonashcroft/Nowify) and [node-sonos-http-api](https://github.com/jishi/node-sonos-http-api) from which I drew inspiration, built upon, and utilized features of.
