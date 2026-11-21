"""End-to-end native stdout test for the autonomous ELE driver.

Usage: python tests/std/console_output.py <driver> <pe|elf>
"""

import pathlib
import subprocess
import sys
import tempfile


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[2] not in ("pe", "elf"):
        raise SystemExit("usage: console_output.py <driver> <pe|elf>")
    driver = pathlib.Path(sys.argv[1]).resolve()
    target = sys.argv[2]
    root = pathlib.Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="ele-console-output-") as tmp:
        output = pathlib.Path(tmp) / ("console-output.exe" if target == "pe" else "console-output.elf")
        positive = root / "tests/std/console_output.l"
        negative = root / "tests/std/console_output_invalid.l"
        build = subprocess.run(
            [str(driver), "build", str(positive), "--target", target, "--output", str(output)],
            capture_output=True,
            text=True,
        )
        assert build.returncode == 0 and output.exists(), build.stderr
        run = subprocess.run([str(output)], capture_output=True)
        assert run.returncode == 0, (run.returncode, run.stderr)
        assert run.stdout == bytes([65, 0, 195, 169, 10]), run.stdout
        assert run.stderr == b"", run.stderr
        output.unlink()
        rejected = subprocess.run(
            [str(driver), "build", str(negative), "--target", target, "--output", str(output)],
            capture_output=True,
            text=True,
        )
        assert rejected.returncode != 0 and not output.exists(), rejected.stderr
        assert "L0004" in rejected.stderr, rejected.stderr
    print("console-output-native-ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
