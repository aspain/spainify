# Project Features

This repository contains a consolidated set of locally hosted apps and services with the following features:
- Display Sonos and Spotify now-playing details (artist, track title, and album artwork)
    - This will work regardless of whether playback is initiated from either the Spotify or Sonos app
    - If you have multiple Sonos rooms set up, a specific room can be chosen for the now-playing details
    - The display has a dynamic background color based on a randomly sampled pixel from the album artwork
    - The font color will switch between black and white depending on brightness level of the background to enhance readability
- Display a custom local weather forecast display during specific hours of the day (currently set to display from 7am-9am)
    - If music playback is initiated during the weather display hours, the music now-playing display will take precedence
- Provide an API endpoint to add the currently-playing song to a specified Spotify playlist, which will skip the addition if the song is already present in the playlist
- Enable one-click iOS shortcuts to control all aspects of your Sonos system including presets for bundled actions (such as grouping rooms, setting volume, turn on shuffle, start playing a specified playlist all with one button)
- If nothing is playing in the specified Sonos room(s) and the current time is outside of the designated weather dashboard display hours, the screen will otherwise go to sleep and will be automatically woken up when music playback starts again in the specified room(s)

**Recognition:**
Huge shoutout to the authors of [Nowify](https://github.com/jonashcroft/Nowify) and [node-sonos-http-api](https://github.com/jishi/node-sonos-http-api) from which I drew inspiration, built upon, and utilized features of.

**Now-playing example:**
![now playing](assets/images/now_playing.png)


**Weather dashboard example:**
![weather dashboard](assets/images/weather.png)


**Apps/services included:**

* **Sonos HTTP API** (`apps/sonos-http-api`) - This is an unmodified fork of [node-sonos-http-api](https://github.com/jishi/node-sonos-http-api)
* **Add Current Track to Spotify microservice** (`apps/add-current`)
* **Spotify Display Controller** (`apps/spotify-display`)
* **Weather Dashboard (React)** (`apps/weather-dashboard`)
* **Sonify UI (Vue)** (`apps/sonify`) This is a modified fork of [Nowify](https://github.com/jonashcroft/Nowify)
* **Systemd service definitions** (`systemd/`)
* **Deployment script** (`scripts/redeploy.sh`)

The goal: make updates easy — pull changes, run one command, everything redeploys.

---

## Hardware Requirements

* Raspberry Pi - I used a [Raspberry Pi 4](https://www.amazon.com/dp/B07TC2BK1X?th=1) and a separate [power adapter](https://www.amazon.com/dp/B07VFDYNL4)
* LCD Screen - I used a [7.9" Waveshare](https://www.waveshare.com/7.9inch-hdmi-lcd.htm)

---

## Project Structure

```text
apps/
  add-current/
  sonos-http-api/
  spotify-display/
  weather-dashboard/
  sonify/
scripts/
  redeploy.sh
systemd/
setup.sh
```

---

## Environment Variables

Each app that needs secrets uses a local `.env` file which is **not** committed to git.

### `apps/add-current/.env`

Used by the "add current track to Spotify" microservice.

Template: `apps/add-current/.env.example`

```ini
SPOTIFY_CLIENT_ID=your_spotify_client_id
SPOTIFY_CLIENT_SECRET=your_spotify_client_secret
SPOTIFY_REFRESH_TOKEN=your_refresh_token
SPOTIFY_PLAYLIST_ID=your_playlist_id

# Sonos HTTP API base (usually localhost:5005)
SONOS_HTTP_BASE=http://127.0.0.1:5005

# Optional: preferred Sonos room if multiple zones are playing
PREFERRED_ROOM=

# Service port
PORT=3030

# How many of the most recently added songs will be checked for duplicates
DE_DUPE_WINDOW=750
```

---

### `apps/weather-dashboard/.env`

Used by the React weather dashboard.

Template: `apps/weather-dashboard/.env.example`

```ini
REACT_APP_OPENWEATHER_API_KEY=your_openweather_api_key
REACT_APP_CITY=YourCityName
```

### `apps/spotify-display`

Used by the Raspberry Pi process that switches between the Sonify and weather displays.

Template: `apps/spotify-display/.env.example`

```ini
# Optional: override the Sonos room to monitor for playback
SONOS_ROOM=Living Room
```

### `apps/sonify`

* No Spotify credentials required in this fork.
* Any existing `.env.sample` is only informational and not required.
* Optional: set `VITE_SONOS_ROOM` in `apps/sonify/.env.local` to pick the Sonos room to display (defaults to "Living Room").

---

## First-Time Setup

From your Pi:

```bash
git clone https://github.com/aspain/spainify.git
cd spainify
```

### 1. Create `.env` files

```bash
cp apps/add-current/.env.example apps/add-current/.env
cp apps/weather-dashboard/.env.example apps/weather-dashboard/.env

nano apps/add-current/.env
nano apps/weather-dashboard/.env
```

Fill in:

* Spotify client ID/secret/playlist ID and refresh token
* OpenWeather API key
* City name

### 2. One-time Spotify auth (to get the refresh token)

```bash
cd apps/add-current
node auth.js
```

Then in a browser:

1. Open `http://<pi-ip>:8888/login`
2. Approve the Spotify permissions
3. Copy the `refresh_token` shown
4. Paste it into `apps/add-current/.env` as `SPOTIFY_REFRESH_TOKEN`
5. Stop the auth server with `Ctrl+C`

You only need to do this once per Spotify app/client.

### 3. Install and enable systemd services (first time)

From the repo root:

```bash
cd ~/spainify
./setup.sh
```

What `setup.sh` does:

1. Ensures `.env` files exist for `add-current` and `weather-dashboard`
2. Copies `systemd/*.service` into `/etc/systemd/system/`
3. Runs `systemctl daemon-reload`
4. Enables all the Sonos display services
5. Runs `./scripts/redeploy.sh`
6. Restarts all relevant services

After this, services should come up automatically on boot.

---

## Redeploy / Update Workflow

For future updates you normally only need:

```bash
cd ~/spainify
git pull
./scripts/redeploy.sh
```

The `redeploy.sh` script:

* Installs Node dependencies for all apps under `apps/`
* Builds React (weather-dashboard) and Vue (sonify) frontends
* Creates/updates the Python virtualenv at `backend/venv`
* Installs `apps/spotify-display/requirements.txt` into that venv
* Syncs systemd unit files from `systemd/` to `/etc/systemd/system/`
* Reloads and restarts the services

If you change only frontend code or Python logic, re-running `./scripts/redeploy.sh` is usually enough.

---

## Systemd Services

Relevant units (installed into `/etc/systemd/system`):

* `add-current.service` — Spotify playlist microservice
* `sonos-http-api.service` — Sonos HTTP API backend
* `sonify-serve.service` — Vue UI (Now Playing)
* `spotify_display.service` — Python controller & Chromium display
* `weather-dashboard.service` — Weather React app

Common commands:

```bash
# Check status
systemctl status add-current.service

# Restart one service
sudo systemctl restart spotify_display.service

# Restart everything
sudo systemctl restart \
  add-current.service \
  sonos-http-api.service \
  sonify-serve.service \
  spotify_display.service \
  weather-dashboard.service
```

---

## Development Notes

You can also run pieces manually for debugging.

```bash
# Add-current microservice
cd apps/add-current
npm start

# Sonos HTTP API
cd apps/sonos-http-api
npm start

# Weather dashboard (dev mode)
cd apps/weather-dashboard
npm start

# Sonify UI (dev mode)
cd apps/sonify
npm run serve

# Spotify display controller (standalone)
cd apps/spotify-display
python3 spotify_display_control.py
```

When running in dev mode, remember systemd services may already be bound to the same ports. Stop them first if needed:

```bash
sudo systemctl stop add-current.service sonify-serve.service weather-dashboard.service
```

---

## Updating Secrets Safely

* All `.env` files are ignored by git via the root `.gitignore`.
* Never commit actual client IDs, secrets, or tokens.
* If you rotate keys, just update your local `.env` files and re-run:

```bash
./scripts/redeploy.sh
```

That will pick up changes and restart the services.

