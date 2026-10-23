"""Build a minimal code-only NSO module (used for the x18 trampolines, subsdk9).

Layout (module-relative):
  text  0x0     word0 = 0, word1 = offset of MOD0; MOD0 at 0x8; code at TEXT_START
  ro    page    empty SysV hash, one null dynsym, "\\0" dynstr, empty eh_frame_hdr
  data  page    .dynamic (DT_HASH, DT_STRTAB, DT_SYMTAB, DT_STRSZ, DT_SYMENT)
  bss           module object for rtld, padded so the module is exactly `total` bytes

rtld relocates and links every module through its MOD0 and .dynamic, so the module
exports nothing but stays well formed: symbol lookups walk an empty hash bucket.
"""
import struct

TEXT_START = 0x100
DT_NULL, DT_HASH, DT_STRTAB, DT_SYMTAB, DT_STRSZ, DT_SYMENT = 0, 4, 5, 6, 10, 11


def page_up(n):
    return (n + 0xFFF) & ~0xFFF


# Native flavor (our own loader, 16 KB pages): fixed layout so trampolines can address
# the runtime table before the text size is known.
NATIVE_PAGE = 0x4000
NATIVE_TEXT_CAP = 0x180000          # text   [0, 0x180000)
NATIVE_RO = NATIVE_TEXT_CAP         # ro     [0x180000, 0x184000)
NATIVE_DATA = NATIVE_RO + NATIVE_PAGE   # data   [0x184000, ...)
RT_TABLE = NATIVE_DATA + 0x100      # runtime table, filled by the loader:
RT_MAGIC, RT_TSD_KEY_OFF, RT_SVC_ENTRY = 0, 8, 16   #   "NXRTTBL1", u64 tsd key*8, u64 svc_entry
RT_TABLE_PTR = 0x80                 # text word: module-relative offset of the runtime table


def _page_up(n, page):
    return (n + page - 1) & ~(page - 1)


def build_module(words, total, module_id=b"x18-trampolines", native=False):
    code = struct.pack(f"<{len(words)}I", *words)
    if native:
        if TEXT_START + len(code) > NATIVE_TEXT_CAP:
            raise ValueError("native trampolines exceed the text cap")
        text = bytearray(NATIVE_TEXT_CAP)
    else:
        text = bytearray(page_up(TEXT_START + len(code)))
    text[TEXT_START:TEXT_START + len(code)] = code
    text_off = 0
    ro_off = len(text)

    # ro: [0..8) zero (Ryujinx reads a module-path record here), then tables.
    ro = bytearray(0x10)
    hash_off = ro_off + len(ro)
    ro += struct.pack("<4I", 1, 1, 0, 0)          # nbucket, nchain, bucket[0], chain[0]
    dynsym_off = ro_off + len(ro)
    ro += b"\0" * 24
    dynstr_off = ro_off + len(ro)
    ro += b"\0\0\0\0\0\0\0\0"
    ehh_off = ro_off + len(ro)
    eh_frame_off = ehh_off + 12
    ro += bytes([1, 0x1B, 0x03, 0x3B]) + struct.pack("<iI", eh_frame_off - (ehh_off + 4), 0)
    ro += struct.pack("<I", 0)                    # .eh_frame: zero terminator only
    ehh_end = ehh_off + 12
    ro = ro + b"\0" * (_page_up(len(ro), NATIVE_PAGE if native else 0x1000) - len(ro))
    if native and ro_off + len(ro) != NATIVE_DATA:
        raise ValueError("native ro does not fit its page")

    data_off = ro_off + len(ro)
    dyn = b"".join(struct.pack("<qQ", t, v) for t, v in (
        (DT_HASH, hash_off), (DT_STRTAB, dynstr_off), (DT_SYMTAB, dynsym_off),
        (DT_STRSZ, 1), (DT_SYMENT, 24), (DT_NULL, 0)))
    data = bytearray(dyn)
    if native:
        data += b"\0" * (RT_TABLE - data_off - len(data))
        data += b"NXRTTBL1" + b"\0" * 24           # magic, tsd key offset, svc_entry, spare
    data_end = data_off + len(data)
    bss_start = (data_end + 7) & ~7
    data += b"\0" * (bss_start - data_end)
    module_object = bss_start
    bss_size = total - (data_off + len(data))
    if bss_size < 0x1000:
        raise ValueError(f"trampolines do not fit in {total:#x} bytes")

    mod0 = 8
    struct.pack_into("<II", text, 0, 0, mod0)
    if native:
        struct.pack_into("<I", text, RT_TABLE_PTR, RT_TABLE)
    struct.pack_into("<4s6i", text, mod0, b"MOD0",
                     data_off - mod0, bss_start - mod0, bss_start + bss_size - mod0,
                     ehh_off - mod0, ehh_end - mod0, module_object - mod0)

    hdr = bytearray(0x100)
    file_text = 0x100
    file_ro = file_text + len(text)
    file_data = file_ro + len(ro)
    struct.pack_into("<4sIII", hdr, 0, b"NSO0", 0, 0, 0)  # flags 0: uncompressed, no hash check
    struct.pack_into("<4I", hdr, 0x10, file_text, text_off, len(text), 0)
    struct.pack_into("<4I", hdr, 0x20, file_ro, ro_off, len(ro), 0)
    struct.pack_into("<4I", hdr, 0x30, file_data, data_off, len(data), bss_size)
    hdr[0x40:0x60] = module_id.ljust(32, b"\0")[:32]
    struct.pack_into("<3I", hdr, 0x60, len(text), len(ro), len(data))
    struct.pack_into("<6I", hdr, 0x88, 0, 0, dynstr_off - ro_off, 1, dynsym_off - ro_off, 24)
    return bytes(hdr + text + ro + data)
