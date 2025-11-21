#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> spainify initial setup"

echo
echo "==> Ensuring app .env files exist"

ensure_env() {
  local dir="$1"
  local example="$2"
  local target="$3"

  if [[ -f "$dir/$target" ]]; then
    echo "  [OK] $dir/$target already exists"
  elif [[ -f "$dir/$example" ]]; then
    echo "  [NEW] Creating $dir/$target from $example (edit this file with your real values)"
    cp "$dir/$example" "$dir/$target"
  else
    echo "  [WARN] No $example found in $dir; skipping"
  fi
}

# Spotify “add current track” microservice
ensure_env "$ROOT_DIR/apps/add-current" ".env.example" ".env"

# Weather dashboard (OpenWeather key & city)
ensure_env "$ROOT_DIR/apps/weather-dashboard" ".env.example" ".env"

echo
echo "==> Running first deploy (installs deps, builds frontend, updates systemd)"
"$ROOT_DIR/scripts/redeploy.sh"

echo
cat <<'EOM'
------------------------------------------------------------------------------
Manual steps you still need to do:

1) Edit these env files and put in your real values:
   - apps/add-current/.env
       SPOTIFY_CLIENT_ID
       SPOTIFY_CLIENT_SECRET
       SPOTIFY_REFRESH_TOKEN
       SPOTIFY_PLAYLIST_ID (optional but recommended)
       SONOS_HTTP_BASE (usually http://127.0.0.1:5005)

   - apps/weather-dashboard/.env
       REACT_APP_OPENWEATHER_API_KEY
       REACT_APP_CITY_NAME

2) If you don't have a SPOTIFY_REFRESH_TOKEN yet:

   cd apps/add-current
   node auth.js

   Then in a browser go to:
     http://<PI_IP>:8888/login

   Approve the app, copy the refresh token shown,
   and paste it into SPOTIFY_REFRESH_TOKEN in apps/add-current/.env

   Press Ctrl+C in the terminal to stop auth.js when you're done.

Services are enabled via systemd and should be running after this script.
For future code changes you only need:
   ./scripts/redeploy.sh
------------------------------------------------------------------------------
EOM

