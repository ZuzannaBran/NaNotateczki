#!/usr/bin/env python3
"""Retry only a simulator VM-service discovery stall, never a test failure."""

import os
import re
import selectors
import signal
import subprocess
import sys
import time

TEST_FILE = "integration_test/native_platform_matrix_test.dart"
STARTED = re.compile(r"\d\d:\d\d \+\d+: platform bootstrap ")


def stop_tree(process):
    if process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()


def run_once(device, discovery_timeout):
    command = [
        "flutter", "test", TEST_FILE, "-d", device,
        "--dart-define=NANOTATECZKI_ISOLATED_CI=true",
        "--reporter", "expanded", "--timeout", "3m",
    ]
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        bufsize=0,
    )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    recent = ""
    discovery_deadline = None
    started = False
    try:
        while True:
            ready = selector.select(timeout=0.2)
            if ready:
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    break
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
                recent = (recent + chunk.decode("utf-8", "replace"))[-8192:]
                if not started and STARTED.search(recent):
                    started = True
                    discovery_deadline = None
                elif discovery_deadline is None and "Xcode build done." in recent:
                    discovery_deadline = time.monotonic() + discovery_timeout
            if (
                not started
                and discovery_deadline is not None
                and time.monotonic() >= discovery_deadline
            ):
                print(
                    "::warning::iOS app built, but Flutter never started the "
                    "first test. Suspected simulator VM-service discovery stall.",
                    file=sys.stderr,
                    flush=True,
                )
                stop_tree(process)
                return "stalled", 124
            if process.poll() is not None and not ready:
                break
        return "finished", process.wait()
    finally:
        selector.close()
        stop_tree(process)
        process.stdout.close()


def reboot_simulator(device):
    subprocess.run(
        ["xcrun", "simctl", "shutdown", device],
        check=False,
        timeout=60,
    )
    subprocess.run(
        ["xcrun", "simctl", "boot", device],
        check=True,
        timeout=60,
    )
    subprocess.run(
        ["xcrun", "simctl", "bootstatus", device, "-b"],
        check=True,
        timeout=180,
    )


def main(args):
    if len(args) != 1 or not args[0]:
        print("Exactly one iOS simulator UDID is required.", file=sys.stderr)
        return 2
    device = args[0]
    timeout = float(os.environ.get("IOS_VM_DISCOVERY_TIMEOUT_SECONDS", "240"))
    if timeout <= 0:
        raise ValueError("Discovery timeout must be positive.")

    for attempt in (1, 2):
        status, code = run_once(device, timeout)
        if status == "finished":
            # A real test assertion, compiler error or dependency failure
            # must fail CI immediately, without an automatic second run.
            return code
        if attempt == 2:
            print("::error::iOS VM-service discovery stalled twice.", file=sys.stderr)
            return code
        print(
            "::warning::Restarting iOS simulator and retrying test startup once.",
            file=sys.stderr,
            flush=True,
        )
        reboot_simulator(device)
    return 124


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
