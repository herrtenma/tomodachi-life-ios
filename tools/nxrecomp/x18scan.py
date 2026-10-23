"""Find every use of x18/w18 in an NSO and plan a per-function rename to a free
caller-saved register.

usage: x18scan.py <uncompressed.nso> <out.json>
"""
import bisect
import json
import re
import sys
import time

from disasm import disassemble
from noreturn import find_noreturn
from nso import functions_from_eh_frame, load_nso
from regflow import Insn, build_cfg, liveness, rename_x18, unpredictable

X18 = re.compile(r"\b[xw]18\b")
# Replacement preference: plain temporaries, IP0/IP1, argument registers, then
# registers that are only free in part of the function: callee-saved x19-x28
# (free between the function's own save and restore) and x30 (free between the
# prologue's save and the epilogue's restore, except at calls). Liveness proves
# each choice: an unsaved callee-saved register or an unsaved LR is live from
# entry to return and therefore always interferes.
CANDIDATES = [9, 10, 11, 12, 13, 14, 15, 16, 17, 0, 1, 2, 3, 4, 5, 6, 7, 8,
              30, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28]
B18 = 1 << 18


def interferes(insns, lout, r, points):
    """True if register r cannot hold x18's value at the given instruction indices."""
    br = 1 << r
    for i in points:
        ins, lo = insns[i], lout[i]
        if ins.xdefs & B18 and (lo & br or ins.defs & br):
            return True
        if ins.defs & br and lo & B18:
            return True
        if (ins.xdefs | ins.uses) & B18 and (ins.xdefs | ins.uses) & br \
                and X18.search(ins.text) and unpredictable(rename_x18(ins.text, r)):
            return True  # rename would create an illegal encoding (e.g. stxr w9, w9, [x10])
    return False


def x18_liveness(insns):
    """Liveness with x18 masked to where a real definition can reach.

    Under the Switch ABI x18 is a plain temporary: nothing is passed in it, and
    every call clobbers it. A read reached from function entry or from a call with
    no definition in between reads an undefined value; LLVM emits these for PHIs
    with undef inputs (e.g. `csel w18, w18, wzr, ne` opening a loop), and the value
    never matters. So x18 counts as live only where a real definition may reach.
    Returns (lin, lout, undef_reads) where undef_reads lists x18 reads that no real
    definition reaches at all."""
    lin, lout = liveness(insns)
    n = len(insns)
    preds = [[] for _ in range(n)]
    for i, ins in enumerate(insns):
        for s in ins.succ:
            preds[s].append(i)
    rin, rout = [False] * n, [False] * n
    work, inq = list(range(n - 1, -1, -1)), [True] * n
    while work:
        i = work.pop()
        inq[i] = False
        ins = insns[i]
        r = any(rout[p] for p in preds[i])
        rin[i] = r
        o = bool(ins.xdefs & B18) or (r and ins.kind != "call")
        if o != rout[i]:
            rout[i] = o
            for s in ins.succ:
                if not inq[s]:
                    inq[s] = True
                    work.append(s)
    undef_reads = [insns[i].addr for i in range(n) if insns[i].uses & B18 and not rin[i]
                   and insns[i].kind != "call"]
    for i in range(n):
        if not rin[i]:
            lin[i] &= ~B18
        if not rout[i]:
            lout[i] &= ~B18
    return lin, lout, undef_reads


def undef_only_webs(insns, lin, undef_reads):
    """Reads of x18 that only ever see an undefined value and are not part of any web
    (they define nothing): each is its own one-instruction web. Any register works,
    since the value read is garbage either way."""
    addrs = set(undef_reads)
    return [[i] for i, ins in enumerate(insns)
            if ins.addr in addrs and not ins.xdefs & B18 and not lin[i] & B18]


def x18_webs(insns, lin):
    """Split x18 into independent live ranges: connected components of instructions
    that define x18 or have it live-in, joined along CFG edges that carry x18."""
    nodes = [i for i, ins in enumerate(insns) if ins.xdefs & B18 or lin[i] & B18]
    parent = {i: i for i in nodes}

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i in nodes:
        for s in insns[i].succ:
            if lin[s] & B18:
                parent[find(i)] = find(s)
    webs = {}
    for i in nodes:
        webs.setdefault(find(i), []).append(i)
    return list(webs.values())


def analyze_function(start, end, insns_text, image, noreturn=frozenset()):
    insns = [Insn(a, t) for a, t in insns_text]
    unresolved = build_cfg(insns, start, end, image, noreturn)
    raw_lin, raw_lout = liveness(insns)
    lin, lout, undef_reads = x18_liveness(insns)
    hazards, notes = {}, {}
    # Before masking these were hazards; now they are undefined-value reads. Keep them
    # visible: hand-written code that really passes a value in x18 would look the same.
    if insns and raw_lin[0] & B18:
        notes["raw_live_at_entry"] = True
    across = [ins.addr for ins, lo in zip(insns, raw_lout) if ins.kind == "call" and lo & B18]
    if across:
        notes["raw_live_across_call"] = across
    if undef_reads:
        notes["undef_reads"] = undef_reads
    # A store of an x18 nothing defined is a register save made on someone else's
    # behalf (e.g. the TLS-descriptor resolver saving every register). Leave such
    # functions untouched: saving/restoring x18 is harmless when no caller relies on it.
    saves = [ins.addr for ins in insns if ins.addr in set(undef_reads) and ins.mn.startswith("st")]
    if saves:
        hazards["saves_x18"] = saves
    if insns and lin[0] & B18:
        hazards["live_at_entry"] = True
    across = [ins.addr for ins, lo in zip(insns, lout) if ins.kind == "call" and lo & B18]
    if across:
        hazards["live_across_call"] = across
    if unresolved:
        hazards["unresolved_br"] = unresolved
    sites = [ins.addr for ins in insns if X18.search(ins.text)]
    webs = []
    if not hazards:
        site_set = set(sites)
        covered = set()
        for points in x18_webs(insns, lin) + undef_only_webs(insns, lin, undef_reads):
            reg = next((r for r in CANDIDATES if not interferes(insns, lout, r, points)), None)
            web_sites = [insns[i].addr for i in points if insns[i].addr in site_set]
            covered.update(web_sites)
            webs.append({"reg": reg, "sites": web_sites})
        stray = site_set - covered
        if stray:  # mentions x18 without defining or reading it per our model: must not happen
            hazards["unmodelled_sites"] = sorted(stray)
    return {"start": start, "end": end, "sites": sites, "webs": webs, "notes": notes,
            "replacement": None if hazards or any(w["reg"] is None for w in webs) else "per-web",
            "hazards": hazards}


def scan(path):
    nso = load_nso(path)
    funcs = functions_from_eh_frame(nso)
    starts = [s for s, _ in funcs]
    text = nso.text
    noreturn = find_noreturn(nso.image, text.mem_off, text.size, funcs)
    results, orphans = [], []
    cur_idx, cur_buf, cur_hit = -1, [], False
    n_insn = 0
    t0 = time.time()

    def flush():
        if cur_idx >= 0 and cur_hit:
            s, e = funcs[cur_idx]
            results.append(analyze_function(s, e, cur_buf, nso.image, noreturn))

    for addr, txt in disassemble(nso.image[text.mem_off:text.mem_off + text.size], text.mem_off):
        n_insn += 1
        i = bisect.bisect_right(starts, addr) - 1
        if i < 0 or addr >= funcs[i][1]:
            if X18.search(txt):
                orphans.append({"addr": addr, "text": txt})
            continue
        if i != cur_idx:
            flush()
            cur_idx, cur_buf, cur_hit = i, [], False
        cur_buf.append((addr, txt))
        if not cur_hit and X18.search(txt):
            cur_hit = True
    flush()
    return nso, funcs, results, orphans, n_insn, time.time() - t0, sorted(noreturn)


def main():
    path, out = sys.argv[1], sys.argv[2]
    nso, funcs, results, orphans, n_insn, dt, noreturn = scan(path)
    sites = sum(len(r["sites"]) for r in results)
    no_free = [r for r in results if r["replacement"] is None and not r["hazards"]]
    hz = {}
    for r in results:
        for k in r["hazards"]:
            hz[k] = hz.get(k, 0) + 1
    clean = [r for r in results if r["replacement"] is not None]
    all_webs = [w for r in results for w in r["webs"]]
    stuck = [w for w in all_webs if w["reg"] is None]
    summary = {
        "file": path, "instructions": n_insn, "functions": len(funcs),
        "x18_functions": len(results), "x18_sites": sites,
        "renamable": len(clean), "functions_with_stuck_webs": len(no_free),
        "webs": len(all_webs), "stuck_webs": len(stuck),
        "stuck_web_sites": sum(len(w["sites"]) for w in stuck),
        "hazard_counts": hz, "orphan_sites": len(orphans), "seconds": round(dt, 1),
    }
    json.dump({"summary": summary, "functions": results, "orphans": orphans, "noreturn": noreturn},
              open(out, "w"))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
