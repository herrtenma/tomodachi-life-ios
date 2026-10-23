"""Find functions that never return, so calls to them get no fall-through edge.

Rule: a function with no exit (no ret, no branch leaving it, no br) cannot return.

Deliberately NOT used: "the callee of a function's last `bl` cannot return". A caller
may end with a call because the path after it is unreachable *in that caller* (e.g.
`if (!lookup(k)) __builtin_unreachable();`), which says nothing about the callee:
main 0x3f64f0 ends with `bl 0x1a3bf98`, an ordinary bool-returning hash lookup.
That rule cut real return edges and broke liveness (found 2026-10-06 by a JIT-mode crash).
A call that is the last instruction of its function gets no fall-through edge anyway.
"""
import bisect
import re

from disasm import disassemble

_T = re.compile(r"0x([0-9a-f]+)")


def find_noreturn(image, text_off, text_size, funcs):
    starts = [s for s, _ in funcs]
    info = {}   # start -> [has_exit, set(direct call targets), last_call_target]
    cur = None
    for addr, txt in disassemble(image[text_off:text_off + text_size], text_off):
        i = bisect.bisect_right(starts, addr) - 1
        if i < 0 or addr >= funcs[i][1]:
            continue
        s, e = funcs[i]
        rec = info.setdefault(s, [False, set(), None])
        mn = txt.split("\t", 1)[0]
        tgt = _T.findall(txt.split(" <")[0])
        t = int(tgt[-1], 16) if tgt else None
        if mn in ("ret", "br", "eret", "retaa", "retab"):
            rec[0] = True
        elif mn == "b" or mn.startswith("b.") or mn in ("cbz", "cbnz", "tbz", "tbnz"):
            if t is not None and not s <= t < e:
                rec[0] = True          # tail call or branch out
        elif mn == "bl" and t is not None:
            rec[1].add(t)
        if addr + 4 == e:
            rec[2] = t if mn == "bl" else None
    return {s for s, r in info.items() if not r[0]}
