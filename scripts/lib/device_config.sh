#!/usr/bin/env bash

# Shared helpers for setup/redeploy scripts.

SPAINIFY_SERVICE_KEYS=(
  ENABLE_MEDIA_ACTIONS_API
  ENABLE_DISPLAY_CONTROLLER
  ENABLE_WEATHER_DASHBOARD
  ENABLE_SONOS_HTTP_API
  ENABLE_SONIFY_UI
)

spainify_service_unit() {
  case "$1" in
    ENABLE_MEDIA_ACTIONS_API) echo "media-actions-api.service" ;;
    ENABLE_DISPLAY_CONTROLLER) echo "display-controller.service" ;;
    ENABLE_WEATHER_DASHBOARD) echo "weather-dashboard.service" ;;
    ENABLE_SONOS_HTTP_API) echo "sonos-http-api.service" ;;
    ENABLE_SONIFY_UI) echo "sonify-ui.service" ;;
    *) return 1 ;;
  esac
}

spainify_service_prompt() {
  case "$1" in
    ENABLE_MEDIA_ACTIONS_API) echo "Enable media-actions-api (playlist + track-details + grouping API)" ;;
    ENABLE_DISPLAY_CONTROLLER) echo "Enable display controller (display-controller)" ;;
    ENABLE_WEATHER_DASHBOARD) echo "Enable weather dashboard" ;;
    ENABLE_SONOS_HTTP_API) echo "Enable Sonos API service" ;;
    ENABLE_SONIFY_UI) echo "Enable now-playing web UI (sonify-ui)" ;;
    *) return 1 ;;
  esac
}

spainify_service_default() {
  case "$1" in
    ENABLE_MEDIA_ACTIONS_API) echo "0" ;;
    ENABLE_DISPLAY_CONTROLLER) echo "1" ;;
    ENABLE_WEATHER_DASHBOARD) echo "0" ;;
    ENABLE_SONOS_HTTP_API) echo "1" ;;
    ENABLE_SONIFY_UI) echo "1" ;;
    *) return 1 ;;
  esac
}

spainify_to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

spainify_trim() {
  local value="${1:-}"
  # Strip carriage returns and trim leading/trailing whitespace.
  value="${value//$'\r'/}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

spainify_normalize_bool() {
  local raw
  local default_raw
  local lowered

  raw="$(spainify_trim "${1:-}")"
  default_raw="$(spainify_trim "${2:-0}")"

  lowered="$(spainify_to_lower "$raw")"
  case "$lowered" in
    1|true|yes|on|y) echo "1" ;;
    0|false|no|off|n) echo "0" ;;
    *)
      lowered="$(spainify_to_lower "$default_raw")"
      case "$lowered" in
        1|true|yes|on|y) echo "1" ;;
        *) echo "0" ;;
      esac
      ;;
  esac
}

spainify_read_env_value() {
  local file="$1"
  local key="$2"
  local line
  local value

  if [[ ! -f "$file" ]]; then
    return 1
  fi

  line="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -n 1 || true)"
  if [[ -z "$line" ]]; then
    return 1
  fi

  value="${line#*=}"
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value#\"}"
    value="${value%\"}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value#\'}"
    value="${value%\'}"
  fi

  printf '%s' "$value"
}

spainify_apply_service_dependencies() {
  local messages=()

  if [[ "${ENABLE_DISPLAY_CONTROLLER:-0}" == "1" && "${ENABLE_SONIFY_UI:-0}" != "1" ]]; then
    ENABLE_SONIFY_UI="1"
    messages+=("Enabled sonify-ui because display-controller is enabled.")
  fi

  if [[ "${ENABLE_DISPLAY_CONTROLLER:-0}" == "1" && "${ENABLE_SONOS_HTTP_API:-0}" != "1" ]]; then
    ENABLE_SONOS_HTTP_API="1"
    messages+=("Enabled sonos-http-api because display-controller is enabled.")
  fi

  if [[ "${ENABLE_SONIFY_UI:-0}" == "1" && "${ENABLE_SONOS_HTTP_API:-0}" != "1" ]]; then
    ENABLE_SONOS_HTTP_API="1"
    messages+=("Enabled sonos-http-api because sonify-ui is enabled.")
  fi

  if (( ${#messages[@]} > 0 )); then
    printf '%s\n' "${messages[@]}"
  fi
}

spainify_parse_rooms_from_zones_json() {
  local json_path="$1"
  python3 - "$json_path" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        zones = json.load(f)
except Exception:
    sys.exit(1)

rooms = set()
if isinstance(zones, list):
    for zone in zones:
        if not isinstance(zone, dict):
            continue
        members = zone.get("members")
        if not isinstance(members, list):
            continue
        for member in members:
            if isinstance(member, dict):
                name = member.get("roomName")
                if isinstance(name, str) and name.strip():
                    rooms.add(name.strip())

for room in sorted(rooms):
    print(room)
PY
}
