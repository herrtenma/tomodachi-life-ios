"""AArch64 disassembly via the system llvm-objdump.

Raw code is wrapped in a minimal ELF64 relocatable with a single .text section,
so llvm-objdump can decode it without any third-party packages."""
import os
import re
import struct
import subprocess
import tempfile

OBJDUMP = "/Library/Developer/CommandLineTools/usr/bin/llvm-objdump"
EM_AARCH64 = 183

_LINE = re.compile(r"^\s*([0-9a-f]+):\s+(.*)$")


def _elf_wrap(code, base):
    shstrtab = b"\0.text\0.shstrtab\0"
    ehdr_size, shdr_size = 64, 64
    text_off = ehdr_size
    shstr_off = text_off + len(code)
    sh_off = (shstr_off + len(shstrtab) + 7) & ~7
    ehdr = b"\x7fELF" + bytes([2, 1, 1, 0]) + b"\0" * 8
    ehdr += struct.pack("<HHIQQQIHHHHHH", 1, EM_AARCH64, 1, 0, 0, sh_off, 0,
                        ehdr_size, 0, 0, shdr_size, 3, 2)
    null = b"\0" * shdr_size
    # PROGBITS, ALLOC|EXEC, sh_addr=base so PC-relative operands decode to real addresses
    text = struct.pack("<IIQQQQIIQQ", 1, 1, 6, base, text_off, len(code), 0, 0, 4, 0)
    strt = struct.pack("<IIQQQQIIQQ", 7, 3, 0, 0, shstr_off, len(shstrtab), 0, 0, 1, 0)  # STRTAB
    body = ehdr + code + shstrtab
    body += b"\0" * (sh_off - len(body))
    return body + null + text + strt


def disassemble(code, base=0):
    """Yield (address, text) for every 4-byte word in `code`.
    `text` is objdump's 'mnemonic\\toperands' (or '<unknown>')."""
    with tempfile.NamedTemporaryFile(suffix=".o", delete=False) as f:
        f.write(_elf_wrap(bytes(code), base))
        path = f.name
    try:
        proc = subprocess.Popen(
            [OBJDUMP, "-d", "--no-show-raw-insn", "--mattr=+v8a,+crypto,+crc,+fp-armv8,+neon", path],
            stdout=subprocess.PIPE, text=True, bufsize=1 << 20)
        for line in proc.stdout:
            m = _LINE.match(line)
            if m:
                yield int(m.group(1), 16), m.group(2).strip()
        if proc.wait() != 0:
            raise RuntimeError(f"llvm-objdump failed with exit code {proc.returncode}")
    finally:
        os.unlink(path)


def disassemble_words(words, addrs):
    """Disassemble instruction words as if each sat at the matching address in `addrs`
    (so PC-relative operands match the original). Returns texts in order."""
    out = [None] * len(words)
    # Group consecutive addresses into runs to keep the number of objdump calls small.
    i = 0
    while i < len(words):
        j = i + 1
        while j < len(words) and addrs[j] == addrs[j - 1] + 4:
            j += 1
        code = struct.pack(f"<{j - i}I", *words[i:j])
        for addr, txt in disassemble(code, addrs[i]):
            out[i + (addr - addrs[i]) // 4] = txt
        i = j
    return out
