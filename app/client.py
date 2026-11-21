"""
File client for the DevOps capstone project.

The client:
  1. connects to the server (SERVER_HOST:SERVER_PORT)
  2. reads a one-line JSON header (filename, size, checksum) and then the file bytes
  3. saves the file into DATA_DIR (/clientdata)
  4. recomputes the SHA-256 checksum and compares it with the one sent by the server

If FETCH_INTERVAL_SECONDS > 0 the client repeats this forever (useful for monitoring);
if it is 0 the client fetches once and exits with 0 (verified) or 1 (failed).
"""

import hashlib
import json
import logging
import os
import socket
import sys
import time

SERVER_HOST = os.getenv("SERVER_HOST", "localhost")
SERVER_PORT = int(os.getenv("SERVER_PORT", "5000"))
DATA_DIR = os.getenv("DATA_DIR", "/clientdata")
FETCH_INTERVAL = int(os.getenv("FETCH_INTERVAL_SECONDS", "60"))
CONNECT_RETRIES = int(os.getenv("CONNECT_RETRIES", "10"))
RETRY_DELAY = int(os.getenv("RETRY_DELAY_SECONDS", "3"))
SOCKET_TIMEOUT = int(os.getenv("SOCKET_TIMEOUT_SECONDS", "10"))
MAX_FILE_SIZE = 10 * 1024 * 1024  # refuse anything unreasonably large

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [client] %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger(__name__)


def connect() -> socket.socket:
    """Connect to the server, retrying while it may still be starting up."""
    for attempt in range(1, CONNECT_RETRIES + 1):
        try:
            sock = socket.create_connection((SERVER_HOST, SERVER_PORT), timeout=SOCKET_TIMEOUT)
            log.info("Connected to %s:%d", SERVER_HOST, SERVER_PORT)
            return sock
        except OSError as exc:
            log.warning(
                "Connection attempt %d/%d to %s:%d failed: %s",
                attempt, CONNECT_RETRIES, SERVER_HOST, SERVER_PORT, exc,
            )
            time.sleep(RETRY_DELAY)
    raise ConnectionError(f"Could not connect to {SERVER_HOST}:{SERVER_PORT}")


def read_header(stream) -> dict:
    line = stream.readline(4096)
    if not line.endswith(b"\n"):
        raise ValueError("Malformed or missing header from server")
    header = json.loads(line.decode("utf-8"))
    for key in ("filename", "size", "checksum"):
        if key not in header:
            raise ValueError(f"Header is missing '{key}'")
    if not 0 <= int(header["size"]) <= MAX_FILE_SIZE:
        raise ValueError(f"Invalid file size {header['size']}")
    return header


def read_exact(stream, size: int) -> bytes:
    data = stream.read(size)
    if data is None or len(data) != size:
        got = 0 if data is None else len(data)
        raise ValueError(f"Expected {size} bytes but received {got}")
    return data


def fetch_once() -> bool:
    """Fetch one file from the server. Returns True if the checksum matched."""
    with connect() as sock, sock.makefile("rb") as stream:
        header = read_header(stream)
        payload = read_exact(stream, int(header["size"]))

    # Never trust a path from the network: keep only the base name.
    filename = os.path.basename(header["filename"]) or "received_file.txt"
    os.makedirs(DATA_DIR, exist_ok=True)
    path = os.path.join(DATA_DIR, filename)
    with open(path, "wb") as f:
        f.write(payload)

    # Verify integrity by hashing the file as it was written to disk.
    with open(path, "rb") as f:
        actual = hashlib.sha256(f.read()).hexdigest()
    expected = header["checksum"]

    if actual == expected:
        log.info("Saved %s (%d bytes). Checksum VERIFIED: %s", path, len(payload), actual)
        return True

    log.error("Saved %s but checksum MISMATCH: expected=%s actual=%s", path, expected, actual)
    return False


def main() -> None:
    log.info(
        "Starting client: server=%s:%d data_dir=%s interval=%ss",
        SERVER_HOST, SERVER_PORT, DATA_DIR, FETCH_INTERVAL,
    )

    if FETCH_INTERVAL <= 0:
        try:
            ok = fetch_once()
        except Exception:
            log.exception("Transfer failed")
            ok = False
        sys.exit(0 if ok else 1)

    while True:
        try:
            fetch_once()
        except Exception:
            log.exception("Transfer failed, will retry in %ss", FETCH_INTERVAL)
        time.sleep(FETCH_INTERVAL)


if __name__ == "__main__":
    main()
