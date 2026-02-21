#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_CONFIG_FILE="$ROOT_DIR/.spainify-device.env"
SONOS_ROOM_CACHE_FILE="$ROOT_DIR/.spainify-sonos-rooms.cache"
DISCOVERY_SONOS_API_PID=""
DISCOVERY_SONOS_TEMP_STARTED="0"
SPOTIFY_AUTH_HELPER_PID=""
SPOTIFY_AUTH_TOKEN_FILE=""
APT_UPDATED="0"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/device_config.sh"

cleanup_setup_helpers() {
  terminate_helper_pid "$DISCOVERY_SONOS_API_PID"
  if [[ "$DISCOVERY_SONOS_TEMP_STARTED" == "1" ]] && command -v pkill >/dev/null 2>&1; then
    pkill -f "$ROOT_DIR/apps/sonos-http-api/server.js" >/dev/null 2>&1 || true
  fi
  DISCOVERY_SONOS_API_PID=""
  DISCOVERY_SONOS_TEMP_STARTED="0"
  terminate_helper_pid "$SPOTIFY_AUTH_HELPER_PID"
  SPOTIFY_AUTH_HELPER_PID=""
  if [[ -n "$SPOTIFY_AUTH_TOKEN_FILE" && -f "$SPOTIFY_AUTH_TOKEN_FILE" ]]; then
    rm -f "$SPOTIFY_AUTH_TOKEN_FILE" || true
  fi
  SPOTIFY_AUTH_TOKEN_FILE=""
}
trap cleanup_setup_helpers EXIT INT TERM

terminate_helper_pid() {
  local pid="$1"
  local i
  if [[ -z "$pid" ]]; then
    return 0
  fi
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    return 0
  fi

  kill "$pid" >/dev/null 2>&1 || true
  for ((i=0; i<30; i++)); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.1
  done

  # Last resort so setup cannot hang forever on cleanup.
  kill -9 "$pid" >/dev/null 2>&1 || true
  wait "$pid" 2>/dev/null || true
}

run_with_elevated_privileges() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
    return
  fi
  return 1
}

apt_available() {
  command -v apt-get >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1
}

apt_package_exists() {
  local pkg="$1"
  if ! command -v apt-cache >/dev/null 2>&1; then
    return 1
  fi
  apt-cache show "$pkg" >/dev/null 2>&1
}

apt_package_installed() {
  local pkg="$1"
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"
}

ensure_apt_index() {
  if [[ "$APT_UPDATED" == "1" ]]; then
    return 0
  fi
  echo "Refreshing apt package index..."
  run_with_elevated_privileges apt-get update
  APT_UPDATED="1"
}

install_apt_packages() {
  local mode="$1"
  shift
  local pkg
  local -a missing=()

  if ! apt_available; then
    if [[ "$mode" == "required" ]]; then
      echo "apt-get is unavailable; cannot auto-install required packages."
      return 1
    fi
    return 0
  fi

  for pkg in "$@"; do
    if [[ -z "$pkg" ]]; then
      continue
    fi
    if ! apt_package_installed "$pkg"; then
      missing+=("$pkg")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    return 0
  fi

  ensure_apt_index || return 1

  if [[ "$mode" == "required" ]]; then
    echo "Installing required packages: ${missing[*]}"
    run_with_elevated_privileges apt-get install -y "${missing[@]}"
    return
  fi

  for pkg in "${missing[@]}"; do
    echo "Installing optional package: $pkg"
    if ! run_with_elevated_privileges apt-get install -y "$pkg"; then
      echo "Warning: failed to install optional package '$pkg'. Continuing."
    fi
  done
}

ensure_command_available() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  echo "Missing required command: $cmd"
  return 1
}

ensure_python_venv_available() {
  if python3 -m venv --help >/dev/null 2>&1; then
    return 0
  fi
  echo "Missing Python venv support (python3-venv)."
  return 1
}

ensure_setup_prerequisites() {
  local need_node="0"
  local required_ok="1"
  local -a required_packages=(curl python3)
  local -a optional_packages=(openssh-server realvnc-vnc-server wayvnc)

  if [[ "$ENABLE_MEDIA_ACTIONS_API" == "1" || "$ENABLE_SONOS_HTTP_API" == "1" || "$ENABLE_SONIFY_UI" == "1" || "$ENABLE_WEATHER_DASHBOARD" == "1" ]]; then
    need_node="1"
    required_packages+=(nodejs npm)
  fi

  if [[ "$ENABLE_DISPLAY_CONTROLLER" == "1" ]]; then
    required_packages+=(python3-venv)
    optional_packages+=(unclutter wlr-randr x11-xserver-utils)
  fi

  install_apt_packages required "${required_packages[@]}" || required_ok="0"
  install_apt_packages optional "${optional_packages[@]}" || true

  ensure_command_available curl || required_ok="0"
  ensure_command_available python3 || required_ok="0"

  if [[ "$need_node" == "1" ]]; then
    ensure_command_available node || required_ok="0"
    ensure_command_available npm || required_ok="0"
  fi

  if [[ "$ENABLE_DISPLAY_CONTROLLER" == "1" ]]; then
    if ! command -v chromium-browser >/dev/null 2>&1 && ! command -v chromium >/dev/null 2>&1; then
      ensure_apt_index || required_ok="0"
      if apt_package_exists chromium-browser; then
        install_apt_packages required chromium-browser || required_ok="0"
      elif apt_package_exists chromium; then
        install_apt_packages required chromium || required_ok="0"
      else
        echo "Missing Chromium browser package (neither chromium-browser nor chromium found in apt repositories)."
        required_ok="0"
      fi
    fi
    ensure_python_venv_available || required_ok="0"
  fi

  if [[ "$required_ok" != "1" ]]; then
    echo "One or more required packages are missing. Fix the errors above and re-run ./setup.sh."
    return 1
  fi
}

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
    echo "Value is required." >&2
  done
}

parse_time_to_hhmm() {
  local raw_input="$1"
  local input
  local hour
  local minute
  local suffix

  input="$(spainify_trim "$raw_input")"
  input="${input// /}"
  input="${input,,}"
  input="${input//./}"

  if [[ -z "$input" ]]; then
    return 1
  fi

  if [[ "$input" =~ ^([0-9]{1,2})(:([0-9]{1,2}))?(a|am|p|pm)?$ ]]; then
    hour="${BASH_REMATCH[1]}"
    minute="${BASH_REMATCH[3]:-0}"
    suffix="${BASH_REMATCH[4]:-}"
  else
    return 1
  fi

  if (( 10#$minute > 59 )); then
    return 1
  fi

  if [[ -n "$suffix" ]]; then
    if (( 10#$hour < 1 || 10#$hour > 12 )); then
      return 1
    fi
    if [[ "$suffix" == "a" || "$suffix" == "am" ]]; then
      if (( 10#$hour == 12 )); then
        hour=0
      else
        hour=$((10#$hour))
      fi
    else
      if (( 10#$hour == 12 )); then
        hour=12
      else
        hour=$((10#$hour + 12))
      fi
    fi
  else
    if (( 10#$hour > 23 )); then
      return 1
    fi
    hour=$((10#$hour))
  fi

  printf '%02d:%02d' "$hour" "$((10#$minute))"
}

prompt_time_hhmm() {
  local question="$1"
  local default_value="$2"
  local value
  local parsed

  while true; do
    value="$(prompt_text "$question" "$default_value")"
    parsed="$(parse_time_to_hhmm "$value" || true)"
    if [[ -n "$parsed" ]]; then
      printf '%s' "$parsed"
      return
    fi
    echo "Invalid time. Examples: 8a, 8am, 8:00am, 20, 20:30."
  done
}

prompt_existing_setup_mode() {
  local choice

  while true; do
    echo >&2
    echo "Existing setup detected. Choose setup mode:" >&2
    echo "  1) Full setup (all services and settings)" >&2
    echo "  2) Add/modify one service or room setting" >&2
    read -r -p "Choose setup mode number: [1] " choice || true
    choice="${choice:-1}"

    case "$choice" in
      1) printf 'full'; return ;;
      2) printf 'targeted'; return ;;
      *) echo "Please enter 1 or 2." >&2 ;;
    esac
  done
}

prompt_targeted_setup_item() {
  local choice

  while true; do
    echo >&2
    echo "Choose what to add or modify:" >&2
    echo "  1) media-actions-api (playlist + track-details + grouping API)" >&2
    echo "  2) weather-dashboard" >&2
    echo "  3) Now-playing Sonos zone" >&2
    read -r -p "Choose item: [1] " choice || true
    choice="${choice:-1}"

    case "$choice" in
      1) printf 'ENABLE_MEDIA_ACTIONS_API'; return ;;
      2) printf 'ENABLE_WEATHER_DASHBOARD'; return ;;
      3) printf 'SONOS_ROOM'; return ;;
      *) echo "Please enter a number from 1 to 3." >&2 ;;
    esac
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
  if [[ "$value" == '"' || "$value" == "'" ]]; then
    value=""
  fi
  printf '%s' "$value"
}

normalize_spotify_playlist_id() {
  local input
  input="$(spainify_trim "${1:-}")"
  if [[ -z "$input" ]]; then
    printf ''
    return
  fi

  if [[ "$input" =~ spotify:playlist:([A-Za-z0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return
  fi

  if [[ "$input" =~ open\.spotify\.com/playlist/([A-Za-z0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return
  fi

  if [[ "$input" =~ ^[A-Za-z0-9]+$ ]]; then
    printf '%s' "$input"
    return
  fi

  # Return original value if no known format matched.
  printf '%s' "$input"
}

normalize_openweather_location_query() {
  local input
  local part
  local city
  local region
  local state
  local country
  local -a parts=()

  input="$(spainify_trim "${1:-}")"
  if [[ -z "$input" ]]; then
    printf ''
    return
  fi

  while IFS= read -r part; do
    part="$(spainify_trim "$part")"
    if [[ -z "$part" ]]; then
      continue
    fi
    part="$(printf '%s' "$part" | tr -s '[:space:]' ' ')"
    parts+=("$part")
  done < <(printf '%s' "$input" | tr ',' '\n')

  if (( ${#parts[@]} == 0 )); then
    printf ''
    return
  fi

  city="${parts[0]}"
  if (( ${#parts[@]} == 1 )); then
    printf '%s' "$city"
    return
  fi

  region="$(printf '%s' "${parts[1]}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
  if (( ${#parts[@]} == 2 )); then
    printf '%s,%s' "$city" "$region"
    return
  fi

  state="$region"
  country="$(printf '%s' "${parts[2]}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
  printf '%s,%s,%s' "$city" "$state" "$country"
}

infer_openweather_location_mode() {
  local input
  local part
  local -a parts=()

  input="$(normalize_openweather_location_query "${1:-}")"
  if [[ -z "$input" ]]; then
    printf 'us'
    return
  fi

  while IFS= read -r part; do
    part="$(spainify_trim "$part")"
    if [[ -n "$part" ]]; then
      parts+=("$part")
    fi
  done < <(printf '%s' "$input" | tr ',' '\n')

  if (( ${#parts[@]} == 3 )) && [[ "${parts[2]}" == "US" && "${parts[1]}" =~ ^[A-Z]{2}$ ]]; then
    printf 'us'
    return
  fi
  if (( ${#parts[@]} == 2 )) && [[ "${parts[1]}" =~ ^[A-Z]{2}$ ]]; then
    printf 'international'
    return
  fi
  printf 'raw'
}

prompt_openweather_location_query() {
  local default_query_raw="${1:-}"
  local default_query=""
  local default_mode=""
  local mode_choice=""
  local mode_label=""
  local part=""
  local city_default=""
  local state_default=""
  local country_default=""
  local city=""
  local state=""
  local country=""
  local raw_query=""
  local query=""
  local -a parts=()

  default_query="$(normalize_openweather_location_query "$default_query_raw")"
  default_mode="$(infer_openweather_location_mode "$default_query")"

  if [[ -n "$default_query" ]]; then
    while IFS= read -r part; do
      part="$(spainify_trim "$part")"
      if [[ -n "$part" ]]; then
        parts+=("$part")
      fi
    done < <(printf '%s' "$default_query" | tr ',' '\n')
  fi

  if (( ${#parts[@]} >= 1 )); then
    city_default="${parts[0]}"
  fi
  if (( ${#parts[@]} >= 2 )); then
    if [[ "$default_mode" == "us" ]]; then
      state_default="${parts[1]}"
    elif [[ "$default_mode" == "international" ]]; then
      country_default="${parts[1]}"
    fi
  fi
  if (( ${#parts[@]} >= 3 )) && [[ "$default_mode" == "us" ]]; then
    state_default="${parts[1]}"
  fi

  case "$default_mode" in
    us) mode_choice="1" ;;
    international) mode_choice="2" ;;
    *) mode_choice="3" ;;
  esac

  while true; do
    echo "Choose weather location input mode:" >&2
    echo "  1) US city + state (recommended for US)" >&2
    echo "  2) International city + country" >&2
    echo "  3) Raw OpenWeather query (advanced)" >&2
    read -r -p "Mode: [$mode_choice] " mode_label || true
    mode_label="${mode_label:-$mode_choice}"
    mode_label="$(spainify_trim "$mode_label")"
    case "$mode_label" in
      1|2|3)
        mode_choice="$mode_label"
        break
        ;;
      *)
        echo "Please enter 1, 2, or 3." >&2
        ;;
    esac
  done

  case "$mode_choice" in
    1)
      city="$(prompt_required_text "Weather city (US)" "$city_default")"
      while true; do
        state="$(prompt_required_text "US state code (2 letters)" "$state_default")"
        state="$(printf '%s' "$state" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
        if [[ "$state" =~ ^[A-Z]{2}$ ]]; then
          break
        fi
        echo "Please enter a 2-letter US state code (example: MD)." >&2
      done
      query="$(normalize_openweather_location_query "$city,$state,US")"
      ;;
    2)
      city="$(prompt_required_text "Weather city (international)" "$city_default")"
      while true; do
        country="$(prompt_required_text "Country code (2 letters, example: GB)" "$country_default")"
        country="$(printf '%s' "$country" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
        if [[ "$country" =~ ^[A-Z]{2}$ ]]; then
          break
        fi
        echo "Please enter a 2-letter country code (example: GB)." >&2
      done
      query="$(normalize_openweather_location_query "$city,$country")"
      ;;
    *)
      raw_query="$(prompt_required_text "Weather location query (advanced)" "$default_query")"
      query="$(normalize_openweather_location_query "$raw_query")"
      ;;
  esac

  if [[ -z "$query" ]]; then
    echo "Weather location query is required." >&2
    return 1
  fi
  printf '%s' "$query"
}

load_available_sonos_rooms() {
  local sonos_base="$1"
  local tmp_json
  local room
  local attempt
  local current_count=0
  local max_attempts=15
  local stable_rounds=0
  local last_count=0
  local -A seen_rooms=()

  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi

  # Poll until results stabilize; Sonos discovery can be incomplete
  # for a few seconds right after API startup.
  for ((attempt=1; attempt<=max_attempts; attempt++)); do
    tmp_json="$(mktemp)"
    if curl -fsS --max-time 3 "$sonos_base/zones" >"$tmp_json" 2>/dev/null; then
      while IFS= read -r room; do
        if [[ -n "$room" ]]; then
          seen_rooms["$room"]=1
        fi
      done < <(spainify_parse_rooms_from_zones_json "$tmp_json" 2>/dev/null || true)
    fi
    rm -f "$tmp_json"

    current_count="${#seen_rooms[@]}"
    if (( current_count > 0 )); then
      if (( current_count == last_count )); then
        ((stable_rounds++))
      else
        stable_rounds=0
      fi
      last_count="$current_count"
      if (( stable_rounds >= 2 )); then
        break
      fi
    fi

    sleep 1
  done

  SONOS_ROOMS=()
  for room in "${!seen_rooms[@]}"; do
    SONOS_ROOMS+=("$room")
  done
  set_sonos_rooms_unique_sorted

  (( ${#SONOS_ROOMS[@]} > 0 ))
}

load_available_sonos_rooms_direct() {
  local discovered
  discovered="$(
    python3 - <<'PY'
import re
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

MSEARCH = "\r\n".join([
    "M-SEARCH * HTTP/1.1",
    "HOST: 239.255.255.250:1900",
    "MAN: \"ssdp:discover\"",
    "MX: 2",
    "ST: urn:schemas-upnp-org:device:ZonePlayer:1",
    "",
    "",
]).encode("ascii", "ignore")

locations = set()
rooms = set()

def local_name(tag):
    if "}" in tag:
        return tag.rsplit("}", 1)[1]
    return tag

def parse_rooms(payload):
    names = set()
    root = ET.fromstring(payload)
    for elem in root.iter():
        lname = local_name(elem.tag)
        if lname == "ZonePlayer":
            for key, value in elem.attrib.items():
                if local_name(key) == "ZoneName":
                    zone = (value or "").strip()
                    if zone:
                        names.add(zone)
        elif lname in ("roomName", "ZoneName"):
            zone = (elem.text or "").strip()
            if zone:
                names.add(zone)
    return names

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
sock.settimeout(1.2)
deadline = time.time() + 10.0
next_probe = 0.0

while time.time() < deadline:
    now = time.time()
    if now >= next_probe:
        # Re-probe periodically to catch slower responders.
        for _ in range(3):
            sock.sendto(MSEARCH, ("239.255.255.250", 1900))
            time.sleep(0.1)
        next_probe = now + 2.0
    try:
        data, _ = sock.recvfrom(65535)
    except socket.timeout:
        continue
    text = data.decode("utf-8", "ignore")
    match = re.search(r"(?im)^location:\s*(\S+)\s*$", text)
    if match:
        locations.add(match.group(1).strip())

sock.close()

for location in locations:
    try:
        parsed = urllib.parse.urlparse(location)
        host = parsed.hostname
        if not host:
            continue
        urls = [location, f"http://{host}:1400/status/topology"]
        for url in urls:
            try:
                with urllib.request.urlopen(url, timeout=3) as response:
                    payload = response.read()
                rooms.update(parse_rooms(payload))
            except (urllib.error.URLError, TimeoutError, ET.ParseError, ValueError):
                continue
    except (urllib.error.URLError, TimeoutError, ET.ParseError, ValueError):
        continue

for room in sorted(rooms):
    print(room)
PY
  )"

  SONOS_ROOMS=()
  while IFS= read -r room; do
    room="$(spainify_trim "$room")"
    if [[ -n "$room" ]]; then
      SONOS_ROOMS+=("$room")
    fi
  done <<< "$discovered"

  (( ${#SONOS_ROOMS[@]} > 0 ))
}

choose_discovered_sonos_room() {
  local default_room="$1"
  local i
  local prompt_default=""
  local selected
  local choice

  echo >&2
  echo "Discovered Sonos rooms:" >&2
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
    return 0
  fi

  return 1
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
    (cd "$api_dir" && npm install --no-audit --no-fund --loglevel=error >/dev/null)
  fi

  mkdir -p "$api_dir/presets"
  if [[ ! -f "$api_dir/settings.json" ]]; then
    printf '{}\n' > "$api_dir/settings.json"
  fi

  (
    cd "$api_dir"
    exec node server.js >/tmp/spainify-setup-sonos-http-api.log 2>&1
  ) &
  DISCOVERY_SONOS_API_PID="$!"
  DISCOVERY_SONOS_TEMP_STARTED="1"

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
  local discovered_any=0
  local cached_any=0
  local selected_room=""
  local -a api_rooms=()
  local -a direct_rooms=()
  local -a cached_rooms=()
  SONOS_ROOMS=()

  if load_available_sonos_rooms "$sonos_base"; then
    api_rooms=("${SONOS_ROOMS[@]}")
    discovered_any=1
  elif boot_temp_sonos_http_api "$sonos_base" && load_available_sonos_rooms "$sonos_base"; then
    api_rooms=("${SONOS_ROOMS[@]}")
    discovered_any=1
  fi

  if load_available_sonos_rooms_direct; then
    direct_rooms=("${SONOS_ROOMS[@]}")
    discovered_any=1
  fi

  if load_cached_sonos_rooms; then
    cached_rooms=("${SONOS_ROOMS[@]}")
    cached_any=1
  fi

  SONOS_ROOMS=("${api_rooms[@]}" "${direct_rooms[@]}" "${cached_rooms[@]}" "$default_room")
  set_sonos_rooms_unique_sorted

  if (( discovered_any == 1 )); then
    save_cached_sonos_rooms
  fi

  if (( ${#SONOS_ROOMS[@]} > 0 )); then
    selected_room="$(choose_discovered_sonos_room "$default_room" || true)"
    selected_room="$(spainify_trim "$selected_room")"
    if [[ -n "$selected_room" ]]; then
      cleanup_setup_helpers
      printf '%s' "$selected_room"
      return
    fi
  fi

  if (( discovered_any == 0 && cached_any == 1 )); then
    echo >&2
    echo "Live discovery missed one or more rooms; showing cached room list as backup." >&2
  elif (( discovered_any == 0 )); then
    echo >&2
    echo "Could not auto-discover Sonos rooms through local API or direct network scan. Enter room name manually." >&2
  fi

  selected_room="$(prompt_required_text "Enter Sonos room name" "$default_room")"
  cleanup_setup_helpers
  printf '%s' "$selected_room"
}

first_ipv4_address() {
  hostname -I 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\./) { print $i; exit }}'
}

print_spotify_setup_help() {
  local host_ip=""
  host_ip="$(first_ipv4_address)"

  echo "Spotify app setup (for media-actions-api):"
  echo "  1) Create/sign in to your Spotify developer account:"
  echo "     https://developer.spotify.com/dashboard"
  echo "  2) Create an app and add these Redirect URI values in app settings:"
  echo "     - http://127.0.0.1:8888/callback"
  if [[ -n "$host_ip" ]]; then
    echo "     - http://$host_ip:8888/callback"
  else
    echo "     - http://<pi-ip-address>:8888/callback"
  fi
  echo "  3) Copy the app Client ID and Client Secret into setup prompts."
  echo "  Setup will launch Spotify login and capture refresh token automatically."
}

print_openweather_setup_help() {
  echo "OpenWeather setup (for weather-dashboard):"
  echo "  1) Create/sign in to your OpenWeather account:"
  echo "     https://home.openweathermap.org/api_keys"
  echo "  2) Create an API key and paste it at the OpenWeather API key prompt."
  echo "  3) Setup will guide location input:"
  echo "     - US mode: City + 2-letter state code (saved as City,ST,US)"
  echo "     - International mode: City + 2-letter country code (saved as City,CC)"
  echo "     - Advanced mode: raw OpenWeather query"
}

start_spotify_auth_helper() {
  local client_id="$1"
  local client_secret="$2"
  local auth_dir="$ROOT_DIR/apps/media-actions-api"
  local helper_pattern="$ROOT_DIR/apps/media-actions-api/auth.js"
  local i

  if [[ -z "$client_id" || -z "$client_secret" ]]; then
    echo "Spotify client ID and secret are required to start auth."
    return 1
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "Node.js is required for Spotify auth helper."
    return 1
  fi
  if [[ ! -f "$auth_dir/auth.js" ]]; then
    echo "Could not find media-actions-api auth helper: $auth_dir/auth.js"
    return 1
  fi

  # If a healthy helper is already running, reuse it.
  if curl -fsS --max-time 2 "http://127.0.0.1:8888/healthz" >/dev/null 2>&1; then
    echo "Spotify auth helper already running on port 8888; reusing it."
    return 0
  fi

  # Clean up stale helper processes that may have survived earlier runs.
  if command -v pkill >/dev/null 2>&1; then
    pkill -f "$helper_pattern" >/dev/null 2>&1 || true
  fi

  # Ensure auth helper dependencies exist before launching node auth.js.
  if ! (cd "$auth_dir" && node -e "require.resolve('express'); require.resolve('dotenv'); require.resolve('node-fetch')" >/dev/null 2>&1); then
    echo "Installing media-actions-api dependencies for Spotify auth helper..."
    (cd "$auth_dir" && npm install --no-audit --no-fund >/dev/null)
  fi

  cleanup_setup_helpers
  SPOTIFY_AUTH_TOKEN_FILE="$(mktemp)"
  (
    cd "$auth_dir" && \
    SPOTIFY_CLIENT_ID="$client_id" \
    SPOTIFY_CLIENT_SECRET="$client_secret" \
    PI_HOST="127.0.0.1" \
    SPAINIFY_TOKEN_FILE="$SPOTIFY_AUTH_TOKEN_FILE" \
    node auth.js >/tmp/spainify-setup-spotify-auth.log 2>&1
  ) &
  SPOTIFY_AUTH_HELPER_PID="$!"

  for ((i=0; i<15; i++)); do
    if curl -fsS --max-time 2 "http://127.0.0.1:8888/healthz" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$SPOTIFY_AUTH_HELPER_PID" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  echo "Could not start Spotify auth helper on port 8888."
  echo "See log: /tmp/spainify-setup-spotify-auth.log"
  if [[ -f /tmp/spainify-setup-spotify-auth.log ]]; then
    tail -n 20 /tmp/spainify-setup-spotify-auth.log || true
  fi
  return 1
}

wait_for_spotify_refresh_token() {
  local wait_seconds="${1:-300}"
  local i
  local token=""

  for ((i=0; i<wait_seconds; i++)); do
    if [[ -n "$SPOTIFY_AUTH_TOKEN_FILE" && -s "$SPOTIFY_AUTH_TOKEN_FILE" ]]; then
      token="$(tr -d '\r\n' < "$SPOTIFY_AUTH_TOKEN_FILE")"
      token="$(spainify_trim "$token")"
      if [[ -n "$token" ]]; then
        printf '%s' "$token"
        return 0
      fi
    fi

    token="$(curl -fsS --max-time 2 "http://127.0.0.1:8888/token" 2>/dev/null || true)"
    token="$(spainify_trim "$token")"
    if [[ -n "$token" ]]; then
      printf '%s' "$token"
      return 0
    fi
    sleep 1
  done

  return 1
}

set_sonos_rooms_unique_sorted() {
  local room
  local -a unique=()
  local -A seen=()

  for room in "${SONOS_ROOMS[@]}"; do
    room="$(spainify_trim "$room")"
    if [[ -z "$room" ]]; then
      continue
    fi
    if [[ -z "${seen[$room]+x}" ]]; then
      seen["$room"]="1"
      unique+=("$room")
    fi
  done

  if (( ${#unique[@]} == 0 )); then
    SONOS_ROOMS=()
    return
  fi

  mapfile -t SONOS_ROOMS < <(printf '%s\n' "${unique[@]}" | sort)
}

load_cached_sonos_rooms() {
  local room
  if [[ ! -f "$SONOS_ROOM_CACHE_FILE" ]]; then
    return 1
  fi

  SONOS_ROOMS=()
  while IFS= read -r room; do
    room="$(spainify_trim "$room")"
    if [[ -n "$room" ]]; then
      SONOS_ROOMS+=("$room")
    fi
  done < "$SONOS_ROOM_CACHE_FILE"

  set_sonos_rooms_unique_sorted
  (( ${#SONOS_ROOMS[@]} > 0 ))
}

save_cached_sonos_rooms() {
  local tmp
  if (( ${#SONOS_ROOMS[@]} == 0 )); then
    return 0
  fi

  tmp="$(mktemp)"
  printf '%s\n' "${SONOS_ROOMS[@]}" > "$tmp"
  mv "$tmp" "$SONOS_ROOM_CACHE_FILE"
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
ENABLE_MEDIA_ACTIONS_API=$ENABLE_MEDIA_ACTIONS_API
ENABLE_DISPLAY_CONTROLLER=$ENABLE_DISPLAY_CONTROLLER
ENABLE_WEATHER_DASHBOARD=$ENABLE_WEATHER_DASHBOARD
ENABLE_SONOS_HTTP_API=$ENABLE_SONOS_HTTP_API
ENABLE_SONIFY_UI=$ENABLE_SONIFY_UI
SONOS_ROOM="$escaped_room"
SONIFY_METADATA_BASE="$escaped_metadata"
EOF_CFG
}

write_media_actions_api_env() {
  local file="$ROOT_DIR/apps/media-actions-api/.env"
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

write_display_controller_env() {
  local file="$ROOT_DIR/apps/display-controller/.env"
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
  local display_start="$3"
  local display_end="$4"

  api_key="$(spainify_trim "$api_key")"
  city="$(normalize_openweather_location_query "$city")"

cat >"$file" <<EOF_WEATHER
REACT_APP_OPENWEATHER_API_KEY="$(escape_double_quotes "$api_key")"
REACT_APP_CITY="$(escape_double_quotes "$city")"
WEATHER_DISPLAY_START="$(escape_double_quotes "$display_start")"
WEATHER_DISPLAY_END="$(escape_double_quotes "$display_end")"
EOF_WEATHER
}

write_sonify_env_local() {
  local file="$ROOT_DIR/apps/sonify-ui/.env.local"
  local room="$1"
  local metadata_base="$2"
  local escaped_room
  escaped_room="$(escape_double_quotes "$room")"

  if [[ -n "$metadata_base" ]]; then
    cat >"$file" <<EOF_SONIFY
VUE_APP_SONOS_ROOM="$escaped_room"
VUE_APP_MEDIA_ACTIONS_BASE="$(escape_double_quotes "$metadata_base")"
EOF_SONIFY
  else
    cat >"$file" <<EOF_SONIFY
VUE_APP_SONOS_ROOM="$escaped_room"
EOF_SONIFY
  fi
}

echo "==> spainify setup wizard"
echo "This script configures services and writes local env files for this device."

SETUP_MODE="full"
SETUP_TARGET_KEY=""

if [[ -f "$DEVICE_CONFIG_FILE" ]]; then
  echo "Found existing device config: $DEVICE_CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$DEVICE_CONFIG_FILE"
  SETUP_MODE="$(prompt_existing_setup_mode)"
  if [[ "$SETUP_MODE" == "targeted" ]]; then
    SETUP_TARGET_KEY="$(prompt_targeted_setup_item)"
  fi
fi

for key in "${SPAINIFY_SERVICE_KEYS[@]}"; do
  current_value="${!key:-$(spainify_service_default "$key")}"
  printf -v "$key" '%s' "$(spainify_normalize_bool "$current_value" "$(spainify_service_default "$key")")"
done

echo
if [[ "$SETUP_MODE" == "full" ]]; then
  for key in "${SPAINIFY_SERVICE_KEYS[@]}"; do
    prompt="$(spainify_service_prompt "$key")"
    answer="$(prompt_yes_no "$prompt" "${!key}")"
    printf -v "$key" '%s' "$(spainify_normalize_bool "$answer" "${!key}")"
  done
else
  if [[ "$SETUP_TARGET_KEY" == "SONOS_ROOM" ]]; then
    echo "Targeted mode: service enablement unchanged; now-playing Sonos zone only."
  else
    prompt="$(spainify_service_prompt "$SETUP_TARGET_KEY")"
    answer="$(prompt_yes_no "$prompt" "${!SETUP_TARGET_KEY}")"
    printf -v "$SETUP_TARGET_KEY" '%s' "$(spainify_normalize_bool "$answer" "${!SETUP_TARGET_KEY}")"
  fi
fi

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

echo
echo "==> Checking system package prerequisites..."
ensure_setup_prerequisites

display_env_file="$ROOT_DIR/apps/display-controller/.env"
media_actions_api_env_file="$ROOT_DIR/apps/media-actions-api/.env"
weather_env_file="$ROOT_DIR/apps/weather-dashboard/.env"
sonify_env_local_file="$ROOT_DIR/apps/sonify-ui/.env.local"

configure_room_prompt="0"
configure_cursor_prompt="0"
configure_media_actions_api_prompt="0"
configure_weather_prompt="0"
configure_sonify_prompt="0"

if [[ "$SETUP_MODE" == "full" ]]; then
  if [[ "$ENABLE_DISPLAY_CONTROLLER" == "1" || "$ENABLE_SONIFY_UI" == "1" || "$ENABLE_MEDIA_ACTIONS_API" == "1" ]]; then
    configure_room_prompt="1"
  fi
  if [[ "$ENABLE_DISPLAY_CONTROLLER" == "1" ]]; then
    configure_cursor_prompt="1"
  fi
  if [[ "$ENABLE_MEDIA_ACTIONS_API" == "1" ]]; then
    configure_media_actions_api_prompt="1"
  fi
  if [[ "$ENABLE_WEATHER_DASHBOARD" == "1" ]]; then
    configure_weather_prompt="1"
  fi
  if [[ "$ENABLE_SONIFY_UI" == "1" ]]; then
    configure_sonify_prompt="1"
  fi
else
  case "$SETUP_TARGET_KEY" in
    ENABLE_MEDIA_ACTIONS_API)
      if [[ "$ENABLE_MEDIA_ACTIONS_API" == "1" ]]; then
        configure_media_actions_api_prompt="1"
      fi
      ;;
    ENABLE_WEATHER_DASHBOARD)
      if [[ "$ENABLE_WEATHER_DASHBOARD" == "1" ]]; then
        configure_weather_prompt="1"
      fi
      ;;
    SONOS_ROOM)
      configure_room_prompt="1"
      ;;
  esac
fi

default_sonos_http_base="$(read_existing_or_default "$media_actions_api_env_file" "SONOS_HTTP_BASE" "http://127.0.0.1:5005")"
default_room="$(read_existing_or_default "$display_env_file" "SONOS_ROOM" "")"
if [[ -z "$default_room" ]]; then
  default_room="$(read_existing_or_default "$sonify_env_local_file" "VUE_APP_SONOS_ROOM" "")"
fi
default_room="$(sanitize_room_default "$default_room")"
if [[ "$SETUP_MODE" == "targeted" && "$SETUP_TARGET_KEY" == "SONOS_ROOM" ]]; then
  # Force an explicit selection when user is changing only the now-playing zone.
  default_room=""
fi

SONOS_ROOM_VALUE="$default_room"
if [[ "$configure_room_prompt" == "1" ]]; then
  SONOS_ROOM_VALUE="$(prompt_sonos_room "$default_room" "$default_sonos_http_base")"
fi
cleanup_setup_helpers

HIDE_CURSOR_WHILE_DISPLAYING_VALUE="$(read_existing_or_default "$display_env_file" "HIDE_CURSOR_WHILE_DISPLAYING" "1")"
HIDE_CURSOR_IDLE_SECONDS_VALUE="$(read_existing_or_default "$display_env_file" "HIDE_CURSOR_IDLE_SECONDS" "0.1")"
if [[ "$configure_cursor_prompt" == "1" && "$ENABLE_DISPLAY_CONTROLLER" == "1" ]]; then
  echo
  HIDE_CURSOR_WHILE_DISPLAYING_VALUE="$(prompt_yes_no "Hide mouse cursor while content is showing?" "$HIDE_CURSOR_WHILE_DISPLAYING_VALUE")"
fi

MEDIA_ACTIONS_API_CLIENT_ID="$(read_existing_or_default "$media_actions_api_env_file" "SPOTIFY_CLIENT_ID" "")"
MEDIA_ACTIONS_API_CLIENT_SECRET="$(read_existing_or_default "$media_actions_api_env_file" "SPOTIFY_CLIENT_SECRET" "")"
MEDIA_ACTIONS_API_REFRESH_TOKEN="$(read_existing_or_default "$media_actions_api_env_file" "SPOTIFY_REFRESH_TOKEN" "")"
MEDIA_ACTIONS_API_PLAYLIST_ID="$(read_existing_or_default "$media_actions_api_env_file" "SPOTIFY_PLAYLIST_ID" "")"
MEDIA_ACTIONS_API_SONOS_HTTP_BASE="$(read_existing_or_default "$media_actions_api_env_file" "SONOS_HTTP_BASE" "$default_sonos_http_base")"
MEDIA_ACTIONS_API_PREFERRED_ROOM="$(read_existing_or_default "$media_actions_api_env_file" "PREFERRED_ROOM" "")"
MEDIA_ACTIONS_API_DEDUPE_WINDOW="$(read_existing_or_default "$media_actions_api_env_file" "DE_DUPE_WINDOW" "750")"

if [[ "$configure_media_actions_api_prompt" == "1" && "$ENABLE_MEDIA_ACTIONS_API" == "1" ]]; then
  token_captured_automatically="0"
  echo
  echo "Configure media-actions-api service values:"
  print_spotify_setup_help
  echo
  MEDIA_ACTIONS_API_CLIENT_ID="$(prompt_text "Spotify client ID" "$MEDIA_ACTIONS_API_CLIENT_ID")"
  MEDIA_ACTIONS_API_CLIENT_SECRET="$(prompt_text "Spotify client secret" "$MEDIA_ACTIONS_API_CLIENT_SECRET")"
  if [[ -n "$MEDIA_ACTIONS_API_CLIENT_ID" && -n "$MEDIA_ACTIONS_API_CLIENT_SECRET" ]]; then
    if start_spotify_auth_helper "$MEDIA_ACTIONS_API_CLIENT_ID" "$MEDIA_ACTIONS_API_CLIENT_SECRET"; then
      echo
      if [[ -n "${SSH_CONNECTION:-}" ]]; then
        pi_ip="$(first_ipv4_address)"
        pi_user="$(id -un)"
        if [[ -z "$pi_ip" ]]; then
          pi_ip="raspberrypi.local"
        fi
        echo "Spotify auth uses 127.0.0.1 redirect."
        echo "From your Mac, open a new terminal and run:"
        echo "  ssh -N -L 8888:127.0.0.1:8888 $pi_user@$pi_ip"
        echo "Then open in your Mac browser:"
        echo "  http://127.0.0.1:8888/login"
      else
        echo "Open this URL in a browser and approve Spotify access:"
        echo "  http://127.0.0.1:8888/login"
      fi
      echo "Waiting for callback to capture refresh token (up to 5 minutes)..."
      fetched_refresh_token="$(wait_for_spotify_refresh_token 300 || true)"
      if [[ -n "$fetched_refresh_token" ]]; then
        MEDIA_ACTIONS_API_REFRESH_TOKEN="$fetched_refresh_token"
        token_captured_automatically="1"
        echo "Refresh token captured automatically."
      else
        echo "Timed out waiting for Spotify callback. You can paste token manually."
      fi
    fi
    cleanup_setup_helpers
  fi
  if [[ "$token_captured_automatically" != "1" ]]; then
    MEDIA_ACTIONS_API_REFRESH_TOKEN="$(prompt_text "Spotify refresh token" "$MEDIA_ACTIONS_API_REFRESH_TOKEN")"
  else
    echo "Spotify refresh token: [captured automatically]"
  fi
  media_actions_api_playlist_input="$(prompt_text "Spotify playlist link or ID (example: https://open.spotify.com/playlist/3kQGrwA1LHaM2tt4qqfC2Y)" "$MEDIA_ACTIONS_API_PLAYLIST_ID")"
  MEDIA_ACTIONS_API_PLAYLIST_ID="$(normalize_spotify_playlist_id "$media_actions_api_playlist_input")"

  if [[ "$MEDIA_ACTIONS_API_PLAYLIST_ID" != "$media_actions_api_playlist_input" && -n "$MEDIA_ACTIONS_API_PLAYLIST_ID" ]]; then
    echo "Using playlist ID: $MEDIA_ACTIONS_API_PLAYLIST_ID"
  fi

  if [[ -z "$MEDIA_ACTIONS_API_SONOS_HTTP_BASE" ]]; then
    MEDIA_ACTIONS_API_SONOS_HTTP_BASE="http://127.0.0.1:5005"
  fi
  # Keep existing preferred room if provided; default to blank.
  MEDIA_ACTIONS_API_PREFERRED_ROOM="$(spainify_trim "${MEDIA_ACTIONS_API_PREFERRED_ROOM:-}")"

  # Use full-playlist de-dupe by default for deterministic behavior.
  MEDIA_ACTIONS_API_DEDUPE_WINDOW="all"

  if [[ -z "$MEDIA_ACTIONS_API_CLIENT_ID" || -z "$MEDIA_ACTIONS_API_CLIENT_SECRET" || -z "$MEDIA_ACTIONS_API_REFRESH_TOKEN" ]]; then
    echo "Warning: media-actions-api is enabled but Spotify credentials are incomplete."
    echo "         Metadata and playlist endpoints may return auth errors until values are set."
  fi
fi

WEATHER_API_KEY="$(read_existing_or_default "$weather_env_file" "REACT_APP_OPENWEATHER_API_KEY" "")"
WEATHER_CITY="$(read_existing_or_default "$weather_env_file" "REACT_APP_CITY" "")"
WEATHER_DISPLAY_START="$(read_existing_or_default "$weather_env_file" "WEATHER_DISPLAY_START" "07:00")"
WEATHER_DISPLAY_END="$(read_existing_or_default "$weather_env_file" "WEATHER_DISPLAY_END" "09:00")"
if [[ "$configure_weather_prompt" == "1" && "$ENABLE_WEATHER_DASHBOARD" == "1" ]]; then
  echo
  echo "Configure weather dashboard values:"
  print_openweather_setup_help
  echo
  WEATHER_API_KEY="$(spainify_trim "$(prompt_required_text "OpenWeather API key" "$WEATHER_API_KEY")")"
  WEATHER_CITY="$(prompt_openweather_location_query "$WEATHER_CITY")"
  echo "Using weather location query: $WEATHER_CITY"
  WEATHER_DISPLAY_START="$(prompt_time_hhmm "Enter weather display start time (example: 7:00am)" "$WEATHER_DISPLAY_START")"
  WEATHER_DISPLAY_END="$(prompt_time_hhmm "Enter weather display end time (example: 9:00am)" "$WEATHER_DISPLAY_END")"
fi

SONIFY_METADATA_BASE_EXISTING="$(read_existing_or_default "$sonify_env_local_file" "VUE_APP_MEDIA_ACTIONS_BASE" "")"
SONIFY_METADATA_BASE="$SONIFY_METADATA_BASE_EXISTING"

if [[ "$configure_sonify_prompt" == "1" && "$ENABLE_SONIFY_UI" == "1" ]]; then
  echo
  if [[ "$ENABLE_MEDIA_ACTIONS_API" == "1" ]]; then
    SONIFY_METADATA_BASE="http://localhost:3030"
    echo "Sonify track-details source: $SONIFY_METADATA_BASE (local media-actions-api)"
  else
    use_remote_metadata="$(prompt_yes_no "Use extra Spotify track details from another Pi?" "$( [[ -n "$SONIFY_METADATA_BASE_EXISTING" ]] && echo 1 || echo 0 )")"
    if [[ "$use_remote_metadata" == "1" ]]; then
      SONIFY_METADATA_BASE="$(prompt_required_text "Track-details API URL (example: http://192.168.x.x:3030)" "${SONIFY_METADATA_BASE_EXISTING:-http://localhost:3030}")"
    fi
  fi
fi

if [[ "$SETUP_MODE" == "targeted" && "$SETUP_TARGET_KEY" == "ENABLE_MEDIA_ACTIONS_API" && "$ENABLE_MEDIA_ACTIONS_API" == "1" && "$ENABLE_SONIFY_UI" == "1" ]]; then
  SONIFY_METADATA_BASE="http://localhost:3030"
fi

echo
echo "==> Writing configuration files"

WRITE_MEDIA_ACTIONS_API_ENV="0"
WRITE_DISPLAY_CONTROLLER_ENV="0"
WRITE_WEATHER_ENV="0"
WRITE_SONIFY_ENV_LOCAL="0"

if [[ "$SETUP_MODE" == "full" ]]; then
  if [[ "$ENABLE_MEDIA_ACTIONS_API" == "1" ]]; then
    WRITE_MEDIA_ACTIONS_API_ENV="1"
  fi
  if [[ "$ENABLE_DISPLAY_CONTROLLER" == "1" ]]; then
    WRITE_DISPLAY_CONTROLLER_ENV="1"
  fi
  if [[ "$ENABLE_WEATHER_DASHBOARD" == "1" ]]; then
    WRITE_WEATHER_ENV="1"
  fi
  if [[ "$ENABLE_SONIFY_UI" == "1" ]]; then
    WRITE_SONIFY_ENV_LOCAL="1"
  fi
else
  case "$SETUP_TARGET_KEY" in
    ENABLE_MEDIA_ACTIONS_API)
      if [[ "$ENABLE_MEDIA_ACTIONS_API" == "1" ]]; then
        WRITE_MEDIA_ACTIONS_API_ENV="1"
      fi
      if [[ "$ENABLE_SONIFY_UI" == "1" ]]; then
        WRITE_SONIFY_ENV_LOCAL="1"
      fi
      ;;
    ENABLE_WEATHER_DASHBOARD)
      if [[ "$ENABLE_WEATHER_DASHBOARD" == "1" ]]; then
        WRITE_WEATHER_ENV="1"
      fi
      ;;
    SONOS_ROOM)
      if [[ "$ENABLE_DISPLAY_CONTROLLER" == "1" ]]; then
        WRITE_DISPLAY_CONTROLLER_ENV="1"
      fi
      if [[ "$ENABLE_SONIFY_UI" == "1" ]]; then
        WRITE_SONIFY_ENV_LOCAL="1"
      fi
      ;;
  esac
fi

write_device_config "$SONOS_ROOM_VALUE" "$SONIFY_METADATA_BASE"
if [[ "$WRITE_MEDIA_ACTIONS_API_ENV" == "1" ]]; then
  write_media_actions_api_env \
    "$MEDIA_ACTIONS_API_CLIENT_ID" \
    "$MEDIA_ACTIONS_API_CLIENT_SECRET" \
    "$MEDIA_ACTIONS_API_REFRESH_TOKEN" \
    "$MEDIA_ACTIONS_API_PLAYLIST_ID" \
    "$MEDIA_ACTIONS_API_SONOS_HTTP_BASE" \
    "$MEDIA_ACTIONS_API_PREFERRED_ROOM" \
    "$MEDIA_ACTIONS_API_DEDUPE_WINDOW"
fi
if [[ "$WRITE_DISPLAY_CONTROLLER_ENV" == "1" ]]; then
  write_display_controller_env \
    "$SONOS_ROOM_VALUE" \
    "$HIDE_CURSOR_WHILE_DISPLAYING_VALUE" \
    "$HIDE_CURSOR_IDLE_SECONDS_VALUE"
fi
if [[ "$WRITE_WEATHER_ENV" == "1" ]]; then
  write_weather_env "$WEATHER_API_KEY" "$WEATHER_CITY" "$WEATHER_DISPLAY_START" "$WEATHER_DISPLAY_END"
fi
if [[ "$WRITE_SONIFY_ENV_LOCAL" == "1" ]]; then
  write_sonify_env_local "$SONOS_ROOM_VALUE" "$SONIFY_METADATA_BASE"
fi

echo "Wrote: $DEVICE_CONFIG_FILE"

REDEPLOY_ONLY_KEYS_CSV=""
if [[ "$SETUP_MODE" == "targeted" ]]; then
  declare -A redeploy_scope_map=()
  redeploy_scope_keys=()

  add_redeploy_scope_key() {
    local key="$1"
    if [[ -z "$key" || -n "${redeploy_scope_map[$key]+x}" ]]; then
      return
    fi
    redeploy_scope_map["$key"]="1"
    redeploy_scope_keys+=("$key")
  }

  case "$SETUP_TARGET_KEY" in
    ENABLE_MEDIA_ACTIONS_API)
      add_redeploy_scope_key ENABLE_MEDIA_ACTIONS_API
      if [[ "$ENABLE_SONIFY_UI" == "1" ]]; then
        add_redeploy_scope_key ENABLE_SONIFY_UI
      fi
      ;;
    ENABLE_WEATHER_DASHBOARD)
      add_redeploy_scope_key ENABLE_WEATHER_DASHBOARD
      if [[ "$ENABLE_DISPLAY_CONTROLLER" == "1" ]]; then
        add_redeploy_scope_key ENABLE_DISPLAY_CONTROLLER
      fi
      ;;
    SONOS_ROOM)
      if [[ "$ENABLE_DISPLAY_CONTROLLER" == "1" ]]; then
        add_redeploy_scope_key ENABLE_DISPLAY_CONTROLLER
      fi
      if [[ "$ENABLE_SONIFY_UI" == "1" ]]; then
        add_redeploy_scope_key ENABLE_SONIFY_UI
      fi
      ;;
  esac

  if (( ${#redeploy_scope_keys[@]} > 0 )); then
    REDEPLOY_ONLY_KEYS_CSV="$(IFS=,; echo "${redeploy_scope_keys[*]}")"
  fi
fi

redeploy_prompt="Run redeploy now?"
if [[ "$SETUP_MODE" == "targeted" ]]; then
  case "$SETUP_TARGET_KEY" in
    ENABLE_MEDIA_ACTIONS_API) redeploy_prompt="Deploy changes for media-actions-api now?" ;;
    ENABLE_WEATHER_DASHBOARD) redeploy_prompt="Deploy changes for weather-dashboard now?" ;;
    SONOS_ROOM) redeploy_prompt="Deploy changes for Now-playing Sonos zone now?" ;;
    *) redeploy_prompt="Deploy selected changes now?" ;;
  esac
fi

run_now="$(prompt_yes_no "$redeploy_prompt" "1")"
if [[ "$run_now" == "1" ]]; then
  echo
  echo "==> Running redeploy..."
  if [[ -n "$REDEPLOY_ONLY_KEYS_CSV" ]]; then
    echo "==> Targeted redeploy scope: $REDEPLOY_ONLY_KEYS_CSV"
    "$ROOT_DIR/scripts/redeploy.sh" --only "$REDEPLOY_ONLY_KEYS_CSV"
  else
    "$ROOT_DIR/scripts/redeploy.sh"
  fi
  echo "==> Finalizing setup..."
  echo "==> Setup complete."
else
  echo
  if [[ -n "$REDEPLOY_ONLY_KEYS_CSV" ]]; then
    echo "Run this when ready: ./scripts/redeploy.sh --only $REDEPLOY_ONLY_KEYS_CSV"
  else
    echo "Run this when ready: ./scripts/redeploy.sh"
  fi
  echo "==> Setup complete."
fi

exit 0
