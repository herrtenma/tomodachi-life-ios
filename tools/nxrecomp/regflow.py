"""Per-instruction register def/use (from llvm-objdump text), intra-function CFG
with jump-table resolution, and whole-register-file liveness."""
import re
import struct

_REG = re.compile(r"\b([xw])([0-9]|[12][0-9]|30)\b")
_HEX = re.compile(r"0x([0-9a-f]+)")

NO_DEST = {
    "cmp", "cmn", "tst", "ccmp", "ccmn", "cbz", "cbnz", "tbz", "tbnz", "b", "bl", "br", "blr",
    "ret", "prfm", "prfum", "msr", "hint", "nop", "dmb", "dsb", "isb", "brk", "svc", "hlt",
    "fcmp", "fcmpe", "fccmp", "fccmpe", "dc", "ic", "at", "tlbi", "sys", "clrex", "yield",
    "wfe", "wfi", "sev", "sevl", "udf", "csdb", "bti", "esb",
}
# Destination register is also read (insert into existing value).
READS_DEST = {"movk", "bfi", "bfxil", "bfm", "bfc"}
# Atomic compare-and-swap: operand 0 (pair for casp) is read and written.
RMW_FIRST = re.compile(r"^(cas|casp)(a|al|l)?[bh]?$")
# ld<op>/swp: operand 0 read, operand 1 written.
ATOMIC_LD = re.compile(r"^(ld(add|clr|eor|set|smax|smin|umax|umin)|swp)(a|al|l)?[bh]?$")
# Store-exclusive: operand 0 is the written status register.
STORE_EXCL = re.compile(r"^st(l)?xr[bh]?$|^st(l)?xp$")
PAIR_LOAD = re.compile(r"^ld(n)?p(sw)?$|^ld(a)?xp$")

ALL = (1 << 31) - 1
ARGS = (1 << 9) - 1                                   # x0-x8 (x8 = indirect result)
CALLEE_SAVED = sum(1 << r for r in range(19, 30))     # x19-x29
LR = 1 << 30
CALL_CLOBBER = ((1 << 19) - 1) | LR                   # x0-x18, x30


def strip_comment(text):
    i = text.find("//")
    return text[:i].rstrip() if i >= 0 else text


def split_operands(ops):
    parts, depth, cur = [], 0, ""
    for ch in ops:
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur.strip())
    return parts


def regs_in(s):
    m = 0
    for _, n in _REG.findall(s):
        m |= 1 << int(n)
    return m


def parse(text):
    """Return (mnemonic, operand list) from objdump text."""
    text = strip_comment(text)
    text = re.sub(r"\s*<[^>]*>", "", text)  # symbolic target annotations
    mn, _, ops = text.partition("\t")
    return mn.strip(), split_operands(ops.strip()) if ops else []


def defs_uses(mn, ops):
    """(defined GPR mask, used GPR mask) from the explicit operands of one instruction.
    Vector/FP registers are ignored."""
    if not ops:
        return 0, 0
    defs = uses = 0
    for op in ops:
        if op.startswith("["):
            uses |= regs_in(op)
            if op.endswith("!"):
                defs |= regs_in(op.split(",")[0])
    if len(ops) >= 2 and ops[-2].startswith("[") and ops[-2].endswith("]") and not ops[-1].startswith("["):
        defs |= regs_in(ops[-2].split(",")[0])  # post-index writeback
    plain = [o for o in ops if not o.startswith("[")]
    if mn in NO_DEST:
        for o in plain:
            uses |= regs_in(o)
        return defs, uses
    if mn.startswith("st"):
        if STORE_EXCL.match(mn):
            defs |= regs_in(plain[0])
            plain = plain[1:]
        for o in plain:
            uses |= regs_in(o)
        return defs, uses
    if RMW_FIRST.match(mn):
        n = 2 if mn.startswith("casp") else 1
        for o in plain[:n]:
            defs |= regs_in(o)
            uses |= regs_in(o)
        for o in plain[n:]:
            uses |= regs_in(o)
        return defs, uses
    if ATOMIC_LD.match(mn):
        uses |= regs_in(plain[0])
        if len(plain) > 1:
            defs |= regs_in(plain[1])
        return defs, uses
    ndest = 2 if PAIR_LOAD.match(mn) else 1
    for o in plain[:ndest]:
        defs |= regs_in(o)
        if mn in READS_DEST:
            uses |= regs_in(o)
    for o in plain[ndest:]:
        uses |= regs_in(o)
    return defs, uses


_X18 = re.compile(r"\b([xw])18\b")


def rename_x18(text, reg):
    """objdump text with x18/w18 replaced by register `reg` (same width)."""
    return _X18.sub(lambda m: f"{m.group(1)}{reg}", text)


def unpredictable(text):
    """True for register combinations the architecture leaves UNPREDICTABLE:
    load pair into the same register, writeback base equal to a transfer register,
    store-exclusive status register equal to a data or base register."""
    mn, ops = parse(text)
    regs = [o for o in ops if _REG.fullmatch(o)]
    mem = next((o for o in ops if o.startswith("[")), None)
    base = re.match(r"\[\s*([xw]\d+|sp)", mem).group(1) if mem else None
    writeback = mem is not None and (mem.endswith("!") or ops.index(mem) < len(ops) - 1)
    if PAIR_LOAD.match(mn) and len(regs) >= 2 and regs[0][1:] == regs[1][1:]:
        return True
    if writeback and base and any(r[1:] == base[1:] for r in regs):
        return True
    if STORE_EXCL.match(mn) and regs and (regs[0][1:] in [r[1:] for r in regs[1:]]
                                         or (base and regs[0][1:] == base[1:])):
        return True
    return False


class Insn:
    __slots__ = ("addr", "text", "mn", "ops", "xdefs", "defs", "uses", "kind", "succ")

    def __init__(self, addr, text):
        self.addr, self.text = addr, text
        self.mn, self.ops = parse(text)
        self.xdefs, self.uses = defs_uses(self.mn, self.ops)  # explicit defs
        self.defs = self.xdefs
        self.kind = "fall"
        self.succ = []


def _target(op):
    m = _HEX.findall(op)
    return int(m[-1], 16) if m else None


def _imm(op):
    op = op.lstrip("#")
    return int(op, 16) if op.startswith("0x") else int(op)


def _reg(op):
    m = _REG.fullmatch(op.strip())
    return int(m.group(2)) if m else None


def _find_def(insns, k, reg, limit=64):
    """Index of the nearest instruction before k (linear) that defines `reg`."""
    for j in range(k - 1, max(-1, k - 1 - limit), -1):
        if insns[j].xdefs >> reg & 1:
            return j
    return None


def _table_bound(insns, entry_def, ri):
    """Entry count from the nearest preceding `cmp <index>, #N` + b.hi/b.hs, or None.
    (The original resolver kept the last b.hi/b.hs seen in the window; same result
    for the compiler's cmp-then-branch pairs.)"""
    count = None
    for c in range(entry_def - 1, max(-1, entry_def - 64), -1):
        ins = insns[c]
        if ins.mn == "cmp" and _reg(ins.ops[0]) == ri and ins.ops[1].startswith("#"):
            n = _imm(ins.ops[1])
            for d in range(c + 1, min(len(insns), c + 4)):
                if insns[d].mn == "b.hi":
                    count = n + 1
                elif insns[d].mn == "b.hs":
                    count = n
            break
        if ins.xdefs >> ri & 1:
            if ins.mn == "mov" and len(ins.ops) == 2 and _reg(ins.ops[1]) is not None:
                ri = _reg(ins.ops[1])     # index copied after the bound check: follow it
                continue
            if ins.mn not in ("sub", "add"):
                break
    return count


def resolve_jump_table(insns, k, image, start, end):
    """Return the list of target addresses for `br` at insns[k], or None."""
    br = insns[k]
    rb = _reg(br.ops[0])
    j = _find_def(insns, k, rb)
    if j is None or insns[j].mn != "add" or len(insns[j].ops) < 3:
        return None
    add = insns[j]
    a, b = _reg(add.ops[1]), _reg(add.ops[2])
    shift = 0
    if len(add.ops) == 4:
        m = re.match(r"(lsl|sxtw|uxtw|sxth|sxtb)\s*#?(\d+)?", add.ops[3])
        if not m:
            return None
        shift = int(m.group(2) or 0)
    base = entry_def = None
    for cand_base, cand_entry in ((a, b), (b, a)):
        jb = _find_def(insns, j, cand_base)
        je = _find_def(insns, j, cand_entry)
        if jb is not None and insns[jb].mn == "adr" and je is not None and insns[je].mn.startswith("ldr"):
            base, entry_def = _target(insns[jb].ops[1]), je
            break
    if base is None:
        return None
    ld = insns[entry_def]
    sizes = {"ldrb": (1, "<B"), "ldrsb": (1, "<b"), "ldrh": (2, "<H"), "ldrsh": (2, "<h"),
             "ldrsw": (4, "<i"), "ldr": (4, "<I")}
    if ld.mn not in sizes or len(ld.ops) < 2:
        return None
    esize, fmt = sizes[ld.mn]
    mem = split_operands(ld.ops[1].strip("[]!"))
    if len(mem) < 2:
        return None
    rt, ri = _reg(mem[0]), _reg(mem[1])
    if rt is None or ri is None:
        return None
    # Table address: adrp+add, or adr.
    jt = _find_def(insns, entry_def, rt, limit=4096)
    if jt is None:
        return None
    t = insns[jt]
    if t.mn == "adr":
        table = _target(t.ops[1])
    elif t.mn == "add" and len(t.ops) == 3 and t.ops[2].startswith("#"):
        jp = _find_def(insns, jt, _reg(t.ops[1]), limit=4096)
        if jp is None or insns[jp].mn != "adrp":
            return None
        table = _target(insns[jp].ops[1]) + _imm(t.ops[2])
    else:
        return None
    count = _table_bound(insns, entry_def, ri)
    targets = []
    limit = count if count is not None else 1024
    for e in range(limit):
        off = table + e * esize
        if off + esize > len(image):
            break
        v = struct.unpack_from(fmt, image, off)[0]
        tgt = base + (v << shift)
        if not (start <= tgt < end) or tgt & 3:
            if count is not None:
                return None  # bounded table pointing outside the function: misread
            break
        targets.append(tgt)
    return targets or None


def _preds(insns):
    preds = [[] for _ in insns]
    for i, ins in enumerate(insns):
        for t in ins.succ:
            preds[t].append(i)
    return preds


def reaching_defs(insns, preds, k, reg):
    """Indices of the definitions of `reg` that reach insns[k] (before it executes),
    or None if some path reaches function entry without one. Calls count as
    (unknown) definitions of the registers they clobber."""
    found, seen, stack = set(), set(), list(preds[k])
    if k == 0:
        return None
    while stack:
        p = stack.pop()
        if p in seen:
            continue
        seen.add(p)
        if insns[p].defs >> reg & 1:
            found.add(p)
            continue
        if p == 0:
            return None
        stack.extend(preds[p])
    return found


def _def_values(insns, preds, d, reg, depth):
    """Constant values written to `reg` by the single instruction insns[d], or None."""
    ins = insns[d]
    if ins.kind == "call" or not ins.xdefs >> reg & 1:
        return None
    if ins.mn in ("adr", "adrp"):
        return {_target(ins.ops[1])}
    if ins.mn == "add" and len(ins.ops) == 3 and ins.ops[2].startswith("#") and _reg(ins.ops[1]) is not None:
        src = const_values(insns, preds, d, _reg(ins.ops[1]), depth + 1)
        return None if src is None else {v + _imm(ins.ops[2]) for v in src}
    if ins.mn == "mov" and len(ins.ops) == 2 and _reg(ins.ops[1]) is not None:
        return const_values(insns, preds, d, _reg(ins.ops[1]), depth + 1)
    return None


def const_values(insns, preds, k, reg, depth=0):
    """Set of constant values `reg` may hold just before insns[k], if every reaching
    definition is an address computation (adr, adrp, add #imm, mov); else None."""
    if depth > 6:
        return None
    defs = reaching_defs(insns, preds, k, reg)
    if not defs:
        return None
    vals = set()
    for d in defs:
        v = _def_values(insns, preds, d, reg, depth)
        if v is None:
            return None
        vals |= v
        if len(vals) > 64:
            return None
    return vals


_ENTRY_SIZES = {"ldrb": (1, "<B"), "ldrsb": (1, "<b"), "ldrh": (2, "<H"), "ldrsh": (2, "<h"),
                "ldrsw": (4, "<i"), "ldr": (4, "<I")}


def resolve_br_dataflow(insns, preds, k, image, start, end):
    """Jump-table or computed-goto targets for `br` at k from reaching definitions.
    Shapes: br (adr consts) | br (add base, entry, lsl #s) with base a set of consts
    and entry a table load [table, idx{, lsl #n}] whose table address is a set of
    consts. Every combination is read; extra targets only add edges (conservative)."""
    rb = _reg(insns[k].ops[0])
    if rb is None:
        return None
    direct = const_values(insns, preds, k, rb)
    if direct is not None:
        ok = [v for v in direct if start <= v < end and not v & 3]
        return sorted(ok) if len(ok) == len(direct) else None
    defs = reaching_defs(insns, preds, k, rb)
    if not defs:
        return None
    union = set()
    for j in defs:      # each reaching definition must resolve; targets are the union
        ins = insns[j]
        if ins.mn in ("adr", "adrp", "mov") or (ins.mn == "add" and len(ins.ops) == 3 and ins.ops[2].startswith("#")):
            vals = _def_values(insns, preds, j, rb, 0)
            if vals is None or not all(start <= v < end and not v & 3 for v in vals):
                return None
            union |= vals
            continue
        t = _resolve_table_def(insns, preds, j, image, start, end)
        if t is None:
            return None
        union |= set(t)
    return sorted(union)


def _resolve_table_def(insns, preds, j, image, start, end):
    """Targets for a `br` register defined at j by add base, entry{, lsl #s}."""
    add = insns[j]
    if add.mn != "add" or len(add.ops) < 3:
        return None
    shift = 0
    if len(add.ops) == 4:
        m = re.match(r"(lsl|sxtw|uxtw|sxth|sxtb)\s*#?(\d+)?", add.ops[3])
        if not m:
            return None
        shift = int(m.group(2) or 0)
    a, b = _reg(add.ops[1]), _reg(add.ops[2])
    for cand_base, cand_entry in ((a, b), (b, a)):
        if cand_base is None or cand_entry is None:
            continue
        bases = const_values(insns, preds, j, cand_base)
        edefs = reaching_defs(insns, preds, j, cand_entry)
        if not bases or not edefs or len(edefs) != 1:
            continue
        ld = insns[next(iter(edefs))]
        e = next(iter(edefs))
        if ld.mn not in _ENTRY_SIZES or len(ld.ops) < 2:
            continue
        mem = split_operands(ld.ops[1].strip("[]!"))
        if len(mem) < 2 or _reg(mem[0]) is None or _reg(mem[1]) is None:
            continue
        tables = const_values(insns, preds, e, _reg(mem[0]))
        esize, fmt = _ENTRY_SIZES[ld.mn]
        if not tables:
            # Table address unknown, but base and entry width are: every target lies in
            # [base + min_entry << shift, base + max_entry << shift]. Using that whole
            # range as successors over-approximates the CFG, which is sound.
            bits = 8 * esize
            lo, hi = (-(1 << (bits - 1)), (1 << (bits - 1)) - 1) if fmt[1].islower() else (0, (1 << bits) - 1)
            targets = {t for base in bases
                       for t in range(max(start, base + (lo << shift)), min(end, base + (hi << shift) + 1), 4)
                       if not (t - base) % (1 << shift)}
            if targets:
                return sorted(targets)
            continue
        count = _table_bound(insns, e, _reg(mem[1]))
        targets = set()
        for base in bases:
            for table in tables:
                for n in range(count if count is not None else 1024):  # unbounded: stop at first exit
                    off = table + n * esize
                    if off + esize > len(image):
                        break
                    v = struct.unpack_from(fmt, image, off)[0]
                    tgt = base + (v << shift)
                    if not (start <= tgt < end) or tgt & 3:
                        if count is not None:
                            return None      # bounded table pointing outside: misread
                        break
                    targets.add(tgt)
        if targets:
            return sorted(targets)
    return None


def _is_tail_br(insns, k):
    """`br` that leaves the function: right after the epilogue, or through a code
    pointer loaded from memory at an immediate offset (vtable / function pointer)."""
    ctx = [insns[j].text for j in range(max(0, k - 3), k)]
    if any("ldp\tx29, x30" in t or t.startswith("add\tsp, sp") or t.startswith("ldr\tx30, [sp]") for t in ctx):
        return True
    rb = _reg(insns[k].ops[0])
    j = _find_def(insns, k, rb, limit=4)
    return j is not None and _is_ptr_load(insns[j])


def _is_ptr_load(ins):
    """ldr xN, [xM{, #imm}]: a code pointer read from an object, not a jump table."""
    if ins.mn != "ldr" or len(ins.ops) != 2 or not ins.ops[0].startswith("x"):
        return False
    mem = split_operands(ins.ops[1].strip("[]!"))
    return len(mem) == 1 or (len(mem) == 2 and mem[1].startswith("#"))


def build_cfg(insns, start, end, image, noreturn=frozenset()):
    """Fill kind/succ/defs/uses with call-ABI effects. Returns number of unresolved `br`.
    Calls to addresses in `noreturn` get no fall-through edge."""
    index = {ins.addr: i for i, ins in enumerate(insns)}
    unresolved = 0
    n = len(insns)
    for i, ins in enumerate(insns):
        mn, ops = ins.mn, ins.ops
        nxt = [i + 1] if i + 1 < n else []
        if mn in ("bl", "blr"):
            ins.kind = "call"
            ins.uses |= ARGS
            ins.defs = ins.xdefs | CALL_CLOBBER
            ins.succ = [] if mn == "bl" and _target(ops[-1]) in noreturn else nxt
        elif mn == "ret":
            ins.kind = "ret"
            ins.uses |= (ARGS & 0xFF) | CALLEE_SAVED | LR
        elif mn == "br":
            targets = resolve_jump_table(insns, i, image, start, end)
            if targets is None and _is_tail_br(insns, i):
                ins.kind = "tail"
                ins.uses |= ARGS | CALLEE_SAVED | LR
            elif targets is None:
                ins.kind = "indirect"   # resolved below from dataflow if possible
            else:
                ins.kind = "switch"
                ins.succ = sorted({index[t] for t in targets if t in index})
        elif mn == "b" or mn.startswith("b.") or mn in ("cbz", "cbnz", "tbz", "tbnz"):
            t = _target(ops[-1])
            inside = t is not None and start <= t < end and t in index
            if mn == "b":
                if inside:
                    ins.kind, ins.succ = "jump", [index[t]]
                else:
                    ins.kind = "tail"
                    ins.uses |= ARGS | CALLEE_SAVED | LR
            else:
                ins.kind = "cond"
                ins.succ = nxt + ([index[t]] if inside else [])
                if not inside:
                    ins.uses |= ARGS | CALLEE_SAVED | LR
        else:
            ins.succ = nxt
    # Dataflow resolution needs predecessors, which depend on resolutions. Iterate to
    # a fixed point: every dataflow-resolved `br` is recomputed on the current CFG
    # until no successor set changes, so each final resolution holds on the final CFG.
    dyn = [i for i, ins in enumerate(insns) if ins.kind == "indirect"]
    for _ in range(32):
        changed = False
        preds = _preds(insns)
        for i in dyn:
            ins = insns[i]
            rdefs = reaching_defs(insns, preds, i, _reg(ins.ops[0]) or 0)
            if rdefs and all(_is_ptr_load(insns[d]) for d in rdefs):
                kind, succ = "tail", []
            else:
                targets = resolve_br_dataflow(insns, preds, i, image, start, end)
                kind, succ = ("indirect", []) if targets is None else \
                    ("switch", sorted({index[t] for t in targets if t in index}))
            if (kind, succ) != (ins.kind, ins.succ):
                ins.kind, ins.succ = kind, succ
                changed = True
        if not changed:
            break
    else:
        for i in dyn:                      # no fixed point: trust none of them
            insns[i].kind, insns[i].succ = "indirect", []
    pending = []
    for i in dyn:
        if insns[i].kind == "tail":
            insns[i].uses |= ARGS | CALLEE_SAVED | LR
        elif insns[i].kind == "indirect":
            insns[i].uses |= ALL
            pending.append(i)
    unresolved = len(pending)
    return unresolved


def liveness(insns):
    """Backward dataflow over all GPRs. Returns (live_in, live_out) lists of masks."""
    n = len(insns)
    lin = [0] * n
    lout = [0] * n
    preds = [[] for _ in range(n)]
    for i, ins in enumerate(insns):
        for s in ins.succ:
            preds[s].append(i)
    work = list(range(n))
    inq = [True] * n
    while work:
        i = work.pop()
        inq[i] = False
        ins = insns[i]
        out = 0
        for s in ins.succ:
            out |= lin[s]
        lout[i] = out
        new = ins.uses | (out & ~ins.defs)
        if new != lin[i]:
            lin[i] = new
            for p in preds[i]:
                if not inq[p]:
                    inq[p] = True
                    work.append(p)
    return lin, lout
