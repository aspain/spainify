#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_CONFIG_FILE="$ROOT_DIR/.spainify-device.env"
DISCOVERY_SONOS_API_PID=""

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/device_config.sh"

cleanup_setup_helpers() {
  if [[ -n "$DISCOVERY_SONOS_API_PID" ]] && kill -0 "$DISCOVERY_SONOS_API_PID" >/dev/null 2>&1; then
    kill "$DISCOVERY_SONOS_API_PID" >/dev/null 2>&1 || true
    wait "$DISCOVERY_SONOS_API_PID" 2>/dev/null || true
    DISCOVERY_SONOS_API_PID=""
  fi
}
trap cleanup_setup_helpers EXIT INT TERM

prompt_yes_no() {
  local question="$1"
  local default_raw="$2"
  local default
  local hint
  local answer

  default="$(spainify_normalize_bool "$default_raw" "0")"
  if [[ "$default" == "1" ]]; then
    hint="Y/n"
  else
    hint="y/N"
  fi

  read -r -p "$question: [$hint] " answer || true
  if [[ -z "$answer" ]]; then
    answer="$default"
  fi
  spainify_normalize_bool "$answer" "$default"
}

prompt_text() {
  local question="$1"
  local default_value="$2"
  local answer

  if [[ -n "$default_value" ]]; then
    read -r -p "$question: [$default_value] " answer || true
  else
    read -r -p "$question: " answer || true
  fi

  if [[ -z "$answer" ]]; then
    answer="$default_value"
  fi
  printf '%s' "$answer"
}

prompt_required_text() {
  local question="$1"
  local default_value="$2"
  local value

  while true; do
    value="$(prompt_text "$question" "$default_value")"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return
    fi
    echo "Value is required."
  done
}

escape_double_quotes() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\$}"
  value="${value//\`/\\\`}"
  printf '%s' "$value"
}

read_existing_or_default() {
  local file="$1"
  local key="$2"
  local fallback="$3"
  local value

  value="$(spainify_read_env_value "$file" "$key" 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    value="$fallback"
  fi
  printf '%s' "$value"
}

sanitize_room_default() {
  local value
  value="$(spainify_trim "${1:-}")"

  # Drop wrapping quotes if present.
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value#\"}"
    value="${value%\"}"
  fi
  if [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value#\'}"
    value="${value%\'}"
  fi

  # Guard against broken prior values such as a standalone quote.
  if [[ -z "$value" || "$value" == '"' || "$value" == "'" ]]; then
    value="Living Room"
  fi
  printf '%s' "$value"
}

load_available_sonos_rooms() {
  local sonos_base="$1"
  local tmp_json

  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi

  tmp_json="$(mktemp)"
  if ! curl -fsS --max-time 3 "$sonos_base/zones" >"$tmp_json" 2>/dev/null; then
    rm -f "$tmp_json"
    return 1
  fi

  while IFS= read -r room; do
    if [[ -n "$room" ]]; then
      SONOS_ROOMS+=("$room")
    fi
  done < <(spainify_parse_rooms_from_zones_json "$tmp_json" 2>/dev/null || true)

  rm -f "$tmp_json"
  (( ${#SONOS_ROOMS[@]} > 0 ))
}

boot_temp_sonos_http_api() {
  local sonos_base="$1"
  local api_dir="$ROOT_DIR/apps/sonos-http-api"
  local wait_seconds=30
  local i

  case "$sonos_base" in
    http://127.0.0.1:5005|http://localhost:5005) ;;
    *) return 1 ;;
  esac

  if ! command -v node >/dev/null 2>&1; then
    return 1
  fi

  if [[ ! -f "$api_dir/server.js" || ! -f "$api_dir/package.json" ]]; then
    return 1
  fi

  if ! curl -fsS --max-time 2 "$sonos_base/zones" >/dev/null 2>&1; then
    echo >&2
    echo "Starting local Sonos API temporarily so room discovery can run..." >&2
  else
    return 0
  fi

  if [[ ! -d "$api_dir/node_modules" ]]; then
    echo "Installing Sonos API dependencies for room discovery..." >&2
    (cd "$api_dir" && npm install --no-audit --no-fund >/dev/null)
  fi

  (cd "$api_dir" && node server.js >/tmp/spainify-setup-sonos-http-api.log 2>&1) &
  DISCOVERY_SONOS_API_PID="$!"

  for ((i=0; i<wait_seconds; i++)); do
    if curl -fsS --max-time 2 "$sonos_base/zones" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  return 1
}

prompt_sonos_room() {
  local default_room="$1"
  local sonos_base="$2"
  local i
  local prompt_default=""
  local selected
  local choice
  SONOS_ROOMS=()

  if load_available_sonos_rooms "$sonos_base"; then
    echo >&2
    echo "Discovered Sonos rooms from $sonos_base:" >&2
    i=1
    while (( i <= ${#SONOS_ROOMS[@]} )); do
      echo "  $i) ${SONOS_ROOMS[$((i - 1))]}" >&2
      if [[ "${SONOS_ROOMS[$((i - 1))]}" == "$default_room" ]]; then
        prompt_default="$i"
      fi
      ((i++))
    done
    echo "  0) Enter room manually" >&2

    if [[ -n "$prompt_default" ]]; then
      read -r -p "Choose Sonos room number: [$prompt_default] " choice || true
    else
      read -r -p "Choose Sonos room number: [0] " choice || true
      choice="${choice:-0}"
    fi

    if [[ -z "$choice" && -n "$prompt_default" ]]; then
      choice="$prompt_default"
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 )) && (( choice <= ${#SONOS_ROOMS[@]} )); then
      selected="${SONOS_ROOMS[$((choice - 1))]}"
      printf '%s' "$selected"
      return
    fi
  elif boot_temp_sonos_http_api "$sonos_base" && load_available_sonos_rooms "$sonos_base"; then
    echo >&2
    echo "Discovered Sonos rooms from $sonos_base:" >&2
    i=1
    while (( i <= ${#SONOS_ROOMS[@]} )); do
      echo "  $i) ${SONOS_ROOMS[$((i - 1))]}" >&2
      if [[ "${SONOS_ROOMS[$((i - 1))]}" == "$default_room" ]]; then
        prompt_default="$i"
      fi
      ((i++))
    done
    echo "  0) Enter room manually" >&2

    if [[ -n "$prompt_default" ]]; then
      read -r -p "Choose Sonos room number: [$prompt_default] " choice || true
    else
      read -r -p "Choose Sonos room number: [0] " choice || true
      choice="${choice:-0}"
    fi

    if [[ -z "$choice" && -n "$prompt_default" ]]; then
      choice="$prompt_default"
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 )) && (( choice <= ${#SONOS_ROOMS[@]} )); then
      selected="${SONOS_ROOMS[$((choice - 1))]}"
      printf '%s' "$selected"
      return
    fi
  else
    echo >&2
    echo "Could not auto-discover Sonos rooms. Enter room name manually." >&2
  fi

  prompt_required_text "Enter Sonos room name" "$default_room"
}

write_device_config() {
  local room_value="$1"
  local metadata_base="$2"
  local escaped_room
  local escaped_metadata

  escaped_room="$(escape_double_quotes "$room_value")"
  escaped_metadata="$(escape_double_quotes "$metadata_base")"

  cat >"$DEVICE_CONFIG_FILE" <<EOF_CFG
# Generated by scripts/setup.sh
ENABLE_ADD_CURRENT=$ENABLE_ADD_CURRENT
ENABLE_SPOTIFY_DISPLAY=$ENABLE_SPOTIFY_DISPLAY
ENABLE_WEATHER_DASHBOARD=$ENABLE_WEATHER_DASHBOARD
ENABLE_SONOS_HTTP_API=$ENABLE_SONOS_HTTP_API
ENABLE_SONIFY_SERVE=$ENABLE_SONIFY_SERVE
SONOS_ROOM="$escaped_room"
SONIFY_METADATA_BASE="$escaped_metadata"
EOF_CFG
}

write_add_current_env() {
  local file="$ROOT_DIR/apps/add-current/.env"
  local client_id="$1"
  local client_secret="$2"
  local refresh_token="$3"
  local playlist_id="$4"
  local sonos_http_base="$5"
  local preferred_room="$6"
  local dedupe_window="$7"

cat >"$file" <<EOF_AC
SPOTIFY_CLIENT_ID="$(escape_double_quotes "$client_id")"
SPOTIFY_CLIENT_SECRET="$(escape_double_quotes "$client_secret")"
SPOTIFY_REFRESH_TOKEN="$(escape_double_quotes "$refresh_token")"
SPOTIFY_PLAYLIST_ID="$(escape_double_quotes "$playlist_id")"

SONOS_HTTP_BASE="$(escape_double_quotes "$sonos_http_base")"
PREFERRED_ROOM="$(escape_double_quotes "$preferred_room")"
PORT=3030
DE_DUPE_WINDOW="$(escape_double_quotes "$dedupe_window")"
EOF_AC
}

write_spotify_display_env() {
  local file="$ROOT_DIR/apps/spotify-display/.env"
  local room="$1"
  local hide_cursor="$2"
  local hide_cursor_idle_seconds="$3"

cat >"$file" <<EOF_SD
SONOS_ROOM="$(escape_double_quotes "$room")"
HIDE_CURSOR_WHILE_DISPLAYING=$hide_cursor
HIDE_CURSOR_IDLE_SECONDS="$(escape_double_quotes "$hide_cursor_idle_seconds")"
EOF_SD
}

write_weather_env() {
  local file="$ROOT_DIR/apps/weather-dashboard/.env"
  local api_key="$1"
  local city="$2"

cat >"$file" <<EOF_WEATHER
REACT_APP_OPENWEATHER_API_KEY="$(escape_double_quotes "$api_key")"
REACT_APP_CITY="$(escape_double_quotes "$city")"
EOF_WEATHER
}

write_sonify_env_local() {
  local file="$ROOT_DIR/apps/sonify/.env.local"
  local room="$1"
  local metadata_base="$2"
  local escaped_room
  escaped_room="$(escape_double_quotes "$room")"

  if [[ -n "$metadata_base" ]]; then
    cat >"$file" <<EOF_SONIFY
VUE_APP_SONOS_ROOM="$escaped_room"
VUE_APP_ADD_CURRENT_BASE="$(escape_double_quotes "$metadata_base")"
EOF_SONIFY
  else
    cat >"$file" <<EOF_SONIFY
VUE_APP_SONOS_ROOM="$escaped_room"
EOF_SONIFY
  fi
}

echo "==> spainify setup wizard"
echo "This script configures services and writes local env files for this device."

if [[ -f "$DEVICE_CONFIG_FILE" ]]; then
  echo "Found existing device config: $DEVICE_CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$DEVICE_CONFIG_FILE"
fi

for key in "${SPAINIFY_SERVICE_KEYS[@]}"; do
  current_value="${!key:-$(spainify_service_default "$key")}"
  printf -v "$key" '%s' "$(spainify_normalize_bool "$current_value" "$(spainify_service_default "$key")")"
done

echo
for key in "${SPAINIFY_SERVICE_KEYS[@]}"; do
  prompt="$(spainify_service_prompt "$key")"
  answer="$(prompt_yes_no "$prompt" "${!key}")"
  printf -v "$key" '%s' "$(spainify_normalize_bool "$answer" "${!key}")"
done

dependency_notes_file="$(mktemp)"
spainify_apply_service_dependencies >"$dependency_notes_file" || true
dependency_notes="$(cat "$dependency_notes_file")"
rm -f "$dependency_notes_file"
if [[ -n "$dependency_notes" ]]; then
  echo
  echo "Dependency adjustments:"
  while IFS= read -r note; do
    [[ -n "$note" ]] && echo "  - $note"
  done <<< "$dependency_notes"
fi

display_env_file="$ROOT_DIR/apps/spotify-display/.env"
add_current_env_file="$ROOT_DIR/apps/add-current/.env"
weather_env_file="$ROOT_DIR/apps/weather-dashboard/.env"
sonify_env_local_file="$ROOT_DIR/apps/sonify/.env.local"

default_sonos_http_base="$(read_existing_or_default "$add_current_env_file" "SONOS_HTTP_BASE" "http://127.0.0.1:5005")"
default_room="$(read_existing_or_default "$display_env_file" "SONOS_ROOM" "")"
if [[ -z "$default_room" ]]; then
  default_room="$(read_existing_or_default "$sonify_env_local_file" "VUE_APP_SONOS_ROOM" "Living Room")"
fi
default_room="$(sanitize_room_default "$default_room")"

SONOS_ROOM_VALUE="$default_room"
if [[ "$ENABLE_SPOTIFY_DISPLAY" == "1" || "$ENABLE_SONIFY_SERVE" == "1" || "$ENABLE_ADD_CURRENT" == "1" ]]; then
  SONOS_ROOM_VALUE="$(prompt_sonos_room "$default_room" "$default_sonos_http_base")"
fi
cleanup_setup_helpers

HIDE_CURSOR_WHILE_DISPLAYING_VALUE="$(read_existing_or_default "$display_env_file" "HIDE_CURSOR_WHILE_DISPLAYING" "1")"
HIDE_CURSOR_IDLE_SECONDS_VALUE="$(read_existing_or_default "$display_env_file" "HIDE_CURSOR_IDLE_SECONDS" "0.1")"
if [[ "$ENABLE_SPOTIFY_DISPLAY" == "1" ]]; then
  echo
  HIDE_CURSOR_WHILE_DISPLAYING_VALUE="$(prompt_yes_no "Hide mouse cursor while content is showing?" "$HIDE_CURSOR_WHILE_DISPLAYING_VALUE")"
fi

ADD_CURRENT_CLIENT_ID="$(read_existing_or_default "$add_current_env_file" "SPOTIFY_CLIENT_ID" "")"
ADD_CURRENT_CLIENT_SECRET="$(read_existing_or_default "$add_current_env_file" "SPOTIFY_CLIENT_SECRET" "")"
ADD_CURRENT_REFRESH_TOKEN="$(read_existing_or_default "$add_current_env_file" "SPOTIFY_REFRESH_TOKEN" "")"
ADD_CURRENT_PLAYLIST_ID="$(read_existing_or_default "$add_current_env_file" "SPOTIFY_PLAYLIST_ID" "")"
ADD_CURRENT_SONOS_HTTP_BASE="$(read_existing_or_default "$add_current_env_file" "SONOS_HTTP_BASE" "$default_sonos_http_base")"
ADD_CURRENT_PREFERRED_ROOM="$(read_existing_or_default "$add_current_env_file" "PREFERRED_ROOM" "")"
ADD_CURRENT_DEDUPE_WINDOW="$(read_existing_or_default "$add_current_env_file" "DE_DUPE_WINDOW" "750")"

if [[ "$ENABLE_ADD_CURRENT" == "1" ]]; then
  echo
  echo "Configure add-current service values:"
  ADD_CURRENT_CLIENT_ID="$(prompt_text "Spotify client ID" "$ADD_CURRENT_CLIENT_ID")"
  ADD_CURRENT_CLIENT_SECRET="$(prompt_text "Spotify client secret" "$ADD_CURRENT_CLIENT_SECRET")"
  ADD_CURRENT_REFRESH_TOKEN="$(prompt_text "Spotify refresh token" "$ADD_CURRENT_REFRESH_TOKEN")"
  ADD_CURRENT_PLAYLIST_ID="$(prompt_text "Spotify playlist ID (optional)" "$ADD_CURRENT_PLAYLIST_ID")"
  ADD_CURRENT_SONOS_HTTP_BASE="$(prompt_required_text "Sonos HTTP base URL" "$ADD_CURRENT_SONOS_HTTP_BASE")"
  ADD_CURRENT_PREFERRED_ROOM="$(prompt_text "Preferred Sonos room for add-current (optional)" "$ADD_CURRENT_PREFERRED_ROOM")"
  ADD_CURRENT_DEDUPE_WINDOW="$(prompt_text "De-dupe window size" "$ADD_CURRENT_DEDUPE_WINDOW")"

  if [[ -z "$ADD_CURRENT_CLIENT_ID" || -z "$ADD_CURRENT_CLIENT_SECRET" || -z "$ADD_CURRENT_REFRESH_TOKEN" ]]; then
    echo "Warning: add-current is enabled but Spotify credentials are incomplete."
    echo "         Metadata and playlist endpoints may return auth errors until values are set."
  fi
fi

WEATHER_API_KEY="$(read_existing_or_default "$weather_env_file" "REACT_APP_OPENWEATHER_API_KEY" "")"
WEATHER_CITY="$(read_existing_or_default "$weather_env_file" "REACT_APP_CITY" "")"
if [[ "$ENABLE_WEATHER_DASHBOARD" == "1" ]]; then
  echo
  echo "Configure weather dashboard values:"
  WEATHER_API_KEY="$(prompt_required_text "OpenWeather API key" "$WEATHER_API_KEY")"
  WEATHER_CITY="$(prompt_required_text "Weather city" "$WEATHER_CITY")"
fi

SONIFY_METADATA_BASE_EXISTING="$(read_existing_or_default "$sonify_env_local_file" "VUE_APP_ADD_CURRENT_BASE" "")"
SONIFY_METADATA_BASE=""

if [[ "$ENABLE_SONIFY_SERVE" == "1" ]]; then
  echo
  if [[ "$ENABLE_ADD_CURRENT" == "1" ]]; then
    SONIFY_METADATA_BASE="http://localhost:3030"
    echo "Sonify track-details source: $SONIFY_METADATA_BASE (local add-current)"
  else
    use_remote_metadata="$(prompt_yes_no "Use extra Spotify track details from another Pi?" "$( [[ -n "$SONIFY_METADATA_BASE_EXISTING" ]] && echo 1 || echo 0 )")"
    if [[ "$use_remote_metadata" == "1" ]]; then
      SONIFY_METADATA_BASE="$(prompt_required_text "Track-details API URL (example: http://192.168.x.x:3030)" "${SONIFY_METADATA_BASE_EXISTING:-http://localhost:3030}")"
    fi
  fi
fi

echo
echo "==> Writing configuration files"
write_device_config "$SONOS_ROOM_VALUE" "$SONIFY_METADATA_BASE"
if [[ "$ENABLE_ADD_CURRENT" == "1" ]]; then
  write_add_current_env \
    "$ADD_CURRENT_CLIENT_ID" \
    "$ADD_CURRENT_CLIENT_SECRET" \
    "$ADD_CURRENT_REFRESH_TOKEN" \
    "$ADD_CURRENT_PLAYLIST_ID" \
    "$ADD_CURRENT_SONOS_HTTP_BASE" \
    "$ADD_CURRENT_PREFERRED_ROOM" \
    "$ADD_CURRENT_DEDUPE_WINDOW"
fi
if [[ "$ENABLE_SPOTIFY_DISPLAY" == "1" ]]; then
  write_spotify_display_env \
    "$SONOS_ROOM_VALUE" \
    "$HIDE_CURSOR_WHILE_DISPLAYING_VALUE" \
    "$HIDE_CURSOR_IDLE_SECONDS_VALUE"
fi
if [[ "$ENABLE_WEATHER_DASHBOARD" == "1" ]]; then
  write_weather_env "$WEATHER_API_KEY" "$WEATHER_CITY"
fi
if [[ "$ENABLE_SONIFY_SERVE" == "1" ]]; then
  write_sonify_env_local "$SONOS_ROOM_VALUE" "$SONIFY_METADATA_BASE"
fi

echo "Wrote: $DEVICE_CONFIG_FILE"

run_now="$(prompt_yes_no "Run redeploy now?" "1")"
if [[ "$run_now" == "1" ]]; then
  echo
  "$ROOT_DIR/scripts/redeploy.sh"
else
  echo
  echo "Run this when ready: ./scripts/redeploy.sh"
fi
