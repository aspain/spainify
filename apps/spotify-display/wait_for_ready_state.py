import os
import socket
import stat
import sys
import time

POLL_INTERVAL_SECONDS = 1.0
DEFAULT_TIMEOUT_SECONDS = 90


def _parse_display_socket_path(display_value):
    if not display_value:
        return None

    # Typical values are ':0' or ':0.0'.
    if display_value.startswith(":"):
        display_number = display_value[1:].split(".", 1)[0]
        if display_number.isdigit():
            return f"/tmp/.X11-unix/X{display_number}"
    return None


def _is_unix_socket(path):
    try:
        st_mode = os.stat(path).st_mode
    except FileNotFoundError:
        return False
    except OSError:
        return False
    return stat.S_ISSOCK(st_mode)


def _port_is_open(host, port, timeout=0.5):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect((host, port))
        return True
    except OSError:
        return False
    finally:
        sock.close()


def main():
    timeout_seconds = int(os.getenv("STARTUP_READY_TIMEOUT_SECONDS", str(DEFAULT_TIMEOUT_SECONDS)))
    deadline = time.monotonic() + timeout_seconds

    display_socket = _parse_display_socket_path(os.getenv("DISPLAY", ":0"))

    while time.monotonic() < deadline:
        missing = []

        if display_socket and not _is_unix_socket(display_socket):
            missing.append(f"X display socket {display_socket}")

        if not _port_is_open("127.0.0.1", 3000):
            missing.append("weather dashboard port 3000")

        if not _port_is_open("127.0.0.1", 5000):
            missing.append("sonify port 5000")

        if not missing:
            print("Startup readiness checks passed.")
            return 0

        print("Waiting for startup readiness: " + ", ".join(missing))
        time.sleep(POLL_INTERVAL_SECONDS)

    print(
        f"Startup readiness checks timed out after {timeout_seconds}s.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
