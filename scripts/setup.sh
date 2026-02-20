#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_CONFIG_FILE="$ROOT_DIR/.spainify-device.env"
SONOS_ROOM_CACHE_FILE="$ROOT_DIR/.spainify-sonos-rooms.cache"
DISCOVERY_SONOS_API_PID=""
SPOTIFY_AUTH_HELPER_PID=""
SPOTIFY_AUTH_TOKEN_FILE=""
APT_UPDATED="0"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/device_config.sh"

cleanup_setup_helpers() {
  terminate_helper_pid "$DISCOVERY_SONOS_API_PID"
  DISCOVERY_SONOS_API_PID=""
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

  if [[ "$ENABLE_ADD_CURRENT" == "1" || "$ENABLE_SONOS_HTTP_API" == "1" || "$ENABLE_SONIFY_SERVE" == "1" || "$ENABLE_WEATHER_DASHBOARD" == "1" ]]; then
    need_node="1"
    required_packages+=(nodejs npm)
  fi

  if [[ "$ENABLE_SPOTIFY_DISPLAY" == "1" ]]; then
    required_packages+=(python3-venv)
    optional_packages+=(unclutter wlr-randr)
  fi

  install_apt_packages required "${required_packages[@]}" || required_ok="0"
  install_apt_packages optional "${optional_packages[@]}" || true

  ensure_command_available curl || required_ok="0"
  ensure_command_available python3 || required_ok="0"

  if [[ "$need_node" == "1" ]]; then
    ensure_command_available node || required_ok="0"
    ensure_command_available npm || required_ok="0"
  fi

  if [[ "$ENABLE_SPOTIFY_DISPLAY" == "1" ]]; then
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

is_all_playlist_dedupe_value() {
  local raw
  raw="$(spainify_to_lower "$(spainify_trim "${1:-}")")"
  case "$raw" in
    all|full|entire|none|0) return 0 ;;
    *) return 1 ;;
  esac
}

sanitize_dedupe_window_value() {
  local raw
  local fallback="${2:-750}"
  local trimmed
  trimmed="$(spainify_trim "${1:-}")"
  raw="$(spainify_to_lower "$trimmed")"

  if [[ -z "$trimmed" ]]; then
    printf '%s' "$fallback"
    return
  fi

  if is_all_playlist_dedupe_value "$trimmed"; then
    printf 'all'
    return
  fi

  if [[ "$raw" =~ ^[0-9]+$ ]] && (( raw >= 1 )); then
    printf '%s' "$raw"
    return
  fi

  printf '%s' "$fallback"
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

  echo "Spotify app setup (for add-current):"
  echo "  Dashboard: https://developer.spotify.com/dashboard"
  echo "  Add these Redirect URI values in your Spotify app settings:"
  echo "    - http://127.0.0.1:8888/callback"
  if [[ -n "$host_ip" ]]; then
    echo "    - http://$host_ip:8888/callback"
  fi
  echo "  Note: Spotify may flag local HTTP callbacks as 'not secure';"
  echo "        use loopback IPs (127.0.0.1 / [::1]) instead of localhost."
  echo "  Setup can launch Spotify login and capture refresh token automatically."
}

start_spotify_auth_helper() {
  local client_id="$1"
  local client_secret="$2"
  local auth_dir="$ROOT_DIR/apps/add-current"
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
    echo "Could not find add-current auth helper: $auth_dir/auth.js"
    return 1
  fi

  cleanup_setup_helpers
  SPOTIFY_AUTH_TOKEN_FILE="$(mktemp)"
  (
    cd "$auth_dir" && \
    SPOTIFY_CLIENT_ID="$client_id" \
    SPOTIFY_CLIENT_SECRET="$client_secret" \
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

echo
echo "==> Checking system package prerequisites..."
ensure_setup_prerequisites

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
  print_spotify_setup_help
  echo
  ADD_CURRENT_CLIENT_ID="$(prompt_text "Spotify client ID" "$ADD_CURRENT_CLIENT_ID")"
  ADD_CURRENT_CLIENT_SECRET="$(prompt_text "Spotify client secret" "$ADD_CURRENT_CLIENT_SECRET")"
  if [[ -n "$ADD_CURRENT_CLIENT_ID" && -n "$ADD_CURRENT_CLIENT_SECRET" ]]; then
    fetch_token_now_default="0"
    if [[ -z "$ADD_CURRENT_REFRESH_TOKEN" ]]; then
      fetch_token_now_default="1"
    fi
    fetch_token_now="$(prompt_yes_no "Automatically fetch Spotify refresh token now?" "$fetch_token_now_default")"
    if [[ "$fetch_token_now" == "1" ]]; then
      if start_spotify_auth_helper "$ADD_CURRENT_CLIENT_ID" "$ADD_CURRENT_CLIENT_SECRET"; then
        spotify_login_host="$(first_ipv4_address)"
        if [[ -z "$spotify_login_host" ]]; then
          spotify_login_host="127.0.0.1"
        fi
        echo
        echo "Open this URL in a browser and approve Spotify access:"
        echo "  http://$spotify_login_host:8888/login"
        echo "Waiting for callback to capture refresh token (up to 5 minutes)..."
        fetched_refresh_token="$(wait_for_spotify_refresh_token 300 || true)"
        if [[ -n "$fetched_refresh_token" ]]; then
          ADD_CURRENT_REFRESH_TOKEN="$fetched_refresh_token"
          echo "Refresh token captured automatically."
        else
          echo "Timed out waiting for Spotify callback. You can paste token manually."
        fi
      fi
      cleanup_setup_helpers
    fi
  fi
  ADD_CURRENT_REFRESH_TOKEN="$(prompt_text "Spotify refresh token" "$ADD_CURRENT_REFRESH_TOKEN")"
  add_current_playlist_input="$(prompt_text "Spotify playlist link or ID (example: https://open.spotify.com/playlist/3kQGrwA1LHaM2tt4qqfC2Y)" "$ADD_CURRENT_PLAYLIST_ID")"
  ADD_CURRENT_PLAYLIST_ID="$(normalize_spotify_playlist_id "$add_current_playlist_input")"

  if [[ "$ADD_CURRENT_PLAYLIST_ID" != "$add_current_playlist_input" && -n "$ADD_CURRENT_PLAYLIST_ID" ]]; then
    echo "Using playlist ID: $ADD_CURRENT_PLAYLIST_ID"
  fi

  if [[ -z "$ADD_CURRENT_SONOS_HTTP_BASE" ]]; then
    ADD_CURRENT_SONOS_HTTP_BASE="http://127.0.0.1:5005"
  fi
  if [[ -z "$ADD_CURRENT_PREFERRED_ROOM" ]]; then
    ADD_CURRENT_PREFERRED_ROOM="$SONOS_ROOM_VALUE"
  fi

  dedupe_all_default="0"
  if is_all_playlist_dedupe_value "$ADD_CURRENT_DEDUPE_WINDOW"; then
    dedupe_all_default="1"
  fi
  dedupe_all_playlist="$(prompt_yes_no "Check entire playlist for duplicates?" "$dedupe_all_default")"
  if [[ "$dedupe_all_playlist" == "1" ]]; then
    ADD_CURRENT_DEDUPE_WINDOW="all"
  else
    ADD_CURRENT_DEDUPE_WINDOW="$(sanitize_dedupe_window_value "$ADD_CURRENT_DEDUPE_WINDOW" "750")"
  fi

  configure_add_current_advanced="$(prompt_yes_no "Configure advanced add-current options?" "0")"
  if [[ "$configure_add_current_advanced" == "1" ]]; then
    ADD_CURRENT_SONOS_HTTP_BASE="$(prompt_required_text "Sonos HTTP base URL" "$ADD_CURRENT_SONOS_HTTP_BASE")"
    ADD_CURRENT_PREFERRED_ROOM="$(prompt_text "Preferred Sonos room (optional)" "$ADD_CURRENT_PREFERRED_ROOM")"
    if [[ "$dedupe_all_playlist" != "1" ]]; then
      ADD_CURRENT_DEDUPE_WINDOW="$(prompt_text "De-dupe window size" "$ADD_CURRENT_DEDUPE_WINDOW")"
      ADD_CURRENT_DEDUPE_WINDOW="$(sanitize_dedupe_window_value "$ADD_CURRENT_DEDUPE_WINDOW" "750")"
    fi
  fi

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
