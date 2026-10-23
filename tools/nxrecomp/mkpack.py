"""Port pack data for the packager app (nx-packager): what turns the user's own game files into this port's game image.

Run by the port's developer after changing the native NSOs (spill.py / patch.py); the output is committed in port/:
    port/layout.json        each module's sizes (embed.py --empty builds the base app's empty slots from it)
    port/patches/<m>.nxwp   the words our native build changes in the game's module <m>: "NXWP", u32 count, then count x
                            (u32 offset in the memory image, u32 new word). Only our instructions: no game bytes.
    port/modules/<m>.img    modules that are entirely ours (subsdk9: the x18 trampolines)
    port/modules.json       per module: where it comes from, SHA-256 of the input image (the user's dump must match)
                            and of the result (checked before anything is installed)

Images are NSO memory images (segments at their memory offsets, decompressed, bss not included), as embed.py and the
packager build them.

usage: mkpack.py <original exefs dir (decompressed or not)> <dir with *.native.nso> <port dir>"""
import hashlib
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from embed import HOOKS, MODULES, page_up  # noqa: E402

GENERATED = {"subsdk9"}   # modules spill.py writes from scratch


def lz4_block(src, size):
    out, i = bytearray(), 0
    while i < len(src):
        tok = src[i]
        i += 1
        lit = tok >> 4
        if lit == 15:
            while True:
                b = src[i]
                i += 1
                lit += b
                if b != 255:
                    break
        out += src[i:i + lit]
        i += lit
        if i >= len(src):
            break
        off = src[i] | src[i + 1] << 8
        i += 2
        n = (tok & 15) + 4
        if tok & 15 == 15:
            while True:
                b = src[i]
                i += 1
                n += b
                if b != 255:
                    break
        for _ in range(n):
            out.append(out[-off])
    assert len(out) == size
    return bytes(out)


def nso_image(path):
    raw = open(path, "rb").read()
    if raw[:4] != b"NSO0":
        raise SystemExit(f"{path}: not an NSO")
    flags = struct.unpack_from("<I", raw, 0xC)[0]
    segs = [struct.unpack_from("<III", raw, 0x10 + i * 0x10) for i in range(3)]
    fsize = struct.unpack_from("<3I", raw, 0x60)
    bss = struct.unpack_from("<I", raw, 0x3C)[0]
    img = bytearray(max(m + s for _, m, s in segs))
    for i, (off, mem, size) in enumerate(segs):
        data = lz4_block(raw[off:off + fsize[i]], size) if flags >> i & 1 else raw[off:off + size]
        img[mem:mem + size] = data
    return bytes(img), segs, bss


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    orig_dir, native_dir, port = sys.argv[1:]
    os.makedirs(os.path.join(port, "patches"), exist_ok=True)
    os.makedirs(os.path.join(port, "modules"), exist_ok=True)
    layout, modules = [], []
    for slot, name in enumerate(MODULES):
        img, segs, bss = nso_image(os.path.join(native_dir, f"{name}.native.nso"))
        layout.append({"name": name, "slot": slot, "text_size": segs[0][2], "ro_off": segs[1][1], "ro_size": segs[1][2],
                       "data_off": segs[2][1], "data_size": segs[2][2], "bss": bss, "image_size": len(img),
                       "span": page_up(len(img) + bss),
                       "hooks": [{"offset": off, "symbol": sym} for mod, off, sym in HOOKS if mod == name]})
        m = {"name": name, "slot": slot, "output_sha256": hashlib.sha256(img).hexdigest()}
        if name in GENERATED:
            open(os.path.join(port, "modules", f"{name}.img"), "wb").write(img)
            m["source"] = f"modules/{name}.img"
        else:
            src = next(p for p in (os.path.join(orig_dir, name + ".raw"), os.path.join(orig_dir, name)) if os.path.exists(p))
            orig, osegs, obss = nso_image(src)
            if len(orig) != len(img) or [s[1:] for s in osegs] != [s[1:] for s in segs] or obss != bss:
                raise SystemExit(f"{name}: the native module's layout differs from the game's")
            n = len(img) // 4
            a, b = struct.unpack(f"<{n}I", orig[:n * 4]), struct.unpack(f"<{n}I", img[:n * 4])
            words = [(i * 4, b[i]) for i in range(n) if a[i] != b[i]]
            if orig[n * 4:] != img[n * 4:]:
                raise SystemExit(f"{name}: unaligned tail differs")
            blob = b"NXWP" + struct.pack("<I", len(words)) + b"".join(struct.pack("<II", o, w) for o, w in words)
            open(os.path.join(port, "patches", f"{name}.nxwp"), "wb").write(blob)
            m.update(source=f"exefs:{name}", input_sha256=hashlib.sha256(orig).hexdigest(), patch=f"patches/{name}.nxwp",
                     words=len(words))
        modules.append(m)
        print(f"{name}: image {len(img):#x}, {m.get('words', 'generated')} words")
    json.dump(layout, open(os.path.join(port, "layout.json"), "w"), indent=1)
    json.dump(modules, open(os.path.join(port, "modules.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
