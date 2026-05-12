#!/usr/bin/env python3
"""Backup the Bifrost SQLite config database.

Creates timestamped backups to a configurable directory.
Does NOT rotate backups — use an external tool for retention.

Usage:
  ./scripts/backup-bifrost-config.py [--db /app/data/config.db] [--out /app/data/backups]
"""

import argparse
import os
import shutil
import sqlite3
import sys
from datetime import datetime


def backup(db_path: str, out_dir: str) -> tuple[str, int]:
    """Copy and VACUUM INTO a backup file. Returns (path, bytes)."""
    os.makedirs(out_dir, exist_ok=True)

    ts = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    backup_path = os.path.join(out_dir, f"config-{ts}.db")

    # VACUUM INTO is atomic and creates a freshly-packed copy
    conn = sqlite3.connect(db_path)
    conn.execute(f"VACUUM INTO '{backup_path}'")
    conn.close()

    size = os.path.getsize(backup_path)
    return backup_path, size


def verify_backup(backup_path: str) -> bool:
    """Quick sanity check: open the backup and count VKs."""
    try:
        conn = sqlite3.connect(backup_path)
        vk_count = conn.execute(
            "SELECT COUNT(*) FROM governance_virtual_keys"
        ).fetchone()[0]
        conn.close()
        return vk_count > 0
    except Exception:
        return False


def main():
    parser = argparse.ArgumentParser(
        description="Backup the Bifrost SQLite config database"
    )
    parser.add_argument(
        "--db",
        default="/app/data/config.db",
        help="Path to the live config.db (default: /app/data/config.db)",
    )
    parser.add_argument(
        "--out",
        default="/app/data/backups",
        help="Output directory for backups (default: /app/data/backups)",
    )
    args = parser.parse_args()

    if not os.path.isfile(args.db):
        print(f"Error: config DB not found at {args.db}")
        sys.exit(1)

    try:
        path, size = backup(args.db, args.out)
    except Exception as e:
        print(f"Error: backup failed — {e}")
        sys.exit(1)

    if not verify_backup(path):
        print("Error: backup verification failed — VACUUM INTO may be incomplete")
        os.remove(path)
        sys.exit(1)

    size_mb = size / (1024 * 1024)
    print(f"Backup saved: {path} ({size_mb:.1f} MB)")
    print("Verification: OK")


if __name__ == "__main__":
    main()