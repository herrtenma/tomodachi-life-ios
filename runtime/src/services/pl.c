// pl:u — system shared fonts. Read from the firmware system data bundled in the XCI's
// update partition, decrypted into shared memory in the layout the SDK expects
// (per font: 7f 9a 02 18, BE(size ^ key), then the TTF). Format per yuzu's pl_u.cpp.
#include <TargetConditionals.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ipc.h"

#define FONT_SHM_SIZE 0x1100000
#define EXPECTED_RESULT 0x7f9a0218u   // decrypted first word
#define EXPECTED_MAGIC 0x36f81a1eu    // encrypted first word

static const struct { uint64_t archive; const char *file; } g_fonts[] = {
    {0x0100000000000811ull, "nintendo_udsg-r_std_003.bfttf"},        // 0 JapanUSEurope
    {0x0100000000000814ull, "nintendo_udsg-r_org_zh-cn_003.bfttf"},  // 1 ChineseSimplified
    {0x0100000000000814ull, "nintendo_udsg-r_ext_zh-cn_003.bfttf"},  // 2 ExtChineseSimplified
    {0x0100000000000813ull, "nintendo_udjxh-db_zh-tw_003.bfttf"},    // 3 ChineseTraditional
    {0x0100000000000812ull, "nintendo_udsg-r_ko_003.bfttf"},         // 4 Korean
    {0x0100000000000810ull, "nintendo_ext_003.bfttf"},               // 5 NintendoExtended
    {0x0100000000000810ull, "nintendo_ext2_003.bfttf"},              // 6 (second extension font)
};
enum { NFONTS = sizeof g_fonts / sizeof *g_fonts };

static KShmem *g_shm;
static uint32_t g_shm_handle;
static uint32_t g_off[NFONTS], g_size[NFONTS];

static uint32_t swap32(uint32_t v) { return __builtin_bswap32(v); }

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static uint16_t be16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
int nx_hide_button_glyphs(void) {
    static int hide = -1;
    if (hide < 0) {
#if TARGET_OS_IPHONE
        hide = 1;
#else
        hide = 0;
#endif
        if (getenv("NXRT_HIDEBUTTONGLYPHS")) hide = atoi(getenv("NXRT_HIDEBUTTONGLYPHS")) != 0;
    }
    return hide;
}
// The A/B/X/Y button symbols of the extended fonts (U+E0A0-E0A3 outlined, U+E0E0-E0E3 filled) become empty glyphs
// (no contours; advance unchanged, so the cue next to them, "Back", "Drop", ..., stays put). On the phone the prompts
// are tapped (ui_touch.c finds them by the characters, which are unchanged). NXRT_HIDEBUTTONGLYPHS=0/1 (iOS default 1).
int nx_blank_button_glyphs(uint8_t *f, size_t n) {
    if (n < 12) return 0;
    unsigned nt = be16(f + 4);
    const uint8_t *cmap = NULL, *head = NULL, *loca = NULL;
    uint8_t *glyf = NULL;
    size_t glyf_len = 0, loca_len = 0;
    for (unsigned i = 0; i < nt && 12 + 16 * i + 16 <= n; i++) {
        const uint8_t *r = f + 12 + 16 * i;
        uint32_t off = be32(r + 8), len = be32(r + 12);
        if (off + len > n) continue;
        if (!memcmp(r, "cmap", 4)) cmap = f + off;
        else if (!memcmp(r, "head", 4)) head = f + off;
        else if (!memcmp(r, "loca", 4)) loca = f + off, loca_len = len;
        else if (!memcmp(r, "glyf", 4)) glyf = f + off, glyf_len = len;
    }
    if (!cmap || !head || !loca || !glyf) return 0;
    const uint8_t *sub = NULL;   // format 4, Windows Unicode BMP (3, 1)
    for (unsigned i = 0, k = be16(cmap + 2); i < k; i++) {
        const uint8_t *e = cmap + 4 + 8 * i;
        if (be16(e) == 3 && be16(e + 2) == 1 && be16(cmap + be32(e + 4)) == 4) sub = cmap + be32(e + 4);
    }
    if (!sub) return 0;
    unsigned seg2 = be16(sub + 6), longloca = be16(head + 50) != 0, done = 0;
    const uint8_t *ends = sub + 14, *starts = ends + seg2 + 2, *deltas = starts + seg2, *ranges = deltas + seg2;
    static const uint16_t cps[] = {0xE0A0, 0xE0A1, 0xE0A2, 0xE0A3, 0xE0E0, 0xE0E1, 0xE0E2, 0xE0E3};
    for (unsigned c = 0; c < sizeof cps / sizeof *cps; c++) {
        unsigned cp = cps[c], g = 0;
        for (unsigned i = 0; i < seg2 / 2; i++) {
            if (cp > be16(ends + 2 * i) || cp < be16(starts + 2 * i)) continue;
            unsigned ro = be16(ranges + 2 * i);
            if (!ro) g = (cp + be16(deltas + 2 * i)) & 0xffff;
            else {
                const uint8_t *gp = ranges + 2 * i + ro + 2 * (cp - be16(starts + 2 * i));
                g = be16(gp);
                if (g) g = (g + be16(deltas + 2 * i)) & 0xffff;
            }
            break;
        }
        if (!g) continue;
        uint32_t a = longloca ? be32(loca + 4 * g) : 2u * be16(loca + 2 * g), b = longloca ? be32(loca + 4 * g + 4) : 2u * be16(loca + 2 * g + 2);
        if ((longloca ? 4 * g + 8 : 2 * g + 4) > loca_len || b > glyf_len || b < a + 12) continue;
        memset(glyf + a, 0, 12);   // numberOfContours 0, empty bounds, no instructions
        done++;
    }
    return (int)done;
}

static void load_fonts(void) {
    if (g_shm) return;
    g_shm = nx_shmem_new(FONT_SHM_SIZE, &g_shm_handle);
    size_t at = 0;
    for (int i = 0; i < NFONTS; i++) {
        uint64_t sz;
        uint8_t *f = nx_system_data_file(g_fonts[i].archive, g_fonts[i].file, &sz);
        if (!f || sz < 8 || at + sz > FONT_SHM_SIZE) {
            nx_log("pl:u: font %s not available", g_fonts[i].file);
            free(f);
            continue;
        }
        // The file is the TTF XOR-ed bytewise with 49 62 18 06; its first word decrypts to
        // 7f 9a 02 18. Shared memory holds the decrypted bytes, except word 1 (the size),
        // which stays encrypted: the SDK decrypts it with the key it derives from word 0.
        uint32_t *in = (uint32_t *)f, n = (uint32_t)(sz / 4);
        uint32_t key = in[0] ^ 0x18029a7fu;               // LE view of 7f 9a 02 18
        if (key != 0x06186249u) nx_log("pl:u: %s: unexpected key %#x", g_fonts[i].file, key);
        uint32_t *out = malloc(n * 4);
        for (uint32_t k = 0; k < n; k++) out[k] = in[k] ^ key;
        out[1] = in[1];
        nx_shmem_write(g_shm, at, out, n * 4);
        {
            int nx_hide_button_glyphs(void);
            if (nx_hide_button_glyphs() && (i == 5 || i == 6))
                nx_log("pl:u: %s: %d button glyphs blanked", g_fonts[i].file, nx_blank_button_glyphs((uint8_t *)(out + 2), swap32(in[1] ^ key)));
        }
        if (getenv("NXRT_FONTDUMP")) {   // the decrypted TTF, for font tools
            char path[1024];
            snprintf(path, sizeof path, "%s/%s.ttf", getenv("NXRT_FONTDUMP"), g_fonts[i].file);
            FILE *fo = fopen(path, "wb");
            if (fo) fwrite(out + 2, 1, (size_t)swap32(in[1] ^ key), fo), fclose(fo);
        }
        g_off[i] = (uint32_t)at + 8;
        g_size[i] = swap32(in[1] ^ key);                  // decrypted size (stored big-endian)
        at += n * 4;
        free(out);
        free(f);
    }
    nx_log("pl:u: %zu KiB of shared fonts loaded from the cartridge's system data", at / 1024);
}

static void request_load(SvcObj *o, IpcReq *rq, IpcResp *rs) { load_fonts(); }
static void load_state(SvcObj *o, IpcReq *rq, IpcResp *rs) { load_fonts(); OUT(rs, (uint32_t)1); }  // Loaded
static void get_size(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    load_fonts();
    uint32_t t = IN(uint32_t, 0);
    OUT(rs, t < NFONTS ? g_size[t] : 0);
}
static void get_offset(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    load_fonts();
    uint32_t t = IN(uint32_t, 0);
    OUT(rs, t < NFONTS ? g_off[t] : 0);
}
static void get_shm(SvcObj *o, IpcReq *rq, IpcResp *rs) { load_fonts(); ipc_push_copy(rs, g_shm_handle); }
// GetSharedFontInOrderOfPriority(language code) -> loaded flag, count; buffers:
// font types, offsets, sizes (u32 arrays in B/C buffers 0..2)
static void get_in_order(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    load_fonts();
    uint32_t n = 0;
    IpcBuf *bufs = rq->num_b ? rq->b : rq->c;
    int nb = rq->num_b ? rq->num_b : rq->num_c;
    for (int t = 0; t < 6 && nb >= 3; t++, n++) {
        if ((n + 1) * 4 > bufs[0].size) break;
        ((uint32_t *)bufs[0].addr)[n] = t;
        ((uint32_t *)bufs[1].addr)[n] = g_off[t];
        ((uint32_t *)bufs[2].addr)[n] = g_size[t];
    }
    OUT(rs, (uint8_t)1);
    uint8_t pad[3] = {0};
    ipc_push_raw(rs, pad, 3);
    OUT(rs, n);
}

static const IpcCmd cmds[] = {
    {NULL, 0, request_load},
    {NULL, 1, load_state},
    {NULL, 2, get_size},
    {NULL, 3, get_offset},
    {NULL, 4, get_shm},
    {NULL, 5, get_in_order},
    {0},
};
const ServiceDef svc_pl = {.name = "pl:u", .cmds = cmds};
