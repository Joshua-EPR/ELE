#!/usr/bin/env python3
"""
scripts/package_distribution.py

Packaging, Local Installers & Distribution Automation for ELE.
Prepares standalone, zero-CRT native ELE distribution packages for
Windows (x86-64 PE32+) and Linux (x86-64 ELF64).

Archives Produced:
  - dist/ele-windows-x86_64.zip
  - dist/ele-linux-x86_64.tar.gz
  - dist/SHA256SUMS.txt

Directory Layout Inside Archives:
  ele/
  ├── bin/
  │   └── ele (ele.exe on Windows, ele on Linux)
  ├── examples/
  ├── README.md
  ├── README.es.md
  └── VERSION

Guarantees:
  - Binaries are produced by the autonomous ELE compiler (Gen 2/Gen 3).
  - Completely free of Rust or CRT dependencies.
  - No invented license file (Principle 23).
  - Verifiable SHA-256 checksums manifest.
"""

import argparse
import hashlib
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path


def get_repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def read_version(repo_root: Path) -> str:
    version_file = repo_root / "VERSION"
    if version_file.is_file():
        return version_file.read_text(encoding="utf-8").strip()
    return "0.3.0"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()



def verify_fixpoint(gen2_bin: Path, gen3_bin: Path) -> Path:
    """Fail closed: neither a missing Gen 3 nor a mismatch is distributable."""
    if not gen2_bin.is_file() or not gen3_bin.is_file():
        raise RuntimeError("Self-hosting verification failed: missing Gen 2 or Gen 3 binary")
    hash_gen2 = sha256_file(gen2_bin)
    hash_gen3 = sha256_file(gen3_bin)
    if hash_gen2 != hash_gen3:
        raise RuntimeError(
            f"Self-hosting verification failed: Gen 2 != Gen 3 "
            f"(Gen 2 SHA256={hash_gen2}, Gen 3 SHA256={hash_gen3})"
        )
    print(f"[dist] Verified Gen 2 == Gen 3 bit for bit (SHA256: {hash_gen3})")
    return gen3_bin


def require_seed_driver(driver: Path | None) -> Path:
    """Require the hash-verified native seed supplied by the caller."""
    if driver is None:
        raise ValueError("distribution requires --driver-path to a verified native ELE seed")
    resolved = driver.resolve()
    if not resolved.is_file():
        raise FileNotFoundError(f"verified ELE seed not found: {resolved}")
    return resolved


def build_autonomous_compiler(
    repo_root: Path,
    target_os: str,
    work_dir: Path,
    driver_override: Path | None = None,
) -> Path:
    """
    Produces a Gen 2/Gen 3 autonomous ELE binary.
    target_os: 'windows' or 'linux'
    """
    driver_src = repo_root / "compiler-l/src/main_driver.l"
    if not driver_src.is_file():
        raise FileNotFoundError(f"Driver source not found: {driver_src}")

    target_flag = "pe" if target_os == "windows" else "elf"
    out_ext = ".exe" if target_os == "windows" else ""
    gen2_bin = work_dir / f"ele_gen2_{target_os}{out_ext}"
    gen3_bin = work_dir / f"ele_gen3_{target_os}{out_ext}"

    # Distribution requires the verified native seed passed explicitly.
    gen1_driver = require_seed_driver(driver_override)

    print(f"[dist] Building Gen 2 ({target_os}) using {gen1_driver.name}...")
    cmd_gen2 = [
        str(gen1_driver),
        "build",
        str(driver_src),
        "--target",
        target_flag,
        "--output",
        str(gen2_bin),
    ]
    res_gen2 = subprocess.run(cmd_gen2, cwd=repo_root, capture_output=True, text=True)
    if res_gen2.returncode != 0 or not gen2_bin.is_file():
        raise RuntimeError(f"Gen 2 build failed: {res_gen2.stderr}\n{res_gen2.stdout}")

    # Set executable permissions on Unix if needed
    if target_os == "linux" and sys.platform != "win32":
        gen2_bin.chmod(gen2_bin.stat().st_mode | 0o755)

    # Gen 2 must execute on the packaging host: a cross-target binary
    # cannot certify the autonomous Gen 2 -> Gen 3 fixpoint here.
    can_execute_gen2 = (
        (target_os == "windows" and sys.platform == "win32")
        or (target_os == "linux" and sys.platform.startswith("linux"))
    )
    if not can_execute_gen2:
        raise RuntimeError(
            f"Cannot verify {target_os} Gen 2 -> Gen 3 on host {sys.platform}; "
            "build each distribution on its native target runner"
        )

    print(f"[dist] Building Gen 3 ({target_os}) using Gen 2 for fixpoint verification...")
    cmd_gen3 = [
        str(gen2_bin), "build", str(driver_src), "--target", target_flag,
        "--output", str(gen3_bin),
    ]
    res_gen3 = subprocess.run(cmd_gen3, cwd=repo_root, capture_output=True, text=True)
    if res_gen3.returncode != 0 or not gen3_bin.is_file():
        raise RuntimeError(
            f"Gen 3 self-rebuild failed (exit={res_gen3.returncode}): "
            f"{res_gen3.stderr}\\n{res_gen3.stdout}"
        )
    return verify_fixpoint(gen2_bin, gen3_bin)

def assemble_distribution_archive(
    repo_root: Path,
    target_os: str,
    compiler_binary: Path,
    version: str,
    dist_dir: Path,
) -> Path:
    """
    Creates target archive:
      - Windows: ele-windows-x86_64.zip
      - Linux: ele-linux-x86_64.tar.gz
    """
    dist_dir.mkdir(parents=True, exist_ok=True)
    stage_dir = Path(tempfile.mkdtemp(prefix="ele-dist-"))

    try:
        ele_root = stage_dir / "ele"
        bin_dir = ele_root / "bin"
        examples_dir = ele_root / "examples"
        bin_dir.mkdir(parents=True, exist_ok=True)
        examples_dir.mkdir(parents=True, exist_ok=True)

        # 1. Copy autonomous binary
        bin_name = "ele.exe" if target_os == "windows" else "ele"
        dest_bin = bin_dir / bin_name
        shutil.copy2(compiler_binary, dest_bin)
        if target_os == "linux" and sys.platform != "win32":
            dest_bin.chmod(0o755)

        # 2. Copy documentation & VERSION (strictly NO invented license, Principle 23)
        shutil.copy2(repo_root / "README.md", ele_root / "README.md")
        if (repo_root / "README.es.md").is_file():
            shutil.copy2(repo_root / "README.es.md", ele_root / "README.es.md")

        version_file = ele_root / "VERSION"
        version_file.write_text(f"{version}\n", encoding="utf-8")

        # 3. Copy examples (preserve source files and user examples)
        src_examples = repo_root / "examples"
        if src_examples.is_dir():
            for item in src_examples.iterdir():
                if item.name == "invalid":
                    continue
                if item.is_file() and (item.suffix in [".l", ".expected"] or item.name.endswith(".md")):
                    shutil.copy2(item, examples_dir / item.name)

        # Add a canonical hello.l if not present
        hello_dest = examples_dir / "hello.l"
        if not hello_dest.is_file():
            hello_dest.write_text(
                '// hello.l: Minimal ELE v2 program\n'
                'flow main() => Int {\n'
                '    print("Hello from native ELE!")\n'
                '    give 0\n'
                '}\n',
                encoding="utf-8",
            )

        # 4. Create archive
        if target_os == "windows":
            archive_path = dist_dir / "ele-windows-x86_64.zip"
            if archive_path.is_file():
                archive_path.unlink()

            print(f"[dist] Creating ZIP archive: {archive_path}")
            with zipfile.ZipFile(archive_path, "w", zipfile.ZIP_DEFLATED) as zf:
                for root, _, files in os.walk(ele_root):
                    for file in files:
                        full_path = Path(root) / file
                        arcname = full_path.relative_to(stage_dir).as_posix()
                        zf.write(full_path, arcname)

            return archive_path
        else:
            archive_path = dist_dir / "ele-linux-x86_64.tar.gz"
            if archive_path.is_file():
                archive_path.unlink()

            print(f"[dist] Creating Tarball archive: {archive_path}")
            with tarfile.open(archive_path, "w:gz") as tf:
                for root, dirs, files in os.walk(ele_root):
                    # Sort for deterministic archive order
                    dirs.sort()
                    files.sort()
                    for d in dirs:
                        dir_path = Path(root) / d
                        arcname = dir_path.relative_to(stage_dir).as_posix()
                        ti = tf.gettarinfo(dir_path, arcname=arcname)
                        ti.mode = 0o755
                        ti.uid = 0
                        ti.gid = 0
                        ti.uname = "ele"
                        ti.gname = "ele"
                        tf.addfile(ti)

                    for file in files:
                        full_path = Path(root) / file
                        arcname = full_path.relative_to(stage_dir).as_posix()
                        ti = tf.gettarinfo(full_path, arcname=arcname)
                        ti.uid = 0
                        ti.gid = 0
                        ti.uname = "ele"
                        ti.gname = "ele"
                        if arcname.endswith("bin/ele"):
                            ti.mode = 0o755
                        else:
                            ti.mode = 0o644
                        with open(full_path, "rb") as f:
                            tf.addfile(ti, f)

            return archive_path

    finally:
        shutil.rmtree(stage_dir, ignore_errors=True)


def verify_archive(archive_path: Path, target_os: str) -> None:
    print(f"[dist] Verifying archive structure: {archive_path.name}...")
    expected_bin = "ele/bin/ele.exe" if target_os == "windows" else "ele/bin/ele"
    expected_readme = "ele/README.md"
    expected_version = "ele/VERSION"

    if target_os == "windows":
        with zipfile.ZipFile(archive_path, "r") as zf:
            namelist = set(zf.namelist())
            assert expected_bin in namelist, f"Missing {expected_bin} in zip"
            assert expected_readme in namelist, f"Missing {expected_readme} in zip"
            assert expected_version in namelist, f"Missing {expected_version} in zip"
            assert not any("LICENSE" in name.upper() for name in namelist), "License found (Principle 23 violation)"
    else:
        with tarfile.open(archive_path, "r:gz") as tf:
            names = set(tf.getnames())
            assert expected_bin in names, f"Missing {expected_bin} in tarball"
            assert expected_readme in names, f"Missing {expected_readme} in tarball"
            assert expected_version in names, f"Missing {expected_version} in tarball"
            assert not any("LICENSE" in name.upper() for name in names), "License found (Principle 23 violation)"

            # Verify executable permissions on bin/ele
            ti = tf.getmember(expected_bin)
            assert (ti.mode & 0o111) != 0, f"Binary {expected_bin} is not marked executable ({oct(ti.mode)})"

    print(f"[dist] Verification PASSED for {archive_path.name}")


def write_checksums_manifest(dist_dir: Path) -> Path:
    manifest_path = dist_dir / "SHA256SUMS.txt"
    entries = []

    for name in sorted(os.listdir(dist_dir)):
        if name == "SHA256SUMS.txt":
            continue
        p = dist_dir / name
        if p.is_file() and (p.suffix in [".zip", ".gz"] or name.startswith("ele-")):
            h = sha256_file(p)
            entries.append(f"{h}  {name}\n")

    manifest_path.write_text("".join(entries), encoding="utf-8")
    print(f"[dist] Checksums manifest written to {manifest_path}:")
    for entry in entries:
        print(f"  {entry.strip()}")
    return manifest_path


def main():
    parser = argparse.ArgumentParser(description="ELE Distribution Package Builder")
    parser.add_argument(
        "--target",
        choices=["windows", "linux", "auto"],
        default="auto",
        help="Native target archive to produce (must match this runner)",
    )
    parser.add_argument(
        "--dist-dir",
        type=Path,
        default=None,
        help="Output directory for distribution packages (default: dist/)",
    )
    parser.add_argument(
        "--driver-path",
        type=Path,
        required=True,
        help="Path to a verified native ELE seed for the current host",
    )
    parser.add_argument(
        "--skip-verify",
        action="store_true",
        help="Skip archive structure and permission verification",
    )
    args = parser.parse_args()

    repo_root = get_repo_root()
    dist_dir = args.dist_dir or (repo_root / "dist")
    version = read_version(repo_root)

    print("============================================================")
    print(" ELE Distribution Packaging Automation")
    print(f" Repo root: {repo_root}")
    print(f" Dist dir:  {dist_dir}")
    print(f" Version:   {version}")
    print("============================================================")

    targets = []
    if args.target == "auto":
        targets = ["windows" if sys.platform == "win32" else "linux"]
    else:
        targets = [args.target]

    work_dir = Path(tempfile.mkdtemp(prefix="ele-build-"))
    created_archives = []

    try:
        for t in targets:
            print(f"\n[dist] Packaging target: {t}")
            comp_bin = build_autonomous_compiler(
                repo_root=repo_root,
                target_os=t,
                work_dir=work_dir,
                driver_override=args.driver_path,
            )
            print(f"[dist] Autonomous binary prepared: {comp_bin} ({comp_bin.stat().st_size:,} bytes)")

            archive = assemble_distribution_archive(
                repo_root=repo_root,
                target_os=t,
                compiler_binary=comp_bin,
                version=version,
                dist_dir=dist_dir,
            )
            created_archives.append((archive, t))

            if not args.skip_verify:
                verify_archive(archive, t)

        write_checksums_manifest(dist_dir)
        print("\n[dist] Distribution packaging complete!")

    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
