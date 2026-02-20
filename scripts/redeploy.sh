#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
SPAINIFY_USER="${SUDO_USER:-${USER:-$(id -un)}}"
DEVICE_CONFIG_FILE="$ROOT_DIR/.spainify-device.env"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/device_config.sh"

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

set_service_flags_from_config() {
  local mode="$1"
  local key

  if [[ "$mode" == "legacy-full" ]]; then
    for key in "${SPAINIFY_SERVICE_KEYS[@]}"; do
      eval "$key=1"
    done
    return
  fi

  for key in "${SPAINIFY_SERVICE_KEYS[@]}"; do
    eval "$key=$(spainify_normalize_bool \"${!key:-}\" \"$(spainify_service_default "$key")\")"
  done
}

service_enabled() {
  local key="$1"
  [[ "${!key:-0}" == "1" ]]
}

reconcile_service() {
  local key="$1"
  local unit
  unit="$(spainify_service_unit "$key")"

  if service_enabled "$key"; then
    echo "----> enabling + restarting $unit"
    sudo systemctl enable "$unit"
    sudo systemctl restart "$unit"
  else
    echo "----> stopping + disabling $unit"
    sudo systemctl stop "$unit" || true
    sudo systemctl disable "$unit" || true
  fi
}

MODE="legacy-full"
if [[ -f "$DEVICE_CONFIG_FILE" ]]; then
  MODE="config-driven"
  # shellcheck disable=SC1090
  source "$DEVICE_CONFIG_FILE"
fi

set_service_flags_from_config "$MODE"

dependency_notes_file="$(mktemp)"
spainify_apply_service_dependencies >"$dependency_notes_file" || true
dependency_notes="$(cat "$dependency_notes_file")"
rm -f "$dependency_notes_file"

if [[ "$MODE" == "legacy-full" ]]; then
  echo "==> No .spainify-device.env found; using legacy full redeploy mode"
else
  echo "==> Using device config: $DEVICE_CONFIG_FILE"
fi

if [[ -n "$dependency_notes" ]]; then
  echo "==> Dependency adjustments:"
  while IFS= read -r note; do
    [[ -n "$note" ]] && echo "  - $note"
  done <<< "$dependency_notes"
fi

echo
echo "==> Installing Node dependencies..."
if service_enabled ENABLE_ADD_CURRENT; then
  echo "----> npm install in apps/add-current"
  (cd apps/add-current && npm install --no-audit --no-fund)
fi
if service_enabled ENABLE_WEATHER_DASHBOARD; then
  echo "----> npm install in apps/weather-dashboard"
  (cd apps/weather-dashboard && npm install --legacy-peer-deps --no-audit --no-fund)
fi
if service_enabled ENABLE_SONIFY_SERVE; then
  echo "----> npm install in apps/sonify"
  (cd apps/sonify && npm install --no-audit --no-fund)
fi
if service_enabled ENABLE_SONOS_HTTP_API; then
  echo "----> npm install in apps/sonos-http-api"
  (cd apps/sonos-http-api && npm install --no-audit --no-fund)
fi

echo
if service_enabled ENABLE_SPOTIFY_DISPLAY; then
  echo "==> Installing Python dependencies for Spotify display (backend/venv)..."
  REQ_FILE=apps/spotify-display/requirements.txt
  VENV_DIR=backend/venv

  if [[ -f "$REQ_FILE" ]]; then
    needs_new_venv=false
    if [[ ! -x "$VENV_DIR/bin/python" || ! -x "$VENV_DIR/bin/pip" ]]; then
      needs_new_venv=true
    elif ! "$VENV_DIR/bin/pip" --version >/dev/null 2>&1; then
      echo "----> existing venv pip is not runnable; recreating $VENV_DIR"
      needs_new_venv=true
    fi

    if [[ "$needs_new_venv" == true ]]; then
      rm -rf "$VENV_DIR"
      echo "----> creating venv at $VENV_DIR"
      python3 -m venv "$VENV_DIR"
    fi

    echo "----> installing requirements from $REQ_FILE"
    "$VENV_DIR/bin/pip" install --disable-pip-version-check -r "$REQ_FILE"
  else
    echo "----> no $REQ_FILE found; skipping Python deps"
  fi
else
  echo "==> Spotify display disabled; skipping Python dependency step."
fi

echo
echo "==> Building frontend assets..."
if service_enabled ENABLE_WEATHER_DASHBOARD; then
  echo "----> npm run build (weather-dashboard)"
  (cd apps/weather-dashboard && npm run build)
else
  echo "----> skipping weather-dashboard build (service disabled)"
fi

if service_enabled ENABLE_SONIFY_SERVE; then
  echo "----> npm run build (sonify)"
  (cd apps/sonify && npm run build)
else
  echo "----> skipping sonify build (service disabled)"
fi

echo
echo "==> Updating systemd unit files from repo..."
render_and_install_unit systemd/add-current.service        /etc/systemd/system/add-current.service
render_and_install_unit systemd/spotify_display.service    /etc/systemd/system/spotify_display.service
render_and_install_unit systemd/weather-dashboard.service  /etc/systemd/system/weather-dashboard.service
render_and_install_unit systemd/sonos-http-api.service     /etc/systemd/system/sonos-http-api.service
render_and_install_unit systemd/sonify-serve.service       /etc/systemd/system/sonify-serve.service

sudo systemctl daemon-reload

echo
echo "==> Reconciling service state"
reconcile_service ENABLE_ADD_CURRENT
reconcile_service ENABLE_SPOTIFY_DISPLAY
reconcile_service ENABLE_WEATHER_DASHBOARD
reconcile_service ENABLE_SONOS_HTTP_API
reconcile_service ENABLE_SONIFY_SERVE

echo
echo "All done."
