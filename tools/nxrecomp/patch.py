"""Apply the per-web x18 renames planned by x18scan.py and verify them.

usage: patch.py <uncompressed.nso> <plan.json> <out.nso>

Every rewritten instruction is checked by disassembling the new encoding and
requiring it to equal the original text with only x18/w18 replaced. Afterwards
the whole .text is re-disassembled and diffed against the original.
"""
import itertools
import json
import re
import sys

from disasm import disassemble
from nso import load_nso, write_nso
from regflow import rename_x18, unpredictable

FIELDS = (0, 5, 10, 16)  # Rd/Rt, Rn, Rt2/Ra, Rm/Rs
X18 = re.compile(r"\b([xw])18\b")


def candidates(word, reg):
    """All encodings obtained by replacing some register field that holds 18 with `reg`."""
    holding = [f for f in FIELDS if (word >> f) & 31 == 18]
    out = []
    for k in range(1, len(holding) + 1):
        for subset in itertools.combinations(holding, k):
            w = word
            for f in subset:
                w = (w & ~(31 << f)) | (reg << f)
            out.append(w)
    return out


def _norm(text):
    return re.sub(r"\s*//.*$", "", text)


def main():
    nso_path, plan_path, out_path = sys.argv[1:4]
    nso = load_nso(nso_path)
    plan = json.load(open(plan_path))
    text = nso.text
    orig = {a: t for a, t in disassemble(nso.image[text.mem_off:text.mem_off + text.size], text.mem_off)}

    # Collect sites to rewrite.
    jobs = []  # (addr, reg, web id)
    web_id = 0
    for fn in plan["functions"]:
        if fn["hazards"]:
            continue
        for web in fn["webs"]:
            if web["reg"] is not None:
                jobs.extend((a, web["reg"], web_id) for a in web["sites"])
            web_id += 1

    # Batch-disassemble every candidate encoding at its own address.
    cand_words, cand_addrs, owners = [], [], []
    for n, (addr, reg, _) in enumerate(jobs):
        for w in candidates(nso.read32(addr), reg):
            cand_words.append(w)
            cand_addrs.append(addr)
            owners.append(n)
    cand_text = _disassemble_candidates(nso, cand_words, cand_addrs)

    chosen, failures = {}, []
    for i, w in enumerate(cand_words):
        n = owners[i]
        addr, reg, _ = jobs[n]
        if addr in chosen:
            continue
        if _norm(cand_text[i]) == _norm(rename_x18(orig[addr], reg)) and not unpredictable(cand_text[i]):
            chosen[addr] = (w, cand_text[i])
    # A web is renamed completely or not at all: a partially renamed web would
    # write the value to one register and read it from another.
    failed_webs = set()
    for addr, reg, web in jobs:
        if addr not in chosen:
            failures.append({"addr": addr, "reg": reg, "orig": orig[addr]})
            failed_webs.add(web)
    for addr, reg, web in jobs:
        if web in failed_webs:
            chosen.pop(addr, None)

    for addr, (w, _) in chosen.items():
        nso.write32(addr, w)

    # Whole-text verification against the original disassembly.
    unexpected = []
    for addr, t in disassemble(nso.image[text.mem_off:text.mem_off + text.size], text.mem_off):
        if t != orig[addr] and (addr not in chosen or t != chosen[addr][1]):
            unexpected.append({"addr": addr, "orig": orig[addr], "now": t})

    remaining = sum(1 for a, t in orig.items() if X18.search(t)) - len(chosen)
    report = {"sites_planned": len(jobs), "rewritten": len(chosen), "encode_failures": len(failures),
              "webs_reverted": len(failed_webs),
              "unexpected_diffs": len(unexpected), "x18_sites_remaining": remaining}
    print(json.dumps(report, indent=2))
    json.dump({"report": report, "failures": failures[:200], "unexpected": unexpected[:200]},
              open(out_path + ".report.json", "w"), indent=1)
    if unexpected:
        sys.exit("verification failed: unexpected instruction changes; NSO not written")
    write_nso(nso, out_path)


def _disassemble_candidates(nso, words, addrs):
    """Disassemble each candidate word at its own address. Candidates are grouped into
    batches with unique addresses; each batch is written into a copy of .text, which is
    disassembled in one pass so PC-relative operands decode exactly as in place."""
    text = nso.text
    out = [None] * len(words)
    remaining = list(range(len(words)))
    while remaining:
        seen, batch, rest = set(), {}, []
        for i in remaining:
            if addrs[i] in seen:
                rest.append(i)
            else:
                seen.add(addrs[i])
                batch[addrs[i]] = i
        code = bytearray(nso.image[text.mem_off:text.mem_off + text.size])
        for a, i in batch.items():
            code[a - text.mem_off:a - text.mem_off + 4] = words[i].to_bytes(4, "little")
        for a, t in disassemble(code, text.mem_off):
            i = batch.get(a)
            if i is not None:
                out[i] = t
        remaining = rest
    return out


if __name__ == "__main__":
    main()
