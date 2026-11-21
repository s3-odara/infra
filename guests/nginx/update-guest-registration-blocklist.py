"""Refresh the guest registration IP blocks from Caddy's dedicated access log."""

import ipaddress
import json
import os
import sys
import time
from collections import Counter
from pathlib import Path


def update(log_path: Path, block_dir: Path, now: float) -> None:
    cutoff = now - 24 * 60 * 60
    successes = Counter()
    seen = set()

    def count(path: Path) -> None:
        try:
            log = path.open("rb")
        except FileNotFoundError:  # The log may rotate while being read.
            return
        with log:
            stat = os.fstat(log.fileno())
            identity = (stat.st_dev, stat.st_ino)
            if identity in seen or stat.st_mtime < cutoff:
                return
            seen.add(identity)
            for line in log:
                try:
                    entry = json.loads(line)
                    if entry["status"] == 200 and cutoff <= entry["ts"] <= now:
                        ip = ipaddress.ip_address(entry["request"]["remote_ip"])
                        if isinstance(ip, ipaddress.IPv6Address):
                            ip = ip.ipv4_mapped or ip
                        successes[str(ip)] += 1
                except (KeyError, TypeError, ValueError):
                    continue

    # Open the current log first. If it rolls before globbing the archives,
    # inode deduplication prevents counting it twice.
    count(log_path)
    for path in log_path.parent.glob(f"{log_path.stem}-*{log_path.suffix}"):
        count(path)

    blocked = {ip for ip, total in successes.items() if total >= 30}
    current = {path.name for path in block_dir.iterdir() if path.is_file()}
    for ip in blocked - current:
        (block_dir / ip).touch(exist_ok=False)
    for ip in current - blocked:
        (block_dir / ip).unlink()


if __name__ == "__main__":
    update(Path(sys.argv[1]), Path(sys.argv[2]), time.time())
