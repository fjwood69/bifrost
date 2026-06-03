#!/usr/bin/env python3
"""Verify a running Bifrost gateway is healthy and configured.

Tests:
  1. Container/process is responding on :8080
  2. Health endpoint returns 200
  3. At least one Virtual Key exists
  4. At least one provider key is active
  5. /v1/models is reachable (not exhaustive — models may vary)

Usage:
  ./scripts/verify-bifrost.py [--port 8080] [--db /app/data/config.db]
"""

import json
import sqlite3
import sys
import urllib.error
import urllib.request

PASS = "✓"
FAIL = "✗"


def check(label: str, ok: bool, detail: str = "") -> bool:
    icon = PASS if ok else FAIL
    print(f"  {icon} {label}{' — ' + detail if detail else ''}")
    return ok


def main():
    port = 8080
    db_path = "/app/data/config.db"

    for i, arg in enumerate(sys.argv[1:]):
        if arg == "--port" and i + 2 < len(sys.argv):
            port = int(sys.argv[i + 2])
        elif arg == "--db" and i + 2 < len(sys.argv):
            db_path = sys.argv[i + 2]

    base = f"http://localhost:{port}"
    all_ok = True

    print(f"Bifrost health check (port {port})\n")

    # 1. Health endpoint
    try:
        resp = urllib.request.urlopen(f"{base}/health", timeout=10)
        ok = resp.status == 200
        detail = f"HTTP {resp.status}" if not ok else ""
        all_ok &= check("Health endpoint", ok, detail)
    except Exception as e:
        all_ok &= check("Health endpoint", False, str(e))

    # 2. SQLite DB access
    try:
        conn = sqlite3.connect(db_path)
        # Check VKs exist
        vk_count = conn.execute(
            "SELECT COUNT(*) FROM governance_virtual_keys WHERE is_active = 1"
        ).fetchone()[0]
        all_ok &= check("Virtual Keys found", vk_count > 0, f"{vk_count} active VKs")

        # Check at least one enabled provider key
        key_count = conn.execute(
            "SELECT COUNT(*) FROM config_keys WHERE enabled = 1"
        ).fetchone()[0]
        all_ok &= check(
            "Provider keys enabled", key_count > 0, f"{key_count} enabled keys"
        )

        # Check at least one routing rule
        rule_count = conn.execute(
            "SELECT COUNT(*) FROM routing_rules WHERE enabled = 1"
        ).fetchone()[0]
        all_ok &= check(
            "Routing rules active", rule_count > 0, f"{rule_count} enabled rules"
        )

        conn.close()
    except Exception as e:
        all_ok &= check("SQLite config access", False, str(e))

    # 3. /v1/models responds
    try:
        req = urllib.request.Request(f"{base}/v1/models")
        resp = urllib.request.urlopen(req, timeout=15)
        data = json.loads(resp.read().decode())
        models = data.get("data", [])
        all_ok &= check(
            "Gateway returns models", len(models) > 0, f"{len(models)} model(s)"
        )
    except Exception as e:
        all_ok &= check("Gateway returns models", False, str(e))

    print(f"\n{'All checks passed.' if all_ok else 'Some checks failed.'}")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()