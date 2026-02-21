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
   - Setup then guides location input with three modes:
     - US mode: enter city + 2-letter state code (saved as `City,ST,US`)
     - International mode: enter city + 2-letter country code (saved as `City,CC`)
     - Advanced mode: enter a raw OpenWeather location query

2. Spotify (media-actions-api)
   - Create/sign in to Spotify Developer and open the dashboard: https://developer.spotify.com/dashboard
   - Create an app and add both redirect URIs:
     - `http://127.0.0.1:8888/callback`
     - `http://<pi-ip-address>:8888/callback`
   - Copy `Client ID` and `Client Secret` into setup prompts.

Optional: run setup directly on the Pi (for local desktop use):

```bash
cd ~/spainify
./setup.sh
```

`setup.sh` is the core setup wizard used by `setup-remote.sh`.

To change service choices later, just re-run setup:

```bash
./scripts/setup-remote.sh <pi-user>@<pi-ip>
```

---

## Apps and Services

- `media-actions-api.service` — playlist add + metadata + Sonos grouping API
- `display-controller.service` — Python display controller (power, browser, mode switching)
- `sonify-ui.service` — now-playing web UI host
- `sonos-http-api.service` — Sonos HTTP API backend (includes local `/album-art` proxy)
- `weather-dashboard.service` — weather web UI host
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
ssh <pi-user>@<pi-ip> 'cd ~/spainify && git pull --ff-only && ./scripts/redeploy.sh'
```

Use setup when you need to change service enablement, room selection, or other setup-driven config:

```bash
cd /path/to/spainify
./scripts/setup-remote.sh <pi-user>@<pi-ip>
```

When the remote repo has local changes during setup, choose:
- default interactive prompt (`auto-stash`, `discard`, `cancel`)
- `--auto-stash` for non-interactive stash-before-pull
- `--discard-local` for non-interactive discard-before-pull

For multi-Pi setups, run these commands on each Pi.

## Command Cheat Sheet

Use these for checks and troubleshooting after setup.

```bash
# Run full post-deploy healthcheck
ssh <pi-user>@<pi-ip> 'cd ~/spainify && ./scripts/healthcheck.sh'

# Check service status quickly
ssh <pi-user>@<pi-ip> 'for s in media-actions-api display-controller weather-dashboard sonos-http-api sonify-ui; do printf "%-20s active=%-8s enabled=%s\n" "$s" "$(systemctl is-active "$s".service)" "$(systemctl is-enabled "$s".service)"; done'

# Restart one service
ssh <pi-user>@<pi-ip> 'sudo systemctl restart display-controller.service'

# Restart all core services
ssh <pi-user>@<pi-ip> 'sudo systemctl restart media-actions-api.service display-controller.service weather-dashboard.service sonos-http-api.service sonify-ui.service'

# Tail logs for a specific service
ssh <pi-user>@<pi-ip> 'journalctl -u media-actions-api.service -f -n 100'

# API smoke checks from Pi
ssh <pi-user>@<pi-ip> 'curl -sS http://127.0.0.1:3030/health; echo'
ssh <pi-user>@<pi-ip> 'curl -sS http://127.0.0.1:3030/media-actions-smart; echo'
```

---

## Recognition

Huge shoutout to the authors of [Nowify](https://github.com/jonashcroft/Nowify) and [node-sonos-http-api](https://github.com/jishi/node-sonos-http-api) from which I drew inspiration, built upon, and utilized features of.
