#!/usr/bin/env python3
"""Copy the submission through no-follow file descriptors into the artifact mount."""

from __future__ import annotations

import os
import secrets
import stat
import sys


MAX_ARTIFACT_BYTES = 131_072
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def main() -> None:
    app_fd = os.open("/app", DIRECTORY_FLAGS)
    logs_fd = os.open("/logs", DIRECTORY_FLAGS)
    source_dir_fd = artifact_dir_fd = source_fd = temporary_fd = None
    temporary_name = f".Exploit.sol.{secrets.token_hex(8)}"
    try:
        source_dir_fd = os.open("src", DIRECTORY_FLAGS, dir_fd=app_fd)
        try:
            os.mkdir("artifacts", mode=0o755, dir_fd=logs_fd)
        except FileExistsError:
            pass
        artifact_dir_fd = os.open("artifacts", DIRECTORY_FLAGS, dir_fd=logs_fd)
        # The hook is a trusted root process. Reclaim a directory the model may
        # have pre-created so it cannot replace the finished artifact afterward.
        os.fchown(artifact_dir_fd, 0, 0)
        os.fchmod(artifact_dir_fd, 0o755)
        source_fd = os.open(
            "Exploit.sol", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=source_dir_fd
        )
        source_stat = os.fstat(source_fd)
        if not stat.S_ISREG(source_stat.st_mode) or source_stat.st_size > MAX_ARTIFACT_BYTES:
            raise ValueError("invalid Exploit.sol")

        temporary_fd = os.open(
            temporary_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=artifact_dir_fd,
        )
        copied = 0
        while chunk := os.read(source_fd, 65_536):
            copied += len(chunk)
            if copied > MAX_ARTIFACT_BYTES:
                raise ValueError("Exploit.sol is too large")
            view = memoryview(chunk)
            while view:
                view = view[os.write(temporary_fd, view) :]
        os.fchmod(temporary_fd, 0o644)
        os.fsync(temporary_fd)
        os.close(temporary_fd)
        temporary_fd = None
        os.rename(
            temporary_name,
            "Exploit.sol",
            src_dir_fd=artifact_dir_fd,
            dst_dir_fd=artifact_dir_fd,
        )
        temporary_name = ""
    finally:
        if temporary_name and artifact_dir_fd is not None:
            try:
                os.unlink(temporary_name, dir_fd=artifact_dir_fd)
            except FileNotFoundError:
                pass
        for descriptor in (
            temporary_fd,
            source_fd,
            artifact_dir_fd,
            source_dir_fd,
            logs_fd,
            app_fd,
        ):
            if descriptor is not None:
                os.close(descriptor)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError):
        print("invalid Exploit.sol artifact", file=sys.stderr)
        raise SystemExit(1)
