#!/usr/bin/env python3
"""
Test fixture that mimics secret_exec.py without calling AWS.

Reads --secret-env ENV=SECRET_ID[:FIELD] flags and resolves them from a JSON
manifest at $SYMPHONY_FAKE_SECRETS_PATH. The manifest schema is:

    {
      "<secret_id>": "string-value",
      "<secret_id_with_field>": {"field": "value", ...}
    }

When a referenced secret_id is missing OR the requested field is absent,
the wrapper exits non-zero with a redacted error written to stderr.
Otherwise it exec()s the child command (argv after `--`) with the resolved
values injected into the env. Stdout/stderr from the child are passed
through after the same value-redaction loop secret_exec.py uses, so tests
exercising the scrubber path still see [REDACTED_SECRET].
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from typing import Iterable


def _load_manifest() -> dict:
    path = os.environ.get("SYMPHONY_FAKE_SECRETS_PATH")
    if not path:
        raise SystemExit("fake_secret_exec: SYMPHONY_FAKE_SECRETS_PATH is unset")
    if not os.path.isfile(path):
        raise SystemExit(f"fake_secret_exec: manifest missing at {path}")
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def _resolve(manifest: dict, secret_id: str, field: str | None) -> str:
    if secret_id not in manifest:
        raise SystemExit(f"fake_secret_exec: secret {secret_id!r} not found")

    raw = manifest[secret_id]

    if field is None:
        if isinstance(raw, str):
            return raw
        raise SystemExit(f"fake_secret_exec: secret {secret_id!r} requires a field")

    if isinstance(raw, dict) and field in raw:
        value = raw[field]
        if not isinstance(value, str):
            raise SystemExit(f"fake_secret_exec: secret {secret_id!r}#{field} not a string")
        return value

    raise SystemExit(f"fake_secret_exec: secret {secret_id!r} missing field {field!r}")


def _redact(text: str, values: Iterable[str]) -> str:
    redacted = text
    for value in sorted({v for v in values if v}, key=len, reverse=True):
        redacted = redacted.replace(value, "[REDACTED_SECRET]")
    return redacted


def main() -> int:
    parser = argparse.ArgumentParser(description="Fake secret_exec.py for Symphony tests")
    parser.add_argument("--secret-env", action="append", default=[])
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        raise SystemExit("fake_secret_exec: no child command provided")

    manifest = _load_manifest()
    child_env = os.environ.copy()
    secret_values: list[str] = []

    for spec in args.secret_env:
        if "=" not in spec:
            raise SystemExit(f"fake_secret_exec: invalid --secret-env value {spec!r}")
        env_name, secret_spec = spec.split("=", 1)
        if ":" in secret_spec:
            secret_id, field = secret_spec.split(":", 1)
        else:
            secret_id, field = secret_spec, None
        value = _resolve(manifest, secret_id, field)
        child_env[env_name] = value
        secret_values.append(value)

    proc = subprocess.Popen(
        command,
        env=child_env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    stdout, stderr = proc.communicate()

    if stdout:
        sys.stdout.write(_redact(stdout, secret_values))
    if stderr:
        sys.stderr.write(_redact(stderr, secret_values))

    return proc.returncode


if __name__ == "__main__":
    raise SystemExit(main())
