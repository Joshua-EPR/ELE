#!/usr/bin/env python3
"""Experimental Rust-free ELE-LIR 1 -> portable C11 -> native executable.

This is an alternative bootstrap backend, NOT a self-hosted ELE compiler.
Only verified/implemented operations are accepted. It never invokes Rust or
Cranelift. Generated C uses the project-local ELE runtime header.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import shutil
import subprocess
import sys

MAX_BYTES = 64 * 1024 * 1024
MAX_ROWS = 200_000  # additional, conservative bound for this experimental backend
MAX_TEXT = 1 << 20


class LirError(Exception):
    def __init__(self, line: int, message: str):
        super().__init__(f"L0017 [ELE-LIR line {line}]: {message}")
        self.line = line


def require(cond: bool, line: int, msg: str) -> None:
    if not cond:
        raise LirError(line, msg)


def number(s: str, line: int, limit: int = MAX_ROWS) -> int:
    require(bool(re.fullmatch(r"(?:0|[1-9][0-9]*)", s)), line, f"invalid nonnegative integer: {s}")
    n = int(s)
    require(n <= limit, line, "count exceeds portable backend bound")
    return n


def encoded_text(s: str, line: int) -> str:
    m = re.fullmatch(r"(0|[1-9][0-9]*):(.*)", s)
    require(m is not None, line, "invalid length-prefixed text")
    length = number(m.group(1), line, MAX_TEXT)
    chunks = m.group(2).split(",") if m.group(2) else []
    require(length == len(chunks), line, "text byte count mismatch")
    result = bytearray()
    for b in chunks:
        result.append(number(b, line, 255))
    try:
        return result.decode("utf-8", "strict")
    except UnicodeDecodeError:
        raise LirError(line, "invalid UTF-8 text") from None


def check_id(s: str, prefix: str, n: int, line: int) -> int:
    require(s.startswith(prefix), line, f"expected {prefix} ID")
    value = number(s[len(prefix):], line)
    require(value < n, line, f"{prefix} ID out of range")
    return value


@dataclass
class Record:
    line: int
    words: list[str]


@dataclass
class Block:
    instructions: list[Record]
    terminator: Record


@dataclass
class Func:
    name: str
    params: int
    result: str
    result_ref: bool
    result_mut: bool
    vars: list[tuple[bool, str]]
    blocks: list[Block]


@dataclass
class Module:
    structs: list[list[str]]
    lists: list[str]
    funcs: list[Func]
    main: int


class Reader:
    def __init__(self, content: str):
        self.lines = content.splitlines()
        self.cursor = 0

    def get(self, prefix: str | None = None) -> Record:
        line = self.cursor + 1
        require(self.cursor < len(self.lines), line, "unexpected end of LIR")
        raw = self.lines[self.cursor]
        self.cursor += 1
        require(raw and raw == raw.strip(" ") and "  " not in raw and "\t" not in raw,
                line, "invalid line separators")
        words = raw.split(" ")
        if prefix is not None:
            require(words[0] == prefix, line, f"expected '{prefix}'")
        return Record(line, words)


def parse_type(s: str, line: int, structs: int, lists: int) -> str:
    if s in ("i", "b", "t", "u"):
        return s
    if s == "f":
        raise LirError(line, "Float is not supported by the C backend")
    if s.startswith("s"):
        check_id(s, "s", structs, line)
        return s
    if s.startswith("l"):
        check_id(s, "l", lists, line)
        return s
    raise LirError(line, f"unsupported or unknown type: {s}")




def strip_span(rec: Record) -> Record:
    if rec.words and rec.words[-1].startswith("@"):
        require(bool(re.fullmatch(r"@[0-9]+:[0-9]+", rec.words[-1])), rec.line,
                "invalid source position")
        return Record(rec.line, rec.words[:-1])
    return rec

def parse(content: str) -> Module:
    require(len(content.encode("utf-8")) <= MAX_BYTES, 1, "LIR too large")
    r = Reader(content)
    h = r.get()
    require(h.words == ["ELE-LIR", "1"], h.line, "unsupported LIR version")
    m = r.get("module")
    w = m.words
    require(len(w) >= 7 and w[1] == "structs", m.line, "invalid module header")
    structs = number(w[2], m.line)
    pos = 3
    if pos < len(w) and w[pos] == "enums":
        require(pos + 1 < len(w), m.line, "missing enum count")
        require(number(w[pos+1], m.line) == 0, m.line, "enums not yet supported by C backend")
        pos += 2
    lists = 0
    if pos < len(w) and w[pos] == "lists":
        require(pos + 1 < len(w), m.line, "missing list count")
        lists = number(w[pos+1], m.line)
        pos += 2
    require(w[pos:pos+1] == ["funcs"] and len(w) == pos + 4 and w[pos+2] == "main", m.line,
            "invalid module function header")
    funcs = number(w[pos+1], m.line)
    require(funcs > 0, m.line, "module must have functions")
    main = check_id(w[pos+3], "f", funcs, m.line)

    struct_defs: list[list[str]] = []
    for k in range(structs):
        rec = r.get("struct")
        require(len(rec.words) == 5 and rec.words[3] == "fields", rec.line, "invalid struct header")
        require(check_id(rec.words[1], "s", structs, rec.line) == k, rec.line, "out-of-order struct")
        encoded_text(rec.words[2], rec.line)
        n = number(rec.words[4], rec.line)
        fields = []
        for _ in range(n):
            f = r.get("field")
            require(len(f.words) == 3, f.line, "invalid field")
            encoded_text(f.words[1], f.line)
            fields.append(parse_type(f.words[2], f.line, structs, lists))
        struct_defs.append(fields)

    list_defs = []
    for k in range(lists):
        rec = r.get("list")
        require(len(rec.words) == 3, rec.line, "invalid list header")
        require(check_id(rec.words[1], "l", lists, rec.line) == k, rec.line, "out-of-order list")
        list_defs.append(parse_type(rec.words[2], rec.line, structs, lists))
    functions: list[Func] = []
    for idx in range(funcs):
        rec = r.get("func")
        w = rec.words
        require(len(w) == 13 and w[3] == "params" and w[5] == "result" and
                w[9] == "vars" and w[11] == "blocks", rec.line, "invalid function header")
        require(check_id(w[1], "f", funcs, rec.line) == idx, rec.line, "out-of-order function")
        name = encoded_text(w[2], rec.line)
        params = number(w[4], rec.line)
        result = parse_type(w[6], rec.line, structs, lists)
        require(w[7] in ("0", "1") and w[8] in ("0", "1"), rec.line, "invalid reference flags")
        result_ref = w[7] == "1"
        result_mut = w[8] == "1"
        require(not result_ref and not result_mut, rec.line,
                "borrowed function returns are not yet supported by C backend")
        nvars = number(w[10], rec.line)
        nblocks = number(w[12], rec.line)
        require(nblocks > 0 and params <= nvars, rec.line, "invalid variables or blocks")
        vars_: list[tuple[bool, str]] = []
        for v in range(nvars):
            item = r.get("var")
            require(len(item.words) == 4, item.line, "invalid variable")
            require(check_id(item.words[1], "v", nvars, item.line) == v,
                    item.line, "out-of-order variable")
            require(item.words[2] in ("ref", "val"), item.line, "invalid variable class")
            vars_.append((item.words[2] == "ref",
                          parse_type(item.words[3], item.line, structs, lists)))
        blocks_: list[Block] = []
        for b in range(nblocks):
            line = r.get("block")
            require(len(line.words) == 3, line.line, "invalid block header")
            require(number(line.words[1], line.line) == b, line.line, "out-of-order block")
            count = number(line.words[2], line.line)
            instructions = []
            for _ in range(count):
                inst = r.get("i")
                instructions.append(strip_span(inst))
            term = strip_span(r.get("t"))
            blocks_.append(Block(instructions, term))
        endfunc = r.get("endfunc")
        require(len(endfunc.words) == 1, endfunc.line, "extra fields after endfunc")
        functions.append(Func(name, params, result, result_ref, result_mut, vars_, blocks_))
    end = r.get("end")
    require(len(end.words) == 1 and r.cursor == len(r.lines), end.line,
            "extra content after module end")
    require(functions[main].params == 0 and functions[main].result == "i", m.line,
            "entrypoint must be fn main() -> Int")
    return Module(struct_defs, list_defs, functions, main)


class Cursor:
    def __init__(self, record: Record, start: int = 2):
        self.rec = record
        self.at = start

    def next(self) -> str:
        require(self.at < len(self.rec.words), self.rec.line, "missing field")
        value = self.rec.words[self.at]
        self.at += 1
        return value

    def count(self) -> int:
        return number(self.next(), self.rec.line)

    def done(self) -> None:
        require(self.at == len(self.rec.words), self.rec.line, "unexpected extra fields")


class Codegen:
    def __init__(self, module: Module):
        self.m = module
        self.f: Func | None = None
        self.seq = 0
        self.lines: list[str] = []

    def write(self, code: str) -> None:
        self.lines.append("    " + code)

    def temporary(self, prefix: str = "tmp") -> str:
        self.seq += 1
        return f"ele_{prefix}_{self.seq}"

    def variable(self, token: str, line: int) -> tuple[int, bool, str]:
        assert self.f is not None
        n = check_id(token, "v", len(self.f.vars), line)
        isref, ty = self.f.vars[n]
        return n, isref, ty

    def place(self, token: str, line: int) -> tuple[str, str]:
        assert self.f is not None
        match = re.fullmatch(r"p(0|[1-9][0-9]*)((?:\.[0-9]+|\[v[0-9]+\])*)", token)
        require(match is not None, line, f"invalid place: {token}")
        root = check_id("v"+match.group(1), "v", len(self.f.vars), line)
        ty = self.f.vars[root][1]
        code = f"ele_deref(&v[{root}])"
        rest = match.group(2)
        projections = re.findall(r"\.[0-9]+|\[v[0-9]+\]", rest)
        require("".join(projections) == rest and len(projections) <= 64, line,
                "invalid/excessive place projections")
        for p in projections:
            if p.startswith("."):
                require(ty.startswith("s"), line, "field access on non-struct")
                s = check_id(ty, "s", len(self.m.structs), line)
                field = number(p[1:], line)
                require(field < len(self.m.structs[s]), line, "struct field out of range")
                ty = self.m.structs[s][field]
                code = f"ele_field({code}, {field})"
            else:
                require(ty.startswith("l"), line, "index on non-list")
                l = check_id(ty, "l", len(self.m.lists), line)
                idx, isref, ity = self.variable(p[1:-1], line)
                require(not isref and ity == "i", line, "index variable must be Int")
                ty = self.m.lists[l]
                code = f"ele_index({code}, ele_as_int(&v[{idx}]))"
        return ty, code

    def operand(self, s: str, line: int) -> tuple[str, str]:
        if s.startswith("ci"):
            raw = s[2:]
            require(re.fullmatch(r"-?(0|[1-9][0-9]*)", raw) is not None, line,
                    "invalid Int constant")
            n = int(raw)
            require(-(1<<63) <= n < (1<<63), line, "Int constant overflows i64")
            numeric = "(-9223372036854775807LL-1LL)" if n == -(1<<63) else f"{n}LL"
            return "i", f"ele_int({numeric})"
        if s in ("cb0", "cb1"):
            return "b", f"ele_bool({'true' if s == 'cb1' else 'false'})"
        if s == "cu":
            return "u", "ele_unit()"
        if s.startswith("ct"):
            text = encoded_text(s[2:], line).encode("utf-8")
            data = "(const unsigned char[]){" + ",".join(f"0x{b:02x}" for b in text) + "}" if text else '(const unsigned char *)""'
            return "t", f"ele_text({data}, {len(text)}U)"
        idx, isref, ty = self.variable(s, line)
        require(not isref, line, "reference variable cannot be passed by value")
        return ty, f"ele_take(&v[{idx}])"

    def argument(self, cur: Cursor) -> tuple[str, str, bool]:
        kind = cur.next()
        if kind == "val":
            ty, code = self.operand(cur.next(), cur.rec.line)
            return ty, code, False
        require(kind == "ref", cur.rec.line, "expected val or ref argument")
        ty, code = self.place(cur.next(), cur.rec.line)
        require(cur.next() in ("0", "1"), cur.rec.line, "invalid mutability flag")
        return ty, f"ele_borrow({code})", True

    def dest(self, cur: Cursor, ty: str, ref: bool = False) -> int:
        idx, isref, actual = self.variable(cur.next(), cur.rec.line)
        require((isref, actual) == (ref, ty), cur.rec.line,
                f"destination type mismatch (expected {'ref ' if ref else ''}{ty})")
        return idx

    def assign(self, idx: int, expr: str) -> None:
        self.write(f"ele_assign(&v[{idx}], {expr});")

    def make_args(self, cur: Cursor, count: int, types: list[tuple[bool, str]] | None = None) -> list[str]:
        arg_names: list[str] = []
        for k in range(count):
            ty, expression, ref = self.argument(cur)
            if types is not None:
                require(k < len(types) and types[k] == (ref, ty), cur.rec.line,
                        "call argument type/borrow mismatch")
            v = self.temporary("arg")
            self.write(f"EleValue {v} = {expression};")
            arg_names.append(v)
        return arg_names

    def emit_inst(self, record: Record) -> None:
        words = record.words
        require(len(words) >= 2, record.line, "empty LIR instruction")
        op = words[1]
        cur = Cursor(record)
        if op == "use":
            dst = cur.next()
            ty, expr = self.operand(cur.next(), record.line)
            idx = self.dest(Cursor(Record(record.line, ["", "", dst])), ty)
            self.assign(idx, expr)
        elif op == "unary":
            dest = cur.next()
            which = cur.next()
            ty, value = self.operand(cur.next(), record.line)
            require((which,ty) in (("neg","i"),("not","b")), record.line,
                    "invalid unary operation")
            expected = ty
            idx = self.dest(Cursor(Record(record.line,["","",dest])),expected)
            v = self.temporary()
            self.write(f"EleValue {v} = {value};")
            expr = f"ele_int(ele_ineg(ele_as_int(&{v})))" if which=="neg" else f"ele_bool(!ele_as_bool(&{v}))"
            self.assign(idx,expr)
            self.write(f"ele_drop(&{v});")
        elif op == "binary":
            dest, operation = cur.next(), cur.next()
            at, av = self.operand(cur.next(), record.line)
            bt, bv = self.operand(cur.next(), record.line)
            require(at == bt, record.line, "binary operand type mismatch")
            math_ops = {"add":"ele_iadd", "sub":"ele_isub", "mul":"ele_imul", "div":"ele_idiv", "rem":"ele_irem"}
            comparisons = {"eq":"==", "ne":"!=", "lt":"<", "le":"<=", "gt":">", "ge":">="}
            require(operation in math_ops or operation in comparisons,record.line,"unknown binary operator")
            if operation in math_ops:
                require(at=="i", record.line, "arithmetic requires Int")
                result = "i"
            else:
                require(at in ("i", "b") and (at=="i" or operation in ("eq","ne")),
                        record.line, "unsupported comparison")
                result = "b"
            idx = self.dest(Cursor(Record(record.line,["","",dest])),result)
            a=self.temporary("left");b=self.temporary("right")
            self.write(f"EleValue {a} = {av};")
            self.write(f"EleValue {b} = {bv};")
            x=f"ele_as_{'int' if at=='i' else 'bool'}(&{a})"
            y=f"ele_as_{'int' if at=='i' else 'bool'}(&{b})"
            if operation in math_ops:
                expr=f"ele_int({math_ops[operation]}({x}, {y}))"
            else:
                expr=f"ele_bool({x} {comparisons[operation]} {y})"
            self.assign(idx,expr)
            self.write(f"ele_drop(&{a}); ele_drop(&{b});")
        elif op == "call":
            dst, fnid = cur.next(), cur.next()
            k = check_id(fnid,"f",len(self.m.funcs),record.line)
            callee = self.m.funcs[k]
            count=cur.count()
            require(count==callee.params,record.line,"call arity mismatch")
            require(not callee.result_ref,record.line,"borrowed returns unsupported")
            idx=self.dest(Cursor(Record(record.line,["","",dst])),callee.result)
            args=self.make_args(cur,count,callee.vars[:count])
            self.assign(idx, f"ele_fn_{k}({', '.join(args) if args else 'void_dummy_unsupported'})" if args else f"ele_fn_{k}()")
        elif op == "struct":
            dst, struct_id = cur.next(), cur.next()
            k=check_id(struct_id,"s",len(self.m.structs),record.line)
            count=cur.count()
            require(count==len(self.m.structs[k]),record.line,"wrong struct field count")
            idx=self.dest(Cursor(Record(record.line,["","",dst])),f"s{k}")
            values=[]
            for f in range(count):
                ty, expr=self.operand(cur.next(),record.line)
                require(ty==self.m.structs[k][f],record.line,"incorrect struct field type")
                name=self.temporary("field")
                self.write(f"EleValue {name} = {expr};")
                values.append(name)
            arr = "(EleValue[]){"+", ".join(values)+"}" if values else "NULL"
            self.assign(idx,f"ele_struct({count}, {arr}, {k})")
        elif op == "listlit":
            dst, lid=cur.next(),cur.next()
            k=check_id(lid,"l",len(self.m.lists),record.line)
            count=cur.count()
            idx=self.dest(Cursor(Record(record.line,["","",dst])),f"l{k}")
            values=[]
            for _ in range(count):
                ty, expr=self.operand(cur.next(),record.line)
                require(ty==self.m.lists[k],record.line,"wrong list item type")
                name=self.temporary("item");self.write(f"EleValue {name} = {expr};")
                values.append(name)
            arr="(EleValue[]){"+", ".join(values)+"}" if values else "NULL"
            self.assign(idx,f"ele_list({count}, {arr}, {k})")
        elif op == "read":
            dst=cur.next()
            ty, place=self.place(cur.next(),record.line)
            require(ty in ("i","b","u"),record.line,"read of non-Copy value")
            idx=self.dest(Cursor(Record(record.line,["","",dst])),ty)
            self.assign(idx,f"ele_copy({place})")
        elif op == "loan":
            dst=cur.next()
            ty, place=self.place(cur.next(),record.line)
            require(cur.next() in ("0","1"),record.line,"invalid loan flag")
            idx=self.dest(Cursor(Record(record.line,["","",dst])),ty,True)
            self.assign(idx,f"ele_borrow({place})")
        elif op == "textbuf":
            idx=self.dest(cur,"t")
            cap=cur.count()
            self.assign(idx,f"ele_textbuf({cap})")
        elif op == "append":
            idx=self.dest(cur,"t")
            ty, expr, ref=self.argument(cur)
            require(ty in ("i","b","u","t"),record.line,"unsupported append type")
            t=self.temporary();self.write(f"EleValue {t} = {expr};")
            self.write(f"ele_append(&v[{idx}], &{t}, {'false' if ref else 'true'});")
        elif op == "store":
            ty, place=self.place(cur.next(),record.line)
            ity, expr=self.operand(cur.next(),record.line)
            require(ity==ty,record.line,"store type mismatch")
            p=self.temporary("place");v=self.temporary()
            self.write(f"EleValue *{p} = {place};")
            self.write(f"EleValue {v} = {expr};")
            self.write(f"ele_assign({p}, {v});")
        elif op == "print":
            ty, expr, ref=self.argument(cur)
            require(ty in ("i","b","u","t"),record.line,"unsupported print type")
            t=self.temporary();self.write(f"EleValue {t} = {expr};")
            self.write(f"ele_print_arg(&{t}, {'false' if ref else 'true'}, false);")
        elif op == "drop":
            idx, _, _ = self.variable(cur.next(),record.line)
            flag=cur.next()
            if flag!="-":
                fidx, isref, fty=self.variable(flag,record.line)
                require(not isref and fty=="b",record.line,"drop flag must be Bool")
                self.write(f"if(ele_as_bool(&v[{fidx}])) ele_drop(&v[{idx}]);")
            else:self.write(f"ele_drop(&v[{idx}]);")
        elif op == "dropfield":
            ptext=cur.next()
            require("." in ptext or "[" in ptext,record.line,"dropfield needs projection")
            _, place=self.place(ptext,record.line)
            flag=cur.next()
            if flag!="-":
                fidx,isref,fty=self.variable(flag,record.line)
                require(not isref and fty=="b",record.line,"dropfield flag must be Bool")
                self.write(f"if(ele_as_bool(&v[{fidx}])) ele_drop({place});")
            else:self.write(f"ele_drop({place});")
        elif op in ("len","cap"):
            dst=cur.next()
            ty, place=self.place(cur.next(),record.line)
            require((op=="len" and (ty=="t" or ty.startswith("l"))) or
                    (op=="cap" and ty.startswith("l")), record.line,
                    "length/capacity type mismatch")
            idx=self.dest(Cursor(Record(record.line,["","",dst])),"i")
            self.assign(idx,f"ele_int(ele_{op}({place}))")
        elif op in ("listpush", "listreserve"):
            ty, place=self.place(cur.next(),record.line)
            require(ty.startswith("l"),record.line,"operation requires List")
            k=check_id(ty,"l",len(self.m.lists),record.line)
            vt, expr=self.operand(cur.next(),record.line)
            require(vt==("i" if op=="listreserve" else self.m.lists[k]),record.line,
                    "invalid list operand type")
            t=self.temporary();self.write(f"EleValue {t} = {expr};")
            if op=="listpush": self.write(f"ele_list_push({place}, {t});")
            else:
                self.write(f"ele_list_reserve({place}, ele_as_int(&{t}));")
                self.write(f"ele_drop(&{t});")
        elif op == "byteat":
            dst=cur.next()
            ty,place=self.place(cur.next(),record.line)
            vt,expr=self.operand(cur.next(),record.line)
            require(ty=="t" and vt=="i",record.line,"byteAt requires Text and Int")
            idx=self.dest(Cursor(Record(record.line,["","",dst])),"i")
            t=self.temporary();self.write(f"EleValue {t} = {expr};")
            self.assign(idx,f"ele_int(ele_byte_at({place}, ele_as_int(&{t})))")
            self.write(f"ele_drop(&{t});")
        else:
            raise LirError(record.line, f"instruction '{op}' not implemented by the Rust-free backend")
        cur.done()

    def emit_terminator(self, record: Record, blocks: int) -> None:
        require(len(record.words)>=2,record.line,"missing terminator")
        cur=Cursor(record)
        op=record.words[1]
        if op=="jump":
            b=cur.count();require(b<blocks,record.line,"jump target out of range")
            self.write(f"goto block_{b};")
        elif op=="branch":
            ty, expr=self.operand(cur.next(),record.line)
            require(ty=="b",record.line,"branch condition must be Bool")
            a=cur.count();b=cur.count()
            require(a<blocks and b<blocks,record.line,"branch target out of range")
            t=self.temporary();self.write(f"EleValue {t} = {expr};")
            self.write(f"bool ele_cond = ele_as_bool(&{t});")
            self.write(f"ele_drop(&{t});")
            self.write(f"if(ele_cond) goto block_{a}; else goto block_{b};")
        elif op=="return":
            ty, expr=self.operand(cur.next(),record.line)
            require(ty==self.f.result,record.line,"return type mismatch")
            t=self.temporary("result")
            self.write(f"EleValue {t} = {expr};")
            self.write(f"ele_drop_locals(v, {len(self.f.vars)}); free(v); return {t};")
        elif op=="unreachable":
            self.write('ele_die("unreachable executed");')
        else:
            raise LirError(record.line, f"unsupported terminator '{op}'")
        cur.done()

    def function_code(self, index: int, func: Func) -> str:
        self.f=func
        self.seq=0
        self.lines=[]
        params=", ".join(f"EleValue a{i}" for i in range(func.params)) if func.params else "void"
        self.lines.append(f"static EleValue ele_fn_{index}({params}) {{")
        n=len(func.vars)
        self.write(f"EleValue *v = ele_malloc({max(1,n)} * sizeof(EleValue));")
        self.write(f"for(size_t z=0;z<{n};z++) v[z]=ele_nil();")
        for i in range(func.params): self.write(f"v[{i}]=a{i};")
        self.write("goto block_0;")
        for b,block in enumerate(func.blocks):
            self.lines.append(f"block_{b}: {{")
            for instruction in block.instructions:
                self.emit_inst(instruction)
            self.emit_terminator(block.terminator,len(func.blocks))
            self.lines.append("}")
        self.lines.append("}")
        return "\n".join(self.lines)

    def c_program(self) -> str:
        header=Path(__file__).with_name("ele_runtime.h").read_text(encoding="utf-8")
        signatures=[]
        for idx, func in enumerate(self.m.funcs):
            args=", ".join("EleValue" for _ in range(func.params)) if func.params else "void"
            signatures.append(f"static EleValue ele_fn_{idx}({args});")
        code=[header, "\n/* Emitted by ELE portable C backend; untrusted LIR is validated before emission. */",
              "\n".join(signatures)]
        for idx, func in enumerate(self.m.funcs):
            code.append(self.function_code(idx,func))
        code.append(f'''int main(int argc, char **argv) {{
    ele_argc=argc; ele_argv=argv;
    EleValue out=ele_fn_{self.m.main}();
    int64_t result=ele_as_int(&out);
    ele_drop(&out);
    return (int)(unsigned char)result;
}}''')
        return "\n\n".join(code)+"\n"


def compile_lir(source: Path, output: Path | None, cc: str | None, emit_c: Path | None,
                check: bool) -> None:
    size=source.stat().st_size
    require(size<=MAX_BYTES,1,"LIR too large")
    try:
        content=source.read_text(encoding="utf-8",errors="strict")
    except UnicodeError:
        raise LirError(1,"LIR is not valid UTF-8") from None
    module=parse(content)
    c=Codegen(module).c_program()  # validates every operation before writing any output
    if check:
        print(f"ELE-LIR 1 accepted: {len(module.funcs)} functions, {len(module.structs)} structs, {len(module.lists)} lists")
        return
    if emit_c:
        emit_c.parent.mkdir(parents=True,exist_ok=True)
        emit_c.write_text(c,encoding="utf-8")
    if output:
        compiler=cc or shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
        if not compiler: raise RuntimeError("C11 compiler not found; use --cc or --emit-c")
        import tempfile
        with tempfile.TemporaryDirectory(prefix="ele_cgen_") as d:
            src=Path(d)/"program.c"
            src.write_text(c,encoding="utf-8")
            output.parent.mkdir(parents=True,exist_ok=True)
            subprocess.run([compiler,"-std=c11","-O2",str(src),"-o",str(output)],check=True)
    if not output and not emit_c:
        raise RuntimeError("specify --output, --emit-c or --check")


def main() -> int:
    ap=argparse.ArgumentParser(description="ELE-LIR to native C11 codegen without Rust or Cranelift")
    ap.add_argument("input",type=Path,help="ELE-LIR 1 text generated by Stage 1")
    ap.add_argument("-o","--output",type=Path,help="native executable output")
    ap.add_argument("--emit-c",type=Path,help="write standalone portable C11 source")
    ap.add_argument("--cc",help="C11 compiler executable (GCC or Clang)")
    ap.add_argument("--check",action="store_true",help="validate supported LIR without compiling")
    args=ap.parse_args()
    try:
        compile_lir(args.input,args.output,args.cc,args.emit_c,args.check)
    except (LirError,RuntimeError,OSError,subprocess.CalledProcessError) as e:
        print(f"ELE backend error: {e}",file=sys.stderr)
        return 1
    return 0


if __name__=="__main__":
    sys.exit(main())
