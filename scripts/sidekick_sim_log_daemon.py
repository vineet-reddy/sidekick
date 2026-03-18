#!/usr/bin/env python3

import argparse
import os
import pty
import signal
import subprocess
import sys
import time
from select import select


child_process = None
master_fd = None
log_handle = None
shutdown_requested = False


def terminate_child() -> None:
    global child_process
    if child_process is None or child_process.poll() is not None:
        return
    child_process.terminate()
    try:
        child_process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        child_process.kill()
        child_process.wait(timeout=3)


def handle_signal(_signum, _frame) -> None:
    global shutdown_requested
    shutdown_requested = True
    terminate_child()


def write_banner(message: str) -> None:
    if log_handle is None:
        return
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    log_handle.write(f"\n=== {message} at {timestamp} ===\n".encode("utf-8"))
    log_handle.flush()


def run(process_name: str, log_path: str) -> int:
    global child_process, master_fd, log_handle

    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    log_handle = open(log_path, "ab", buffering=0)
    write_banner(f"Sidekick simulator log capture started for process={process_name}")

    master_fd, slave_fd = pty.openpty()
    child_process = subprocess.Popen(
        ["/usr/bin/log", "stream", "--style", "compact", "--process", process_name],
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        close_fds=True,
        start_new_session=True,
    )
    os.close(slave_fd)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    try:
        while True:
            ready, _, _ = select([master_fd], [], [], 0.5)
            if ready:
                try:
                    data = os.read(master_fd, 4096)
                except OSError:
                    break
                if not data:
                    break
                log_handle.write(data)
                log_handle.flush()

            if child_process.poll() is not None and not ready:
                break
            if shutdown_requested and child_process.poll() is not None:
                break
    finally:
        terminate_child()
        write_banner("Sidekick simulator log capture stopped")
        if master_fd is not None:
            try:
                os.close(master_fd)
            except OSError:
                pass
        if log_handle is not None:
            log_handle.close()

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Persist Sidekick simulator unified logs to a file.")
    parser.add_argument("--process", default="Sidekick")
    parser.add_argument("--log-path", required=True)
    args = parser.parse_args()
    return run(args.process, args.log_path)


if __name__ == "__main__":
    sys.exit(main())
