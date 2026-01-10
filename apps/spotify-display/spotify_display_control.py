import os
import time
import logging
import datetime
import pytz
import requests
import subprocess
import signal
import shutil
import json

# Timezone setup
eastern = pytz.timezone('US/Eastern')

# Configure logging
logging.basicConfig(level=logging.INFO)

# Chromium user data directory
CHROMIUM_USER_DATA_SONIFY = '/home/aspain/spainify/apps/spotify-display/chromium_sonify'

# URLs for displays
SONIFY_URL = "http://localhost:5000"
WEATHER_URL = "http://localhost:3000"

# Weather display hours (7 AM to 9 AM)
WEATHER_START_HOUR = 7
WEATHER_END_HOUR = 9

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

def sanitize_chromium_profile(user_data_dir):
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


SONOS_ROOM = os.getenv("SONOS_ROOM", "Living Room")


def sonos_is_playing(room=SONOS_ROOM, grace_seconds=5):
    zones = requests.get("http://localhost:5005/zones", timeout=3).json()

    # find the zone group that has our target room as a member
    grp = next((z for z in zones if any(m["roomName"] == room for m in z["members"])), None)
    if not grp:
        return False

    # is any member actually playing a track?
    now = time.monotonic()
    playing = False
    for m in grp["members"]:
        st = m["state"]
        if st["playbackState"] in ("PLAYING","TRANSITIONING") \
           and st["currentTrack"].get("type") == "track" \
           and st["currentTrack"].get("title"):
            playing = True
            sonos_is_playing._last_true = now
            break

    return playing or (now - getattr(sonos_is_playing, "_last_true", 0)) < grace_seconds


def turn_display_on():
    result = os.system('vcgencmd display_power 1')
    logging.info(f"Display turned ON, command result: {result}")

def turn_display_off():
    result = os.system('vcgencmd display_power 0')
    logging.info(f"Display turned OFF, command result: {result}")

def kill_chromium(chromium_process):
    """Terminate the Chromium process group."""
    if chromium_process:
        try:
            os.killpg(os.getpgid(chromium_process.pid), signal.SIGTERM)
            time.sleep(2)  # Allow graceful termination
            os.killpg(os.getpgid(chromium_process.pid), signal.SIGKILL)
            logging.info("Chromium process group has been terminated.")
        except ProcessLookupError:
            logging.warning("Chromium process group already terminated.")
        except Exception as e:
            logging.exception("Error terminating Chromium process group.")

def launch_chromium(url, user_data_dir, scale_factor=None, hide_scrollbars=False):
    sanitize_chromium_profile(user_data_dir)
    """Launch Chromium in full-screen mode with custom options."""
    args = [
        "chromium-browser",
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
    display_on = True  # Assume the display is initially on
    browser_url = None  # Tracks current mode: 'sonify' or 'weather'
    chromium_process = None

    while True:
        try:
            now = datetime.datetime.now(eastern)
            current_hour = now.hour

            if sonos_is_playing():
                logging.info("Music is playing on Sonos.")
                if not display_on or browser_url != 'sonify':
                    logging.info("Switching to Sonify display.")
                    kill_chromium(chromium_process)
                    chromium_process = launch_chromium(SONIFY_URL, CHROMIUM_USER_DATA_SONIFY, scale_factor=0.8)
                    browser_url = 'sonify'
                    if not display_on:
                        turn_display_on()
                        display_on = True
            else:
                # Nothing is playing on Sonos
                if WEATHER_START_HOUR <= current_hour < WEATHER_END_HOUR:
                    # Within weather display hours; show weather dashboard
                    if not display_on or browser_url != 'weather':
                        logging.info("Displaying Weather Dashboard.")
                        kill_chromium(chromium_process)
                        chromium_process = launch_chromium(WEATHER_URL, CHROMIUM_USER_DATA_SONIFY, hide_scrollbars=True)
                        browser_url = 'weather'
                        if not display_on:
                            turn_display_on()
                            display_on = True
                else:
                    # Outside weather hours; ensure display is off
                    if display_on:
                        logging.info("No content to display; turning off display.")
                        turn_display_off()
                        display_on = False
                    if browser_url is not None:
                        logging.info("Closing browser.")
                        kill_chromium(chromium_process)
                        chromium_process = None
                        browser_url = None

            # Optionally clean user data directories every hour
            if now.minute == 0 and now.second < 15:
                logging.info("Cleaning user data directories.")
                clean_user_data_dir(CHROMIUM_USER_DATA_SONIFY)

        except Exception as e:
            logging.exception("An error occurred during display check.")
        time.sleep(15)

if __name__ == '__main__':
    main()
