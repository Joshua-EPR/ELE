"""Verify SHA-256 manifests; fail closed on malformed or missing entries."""
import hashlib
import pathlib
import sys


def verify_hashes(manifest: pathlib.Path) -> int:
    try:
        entries = manifest.read_text(encoding="utf-8-sig").splitlines()
    except OSError as exc:
        print(f"Cannot read manifest: {exc}", file=sys.stderr)
        return 1
    if not entries:
        print("Empty hash manifest", file=sys.stderr)
        return 1
    failures = 0
    count = 0
    for line_no, line in enumerate(entries, 1):
        if not line.strip():
            continue
        if "  " not in line:
            print(f"Malformed entry on line {line_no}", file=sys.stderr)
            failures += 1
            continue
        expected, filename = line.split("  ", 1)
        if len(expected) != 64 or any(c not in "0123456789abcdefABCDEF" for c in expected) or not filename:
            print(f"Invalid SHA-256 entry on line {line_no}", file=sys.stderr)
            failures += 1
            continue
        path = pathlib.Path(filename)
        if not path.is_absolute():
            path = manifest.parent / path
        try:
            h = hashlib.sha256()
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    h.update(block)
        except OSError as exc:
            print(f"Missing/unreadable file {path}: {exc}", file=sys.stderr)
            failures += 1
            continue
        count += 1
        if h.hexdigest().lower() != expected.lower():
            print(f"Hash mismatch: {path}", file=sys.stderr)
            failures += 1
    if count == 0:
        failures += 1
        print("No files could be verified", file=sys.stderr)
    print(f"Checked {count} file(s); failures={failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: verify_hashes.py <manifest>", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(verify_hashes(pathlib.Path(sys.argv[1]).resolve()))
