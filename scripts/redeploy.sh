#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
SPAINIFY_USER="${SUDO_USER:-${USER:-$(id -un)}}"
DEVICE_CONFIG_FILE="$ROOT_DIR/.spainify-device.env"
REDEPLOY_ONLY_RAW=""

usage() {
  cat <<'EOF'
Usage:
  ./scripts/redeploy.sh [--only <comma-separated-service-keys>]

Options:
  --only <keys>   Redeploy only selected service keys (for example:
                  ENABLE_WEATHER_DASHBOARD,ENABLE_DISPLAY_CONTROLLER)
  -h, --help      Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      REDEPLOY_ONLY_RAW="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

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

ensure_sonos_http_api_layout() {
  local api_dir="$ROOT_DIR/apps/sonos-http-api"
  local presets_dir="$api_dir/presets"
  local settings_file="$api_dir/settings.json"

  mkdir -p "$presets_dir"
  if [[ ! -f "$settings_file" ]]; then
    printf '{}\n' > "$settings_file"
  fi
}

run_quiet_build() {
  local label="$1"
  local dir="$2"
  local log_file

  log_file="$(mktemp -t "spainify-build-${label}.XXXXXX.log")"
  echo "----> npm run build ($label)"

  if (
    cd "$dir" && \
    BROWSERSLIST_IGNORE_OLD_DATA=1 \
    SASS_SILENCE_DEPRECATIONS=legacy-js-api,import \
    npm run build
  ) >"$log_file" 2>&1; then
    rm -f "$log_file"
    echo "----> $label build complete"
    return 0
  fi

  echo "----> $label build failed. Full log: $log_file"
  echo "----> Last 120 lines:"
  tail -n 120 "$log_file" || true
  return 1
}

set_service_flags_from_config() {
  local mode="$1"
  local key
  local normalized

  if [[ "$mode" == "legacy-full" ]]; then
    for key in "${SPAINIFY_SERVICE_KEYS[@]}"; do
      eval "$key=1"
    done
    return
  fi

  for key in "${SPAINIFY_SERVICE_KEYS[@]}"; do
    normalized="$(spainify_normalize_bool "${!key:-}" "$(spainify_service_default "$key")")"
    printf -v "$key" '%s' "$normalized"
  done
}

service_enabled() {
  local key="$1"
  [[ "${!key:-0}" == "1" ]]
}

declare -A REDEPLOY_SCOPE_MAP=()
if [[ -n "$REDEPLOY_ONLY_RAW" ]]; then
  IFS=',' read -r -a requested_scope_keys <<< "$REDEPLOY_ONLY_RAW"
  for key in "${requested_scope_keys[@]}"; do
    key="$(spainify_trim "$key")"
    [[ -z "$key" ]] && continue
    case "$key" in
      ENABLE_MEDIA_ACTIONS_API|ENABLE_DISPLAY_CONTROLLER|ENABLE_WEATHER_DASHBOARD|ENABLE_SONOS_HTTP_API|ENABLE_SONIFY_UI)
        REDEPLOY_SCOPE_MAP["$key"]="1"
        ;;
      *)
        echo "Invalid --only service key: $key"
        echo "Valid keys: ${SPAINIFY_SERVICE_KEYS[*]}"
        exit 1
        ;;
    esac
  done
  if (( ${#REDEPLOY_SCOPE_MAP[@]} == 0 )); then
    echo "--only was provided but no valid service keys were found."
    exit 1
  fi
fi

scope_includes() {
  local key="$1"
  if (( ${#REDEPLOY_SCOPE_MAP[@]} == 0 )); then
    return 0
  fi
  [[ -n "${REDEPLOY_SCOPE_MAP[$key]+x}" ]]
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

if (( ${#REDEPLOY_SCOPE_MAP[@]} > 0 )); then
  echo "==> Scoped redeploy requested: ${!REDEPLOY_SCOPE_MAP[*]}"
fi

if [[ -n "$dependency_notes" ]]; then
  echo "==> Dependency adjustments:"
  while IFS= read -r note; do
    [[ -n "$note" ]] && echo "  - $note"
  done <<< "$dependency_notes"
fi

echo
echo "==> Installing Node dependencies..."
if scope_includes ENABLE_MEDIA_ACTIONS_API && service_enabled ENABLE_MEDIA_ACTIONS_API; then
  echo "----> npm ci in apps/media-actions-api (media-actions-api)"
  (cd apps/media-actions-api && npm ci --no-audit --no-fund --loglevel=error)
fi
if scope_includes ENABLE_WEATHER_DASHBOARD && service_enabled ENABLE_WEATHER_DASHBOARD; then
  echo "----> npm ci in apps/weather-dashboard"
  (cd apps/weather-dashboard && npm ci --legacy-peer-deps --no-audit --no-fund --loglevel=error)
fi
if scope_includes ENABLE_SONIFY_UI && service_enabled ENABLE_SONIFY_UI; then
  echo "----> npm ci in apps/sonify-ui"
  (cd apps/sonify-ui && npm ci --no-audit --no-fund --loglevel=error)
fi
if scope_includes ENABLE_SONOS_HTTP_API && service_enabled ENABLE_SONOS_HTTP_API; then
  ensure_sonos_http_api_layout
  echo "----> npm ci in apps/sonos-http-api"
  (cd apps/sonos-http-api && npm ci --no-audit --no-fund --loglevel=error)
fi

echo
if scope_includes ENABLE_DISPLAY_CONTROLLER && service_enabled ENABLE_DISPLAY_CONTROLLER; then
  echo "==> Installing Python dependencies for display-controller (backend/venv)..."
  REQ_FILE=apps/display-controller/requirements.txt
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
  echo "==> display-controller not in redeploy scope or disabled; skipping Python dependency step."
fi

echo
echo "==> Building frontend assets..."
if scope_includes ENABLE_WEATHER_DASHBOARD && service_enabled ENABLE_WEATHER_DASHBOARD; then
  run_quiet_build "weather-dashboard" "apps/weather-dashboard"
else
  echo "----> skipping weather-dashboard build (not in scope or service disabled)"
fi

if scope_includes ENABLE_SONIFY_UI && service_enabled ENABLE_SONIFY_UI; then
  run_quiet_build "sonify" "apps/sonify-ui"
else
  echo "----> skipping sonify build (not in scope or service disabled)"
fi

echo
echo "==> Updating systemd unit files from repo..."
render_and_install_unit systemd/media-actions-api.service  /etc/systemd/system/media-actions-api.service
render_and_install_unit systemd/display-controller.service /etc/systemd/system/display-controller.service
render_and_install_unit systemd/weather-dashboard.service  /etc/systemd/system/weather-dashboard.service
render_and_install_unit systemd/sonos-http-api.service     /etc/systemd/system/sonos-http-api.service
render_and_install_unit systemd/sonify-ui.service          /etc/systemd/system/sonify-ui.service

sudo systemctl daemon-reload

echo
echo "==> Reconciling service state"
for key in "${SPAINIFY_SERVICE_KEYS[@]}"; do
  if scope_includes "$key"; then
    reconcile_service "$key"
  else
    echo "----> leaving $(spainify_service_unit "$key") unchanged (out of scope)"
  fi
done

echo
echo "All done."
