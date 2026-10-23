// Tomodachi textures for the iPhone: BC -> ASTC in the game files (ported from BOTW's tools/texconv). Colour textures
// already ship as ASTC; the BC ones (BC4 masks, BC5 normal maps, ...) were decoded to RGBA8 at run time on the phone
// (gfx_bcdec.m: 244 MB of the island's 390 MB of uploaded textures), which pushed quality mode ~150 MB over the texture
// budget (eviction + re-upload churn). The runtime uploads ASTC as it is (gfx_textures.m maps NVN ASTC to Metal).
//
//   texconv census  <romfs.bin> [path substring]           BNTX textures by format
//   texconv convert <romfs.bin> <cache dir> [substring]     pass 1: every texture container, converted, into the cache
//                                                           (<file index>.bin; .none = nothing to convert); resumable
//   texconv build   <romfs.bin> <cache dir> <out.bin>       pass 2: the RomFS with the cached files
// romfs.bin: `NXRT_ROMFS_DUMP=<file> ./build/nxrt ../work` (the program NCA's RomFS, decrypted). The runtime reads the
// output with NXRT_ROMFS=<out.bin>.
//
// Conversions:
//   BC1 (8 B / 4x4)       -> ASTC 6x6 (16 B / 6x6: 3.56 bpp), or 8x5 / 8x6 / 8x8 when 6x6 does not fit BC1's space
//                            (small textures: GOB padding)
//   BC4 unorm (8 B / 4x4) -> the same, luminance (every BC4 channel mapping reads only R)
//   BC3 (16 B / 4x4)      -> ASTC 4x4 (same block grid and size)
//   BC5 unorm (16 B)      -> ASTC 4x4, normal-map mode: x in RGB, y in A; channel mapping Green -> Alpha (every BC5
//                            mapping reads only R and G)
//   BC7 (16 B)            -> ASTC 4x4
//   BC5 snorm (16 B)      -> EAC RG11 snorm, labelled BC2 (see bc5s_to_eac)
//   BC4 snorm, BC6H, 3D textures: unchanged (decoded at run time).
// The texture data keeps its place and size inside the BNTX (6x6 needs less, the rest is zero), so no offset in any
// file moves and no decompressed size changes; only the BRTI fields format, block height (textureLayout bits 0-2),
// channel mapping and mip offsets change. Layout: Tegra block-linear with the runtime's own rules
// (runtime/include/nvn_formats.h). Containers: zstd frames (re-compressed, same checksum flag, no dictionary), SARC
// (rebuilt, each file keeps the alignment its old position had). A file whose decompressed size would change is
// reported (the game's ResourceSizeTable would need it), not written. UI layout archives (.blarc) are left alone
// (kept_path).
// Memory: one RomFS file per worker (8 GB Mac).
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <math.h>
#include <zstd.h>

#define BCDEC_IMPLEMENTATION
#include "../../runtime/third_party/bcdec.h"
#include "../../runtime/include/nvn_formats.h"

int astc_encode(int thread, int kind, int bw, int bh, const uint8_t *rgba, int w, int h, uint8_t *out, size_t out_len,
                float quality);

static float g_quality = 10.0f;   // astcenc effort (ASTCENC_PRE_FAST); TEXCONV_QUALITY=<0..100>

// ---- stats ------------------------------------------------------------------------------------------------------
typedef struct { uint64_t n, bytes; } Tally;
static Tally g_fmt[256][256];   // census: [type][variant]
static Tally g_src[64];
static char g_ext[64][16];
static int g_next;
static pthread_mutex_t g_stat_lock = PTHREAD_MUTEX_INITIALIZER;
static Tally g_conv[5], g_skip_fit, g_skip_size, g_skip_other;   // converted: BC1, BC4, BC3, BC5, BC7
static uint64_t g_foot[16];   // textures per ASTC footprint (BNTX type - 0x2d)

static int ext_index(const char *path) {
    const char *b = strrchr(path, '/'), *e = strrchr(b ? b : path, '.');
    char x[16];
    snprintf(x, sizeof x, "%s", e ? e + 1 : "-");
    for (int i = 0; i < g_next; i++)
        if (!strcmp(g_ext[i], x)) return i;
    if (g_next == 63) return 63;
    snprintf(g_ext[g_next], 16, "%s", x);
    return g_next++;
}


// ---- zstd -------------------------------------------------------------------------------------------------------
static int is_zstd(const uint8_t *p, size_t n) { return n >= 6 && p[0] == 0x28 && p[1] == 0xb5 && p[2] == 0x2f && p[3] == 0xfd; }
static int g_zlevel = 19;   // TEXCONV_ZLEVEL
static uint8_t *zstd_dec(const uint8_t *s, size_t n, size_t *out_n) {
    unsigned long long dn = ZSTD_getFrameContentSize(s, n);
    if (dn == ZSTD_CONTENTSIZE_UNKNOWN || dn == ZSTD_CONTENTSIZE_ERROR || dn > (1ull << 31)) return NULL;
    if (ZSTD_getDictID_fromFrame(s, n)) return NULL;   // dictionary frames: not handled (none seen)
    uint8_t *d = malloc(dn ? dn : 1);
    size_t r = ZSTD_decompress(d, dn, s, n);
    if (ZSTD_isError(r) || r != dn) { free(d); return NULL; }
    *out_n = dn;
    return d;
}
// Same frame options as the original: content size always, checksum when it had one (header descriptor bit 2).
static uint8_t *zstd_enc(const uint8_t *s, size_t n, const uint8_t *orig, size_t *on) {
    static __thread ZSTD_CCtx *cx;
    if (!cx) cx = ZSTD_createCCtx();
    ZSTD_CCtx_reset(cx, ZSTD_reset_session_and_parameters);
    ZSTD_CCtx_setParameter(cx, ZSTD_c_compressionLevel, g_zlevel);
    ZSTD_CCtx_setParameter(cx, ZSTD_c_contentSizeFlag, 1);
    ZSTD_CCtx_setParameter(cx, ZSTD_c_checksumFlag, orig[4] >> 2 & 1);
    ZSTD_CCtx_setParameter(cx, ZSTD_c_dictIDFlag, 0);
    size_t cap = ZSTD_compressBound(n);
    uint8_t *o = malloc(cap);
    size_t r = ZSTD_compress2(cx, o, cap, s, n);
    if (ZSTD_isError(r)) { free(o); return NULL; }
    *on = r;
    return o;
}

// ---- block-linear (gfx_textures.m deswizzle / swizzle) -------------------------------------------------------------
static uint64_t bl_addr(uint32_t x_bytes, uint32_t y, uint64_t width_gobs, int gh) {
    return (uint64_t)(y / (8 * gh)) * 512 * gh * width_gobs + (uint64_t)((y % (8 * gh)) / 8) * 512 + ((y % 8) / 2) * 64 +
           (y % 2) * 16 + (uint64_t)(x_bytes / 64) * 512 * gh + ((x_bytes % 64) / 32) * 256 + ((x_bytes % 32) / 16) * 32 +
           (x_bytes % 16);
}
static void deswizzle(const uint8_t *src, uint8_t *dst, uint32_t wb, uint32_t hb, int bpb, int gh) {
    uint64_t wg = ((uint64_t)wb * bpb + 63) / 64;
    for (uint32_t y = 0; y < hb; y++)
        for (uint32_t x = 0; x < wb; x++) memcpy(dst + ((uint64_t)y * wb + x) * bpb, src + bl_addr(x * bpb, y, wg, gh), bpb);
}
static void swizzle(const uint8_t *src, uint8_t *dst, uint32_t wb, uint32_t hb, int bpb, int gh) {
    uint64_t wg = ((uint64_t)wb * bpb + 63) / 64;
    for (uint32_t y = 0; y < hb; y++)
        for (uint32_t x = 0; x < wb; x++) memcpy(dst + bl_addr(x * bpb, y, wg, gh), src + ((uint64_t)y * wb + x) * bpb, bpb);
}
// Bytes of one layer (all levels), and the offset of each level in it.
static uint64_t layer_layout(uint32_t w, uint32_t h, int levels, int bw, int bh, int bpb, int gh, uint64_t *level_off) {
    uint64_t off = 0;
    for (int l = 0; l < levels; l++) {
        uint32_t mw = w >> l ? w >> l : 1, mh = h >> l ? h >> l : 1, wb = (mw + bw - 1) / bw, hb = (mh + bh - 1) / bh;
        if (level_off) level_off[l] = off;
        off += nvn_surface_size(wb, hb, bpb, nvn_mip_gob_height(gh, hb));
    }
    return off;
}

// ---- BC5 snorm -> EAC RG11 snorm ----------------------------------------------------------------------------------
// ASTC has no signed formats, so the BC5 snorm normal maps (3 GB, 79% of the island's decoded textures) go to EAC
// RG11 snorm: also 16 B per 4x4 block, signed, native on Apple GPUs. Same block size and grid, so each block is
// transcoded where it is (no deswizzle, no layout change). BNTX has no EAC format: the texture is labelled BC2 unorm
// (0x1b01, NVN RGBA_DXT3 = 67; the game ships no BC2) and the runtime reads 67 as EAC RG11 snorm with NXRT_ROMFS
// (gfx_textures.m). Khronos EAC signed R11: byte 0 base (int8, -128 = -127), byte 1 multiplier << 4 | table,
// bytes 2-7 big-endian 16 x 3-bit indices, pixel k = x * 4 + y from the top bits; value = clamp(base * 8 +
// mod * mult * 8, +-1023) (mult 0: base * 8 + mod), / 1023. R block, then G.
static const int eac_mod[16][8] = {
    {-3, -6, -9, -15, 2, 5, 8, 14}, {-3, -7, -10, -13, 2, 6, 9, 12}, {-2, -5, -8, -13, 1, 4, 7, 12}, {-2, -4, -6, -13, 1, 3, 5, 12},
    {-3, -6, -8, -12, 2, 5, 7, 11}, {-3, -7, -9, -11, 2, 6, 8, 10}, {-4, -7, -8, -11, 3, 6, 7, 10}, {-3, -5, -8, -11, 2, 4, 7, 10},
    {-2, -6, -8, -10, 1, 5, 7, 9},  {-2, -5, -8, -10, 1, 4, 7, 9},  {-2, -4, -8, -10, 1, 3, 7, 9},  {-2, -5, -7, -10, 1, 4, 6, 9},
    {-3, -4, -7, -10, 2, 3, 6, 9},  {-1, -2, -3, -10, 0, 1, 2, 9},  {-4, -6, -8, -9, 3, 5, 7, 8},   {-3, -5, -7, -9, 2, 4, 6, 8}};
static int eac_value(int base, int mult, int table, int idx) {
    int v = mult ? base * 8 + eac_mod[table][idx] * mult * 8 : base * 8 + eac_mod[table][idx];
    return v < -1023 ? -1023 : v > 1023 ? 1023 : v;
}
// One channel: targets t[k] (pixel k = x * 4 + y) in -1023..1023 -> 8 bytes. Per table, multipliers around the one
// whose span fits the block's range (and 0 for flat blocks), bases around the one centring that span.
static void eac_encode(const float *t, uint8_t *out) {
    float lo = t[0], hi = t[0];
    for (int k = 1; k < 16; k++) lo = t[k] < lo ? t[k] : lo, hi = t[k] > hi ? t[k] : hi;
    float mid = (lo + hi) / 2, best = 1e30f;
    int bb = 0, bm = 0, bt = 0;
    for (int tb = 0; tb < 16; tb++) {
        int mn = eac_mod[tb][3], mx = eac_mod[tb][7];
        int m0 = (int)((hi - lo) / (8.0f * (mx - mn)) + 0.5f);
        const int cand[4] = {0, m0 - 1, m0, m0 + 1};
        for (int ci = 0; ci < 4; ci++) {
            int mm = cand[ci];
            if (mm < 0 || mm > 15 || (ci && mm == 0)) continue;
            float c = mm ? mid - 4.0f * mm * (mn + mx) : mid - (mn + mx) / 2.0f;
            int b0 = (int)lroundf(c / 8);
            for (int b = b0 - 1; b <= b0 + 1; b++) {
                if (b < -127 || b > 127) continue;
                int vals[8];
                for (int i = 0; i < 8; i++) vals[i] = eac_value(b, mm, tb, i);
                float err = 0;
                for (int k = 0; k < 16 && err < best; k++) {
                    float e = 1e30f;
                    for (int i = 0; i < 8; i++) {
                        float d = t[k] - vals[i];
                        e = d * d < e ? d * d : e;
                    }
                    err += e;
                }
                if (err < best) best = err, bb = b, bm = mm, bt = tb;
            }
        }
    }
    uint64_t bits = 0;
    for (int k = 0; k < 16; k++) {
        int bi = 0;
        float e = 1e30f;
        for (int i = 0; i < 8; i++) {
            float d = t[k] - eac_value(bb, bm, bt, i);
            if (d * d < e) e = d * d, bi = i;
        }
        bits |= (uint64_t)bi << (45 - 3 * k);
    }
    out[0] = (uint8_t)(int8_t)bb, out[1] = (uint8_t)(bm << 4 | bt);
    for (int i = 0; i < 6; i++) out[2 + i] = (uint8_t)(bits >> (40 - 8 * i));
}
static void eac_decode(const uint8_t *in, int *v) {   // -> v[k], pixel k = x * 4 + y (self-test)
    int base = (int8_t)in[0];
    if (base == -128) base = -127;
    uint64_t bits = 0;
    for (int i = 0; i < 6; i++) bits = bits << 8 | in[2 + i];
    for (int k = 0; k < 16; k++) v[k] = eac_value(base, in[1] >> 4, in[1] & 15, (int)(bits >> (45 - 3 * k) & 7));
}
// BC4 snorm block -> values in -1..1 at texel (x, y) = index y * 4 + x (as the runtime's GPU decoder: gfx_bcdec.m bc4s,
// but interpolated in float).
static void bc4s_decode(const uint8_t *b, float *o) {
    int a0 = (int8_t)b[0], a1 = (int8_t)b[1];
    a0 = a0 < -127 ? -127 : a0, a1 = a1 < -127 ? -127 : a1;
    uint64_t idx = 0;
    for (int i = 0; i < 6; i++) idx |= (uint64_t)b[2 + i] << (8 * i);
    for (int i = 0; i < 16; i++) {
        int s = (int)(idx >> (3 * i) & 7);
        float v = s == 0 ? a0 : s == 1 ? a1 : a0 > a1 ? ((8 - s) * a0 + (s - 1) * a1) / 7.0f
                : s == 6 ? -127 : s == 7 ? 127 : ((6 - s) * a0 + (s - 1) * a1) / 5.0f;
        o[i] = v / 127.0f;
    }
}
static Tally g_eac;
static double g_eac_err2, g_eac_n;   // squared error in 1/127 units (BC5's own step)
static void bc5s_to_eac(uint8_t *blk) {
    uint8_t out[16];
    for (int c = 0; c < 2; c++) {
        float v[16], t[16];
        bc4s_decode(blk + 8 * c, v);
        for (int y = 0; y < 4; y++)
            for (int x = 0; x < 4; x++) t[x * 4 + y] = v[y * 4 + x] * 1023.0f;
        eac_encode(t, out + 8 * c);
        int d[16];
        eac_decode(out + 8 * c, d);
        double e = 0;
        for (int k = 0; k < 16; k++) e += (d[k] - t[k]) * (d[k] - t[k]) * (127.0 * 127.0) / (1023.0 * 1023.0);
        pthread_mutex_lock(&g_stat_lock);
        g_eac_err2 += e, g_eac_n += 16;
        pthread_mutex_unlock(&g_stat_lock);
    }
    memcpy(blk, out, 16);
}

// ---- BNTX ---------------------------------------------------------------------------------------------------------
// BRTI: 0x16 mips, 0x1c format (type << 8 | variant), 0x24 w, 0x28 h, 0x2c depth, 0x30 layers, 0x34 layout (bits 0-2:
// log2 block height in GOBs), 0x50 data size, 0x58 channel mapping (bytes r g b a: 0 zero, 1 one, 2-5 R G B A),
// 0x70 -> mip offsets (u64, absolute in the BNTX).
static void bntx_census(const uint8_t *b, size_t n, int src) {
    uint32_t cnt;
    int64_t info;
    memcpy(&cnt, b + 0x24, 4), memcpy(&info, b + 0x28, 8);
    for (uint32_t i = 0; i < cnt; i++) {
        int64_t p;
        if (info + 8 * (i + 1) > (int64_t)n) return;
        memcpy(&p, b + info + 8 * i, 8);
        if (p < 0 || p + 0x78 > (int64_t)n || memcmp(b + p, "BRTI", 4)) return;
        uint32_t fmt, size;
        memcpy(&fmt, b + p + 0x1c, 4), memcpy(&size, b + p + 0x50, 4);
        Tally *t = &g_fmt[fmt >> 8 & 255][fmt & 255];
        t->n++, t->bytes += size;
        g_src[src].n++, g_src[src].bytes += size;
    }
}

// Converts one texture in place; 1 = converted.
static int brti_convert(uint8_t *b, size_t n, uint8_t *r, int thread) {
    uint32_t fmt, size, layout;
    uint16_t mips;
    int32_t w, h, depth, layers;
    int64_t ptrs;
    memcpy(&mips, r + 0x16, 2), memcpy(&fmt, r + 0x1c, 4), memcpy(&w, r + 0x24, 4), memcpy(&h, r + 0x28, 4);
    memcpy(&depth, r + 0x2c, 4), memcpy(&layers, r + 0x30, 4), memcpy(&layout, r + 0x34, 4), memcpy(&size, r + 0x50, 4);
    memcpy(&ptrs, r + 0x70, 8);
    int type = fmt >> 8 & 255, var = fmt & 255, which, kind, dbw, sbpb;
    if (type == 0x1e && var == 2) {   // BC5 snorm -> EAC RG11 snorm, block by block in place (labelled BC2)
        int64_t base;
        if (ptrs < 0 || ptrs + 8 > (int64_t)n) return 0;
        memcpy(&base, b + ptrs, 8);
        if (base < 0 || base + (int64_t)size > (int64_t)n || size % 16) return 0;
        for (uint32_t o = 0; o < size; o += 16) bc5s_to_eac(b + base + o);
        uint32_t nf = 0x1b01;
        memcpy(r + 0x1c, &nf, 4);
        pthread_mutex_lock(&g_stat_lock);
        g_eac.n++, g_eac.bytes += size;
        pthread_mutex_unlock(&g_stat_lock);
        return 1;
    }
    if (type == 0x1a && (var == 1 || var == 6)) which = 0, kind = var == 6, dbw = 6, sbpb = 8;
    else if (type == 0x1d && var == 1) which = 1, kind = 0, dbw = 6, sbpb = 8;
    else if (type == 0x1c && (var == 1 || var == 6)) which = 2, kind = var == 6, dbw = 4, sbpb = 16;
    else if (type == 0x1e && var == 1) which = 3, kind = 2, dbw = 4, sbpb = 16;
    else if (type == 0x20 && (var == 1 || var == 6)) which = 4, kind = var == 6, dbw = 4, sbpb = 16;
    else return 0;
    Tally *skip = NULL;
    if (depth > 1 || w <= 0 || h <= 0 || mips < 1 || mips > 16 || ptrs < 0 || ptrs + 8 * (int64_t)mips > (int64_t)n) {
        skip = &g_skip_other;
        goto skipped;
    }
    if (layers < 1) layers = 1;
    int64_t base;
    memcpy(&base, b + ptrs, 8);
    if (base < 0 || base + (int64_t)size > (int64_t)n) { skip = &g_skip_other; goto skipped; }
    int sgh = 1 << (layout & 7);
    uint64_t soff[16], doff[16];
    uint64_t slayer = layer_layout(w, h, mips, 4, 4, sbpb, sgh, soff);
    if (layers > 1) slayer = (slayer + 512ull * sgh - 1) / (512ull * sgh) * (512ull * sgh);
    if (slayer * layers > size) { skip = &g_skip_size; goto skipped; }
    // Footprint: the best one that fits the texture's space (8-byte BC blocks: 6x6, else 8x5 / 8x6 / 8x8; a GOB row
    // holds half as many 16-byte blocks, so up to ~256x256 6x6 needs ~10% more than BC1). Block height: the one with
    // the least padding (the BNTX carries it; the driver's pick, nvn_gob_height, pads 6x6 rows of a 512x512 up to 128).
    static const int foot[4][3] = {{6, 6, 0x31}, {8, 5, 0x32}, {8, 6, 0x33}, {8, 8, 0x34}};   // w, h, BNTX type
    int dbh = dbw, ntype = 0x2d, dgh = 0;
    uint64_t dlayer = ~0ull;
    for (int fi = 0; fi < (dbw == 4 ? 1 : 4); fi++) {
        int fw = dbw == 4 ? 4 : foot[fi][0], fh = dbw == 4 ? 4 : foot[fi][1];
        for (int g = 16; g >= 1; g >>= 1) {
            uint64_t s = layer_layout(w, h, mips, fw, fh, 16, g, NULL);
            if (layers > 1) s = (s + 512ull * g - 1) / (512ull * g) * (512ull * g);
            if (s < dlayer || (fi && dlayer * layers > size)) dlayer = s, dgh = g, dbw = fw, dbh = fh, ntype = dbw == 4 && fh == 4 ? 0x2d : foot[fi][2];
        }
        if (dlayer * layers <= size) break;
    }
    layer_layout(w, h, mips, dbw, dbh, 16, dgh, doff);
    if (dlayer * layers > size) {
        if (getenv("TEXCONV_DEBUG"))
            fprintf(stderr, "no fit: %02x %dx%d mips %d layers %d size %u src %llu dst %llu (gh %d, src gh %d)\n", type, w, h, mips,
                    layers, size, (unsigned long long)slayer, (unsigned long long)dlayer, dgh, sgh);
        skip = &g_skip_fit;
        goto skipped;
    }
    pthread_mutex_lock(&g_stat_lock);
    g_foot[ntype - 0x2d]++;
    pthread_mutex_unlock(&g_stat_lock);

    uint8_t *data = b + base, *out = calloc(size, 1);
    uint8_t *lin = malloc((size_t)((w + 3) / 4) * ((h + 3) / 4) * 16), *rgba = malloc((size_t)(w + 3) * (h + 3) * 4);
    uint8_t *astc = malloc((size_t)((w + 3) / 4 + 1) * ((h + 3) / 4 + 1) * 16);   // 4x4 is the most blocks
    for (int L = 0; L < layers; L++)
        for (int l = 0; l < mips; l++) {
            uint32_t mw = w >> l ? w >> l : 1, mh = h >> l ? h >> l : 1;
            uint32_t wb = (mw + 3) / 4, hb = (mh + 3) / 4, pw = wb * 4;
            deswizzle(data + L * slayer + soff[l], lin, wb, hb, sbpb, nvn_mip_gob_height(sgh, hb));
            // decode into a block-padded RGBA image (pw wide), then hand astcenc the real mw x mh part
            uint8_t blk[64];
            for (uint32_t by = 0; by < hb; by++)
                for (uint32_t bx = 0; bx < wb; bx++) {
                    const uint8_t *s = lin + ((size_t)by * wb + bx) * sbpb;
                    if (which == 0) bcdec_bc1(s, blk, 16);
                    else if (which == 2) bcdec_bc3(s, blk, 16);
                    else if (which == 4) bcdec_bc7(s, blk, 16);
                    else if (which == 1) {
                        uint8_t v[16];
                        bcdec_bc4(s, v, 4);
                        for (int k = 0; k < 16; k++) blk[4 * k] = blk[4 * k + 1] = blk[4 * k + 2] = v[k], blk[4 * k + 3] = 255;
                    } else {
                        uint8_t rg[32];
                        bcdec_bc5(s, rg, 8);
                        for (int k = 0; k < 16; k++)
                            blk[4 * k] = blk[4 * k + 1] = blk[4 * k + 2] = rg[2 * k], blk[4 * k + 3] = rg[2 * k + 1];
                    }
                    for (int yy = 0; yy < 4; yy++) memcpy(rgba + (((size_t)by * 4 + yy) * pw + bx * 4) * 4, blk + yy * 16, 16);
                }
            if (pw != mw)   // rows of mw texels
                for (uint32_t y = 1; y < mh; y++) memmove(rgba + (size_t)y * mw * 4, rgba + (size_t)y * pw * 4, (size_t)mw * 4);
            uint32_t dwb = (mw + dbw - 1) / dbw, dhb = (mh + dbh - 1) / dbh;
            if (astc_encode(thread, kind, dbw, dbh, rgba, mw, mh, astc, (size_t)dwb * dhb * 16, g_quality)) {
                free(out), free(lin), free(rgba), free(astc);
                skip = &g_skip_other;
                goto skipped;
            }
            swizzle(astc, out + L * dlayer + doff[l], dwb, dhb, 16, nvn_mip_gob_height(dgh, dhb));
        }
    memcpy(data, out, size);
    free(out), free(lin), free(rgba), free(astc);
    uint32_t nf = (uint32_t)ntype << 8 | (which == 0 || which == 2 || which == 4 ? (uint32_t)var : 1);
    memcpy(r + 0x1c, &nf, 4);
    int lg = 0;
    while ((1 << lg) < dgh) lg++;
    layout = (layout & ~7u) | (uint32_t)lg;
    memcpy(r + 0x34, &layout, 4);
    for (int l = 0; l < mips; l++) {
        int64_t v = base + (int64_t)doff[l];
        memcpy(b + ptrs + 8 * l, &v, 8);
    }
    if (which == 3)
        for (int c = 0; c < 4; c++)
            if (r[0x58 + c] == 3) r[0x58 + c] = 5;   // Green -> Alpha
    pthread_mutex_lock(&g_stat_lock);
    g_conv[which].n++, g_conv[which].bytes += size;
    pthread_mutex_unlock(&g_stat_lock);
    return 1;
skipped:
    pthread_mutex_lock(&g_stat_lock);
    skip->n++, skip->bytes += size;
    pthread_mutex_unlock(&g_stat_lock);
    return 0;
}

static int bntx_convert(uint8_t *b, size_t n, int thread) {
    uint32_t cnt;
    int64_t info;
    memcpy(&cnt, b + 0x24, 4), memcpy(&info, b + 0x28, 8);
    int done = 0;
    for (uint32_t i = 0; i < cnt; i++) {
        int64_t p;
        if (info < 0 || info + 8 * (i + 1) > (int64_t)n) break;
        memcpy(&p, b + info + 8 * i, 8);
        if (p < 0 || p + 0xa0 > (int64_t)n || memcmp(b + p, "BRTI", 4)) break;
        done += brti_convert(b, n, b + p, thread);
    }
    return done;
}

// ---- containers ---------------------------------------------------------------------------------------------------
typedef struct { int thread; int census_src; int census; int resized; } Job;

// Takes ownership of buf; returns the (possibly new) buffer, *changed set when anything was converted.
static uint8_t *process(uint8_t *buf, size_t *pn, const char *name, int depth, Job *j, int *changed) {
    size_t n = *pn;
    *changed = 0;
    if (depth > 8 || n < 16) return buf;
    if (is_zstd(buf, n)) {
        size_t dn;
        uint8_t *d = zstd_dec(buf, n, &dn);
        if (!d) return buf;
        size_t dn2 = dn;
        int ch;
        d = process(d, &dn2, name, depth + 1, j, &ch);
        if (!ch) { free(d); return buf; }
        if (dn2 != dn) {   // the game's ResourceSizeTable has the old size: keep the original file
            j->resized++;
            fprintf(stderr, "size changed, kept original: %s (%zu -> %zu)\n", name, dn, dn2);
            free(d);
            return buf;
        }
        size_t en;
        uint8_t *e = zstd_enc(d, dn2, buf, &en);
        free(d);
        if (!e) return buf;
        free(buf);
        *pn = en, *changed = 1;
        return e;
    }
    if (!memcmp(buf, "SARC", 4) && n >= 0x20) {
        uint16_t hl, count;
        uint32_t doff;
        memcpy(&hl, buf + 4, 2), memcpy(&doff, buf + 12, 4);
        if (hl + 12u > n) return buf;
        memcpy(&count, buf + hl + 6, 2);
        uint8_t *nodes = buf + hl + 12, *names = nodes + 16 * count + 8;
        if ((size_t)(nodes - buf) + 16ull * count > n || doff > n) return buf;
        uint8_t **nb = calloc(count ? count : 1, sizeof *nb);
        size_t *nn = calloc(count ? count : 1, sizeof *nn);
        int any = 0;
        for (int i = 0; i < count; i++) {
            uint32_t attr, s, e;
            memcpy(&attr, nodes + 16 * i + 4, 4), memcpy(&s, nodes + 16 * i + 8, 4), memcpy(&e, nodes + 16 * i + 12, 4);
            if (s > e || doff + (uint64_t)e > n) continue;
            char nm[512] = "";
            if (attr >> 24 && names + (attr & 0xffffff) * 4 < buf + n)
                snprintf(nm, sizeof nm, "%s", (const char *)names + (attr & 0xffffff) * 4);
            size_t en = e - s;
            uint8_t *eb = malloc(en ? en : 1);
            memcpy(eb, buf + doff + s, en);
            int ch;
            eb = process(eb, &en, nm, depth + 1, j, &ch);
            if (ch) nb[i] = eb, nn[i] = en, any = 1;
            else free(eb);
        }
        if (!any) { free(nb), free(nn); return buf; }
        // rebuild: files in their old order, each at the alignment its old position had (max 0x2000)
        int *ord = malloc(sizeof(int) * (count ? count : 1));
        for (int i = 0; i < count; i++) ord[i] = i;
        for (int i = 1; i < count; i++)   // insertion sort by old start
            for (int k = i; k > 0; k--) {
                uint32_t a, c;
                memcpy(&a, nodes + 16 * ord[k - 1] + 8, 4), memcpy(&c, nodes + 16 * ord[k] + 8, 4);
                if (a <= c) break;
                int t = ord[k]; ord[k] = ord[k - 1], ord[k - 1] = t;
            }
        size_t cap = doff + 0x2000;
        for (int i = 0; i < count; i++) {
            uint32_t s, e;
            memcpy(&s, nodes + 16 * i + 8, 4), memcpy(&e, nodes + 16 * i + 12, 4);
            cap += (nb[i] ? nn[i] : e - s) + 0x2000;
        }
        uint8_t *o = calloc(cap, 1);
        memcpy(o, buf, doff);
        uint8_t *onodes = o + hl + 12;
        size_t pos = doff;
        for (int k = 0; k < count; k++) {
            int i = ord[k];
            uint32_t s, e;
            memcpy(&s, nodes + 16 * i + 8, 4), memcpy(&e, nodes + 16 * i + 12, 4);
            uint64_t abs_old = doff + (uint64_t)s, al = abs_old ? abs_old & -abs_old : 0x2000;
            if (al > 0x2000) al = 0x2000;
            pos = (pos + al - 1) & ~(al - 1);
            size_t len = nb[i] ? nn[i] : e - s;
            memcpy(o + pos, nb[i] ? nb[i] : buf + doff + s, len);
            uint32_t ns = (uint32_t)(pos - doff), ne = (uint32_t)(pos - doff + len);
            memcpy(onodes + 16 * i + 8, &ns, 4), memcpy(onodes + 16 * i + 12, &ne, 4);
            pos += len;
            free(nb[i]);
        }
        uint32_t total = (uint32_t)pos;
        memcpy(o + 8, &total, 4);
        free(nb), free(nn), free(ord), free(buf);
        *pn = pos, *changed = 1;
        return o;
    }
    // FRES / BNTX / anything else: embedded BNTX
    int done = 0;
    for (size_t o = 0; o + 0x40 <= n; o += 8)
        if (!memcmp(buf + o, "BNTX", 4) && !memcmp(buf + o + 0x20, "NX  ", 4)) {
            uint32_t sz;
            memcpy(&sz, buf + o + 0x1c, 4);
            size_t len = sz && o + sz <= n ? sz : n - o;
            if (j->census) bntx_census(buf + o, len, j->census_src);
            else done += bntx_convert(buf + o, len, j->thread);
            if (sz) o += (sz - 8) & ~7ull;
        }
    *changed = done > 0;
    return buf;
}

// ---- RomFS --------------------------------------------------------------------------------------------------------
typedef struct { char path[512]; uint64_t off, size, meta_at; } RFile;
typedef struct { uint64_t h[10]; uint8_t *dh, *dm, *fh, *fm; RFile *files; int nfiles; } RomFS;

static void read_at(int fd, void *p, size_t n, uint64_t off) {
    size_t got = 0;
    while (got < n) {
        ssize_t r = pread(fd, (uint8_t *)p + got, n - got, (off_t)(off + got));
        if (r <= 0) { perror("pread"); exit(1); }
        got += (size_t)r;
    }
}
static void romfs_open(int fd, RomFS *r) {
    read_at(fd, r->h, 0x50, 0);
    uint8_t **t[4] = {&r->dh, &r->dm, &r->fh, &r->fm};
    for (int i = 0; i < 4; i++) *t[i] = malloc(r->h[2 + 2 * i]), read_at(fd, *t[i], r->h[2 + 2 * i], r->h[1 + 2 * i]);
    uint64_t dms = r->h[4], fms = r->h[8];
    int cap = 1024;
    r->files = malloc(sizeof(RFile) * cap), r->nfiles = 0;
    for (uint64_t p = 0; p + 0x20 <= fms;) {
        uint32_t parent, nl;
        uint64_t off, size;
        memcpy(&parent, r->fm + p, 4), memcpy(&off, r->fm + p + 8, 8), memcpy(&size, r->fm + p + 16, 8), memcpy(&nl, r->fm + p + 28, 4);
        char path[512] = "", tmp[512];
        for (uint32_t d = parent; d && d + 0x18 <= dms;) {
            uint32_t up, dl;
            memcpy(&up, r->dm + d, 4), memcpy(&dl, r->dm + d + 20, 4);
            snprintf(tmp, sizeof tmp, "%.*s%s%s", (int)dl, r->dm + d + 24, path[0] ? "/" : "", path);
            memcpy(path, tmp, sizeof path);
            if (up == d) break;
            d = up;
        }
        if (r->nfiles == cap) r->files = realloc(r->files, sizeof(RFile) * (cap *= 2));
        RFile *f = &r->files[r->nfiles++];
        snprintf(f->path, sizeof f->path, "%s%s%.*s", path, path[0] ? "/" : "", (int)nl, r->fm + p + 32);
        f->off = off, f->size = size, f->meta_at = p;
        p += (0x20 + nl + 3) & ~3ull;
    }
}

// UI layout archives (.blarc) stay as they are: the launcher / island screens decode their textures on the CPU
// (nx_assets.m: BC4 = white with the channel as alpha, ASTC 4x4 only), and they are small next to the 3D textures.
static int kept_path(const char *path) { return strstr(path, ".blarc.") != NULL; }
static int candidate(int fd, const RomFS *r, const RFile *f) {
    if (f->size < 16 || kept_path(f->path)) return 0;
    char m[4];
    read_at(fd, m, 4, r->h[9] + f->off);
    return is_zstd((const uint8_t *)m, 6) || !memcmp(m, "SARC", 4) || !memcmp(m, "FRES", 4) || !memcmp(m, "BNTX", 4);
}

// ---- pass 1 -------------------------------------------------------------------------------------------------------
static struct { int fd; RomFS r; const char *cache, *filter; int next, done, nconv, resized; uint64_t in_bytes, out_bytes; } P;
static pthread_mutex_t g_q = PTHREAD_MUTEX_INITIALIZER;

static void *worker(void *arg) {
    int thread = (int)(intptr_t)arg;
    for (;;) {
        pthread_mutex_lock(&g_q);
        int i = P.next++;
        pthread_mutex_unlock(&g_q);
        if (i >= P.r.nfiles) return NULL;
        RFile *f = &P.r.files[i];
        if (P.filter && !strstr(f->path, P.filter)) continue;
        char bin[1024], none[1024], tmp[1024];
        snprintf(bin, sizeof bin, "%s/%d.bin", P.cache, i), snprintf(none, sizeof none, "%s/%d.none", P.cache, i);
        if (!access(bin, F_OK) || !access(none, F_OK) || !candidate(P.fd, &P.r, f)) continue;
        uint8_t *b = malloc(f->size);
        read_at(P.fd, b, f->size, P.r.h[9] + f->off);
        size_t n = f->size;
        Job j = {thread, 0, 0, 0};
        int ch;
        int was_zstd = is_zstd(b, n);
        b = process(b, &n, f->path, 0, &j, &ch);
        if (ch && !was_zstd && n != f->size) {   // a bare SARC that grew: the size table has the old size
            fprintf(stderr, "size changed, kept original: %s (%llu -> %zu)\n", f->path, (unsigned long long)f->size, n);
            j.resized++, ch = 0;
        }
        if (ch) {
            snprintf(tmp, sizeof tmp, "%s.tmp", bin);
            FILE *o = fopen(tmp, "wb");
            if (!o || fwrite(b, 1, n, o) != n || fclose(o)) { perror(tmp); exit(1); }
            rename(tmp, bin);
        } else close(open(none, O_CREAT | O_WRONLY, 0644));
        free(b);
        pthread_mutex_lock(&g_q);
        P.done++, P.nconv += ch, P.resized += j.resized, P.in_bytes += f->size, P.out_bytes += ch ? n : f->size;
        if (P.done % 200 == 0)
            fprintf(stderr, "  %d files (%d converted), %.0f -> %.0f MB, at %s\n", P.done, P.nconv, P.in_bytes / 1048576.0,
                    P.out_bytes / 1048576.0, f->path);
        pthread_mutex_unlock(&g_q);
    }
}

// ---- pass 2 -------------------------------------------------------------------------------------------------------
static int by_offset(void *ctx, const void *a, const void *b) {
    const RomFS *r = ctx;
    uint64_t x = r->files[*(const int *)a].off, y = r->files[*(const int *)b].off;
    return x < y ? -1 : x > y;
}
static int build(const char *in, const char *cache, const char *out) {
    int fd = open(in, O_RDONLY);
    if (fd < 0) return perror(in), 1;
    RomFS r;
    romfs_open(fd, &r);
    FILE *o = fopen(out, "wb");
    if (!o) return perror(out), 1;
    uint64_t data = r.h[9];
    uint8_t *head = calloc(data, 1);
    read_at(fd, head, data, 0);
    fwrite(head, 1, data, o);
    // files in their old data order
    int *ord = malloc(sizeof(int) * r.nfiles);
    for (int i = 0; i < r.nfiles; i++) ord[i] = i;
    qsort_r(ord, r.nfiles, sizeof *ord, &r, by_offset);
    uint64_t pos = 0;
    size_t bufcap = 8 << 20;
    uint8_t *buf = malloc(bufcap);
    int replaced = 0;
    for (int k = 0; k < r.nfiles; k++) {
        int i = ord[k];
        RFile *f = &r.files[i];
        uint64_t al = (pos + 15) & ~15ull;
        static const uint8_t z[16];
        fwrite(z, 1, al - pos, o), pos = al;
        char bin[1024];
        snprintf(bin, sizeof bin, "%s/%d.bin", cache, i);
        uint64_t size;
        struct stat st;
        if (!kept_path(f->path) && !stat(bin, &st)) {
            FILE *c = fopen(bin, "rb");
            size = (uint64_t)st.st_size;
            for (uint64_t left = size; left;) {
                size_t m = left < bufcap ? left : bufcap;
                if (fread(buf, 1, m, c) != m) { perror(bin); exit(1); }
                fwrite(buf, 1, m, o), left -= m;
            }
            fclose(c), replaced++;
        } else {
            size = f->size;
            for (uint64_t left = size, at = data + f->off; left;) {
                size_t m = left < bufcap ? left : bufcap;
                read_at(fd, buf, m, at);
                fwrite(buf, 1, m, o), left -= m, at += m;
            }
        }
        memcpy(r.fm + f->meta_at + 8, &pos, 8), memcpy(r.fm + f->meta_at + 16, &size, 8);
        pos += size;
    }
    // tables after the data, as in the original: dir hash, dir meta, file hash, file meta
    uint64_t at = data + pos;
    uint8_t *t[4] = {r.dh, r.dm, r.fh, r.fm};
    for (int i = 0; i < 4; i++) {
        uint64_t al = (at + 3) & ~3ull;
        static const uint8_t z[4];
        fwrite(z, 1, al - at, o), at = al;
        r.h[1 + 2 * i] = at;
        fwrite(t[i], 1, r.h[2 + 2 * i], o), at += r.h[2 + 2 * i];
    }
    fseeko(o, 0, SEEK_SET);
    fwrite(r.h, 8, 10, o);
    if (fclose(o)) return perror(out), 1;
    fprintf(stderr, "%s: %d files replaced, %.2f GiB\n", out, replaced, at / 1073741824.0);
    return 0;
}

static const char *fmt_name(int t) {
    switch (t) {
    case 0x1a: return "BC1"; case 0x1b: return "BC2"; case 0x1c: return "BC3"; case 0x1d: return "BC4";
    case 0x1e: return "BC5"; case 0x1f: return "BC6H"; case 0x20: return "BC7";
    case 0x02: return "R8"; case 0x07: return "R5G6B5"; case 0x09: return "R8G8"; case 0x0b: return "RGBA8";
    case 0x0c: return "BGRA8"; case 0x12: return "RGBA16F";
    default: return t >= 0x2d && t <= 0x3a ? "ASTC" : "?";
    }
}

int main(int argc, char **argv) {
    if (getenv("TEXCONV_QUALITY")) g_quality = (float)atof(getenv("TEXCONV_QUALITY"));
    if (getenv("TEXCONV_ZLEVEL")) g_zlevel = atoi(getenv("TEXCONV_ZLEVEL"));
    if (argc >= 3 && !strcmp(argv[1], "census")) {
        int fd = open(argv[2], O_RDONLY);
        if (fd < 0) return perror(argv[2]), 1;
        RomFS r;
        romfs_open(fd, &r);
        for (int i = 0; i < r.nfiles; i++) {
            RFile *f = &r.files[i];
            if ((argc > 3 && !strstr(f->path, argv[3])) || !candidate(fd, &r, f)) continue;
            uint8_t *b = malloc(f->size);
            read_at(fd, b, f->size, r.h[9] + f->off);
            size_t n = f->size;
            Job j = {0, ext_index(f->path), 1, 0};
            int ch;
            free(process(b, &n, f->path, 0, &j, &ch));
        }
        printf("by format (type.variant: 1 unorm, 2 snorm, 6 srgb):\n");
        for (int t = 0; t < 256; t++)
            for (int v = 0; v < 256; v++)
                if (g_fmt[t][v].n)
                    printf("  %-7s %02x.%02x %7llu textures %8.1f MB\n", fmt_name(t), t, v, (unsigned long long)g_fmt[t][v].n,
                           g_fmt[t][v].bytes / 1048576.0);
        printf("by RomFS file type:\n");
        for (int i = 0; i < g_next; i++)
            if (g_src[i].n) printf("  %-14s %7llu textures %8.1f MB\n", g_ext[i], (unsigned long long)g_src[i].n, g_src[i].bytes / 1048576.0);
        return 0;
    }
    if (argc >= 4 && !strcmp(argv[1], "convert")) {
        P.fd = open(argv[2], O_RDONLY);
        if (P.fd < 0) return perror(argv[2]), 1;
        romfs_open(P.fd, &P.r);
        P.cache = argv[3], P.filter = argc > 4 ? argv[4] : NULL;
        mkdir(P.cache, 0755);
        int nt = getenv("TEXCONV_THREADS") ? atoi(getenv("TEXCONV_THREADS")) : 6;
        pthread_t th[32];
        for (int i = 0; i < nt && i < 32; i++) pthread_create(&th[i], NULL, worker, (void *)(intptr_t)i);
        for (int i = 0; i < nt && i < 32; i++) pthread_join(th[i], NULL);
        static const char *nm[5] = {"BC1 -> ASTC 6x6", "BC4 -> ASTC 6x6", "BC3 -> ASTC 4x4", "BC5 -> ASTC 4x4", "BC7 -> ASTC 4x4"};
        for (int i = 0; i < 5; i++)
            fprintf(stderr, "%s: %llu textures, %.1f MB\n", nm[i], (unsigned long long)g_conv[i].n, g_conv[i].bytes / 1048576.0);
        fprintf(stderr, "BC5 snorm -> EAC RG11 snorm: %llu textures, %.1f MB, RMS error %.3f BC5 steps\n", (unsigned long long)g_eac.n,
                g_eac.bytes / 1048576.0, g_eac_n ? sqrt(g_eac_err2 / g_eac_n) : 0.0);
        fprintf(stderr, "footprints: 4x4 %llu, 6x6 %llu, 8x5 %llu, 8x6 %llu, 8x8 %llu\n", (unsigned long long)g_foot[0],
                (unsigned long long)g_foot[4], (unsigned long long)g_foot[5], (unsigned long long)g_foot[6], (unsigned long long)g_foot[7]);
        fprintf(stderr, "skipped: %llu don't fit (%.1f MB), %llu size mismatch (%.1f MB), %llu other (%.1f MB)\n",
                (unsigned long long)g_skip_fit.n, g_skip_fit.bytes / 1048576.0, (unsigned long long)g_skip_size.n,
                g_skip_size.bytes / 1048576.0, (unsigned long long)g_skip_other.n, g_skip_other.bytes / 1048576.0);
        fprintf(stderr, "this run: %d files, %d converted, %.0f -> %.0f MB; %d containers kept (size would change)\n", P.done,
                P.nconv, P.in_bytes / 1048576.0, P.out_bytes / 1048576.0, P.resized);
        return 0;
    }
    if (argc >= 5 && !strcmp(argv[1], "build")) return build(argv[2], argv[3], argv[4]);
    if (argc >= 4 && !strcmp(argv[1], "eactest")) {   // eactest <n blocks> <out>: random BC5 snorm blocks for a Metal check
        int nb = atoi(argv[2]);
        FILE *o = fopen(argv[3], "wb");
        srand(1);
        fwrite(&nb, 4, 1, o);
        for (int i = 0; i < nb; i++) {
            uint8_t bc[16], eac[16];
            for (int k = 0; k < 16; k++) bc[k] = (uint8_t)rand();
            if (i % 4 == 1) bc[1] = bc[0] + 3, bc[9] = bc[8] - 2;   // some near-flat blocks
            memcpy(eac, bc, 16);
            bc5s_to_eac(eac);
            float mine[32];
            int dec[32];
            for (int c = 0; c < 2; c++) {
                float v[16];
                int d[16];
                bc4s_decode(bc + 8 * c, v), eac_decode(eac + 8 * c, d);
                for (int y = 0; y < 4; y++)
                    for (int x = 0; x < 4; x++) mine[(y * 4 + x) * 2 + c] = v[y * 4 + x], dec[(y * 4 + x) * 2 + c] = d[x * 4 + y];
            }
            fwrite(bc, 1, 16, o), fwrite(eac, 1, 16, o), fwrite(mine, 4, 32, o), fwrite(dec, 4, 32, o);
        }
        fclose(o);
        fprintf(stderr, "RMS error %.3f BC5 steps\n", sqrt(g_eac_err2 / g_eac_n));
        return 0;
    }
    fprintf(stderr, "usage: texconv census <romfs.bin> [substring]\n"
                    "       texconv convert <romfs.bin> <cache dir> [substring]\n"
                    "       texconv build <romfs.bin> <cache dir> <out.bin>\n");
    return 1;
}
