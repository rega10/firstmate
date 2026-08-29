#!/usr/bin/env python3
"""Safe record I/O and transaction locking for fm-bitwarden-ceremony.sh."""

import hashlib
import json
import os
import secrets
import stat
import subprocess
import sys
import time


PREFIX = "fm-bitwarden-ceremony: "
LOCK_VERSION = "fm-bitwarden-lock-v1"
EXIT_EXISTS = 17


def fail(message, code=1):
    print(PREFIX + message, file=sys.stderr)
    raise SystemExit(code)


def require_capabilities():
    if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY"):
        fail("refused: python3 lacks required no-follow directory I/O support")
    required = (os.open, os.mkdir, os.stat, os.unlink, os.link, os.rename)
    if any(function not in os.supports_dir_fd for function in required):
        fail("refused: python3 lacks required relative directory I/O support")
    if os.link not in os.supports_follow_symlinks or os.stat not in os.supports_follow_symlinks:
        fail("refused: python3 lacks required no-follow metadata support")


def open_directory(path, create):
    if not path:
        fail("refused: ceremony record directory is unavailable")
    absolute = os.path.isabs(path)
    descriptor = os.open("/" if absolute else ".", os.O_RDONLY | os.O_DIRECTORY)
    parts = path.split("/")
    try:
        for part in parts:
            if part in ("", "."):
                continue
            if part == "..":
                fail("refused: ceremony record path contains traversal")
            flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
            try:
                next_descriptor = os.open(part, flags, dir_fd=descriptor)
            except FileNotFoundError:
                if not create:
                    fail("ceremony record directory is unavailable; run init first")
                try:
                    os.mkdir(part, 0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
                try:
                    next_descriptor = os.open(part, flags, dir_fd=descriptor)
                except OSError:
                    fail("refused: ceremony record path contains a symbolic link or non-directory component")
            except OSError:
                fail("refused: ceremony record path contains a symbolic link or non-directory component")
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def read_all(descriptor):
    chunks = []
    while True:
        chunk = os.read(descriptor, 65536)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)


def open_regular(directory, name):
    try:
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
    except FileNotFoundError:
        fail("no ceremony record for this batch; run init first")
    except OSError:
        fail("refused: ceremony record destination is a symbolic link or non-regular file")
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode):
        os.close(descriptor)
        fail("refused: ceremony record destination is not a regular file")
    return descriptor


def write_all(descriptor, payload):
    offset = 0
    while offset < len(payload):
        written = os.write(descriptor, payload[offset:])
        if written <= 0:
            fail("could not write ceremony transaction state")
        offset += written


def process_identity(pid):
    proc = f"/proc/{pid}"
    try:
        with open(f"{proc}/stat", "rb") as stat_file:
            stat_bytes = stat_file.read()
        with open(f"{proc}/cmdline", "rb") as cmdline_file:
            cmdline = cmdline_file.read()
        tail = stat_bytes.rsplit(b")", 1)[1].split()
        if len(tail) >= 20 and cmdline:
            return "proc-start=" + tail[19].decode("ascii") + " cmdline-sha256=" + hashlib.sha256(cmdline).hexdigest()
    except (FileNotFoundError, IndexError, UnicodeDecodeError, OSError):
        pass
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "lstart=", "-o", "command="],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=environment,
        check=False,
        text=True,
    )
    identity = result.stdout.strip()
    return identity or None


def lock_owner_bytes(token):
    identity = process_identity(os.getpid())
    if identity is None:
        fail("refused: cannot establish ceremony lock process identity")
    owner = {"version": LOCK_VERSION, "token": token, "pid": os.getpid(), "process_start": identity}
    return (json.dumps(owner, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def read_lock(directory, name):
    try:
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
    except FileNotFoundError:
        return None
    except OSError:
        fail("refused: ceremony lock ownership is unreadable")
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            fail("refused: ceremony lock ownership is malformed")
        payload = read_all(descriptor)
    finally:
        os.close(descriptor)
    try:
        owner = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail("refused: ceremony lock ownership is malformed")
    if set(owner) != {"version", "token", "pid", "process_start"}:
        fail("refused: ceremony lock ownership is malformed")
    if owner["version"] != LOCK_VERSION or not isinstance(owner["token"], str):
        fail("refused: ceremony lock ownership is malformed")
    if not isinstance(owner["pid"], int) or owner["pid"] <= 1 or not isinstance(owner["process_start"], str) or not owner["process_start"]:
        fail("refused: ceremony lock ownership is malformed")
    return owner, payload, (metadata.st_dev, metadata.st_ino)


def owner_state(owner):
    try:
        os.kill(owner["pid"], 0)
    except ProcessLookupError:
        return "dead", None
    except PermissionError:
        return "uncertain", "refused: ceremony lock owner liveness is uncertain"
    current = process_identity(owner["pid"])
    if current is None:
        return "uncertain", "refused: ceremony lock owner identity is unreadable"
    if current != owner["process_start"]:
        return "uncertain", "refused: ceremony lock owner identity does not match the live process"
    return "live", None


def lock_unchanged(directory, name, payload, identity):
    current = read_lock(directory, name)
    return current is not None and current[1] == payload and current[2] == identity


def claim_lock(directory, record_name):
    lock_name = record_name + ".lock"
    token = secrets.token_hex(24)
    owner_payload = lock_owner_bytes(token)
    wait_seconds = float(os.environ.get("FM_BITWARDEN_LOCK_WAIT_SECONDS", "15"))
    if wait_seconds < 0 or wait_seconds > 30:
        fail("refused: ceremony lock wait must be between 0 and 30 seconds")
    deadline = time.monotonic() + wait_seconds
    while True:
        temporary = f".{lock_name}.claim.{token}"
        try:
            descriptor = os.open(
                temporary,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
                dir_fd=directory,
            )
            try:
                write_all(descriptor, owner_payload)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            try:
                os.link(temporary, lock_name, src_dir_fd=directory, dst_dir_fd=directory, follow_symlinks=False)
                os.unlink(temporary, dir_fd=directory)
                os.fsync(directory)
                return lock_name, token, owner_payload
            except FileExistsError:
                os.unlink(temporary, dir_fd=directory)
        except FileExistsError:
            try:
                os.unlink(temporary, dir_fd=directory)
            except FileNotFoundError:
                pass
        current = read_lock(directory, lock_name)
        if current is None:
            continue
        owner, payload, identity = current
        state, uncertain_reason = owner_state(owner)
        if state == "dead":
            if not lock_unchanged(directory, lock_name, payload, identity):
                fail("refused: ceremony lock ownership changed during stale recovery")
            os.unlink(lock_name, dir_fd=directory)
            os.fsync(directory)
            continue
        if time.monotonic() >= deadline:
            if state == "uncertain":
                fail(uncertain_reason)
            fail("ceremony record is busy; retry after the active writer finishes")
        time.sleep(0.05)


def release_lock(directory, lock_name, token, owner_payload):
    current = read_lock(directory, lock_name)
    if current is None:
        return
    owner, payload, _ = current
    if owner["token"] != token or payload != owner_payload or owner["pid"] != os.getpid():
        return
    os.unlink(lock_name, dir_fd=directory)
    os.fsync(directory)


def pause_at(environment_name):
    marker = os.environ.get(environment_name)
    if not marker:
        return
    with open(marker + ".ready", "w", encoding="utf-8") as ready:
        ready.write("ready\n")
    deadline = time.monotonic() + 15
    while not os.path.exists(marker + ".go"):
        if time.monotonic() >= deadline:
            fail("test synchronization timed out")
        time.sleep(0.02)


def stage_bytes(directory, record_name, payload):
    temporary = f".{record_name}.stage.{secrets.token_hex(16)}"
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
        dir_fd=directory,
    )
    try:
        write_all(descriptor, payload)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    return temporary


def command_run(arguments):
    if len(arguments) < 6:
        fail("internal record transaction arguments are incomplete")
    directory_path, batch, create_text, lock_text, script, command, *command_arguments = arguments
    if not batch or any(character not in "abcdefghijklmnopqrstuvwxyz0123456789-" for character in batch):
        fail("refused: invalid internal batch identity")
    directory = open_directory(directory_path, create_text == "1")
    old_cwd = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
    lock_state = None
    try:
        if lock_text == "1":
            lock_state = claim_lock(directory, batch + ".ceremony")
            pause_at("FM_BITWARDEN_TEST_AFTER_LOCK")
        os.fchdir(directory)
        environment = os.environ.copy()
        environment["FM_BITWARDEN_IO_ACTIVE"] = "1"
        environment["FM_BITWARDEN_RECORD_DISPLAY"] = os.path.join(directory_path, batch + ".ceremony")
        completed = subprocess.run([script, command, *command_arguments], env=environment, check=False)
        return completed.returncode
    finally:
        os.fchdir(old_cwd)
        os.close(old_cwd)
        if lock_state is not None:
            release_lock(directory, *lock_state)
        os.close(directory)


def command_stream(batch):
    directory = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
    try:
        descriptor = open_regular(directory, batch + ".ceremony")
        try:
            payload = read_all(descriptor)
        finally:
            os.close(descriptor)
    finally:
        os.close(directory)
    fingerprint = hashlib.sha256(payload).hexdigest()
    sys.stdout.buffer.write(f"fm-bitwarden-snapshot-v1 sha256={fingerprint}\n".encode("ascii"))
    sys.stdout.buffer.write(payload)
    sys.stdout.buffer.flush()
    return 0


def command_create(batch):
    payload = sys.stdin.buffer.read()
    directory = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
    record_name = batch + ".ceremony"
    temporary = stage_bytes(directory, record_name, payload)
    try:
        try:
            os.link(temporary, record_name, src_dir_fd=directory, dst_dir_fd=directory, follow_symlinks=False)
        except FileExistsError:
            metadata = os.stat(record_name, dir_fd=directory, follow_symlinks=False)
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                fail("refused: ceremony record destination is a symbolic link or non-regular file")
            return EXIT_EXISTS
        os.fsync(directory)
        return 0
    finally:
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass
        os.close(directory)


def command_append(batch, expected_hash, line):
    if "\n" in line or "\r" in line:
        fail("refused: ceremony record update contains a line break")
    directory = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
    record_name = batch + ".ceremony"
    try:
        descriptor = open_regular(directory, record_name)
        try:
            payload = read_all(descriptor)
        finally:
            os.close(descriptor)
        if hashlib.sha256(payload).hexdigest() != expected_hash:
            fail("refused: ceremony record changed during the transaction; retry")
        temporary = stage_bytes(directory, record_name, payload + line.encode("utf-8") + b"\n")
        try:
            pause_at("FM_BITWARDEN_TEST_BEFORE_REPLACE")
            os.rename(temporary, record_name, src_dir_fd=directory, dst_dir_fd=directory)
            os.fsync(directory)
        finally:
            try:
                os.unlink(temporary, dir_fd=directory)
            except FileNotFoundError:
                pass
        return 0
    finally:
        os.close(directory)


def main():
    require_capabilities()
    if len(sys.argv) < 2:
        fail("internal record I/O command is required")
    command = sys.argv[1]
    if command == "run":
        return command_run(sys.argv[2:])
    if command == "stream" and len(sys.argv) == 3:
        return command_stream(sys.argv[2])
    if command == "create" and len(sys.argv) == 3:
        return command_create(sys.argv[2])
    if command == "append" and len(sys.argv) == 5:
        return command_append(sys.argv[2], sys.argv[3], sys.argv[4])
    fail("internal record I/O command is invalid")


if __name__ == "__main__":
    raise SystemExit(main())
