// The game's own UI assets on the host side (the iOS prelauncher): RomFS file -> zstd (.zs) -> SARC (.blarc / .bfarc)
// -> BNTX textures (block-linear, BC1-BC5/BC7 decoded on the CPU with bcdec, ASTC 4x4 decoded by the GPU through a
// Metal read) as CGImages, and the fonts (.bfotf / .bfttf: OpenType XORed with 0xA6018502, big-endian words, after an
// 8-byte header: magic 0x7F9A0218, size). Nothing is bundled: everything is read from the user's .xci at run time.
// NXRT_ASSET_DUMP=1 with NXRT_ROMFS_EXTRACT=<dir> NXRT_ROMFS_FILES=...: archives are unpacked into dir instead (PNGs,
// fonts), for recon on the Mac. Sound effects: BARS archives -> WAV (nx_bars_wav).
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#include "nxrt.h"
#include "../third_party/bcdec.h"

uint8_t *nx_romfs_file(const char *fname, uint64_t *size);
unsigned long long ZSTD_getFrameContentSize(const void *src, size_t srcSize);
size_t ZSTD_decompress(void *dst, size_t dstCapacity, const void *src, size_t compressedSize);
unsigned ZSTD_isError(size_t code);

// A RomFS file, zstd-decompressed when it ends in .zs (malloc'd).
uint8_t *nx_asset_file(const char *name, size_t *n) {
    uint64_t sz;
    uint8_t *raw = nx_romfs_file(name, &sz);
    if (!raw) return NULL;
    size_t l = strlen(name);
    if (l < 3 || strcmp(name + l - 3, ".zs")) { *n = sz; return raw; }
    unsigned long long out = ZSTD_getFrameContentSize(raw, sz);
    if (out == 0ULL - 1 || out == 0ULL - 2 || out > (1ull << 31)) { free(raw); return NULL; }
    uint8_t *d = malloc(out ? out : 1);
    size_t r = ZSTD_decompress(d, out, raw, sz);
    free(raw);
    if (ZSTD_isError(r)) { free(d); return NULL; }
    *n = r;
    return d;
}

// SARC: a file by name (pointer into the archive), or the i-th file (name copied out) when name is NULL.
static const uint8_t *sarc_entry(const uint8_t *b, size_t n, const char *name, int index, char *out_name, size_t *size) {
    if (n < 0x20 || memcmp(b, "SARC", 4)) return NULL;
    uint16_t hl;
    uint32_t doff;
    memcpy(&hl, b + 4, 2), memcpy(&doff, b + 12, 4);
    uint16_t count;
    memcpy(&count, b + hl + 6, 2);
    const uint8_t *nodes = b + hl + 12, *names = nodes + 16 * count + 8;
    for (int i = 0; i < count; i++) {
        uint32_t attr, s, e;
        memcpy(&attr, nodes + 16 * i + 4, 4), memcpy(&s, nodes + 16 * i + 8, 4), memcpy(&e, nodes + 16 * i + 12, 4);
        const char *nm = attr >> 24 ? (const char *)names + (attr & 0xffffff) * 4 : "";
        if (doff + e > n) return NULL;
        if (name ? !strcmp(nm, name) : i == index) {
            if (out_name) snprintf(out_name, 256, "%s", nm);
            *size = e - s;
            return b + doff + s;
        }
    }
    return NULL;
}
const uint8_t *nx_sarc_file(const uint8_t *b, size_t n, const char *name, size_t *size) { return sarc_entry(b, n, name, 0, NULL, size); }

// ---- BNTX ----------------------------------------------------------------------------------------------------------
typedef struct { const uint8_t *brti; char name[64]; int w, h, fmt, bh_log2; const uint8_t *data; size_t size; } BntxTex;
static int bntx_tex(const uint8_t *b, size_t n, int i, BntxTex *t) {
    if (n < 0x40 || memcmp(b, "BNTX", 4)) return -1;
    uint32_t cnt;
    int64_t info;
    memcpy(&cnt, b + 0x24, 4), memcpy(&info, b + 0x28, 8);
    if (i >= (int)cnt || info + 8 * (i + 1) > (int64_t)n) return -1;
    int64_t p;
    memcpy(&p, b + info + 8 * i, 8);
    if (p + 0x78 > (int64_t)n || memcmp(b + p, "BRTI", 4)) return -1;
    const uint8_t *r = b + p;
    uint32_t fmt, size, lay;
    int32_t w, h;
    int64_t name_at, ptrs;
    memcpy(&fmt, r + 0x1c, 4), memcpy(&w, r + 0x24, 4), memcpy(&h, r + 0x28, 4), memcpy(&lay, r + 0x34, 4);
    memcpy(&size, r + 0x50, 4), memcpy(&name_at, r + 0x60, 8), memcpy(&ptrs, r + 0x70, 8);
    int64_t mip0;
    if (ptrs + 8 > (int64_t)n) return -1;
    memcpy(&mip0, b + ptrs, 8);
    if (mip0 + size > (int64_t)n || name_at + 2 > (int64_t)n) return -1;
    uint16_t nl;
    memcpy(&nl, b + name_at, 2);
    snprintf(t->name, sizeof t->name, "%.*s", nl < 63 ? nl : 63, (const char *)b + name_at + 2);
    t->brti = r, t->w = w, t->h = h, t->fmt = (int)fmt, t->bh_log2 = lay & 7, t->data = b + mip0, t->size = size;
    return 0;
}
int nx_bntx_count(const uint8_t *b, size_t n) {
    uint32_t cnt = 0;
    if (n >= 0x28 && !memcmp(b, "BNTX", 4)) memcpy(&cnt, b + 0x24, 4);
    return (int)cnt;
}
const char *nx_bntx_name(const uint8_t *b, size_t n, int i) {
    static __thread BntxTex t;
    return bntx_tex(b, n, i, &t) ? NULL : t.name;
}

// Block-linear (GOB 64 B x 8 rows, block height 2^bh GOBs) -> linear rows of blocks.
static void deswizzle(const uint8_t *src, size_t src_size, uint8_t *dst, int wb, int hb, int bpe, int bh_log2) {
    int bh = 1 << bh_log2, row_bytes = wb * bpe, gobs_x = (row_bytes + 63) / 64;
    for (int y = 0; y < hb; y++)
        for (int x = 0; x < row_bytes; x++) {
            size_t a = (size_t)(y / (8 * bh)) * gobs_x * bh * 512 + (size_t)(x / 64) * bh * 512 + (size_t)((y % (8 * bh)) / 8) * 512 +
                       ((x % 64) / 32) * 256 + ((y % 8) / 2) * 64 + ((x % 32) / 16) * 32 + (y % 2) * 16 + (x % 16);
            dst[(size_t)y * row_bytes + x] = a < src_size ? src[a] : 0;
        }
}

static id<MTLDevice> asset_dev(void) {
    static id<MTLDevice> d;
    if (!d) d = MTLCreateSystemDefaultDevice();
    return d;
}
// ASTC 4x4 blocks -> RGBA8 (sRGB bytes) through the GPU: a compute read of the compressed texture.
static int astc_decode(const uint8_t *blocks, int w, int h, int srgb, uint8_t *rgba) {
    id<MTLDevice> dev = asset_dev();
    static id<MTLComputePipelineState> ps;
    if (!ps) {
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
                         "kernel void k(texture2d<float, access::read> s [[texture(0)]], texture2d<float, access::write> d [[texture(1)]],"
                         " uint2 g [[thread_position_in_grid]]) { if (g.x < d.get_width() && g.y < d.get_height()) d.write(s.read(g), g); }";
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
        ps = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err] : nil;
        if (!ps) { nx_log("assets: ASTC kernel: %s", err.localizedDescription.UTF8String); return -1; }
    }
    MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:srgb ? MTLPixelFormatASTC_4x4_sRGB : MTLPixelFormatASTC_4x4_LDR
                                                                                   width:w height:h mipmapped:NO];
    id<MTLTexture> s = [dev newTextureWithDescriptor:sd];
    if (!s) return -1;
    [s replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:blocks bytesPerRow:(NSUInteger)((w + 3) / 4) * 16];
    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:srgb ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm
                                                                                   width:w height:h mipmapped:NO];
    dd.usage = MTLTextureUsageShaderWrite;
    dd.storageMode = MTLStorageModeShared;
    id<MTLTexture> d = [dev newTextureWithDescriptor:dd];
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps];
    [ce setTexture:s atIndex:0], [ce setTexture:d atIndex:1];
    [ce dispatchThreadgroups:MTLSizeMake((w + 15) / 16, (h + 15) / 16, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [ce endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    [d getBytes:rgba bytesPerRow:(NSUInteger)w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    return 0;
}

// A texture as straight RGBA8 (malloc'd). Single-channel formats (BC4, R8: the game's shape masks, tinted by the layout)
// come out white with the channel as alpha; BC5 / RG8 as R, G, 0, 255.
uint8_t *nx_bntx_rgba(const uint8_t *b, size_t n, const char *name, int *w_out, int *h_out) {
    BntxTex t = {0};
    int found = 0;
    for (int i = 0; !found && !bntx_tex(b, n, i, &t); i++) found = !strcmp(t.name, name);
    if (!found) return NULL;
    int type = t.fmt >> 8, w = t.w, h = t.h;
    int bw = 1, bpe;
    switch (type) {
    case 0x02: bpe = 1; break;                           // R8
    case 0x09: bpe = 2; break;                           // R8G8
    case 0x0b: bpe = 4; break;                           // R8G8B8A8
    case 0x1a: case 0x1d: bw = 4, bpe = 8; break;        // BC1, BC4
    case 0x1b: case 0x1c: case 0x1e: case 0x20: case 0x2d: bw = 4, bpe = 16; break;   // BC2, BC3, BC5, BC7, ASTC 4x4
    default: nx_log("assets: %s: format %#x not handled", name, t.fmt); return NULL;
    }
    int wb = (w + bw - 1) / bw, hb = (h + bw - 1) / bw;
    uint8_t *lin = malloc((size_t)wb * hb * bpe), *rgba = calloc((size_t)w * h, 4);
    deswizzle(t.data, t.size, lin, wb, hb, bpe, t.bh_log2);
    if (type == 0x2d) {
        if (astc_decode(lin, w, h, (t.fmt & 0xff) == 6, rgba)) { free(lin), free(rgba); return NULL; }
    } else if (bw == 1) {
        for (int i = 0; i < w * h; i++) {
            uint8_t *o = rgba + 4 * i, *s = lin + (size_t)i * bpe;
            if (bpe == 1) o[0] = o[1] = o[2] = 255, o[3] = s[0];
            else if (bpe == 2) o[0] = s[0], o[1] = s[1], o[2] = 0, o[3] = 255;
            else memcpy(o, s, 4);
        }
    } else {
        uint8_t blk[4 * 4 * 4];
        for (int by = 0; by < hb; by++)
            for (int bx = 0; bx < wb; bx++) {
                const uint8_t *s = lin + ((size_t)by * wb + bx) * bpe;
                memset(blk, 0, sizeof blk);
                if (type == 0x1a) bcdec_bc1(s, blk, 16);
                else if (type == 0x1b) bcdec_bc2(s, blk, 16);
                else if (type == 0x1c) bcdec_bc3(s, blk, 16);
                else if (type == 0x20) bcdec_bc7(s, blk, 16);
                else if (type == 0x1d) {
                    uint8_t r[16];
                    bcdec_bc4(s, r, 4);
                    for (int k = 0; k < 16; k++) blk[4 * k] = blk[4 * k + 1] = blk[4 * k + 2] = 255, blk[4 * k + 3] = r[k];
                } else {   // BC5
                    uint8_t rg[32];
                    bcdec_bc5(s, rg, 8);
                    for (int k = 0; k < 16; k++) blk[4 * k] = rg[2 * k], blk[4 * k + 1] = rg[2 * k + 1], blk[4 * k + 2] = 0, blk[4 * k + 3] = 255;
                }
                for (int yy = 0; yy < 4 && by * 4 + yy < h; yy++)
                    for (int xx = 0; xx < 4 && bx * 4 + xx < w; xx++)
                        memcpy(rgba + (((size_t)(by * 4 + yy) * w) + bx * 4 + xx) * 4, blk + (yy * 4 + xx) * 4, 4);
            }
    }
    free(lin);
    *w_out = w, *h_out = h;
    return rgba;
}
// As a CGImage (+1, straight alpha), or NULL.
CGImageRef nx_bntx_image(const uint8_t *b, size_t n, const char *name) {
    int w, h;
    uint8_t *rgba = nx_bntx_rgba(b, n, name, &w, &h);
    if (!rgba) return NULL;
    CFDataRef data = CFDataCreate(NULL, rgba, (CFIndex)w * h * 4);
    free(rgba);
    CGDataProviderRef dp = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef img = CGImageCreate(w, h, 8, 32, (size_t)w * 4, cs, kCGBitmapByteOrderDefault | kCGImageAlphaLast, dp, NULL, true,
                                   kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs), CGDataProviderRelease(dp), CFRelease(data);
    return img;
}

// A font of the archive (.bfotf / .bfttf) decrypted to plain OpenType / TrueType (malloc'd), or NULL.
uint8_t *nx_font_decrypt(const uint8_t *f, size_t n, size_t *out_n) {
    enum { KEY = 0xA6018502u };
    if (n < 12) return NULL;
    uint32_t w[2];
    for (int i = 0; i < 2; i++) w[i] = ((uint32_t)f[4 * i] << 24 | (uint32_t)f[4 * i + 1] << 16 | (uint32_t)f[4 * i + 2] << 8 | f[4 * i + 3]) ^ KEY;
    if (w[0] != 0x7F9A0218u || w[1] > n - 8) return NULL;
    uint8_t *o = malloc(w[1]);
    for (uint32_t i = 0; i < w[1]; i++) {
        size_t at = 8 + i;
        uint32_t k = at / 4 * 4 + 4 <= n ? KEY : 0;   // a trailing partial word is stored plain
        o[i] = f[at] ^ (uint8_t)(k >> (24 - 8 * (at % 4)));
    }
    *out_n = w[1];
    return o;
}

// ---- recon dump (Mac) -----------------------------------------------------------------------------------------------
static void write_png(const char *path, CGImageRef img) {
    CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CGImageDestinationRef d = CGImageDestinationCreateWithURL(u, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    CGImageDestinationAddImage(d, img, NULL);
    CGImageDestinationFinalize(d);
    CFRelease(d), CFRelease(u);
}
void nx_asset_dump(const char *dir, const char *romfs_name) {
    size_t n;
    uint8_t *a = nx_asset_file(romfs_name, &n);
    if (!a) { nx_log("assets: %s: not found", romfs_name); return; }
    char nm[256], path[2048];
    size_t sz;
    const uint8_t *e;
    for (int i = 0; (e = sarc_entry(a, n, NULL, i, nm, &sz)); i++) {
        const char *base = strrchr(nm, '/') ? strrchr(nm, '/') + 1 : nm;
        if (nx_bntx_count(e, sz) > 0) {
            for (int k = 0; k < nx_bntx_count(e, sz); k++) {
                const char *tn = nx_bntx_name(e, sz, k);
                char tname[64];
                snprintf(tname, sizeof tname, "%s", tn ? tn : "?");
                CGImageRef img = tn ? nx_bntx_image(e, sz, tname) : NULL;
                for (char *c = tname; *c; c++) if (*c == '^' || *c == '+') *c = '_';
                snprintf(path, sizeof path, "%s/%.*s__%s.png", dir, (int)(strchr(romfs_name, '.') - romfs_name), romfs_name, tname);
                if (img) write_png(path, img), CGImageRelease(img);
                nx_log("assets: %s %s", path, img ? "ok" : "FAILED");
            }
        } else if (strstr(base, ".bfotf") || strstr(base, ".bfttf")) {
            size_t fn;
            uint8_t *font = nx_font_decrypt(e, sz, &fn);
            snprintf(path, sizeof path, "%s/%s.%s", dir, base, strstr(base, ".bfotf") ? "otf" : "ttf");
            FILE *f = font ? fopen(path, "wb") : NULL;
            if (f) fwrite(font, 1, fn, f), fclose(f);
            nx_log("assets: %s %s", path, f ? "ok" : "FAILED");
            free(font);
        }
    }
    free(a);
}

// ---- sounds --------------------------------------------------------------------------------------------------------
// A sound effect from a BARS archive (Sound/Resource/*.bars.zs) as a 16-bit WAV file: BARS = "BARS", u32 size, BOM,
// u16 version, u32 count, count x CRC32 of the names, count x (AMTA offset, BWAV offset). BWAV: u16 channels at +0xE,
// then 0x4C bytes per channel: u16 codec (0 PCM16, 1 DSP-ADPCM), u16 pan, u32 rate, u32 samples, 16 coefficients at
// +0x10, sample data offset (from the BWAV) at +0x30, predictor/scale, history 1 and 2 at +0x40.
// DSP-ADPCM: 8-byte frames, a header byte (predictor << 4 | scale log2) then 14 4-bit samples. nil: not there.
NSData *nx_bars_wav(const uint8_t *b, size_t n, const char *name) {
    if (n < 0x10 || memcmp(b, "BARS", 4)) return nil;
    uint32_t count, h = (uint32_t)crc32(0, (const Bytef *)name, (uInt)strlen(name)), bw = 0;
    memcpy(&count, b + 0xc, 4);
    if (0x10 + 12ull * count > n) return nil;
    for (uint32_t i = 0; i < count && !bw; i++) {
        uint32_t x;
        memcpy(&x, b + 0x10 + 4 * i, 4);
        if (x == h) memcpy(&bw, b + 0x10 + 4 * count + 8 * i + 4, 4);
    }
    if (!bw || bw + 0x10 + 0x4c > n || memcmp(b + bw, "BWAV", 4)) return nil;
    uint16_t nch, codec;
    uint32_t rate, ns, start;
    memcpy(&nch, b + bw + 0xe, 2);
    if (nch < 1 || nch > 2 || bw + 0x10 + 0x4c * nch > n) return nil;
    const uint8_t *c0 = b + bw + 0x10;
    memcpy(&codec, c0, 2), memcpy(&rate, c0 + 4, 4), memcpy(&ns, c0 + 8, 4);
    if (ns == 0 || ns > 48000 * 10) return nil;
    NSMutableData *wav = [NSMutableData dataWithLength:44 + 2ull * ns * nch];
    int16_t *out = (int16_t *)((uint8_t *)wav.mutableBytes + 44);
    for (int c = 0; c < nch; c++) {
        const uint8_t *ci = b + bw + 0x10 + 0x4c * c;
        memcpy(&start, ci + 0x30, 4);
        const uint8_t *src = b + bw + start;
        if (codec == 0) {
            if (bw + start + 2ull * ns > n) return nil;
            for (uint32_t i = 0; i < ns; i++) memcpy(&out[i * nch + c], src + 2 * i, 2);
            continue;
        }
        if (codec != 1 || bw + start + (ns + 13) / 14 * 8ull > n) return nil;
        int16_t coef[16], h1, h2;
        memcpy(coef, ci + 0x10, 32), memcpy(&h1, ci + 0x42, 2), memcpy(&h2, ci + 0x44, 2);
        for (uint32_t i = 0; i < ns; i++) {
            const uint8_t *fr = src + i / 14 * 8;
            int k = i % 14, scale = 1 << (fr[0] & 15), p = fr[0] >> 4 & 7;
            int nib = k & 1 ? fr[1 + k / 2] & 15 : fr[1 + k / 2] >> 4;
            if (nib >= 8) nib -= 16;
            int v = (((nib * scale) << 11) + 1024 + coef[p * 2] * h1 + coef[p * 2 + 1] * h2) >> 11;
            v = v < -32768 ? -32768 : v > 32767 ? 32767 : v;
            out[i * nch + c] = (int16_t)v, h2 = h1, h1 = (int16_t)v;
        }
    }
    uint8_t *w = wav.mutableBytes;
    uint32_t data = 2 * ns * nch, riff = 36 + data, fmt = 16, br = rate * 2 * nch;
    uint16_t pcm = 1, ba = (uint16_t)(2 * nch), bits = 16;
    memcpy(w, "RIFF", 4), memcpy(w + 4, &riff, 4), memcpy(w + 8, "WAVEfmt ", 8), memcpy(w + 16, &fmt, 4);
    memcpy(w + 20, &pcm, 2), memcpy(w + 22, &nch, 2), memcpy(w + 24, &rate, 4), memcpy(w + 28, &br, 4);
    memcpy(w + 32, &ba, 2), memcpy(w + 34, &bits, 2), memcpy(w + 36, "data", 4), memcpy(w + 40, &data, 4);
    return wav;
}
