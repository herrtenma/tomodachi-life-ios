"""Out-of-line spill for the x18 webs x18scan.py could not rename ("stuck" webs).

usage: spill.py <main.raw> <x18_main.json> <main.renamed.nso> <main.out.nso>
                <sdk.raw>  <x18_sdk.json>  <sdk.renamed.nso>  <sdk.out.nso>
                <subsdk.out.nso>

The web's value lives in a stack slot below SP, the "virtual x18" at [sp, #-8].
Every instruction of the web that names x18 is replaced in place by `b tramp`.
The trampoline loads the slot into a scratch register, runs the instruction
with x18 renamed to the scratch register, stores the result back, and branches
to the next instruction. If no register is free at the site, the scratch
register's own value is parked at [sp, #-16] around the instruction.

The slot is valid because:
  - SP is checked constant over every instruction of the web;
  - a web never spans a call (that would be a live_across_call hazard), so no
    callee can write below SP while the slot is live;
  - AAPCS64 code never writes below SP; Darwin keeps a 128-byte red zone that
    signal delivery respects, and Ryujinx never touches the guest stack.

Trampolines go into a new module (subsdk9). Ryujinx places modules back to
back, each page-aligned and including bss, in the order rtld, main,
subsdk0-9, sdk, so in one address space with main at 0:
    subsdk9 = MAIN_SIZE, sdk = MAIN_SIZE + SUB_SIZE.
"""
import json
import os
import re
import struct
import sys

import a64enc as enc
import nsobuild
from disasm import disassemble, disassemble_words
from nso import functions_from_eh_frame, load_nso, write_nso
from patch import candidates, _norm
from regflow import Insn, build_cfg, liveness, rename_x18, unpredictable
from x18scan import B18, X18, undef_only_webs, x18_liveness, x18_webs

SP = 31
SLOT, PARK = int(os.environ.get("SPILL_SLOT", "-8")), int(os.environ.get("SPILL_PARK", "-16"))
NOP = 0xD503201F
SUB_SIZE = 0x200000          # whole subsdk9 module, fixed so sdk's base is known up front
SPMOD = re.compile(r"^(sub|add|mov)\s+sp\b|\[sp[^\]]*\]!|\[sp\],|\[sp, #-")
# Scratch preference: IP0/IP1 and temporaries first.
SCRATCH = [16, 17, 9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8,
           19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 30]


def page_up(n):
    page = nsobuild.NATIVE_PAGE if NATIVE else 0x1000
    return (n + page - 1) & ~(page - 1)


class Tramps:
    """Trampoline text for subsdk9, addressed in the shared address space."""

    def __init__(self, base, text_off):
        self.base = base
        self.words = []
        self.text_off = text_off
        self.checks = []  # (abs addr, expected normalized text or None)
        self.targets = []  # (abs addr of a branch, its required target)
        self.ptrs = []     # (abs addr of an adrp+ldr pair, the address it must load from)

    @property
    def here(self):
        return self.base + self.text_off + 4 * len(self.words)

    def emit_b(self, dst):
        self.targets.append((self.here, dst))
        self.emit(enc.b(self.here, dst))

    def emit(self, word, expect=None):
        self.checks.append((self.here, expect))
        self.words.append(word)


def precompute_renames(jobs):
    """For each plain site, the encoding with x18 -> its scratch register. These
    instructions are not PC-relative, so one batch disassembled at address 0 decides;
    the final trampoline check re-disassembles each at its real address."""
    words, owners = [], []
    for n, j in enumerate(jobs):
        reg = j["free"] if j["free"] is not None else j["park"]
        for w in candidates(j["word"], reg):
            words.append(w)
            owners.append(n)
    texts = disassemble_words(words, [4 * i for i in range(len(words))])
    for w, n, t in zip(words, owners, texts):
        j = jobs[n]
        reg = j["free"] if j["free"] is not None else j["park"]
        want = _norm(rename_x18(j["text"], reg))
        if "renamed" not in j and _norm(t) == want and not unpredictable(t):
            j["renamed"] = (w, want)


_SPIMM = re.compile(r"^(sub|add)\tsp, sp, #(0x[0-9a-f]+|\d+)(, lsl #12)?$")
_PRE = re.compile(r"\[sp, #(-?(?:0x[0-9a-f]+|\d+))\]!")
_POST = re.compile(r"\[sp\], #(-?(?:0x[0-9a-f]+|\d+))")
RED_ZONE = 128     # Darwin keeps 128 bytes below SP safe from signal delivery


def _sp_effect(ins):
    """Change to SP made by one instruction (0 if none), or None if not a constant."""
    t = ins.text.split(" //")[0].strip()
    m = _SPIMM.match(t)
    if m:
        v = int(m.group(2), 0) << (12 if m.group(3) else 0)
        return -v if m.group(1) == "sub" else v
    m = _PRE.search(t) or _POST.search(t)
    if m:
        return int(m.group(1), 0)
    if ins.ops and ins.ops[0] == "sp" and not ins.mn.startswith(("st", "cmp", "cmn", "tst")):
        return None    # mov sp, x29 / add sp, x29, #n ...: not a known constant
    return 0


UNKNOWN = object()


def sp_deltas(insns, points):
    """SP offset from function entry before and after each instruction, by a forward
    pass over the whole function. A conflicting merge or a non-constant SP write makes
    the offset UNKNOWN from there on. Returns (din, dout) restricted to `points`, or
    None if any point's offset is unknown."""
    n = len(insns)
    din = [None] * n
    din[0] = 0
    work = [0]
    while work:
        i = work.pop()
        if din[i] is UNKNOWN:
            out = UNKNOWN
        else:
            eff = _sp_effect(insns[i])
            out = UNKNOWN if eff is None else din[i] + eff
        for t in insns[i].succ:
            if din[t] is None:
                din[t] = out
                work.append(t)
            elif din[t] is not UNKNOWN and din[t] != out:
                din[t] = UNKNOWN
                work.append(t)
    res_in, res_out = {}, {}
    for i in points:
        if din[i] is None or din[i] is UNKNOWN:
            return None
        eff = _sp_effect(insns[i])
        if eff is None:
            return None
        res_in[i], res_out[i] = din[i], din[i] + eff
    return res_in, res_out


def jump_table_br(insns, c, lout):
    """Recognize `br x18` at index c as a jump-table dispatch that can go through
    landing pads instead of a scratch register:
        add x18, x18, xE, lsl #2 ; br x18     with x18 = adr B on every path,
    x18 dead at every target, and the targets known. Returns (E, B, count) or None;
    count is the number of pads (largest entry value + 1)."""
    from regflow import _preds, const_values
    br = insns[c]
    if br.text.strip() != "br\tx18" or br.kind != "switch" or lout[c] & B18:
        return None
    preds = _preds(insns)
    # Walk back over straight-line code (no other way in) to the add defining x18.
    j = c - 1
    while j >= 0 and not insns[j].xdefs & B18:
        if insns[j].kind != "fall" or preds[j + 1] != [j] or c - j > 8:
            return None
        j -= 1
    if j < 0 or preds[j + 1] != [j]:
        return None
    add = insns[j]
    if add.mn != "add" or add.ops[:2] != ["x18", "x18"] or len(add.ops) != 4 or add.ops[3] != "lsl #2":
        return None
    e = int(add.ops[2][1:])
    if not 0 <= e < 31 or e == 18 or any(insns[k].defs >> e & 1 for k in range(j + 1, c)):
        return None
    bases = const_values(insns, preds, j, 18)
    if not bases or len(bases) != 1:
        return None
    base = bases.pop()
    # Pads are indexed by the entry value (target = B + 4 * value). The CFG's switch
    # successors are every possible target (liveness already relies on that).
    offs = [insns[t].addr - base for t in br.succ]
    if not offs or min(offs) < 0 or any(o & 3 for o in offs):
        return None
    count = max(offs) // 4 + 1
    return (e, base, count) if count <= 4096 else None


def slot_moves(insns, points, sites, lin, lout):
    """For the move-the-slot fallback: the web's SP-changing instructions with a free
    scratch register each, or None. x18 sites themselves must not move SP, and an
    SP-changing instruction must not be PC-relative or name x18."""
    site_set = set(sites)
    moves = []
    for i in points:
        eff = _sp_effect(insns[i])
        if eff == 0:
            continue
        ins = insns[i]
        if eff is None or i in site_set or X18.search(ins.text):
            return None
        busy = lin[i] | lout[i] | ins.uses | ins.defs | B18
        free = [r for r in SCRATCH if not busy >> r & 1]
        if not free:
            return None
        moves.append((i, free[0]))
    return moves or None


def memory_mode(name, nso, fn, noreturn, mod_base, jobs, skipped):
    """x18 lives in the slot for the whole function, with no liveness at all: for
    functions whose CFG has an unresolved `br`. Every read loads the slot, every write
    stores it, and the scratch register is always parked, so no register-liveness fact
    is needed. Requires the same SP offset at every site. Calls clobber the slot, but
    the ABI already clobbers x18 at calls, so reads after a call see garbage either way."""
    s, e = fn["start"], fn["end"]
    insns = [Insn(a, t) for a, t in disassemble(nso.image[s:e], s)]
    build_cfg(insns, s, e, nso.image, noreturn)
    sites = [i for i, ins in enumerate(insns) if X18.search(ins.text)]
    d = sp_deltas(insns, sites)
    why = None
    if d is None:
        why = "memory mode: SP offset unknown at a site"
    elif len(set(d[0].values()) | set(d[1].values())) != 1:
        why = "memory mode: SP differs between sites"
    elif any(insns[i].mn == "br" for i in sites):
        why = "memory mode: br x18"
    if why:
        skipped.append({"module": name, "func": s, "sites": [insns[i].addr for i in sites], "why": why})
        return
    for i in sites:
        ins = insns[i]
        avoid = ins.uses | ins.xdefs | B18
        jobs.append({"addr": ins.addr, "abs": mod_base + ins.addr, "text": ins.text,
                     "word": nso.read32(ins.addr), "mn": ins.mn, "kind": ins.kind,
                     "reads": bool(ins.uses & B18), "writes": bool(ins.xdefs & B18),
                     "free": None, "park": next(r for r in SCRATCH if not avoid >> r & 1),
                     "slot_in": SLOT, "slot_out": SLOT, "sp_moves": False, "func": s})


def plan_module(name, raw_path, plan_path, mod_base):
    """Yield one site job per stuck-web site, or record why a web is skipped."""
    nso = load_nso(raw_path)
    plan = json.load(open(plan_path))
    noreturn = frozenset(plan.get("noreturn", ()))   # must match the CFG the plan was made with
    jobs, skipped = [], []
    for fn in plan["functions"]:
        if set(fn["hazards"]) == {"unresolved_br"}:
            memory_mode(name, nso, fn, noreturn, mod_base, jobs, skipped)
            continue
        if fn["hazards"] or all(w["reg"] is not None for w in fn["webs"]):
            continue
        s, e = fn["start"], fn["end"]
        insns = [Insn(a, t) for a, t in disassemble(nso.image[s:e], s)]
        build_cfg(insns, s, e, nso.image, noreturn)
        lin, lout, undef_reads = x18_liveness(insns)
        stuck = [set(w["sites"]) for w in fn["webs"] if w["reg"] is None]
        for points in x18_webs(insns, lin) + undef_only_webs(insns, lin, undef_reads):
            sites = [i for i in points if X18.search(insns[i].text)]
            if {insns[i].addr for i in sites} not in stuck:
                continue
            bad = [insns[i].text for i in points if SPMOD.search(insns[i].text.replace("\t", " "))]
            if bad:
                # SP moves inside the web: fix the slot at one place below the lowest SP
                # the web sees, addressed relative to the SP at each site.
                d = sp_deltas(insns, points)
                why = None
                if d is None:
                    why = "sp not a known constant inside web"
                else:
                    din, dout = d
                    slot_abs = min(min(din.values()), min(dout.values())) - 24
                    offs = [slot_abs - din[i] for i in sites] + [slot_abs - dout[i] for i in sites]
                    if min(offs) < -RED_ZONE:
                        why = f"slot would sit {-min(offs)} bytes below SP (red zone is {RED_ZONE})"
                        moves = slot_moves(insns, points, sites, lin, lout)
                        if moves is not None:
                            # Fallback: keep the slot at [sp, #-8] of the current SP and
                            # carry the value across each SP change.
                            for i, r in moves:
                                jobs.append({"addr": insns[i].addr, "abs": mod_base + insns[i].addr,
                                             "text": insns[i].text, "word": nso.read32(insns[i].addr),
                                             "mn": insns[i].mn, "special": "spmove", "free": r,
                                             "func": s})
                            why, din = None, None
                if why:
                    skipped.append({"module": name, "func": s, "sites": [insns[i].addr for i in sites],
                                    "why": why, "insns": bad})
                    continue
            else:
                din = dout = None
            if din is None:
                dout = None
            for i in sites:
                ins = insns[i]
                busy = lin[i] | lout[i] | ins.uses | ins.defs | B18
                free = [r for r in SCRATCH if not busy >> r & 1]
                if s in PARK_ALL:
                    free = []       # debug: no liveness-based scratch in this function
                jt = jump_table_br(insns, i, lout) if ins.mn == "br" and not free else None
                if jt is not None:
                    jobs.append({"addr": ins.addr, "abs": mod_base + ins.addr, "text": ins.text,
                                 "word": nso.read32(ins.addr), "mn": "br", "special": "jtpads",
                                 "entry_reg": jt[0], "base": mod_base + jt[1], "count": jt[2], "func": s})
                    continue
                avoid = ins.uses | ins.xdefs | B18
                jobs.append({"addr": ins.addr, "abs": mod_base + ins.addr, "text": ins.text,
                             "word": nso.read32(ins.addr), "mn": ins.mn, "kind": ins.kind,
                             "reads": bool(ins.uses & B18), "writes": bool(ins.xdefs & B18),
                             "free": free[0] if free else None,
                             "park": next(r for r in SCRATCH if not avoid >> r & 1),
                             "slot_in": SLOT if din is None else slot_abs - din[i],
                             "slot_out": SLOT if din is None else slot_abs - dout[i],
                             "sp_moves": din is not None and din[i] != dout[i],
                             "func": s})
    return nso, jobs, skipped


POISON = os.environ.get("SPILL_POISON") == "1"
IDENTITY = os.environ.get("SPILL_IDENTITY") == "1"
NATIVE = os.environ.get("SPILL_NATIVE") == "1"      # our own loader: 16 KB pages, TLS + SVC rewrite
PARK_ALL = {int(x, 16) for x in os.environ.get("SPILL_PARK_ALL", "").split(",") if x}
POISON_X18 = 0xD2E00000 | (0xDEAD << 5) | 18      # movz x18, #0xdead, lsl #48
# Native flavor, opt-in (ACQREL=1): every plain exclusive becomes its ordered form (bit 15, o0): LDXR* -> LDAXR*,
# STXR* -> STLXR*, LDXP/STXP -> LDAXP/STLXP. From the BOTW port (its HANDOFF session 4): sead spin locks there acquire
# with plain ldxr/stxr and no barrier; an A57 holds that in practice, Apple cores let the critical section's loads run
# before the lock is taken (random crashes). Off by default here: no symptom seen in Tomodachi yet (runtime/src/loader.c
# logs the plain count; NXRT_ACQREL=1 patches them at load on the Mac for an A/B).
ACQREL = NATIVE and os.environ.get("ACQREL", "0") == "1"


def build_trampoline(T, job, mod_base):
    """Append the trampoline for one site. Returns its address, or raises ValueError.
    With SPILL_POISON=1 every trampoline first writes a non-canonical value to x18,
    standing in for the kernel wiping it: any x18 read left behind gets garbage."""
    start = T.here
    if IDENTITY:
        # debug: run the original instruction (adrp re-encoded) and come back; no slot
        back = job["abs"] + 4
        pc = enc.decode_pcrel(job["word"], job["addr"])
        if pc is not None and pc[0] == "adrp":
            T.emit(enc.adrp(pc[1], T.here, pc[2] + mod_base))
        elif pc is None and job["mn"] not in ("b", "bl", "cbz", "cbnz", "tbz", "tbnz", "br", "blr"):
            T.emit(job["word"], _norm(job["text"]))
        else:
            raise ValueError("identity mode: unsupported site")
        T.emit_b(back)
        return start
    if POISON:
        T.emit(POISON_X18, "mov\tx18, #-0x2153000000000000")
    back = job["abs"] + 4
    mn, text, word = job["mn"], job["text"], job["word"]
    pcrel = enc.decode_pcrel(word, job["addr"])

    if job.get("special") == "spmove":
        # Carry the virtual x18 across an SP change: [old sp - 8] -> [new sp - 8].
        r = job["free"]
        T.emit(enc.ldur_x(r, SP, SLOT))
        T.emit(job["word"], _norm(job["text"]))   # SP arithmetic / push / pop: position independent
        T.emit(enc.stur_x(r, SP, SLOT))
        T.emit_b(back)
        return start

    if job.get("special") == "jtpads":
        # Dispatcher: park x16, x16 = pads + entry * 8, br x16. Pad k: restore x16, b B + 4k.
        e = job["entry_reg"]
        r = 16 if e != 16 else 17                   # dispatch register, parked meanwhile
        T.emit(enc.stur_x(r, SP, PARK))
        adr_at = T.here
        T.emit(0)                                   # adr xR, pads (patched below)
        T.emit(0x8B000000 | (e << 16) | (3 << 10) | (r << 5) | r, f"add\tx{r}, x{r}, x{e}, lsl #3")
        T.emit(enc.br(r))
        pads = T.here
        T.words[(adr_at - T.base - T.text_off) // 4] = enc.adr(r, adr_at, pads)
        for k in range(job["count"]):
            T.emit(enc.ldur_x(r, SP, PARK))
            T.emit_b(job["base"] + 4 * k)
        return start

    if mn in ("br", "blr"):
        if mn == "blr":
            # x16/x17 are clobbered by every call and never carry arguments.
            s = 16 if "x16" not in text else 17
            T.emit(enc.ldur_x(s, SP, job["slot_in"]))
            for w in enc.adr_pair(30, T.here, back):  # LR = original return address
                T.emit(w)
            T.emit(enc.br(s))
            return start
        if job["free"] is None:
            raise ValueError("br x18 with no free register")
        T.emit(enc.ldur_x(job["free"], SP, job["slot_in"]))
        T.emit(enc.br(job["free"]))
        return start

    s = job["free"] if job["free"] is not None else job["park"]
    parked = job["free"] is None
    if parked and job["sp_moves"]:
        raise ValueError("parking around an instruction that moves SP")

    def restore():
        if parked:
            T.emit(enc.ldur_x(s, SP, PARK))

    if parked:
        T.emit(enc.stur_x(s, SP, PARK))
    if job["reads"]:
        T.emit(enc.ldur_x(s, SP, job["slot_in"]))

    if mn in ("cbz", "cbnz", "tbz", "tbnz"):
        target = enc.cond_branch_target(word, job["addr"]) + mod_base
        cond_at = T.here
        T.words.append(0)                     # patched below once the taken label is known
        T.checks.append((cond_at, None))
        restore()
        T.emit_b(back)
        taken = T.here
        restore()
        T.emit_b(target)
        T.words[(cond_at - T.base - T.text_off) // 4] = enc.retarget_cond_branch(word, cond_at, taken, s)
        T.targets.append((cond_at, taken))
        return start

    if pcrel is not None:
        kind, rd, target, extra = pcrel
        if rd != 18:
            raise ValueError(f"pc-relative site not defining x18: {text}")
        target += mod_base
        if kind == "adrp":
            T.emit(enc.adrp(s, T.here, target))
        else:
            for w in enc.adr_pair(s, T.here, target):
                T.emit(w)
            if kind == "ldrlit":
                _, size, signed = extra
                T.emit(enc.ldr_lit_like(size, signed, s, s))
    else:
        if "renamed" not in job:
            raise ValueError(f"cannot re-encode {text} with x{s}")
        w, want = job["renamed"]
        if ACQREL and exclusive_kind(w) >= 0:
            w, want = acquire_release(w, want)
        T.emit(w, want)

    if job["writes"]:
        T.emit(enc.stur_x(s, SP, job["slot_out"]))
    restore()
    T.emit_b(back)
    return start


def apply(name, raw_path, plan_path, renamed_path, out_path, mod_base, T, report):
    nso, jobs, skipped = plan_module(name, raw_path, plan_path, mod_base)
    out = load_nso(renamed_path)
    precompute_renames([j for j in jobs if "special" not in j
                        and j["mn"] not in ("br", "blr", "cbz", "cbnz", "tbz", "tbnz")
                        and enc.decode_pcrel(j["word"], j["addr"]) is None])
    failed_funcs, placed = set(), []
    # Group by function: a web is converted all-or-nothing; simplest is per function.
    by_func = {}
    for j in jobs:
        by_func.setdefault(j["func"], []).append(j)
    only = os.environ.get("SPILL_ONLY")  # bisection: "main:lo-hi,sdk:lo-hi" (hex), others untouched
    if only:
        ranges = [r.split(":") for r in only.split(",")]
        ranges = [(m, *(int(x, 16) for x in r.split("-"))) for m, r in ranges]
        by_func = {f: js for f, js in by_func.items()
                   if any(m == name and lo <= f < hi for m, lo, hi in ranges)}
    for func, fjobs in by_func.items():
        mark = (len(T.words), len(T.checks), len(T.targets))
        try:
            fplaced = []
            for j in fjobs:
                if out.read32(j["addr"]) != j["word"]:
                    raise ValueError("site already modified by the rename pass")
                if j.get("special") == "nop":
                    fplaced.append((j, None))
                    continue
                t = build_trampoline(T, j, mod_base)
                fplaced.append((j, t))
            placed.extend(fplaced)
        except ValueError as ex:
            del T.words[mark[0]:]
            del T.checks[mark[1]:]
            del T.targets[mark[2]:]
            failed_funcs.add(func)
            skipped.append({"module": name, "func": func, "why": str(ex)})
    for j, t in placed:
        out.write32(j["addr"], NOP if t is None else enc.b(j["abs"], t))
    native_placed = native_sites(name, out, mod_base, T, report) if NATIVE else []
    acq_sites = acqrel_sites(name, out, functions_from_eh_frame(nso), report) if ACQREL else {}
    # Whole-text diff: only the converted sites may change, each into `b tramp`.
    text = out.text
    before = {a: t for a, t in disassemble(load_nso(renamed_path).image[text.mem_off:text.mem_off + text.size], 0)}
    sites = {j["addr"]: t for j, t in placed}
    sites.update(native_placed)
    unexpected = 0
    for a, t in disassemble(out.image[text.mem_off:text.mem_off + text.size], 0):
        if a in sites:
            want = r"nop" if sites[a] is None else r"b\s+0x[0-9a-f]+"
            if not re.fullmatch(want, t.split(" <")[0]):
                unexpected += 1
        elif a in acq_sites:
            if t != acquire_release(acq_sites[a], before[a])[1]:
                print(f"{name} acqrel {a:#x}: got {t!r} from {before[a]!r}")
                unexpected += 1
        elif t != before[a]:
            unexpected += 1
    report[name] = {"site_jobs": len(jobs), "converted_sites": len(placed),
                    "skipped": len(skipped), "unexpected_diffs": unexpected}
    if unexpected:
        sys.exit(f"{name}: verification failed")
    write_nso(out, out_path)
    return skipped, placed


# ---------------------------------------------------------------- native flavor
# GuestThread block (runtime/include/nxrt.h): field offsets
GT_TPIDR, GT_TPIDRRO = 0, 8
MRS_TPIDR, MRS_TPIDRRO, MSR_TPIDR = 0xD53BD040, 0xD53BD060, 0xD51BD040
_TLS_RE = re.compile(r"^(mrs|msr)\s+(?:x(\d+), (TPIDR_EL0|TPIDRRO_EL0)|(TPIDR_EL0|TPIDRRO_EL0), x(\d+))$")


def _tbl(T):
    return T.base + nsobuild.RT_TABLE


def _emit_tbl_load(T, rd, field):
    """rd = runtime_table.field (adrp + ldr), recorded for address verification."""
    addr = _tbl(T) + field
    at = T.here
    T.emit(enc.adrp(rd, at, addr))
    T.emit(0xF9400000 | (((addr & 0xFFF) // 8) << 10) | (rd << 5) | rd)
    T.ptrs.append((at, addr))


def _emit_guest_thread(T, rd, scratch):
    """rd = GuestThread* of the current host thread, via Darwin's TSD (TPIDRRO_EL0) and the
    pthread key offset the loader stored in the runtime table. Clobbers `scratch`."""
    T.emit(MRS_TPIDRRO | scratch, f"mrs\tx{scratch}, TPIDRRO_EL0")
    T.emit(0x927DF000 | (scratch << 5) | scratch, f"and\tx{scratch}, x{scratch}, #0xfffffffffffffff8")
    _emit_tbl_load(T, rd, nsobuild.RT_TSD_KEY_OFF)
    T.emit(0xF8606800 | (rd << 16) | (scratch << 5) | rd, f"ldr\tx{rd}, [x{scratch}, x{rd}]")


def tls_trampoline(T, abs_addr, word, text):
    """mrs xN, tpidr_el0 / tpidrro_el0  and  msr tpidr_el0, xV  through the GuestThread block."""
    m = _TLS_RE.match(text.split(" //")[0].strip())
    if not m:
        raise ValueError(f"unexpected TLS form: {text}")
    start, back = T.here, abs_addr + 4
    if m.group(1) == "mrs":
        n, field = int(m.group(2)), GT_TPIDR if m.group(3) == "TPIDR_EL0" else GT_TPIDRRO
        sc = 16 if n != 16 else 17
        T.emit(enc.stur_x(sc, SP, PARK))
        _emit_guest_thread(T, n, sc)
        T.emit(0xF9400000 | ((field // 8) << 10) | (n << 5) | n,
               f"ldr\tx{n}, [x{n}" + (f", #0x{field:x}]" if field else "]"))
        T.emit(enc.ldur_x(sc, SP, PARK))
    else:
        if m.group(4) != "TPIDR_EL0":
            raise ValueError(f"write to {m.group(4)}")
        v = int(m.group(5))
        a, b = [r for r in (16, 17, 15) if r != v][:2]
        T.emit(0xA9000000 | ((-4 & 0x7F) << 15) | (b << 10) | (SP << 5) | a, f"stp\tx{a}, x{b}, [sp, #-0x20]")
        _emit_guest_thread(T, b, a)          # b = GuestThread*
        T.emit(0xF9000000 | (GT_TPIDR // 8 << 10) | (b << 5) | v, f"str\tx{v}, [x{b}]")
        T.emit(0xA9400000 | ((-4 & 0x7F) << 15) | (b << 10) | (SP << 5) | a, f"ldp\tx{a}, x{b}, [sp, #-0x20]")
    T.emit_b(back)
    return start


def svc_trampoline(T, abs_addr, num):
    """svc #N -> call the runtime's svc_entry with x16 = N; every other register is preserved
    by svc_entry except the SVC's outputs, exactly like the Horizon kernel."""
    start = T.here
    T.emit(0xA9BF7BF0, "stp\tx16, x30, [sp, #-0x10]!")
    T.emit(0xD2800000 | (num << 5) | 16, f"mov\tx16, #0x{num:x}")
    _emit_tbl_load(T, 30, nsobuild.RT_SVC_ENTRY)
    T.emit(0xD63F03C0, "blr\tx30")
    T.emit(0xA8C17BF0, "ldp\tx16, x30, [sp], #0x10")
    T.emit_b(abs_addr + 4)
    return start


MRS_CNTVCT = 0xD53BE040
_SYSREG_RE = re.compile(r"^mrs\s+x(\d+), (CTR_EL0|CNTPCT_EL0)$")


def sysreg_trampoline(T, abs_addr, text):
    """mrs xN, CTR_EL0 -> the Switch's value; mrs xN, CNTPCT_EL0 -> the host virtual counter
    scaled 24 MHz -> 19.2 MHz (x4/5), the frequency the SDK assumes."""
    m = _SYSREG_RE.match(text.split(" //")[0].strip())
    n, reg = int(m.group(1)), m.group(2)
    start = T.here
    if reg == "CTR_EL0":
        T.emit(0xD2800000 | (0xC004 << 5) | n, f"mov\tx{n}, #0xc004")
        T.emit(0xF2A00000 | (0x8444 << 5) | n, f"movk\tx{n}, #0x8444, lsl #16")
    else:
        sc = 16 if n != 16 else 17
        T.emit(enc.stur_x(sc, SP, PARK))
        T.emit(MRS_CNTVCT | n, f"mrs\tx{n}, CNTVCT_EL0")
        T.emit(0xD37EF400 | (n << 5) | n, f"lsl\tx{n}, x{n}, #2")
        T.emit(0xD2800000 | (5 << 5) | sc, f"mov\tx{sc}, #0x5")
        T.emit(0x9AC00800 | (sc << 16) | (n << 5) | n, f"udiv\tx{n}, x{n}, x{sc}")
        T.emit(enc.ldur_x(sc, SP, PARK))
    T.emit_b(abs_addr + 4)
    return start


def exclusive_kind(w):
    """0 ldxr*, 1 stxr*, 2 ldxp, 3 stxp (plain, o0 = 0); -1 for anything else, ordered forms included."""
    return (0 if (w & 0x3FFFFC00) == 0x085F7C00 else 1 if (w & 0x3FE0FC00) == 0x08007C00
            else 2 if (w & 0xBFFF8000) == 0x887F0000 else 3 if (w & 0xBFE08000) == 0x88200000 else -1)


def acquire_release(w, text):
    """The ordered form of a plain exclusive and its expected disassembly (ldxrb -> ldaxrb, stxp -> stlxp, ...)."""
    return w | 0x8000, re.sub(r"^(ld)(x)|^(st)(x)", lambda m: (m[1] + "a" + m[2]) if m[1] else (m[3] + "l" + m[4]), text)


def acqrel_sites(name, out, funcs, report):
    """Set bit 15 on every plain exclusive inside a function (FDE) range of `out`. Returns {addr: original word}
    for the whole-text diff."""
    sites, n = {}, [0] * 4
    for s, e in funcs:
        for a in range(s, e, 4):
            w = out.read32(a)
            k = exclusive_kind(w)
            if k < 0:
                continue
            out.write32(a, w | 0x8000)
            sites[a] = w
            n[k] += 1
    report[f"{name}_acqrel"] = f"{n[0]} ldxr, {n[1]} stxr, {n[2]} ldxp, {n[3]} stxp -> acquire/release"
    return sites


def native_sites(name, out, mod_base, T, report):
    """Rewrite every TLS-register access and svc in `out` (after the x18 passes) into
    trampolines. Returns {addr: trampoline} for the whole-text diff."""
    text = out.text
    placed, n_tls, n_svc, n_sys = {}, 0, 0, 0
    for a, t in disassemble(out.image[text.mem_off:text.mem_off + text.size], 0):
        tl = t.lower()
        if t.startswith("svc"):
            tramp = svc_trampoline(T, mod_base + a, int(t.split("#")[1], 0))
            n_svc += 1
        elif _SYSREG_RE.match(t.split(" //")[0].strip()):
            tramp = sysreg_trampoline(T, mod_base + a, t)
            n_sys += 1
        elif "tpidr" in tl and t.startswith(("mrs", "msr")):
            if re.search(r"\b[xw]18\b", t):
                raise ValueError(f"{name} {a:#x}: TLS access names x18")
            tramp = tls_trampoline(T, mod_base + a, out.read32(a), t)
            n_tls += 1
        else:
            continue
        out.write32(a, enc.b(mod_base + a, tramp))
        placed[a] = tramp
    report[f"{name}_native"] = {"tls_sites": n_tls, "svc_sites": n_svc, "sysreg_sites": n_sys}
    return placed


def apply_native_only(name, renamed_path, out_path, mod_base, T, report):
    """Modules with no spill work (rtld): only the native TLS/SVC rewrite."""
    out = load_nso(renamed_path)
    before = {a: t for a, t in disassemble(out.image[out.text.mem_off:out.text.mem_off + out.text.size], 0)}
    placed = native_sites(name, out, mod_base, T, report)
    for a, t in disassemble(out.image[out.text.mem_off:out.text.mem_off + out.text.size], 0):
        if (a in placed) != (t != before[a]):
            sys.exit(f"{name}: verification failed at {a:#x}")
    write_nso(out, out_path)


def _b_target(w, pc):
    imm = w & 0x3FFFFFF
    if imm & (1 << 25):
        imm -= 1 << 26
    return pc + (imm << 2)


def main():
    a = sys.argv[1:]
    if len(a) != (11 if NATIVE else 9):
        sys.exit(__doc__ + "\nSPILL_NATIVE=1 adds two arguments: <rtld.renamed.nso> <rtld.out.nso>")
    main_raw = load_nso(a[0])
    main_size = page_up(max(s.mem_off + s.size for s in main_raw.segments.values()) + main_raw.bss_size)
    sub_base, sdk_base = main_size, main_size + SUB_SIZE
    T = Tramps(sub_base, nsobuild.TEXT_START)
    report, skipped = {"main_size": hex(main_size), "subsdk_base": hex(sub_base), "sdk_base": hex(sdk_base)}, []
    sk, pm = apply("main", *a[0:4], 0, T, report)
    skipped += sk
    sk, ps = apply("sdk", *a[4:8], sdk_base, T, report)
    skipped += sk
    if NATIVE:
        # rtld sits directly before main: [rtld | main | subsdk9 | sdk]
        r = load_nso(a[9])
        rtld_size = page_up(max(s_.mem_off + s_.size for s_ in r.segments.values()) + r.bss_size)
        report["rtld_size"] = hex(rtld_size)
        apply_native_only("rtld", a[9], a[10], -rtld_size, T, report)

    # Verify every trampoline instruction that carries an expected text.
    addrs = [c[0] for c in T.checks]
    texts = disassemble_words([T.words[(x - sub_base - T.text_off) // 4] for x in addrs], addrs)
    bad = [(hex(x), e, t) for (x, e), t in zip(T.checks, texts) if e is not None and _norm(t) != e]
    bad += [(hex(x), "valid", t) for x, t in zip(addrs, texts) if t is None or "unknown" in t]
    for x, want in T.targets:
        w = T.words[(x - sub_base - T.text_off) // 4]
        got = _b_target(w, x) if (w >> 26) == 5 else enc.cond_branch_target(w, x)
        if got != want:
            bad.append((hex(x), hex(want), "branch target"))
    for x, want in T.ptrs:
        w0, w1 = T.words[(x - sub_base - T.text_off) // 4], T.words[(x + 4 - sub_base - T.text_off) // 4]
        page = enc.decode_pcrel(w0, x)[2]
        if page + ((w1 >> 10) & 0xFFF) * 8 != want:
            bad.append((hex(x), hex(want), "table address"))
    report["trampoline_words"] = len(T.words)
    report["trampoline_check_failures"] = len(bad)
    if bad:
        print(bad[:20])
        sys.exit("trampoline verification failed")
    image = nsobuild.build_module(T.words, SUB_SIZE, native=NATIVE)
    open(a[8], "wb").write(image)
    print(json.dumps(report, indent=2))
    json.dump({"report": report, "skipped": skipped}, open(a[8] + ".report.json", "w"), indent=1)


if __name__ == "__main__":
    main()
