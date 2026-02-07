#!/usr/bin/env bash
set -euo pipefail

# Always run from repo root
cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
SPAINIFY_USER="${SUDO_USER:-${USER:-$(id -un)}}"

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'
}

render_and_install_unit() {
  local src="$1"
  local dst="$2"
  local escaped_root
  local escaped_user
  escaped_root="$(escape_sed_replacement "$ROOT_DIR")"
  escaped_user="$(escape_sed_replacement "$SPAINIFY_USER")"

  local tmp
  tmp="$(mktemp)"
  sed \
    -e "s|__SPAINIFY_ROOT__|$escaped_root|g" \
    -e "s|__SPAINIFY_USER__|$escaped_user|g" \
    "$src" > "$tmp"
  sudo install -m 0644 "$tmp" "$dst"
  rm -f "$tmp"
}

echo "==> Installing Node dependencies..."
for dir in \
  apps/add-current \
  apps/weather-dashboard \
  apps/sonify \
  apps/sonos-http-api
do
  if [ -f "$dir/package.json" ]; then
    echo "----> npm install in $dir"
    case "$(basename "$dir")" in
      weather-dashboard)
        (cd "$dir" && npm install --legacy-peer-deps --no-audit --no-fund)
        ;;
      *)
        (cd "$dir" && npm install --no-audit --no-fund)
        ;;
    esac
  else
    echo "----> skipping $dir (no package.json)"
  fi
done

echo
echo "==> Installing Python dependencies for Spotify display (backend/venv)..."
REQ_FILE=apps/spotify-display/requirements.txt
VENV_DIR=backend/venv

if [ -f "$REQ_FILE" ]; then
  needs_new_venv=false
  if [ ! -x "$VENV_DIR/bin/python" ] || [ ! -x "$VENV_DIR/bin/pip" ]; then
    needs_new_venv=true
  elif ! "$VENV_DIR/bin/pip" --version >/dev/null 2>&1; then
    echo "----> existing venv pip is not runnable; recreating $VENV_DIR"
    needs_new_venv=true
  fi

  if [ "$needs_new_venv" = true ]; then
    rm -rf "$VENV_DIR"
    echo "----> creating venv at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi
  echo "----> installing requirements from $REQ_FILE"
  "$VENV_DIR/bin/pip" install --disable-pip-version-check -r "$REQ_FILE"
else
  echo "----> no $REQ_FILE found; skipping Python deps"
fi

echo
echo "==> Building frontend assets..."

if [ -d apps/weather-dashboard ] && [ -f apps/weather-dashboard/package.json ]; then
  echo "----> npm run build (weather-dashboard)"
  (cd apps/weather-dashboard && npm run build)
else
  echo "----> skipping weather-dashboard (missing dir or package.json)"
fi

if [ -d apps/sonify ] && [ -f apps/sonify/package.json ]; then
  echo "----> npm run build (sonify)"
  (cd apps/sonify && npm run build)
else
  echo "----> skipping sonify (missing dir or package.json)"
fi

echo
echo "==> Updating systemd unit files from repo and restarting services..."
render_and_install_unit systemd/add-current.service        /etc/systemd/system/add-current.service
render_and_install_unit systemd/spotify_display.service    /etc/systemd/system/spotify_display.service
render_and_install_unit systemd/weather-dashboard.service  /etc/systemd/system/weather-dashboard.service
render_and_install_unit systemd/sonos-http-api.service     /etc/systemd/system/sonos-http-api.service
render_and_install_unit systemd/sonify-serve.service       /etc/systemd/system/sonify-serve.service

sudo systemctl daemon-reload

sudo systemctl restart \
  add-current.service \
  spotify_display.service \
  weather-dashboard.service \
  sonos-http-api.service \
  sonify-serve.service

echo
echo "All done."
