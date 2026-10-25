#!/usr/bin/env python3
"""Run inside a graphical Craft Apps container as its desktop user.

Opens a generated PNG in a separate PhotoCraft instance with temporary settings,
queries its authenticated loopback control API, then quits and removes the
temporary files. Does not open or modify the user's documents/preferences.
Requires the container's desktop environment (e.g. s6-envdir + s6-setuidgid abc).
"""

import json
import os
from pathlib import Path
import secrets
import socket
import struct
import subprocess
import tempfile
import threading
import time
import zlib


def png_chunk(kind, data):
    return (
        struct.pack("!I", len(data))
        + kind
        + data
        + struct.pack("!I", zlib.crc32(kind + data))
    )


def run():
    with tempfile.TemporaryDirectory(prefix="kw-photocraft-gpu-") as directory:
        root = Path(directory)
        image = root / "gpu-proof.png"
        width = height = 256
        pixels = b"".join(
            b"\0" + bytes(v for x in range(width) for v in (x, y, x ^ y, 255))
            for y in range(height)
        )
        image.write_bytes(
            b"\x89PNG\r\n\x1a\n"
            + png_chunk(b"IHDR", struct.pack("!2I5B", width, height, 8, 6, 0, 0, 0))
            + png_chunk(b"IDAT", zlib.compress(pixels))
            + png_chunk(b"IEND", b"")
        )
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        token = secrets.token_hex(32)
        env = dict(os.environ)
        env.update(
            PHOTOCRAFT_CONFIG_DIR=str(root / "config"),
            PHOTOCRAFT_CONTROL_TOKEN=token,
            RUST_LOG="info",
        )
        process = subprocess.Popen(
            ["photocraft", "--new-instance", "--control", str(port), str(image)],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        # Drain output while the app runs; never print its control token.
        relevant_logs = []

        def drain():
            for line in process.stdout:
                if token not in line and any(
                    text in line
                    for text in ("GPU startup:", "gpu canvas:", "using the CPU compositor", "ERROR")
                ):
                    if len(relevant_logs) < 50:
                        relevant_logs.append(line.rstrip())

        reader = threading.Thread(target=drain, daemon=True)
        reader.start()
        connection = None
        stream = None
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f"PhotoCraft exited early ({process.returncode})")
                try:
                    connection = socket.create_connection(("127.0.0.1", port), timeout=2)
                    connection.settimeout(10)
                    break
                except (ConnectionRefusedError, TimeoutError):
                    time.sleep(0.2)
            if connection is None:
                raise RuntimeError("PhotoCraft control server did not start")
            stream = connection.makefile("rwb")

            def rpc(method, params=None):
                stream.write((json.dumps({"id": method, "method": method, "params": params or {}}) + "\n").encode())
                stream.flush()
                reply = json.loads(stream.readline(8 * 1024 * 1024))
                if "error" in reply:
                    raise RuntimeError(f"{method}: {reply['error']}")
                return reply.get("result")

            rpc("auth", {"token": token})
            rpc("ui.focus")
            info = None
            perf = {}
            while time.monotonic() < deadline:
                state = rpc("ui.inspect")
                perf = state.get("perf", {})
                info = perf.get("timings", {}).get("gpuInfo")
                if info and info.get("canvas") == "gpu":
                    # Let the synthetic image finish rendering, then re-query.
                    time.sleep(2)
                    perf = rpc("ui.inspect").get("perf", {})
                    info = perf.get("timings", {}).get("gpuInfo")
                    break
                time.sleep(0.25)
            print(json.dumps({"gpuInfo": info, "perf": perf}, indent=2))
            if not info or info.get("canvas") != "gpu":
                raise RuntimeError("PhotoCraft did not report an active GPU canvas")
            if info.get("lost"):
                raise RuntimeError("PhotoCraft reported a lost GPU device")
            adapter = info.get("adapter", "").lower()
            if "intel" not in adapter or "llvmpipe" in adapter:
                raise RuntimeError("Expected Intel hardware graphics, not a software adapter")
            timings = perf.get("timings", {})
            if not timings.get("gpu") or not str(timings.get("lastRefresh", "")).startswith("gpu-"):
                raise RuntimeError("Synthetic image was not composited on the GPU")
            rpc("app.quit")
            process.wait(timeout=10)
            if process.returncode:
                raise RuntimeError(f"PhotoCraft exited with {process.returncode}")
            print("PASS: synthetic PNG displayed with PhotoCraft reporting an Intel GPU canvas.")
        finally:
            if stream:
                stream.close()
            if connection:
                connection.close()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            reader.join(timeout=2)
            for line in relevant_logs:
                print(line)


if __name__ == "__main__":
    run()
