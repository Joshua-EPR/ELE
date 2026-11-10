"""Rust-free end-to-end native code generation tests for ELE-LIR 1."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "tools" / "ele_c_backend.py"
CC = shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")


def enc(text: str) -> str:
    data=text.encode("utf-8")
    return f"{len(data)}:"+",".join(str(x) for x in data)


def program(*, structs: list[str] | None = None, lists: list[str] | None = None,
            functions: list[tuple[str,list[str],list[tuple[str,list[str],str]]]], main=0):
    structs=structs or []
    lists=lists or []
    num_structs=sum(1 for row in structs if row.startswith("struct "))
    lines=["ELE-LIR 1", f"module structs {num_structs}"+
           (f" lists {len(lists)}" if lists else "")+
           f" funcs {len(functions)} main f{main}"]
    if structs:
        # Struct definitions interleave each header with its own field records.
        lines.extend(structs)
    for k,ty in enumerate(lists):lines.append(f"list l{k} {ty}")
    for k,(name,vars_,blocks) in enumerate(functions):
        # name, parameter count, result, and variable signatures separated by ::
        nm,pc,ret=name.split("::")
        lines.append(f"func f{k} {enc(nm)} params {pc} result {ret} 0 0 vars {len(vars_)} blocks {len(blocks)}")
        lines.extend(f"var v{i} {v}" for i,v in enumerate(vars_))
        for i,(unused,insts,term) in enumerate(blocks):
            lines.append(f"block {i} {len(insts)}")
            lines.extend("i "+s for s in insts)
            lines.append("t "+term)
        lines.append("endfunc")
    lines.append("end")
    return "\n".join(lines)+"\n"


@unittest.skipUnless(CC, "requires a C11 compiler")
class NativeBackendTest(unittest.TestCase):
    def compile_run(self, lir: str, *, args: list[str] | None = None):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)
            (p/"input.lir").write_text(lir,encoding="utf-8")
            exe=p/"out"
            build=subprocess.run([sys.executable,str(TOOL),str(p/"input.lir"),
                                  "--output",str(exe),"--cc",CC],capture_output=True,text=True)
            self.assertEqual(build.returncode,0,build.stderr)
            return subprocess.run([str(exe),*(args or [])],capture_output=True,text=True)

    def reject(self, lir: str, expected: str):
        with tempfile.TemporaryDirectory() as d:
            src=Path(d)/"bad.lir"
            src.write_text(lir,encoding="utf-8")
            proc=subprocess.run([sys.executable,str(TOOL),str(src),"--check"],
                                capture_output=True,text=True)
            self.assertNotEqual(proc.returncode,0)
            self.assertIn("L0017",proc.stderr)
            self.assertIn(expected,proc.stderr)

    def test_arithmetic_and_function_calls(self):
        lir=program(functions=[
            ("main::0::i",["val i","val b"],[("",[
                "call v0 f1 2 val ci20 val ci22",
                "binary v1 eq v0 ci42",
                "print val v0"],"branch v1 1 2"),
                ("",[],"return ci0"),("",[],"return ci3")]),
            ("add::2::i",["val i","val i","val i"],[("",["binary v2 add v0 v1"],"return v2")])
        ])
        result=self.compile_run(lir)
        self.assertEqual((result.returncode,result.stdout,result.stderr),(0,"42\n",""))

    def test_list_literals_index_updates_and_bounds(self):
        lir=program(lists=["i"],functions=[
            ("main::0::i",["val l0","val i","val i","val b","val i"],[("",[
                "listlit v0 l0 2 ci5 ci7",
                "listpush p0 ci11",
                "listreserve p0 ci8",
                "use v1 ci1",
                "store p0[v1] ci42",
                "len v2 p0",
                "binary v3 eq v2 ci3"
            ],"branch v3 1 2"),
                ("",["read v4 p0[v1]","print val v4","drop v0 -"],"return ci0"),
                ("",["drop v0 -"],"return ci1")])])
        result=self.compile_run(lir)
        self.assertEqual((result.returncode,result.stdout,result.stderr),(0,"42\n",""))
        broken=lir.replace("use v1 ci1", "use v1 ci100")
        result=self.compile_run(broken)
        self.assertEqual(result.returncode,1)
        self.assertIn("index out of range",result.stderr)

    def test_loop_with_backedge(self):
        lir=program(functions=[
            ("main::0::i",["val i","val b","val i"],[
                ("",["use v0 ci0"],"jump 1"),
                ("",["binary v1 lt v0 ci5"],"branch v1 2 3"),
                ("",["binary v2 add v0 ci1","use v0 v2"],"jump 1"),
                ("",["print val v0"],"return ci0")
            ])])
        result=self.compile_run(lir)
        self.assertEqual((result.returncode,result.stdout,result.stderr),(0,"5\n",""))

    def test_owned_text_list_recursive_drop(self):
        lir=program(lists=["t"],functions=[
            ("main::0::i",["val l0","val i"],[("",[
                f"listlit v0 l0 2 ct{enc('hola')} ct{enc('✓')}",
                "len v1 p0", "drop v0 -"],"return v1")])])
        result=self.compile_run(lir)
        self.assertEqual((result.returncode,result.stdout,result.stderr),(2,"",""))

    def test_text_concat_unicode_and_byteat(self):
        lir=program(functions=[
            ("main::0::i",["val t","val t","val i"],[("",[
                "textbuf v0 4",
                f"use v1 ct{enc('ELE ✓')}",
                "append v0 val v1",
                "print ref p0 0",
                "byteat v2 p0 ci0",
                "drop v0 -"],"return v2")])])
        result=self.compile_run(lir)
        self.assertEqual((result.returncode,result.stdout,result.stderr),(69,"ELE ✓\n",""))

    def test_struct_field_and_drop(self):
        defs=[f"struct s0 {enc('Pair')} fields 2",
              f"field {enc('num')} i", f"field {enc('text')} t"]
        lir=program(structs=defs,functions=[
            ("main::0::i",["val s0","val i"],[("",[
                f"struct v0 s0 2 ci12 ct{enc('hola')}",
                "read v1 p0.0", "dropfield p0.1 -", "drop v0 -"],"return v1")])])
        result=self.compile_run(lir)
        self.assertEqual((result.returncode,result.stdout,result.stderr),(12,"",""))

    def test_ref_parameter(self):
        lir=program(functions=[
            ("main::0::i",["val i","val i"],[("",[
                "use v0 ci31", "call v1 f1 1 ref p0 0"],"return v1")]),
            ("readref::1::i",["ref i","val i"],[("",[
                "read v1 p0"],"return v1")])])
        result=self.compile_run(lir)
        self.assertEqual((result.returncode,result.stdout,result.stderr),(31,"",""))

    def test_checked_integer_overflow(self):
        lir=program(functions=[("main::0::i",["val i"],[("",[
            "binary v0 add ci9223372036854775807 ci1"],"return v0")])])
        result=self.compile_run(lir)
        self.assertNotEqual(result.returncode,0)
        self.assertIn("integer overflow",result.stderr)

    def test_malformed_and_unsupported_rejected_before_codegen(self):
        src=program(functions=[("main::0::i",["val i"],[("",[
            "binary v0 add ci2 cb1"],"return v0")])])
        self.reject(src,"binary operand type mismatch")
        src=src.replace("binary v0 add ci2 cb1","platform v0 argcount 0")
        self.reject(src,"not implemented")
        src=src.replace("platform v0 argcount 0","use v0 ci9223372036854775808")
        self.reject(src,"overflows")
        src=src.replace("use v0 ci9223372036854775808","use v0 ct1:255")
        self.reject(src,"invalid UTF-8")

    def test_deterministic_c_and_no_rust_invocation(self):
        lir=program(functions=[("main::0::i",[],[("",[],"return ci0")])])
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);src=p/"src.lir";src.write_text(lir,encoding="utf-8")
            a=p/"a.c";b=p/"b.c"
            for output in (a,b):
                result=subprocess.run([sys.executable,str(TOOL),str(src),"--emit-c",str(output)],
                                      capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(a.read_bytes(),b.read_bytes())
            self.assertNotIn("rustc",a.read_text())
            exe=p/"app"
            result=subprocess.run([CC,"-std=c11",str(a),"-o",str(exe)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(subprocess.run([str(exe)]).returncode,0)


if __name__ == "__main__":
    unittest.main()
