#!/usr/bin/env python3
"""Smoke test for the Folio Zed single-instance check.

Usage: single_instance_smoke_test.py <Folio Zed.app | Folio-Zed.dmg>

Case 1: a vanilla Zed holds its port. Folio Zed must start, not hand off to it.
Case 2: a Folio Zed holds the Folio port. A second Folio Zed must hand off and exit.
"""

import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

BASE_PORT = 43737
USER_BLOCK = 100
STABLE_OFFSET = 2 * USER_BLOCK
FOLIO_PORT_OFFSET = 4 * USER_BLOCK
VANILLA_HANDSHAKE = b"Zed Editor Stable Instance Running"
FOLIO_HANDSHAKE = b"Folio Zed Stable Instance Running"
ALREADY_RUNNING = "zed is already running"


def user_port(port):
    max_uid = 0xFFFF - port
    return port + (os.getuid() % max_uid)


VANILLA_PORT = user_port(BASE_PORT + STABLE_OFFSET)
FOLIO_PORT = user_port(BASE_PORT + STABLE_OFFSET + FOLIO_PORT_OFFSET)


def read_handshake(port, length, timeout=0.5):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout) as conn:
            conn.settimeout(timeout)
            data = b""
            while len(data) < length:
                chunk = conn.recv(length - len(data))
                if not chunk:
                    break
                data += chunk
            return data
    except OSError:
        return None


class FakeInstance:
    """Answers every connection on `port` with `handshake`, like a running Zed."""

    def __init__(self, port, handshake):
        self.port = port
        self.handshake = handshake
        self.server = None

    def __enter__(self):
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            server.bind(("127.0.0.1", self.port))
        except OSError:
            server.close()
            if read_handshake(self.port, len(self.handshake)) == self.handshake:
                return self
            raise RuntimeError(f"port {self.port} is held by something that is not a matching Zed")
        server.listen()
        self.server = server
        threading.Thread(target=self._serve, daemon=True).start()
        return self

    def _serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            with conn:
                conn.sendall(self.handshake)

    def __exit__(self, *exc):
        if self.server:
            self.server.close()


def launch(binary, home):
    env = dict(os.environ, HOME=home, RUST_LOG="info")
    env.pop("ZED_STATELESS", None)
    return subprocess.Popen(
        [binary],
        cwd=home,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )


def stop(proc):
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGKILL)
    output, _ = proc.communicate(timeout=10)
    return output or ""


def case_runs_next_to_vanilla_zed(binary, home):
    with FakeInstance(VANILLA_PORT, VANILLA_HANDSHAKE):
        proc = launch(binary, home)
        handshake = None
        deadline = time.time() + 20
        while time.time() < deadline and proc.poll() is None:
            handshake = read_handshake(FOLIO_PORT, len(FOLIO_HANDSHAKE))
            if handshake == FOLIO_HANDSHAKE:
                break
            time.sleep(0.02)
        if handshake == FOLIO_HANDSHAKE:
            # Verify Folio Zed stays alive past settings::init / GPUI startup
            # when launched outside a source checkout (cwd=home).
            time.sleep(1.5)
        early_exit = proc.poll()
        output = stop(proc)
    if ALREADY_RUNNING in output:
        return f"Folio Zed handed its launch to vanilla Zed on port {VANILLA_PORT}:\n{output}"
    if handshake != FOLIO_HANDSHAKE:
        return f"Folio Zed did not answer on port {FOLIO_PORT} (got {handshake!r}):\n{output}"
    if early_exit is not None or "panicked at" in output:
        return (
            f"Folio Zed crashed during startup after binding port {FOLIO_PORT} "
            f"(exit={early_exit}):\n{output}"
        )
    return None


def case_hands_off_to_running_folio_zed(binary, home):
    with FakeInstance(FOLIO_PORT, FOLIO_HANDSHAKE):
        proc = launch(binary, home)
        try:
            proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            pass
        output = stop(proc)
    if ALREADY_RUNNING not in output:
        return f"A second Folio Zed did not hand off to the running one on port {FOLIO_PORT}:\n{output}"
    return None


def resolve_binary(path, stack):
    if path.endswith(".dmg"):
        mount = tempfile.mkdtemp(prefix="folio-zed-dmg-")
        subprocess.run(
            ["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mount, path],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        stack.append(lambda: subprocess.run(["hdiutil", "detach", "-force", mount], check=False))
        path = os.path.join(mount, "Folio Zed.app")
    return os.path.join(path, "Contents", "MacOS", "zed")


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    cleanups = []
    failures = []
    try:
        binary = resolve_binary(sys.argv[1], cleanups)
        for case in (case_runs_next_to_vanilla_zed, case_hands_off_to_running_folio_zed):
            with tempfile.TemporaryDirectory(prefix="folio-zed-home-") as home:
                error = case(binary, home)
            print(f"{'FAIL' if error else 'PASS'}: {case.__name__}", flush=True)
            if error:
                failures.append(error)
    finally:
        for cleanup in reversed(cleanups):
            cleanup()
    for error in failures:
        print(error, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
