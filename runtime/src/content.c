// Read the game's RomFS straight from the owner's XCI dump: no extraction step.
// XCI -> root HFS0 -> "secure" HFS0 -> program NCA (header: AES-XTS with header_key)
// -> RomFS section (IVFC level 5) decrypted with AES-CTR on every read.
// Keys come from the user's prod.keys. Layouts per switchbrew / hactool.
#include <CommonCrypto/CommonCryptor.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "nxrt.h"

typedef struct NcaCtx {
    uint64_t nca_off;               // NCA offset in the XCI
    uint64_t romfs_off;             // RomFS data offset within the NCA (section + IVFC level 5)
    uint64_t romfs_size;
    uint8_t ctr_hi[8];              // upper half of the AES-CTR counter
    uint8_t ctr_key[16];
    int plain_fd;                   // > 0: an unencrypted RomFS image (NXRT_ROMFS), read as is
} NcaCtx;

static int g_fd = -1;
static NcaCtx g_prog;               // the game's program NCA
static uint64_t g_root_hfs0;
static uint8_t g_header_key[32];
static char g_keys_path[1024];

// ---- keys --------------------------------------------------------------------------

static int hexval(char c) {
    return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
}

static int load_key(const char *path, const char *name, uint8_t *out, size_t len) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char line[512];
    int found = -1;
    size_t nl = strlen(name);
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, name, nl) || (line[nl] != ' ' && line[nl] != '=')) continue;
        char *p = strchr(line, '=');
        if (!p) continue;
        p++;
        while (*p == ' ') p++;
        size_t i = 0;
        for (; i < len && hexval(p[2 * i]) >= 0 && hexval(p[2 * i + 1]) >= 0; i++)
            out[i] = (uint8_t)(hexval(p[2 * i]) << 4 | hexval(p[2 * i + 1]));
        found = i == len ? 0 : -1;
        break;
    }
    fclose(f);
    return found;
}

// ---- crypto ------------------------------------------------------------------------

static void aes_ecb(int decrypt, const uint8_t *key, const uint8_t *in, uint8_t *out, size_t n) {
    size_t moved;
    CCCrypt(decrypt ? kCCDecrypt : kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode, key, 16, NULL, in, n, out, n, &moved);
}

// Nintendo's XTS: 0x200-byte sectors, tweak = sector number big-endian.
static void aes_xts_decrypt(const uint8_t *key32, uint8_t *buf, size_t size, uint64_t sector) {
    for (size_t s = 0; s < size; s += 0x200, sector++) {
        uint8_t tweak[16] = {0}, t[16];
        for (int i = 0; i < 8; i++) tweak[15 - i] = (uint8_t)(sector >> (8 * i));
        aes_ecb(0, key32 + 16, tweak, t, 16);
        for (size_t b = 0; b < 0x200; b += 16) {
            uint8_t x[16];
            for (int i = 0; i < 16; i++) x[i] = buf[s + b + i] ^ t[i];
            aes_ecb(1, key32, x, x, 16);
            for (int i = 0; i < 16; i++) buf[s + b + i] = x[i] ^ t[i];
            int carry = t[15] >> 7;                       // t *= alpha (little-endian GF(2^128))
            for (int i = 15; i > 0; i--) t[i] = (uint8_t)(t[i] << 1 | t[i - 1] >> 7);
            t[0] = (uint8_t)(t[0] << 1) ^ (carry ? 0x87 : 0);
        }
    }
}

static void aes_ctr_decrypt(const NcaCtx *c_, uint8_t *buf, size_t n, uint64_t nca_offset) {
    uint8_t iv[16];
    memcpy(iv, c_->ctr_hi, 8);
    uint64_t block = nca_offset >> 4;
    for (int i = 0; i < 8; i++) iv[15 - i] = (uint8_t)(block >> (8 * i));
    CCCryptorRef c;
    CCCryptorCreateWithMode(kCCDecrypt, kCCModeCTR, kCCAlgorithmAES, ccNoPadding, iv, c_->ctr_key, 16, NULL, 0, 0,
                            kCCModeOptionCTR_BE, &c);
    size_t moved;
    CCCryptorUpdate(c, buf, n, buf, n, &moved);
    CCCryptorRelease(c);
}

// ---- containers --------------------------------------------------------------------

static int pread_all(void *buf, size_t n, uint64_t off) { return pread(g_fd, buf, n, (off_t)off) == (ssize_t)n ? 0 : -1; }

// Find `name` in the HFS0 at `off`; returns the file's absolute offset (and size).
static uint64_t hfs0_find(uint64_t off, const char *name, uint64_t *size, int index, char *out_name) {
    uint8_t hdr[16];
    pread_all(hdr, 16, off);
    if (memcmp(hdr, "HFS0", 4)) nx_fatal("content: no HFS0 at %#llx", (unsigned long long)off);
    uint32_t n, strsz;
    memcpy(&n, hdr + 4, 4);
    memcpy(&strsz, hdr + 8, 4);
    size_t tsize = 16 + (size_t)n * 0x40 + strsz;
    uint8_t *t = malloc(tsize);
    pread_all(t, tsize, off);
    const char *strtab = (const char *)t + 16 + n * 0x40;
    uint64_t result = 0;
    for (uint32_t i = 0; i < n; i++) {
        uint8_t *e = t + 16 + i * 0x40;
        uint64_t foff, fsz;
        uint32_t noff;
        memcpy(&foff, e, 8);
        memcpy(&fsz, e + 8, 8);
        memcpy(&noff, e + 16, 4);
        if ((name && !strcmp(strtab + noff, name)) || (!name && (int)i == index)) {
            result = off + tsize + foff;
            *size = fsz;
            if (out_name) strcpy(out_name, strtab + noff);
            break;
        }
    }
    free(t);
    return result;
}

static int ctx_read(const NcaCtx *c, uint64_t off, void *dst, size_t n) {
    if (off >= c->romfs_size) return -1;
    if (off + n > c->romfs_size) n = c->romfs_size - off;
    if (c->plain_fd > 0) return pread(c->plain_fd, dst, n, (off_t)off) == (ssize_t)n ? 0 : -1;
    uint64_t nca = c->romfs_off + off;
    uint64_t start = nca & ~15ull, end = (nca + n + 15) & ~15ull;
    uint8_t stack[0x10000], *buf = end - start <= sizeof stack ? stack : malloc(end - start);
    if (pread_all(buf, end - start, c->nca_off + start)) return -1;
    aes_ctr_decrypt(c, buf, end - start, start);
    memcpy(dst, buf + (nca - start), n);
    if (buf != stack) free(buf);
    return 0;
}

// Decrypt an NCA header at `off`; if it has a RomFS section, fill `c`. Returns content
// type (or -1) and the program id.
static int nca_setup(uint64_t off, NcaCtx *c, uint64_t *program_id, int need_romfs) {
    uint8_t h[0xC00];
    pread_all(h, sizeof h, off);
    aes_xts_decrypt(g_header_key, h, sizeof h, 0);
    if (memcmp(h + 0x200, "NCA3", 4)) return -1;
    memcpy(program_id, h + 0x210, 8);
    int type = h[0x205];
    if (!need_romfs) return type;
    uint8_t rights[16] = {0};
    if (memcmp(h + 0x230, rights, 16)) return -1;          // title-key NCAs: not needed here
    int gen = h[0x206] > h[0x220] ? h[0x206] : h[0x220];
    int rev = gen ? gen - 1 : 0;
    static const char *const kind[] = {"application", "ocean", "system"};
    if (h[0x207] > 2) return -1;
    char kname[64];
    snprintf(kname, sizeof kname, "key_area_key_%s_%02x", kind[h[0x207]], rev);
    uint8_t kaek[16], keys[64];
    if (load_key(g_keys_path, kname, kaek, 16)) nx_fatal("content: %s missing", kname);
    aes_ecb(1, kaek, h + 0x300, keys, 64);
    memcpy(c->ctr_key, keys + 0x20, 16);                  // key area slot 2: AES-CTR
    for (int s = 0; s < 4; s++) {
        uint32_t start;
        memcpy(&start, h + 0x240 + s * 16, 4);
        uint8_t *fs = h + 0x400 + s * 0x200;
        if (!start || memcmp(fs + 0x8, "IVFC", 4) || fs[0x4] != 3) continue;
        uint64_t l5_off, l5_size;
        memcpy(&l5_off, fs + 0x8 + 0x10 + 5 * 0x18, 8);
        memcpy(&l5_size, fs + 0x8 + 0x10 + 5 * 0x18 + 8, 8);
        for (int j = 0; j < 8; j++) c->ctr_hi[j] = fs[0x140 + 7 - j];
        c->nca_off = off;
        c->romfs_off = (uint64_t)start * 0x200 + l5_off;
        c->romfs_size = l5_size;
        uint64_t hsz = 0;
        ctx_read(c, 0, &hsz, 8);
        if (hsz != 0x50) return -1;                       // not a valid RomFS (wrong key?)
        return type;
    }
    return -1;
}

static void romfs_extract(void);
// NXRT_ROMFS_DUMP=<file>: the program's whole RomFS, decrypted, as a plain image (tools/texconv's input), then exit.
static void romfs_dump(const char *path) {
    FILE *f = fopen(path, "wb");
    if (!f) nx_fatal("romfs dump: cannot create %s", path);
    enum { CH = 8 << 20 };
    uint8_t *b = malloc(CH);
    for (uint64_t at = 0; at < g_prog.romfs_size; at += CH) {
        size_t n = g_prog.romfs_size - at < CH ? (size_t)(g_prog.romfs_size - at) : CH;
        if (ctx_read(&g_prog, at, b, n) || fwrite(b, 1, n, f) != n) nx_fatal("romfs dump: failed at %#llx", (unsigned long long)at);
        if (at % (512ull << 20) == 0) nx_log("romfs dump: %.1f / %.1f GiB", at / 1073741824.0, g_prog.romfs_size / 1073741824.0);
    }
    if (fclose(f)) nx_fatal("romfs dump: write error");
    nx_log("romfs dump: %s done (%llu bytes)", path, (unsigned long long)g_prog.romfs_size);
    exit(0);
}
// NXRT_ROMFS_LIST=1: every RomFS file (full path, size) to the log, then exit (asset recon).
static void romfs_list(const NcaCtx *c) {
    uint64_t hdr[10];
    ctx_read(c, 0, hdr, sizeof hdr);
    uint64_t doff = hdr[3], dsz = hdr[4], foff = hdr[7], fsz = hdr[8];   // dir meta, file meta tables
    uint8_t *dm = malloc(dsz), *fm = malloc(fsz);
    ctx_read(c, doff, dm, dsz), ctx_read(c, foff, fm, fsz);
    for (uint64_t p = 0; p + 0x20 <= fsz;) {
        uint32_t parent, nlen;
        uint64_t size;
        memcpy(&parent, fm + p, 4), memcpy(&size, fm + p + 16, 8), memcpy(&nlen, fm + p + 28, 4);
        char path[1024] = "", tmp[1024];
        for (uint32_t d = parent; d && d + 0x18 <= dsz;) {   // walk up the directories
            uint32_t dl, up;
            memcpy(&up, dm + d, 4), memcpy(&dl, dm + d + 20, 4);
            snprintf(tmp, sizeof tmp, "%.*s/%s", (int)dl, (const char *)dm + d + 24, path);
            memcpy(path, tmp, sizeof path);
            if (up == d) break;
            d = up;
        }
        nx_log("romfs: %10llu %s%.*s", (unsigned long long)size, path, (int)nlen, (const char *)fm + p + 32);
        p += (0x20 + nlen + 3) & ~3ull;
    }
    free(dm), free(fm);
    exit(0);
}
// nx_content_try: the same without exiting on failure (-1; the iOS ROM screen checks a picked file). Opening the same
// file again is a no-op (the prelauncher reads its assets before the game boots).
static int g_soft;
static char g_open_path[1024];
#define CFAIL(...) do { if (g_soft) { nx_log(__VA_ARGS__); if (g_fd >= 0) close(g_fd), g_fd = -1; return -1; } nx_fatal(__VA_ARGS__); } while (0)
int nx_content_open(const char *xci_path, const char *keys_path) {
    if (g_prog.romfs_size && !strcmp(g_open_path, xci_path)) return 0;
    snprintf(g_keys_path, sizeof g_keys_path, "%s", keys_path);
    if (load_key(keys_path, "header_key", g_header_key, 32)) CFAIL("content: header_key missing in %s", keys_path);
    if (g_fd >= 0) close(g_fd);
    memset(&g_prog, 0, sizeof g_prog), g_open_path[0] = 0;
    g_fd = open(xci_path, O_RDONLY);
    if (g_fd < 0) CFAIL("content: cannot open %s", xci_path);
    uint8_t xh[0x200];
    if (pread_all(xh, sizeof xh, 0) || memcmp(xh + 0x100, "HEAD", 4)) CFAIL("content: not an XCI");
    memcpy(&g_root_hfs0, xh + 0x130, 8);
    uint64_t sz, secure = hfs0_find(g_root_hfs0, "secure", &sz, 0, NULL);
    if (!secure) CFAIL("content: no secure partition");
    for (int i = 0; i < 64; i++) {
        char name[256];
        uint64_t nsz, off = hfs0_find(secure, NULL, &nsz, i, name), pid;
        if (!off) break;
        if (!strstr(name, ".nca") || strstr(name, ".cnmt")) continue;
        if (nca_setup(off, &g_prog, &pid, 1) == 0) {
            nx_log("content: %s (program %016llx), RomFS %.2f GiB", name, (unsigned long long)pid,
                   g_prog.romfs_size / 1073741824.0);
            if (getenv("NXRT_ROMFS_DUMP")) romfs_dump(getenv("NXRT_ROMFS_DUMP"));
            // NXRT_ROMFS=<file>: the game's RomFS from a plain image instead (tools/texconv's output: BC textures as
            // ASTC). The XCI still serves the program and system data.
            const char *rp = getenv("NXRT_ROMFS");
            if (rp && *rp) {
                int fd = open(rp, O_RDONLY);
                if (fd < 0) CFAIL("content: cannot open NXRT_ROMFS %s", rp);
                uint64_t hsz = 0;
                off_t end = lseek(fd, 0, SEEK_END);
                if (pread(fd, &hsz, 8, 0) != 8 || hsz != 0x50) CFAIL("content: %s is not a RomFS image", rp);
                g_prog.plain_fd = fd, g_prog.romfs_size = (uint64_t)end;
                nx_log("content: RomFS from %s (%.2f GiB)", rp, end / 1073741824.0);
            }
            if (getenv("NXRT_ROMFS_LIST")) romfs_list(&g_prog);
            if (getenv("NXRT_ROMFS_EXTRACT")) romfs_extract();
            snprintf(g_open_path, sizeof g_open_path, "%s", xci_path);
            return 0;
        }
    }
    CFAIL("content: no program NCA with a RomFS");
}
int nx_content_try(const char *xci_path, const char *keys_path) {
    g_soft = 1;
    int r = nx_content_open(xci_path, keys_path);
    g_soft = 0;
    return r;
}

uint64_t nx_romfs_size(void) { return g_prog.romfs_size; }
int nx_romfs_read(uint64_t off, void *dst, size_t n) { return ctx_read(&g_prog, off, dst, n); }

// ---- system data from the cartridge's bundled update partition ---------------------

static int find_system_data(uint64_t program_id, NcaCtx *c) {
    uint64_t sz, upd = hfs0_find(g_root_hfs0, "update", &sz, 0, NULL);
    if (!upd) return -1;
    for (int i = 0; i < 512; i++) {
        char name[256];
        uint64_t nsz, off = hfs0_find(upd, NULL, &nsz, i, name), pid;
        if (!off) break;
        if (!strstr(name, ".nca") || strstr(name, ".cnmt")) continue;
        NcaCtx t;
        if (nca_setup(off, &t, &pid, 0) < 0 || pid != program_id) continue;
        if (nca_setup(off, c, &pid, 1) >= 0) return 0;
    }
    return -1;
}

// RomFS file lookup by name (any directory): returns the file's offset in the RomFS.
static int romfs_find(const NcaCtx *c, const char *fname, uint64_t *off, uint64_t *size) {
    uint64_t hdr[10];
    ctx_read(c, 0, hdr, sizeof hdr);
    uint64_t fmeta_off = hdr[7], fmeta_size = hdr[8], data_off = hdr[9];
    uint8_t *meta = malloc(fmeta_size);
    ctx_read(c, fmeta_off, meta, fmeta_size);
    size_t fl = strlen(fname);
    for (uint64_t p = 0; p + 0x20 <= fmeta_size;) {
        uint64_t doff, dsize;
        uint32_t nlen;
        memcpy(&doff, meta + p + 8, 8);
        memcpy(&dsize, meta + p + 16, 8);
        memcpy(&nlen, meta + p + 28, 4);
        if (nlen == fl && !memcmp(meta + p + 32, fname, fl)) {
            *off = data_off + doff;
            *size = dsize;
            free(meta);
            return 0;
        }
        p += (0x20 + nlen + 3) & ~3ull;
    }
    free(meta);
    return -1;
}

// A whole file of the game's RomFS by file name (any directory), malloc'd; NULL if missing. Needs nx_content_open.
uint8_t *nx_romfs_file(const char *fname, uint64_t *size) {
    uint64_t off;
    if (!g_prog.romfs_size || romfs_find(&g_prog, fname, &off, size)) return NULL;
    uint8_t *buf = malloc(*size ? *size : 1);
    if (ctx_read(&g_prog, off, buf, *size)) { free(buf); return NULL; }
    return buf;
}
// NXRT_ROMFS_EXTRACT=<dir> NXRT_ROMFS_FILES=<name>,<name>...: write those RomFS files to dir, then exit (asset recon).
static void romfs_extract(void) {
    const char *dir = getenv("NXRT_ROMFS_EXTRACT"), *names = getenv("NXRT_ROMFS_FILES");
    char list[8192];
    snprintf(list, sizeof list, "%s", names ? names : "");
    for (char *save, *n = strtok_r(list, ",", &save); n; n = strtok_r(NULL, ",", &save)) {
        if (getenv("NXRT_ASSET_DUMP")) { void nx_asset_dump(const char *, const char *); nx_asset_dump(dir, n); continue; }
        uint64_t sz;
        uint8_t *d = nx_romfs_file(n, &sz);
        char path[2048];
        snprintf(path, sizeof path, "%s/%s", dir, n);
        FILE *f = d ? fopen(path, "wb") : NULL;
        if (f) fwrite(d, 1, sz, f), fclose(f);
        nx_log("romfs: extract %s: %s (%llu bytes)", n, f ? "ok" : "FAILED", (unsigned long long)(d ? sz : 0));
        free(d);
    }
    exit(0);
}

// Read a whole file out of a system data archive (malloc'd).
uint8_t *nx_system_data_file(uint64_t program_id, const char *fname, uint64_t *size) {
    NcaCtx c;
    uint64_t off;
    if (find_system_data(program_id, &c) || romfs_find(&c, fname, &off, size)) return NULL;
    uint8_t *buf = malloc(*size);
    if (ctx_read(&c, off, buf, *size)) { free(buf); return NULL; }
    return buf;
}
