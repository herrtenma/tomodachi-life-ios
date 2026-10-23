"""NSO loading (uncompressed NSO as written by `hactool --uncompressed`) and
function discovery from .eh_frame_hdr / .eh_frame."""
import struct
from dataclasses import dataclass, field


@dataclass
class Segment:
    name: str
    file_off: int
    mem_off: int
    size: int


@dataclass
class Nso:
    path: str
    raw: bytearray
    segments: dict
    bss_size: int
    image: bytearray = field(repr=False)  # flat memory image (text|ro|data), bss excluded
    mod0: dict = None

    @property
    def text(self):
        return self.segments["text"]

    def read32(self, addr):
        return struct.unpack_from("<I", self.image, addr)[0]

    def write32(self, addr, value):
        struct.pack_into("<I", self.image, addr, value)


def load_nso(path):
    raw = bytearray(open(path, "rb").read())
    if raw[:4] != b"NSO0":
        raise ValueError(f"{path}: not an NSO")
    flags = struct.unpack_from("<I", raw, 0xC)[0]
    if flags & 7:
        raw = _decompress(raw, flags)
    segs = {}
    for i, name in enumerate(("text", "ro", "data")):
        fo, mo, sz = struct.unpack_from("<III", raw, 0x10 + i * 0x10)
        segs[name] = Segment(name, fo, mo, sz)
    bss = struct.unpack_from("<I", raw, 0x3C)[0]
    end = segs["data"].mem_off + segs["data"].size
    image = bytearray(end)
    for s in segs.values():
        image[s.mem_off:s.mem_off + s.size] = raw[s.file_off:s.file_off + s.size]
    nso = Nso(path, raw, segs, bss, image)
    nso.mod0 = _parse_mod0(nso)
    return nso


def lz4_block_decompress(src, out_size):
    """Decode one LZ4 block (no frame header), as used for NSO segments."""
    out = bytearray()
    i, n = 0, len(src)
    while i < n:
        token = src[i]
        i += 1
        lit = token >> 4
        if lit == 15:
            while True:
                b = src[i]
                i += 1
                lit += b
                if b != 255:
                    break
        out += src[i:i + lit]
        i += lit
        if i >= n:
            break
        off = src[i] | src[i + 1] << 8
        i += 2
        mlen = token & 15
        if mlen == 15:
            while True:
                b = src[i]
                i += 1
                mlen += b
                if b != 255:
                    break
        mlen += 4
        start = len(out) - off
        if off >= mlen:
            out += out[start:start + mlen]
        else:
            for k in range(mlen):
                out.append(out[start + k])
    if len(out) != out_size:
        raise ValueError(f"lz4: got {len(out)} bytes, expected {out_size}")
    return bytes(out)


def _decompress(raw, flags):
    """Rewrite a compressed NSO as an uncompressed one (header + segments in place)."""
    hdr = bytearray(raw[:0x100])
    body = bytearray()
    pos = 0x100
    for i in range(3):
        fo, mo, sz = struct.unpack_from("<III", raw, 0x10 + i * 0x10)
        csz = struct.unpack_from("<I", raw, 0x60 + 4 * i)[0]
        chunk = raw[fo:fo + csz]
        data = lz4_block_decompress(chunk, sz) if flags & (1 << i) else bytes(chunk[:sz])
        struct.pack_into("<I", hdr, 0x10 + i * 0x10, pos)
        struct.pack_into("<I", hdr, 0x60 + 4 * i, sz)
        body += data
        pos += sz
    struct.pack_into("<I", hdr, 0xC, 0)
    return bytearray(hdr + body)


def _parse_mod0(nso):
    off = nso.read32(4)
    if nso.image[off:off + 4] != b"MOD0":
        return None
    rel = struct.unpack_from("<6i", nso.image, off + 4)
    keys = ("dynamic", "bss_start", "bss_end", "eh_frame_hdr_start", "eh_frame_hdr_end", "module_object")
    return {k: off + v for k, v in zip(keys, rel)}


def write_nso(nso, path):
    """Write the (possibly patched) image back as an uncompressed NSO.
    Segment hash checking is disabled because patched segments no longer match."""
    out = bytearray(nso.raw)
    for s in nso.segments.values():
        out[s.file_off:s.file_off + s.size] = nso.image[s.mem_off:s.mem_off + s.size]
    struct.pack_into("<I", out, 0xC, 0)  # flags: uncompressed, no hash check
    with open(path, "wb") as f:
        f.write(out)


# ---------------------------------------------------------------- eh_frame

DW_EH_PE_omit = 0xFF


def _read_encoded(buf, pos, enc, data_base=0):
    """Read a DW_EH_PE-encoded value at image offset `pos`. Returns (value, new_pos)."""
    if enc == DW_EH_PE_omit:
        return None, pos
    fmt = enc & 0x0F
    app = enc & 0x70
    if fmt == 0x00:   # absptr
        v, n = struct.unpack_from("<Q", buf, pos)[0], 8
    elif fmt == 0x01:  # uleb128
        v, n = _uleb(buf, pos)
    elif fmt == 0x02:
        v, n = struct.unpack_from("<H", buf, pos)[0], 2
    elif fmt == 0x03:
        v, n = struct.unpack_from("<I", buf, pos)[0], 4
    elif fmt == 0x04:
        v, n = struct.unpack_from("<Q", buf, pos)[0], 8
    elif fmt == 0x09:
        v, n = _sleb(buf, pos)
    elif fmt == 0x0A:
        v, n = struct.unpack_from("<h", buf, pos)[0], 2
    elif fmt == 0x0B:
        v, n = struct.unpack_from("<i", buf, pos)[0], 4
    elif fmt == 0x0C:
        v, n = struct.unpack_from("<q", buf, pos)[0], 8
    else:
        raise ValueError(f"unsupported pointer encoding {enc:#x}")
    if app == 0x10:    # pcrel
        v += pos
    elif app == 0x30:  # datarel
        v += data_base
    elif app != 0:
        raise ValueError(f"unsupported pointer application {enc:#x}")
    return v, pos + n


def _uleb(buf, pos):
    result = shift = 0
    start = pos
    while True:
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        shift += 7
        if not b & 0x80:
            return result, pos - start


def _sleb(buf, pos):
    result = shift = 0
    start = pos
    while True:
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        shift += 7
        if not b & 0x80:
            if b & 0x40:
                result -= 1 << shift
            return result, pos - start


def _cie_fde_encoding(buf, cie_pos):
    """Return the FDE pointer encoding from a CIE's augmentation data ('R')."""
    length = struct.unpack_from("<I", buf, cie_pos)[0]
    pos = cie_pos + 8  # skip length + CIE id
    version = buf[pos]
    pos += 1
    aug_end = buf.index(b"\0", pos)
    aug = buf[pos:aug_end].decode()
    pos = aug_end + 1
    if version >= 4:
        pos += 2  # address_size, segment_size
    _, n = _uleb(buf, pos); pos += n   # code alignment
    _, n = _sleb(buf, pos); pos += n   # data alignment
    if version == 1:
        pos += 1
    else:
        _, n = _uleb(buf, pos); pos += n  # return address register
    enc = 0x00
    if aug.startswith("z"):
        _, n = _uleb(buf, pos); pos += n
        for ch in aug[1:]:
            if ch == "R":
                enc = buf[pos]; pos += 1
            elif ch == "P":
                penc = buf[pos]; pos += 1
                _, pos = _read_encoded(buf, pos, penc)
            elif ch == "L":
                pos += 1
            elif ch in "SB":
                pass
            else:
                break
    return enc


def functions_from_eh_frame(nso):
    """List of (start, end) for every FDE indexed by .eh_frame_hdr, sorted by start."""
    m = nso.mod0
    if not m or m["eh_frame_hdr_start"] == m["eh_frame_hdr_end"]:
        return []
    buf = nso.image
    hdr = m["eh_frame_hdr_start"]
    version, ptr_enc, cnt_enc, tbl_enc = buf[hdr:hdr + 4]
    if version != 1:
        raise ValueError(f"unknown eh_frame_hdr version {version}")
    pos = hdr + 4
    _, pos = _read_encoded(buf, pos, ptr_enc)
    count, pos = _read_encoded(buf, pos, cnt_enc)
    cie_enc_cache = {}
    funcs = []
    for _ in range(count):
        _, pos = _read_encoded(buf, pos, tbl_enc, data_base=hdr)
        fde, pos = _read_encoded(buf, pos, tbl_enc, data_base=hdr)
        cie_ptr_pos = fde + 4
        cie = cie_ptr_pos - struct.unpack_from("<I", buf, cie_ptr_pos)[0]
        enc = cie_enc_cache.get(cie)
        if enc is None:
            enc = cie_enc_cache[cie] = _cie_fde_encoding(buf, cie)
        p = fde + 8
        start, p = _read_encoded(buf, p, enc)
        size, p = _read_encoded(buf, p, enc & 0x0F)  # pc_range: same format, no application
        funcs.append((start, start + size))
    funcs.sort()
    return funcs
