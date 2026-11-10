"""Ensure an existing Stage 1 binary can feed C backend without any Rust calls."""
from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
CC=shutil.which('cc') or shutil.which('clang') or shutil.which('gcc')


@unittest.skipUnless(CC and sys.platform != 'win32', 'requires UNIX executable test driver and C compiler')
class BuildBridgeTest(unittest.TestCase):
    def test_prebuilt_stage1_to_native_no_rust(self):
        with tempfile.TemporaryDirectory() as d:
            d=Path(d)
            fake=d/'stage1'
            lir=(ROOT/'examples'/'native_without_rust.lir').read_text(encoding='utf-8')
            fake.write_text('#!/usr/bin/env python3\n'
                'import sys\n'
                'assert sys.argv[1].endswith(".l")\n'
                'assert sys.argv[2] == "--emit-lir"\n'
                f'print({lir!r},end="")\n',encoding='utf-8')
            fake.chmod(0o755)
            source=d/'example.l';source.write_text('fn main() -> Int { print(42)\nreturn 0\n}',encoding='utf-8')
            exe=d/'native';saved=d/'record.lir'
            cmd=[sys.executable,str(ROOT/'tools'/'ele_build.py'),str(source),
                 '--stage1',str(fake),'-o',str(exe),'--cc',CC,'--keep-lir',str(saved)]
            result=subprocess.run(cmd,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(saved.read_text(),lir)
            result=subprocess.run([str(exe)],capture_output=True,text=True)
            self.assertEqual((result.returncode,result.stdout,result.stderr),(0,'42\n',''))

    def test_stage1_nonzero_does_not_compile(self):
        with tempfile.TemporaryDirectory() as d:
            d=Path(d);fake=d/'stage1'
            fake.write_text('#!/usr/bin/env python3\nimport sys\nsys.exit(7)\n',encoding='utf-8')
            fake.chmod(0o755)
            source=d/'bad.l';source.write_text('invalid',encoding='utf-8')
            result=subprocess.run([sys.executable,str(ROOT/'tools'/'ele_build.py'),str(source),
                                   '--stage1',str(fake),'-o',str(d/'out')],capture_output=True,text=True)
            self.assertEqual(result.returncode,7)
            self.assertFalse((d/'out').exists())


if __name__=='__main__':unittest.main()
