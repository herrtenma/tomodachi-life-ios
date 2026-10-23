"""Minimal AArch64 encoders for the instructions trampolines need."""

SP = 31


def _check_branch(off, bits, name):
    if off & 3:
        raise ValueError(f"{name}: misaligned offset {off:#x}")
    lim = 1 << (bits + 1)
    if not -lim <= off < lim:
        raise ValueError(f"{name}: offset {off:#x} out of range")


def b(src, dst):
    off = dst - src
    _check_branch(off, 26, "b")
    return 0x14000000 | ((off >> 2) & 0x3FFFFFF)


def stur_x(rt, rn, imm9):
    return 0xF8000000 | ((imm9 & 0x1FF) << 12) | (rn << 5) | rt


def ldur_x(rt, rn, imm9):
    return 0xF8400000 | ((imm9 & 0x1FF) << 12) | (rn << 5) | rt


def adrp(rd, src, target):
    page_off = (target >> 12) - (src >> 12)
    if not -(1 << 20) <= page_off < (1 << 20):
        raise ValueError("adrp out of range")
    imm = page_off & 0x1FFFFF
    return 0x90000000 | ((imm & 3) << 29) | ((imm >> 2) << 5) | rd


def add_imm(rd, rn, imm12):
    if not 0 <= imm12 < 4096:
        raise ValueError("add imm out of range")
    return 0x91000000 | (imm12 << 10) | (rn << 5) | rd


def ldr_lit_like(size_bits, signed, rt, rn):
    """ldr{,sw} <rt>, [<rn>] for literal-load replacement. size_bits: 32 or 64."""
    if signed:
        return 0xB9800000 | (rn << 5) | rt          # ldrsw xT, [xN]
    return (0xF9400000 if size_bits == 64 else 0xB9400000) | (rn << 5) | rt


def retarget_cond_branch(word, src, dst, reg):
    """Re-encode cbz/cbnz (imm19) or tbz/tbnz (imm14) at a new address with a new target/register."""
    off = dst - src
    if (word & 0x7E000000) == 0x34000000:    # cbz/cbnz
        _check_branch(off, 19, "cbz")
        return (word & 0xFF00001F & ~0x1F) | (((off >> 2) & 0x7FFFF) << 5) | reg
    if (word & 0x7E000000) == 0x36000000:    # tbz/tbnz
        _check_branch(off, 14, "tbz")
        return (word & 0xFFF8001F & ~0x1F) | (((off >> 2) & 0x3FFF) << 5) | reg
    raise ValueError(f"not a cbz/tbz: {word:#010x}")


def decode_pcrel(word, pc):
    """Return (kind, rd, target, extra) for adr/adrp/ldr-literal, else None."""
    if (word & 0x9F000000) == 0x10000000:    # adr
        imm = ((word >> 5) & 0x7FFFF) << 2 | ((word >> 29) & 3)
        if imm & (1 << 20):
            imm -= 1 << 21
        return "adr", word & 31, pc + imm, None
    if (word & 0x9F000000) == 0x90000000:    # adrp
        imm = ((word >> 5) & 0x7FFFF) << 2 | ((word >> 29) & 3)
        if imm & (1 << 20):
            imm -= 1 << 21
        return "adrp", word & 31, (pc & ~0xFFF) + (imm << 12), None
    if (word & 0x3B000000) == 0x18000000 and not (word >> 26) & 1:  # ldr (literal), GPR
        opc = word >> 30
        imm = (word >> 5) & 0x7FFFF
        if imm & (1 << 18):
            imm -= 1 << 19
        kind = {0: ("ldr", 32, False), 1: ("ldr", 64, False), 2: ("ldrsw", 32, True)}.get(opc)
        if kind is None:
            return None  # prfm literal
        return "ldrlit", word & 31, pc + (imm << 2), kind
    return None


def br(rn):
    return 0xD61F0000 | (rn << 5)


def adr_pair(rd, src, target):
    """adrp+add materializing an exact address (any 4 GB-reachable target)."""
    return [adrp(rd, src, target), add_imm(rd, rd, target & 0xFFF)]


def cond_branch_target(word, pc):
    """Target of cbz/cbnz (imm19) or tbz/tbnz (imm14) at pc."""
    if (word & 0x7E000000) == 0x34000000:
        imm, bits = (word >> 5) & 0x7FFFF, 19
    elif (word & 0x7E000000) == 0x36000000:
        imm, bits = (word >> 5) & 0x3FFF, 14
    else:
        raise ValueError(f"not a cbz/tbz: {word:#010x}")
    if imm & (1 << (bits - 1)):
        imm -= 1 << bits
    return pc + (imm << 2)


def adr(rd, src, target):
    off = target - src
    if not -(1 << 20) <= off < (1 << 20):
        raise ValueError("adr out of range")
    return 0x10000000 | ((off & 3) << 29) | (((off >> 2) & 0x7FFFF) << 5) | rd
