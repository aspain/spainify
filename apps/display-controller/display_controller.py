import os
import re
import time
import logging
import datetime
import requests
import subprocess
import signal
import shutil
import json

# Configure logging
logging.basicConfig(level=logging.INFO)

# Sonos HTTP session
SONOS_SESSION = requests.Session()

# Chromium user data directory
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CHROMIUM_USER_DATA_SONIFY = os.path.join(SCRIPT_DIR, "chromium_sonify")
LAST_SANITIZE_FILENAME = "last_sanitize"
NEEDS_SANITIZE_FILENAME = "needs_sanitize"

# URLs for displays
SONIFY_URL = "http://localhost:5000"
WEATHER_URL = "http://localhost:3000"

DEFAULT_WEATHER_START_MINUTES = 7 * 60
DEFAULT_WEATHER_END_MINUTES = 9 * 60


def _env_bool(name, default=False):
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _minutes_to_hhmm(minutes):
    hour = minutes // 60
    minute = minutes % 60
    return f"{hour:02d}:{minute:02d}"


def _parse_clock_time_to_minutes(value, default_minutes, env_name):
    raw = (value or "").strip()
    normalized = raw.lower().replace(" ", "").replace(".", "")
    match = re.fullmatch(r"(\d{1,2})(?::(\d{1,2}))?(a|am|p|pm)?", normalized)
    if not match:
        logging.warning(
            "Invalid %s=%r; using %s.",
            env_name,
            raw,
            _minutes_to_hhmm(default_minutes),
        )
        return default_minutes

    hour = int(match.group(1))
    minute = int(match.group(2) or 0)
    suffix = match.group(3) or ""
    if minute > 59:
        logging.warning(
            "Invalid %s=%r; using %s.",
            env_name,
            raw,
            _minutes_to_hhmm(default_minutes),
        )
        return default_minutes

    if suffix:
        if hour < 1 or hour > 12:
            logging.warning(
                "Invalid %s=%r; using %s.",
                env_name,
                raw,
                _minutes_to_hhmm(default_minutes),
            )
            return default_minutes
        if suffix in {"a", "am"}:
            hour = 0 if hour == 12 else hour
        else:
            hour = 12 if hour == 12 else hour + 12
    elif hour > 23:
        logging.warning(
            "Invalid %s=%r; using %s.",
            env_name,
            raw,
            _minutes_to_hhmm(default_minutes),
        )
        return default_minutes

    return hour * 60 + minute


def _is_within_daily_window(now_minutes, start_minutes, end_minutes):
    if start_minutes == end_minutes:
        return False
    if start_minutes < end_minutes:
        return start_minutes <= now_minutes < end_minutes
    return now_minutes >= start_minutes or now_minutes < end_minutes


HIDE_CURSOR_WHILE_DISPLAYING = _env_bool("HIDE_CURSOR_WHILE_DISPLAYING", True)
DEFAULT_CURSOR_IDLE_SECONDS = 0.1
ENABLE_WEATHER_DASHBOARD = _env_bool("ENABLE_WEATHER_DASHBOARD", True)
DISPLAY_OUTPUT_NAME = os.getenv("DISPLAY_OUTPUT_NAME", "HDMI-A-1")
WEATHER_DISPLAY_START_MINUTES = _parse_clock_time_to_minutes(
    os.getenv("WEATHER_DISPLAY_START", "07:00"),
    DEFAULT_WEATHER_START_MINUTES,
    "WEATHER_DISPLAY_START",
)
WEATHER_DISPLAY_END_MINUTES = _parse_clock_time_to_minutes(
    os.getenv("WEATHER_DISPLAY_END", "09:00"),
    DEFAULT_WEATHER_END_MINUTES,
    "WEATHER_DISPLAY_END",
)
logging.info(
    "Weather display window %s -> %s.",
    _minutes_to_hhmm(WEATHER_DISPLAY_START_MINUTES),
    _minutes_to_hhmm(WEATHER_DISPLAY_END_MINUTES),
)
if WEATHER_DISPLAY_START_MINUTES == WEATHER_DISPLAY_END_MINUTES:
    logging.warning(
        "Weather display start and end are the same; weather dashboard display window is disabled."
    )


def resolve_chromium_command():
    configured = os.getenv("CHROMIUM_BIN", "").strip()
    candidates = []
    if configured:
        candidates.append(configured)
    candidates.extend(["chromium-browser", "chromium"])

    for candidate in candidates:
        if shutil.which(candidate):
            return candidate
    return None


CHROMIUM_COMMAND = resolve_chromium_command()


def _patch_json(path):
    try:
        with open(path, "r+", encoding="utf-8") as f:
            data = json.load(f)

            def mark_clean(d):
                if isinstance(d, dict):
                    if "exited_cleanly" in d:
                        d["exited_cleanly"] = True
                    if "exit_type" in d:
                        d["exit_type"] = "Normal"
                    for v in d.values():
                        mark_clean(v)

            mark_clean(data)
            f.seek(0); f.truncate()
            json.dump(data, f)
    except FileNotFoundError:
        pass
    except Exception:
        logging.exception(f"Failed to patch {path}")

def sanitize_chromium_profile(user_data_dir, force_sanitize=False):
    last_sanitize_path = os.path.join(user_data_dir, LAST_SANITIZE_FILENAME)
    needs_sanitize_path = os.path.join(user_data_dir, NEEDS_SANITIZE_FILENAME)

    try:
        os.makedirs(user_data_dir, exist_ok=True)
    except Exception:
        logging.exception(f"Failed to ensure user data dir {user_data_dir}")
        return

    exited_cleanly = _read_exited_cleanly(user_data_dir)
    needs_sanitize = os.path.exists(needs_sanitize_path)

    if exited_cleanly is not False and not needs_sanitize and not force_sanitize:
        return

    # fix flags that trigger the restore bubble
    _patch_json(os.path.join(user_data_dir, "Local State"))
    _patch_json(os.path.join(user_data_dir, "Default", "Preferences"))

    # delete session artifacts that can prompt restore
    for rel in [
        "Default/Current Session",
        "Default/Last Session",
        "Default/Session Storage",
        "Default/Sessions",              # some builds use this dir
    ]:
        p = os.path.join(user_data_dir, rel)
        try:
            if os.path.isdir(p):
                shutil.rmtree(p)
            elif os.path.isfile(p):
                os.remove(p)
        except Exception:
            logging.exception(f"Failed to remove {p}")
    _mark_sanitized(last_sanitize_path, needs_sanitize_path)


def _read_exited_cleanly(user_data_dir):
    local_state_path = os.path.join(user_data_dir, "Local State")
    try:
        with open(local_state_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data.get("profile", {}).get("exit_type") == "Normal" and data.get(
            "profile", {}
        ).get("exited_cleanly", True)
    except FileNotFoundError:
        return True
    except Exception:
        logging.exception(f"Failed to read {local_state_path}")
        return False


def _mark_sanitized(last_sanitize_path, needs_sanitize_path):
    try:
        with open(last_sanitize_path, "w", encoding="utf-8") as f:
            f.write(str(time.time()))
        if os.path.exists(needs_sanitize_path):
            os.remove(needs_sanitize_path)
    except Exception:
        logging.exception("Failed to update sanitize markers.")


SONOS_ROOM = os.getenv("SONOS_ROOM", "").strip()
if not SONOS_ROOM:
    logging.warning(
        "SONOS_ROOM is not configured; Sonos playback detection is disabled until setup provides a room."
    )


def sonos_is_playing(
    room=SONOS_ROOM,
    grace_seconds=5,
    transition_hold_seconds=20,
    force_refresh=False,
    cache_seconds=5,
):
    now = time.time()
    cached_zones = getattr(sonos_is_playing, "_last_zones", None)
    cached_ts = getattr(sonos_is_playing, "_last_zones_ts", 0)
    if not force_refresh and cached_zones is not None and (now - cached_ts) < cache_seconds:
        zones = cached_zones
    else:
        try:
            zones = SONOS_SESSION.get("http://localhost:5005/zones", timeout=3).json()
            if not isinstance(zones, list):
                logging.warning("Unexpected Sonos zones payload type: %s", type(zones).__name__)
                zones = []
            sonos_is_playing._last_zones = zones
            sonos_is_playing._last_zones_ts = now
        except (requests.RequestException, ValueError) as exc:
            logging.warning("Sonos zones request failed: %s", exc)
            if cached_zones is None:
                return False
            zones = cached_zones

    # find the zone group that has our target room as a member
    grp = None
    for zone in zones:
        if not isinstance(zone, dict):
            continue
        members = zone.get("members")
        if not isinstance(members, list):
            continue
        if any(isinstance(m, dict) and m.get("roomName") == room for m in members):
            grp = zone
            break

    if not grp:
        return False

    # Wake the display only on active PLAYING state.
    # TRANSITIONING is used only as a short hold after recent real playback
    # so track boundaries don't briefly blank the display.
    def _transport_state(state_dict):
        if not isinstance(state_dict, dict):
            return ""
        # Prefer zone-level transport state because player-level state can
        # remain PLAYING during paused handoff/connect scenarios.
        for key in ("zoneState", "playbackState", "playerState"):
            raw = state_dict.get(key)
            if isinstance(raw, str) and raw.strip():
                return raw.strip().upper()
        return ""

    now = time.monotonic()
    playing = False
    transitioning = False
    members = grp.get("members") if isinstance(grp, dict) else None
    if not isinstance(members, list):
        members = []

    coordinator = next(
        (m for m in members if isinstance(m, dict) and m.get("coordinator")), None
    )
    members_to_check = [coordinator] if coordinator else members

    for m in members_to_check:
        if not isinstance(m, dict):
            continue
        st = m.get("state")
        if not isinstance(st, dict):
            continue
        current_track = st.get("currentTrack")
        if not isinstance(current_track, dict):
            current_track = {}

        state = _transport_state(st)
        has_track = current_track.get("type") == "track" and current_track.get("title")

        if state == "PLAYING" and has_track:
            playing = True
            sonos_is_playing._last_true = now
            break
        if state == "TRANSITIONING" and has_track:
            transitioning = True

    last_true_age = now - getattr(sonos_is_playing, "_last_true", 0)
    recent_true = last_true_age < grace_seconds
    transition_hold = transitioning and last_true_age < transition_hold_seconds
    return playing or recent_true or transition_hold


def get_display_power_state(default=True):
    wayland_state = get_wayland_display_power_state()
    if wayland_state is not None:
        return wayland_state

    if shutil.which("vcgencmd") is None:
        return default
    try:
        result = subprocess.run(
            ["vcgencmd", "display_power"],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
        if result.returncode != 0:
            logging.warning("Failed to read display power state (exit %s).", result.returncode)
            return default

        output = result.stdout.strip()
        if output.endswith("=1"):
            return True
        if output.endswith("=0"):
            return False

        logging.warning("Unexpected display power output: %s", output)
    except Exception:
        logging.exception("Failed to read display power state.")
    return default


def _parse_wlr_output_enabled(wlr_output, output_name):
    current_output = None
    for raw_line in (wlr_output or "").splitlines():
        line = raw_line.rstrip()
        if not line:
            continue

        if not line.startswith(" "):
            current_output = line.split(" ", 1)[0].strip('"')
            continue

        if current_output != output_name:
            continue

        match = re.search(r"Enabled:\s*(yes|no)\s*$", line.strip(), flags=re.IGNORECASE)
        if match:
            return match.group(1).lower() == "yes"

    return None


def get_wayland_display_power_state():
    if shutil.which("wlr-randr") is None:
        return None

    for env_updates in _wayland_env_candidates():
        try:
            result = _run_command(["wlr-randr"], env_updates=env_updates)
        except Exception:
            continue

        if result.returncode != 0:
            continue

        enabled = _parse_wlr_output_enabled(result.stdout, DISPLAY_OUTPUT_NAME)
        if enabled is not None:
            return enabled

    return None


def _wayland_env_candidates():
    candidates = []
    configured_runtime = os.getenv("XDG_RUNTIME_DIR", "")
    configured_display = os.getenv("WAYLAND_DISPLAY", "")
    if configured_runtime and configured_display:
        candidates.append(
            {"XDG_RUNTIME_DIR": configured_runtime, "WAYLAND_DISPLAY": configured_display}
        )

    runtime_dir = f"/run/user/{os.getuid()}"
    if os.path.isdir(runtime_dir):
        for wayland_display in ("wayland-0", "wayland-1"):
            if os.path.exists(os.path.join(runtime_dir, wayland_display)):
                candidate = {
                    "XDG_RUNTIME_DIR": runtime_dir,
                    "WAYLAND_DISPLAY": wayland_display,
                }
                if candidate not in candidates:
                    candidates.append(candidate)

    return candidates


def _run_command(args, env_updates=None):
    env = os.environ.copy()
    if env_updates:
        env.update(env_updates)

    return subprocess.run(
        args,
        capture_output=True,
        text=True,
        timeout=4,
        check=False,
        env=env,
    )


def _apply_display_power_fallback(target_on):
    target_text = "on" if target_on else "off"
    wayland_candidates = _wayland_env_candidates()

    if shutil.which("wlr-randr") and wayland_candidates:
        for env_updates in wayland_candidates:
            probe_result = _run_command(["wlr-randr"], env_updates=env_updates)
            candidate_outputs = [DISPLAY_OUTPUT_NAME]
            if probe_result.returncode == 0:
                for line in (probe_result.stdout or "").splitlines():
                    if not line or line.startswith(" "):
                        continue
                    name = line.split(" ", 1)[0].strip('"')
                    if name and name not in candidate_outputs:
                        candidate_outputs.append(name)

            for output_name in candidate_outputs:
                cmd = [
                    "wlr-randr",
                    "--output",
                    output_name,
                    "--on" if target_on else "--off",
                ]
                try:
                    result = _run_command(cmd, env_updates=env_updates)
                    if result.returncode == 0:
                        logging.info(
                            "Display fallback via wlr-randr %s succeeded (%s, output=%s).",
                            target_text,
                            env_updates.get("WAYLAND_DISPLAY", "unknown"),
                            output_name,
                        )
                        return True
                except Exception:
                    logging.exception("Display fallback via wlr-randr failed.")

    # Only use xset when Wayland control is unavailable.
    if not wayland_candidates and shutil.which("xset"):
        display = os.getenv("DISPLAY", ":0")
        cmd = ["xset", "-display", display, "dpms", "force", target_text]
        try:
            result = _run_command(cmd)
            if result.returncode == 0:
                logging.info("Display fallback via xset %s succeeded.", target_text)
                return True
        except Exception:
            logging.exception("Display fallback via xset failed.")

    return False


def set_display_power(target_on):
    target_value = "1" if target_on else "0"
    target_name = "ON" if target_on else "OFF"
    fallback_used = False

    if shutil.which("vcgencmd"):
        try:
            result = _run_command(["vcgencmd", "display_power", target_value])
            logging.info("display_power set %s command exit=%s", target_name, result.returncode)
        except Exception:
            logging.exception("Failed to invoke vcgencmd display_power %s.", target_value)
    else:
        logging.warning("vcgencmd is unavailable; using fallback display control.")

    time.sleep(0.3)
    current_state = get_display_power_state(default=target_on)
    if current_state == target_on:
        return current_state

    logging.warning(
        "Display state mismatch after vcgencmd (wanted %s, current=%s). Trying fallback.",
        target_name,
        "ON" if current_state else "OFF",
    )
    fallback_used = _apply_display_power_fallback(target_on)
    if fallback_used:
        time.sleep(0.3)
        current_state = get_display_power_state(default=target_on)
        if current_state != target_on:
            # Some stacks keep vcgencmd pinned to ON even when Wayland output control works.
            # If fallback command succeeded but state probing is inconclusive, avoid thrashing
            # by trusting the successful fallback transition.
            wayland_state = get_wayland_display_power_state()
            if wayland_state is None:
                logging.info(
                    "Fallback command succeeded but display probe is inconclusive; "
                    "assuming display is now %s.",
                    target_name,
                )
                current_state = target_on

    if current_state != target_on and fallback_used:
        logging.warning(
            "Fallback command completed, but display state still reports %s.",
            "ON" if current_state else "OFF",
        )
    elif current_state == target_on and fallback_used:
        logging.info("Display state corrected via fallback to %s.", target_name)

    return current_state


def turn_display_on():
    return set_display_power(True)


def turn_display_off():
    return set_display_power(False)

def terminate_process_group(process, process_name):
    """Terminate a process group with TERM then KILL fallback."""
    if not process:
        return

    try:
        pgid = os.getpgid(process.pid)
        os.killpg(pgid, signal.SIGTERM)
        time.sleep(2)  # Allow graceful termination
        if process.poll() is None:
            try:
                os.killpg(pgid, 0)
            except ProcessLookupError:
                logging.info("%s process group has been terminated.", process_name)
            else:
                logging.warning(
                    "%s process group still alive after SIGTERM; sending SIGKILL.",
                    process_name,
                )
                os.killpg(pgid, signal.SIGKILL)
                logging.info("%s process group has been terminated.", process_name)
        else:
            logging.info("%s process group has been terminated.", process_name)
    except ProcessLookupError:
        logging.warning("%s process group already terminated.", process_name)
    except Exception:
        logging.exception("Error terminating %s process group.", process_name)


def kill_chromium(chromium_process):
    """Terminate the Chromium process group."""
    terminate_process_group(chromium_process, "Chromium")


def launch_cursor_hider():
    if not HIDE_CURSOR_WHILE_DISPLAYING:
        return None

    if shutil.which("unclutter") is None:
        if not getattr(launch_cursor_hider, "_warned_missing", False):
            logging.warning(
                "Cursor hiding requested but `unclutter` is not installed. "
                "Install it with: sudo apt install unclutter"
            )
            launch_cursor_hider._warned_missing = True
        return None

    idle_raw = os.getenv("HIDE_CURSOR_IDLE_SECONDS", str(DEFAULT_CURSOR_IDLE_SECONDS))
    try:
        idle_seconds = max(float(idle_raw), 0.0)
    except ValueError:
        logging.warning(
            "Invalid HIDE_CURSOR_IDLE_SECONDS=%r; using default %.2fs.",
            idle_raw,
            DEFAULT_CURSOR_IDLE_SECONDS,
        )
        idle_seconds = DEFAULT_CURSOR_IDLE_SECONDS

    args = ["unclutter", "-idle", str(idle_seconds), "-root"]
    try:
        process = subprocess.Popen(
            args,
            preexec_fn=os.setsid,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        logging.info("Cursor hider started (idle %.2fs).", idle_seconds)
        return process
    except Exception:
        logging.exception("Failed to start cursor hider.")
        return None


def kill_cursor_hider(cursor_hider_process):
    terminate_process_group(cursor_hider_process, "Cursor hider")

def launch_chromium(
    url,
    user_data_dir,
    scale_factor=None,
    hide_scrollbars=False,
    force_sanitize=False,
):
    """Launch Chromium in full-screen mode with custom options."""
    if not CHROMIUM_COMMAND:
        if not getattr(launch_chromium, "_warned_missing", False):
            logging.error(
                "No Chromium executable found. Install `chromium` (or `chromium-browser`) "
                "or set CHROMIUM_BIN to the browser binary path."
            )
            launch_chromium._warned_missing = True
        return None

    sanitize_chromium_profile(user_data_dir, force_sanitize=force_sanitize)
    args = [
        CHROMIUM_COMMAND,
        "--start-fullscreen",
        "--no-first-run",
        "--disable-translate",
        "--disable-infobars",
        "--disable-session-crashed-bubble",
        "--disable-session-restore",
        "--new-window",
        f"--user-data-dir={user_data_dir}",
        "--disk-cache-size=0"
    ]
    if scale_factor is not None:
        args.append(f"--force-device-scale-factor={scale_factor}")
    if hide_scrollbars:
        args.append("--hide-scrollbars")
    args.append(url)

    try:
        process = subprocess.Popen(args, preexec_fn=os.setsid)
        logging.info(f"Chromium launched with URL: {url} (scale factor: {scale_factor if scale_factor else 'default'}, hide_scrollbars: {hide_scrollbars})")
        return process
    except Exception as e:
        logging.exception(f"Failed to launch Chromium with URL: {url}")
        return None

def clean_user_data_dir(user_data_dir):
    """Clean parts of the user data directory to save space."""
    try:
        cache_path = os.path.join(user_data_dir, 'Default', 'Cache')
        if os.path.exists(cache_path):
            shutil.rmtree(cache_path)
            os.makedirs(cache_path)
            logging.info(f"Cache cleared for {user_data_dir}")
    except Exception as e:
        logging.exception(f"Failed to clean user data directory {user_data_dir}")

def main():
    display_on = get_display_power_state(default=False)
    last_cleanup_hour = None
    browser_url = None  # Tracks current mode: 'sonify' or 'weather'
    chromium_process = None
    cursor_hider_process = None
    last_sonos_playing = None
    sanitize_next_launch = True
    running = True

    def handle_shutdown_signal(signum, frame):
        nonlocal running
        logging.info("Received signal %s, shutting down display controller.", signum)
        running = False

    signal.signal(signal.SIGTERM, handle_shutdown_signal)
    signal.signal(signal.SIGINT, handle_shutdown_signal)

    while running:
        try:
            now = datetime.datetime.now()
            current_minutes = (now.hour * 60) + now.minute
            sonos_playing = sonos_is_playing()

            if sonos_playing != last_sonos_playing:
                if sonos_playing:
                    logging.info("Music is playing on Sonos.")
                else:
                    logging.info("No active Sonos track playback.")
                last_sonos_playing = sonos_playing

            if sonos_playing:
                if not display_on or browser_url != 'sonify':
                    logging.info("Switching to Sonify display.")
                    kill_chromium(chromium_process)
                    new_process = launch_chromium(
                        SONIFY_URL,
                        CHROMIUM_USER_DATA_SONIFY,
                        force_sanitize=sanitize_next_launch,
                    )
                    if new_process:
                        chromium_process = new_process
                        browser_url = 'sonify'
                        sanitize_next_launch = False
                        display_on = turn_display_on()
                    else:
                        chromium_process = None
                        browser_url = None
            else:
                # Nothing is playing on Sonos
                if ENABLE_WEATHER_DASHBOARD and _is_within_daily_window(
                    current_minutes,
                    WEATHER_DISPLAY_START_MINUTES,
                    WEATHER_DISPLAY_END_MINUTES,
                ):
                    # Within weather display hours; show weather dashboard
                    if not display_on or browser_url != 'weather':
                        logging.info("Displaying Weather Dashboard.")
                        kill_chromium(chromium_process)
                        new_process = launch_chromium(
                            WEATHER_URL,
                            CHROMIUM_USER_DATA_SONIFY,
                            hide_scrollbars=True,
                            force_sanitize=sanitize_next_launch,
                        )
                        if new_process:
                            chromium_process = new_process
                            browser_url = 'weather'
                            sanitize_next_launch = False
                            display_on = turn_display_on()
                        else:
                            chromium_process = None
                            browser_url = None
                else:
                    # Outside weather hours; ensure display is off
                    if display_on:
                        logging.info("No content to display; turning off display.")
                        display_on = turn_display_off()
                    if browser_url is not None:
                        logging.info("Closing browser.")
                        kill_chromium(chromium_process)
                        chromium_process = None
                        browser_url = None

            should_hide_cursor = browser_url is not None and HIDE_CURSOR_WHILE_DISPLAYING
            if should_hide_cursor:
                if cursor_hider_process is None or cursor_hider_process.poll() is not None:
                    cursor_hider_process = launch_cursor_hider()
            elif cursor_hider_process is not None:
                kill_cursor_hider(cursor_hider_process)
                cursor_hider_process = None

            # Optionally clean user data directories every hour
            if now.minute == 0 and now.second < 15 and now.hour != last_cleanup_hour:
                logging.info("Cleaning user data directories.")
                clean_user_data_dir(CHROMIUM_USER_DATA_SONIFY)
                last_cleanup_hour = now.hour

        except Exception as e:
            logging.exception("An error occurred during display check.")
        time.sleep(15)

    if chromium_process is not None:
        logging.info("Stopping Chromium before exit.")
        kill_chromium(chromium_process)
    if cursor_hider_process is not None:
        logging.info("Stopping cursor hider before exit.")
        kill_cursor_hider(cursor_hider_process)

if __name__ == '__main__':
    main()
