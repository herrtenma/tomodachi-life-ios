// Texture registry and dumps (graphics step 2).
// Every nvnTextureInitialize is snapshotted with the builder extras we keep host-side
// (packaged data/layout, stride). NXRT_TEXDUMP=<dir> decodes mip 0 of every live texture at
// frame NXRT_TEXDUMP_FRAME (default 600): Tegra block-linear -> linear on the CPU, then a Metal
// texture in the matching format (BCn is native on Apple GPUs), rendered to RGBA8 and saved
// as PNG (longest side capped at 1024). index.csv lists every texture, decoded or not.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <mach/mach.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif
#include <pthread.h>
#include <pthread/qos.h>
#include <sys/mman.h>
#include <sys/stat.h>

#include "gfx.h"
#include "gfx_internal.h"
#include "nvn_formats.h"
#include "nxrt.h"

typedef struct {
    const uint8_t *packaged;
    uint8_t layout[8];
    int has_layout;
    int64_t stride;
    uint16_t swizzle;   // NVN swizzle r | g << 4 | b << 8 | a << 12 (ZERO 0, ONE 1, R..A 2..5); 0 = identity
} BuilderExtra;

typedef struct {
    const void *tex;
    NxTexDesc d;
    BuilderExtra x;
    uint64_t serial;
} TexRecord;

static pthread_mutex_t g_tlock = PTHREAD_MUTEX_INITIALIZER;
static NSMapTable *g_builders;   // builder* -> NSMutableData(BuilderExtra)
static NSMapTable *g_texreg;     // texture* -> NSMutableData(TexRecord)
static NSMapTable *g_swapped;   // texture* -> @[NSMutableData(SwapRec), pending MTLBuffer or NSNull] (under g_tlock)
static uint64_t g_swap_out_n, g_swap_out_bytes, g_swap_in_n, g_swap_in_bytes, g_swap_stale_n;   // stats since the last gfx_texture_stats
static NSMapTable *g_mtltex;     // texture* -> @[TexMeta, MTLTexture] (Metal textures section)
static uint64_t g_serial;

#define KEY(p) ((__bridge id)(void *)(p))

static void reg_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSPointerFunctionsOptions k = NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality;
        g_builders = [NSMapTable mapTableWithKeyOptions:k valueOptions:NSPointerFunctionsStrongMemory];
        g_texreg = [NSMapTable mapTableWithKeyOptions:k valueOptions:NSPointerFunctionsStrongMemory];
    });
}

static BuilderExtra *extra_for(void *b) {   // lock held
    NSMutableData *d = [g_builders objectForKey:KEY(b)];
    if (!d) {
        d = [NSMutableData dataWithLength:sizeof(BuilderExtra)];
        [g_builders setObject:d forKey:KEY(b)];
    }
    return d.mutableBytes;
}

void gfx_texbuilder_defaults(void *b) {
    @autoreleasepool {
        reg_init();
        pthread_mutex_lock(&g_tlock);
        [g_builders removeObjectForKey:KEY(b)];
        pthread_mutex_unlock(&g_tlock);
    }
}

void gfx_texbuilder_packaged_data(void *b, const void *data) {
    @autoreleasepool {
        reg_init();
        pthread_mutex_lock(&g_tlock);
        extra_for(b)->packaged = data;
        pthread_mutex_unlock(&g_tlock);
    }
}

void gfx_texbuilder_packaged_layout(void *b, const void *layout) {
    @autoreleasepool {
        reg_init();
        pthread_mutex_lock(&g_tlock);
        BuilderExtra *x = extra_for(b);
        if (layout) memcpy(x->layout, layout, 8);
        x->has_layout = layout != NULL;
        pthread_mutex_unlock(&g_tlock);
    }
}

void gfx_texbuilder_stride(void *b, int64_t stride) {
    @autoreleasepool {
        reg_init();
        pthread_mutex_lock(&g_tlock);
        extra_for(b)->stride = stride;
        pthread_mutex_unlock(&g_tlock);
    }
}

void gfx_texbuilder_swizzle(void *b, int32_t r, int32_t g, int32_t bl, int32_t a) {
    @autoreleasepool {
        reg_init();
        pthread_mutex_lock(&g_tlock);
        extra_for(b)->swizzle = (uint16_t)((r & 15) | (g & 15) << 4 | (bl & 15) << 8 | (a & 15) << 12);
        pthread_mutex_unlock(&g_tlock);
    }
}

// The texture's own swizzle (NVN packing), identity 0x5432 when none was set.
uint16_t gfx_texture_swizzle(const void *tex) {
    if (!tex) return 0x5432;
    @autoreleasepool {
        reg_init();
        pthread_mutex_lock(&g_tlock);
        NSMutableData *rd = [g_texreg objectForKey:KEY(tex)];
        uint16_t sw = rd ? ((const TexRecord *)rd.bytes)->x.swizzle : 0;
        pthread_mutex_unlock(&g_tlock);
        return sw ? sw : 0x5432;
    }
}

// nvnTextureWriteTexels(texture, view, region {x, y, z, w, h, d}, data): CPU upload of tightly packed
// texels (the game fills small textures this way at load, e.g. the tone map's 4x4 exposure texture).
// Written straight into the Metal texture at the view's level / layer.
static uint64_t g_texel_writes;
static MTLPixelFormat mtl_raw(int nvn);
static int bc_decoded(int nvn);
static int n_log_texels(void) {
    static int on = -1, n;
    if (on < 0) on = getenv("NXRT_GFXDBG") != NULL;
    return on && n++ < 40;
}
void gfx_texture_write_texels(const void *tex, const void *view, const int32_t *region, const void *data) {
    if (!tex || !region || !data) return;
    @autoreleasepool {
        id<MTLTexture> t = gfx_texture_mtl(tex);
        NxTexDesc d = {0};
        nx_nvn_texture_desc(tex, &d);
        const NvnFmt *f = nvn_fmt(d.format);
        const NxTexView *v = view;
        int level = v && (v->set & 1) ? v->base_level : 0, layer = v && (v->set & 2) ? v->min_layer : 0;
        int x = region[0], y = region[1], z = region[2], w = region[3], h = region[4], dd = region[5] > 0 ? region[5] : 1;
        if (n_log_texels()) nx_log("gfx: WriteTexels %p %dx%d fmt %d level %d layer %d region %d,%d,%d %dx%dx%d", tex, d.w, d.h, d.format, level, layer,
                                   x, y, z, w, h, dd);
        if (!t || !f || w <= 0 || h <= 0 || level >= (int)t.mipmapLevelCount) return;
        gfx_texture_mark_gpu(tex);   // the Metal texture now holds data the pool doesn't
        int lw = MAX(1, (int)t.width >> level), lh = MAX(1, (int)t.height >> level);
        if (x < 0 || y < 0 || x + w > lw || y + h > lh) return;
        NSUInteger slices = t.textureType == MTLTextureType3D ? 1 : t.arrayLength * (t.textureType == MTLTextureTypeCube || t.textureType == MTLTextureTypeCubeArray ? 6 : 1);
        int is3d = t.textureType == MTLTextureType3D;
        if (!is3d && (layer + z < 0 || layer + z + dd > (int)slices)) return;
        NSUInteger wb = (w + f->bw - 1) / f->bw, hb = (h + f->bh - 1) / f->bh, row = wb * f->bpb, img = row * hb;
        id<MTLBuffer> src = [g_dev newBufferWithBytes:data length:img * dd options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        if (bc_decoded(d.format) && !is3d) {
            id<MTLComputeCommandEncoder> ce = [cmd computeCommandEncoder];
            for (int k = 0; k < dd; k++) gfx_bc_decode(ce, src, k * img, row, mtl_raw(d.format), t, layer + z + k, level, x, y, w, h);
            [ce endEncoding];
            [cmd commit];
            g_texel_writes++;
            return;
        }
        id<MTLBlitCommandEncoder> b = [cmd blitCommandEncoder];
        for (int k = 0; k < (is3d ? 1 : dd); k++)
            [b copyFromBuffer:src sourceOffset:k * img sourceBytesPerRow:row sourceBytesPerImage:img
                   sourceSize:MTLSizeMake(w, h, is3d ? dd : 1) toTexture:t destinationSlice:is3d ? 0 : layer + z + k
             destinationLevel:level destinationOrigin:MTLOriginMake(x, y, is3d ? z : 0)];
        [b endEncoding];
        [cmd commit];
        g_texel_writes++;
    }
}

static void fmt_at_note(const NxTexDesc *d);
void gfx_texture_init(void *tex, const void *b) {
    @autoreleasepool {
        reg_init();
        TexRecord r = {.tex = tex};
        nx_nvn_texture_desc(tex, &r.d);
        pthread_mutex_lock(&g_tlock);
        NSMutableData *x = [g_builders objectForKey:KEY(b)];
        if (x) memcpy(&r.x, x.bytes, sizeof r.x);
        r.serial = ++g_serial;
        fmt_at_note(&r.d);
        [g_texreg setObject:[NSMutableData dataWithBytes:&r length:sizeof r] forKey:KEY(tex)];
        pthread_mutex_unlock(&g_tlock);
    }
}

static void alias_forget(const void *tex);
static int alias_in_use(const NxTexDesc *d);
// Recycling: the engine finalizes some render targets every frame and initializes identical ones at the same
// storage (a 256x256x4 9-level array, a 960x540 target). A new Metal texture meant an allocation and a clear of
// every level and slice (clear_new: 37 render passes and 2 command buffers per frame). The same storage on the
// Switch keeps its bytes, so the new NVN texture gets the old Metal texture back. Up to RECYCLE_N entries,
// kept for RECYCLE_FRAMES frames and RECYCLE_BYTES in all (the oldest go first). NXRT_NORECYCLE=1: off.
enum { RECYCLE_N = 24, RECYCLE_FRAMES = 2 };
#define RECYCLE_BYTES (64ull << 20)
static struct { const void *pool; uint64_t offset, seq, bytes; int frame; __strong id<MTLTexture> t; } g_recycle[RECYCLE_N];
static uint64_t g_recycled_n, g_recycle_seq;
static int recycle_on(void) {
    static int on = -1;
    if (on < 0) on = !getenv("NXRT_NORECYCLE");
    return on;
}
static void recycle_put(const NxTexDesc *d, id<MTLTexture> t) {   // g_tlock held
    extern volatile int g_gfx_frame;
    if (getenv("NXRT_RECYCLELOG") && atoi(getenv("NXRT_RECYCLELOG")) == g_gfx_frame)
        nx_log("recycle: frame %d finalize %dx%d fmt %d pool %p +%#llx metal %p (type %lu, %lu slices, %lu levels) parent %p alias in use %d", g_gfx_frame,
               d->w, d->h, d->format, d->pool, (unsigned long long)d->offset, t, (unsigned long)t.textureType, (unsigned long)t.arrayLength,
               (unsigned long)t.mipmapLevelCount, t.parentTexture, alias_in_use(d));
    if (!recycle_on() || !d->pool || !t || t.parentTexture) return;
    uint64_t bytes = t.allocatedSize;
    if (bytes > RECYCLE_BYTES) return;
    for (;;) {   // make room: a free slot and the byte budget, dropping the oldest entries
        uint64_t used = 0;
        int k = -1, old = -1;
        for (int i = 0; i < RECYCLE_N; i++) {
            if (!g_recycle[i].t) { if (k < 0) k = i; continue; }
            used += g_recycle[i].bytes;
            if (old < 0 || g_recycle[i].seq < g_recycle[old].seq) old = i;
        }
        if (k >= 0 && used + bytes <= RECYCLE_BYTES) {
            g_recycle[k].pool = d->pool, g_recycle[k].offset = d->offset, g_recycle[k].frame = g_gfx_frame, g_recycle[k].t = t;
            g_recycle[k].seq = ++g_recycle_seq, g_recycle[k].bytes = bytes;
            return;
        }
        g_recycle[old].t = nil;
    }
}
static id<MTLTexture> recycle_get(const NxTexDesc *d, MTLTextureDescriptor *td) {   // g_tlock held
    extern volatile int g_gfx_frame;
    id<MTLTexture> hit = nil;
    for (int i = 0; i < RECYCLE_N; i++) {
        id<MTLTexture> t = g_recycle[i].t;
        if (!t) continue;
        if (g_gfx_frame - g_recycle[i].frame > RECYCLE_FRAMES) { g_recycle[i].t = nil; continue; }
        if (hit || g_recycle[i].pool != d->pool || g_recycle[i].offset != (uint64_t)d->offset || t.textureType != td.textureType ||
            t.pixelFormat != td.pixelFormat || t.width != td.width || t.height != td.height || t.depth != td.depth ||
            t.arrayLength != td.arrayLength || t.mipmapLevelCount != td.mipmapLevelCount || t.sampleCount != td.sampleCount ||
            t.usage != td.usage || t.storageMode != td.storageMode)
            continue;
        hit = t, g_recycle[i].t = nil;
    }
    if (hit) g_recycled_n++;
    if (getenv("NXRT_RECYCLELOG") && atoi(getenv("NXRT_RECYCLELOG")) == g_gfx_frame)
        nx_log("recycle: frame %d create %lux%lu type %lu fmt %lu pool %p +%#llx -> %s %p", g_gfx_frame, (unsigned long)td.width, (unsigned long)td.height,
               (unsigned long)td.textureType, (unsigned long)td.pixelFormat, d->pool, (unsigned long long)d->offset, hit ? "RECYCLED" : "new", hit);
    return hit;
}
void gfx_texture_finalize(void *tex) {
    @autoreleasepool {
        reg_init();
        pthread_mutex_lock(&g_tlock);
        alias_forget(tex);
        [g_texreg removeObjectForKey:KEY(tex)];
        // Drop the Metal texture too (command buffers in flight retain what they use). Keeping it leaked
        // every transient texture the engine creates and finalizes: ~230 MB/s, then the system killed nxrt.
        NSArray *old = [g_mtltex objectForKey:KEY(tex)];
        [g_mtltex removeObjectForKey:KEY(tex)];
        if (old && old[1] != [NSNull null]) {
            NxTexDesc d;
            nx_nvn_texture_desc(tex, &d);
            recycle_put(&d, old[1]);
        }
        pthread_mutex_unlock(&g_tlock);
        if (old && old[1] != [NSNull null]) gfx_texture_dropped(old[1]);
    }
}

// ---- formats -------------------------------------------------------------------------
// Sizes come from nvn_formats.h; this maps the formats we can sample to Metal.
typedef struct { int nvn; MTLPixelFormat mtl; } MtlFmt;
static const MtlFmt g_mtl[] = {
    {1, MTLPixelFormatR8Unorm},          {2, MTLPixelFormatR8Snorm},         {3, MTLPixelFormatR8Uint},
    {4, MTLPixelFormatR8Sint},           {7, MTLPixelFormatR16Snorm},        {8, MTLPixelFormatR16Uint},
    {9, MTLPixelFormatR16Sint},          {11, MTLPixelFormatR32Uint},        {12, MTLPixelFormatR32Sint},
    {15, MTLPixelFormatRG8Uint},         {16, MTLPixelFormatRG8Sint},        {18, MTLPixelFormatRG16Unorm},
    {19, MTLPixelFormatRG16Snorm},       {20, MTLPixelFormatRG16Uint},       {21, MTLPixelFormatRG16Sint},
    {23, MTLPixelFormatRG32Uint},        {24, MTLPixelFormatRG32Sint},       {39, MTLPixelFormatRGBA8Uint},
    {40, MTLPixelFormatRGBA8Sint},       {42, MTLPixelFormatRGBA16Unorm},    {43, MTLPixelFormatRGBA16Snorm},
    {44, MTLPixelFormatRGBA16Uint},      {45, MTLPixelFormatRGBA16Sint},     {47, MTLPixelFormatRGBA32Uint},
    {48, MTLPixelFormatRGBA32Sint},      {49, MTLPixelFormatStencil8},       {50, MTLPixelFormatDepth16Unorm},
    {51, MTLPixelFormatDepth32Float},    {52, MTLPixelFormatDepth32Float},   {53, MTLPixelFormatDepth32Float_Stencil8},
    {54, MTLPixelFormatDepth32Float_Stencil8}, {57, MTLPixelFormatABGR4Unorm}, {60, MTLPixelFormatB5G6R5Unorm},
    {59, MTLPixelFormatA1BGR5Unorm},     {62, MTLPixelFormatRGB10A2Uint},
    {5, MTLPixelFormatR16Float},        {6, MTLPixelFormatR16Unorm},
    {10, MTLPixelFormatR32Float},        {13, MTLPixelFormatRG8Unorm},       {14, MTLPixelFormatRG8Snorm},
    {17, MTLPixelFormatRG16Float},       {22, MTLPixelFormatRG32Float},      {37, MTLPixelFormatRGBA8Unorm},
    {38, MTLPixelFormatRGBA8Snorm},      {41, MTLPixelFormatRGBA16Float},    {46, MTLPixelFormatRGBA32Float},
    {55, MTLPixelFormatRGBA8Unorm_sRGB}, {56, MTLPixelFormatRGBA8Unorm_sRGB}, {61, MTLPixelFormatRGB10A2Unorm},
    {63, MTLPixelFormatRG11B10Float},    {64, MTLPixelFormatRGB9E5Float},
    {65, MTLPixelFormatBC1_RGBA},        {66, MTLPixelFormatBC1_RGBA},       {67, MTLPixelFormatBC2_RGBA},
    {68, MTLPixelFormatBC3_RGBA},        {69, MTLPixelFormatBC1_RGBA_sRGB},  {70, MTLPixelFormatBC1_RGBA_sRGB},
    {71, MTLPixelFormatBC2_RGBA_sRGB},   {72, MTLPixelFormatBC3_RGBA_sRGB},  {73, MTLPixelFormatBC4_RUnorm},
    {74, MTLPixelFormatBC4_RSnorm},      {75, MTLPixelFormatBC5_RGUnorm},    {76, MTLPixelFormatBC5_RGSnorm},
    {77, MTLPixelFormatBC7_RGBAUnorm},   {78, MTLPixelFormatBC7_RGBAUnorm_sRGB},
    {79, MTLPixelFormatBC6H_RGBFloat},   {80, MTLPixelFormatBC6H_RGBUfloat},
    {121, MTLPixelFormatASTC_4x4_LDR},   {122, MTLPixelFormatASTC_5x4_LDR},  {123, MTLPixelFormatASTC_5x5_LDR},
    {124, MTLPixelFormatASTC_6x5_LDR},   {125, MTLPixelFormatASTC_6x6_LDR},  {126, MTLPixelFormatASTC_8x5_LDR},
    {127, MTLPixelFormatASTC_8x6_LDR},   {128, MTLPixelFormatASTC_8x8_LDR},  {129, MTLPixelFormatASTC_10x5_LDR},
    {130, MTLPixelFormatASTC_10x6_LDR},  {131, MTLPixelFormatASTC_10x8_LDR}, {132, MTLPixelFormatASTC_10x10_LDR},
    {133, MTLPixelFormatASTC_12x10_LDR}, {134, MTLPixelFormatASTC_12x12_LDR},
    {135, MTLPixelFormatASTC_4x4_sRGB},  {136, MTLPixelFormatASTC_5x4_sRGB}, {137, MTLPixelFormatASTC_5x5_sRGB},
    {138, MTLPixelFormatASTC_6x5_sRGB},  {139, MTLPixelFormatASTC_6x6_sRGB}, {140, MTLPixelFormatASTC_8x5_sRGB},
    {141, MTLPixelFormatASTC_8x6_sRGB},  {142, MTLPixelFormatASTC_8x8_sRGB}, {143, MTLPixelFormatASTC_10x5_sRGB},
    {144, MTLPixelFormatASTC_10x6_sRGB}, {145, MTLPixelFormatASTC_10x8_sRGB}, {146, MTLPixelFormatASTC_10x10_sRGB},
    {147, MTLPixelFormatASTC_12x10_sRGB}, {148, MTLPixelFormatASTC_12x12_sRGB},
};
// tools/texconv stores the BC5 snorm normal maps as EAC RG11 snorm (same 16 B / 4x4 blocks) labelled BC2 (RGBA_DXT3,
// which the game itself never uses): with its RomFS (NXRT_ROMFS) 67 is EAC. NXRT_BC2_EAC=0: off.
static int bc2_is_eac(void) {
    static int on = -1;
    if (on < 0) on = getenv("NXRT_ROMFS") && *getenv("NXRT_ROMFS") && (!getenv("NXRT_BC2_EAC") || atoi(getenv("NXRT_BC2_EAC")));
    return on;
}
// The game's format as a Metal format (BC stays BC)
static MTLPixelFormat mtl_raw(int nvn) {
    if (nvn == 67 && bc2_is_eac()) return MTLPixelFormatEAC_RG11Snorm;
    for (size_t i = 0; i < sizeof g_mtl / sizeof *g_mtl; i++)
        if (g_mtl[i].nvn == nvn) return g_mtl[i].mtl;
    return MTLPixelFormatInvalid;
}
// The format the Metal texture has: BC becomes RGBA8/R8/RG8 on GPUs without BC sampling (gfx_bcdec.m)
static MTLPixelFormat mtl_for(int nvn) { return gfx_bc_host_format(mtl_raw(nvn)); }
MTLPixelFormat gfx_mtl_format_raw(int nvn) { return mtl_raw(nvn); }
// Decoded on upload instead of copied (BC on a GPU without BC sampling)
static int bc_decoded(int nvn) { return gfx_bc_mode(mtl_raw(nvn)) && gfx_bc_emulated(); }
static int is_srgb(int nvn) {
    const NvnFmt *f = nvn_fmt(nvn);
    return f && strstr(f->name, "SRGB") != NULL;
}

// ---- Tegra X1 block-linear -> linear ----------------------------------------------------
// A GOB is 64 bytes x 8 rows (512 bytes). A block is gh GOBs stacked vertically; blocks run
// left to right, then down.
static void deswizzle(const uint8_t *src, uint8_t *dst, uint32_t wb, uint32_t hb, int bpb, int gh) {
    uint64_t width_gobs = ((uint64_t)wb * bpb + 63) / 64;
    for (uint32_t y = 0; y < hb; y++) {
        uint64_t row = (uint64_t)(y / (8 * gh)) * 512 * gh * width_gobs + (uint64_t)((y % (8 * gh)) / 8) * 512 +
                       ((y % 8) / 2) * 64 + (y % 2) * 16;
        for (uint32_t x = 0; x < wb; x++) {
            uint64_t xb = (uint64_t)x * bpb;
            uint64_t a = row + (xb / 64) * 512 * gh + ((xb % 64) / 32) * 256 + ((xb % 32) / 16) * 32 + (xb % 16);
            memcpy(dst + ((uint64_t)y * wb + x) * bpb, src + a, bpb);
        }
    }
}

// 3D: blocks of gh GOBs in Y by gd slices in Z (GOBs run Y first, then Z, inside a block); blocks run left to
// right, then down, then back (Ryujinx BlockLinearLayout).
static void deswizzle3d(const uint8_t *src, uint8_t *dst, uint32_t wb, uint32_t hb, uint32_t db, int bpb, int gh, int gd) {
    uint64_t width_gobs = ((uint64_t)wb * bpb + 63) / 64;
    uint64_t rob = 512ull * gh * gd * width_gobs, slice = (hb + 8ull * gh - 1) / (8 * gh) * rob;
    for (uint32_t z = 0; z < db; z++)
        for (uint32_t y = 0; y < hb; y++) {
            uint64_t row = (uint64_t)(z / gd) * slice + (uint64_t)(y / (8 * gh)) * rob + (uint64_t)((y % (8 * gh)) / 8) * 512 +
                           (uint64_t)(z % gd) * 512 * gh + ((y % 8) / 2) * 64 + (y % 2) * 16;
            for (uint32_t x = 0; x < wb; x++) {
                uint64_t xb = (uint64_t)x * bpb;
                uint64_t a = row + (xb / 64) * 512 * gh * gd + ((xb % 64) / 32) * 256 + ((xb % 32) / 16) * 32 + (xb % 16);
                memcpy(dst + (((uint64_t)z * hb + y) * wb + x) * bpb, src + a, bpb);
            }
        }
}
static uint64_t surface_size3d(uint32_t wb, uint32_t hb, uint32_t db, int bpb, int gh, int gd) {
    uint64_t width_gobs = ((uint64_t)wb * bpb + 63) / 64;
    return (uint64_t)((db + gd - 1) / gd) * ((hb + 8ull * gh - 1) / (8 * gh)) * 512ull * gh * gd * width_gobs;
}

// linear -> block-linear (inverse of deswizzle)
static void swizzle(const uint8_t *src, uint8_t *dst, uint32_t wb, uint32_t hb, int bpb, int gh) {
    uint64_t width_gobs = ((uint64_t)wb * bpb + 63) / 64;
    for (uint32_t y = 0; y < hb; y++) {
        uint64_t row = (uint64_t)(y / (8 * gh)) * 512 * gh * width_gobs + (uint64_t)((y % (8 * gh)) / 8) * 512 +
                       ((y % 8) / 2) * 64 + (y % 2) * 16;
        for (uint32_t x = 0; x < wb; x++) {
            uint64_t xb = (uint64_t)x * bpb;
            uint64_t a = row + (xb / 64) * 512 * gh + ((xb % 64) / 32) * 256 + ((xb % 32) / 16) * 32 + (xb % 16);
            memcpy(dst + a, src + ((uint64_t)y * wb + x) * bpb, bpb);
        }
    }
}

static int nonzero(const uint8_t *p, uint64_t n) {
    uint64_t i = 0;
    for (; i + 64 <= n; i += 64) {   // 64 bytes per step (whole 16 MB storages are checked)
        uint64_t w[8];
        memcpy(w, p + i, 64);
        if (w[0] | w[1] | w[2] | w[3] | w[4] | w[5] | w[6] | w[7]) return 1;
    }
    for (; i < n; i++)
        if (p[i]) return 1;
    return 0;
}

// ---- dump ------------------------------------------------------------------------------

static const char *dump_one(const TexRecord *r, const char *dir, int idx, char *file, size_t file_len,
                            const char **src_kind) {
    const NxTexDesc *d = &r->d;
    *src_kind = "-";
    file[0] = 0;
    if (d->w < 16 || d->h < 16) return "small";
    if (d->samples > 1) return "multisample";
    if (d->target == 2) return "3d";
    const NvnFmt *f = nvn_fmt(d->format);
    MTLPixelFormat mf = mtl_for(d->format);
    if (!f || mf == MTLPixelFormatInvalid) return "format";
    uint32_t wb = (d->w + f->bw - 1) / f->bw, hb = (d->h + f->bh - 1) / f->bh;
    int linear = r->x.stride > 0;
    // Packaged (BNTX) textures carry their layout: byte 0 is log2 of the block height in GOBs.
    int gh = r->x.has_layout && r->x.layout[0] <= 5 ? 1 << r->x.layout[0] : nvn_gob_height(hb);
    uint64_t need = linear ? (uint64_t)r->x.stride * hb : nvn_surface_size(wb, hb, f->bpb, gh);
    // Source: the pool storage if it holds anything, else the packaged pointer.
    const uint8_t *src = NULL;
    if (d->pool_data && d->pool_avail >= need && nonzero(d->pool_data, need < 4096 ? need : 4096))
        src = d->pool_data, *src_kind = "pool";
    else if (r->x.packaged && nonzero(r->x.packaged, need < 4096 ? need : 4096))
        src = r->x.packaged, *src_kind = "packaged";
    if (!src) return d->pool_data ? "empty" : "nostorage";

    NSMutableData *lin = [NSMutableData dataWithLength:(NSUInteger)wb * hb * f->bpb];
    if (linear)
        for (uint32_t y = 0; y < hb; y++)
            memcpy((uint8_t *)lin.mutableBytes + (uint64_t)y * wb * f->bpb, src + (uint64_t)y * r->x.stride, (size_t)wb * f->bpb);
    else
        deswizzle(src, lin.mutableBytes, wb, hb, f->bpb, gh);

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:mf
                                                                                  width:d->w height:d->h mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:td];
    if (!t) return "metal";
    [t replaceRegion:MTLRegionMake2D(0, 0, d->w, d->h) mipmapLevel:0 withBytes:lin.bytes
         bytesPerRow:(NSUInteger)wb * f->bpb];

    NSUInteger ow = d->w, oh = d->h;
    while (ow > 1024 || oh > 1024) ow = (ow + 1) / 2, oh = (oh + 1) / 2;
    MTLPixelFormat outf = is_srgb(d->format) ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm;
    MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:outf width:ow height:oh mipmapped:NO];
    od.usage = MTLTextureUsageRenderTarget;
    od.storageMode = MTLStorageModeShared;
    id<MTLTexture> out = [g_dev newTextureWithDescriptor:od];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = out;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
    id<MTLRenderCommandEncoder> e = [cmd renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:gfx_blit_pso(outf)];
    [e setFragmentTexture:t atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];
    NSMutableData *px = [NSMutableData dataWithLength:ow * oh * 4];
    [out getBytes:px.mutableBytes bytesPerRow:ow * 4 fromRegion:MTLRegionMake2D(0, 0, ow, oh) mipmapLevel:0];
    snprintf(file, file_len, "%04d_%dx%d_%s.png", idx, d->w, d->h, f->name);
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", dir, file);
    return gfx_write_png(path, px.bytes, ow, oh) ? NULL : "png";
}

static int cmp_serial(const void *a, const void *b) {
    uint64_t x = ((const TexRecord *)a)->serial, y = ((const TexRecord *)b)->serial;
    return x < y ? -1 : x > y;
}

void gfx_texdump_at_frame(int frame) {
    const char *dir = getenv("NXRT_TEXDUMP");
    const char *fs = getenv("NXRT_TEXDUMP_FRAME");
    if (!dir || frame != (fs ? atoi(fs) : 600)) return;
    @autoreleasepool {
        reg_init();
        mkdir(dir, 0755);
        pthread_mutex_lock(&g_tlock);
        NSUInteger n = g_texreg.count, i = 0;
        TexRecord *recs = calloc(n ? n : 1, sizeof *recs);
        for (NSMutableData *d in g_texreg.objectEnumerator) memcpy(&recs[i++], d.bytes, sizeof *recs);
        pthread_mutex_unlock(&g_tlock);
        qsort(recs, n, sizeof *recs, cmp_serial);
        nx_log("gfx: texdump: %lu live textures at frame %d -> %s", (unsigned long)n, frame, dir);

        char csv_path[1024];
        snprintf(csv_path, sizeof csv_path, "%s/index.csv", dir);
        FILE *csv = fopen(csv_path, "w");
        if (csv) fprintf(csv, "idx,file,status,source,w,h,d,levels,format,target,flags,stride,layout,pool_data,packaged\n");
        int hist[256] = {0}, ok = 0;
        NSMutableDictionary<NSString *, NSNumber *> *why = [NSMutableDictionary new];
        for (NSUInteger k = 0; k < n; k++) {
            @autoreleasepool {
                TexRecord *r = &recs[k];
                hist[r->d.format & 255]++;
                char file[256];
                const char *src_kind;
                const char *err = dump_one(r, dir, (int)k, file, sizeof file, &src_kind);
                if (!err) ok++;
                else why[@(err)] = @(why[@(err)].intValue + 1);
                if (csv)
                    fprintf(csv, "%lu,%s,%s,%s,%d,%d,%d,%d,%d,%d,%#x,%lld,%02x%02x%02x%02x%02x%02x%02x%02x,%p,%p\n",
                            (unsigned long)k, file, err ? err : "ok", src_kind, r->d.w, r->d.h, r->d.d, r->d.levels,
                            r->d.format, r->d.target, r->d.flags, (long long)r->x.stride, r->x.layout[0],
                            r->x.layout[1], r->x.layout[2], r->x.layout[3], r->x.layout[4], r->x.layout[5],
                            r->x.layout[6], r->x.layout[7], r->d.pool_data, r->x.packaged);
            }
        }
        if (csv) fclose(csv);
        nx_log("gfx: texdump: %d decoded", ok);
        for (NSString *k in why) nx_log("gfx: texdump:   skipped %d: %s", why[k].intValue, k.UTF8String);
        for (int f = 0; f < 256; f++)
            if (hist[f]) nx_log("gfx: texdump:   format %3d (%s): %d", f, nvn_fmt(f) ? nvn_fmt(f)->name : "?", hist[f]);
        free(recs);
    }
}

// ---- Metal textures for NVN textures (graphics step 4) ------------------------------------
// One MTLTexture per NVN texture object (re-created if the object was re-initialized). Data in
// the texture's pool storage is deswizzled and uploaded through a staging buffer and a blit on its
// own command buffer (committed before the draws that use it). It is uploaded again when the CPU
// changes that storage later: a nvnMemoryPoolFlushMappedRange overlapping it (glyph caches, streamed
// textures), or, for a texture whose storage was still all zeros, once it isn't. Textures the GPU
// writes (render targets, copy/clear destinations) and WriteTexels textures are never re-uploaded.
typedef struct {
    uint64_t serial;     // TexRecord serial the Metal texture was made for
    uint64_t seq;        // dirty ranges already checked (g_dirty_seq)
    uintptr_t lo, hi;    // pool storage the upload reads
    int state;           // TEX_*
    int frame_checked;   // TEX_EMPTY: last frame the storage was re-checked
    int levels, layers;
    int cpu_pool;        // storage the CPU can write (pool CPU_UNCACHED / CPU_CACHED): content-hashed
    int frame_hashed;    // last frame the content hash was compared
    uint64_t hash;       // content hash at the last upload (or empty check)
    int bg_changed;      // set by hash_thread: the storage no longer matches `hash`
    uint32_t bg_next, bg_interval;   // hash_thread pass of the next check; passes between checks
    int bg_volatile;     // the CPU rewrote it before (glyph cache): checked at least every HASH_VOLATILE_INTERVAL passes
    int wp;              // write-tracked storage (wp_*): slot + 1, 0 none
    int last_used;       // last frame it was looked up (texture budget, gfx_texture_trim)
    int created;         // frame the Metal texture was made
    uint64_t bytes;      // Metal allocation
} TexMeta;
enum { TEX_UPLOADED, TEX_EMPTY, TEX_GPU, TEX_NODATA };

// CPU writes the GPU must see (nvnMemoryPoolFlushMappedRange), as host address ranges in a ring.
enum { DIRTY_RING = 8192 };
static struct { uintptr_t lo, hi; } g_dirty[DIRTY_RING];
static uint64_t g_dirty_seq;
static uint64_t g_reuploads, g_reupload_bytes, g_flush_bytes, g_hashed_bytes_stat;
static uint64_t g_tex_upload_n_stat, g_tex_upload_bytes_stat;   // uploads since the last stats
static uint64_t g_trim_n, g_trim_bytes, g_trim_frames;          // texture budget (gfx_texture_trim)
void gfx_note_cpu_write(const void *p, uint64_t n) {
    if (!p || !n) return;
    pthread_mutex_lock(&g_tlock);
    g_dirty[g_dirty_seq % DIRTY_RING].lo = (uintptr_t)p;
    g_dirty[g_dirty_seq % DIRTY_RING].hi = (uintptr_t)p + n;
    g_dirty_seq++;
    g_flush_bytes += n;
    pthread_mutex_unlock(&g_tlock);
}
static uint64_t g_clear_new_n, g_clear_new_passes, g_clear_new_bytes;   // new-texture clears (stats)
static uint64_t g_tex_lookup_n_stat, g_tex_lookup_ns_stat;   // gfx_texture_mtl calls (all threads), per stats interval
// NXRT_GFXDBG stats: texture re-uploads since the last call.
void gfx_texture_stats(int frames) {
    extern uint64_t g_tex_upload_ns;
    static uint64_t up_ns0;
    pthread_mutex_lock(&g_tlock);
    nx_log("gfx: textures re-uploaded %.1f/frame (%.1f KB/frame); CPU flushes %.1f KB/frame; content hashed %.1f MB/frame",
           (double)g_reuploads / frames, (double)g_reupload_bytes / frames / 1024, (double)g_flush_bytes / frames / 1024,
           (double)g_hashed_bytes_stat / frames / 1048576);
    g_reuploads = g_reupload_bytes = g_flush_bytes = g_hashed_bytes_stat = 0;
    nx_log("gfx: texture budget: %llu textures dropped (%.0f MB) on %llu frames since the last stats; uploads %.1f/frame (%.1f MB/frame, %.2f ms/frame); "
           "lookups %.0f/frame (%.2f ms/frame with uploads)",
           (unsigned long long)g_trim_n, g_trim_bytes / 1048576.0, (unsigned long long)g_trim_frames, (double)g_tex_upload_n_stat / frames,
           g_tex_upload_bytes_stat / 1048576.0 / frames, (g_tex_upload_ns - up_ns0) / 1e6 / frames, (double)__atomic_exchange_n(&g_tex_lookup_n_stat, 0, __ATOMIC_RELAXED) / frames,
           __atomic_exchange_n(&g_tex_lookup_ns_stat, 0, __ATOMIC_RELAXED) / 1e6 / frames);
    g_trim_n = g_trim_bytes = g_trim_frames = g_tex_upload_n_stat = g_tex_upload_bytes_stat = 0;
    up_ns0 = g_tex_upload_ns;
    nx_log("gfx: texture swap: %llu out (%.0f MB), %llu back in (%.0f MB), %llu stale (re-initialized) since the last stats; %lu swapped out now",
           (unsigned long long)g_swap_out_n, g_swap_out_bytes / 1048576.0, (unsigned long long)g_swap_in_n, g_swap_in_bytes / 1048576.0,
           (unsigned long long)g_swap_stale_n,
           (unsigned long)g_swapped.count);
    g_swap_out_n = g_swap_out_bytes = g_swap_in_n = g_swap_in_bytes = g_swap_stale_n = 0;
    nx_log("gfx: new textures cleared %.1f/frame: %.1f clear passes/frame, ~%.1f MB/frame stored; recycled %.1f/frame", (double)g_clear_new_n / frames,
           (double)g_clear_new_passes / frames, g_clear_new_bytes / 1048576.0 / frames, (double)g_recycled_n / frames);
    g_clear_new_n = g_clear_new_passes = g_clear_new_bytes = g_recycled_n = 0;
    {   // Metal textures by state (aliases counted once: they are TEX_GPU entries sharing the primary's texture)
        uint64_t by[4] = {0}, bc = 0, n[4] = {0}, by_fmt[256] = {0};   // by_fmt: uploaded bytes per NVN format
        NSMutableSet *seen = [NSMutableSet set];
        NSMutableDictionary<NSString *, NSMutableData *> *gpu_groups = [NSMutableDictionary dictionary];
        for (id k in g_mtltex) {
            NSArray *v = [g_mtltex objectForKey:k];
            if (v[1] == [NSNull null]) continue;
            NSValue *tv = [NSValue valueWithPointer:(__bridge const void *)v[1]];
            if ([seen containsObject:tv]) continue;
            [seen addObject:tv];
            const TexMeta *m = ((NSMutableData *)v[0]).bytes;
            uint64_t b = ((id<MTLTexture>)v[1]).allocatedSize;
            by[m->state & 3] += b, n[m->state & 3]++;
            NxTexDesc d;
            nx_nvn_texture_desc((__bridge const void *)k, &d);
            if (bc_decoded(d.format)) bc += b;
            if ((m->state & 3) == TEX_UPLOADED && d.format > 0 && d.format < 256) by_fmt[d.format] += b;
            if ((m->state & 3) == TEX_GPU) {   // GPU-written: group by size + format, with how many are idle
                id<MTLTexture> t = v[1];
                NSString *g = [NSString stringWithFormat:@"%lux%lux%lu fmt %d mips %lu", (unsigned long)t.width, (unsigned long)t.height,
                                                         (unsigned long)MAX(t.depth, t.arrayLength), d.format, (unsigned long)t.mipmapLevelCount];
                uint64_t *e = (uint64_t *)((NSMutableData *)(gpu_groups[g] ?: (gpu_groups[g] = [NSMutableData dataWithLength:32]))).mutableBytes;
                extern volatile int g_gfx_frame;
                int age = g_gfx_frame - m->last_used;
                e[0]++, e[1] += b;
                if (age > 300) e[2]++, e[3] += b;
            }
        }
        nx_log("gfx: memory: Metal textures: uploaded %.0f MB (%llu), empty %.0f MB (%llu), GPU-written %.0f MB (%llu), no data (depth/MSAA/...) %.0f MB (%llu); BC decoded %.0f MB",
               by[TEX_UPLOADED] / 1048576.0, n[TEX_UPLOADED], by[TEX_EMPTY] / 1048576.0, n[TEX_EMPTY], by[TEX_GPU] / 1048576.0, n[TEX_GPU],
               by[TEX_NODATA] / 1048576.0, n[TEX_NODATA], bc / 1048576.0);
        {   // uploaded MB by NVN format, largest first (which formats fill memory: BC decoded vs ASTC)
            char line[512];
            int o = 0;
            for (int k = 0; k < 8; k++) {
                int best = 0;
                for (int f = 1; f < 256; f++)
                    if (by_fmt[f] > by_fmt[best]) best = f;
                if (!best || by_fmt[best] < (1u << 20)) break;
                const NvnFmt *nf = nvn_fmt(best);
                o += snprintf(line + o, sizeof line - o, " %s %.0f MB,", nf ? nf->name : "?", by_fmt[best] / 1048576.0);
                by_fmt[best] = 0;
            }
            nx_log("gfx: memory: uploaded by format:%s", line);
        }
        if (getenv("NXRT_TEXGPUSTAT")) {
            NSArray *keys = [gpu_groups keysSortedByValueUsingComparator:^NSComparisonResult(NSMutableData *a, NSMutableData *b) {
                uint64_t x = ((uint64_t *)a.bytes)[1], y = ((uint64_t *)b.bytes)[1];
                return x > y ? NSOrderedAscending : x < y ? NSOrderedDescending : NSOrderedSame;
            }];
            for (NSUInteger i = 0; i < keys.count && i < 25; i++) {
                const uint64_t *e = ((NSMutableData *)gpu_groups[keys[i]]).bytes;
                nx_log("gfx: memory:   GPU-written %s: %llu textures %.1f MB, idle >300 frames %llu (%.1f MB)", [keys[i] UTF8String],
                       e[0], e[1] / 1048576.0, e[2], e[3] / 1048576.0);
            }
        }
    }
    nx_log("gfx: memory: Metal allocated %.0f MB, %lu cached NVN textures, %lu registered", g_dev.currentAllocatedSize / 1048576.0,
           (unsigned long)g_mtltex.count, (unsigned long)g_texreg.count);
    // Process footprint (what jetsam counts) and, on iOS, what is left before the app is killed.
    task_vm_info_data_t vi;
    mach_msg_type_number_t vn = TASK_VM_INFO_COUNT;
    double foot = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &vn) == KERN_SUCCESS ? vi.phys_footprint / 1048576.0 : -1;
#if TARGET_OS_IPHONE
    nx_log("gfx: memory: footprint %.0f MB, %.0f MB left before the limit", foot, os_proc_available_memory() / 1048576.0);
#else
    nx_log("gfx: memory: footprint %.0f MB", foot);
#endif
    void nx_mem_breakdown(char *out, size_t cap);
    char mb[1024];
    nx_mem_breakdown(mb, sizeof mb);
    nx_log("gfx: memory: %s", mb);
    void nx_malloc_hist(void);
    nx_malloc_hist();
    pthread_mutex_unlock(&g_tlock);
}

static int is_depth(MTLPixelFormat f) {
    return f == MTLPixelFormatDepth16Unorm || f == MTLPixelFormatDepth32Float || f == MTLPixelFormatStencil8 ||
           f == MTLPixelFormatDepth32Float_Stencil8;
}
static int is_compressed(int nvn) {
    const NvnFmt *f = nvn_fmt(nvn);
    return f && f->bw > 1;
}

MTLPixelFormat gfx_mtl_format(int nvn) { return mtl_for(nvn); }

// Content hash of a texture's storage. The game writes some textures with plain CPU stores and no
// flush (the 4096x4096 R8 glyph cache of the UI text), so CPU-writable storage is compared by hash.
// That runs on a background thread (hash_thread below): inline on the encode thread it read ~58 MB
// per frame (~12% of encode) and found nothing on the island.
static uint64_t content_hash(uintptr_t lo, uintptr_t hi) {
    const uint64_t *p = (const uint64_t *)lo, *e = (const uint64_t *)(lo + ((hi - lo) & ~7ul));
    uint64_t a = 0, b = 0, c = 0, d = 0;
    for (; p + 4 <= e; p += 4) a = (a ^ p[0]) * 0x100000001b3ull, b += p[1] ^ (b >> 7), c ^= p[2] + (c << 3), d += p[3] * 0x9E3779B97F4A7C15ull;
    for (; p < e; p++) a = (a ^ *p) * 0x100000001b3ull;
    return a ^ b * 31 ^ c * 131 ^ d * 1313;
}

// Upload what the pool holds (block-linear) into t, all levels and layers (3D too), except depth/stencil
// and multisample. Sets m->lo/hi and m->state.
static void upload_pool_body(id<MTLTexture> t, const TexRecord *r, TexMeta *m);
static int wp_arm(TexMeta *m);   // write tracking (below)
// Time spent in uploads / texture lookups (slow-encode diagnostics, gfx_cmd.m)
uint64_t g_tex_upload_ns, g_tex_upload_n, g_tex_upload_bytes, g_tex_lookup_ns;
static void upload_pool(id<MTLTexture> t, const TexRecord *r, TexMeta *m) {
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    upload_pool_body(t, r, m);
    g_tex_upload_ns += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;
    g_tex_upload_n++, g_tex_upload_n_stat++;
    if (m->state == TEX_UPLOADED) g_tex_upload_bytes += m->hi - m->lo, g_tex_upload_bytes_stat += m->hi - m->lo;
    static int at = -2, nf = 2;   // NXRT_UPLOADLOG=<frame>[:<frames>]: those frames' uploads (which textures arrive every frame)
    if (at == -2) {
        const char *e = getenv("NXRT_UPLOADLOG");
        at = e ? atoi(e) : -1;
        if (e && strchr(e, ':')) nf = atoi(strchr(e, ':') + 1);
    }
    extern volatile int g_gfx_frame;
    if (at >= 0 && g_gfx_frame >= at && g_gfx_frame < at + nf)
        nx_log("uploadlog: frame %d tex %p %dx%dx%d fmt %d levels %d layers %d state %d storage %#lx..%#lx (%lu KB) %.1f us", g_gfx_frame, r->tex,
               r->d.w, r->d.h, r->d.d, r->d.format, m->levels, m->layers, m->state, (unsigned long)m->lo, (unsigned long)m->hi,
               (unsigned long)((m->hi - m->lo) >> 10), (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e3);
}
static void upload_pool_body(id<MTLTexture> t, const TexRecord *r, TexMeta *m) {
    const NxTexDesc *d = &r->d;
    const NvnFmt *f = nvn_fmt(d->format);
    m->state = TEX_NODATA;
    if (!d->pool_data || is_depth(t.pixelFormat) || d->samples > 1) return;
    int bw = f->bw, bh = f->bh, bpb = f->bpb, levels = m->levels, layers = m->layers;
    if (t.textureType == MTLTextureType3D && bc_decoded(d->format)) {
        static int n;
        if (n++ < 4) nx_log("gfx: 3D BC texture %dx%dx%d not decoded (left empty)", d->w, d->h, d->d);
        return;
    }
    if (t.textureType == MTLTextureType3D && r->x.stride <= 0) {
        // 3D textures (the sky's 256x32x16 scattering table, a 32x32x32 grading LUT) were never uploaded: the sky
        // colour table came out black (grey sky). Block depth: smallest power of two holding the depth, up to 32
        // (like the block height rule); it halves per level while the level fits in half a block (Ryujinx).
        uint32_t depth = (uint32_t)MAX(d->d, 1);
        uint32_t hb0 = ((uint32_t)d->h + bh - 1) / bh;
        int gh = r->x.has_layout && r->x.layout[0] <= 5 ? 1 << r->x.layout[0] : nvn_gob_height(hb0), gd = 1;
        while (gd < 32 && (uint32_t)gd < depth) gd <<= 1;
        // Block size is capped: the 256x32x16 sky table is laid out with 1-GOB-high blocks 16 deep (offline
        // roughness test of every block height / depth; gh 4 scrambled it into a near-black, blue-less table).
        while (!r->x.has_layout && gh > 1 && gh * gd > 16) gh >>= 1;
        uint64_t total = 0;
        for (int l = 0, mgd = gd; l < levels; l++) {
            uint32_t mw = MAX(1u, (uint32_t)d->w >> l), mh = MAX(1u, (uint32_t)d->h >> l), md = MAX(1u, depth >> l);
            uint32_t wb = (mw + bw - 1) / bw, hb = (mh + bh - 1) / bh;
            if (l > 0) while (mgd > 1 && md <= (uint32_t)(mgd >> 1)) mgd >>= 1;
            total += surface_size3d(wb, hb, md, bpb, nvn_mip_gob_height(gh, hb), mgd);
        }
        if (total > d->pool_avail) return;
        m->lo = (uintptr_t)d->pool_data, m->hi = (uintptr_t)d->pool_data + total;
        m->cpu_pool = (d->pool_flags & 6) != 0;
        if (m->cpu_pool) {
            extern volatile int g_gfx_frame;
            m->hash = content_hash(m->lo, m->hi), m->frame_hashed = g_gfx_frame;
        }
        if (!nonzero(d->pool_data, total)) { m->state = TEX_EMPTY; return; }
        m->state = TEX_UPLOADED;
        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        uint64_t off = 0;
        for (int l = 0, mgd = gd; l < levels; l++) {
            uint32_t mw = MAX(1u, (uint32_t)d->w >> l), mh = MAX(1u, (uint32_t)d->h >> l), md = MAX(1u, depth >> l);
            uint32_t wb = (mw + bw - 1) / bw, hb = (mh + bh - 1) / bh;
            if (l > 0) while (mgd > 1 && md <= (uint32_t)(mgd >> 1)) mgd >>= 1;
            int mgh = nvn_mip_gob_height(gh, hb);
            id<MTLBuffer> lin = [g_dev newBufferWithLength:(NSUInteger)wb * hb * md * bpb options:MTLResourceStorageModeShared];
            deswizzle3d(d->pool_data + off, lin.contents, wb, hb, md, bpb, mgh, mgd);
            if (getenv("NXRT_TEX3DRAW") && l == 0) {   // raw storage of the level for offline layout checks
                char fn[600];
                snprintf(fn, sizeof fn, "%s/tex3d_%dx%dx%d_bpb%d.raw", getenv("NXRT_TEX3DRAW"), d->w, d->h, (int)depth, bpb);
                FILE *fp = fopen(fn, "wb");
                if (fp) fwrite(d->pool_data, 1, MIN(d->pool_avail, (uint64_t)4 << 20), fp), fclose(fp);
            }
            if (getenv("NXRT_TEX3DLOG") && bpb == 8 && f->bw == 1) {   // RGBA16F: per slice max R and the R at x = 0,64,128,192 of row 16
                const __fp16 *h = lin.contents;
                for (uint32_t z = 0; z < md && z < 16; z++) {
                    float mx = 0;
                    for (uint64_t q = 0; q < (uint64_t)wb * hb; q++) mx = fmaxf(mx, (float)h[((uint64_t)z * wb * hb + q) * 4]);
                    uint64_t r16 = ((uint64_t)z * hb + MIN(16u, hb - 1)) * wb;
                    nx_log("tex3d: %p level %d slice %u: max R %g; row 16 R: %g %g %g %g (gh %d gd %d)", r->tex, l, z, mx, (float)h[(r16 + 0) * 4],
                           (float)h[(r16 + MIN(64u, wb - 1)) * 4], (float)h[(r16 + MIN(128u, wb - 1)) * 4], (float)h[(r16 + MIN(192u, wb - 1)) * 4], mgh, mgd);
                }
            }
            [blit copyFromBuffer:lin sourceOffset:0 sourceBytesPerRow:(NSUInteger)wb * bpb sourceBytesPerImage:(NSUInteger)wb * hb * bpb
                      sourceSize:MTLSizeMake(mw, mh, md) toTexture:t destinationSlice:0 destinationLevel:l destinationOrigin:MTLOriginMake(0, 0, 0)];
            off += surface_size3d(wb, hb, md, bpb, mgh, mgd);
        }
        [blit endEncoding];
        [cmd commit];
        return;
    }
    if (t.textureType == MTLTextureType3D) return;
    uint32_t height = (uint32_t)t.height;
    if (r->x.stride > 0) {   // linear (pitch) texture, e.g. the UI glyph cache: one level, rows `stride` apart
        uint32_t wb = (d->w + bw - 1) / bw, hb = (height + bh - 1) / bh;
        uint64_t row = (uint64_t)wb * bpb, size = (uint64_t)r->x.stride * (hb - 1) + row;
        if (row > (uint64_t)r->x.stride || size > d->pool_avail) return;
        m->lo = (uintptr_t)d->pool_data, m->hi = (uintptr_t)d->pool_data + size;
        m->cpu_pool = (d->pool_flags & 6) != 0;
        m->bg_volatile = 1;   // linear textures are the ones the CPU writes (glyph cache): short hash interval
        m->wp = wp_arm(m);    // before reading it: writes from here on mark it dirty
        if (m->cpu_pool) {
            extern volatile int g_gfx_frame;
            m->hash = content_hash(m->lo, m->hi), m->frame_hashed = g_gfx_frame;
        }
        if (!nonzero(d->pool_data, size)) { m->state = TEX_EMPTY; return; }
        m->state = TEX_UPLOADED;
        id<MTLBuffer> lin = [g_dev newBufferWithLength:row * hb options:MTLResourceStorageModeShared];
        for (uint32_t y = 0; y < hb; y++) memcpy((uint8_t *)lin.contents + y * row, d->pool_data + (uint64_t)y * r->x.stride, row);
        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        if (bc_decoded(d->format)) {
            id<MTLComputeCommandEncoder> ce = [cmd computeCommandEncoder];
            gfx_bc_decode(ce, lin, 0, row, mtl_raw(d->format), t, 0, 0, 0, 0, d->w, height);
            [ce endEncoding];
            [cmd commit];
            return;
        }
        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        [blit copyFromBuffer:lin sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:row * hb
                  sourceSize:MTLSizeMake(d->w, height, 1) toTexture:t destinationSlice:0 destinationLevel:0
           destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        [cmd commit];
        return;
    }
    uint32_t hb0 = ((d->target == 0 || d->target == 3 ? 1 : d->h) + bh - 1) / bh;
    int gh = r->x.has_layout && r->x.layout[0] <= 5 ? 1 << r->x.layout[0] : nvn_gob_height(hb0);
    uint64_t layer_size = 0;
    for (int l = 0; l < levels; l++) {
        uint32_t mw = d->w >> l ? d->w >> l : 1, mh = height >> l ? height >> l : 1;
        uint32_t wb = (mw + bw - 1) / bw, hb = (mh + bh - 1) / bh;
        layer_size += nvn_surface_size(wb, hb, bpb, nvn_mip_gob_height(gh, hb));
    }
    if (layers > 1) layer_size = (layer_size + 512ull * gh - 1) / (512ull * gh) * (512ull * gh);
    if (layer_size * layers > d->pool_avail) return;
    m->lo = (uintptr_t)d->pool_data, m->hi = (uintptr_t)d->pool_data + layer_size * layers;
    m->cpu_pool = (d->pool_flags & 6) != 0;
    if (m->cpu_pool) {
        extern volatile int g_gfx_frame;
        m->hash = content_hash(m->lo, m->hi), m->frame_hashed = g_gfx_frame;
    }
    // Empty storage: nothing to upload yet. Checked whole: checking only the first 4 KB marked masks
    // and UI art with a transparent top edge (e.g. the menu's 321x1628 wave mask) empty forever.
    if (!nonzero(d->pool_data, layer_size * layers)) { m->state = TEX_EMPTY; return; }
    m->state = TEX_UPLOADED;
    id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
    int dec = bc_decoded(d->format);
    id<MTLBlitCommandEncoder> blit = dec ? nil : [cmd blitCommandEncoder];
    id<MTLComputeCommandEncoder> ce = dec ? [cmd computeCommandEncoder] : nil;
    for (int layer = 0; layer < layers; layer++) {
        uint64_t off = layer * layer_size;
        for (int l = 0; l < levels; l++) {
            uint32_t mw = d->w >> l ? d->w >> l : 1, mh = height >> l ? height >> l : 1;
            uint32_t wb = (mw + bw - 1) / bw, hb = (mh + bh - 1) / bh;
            int mgh = nvn_mip_gob_height(gh, hb);
            id<MTLBuffer> lin = [g_dev newBufferWithLength:(NSUInteger)wb * hb * bpb options:MTLResourceStorageModeShared];
            deswizzle(d->pool_data + off, lin.contents, wb, hb, bpb, mgh);
            if (dec) {
                gfx_bc_decode(ce, lin, 0, (NSUInteger)wb * bpb, mtl_raw(d->format), t, layer, l, 0, 0, mw, mh);
                off += nvn_surface_size(wb, hb, bpb, mgh);
                continue;
            }
            [blit copyFromBuffer:lin sourceOffset:0 sourceBytesPerRow:(NSUInteger)wb * bpb
                  sourceBytesPerImage:(NSUInteger)wb * hb * bpb sourceSize:MTLSizeMake(mw, mh, 1)
                            toTexture:t destinationSlice:layer destinationLevel:l
                    destinationOrigin:MTLOriginMake(0, 0, 0)];
            off += nvn_surface_size(wb, hb, bpb, mgh);
        }
    }
    [blit endEncoding];
    [ce endEncoding];
    [cmd commit];
}

// ---- write tracking of CPU-written linear textures (the UI glyph cache) ----------------------------------
// The game draws new letters into the 4096x4096 R8 glyph cache with plain stores and no flush, then draws them the
// same frame. The background hash noticed only 1-4+ passes later: freshly drawn text showed with letters missing for a
// frame or more (the X menu opening: "esidents", "ouses", clock digits). Now the storage's whole pages are read-only
// after each upload; the first write faults (crash.c -> gfx_wp_fault), which marks it dirty and opens the pages
// again, and the next lookup re-uploads. NXRT_NOTEXWP=1: off (hash only, old).
enum { WP_MAX = 16 };
static struct { uintptr_t lo, hi; volatile int dirty, armed; } g_wp[WP_MAX];
static volatile int g_nwp;
static int wp_on(void) {
    static int on = -1;
    if (on < 0) on = !getenv("NXRT_NOTEXWP");
    return on;
}
// Signal handler (any thread): a write to tracked pages.
int gfx_wp_fault(uintptr_t a) {
    int n = g_nwp;
    for (int i = 0; i < n; i++)
        if (a >= g_wp[i].lo && a < g_wp[i].hi) {
            g_wp[i].dirty = 1, g_wp[i].armed = 0;
            mprotect((void *)g_wp[i].lo, g_wp[i].hi - g_wp[i].lo, PROT_READ | PROT_WRITE);
            return 1;
        }
    return 0;
}
// Before an upload reads the storage: whole pages inside [lo, hi) read-only (later writes fault). Slot + 1, 0 = not tracked.
static int wp_arm(TexMeta *m) {
    if (!wp_on() || !m->cpu_pool) return 0;
    uintptr_t pg = (uintptr_t)getpagesize(), lo = (m->lo + pg - 1) & ~(pg - 1), hi = m->hi & ~(pg - 1);
    if (hi <= lo) return 0;
    int i = 0, n = g_nwp;
    while (i < n && !(g_wp[i].lo == lo && g_wp[i].hi == hi)) i++;
    if (i == n) {
        if (n == WP_MAX) return 0;
        g_wp[n].lo = lo, g_wp[n].hi = hi, g_wp[n].dirty = 0, g_wp[n].armed = 0;
        __atomic_store_n(&g_nwp, n + 1, __ATOMIC_RELEASE);
        nx_log("gfx: write-tracking texture storage %#lx-%#lx (%lu KB)", (unsigned long)lo, (unsigned long)hi, (unsigned long)((hi - lo) >> 10));
    }
    g_wp[i].dirty = 0;
    if (!g_wp[i].armed && !mprotect((void *)lo, hi - lo, PROT_READ)) g_wp[i].armed = 1;
    return i + 1;
}

// Has the CPU changed the texture's storage since its upload? Lock held.
static int storage_changed(TexMeta *m) {
    extern volatile int g_gfx_frame;
    int changed = 0;
    // Still-empty storage is re-checked whole, every 1 + size/256 KB frames (large empty textures stay cheap).
    if (m->state == TEX_EMPTY && g_gfx_frame - m->frame_checked >= 1 + (int)((m->hi - m->lo) >> 18)) {
        m->frame_checked = g_gfx_frame;
        changed = nonzero((const uint8_t *)m->lo, m->hi - m->lo);
    }
    // hash_thread saw new content. Not for GPU-written textures: the hash job may have been snapshotted
    // before the GPU wrote the texture (a one-time bake, e.g. Mii face textures), and re-uploading the pool
    // then wiped the bake for good.
    if (m->bg_changed) changed = m->state != TEX_GPU, m->bg_changed = 0;
    if (m->wp && g_wp[m->wp - 1].dirty && m->state != TEX_GPU) changed = 1;
    if (m->state == TEX_UPLOADED && m->seq != g_dirty_seq) {
        uint64_t from = g_dirty_seq - m->seq > DIRTY_RING ? g_dirty_seq - DIRTY_RING : m->seq;
        for (uint64_t q = from; q < g_dirty_seq && !changed; q++)
            changed = g_dirty[q % DIRTY_RING].lo < m->hi && g_dirty[q % DIRTY_RING].hi > m->lo;
    }
    m->seq = g_dirty_seq;
    return changed;
}

// Diagnostics: cache state (TEX_*, -1 none) and the storage range the upload reads.
int gfx_texture_state(const void *tex, uintptr_t *lo, uintptr_t *hi) {
    int st = -1;
    pthread_mutex_lock(&g_tlock);
    NSArray *hit = g_mtltex ? [g_mtltex objectForKey:KEY(tex)] : nil;
    if (hit) {
        const TexMeta *m = ((NSMutableData *)hit[0]).bytes;
        st = m->state, *lo = m->lo, *hi = m->hi;
    }
    pthread_mutex_unlock(&g_tlock);
    return st;
}

// The GPU writes this texture (render target, copy/clear destination) or it was filled with
// WriteTexels: its Metal texture is the truth, never re-upload it from the pool.
void gfx_texture_mark_gpu(const void *tex) {
    if (!tex) return;
    static int ww = -1, wh, wf = -1;   // NXRT_TEXWATCH_SIZE=<w>x<h>[:<fmt>]: log GPU writes (render target, copy, clear, WriteTexels) to such textures
    if (ww < 0 && !(getenv("NXRT_TEXWATCH_SIZE") && sscanf(getenv("NXRT_TEXWATCH_SIZE"), "%dx%d:%d", &ww, &wh, &wf) >= 2)) ww = 0;
    if (ww) {
        NxTexDesc d = {0};
        nx_nvn_texture_desc(tex, &d);
        static int n;
        if (d.w == ww && d.h == wh && (wf < 0 || d.format == wf) && n++ < 200) {
            extern volatile int g_gfx_frame;
            Dl_info di = {0};
            dladdr(__builtin_return_address(0), &di);
            nx_log("texwatch: frame %d %p %dx%d fmt %d written by %s", g_gfx_frame, tex, d.w, d.h, d.format, di.dli_sname ? di.dli_sname : "?");
        }
    }
    pthread_mutex_lock(&g_tlock);
    NSArray *hit = g_mtltex ? [g_mtltex objectForKey:KEY(tex)] : nil;
    if (hit) ((TexMeta *)((NSMutableData *)hit[0]).mutableBytes)->state = TEX_GPU;
    pthread_mutex_unlock(&g_tlock);
}

// The game renders into some textures whose storage is CPU-readable (CPU_CACHED / CPU_UNCACHED pool) and reads
// the texels back (island picking: 32x128 targets read at main+0x2128fc). Our render targets live only in Metal,
// so those reads saw zeros; gfx_cmd.m copies such targets back after their pass using this layout.
int gfx_texture_readback_info(const void *tex, NxReadback *out) {
    NxTexDesc d = {0};
    nx_nvn_texture_desc(tex, &d);
    if (!(d.pool_flags & 6) || !d.pool_data || d.samples > 1 || d.target == 2) return 0;
    const NvnFmt *f = nvn_fmt(d.format);
    if (!f || f->bw != 1 || f->bh != 1 || d.w <= 0 || d.h <= 0) return 0;
    int64_t stride = 0;
    int has_layout = 0;
    uint8_t layout0 = 0;
    pthread_mutex_lock(&g_tlock);
    NSMutableData *rd = g_texreg ? [g_texreg objectForKey:KEY(tex)] : nil;
    if (rd) {
        const TexRecord *r = rd.bytes;
        stride = r->x.stride, has_layout = r->x.has_layout, layout0 = r->x.layout[0];
    }
    pthread_mutex_unlock(&g_tlock);
    int gh = has_layout && layout0 <= 5 ? 1 << layout0 : nvn_gob_height((uint32_t)d.h);
    uint64_t need = stride > 0 ? (uint64_t)stride * (d.h - 1) + (uint64_t)d.w * f->bpb : nvn_surface_size(d.w, d.h, f->bpb, gh);
    if (stride > 0 && stride < (int64_t)d.w * f->bpb) return 0;
    int h = d.h;
    // A pitch-linear target running past its pool's end: copy back the rows inside the pool. The island picking
    // targets (32x128 RG8, LINEAR_RENDER_TARGET, stride 256) sit 0x2000 apart in a 0x10000 pool and overlap; the
    // game reads only the first 32 rows of each, the frame after rendering it. The one at +0xa000 was skipped
    // whole while its neighbour's copy-back overwrote its rows, so every other frame the game decoded a stale
    // pick (phantom hover cards while panning).
    if (stride > 0 && need > d.pool_avail && d.pool_avail >= (uint64_t)d.w * f->bpb) {
        h = (int)((d.pool_avail - (uint64_t)d.w * f->bpb) / (uint64_t)stride) + 1;
        need = (uint64_t)stride * (h - 1) + (uint64_t)d.w * f->bpb;
    }
    if (need > d.pool_avail) return 0;
    *out = (NxReadback){(uint8_t *)d.pool_data, need, d.w, h, f->bpb, gh, stride};
    return 1;
}
void gfx_texture_store(const NxReadback *rb, const uint8_t *lin) {
    if (rb->stride > 0)
        for (int y = 0; y < rb->h; y++) memcpy(rb->dst + (uint64_t)y * rb->stride, lin + (uint64_t)y * rb->w * rb->bpb, (size_t)rb->w * rb->bpb);
    else
        swizzle(lin, rb->dst, rb->w, rb->h, rb->bpb, rb->gh);
}

// Background content hashing of CPU-writable texture storage: snapshot the candidates under g_tlock,
// hash without it, then flag a texture only if it is still the same upload (serial and stored hash
// unchanged). A flagged texture is re-uploaded at its next use (storage_changed). NXRT_NOTEXHASH=1: off.
// Each texture backs off while it stays unchanged (interval doubles up to HASH_MAX_INTERVAL passes,
// ~1 s at HASH_PASS_US) and is checked every pass again once it changes, so the glyph cache stays responsive while
// static textures cost little memory bandwidth (checking everything every pass read ~460 MB/frame).
enum { HASH_PASS_US = 16000, HASH_MAX_INTERVAL = 64, HASH_VOLATILE_INTERVAL = 4 };
static void *hash_thread(void *arg) {
    typedef struct { const void *tex; uint64_t serial, hash; uintptr_t lo, hi; int changed; } Job;
    Job *jobs = NULL;
    size_t cap = 0;
    // Efficiency cores: with default QoS this thread competed with the game's threads, and draws of
    // meshes the game had not finished preparing went from <1 to ~5-9 per frame (NXRT_VCHECK=1).
    pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0);
    for (uint32_t pass = 1;; pass++) {
        @autoreleasepool {
            size_t n = 0;
            pthread_mutex_lock(&g_tlock);
            for (id k in g_mtltex) {
                NSArray *v = [g_mtltex objectForKey:k];
                const TexMeta *m = ((NSMutableData *)v[0]).bytes;
                if (!m->cpu_pool || m->bg_changed || (m->state != TEX_UPLOADED && m->state != TEX_EMPTY) || m->hi <= m->lo) continue;
                if ((int32_t)(pass - m->bg_next) < 0) continue;
                if (n == cap) cap = cap ? cap * 2 : 1024, jobs = realloc(jobs, cap * sizeof *jobs);
                jobs[n++] = (Job){(__bridge const void *)k, m->serial, m->hash, m->lo, m->hi, 0};
            }
            pthread_mutex_unlock(&g_tlock);
            uint64_t bytes = 0;
            for (size_t i = 0; i < n; i++) {
                bytes += jobs[i].hi - jobs[i].lo;
                jobs[i].changed = content_hash(jobs[i].lo, jobs[i].hi) != jobs[i].hash;
            }
            pthread_mutex_lock(&g_tlock);
            for (size_t i = 0; i < n; i++) {
                NSArray *v = [g_mtltex objectForKey:KEY(jobs[i].tex)];
                TexMeta *m = v ? ((NSMutableData *)v[0]).mutableBytes : NULL;
                if (!m || m->serial != jobs[i].serial || m->hash != jobs[i].hash) continue;   // re-uploaded meanwhile
                if (jobs[i].changed) m->bg_changed = 1, m->bg_interval = 1, m->bg_volatile = 1;
                else m->bg_interval = m->bg_interval ? MIN(m->bg_interval * 2, m->bg_volatile ? HASH_VOLATILE_INTERVAL : HASH_MAX_INTERVAL) : 1;
                m->bg_next = pass + m->bg_interval;
            }
            pthread_mutex_unlock(&g_tlock);
            __atomic_fetch_add(&g_hashed_bytes_stat, bytes, __ATOMIC_RELAXED);
        }
        usleep(HASH_PASS_US);
    }
    return arg;
}

// ---- storage aliasing ---------------------------------------------------------------------
// Several NVN textures can describe the same storage: the engine renders depth into a DEPTH32F_STENCIL8
// target and reads it through a separate DEPTH32F texture (linear depth for grading, AO, water...). On the
// Switch they share memory; here each NVN texture had its own Metal texture, so the reading one stayed
// empty (no data). Now the first texture created at a storage (pool, offset) is the primary, and later
// ones of the same size use its Metal texture: the same object (same format, or both depth: sampling
// depth+stencil as depth works), or a format view (same bytes per pixel). A depth+stencil texture
// takes over from a depth-only primary. NXRT_NOALIAS=1: off. g_tlock held throughout.
typedef struct { const void *pool; int64_t offset; const void *tex; int format; } AliasEnt;
static NSMutableDictionary<NSNumber *, NSData *> *g_alias;
// The storage's Metal texture, kept after the NVN texture that made it is finalized. The engine re-creates its
// per-frame render-target objects (a new NVNtexture at the same storage every frame or two); when the first one
// died its entry went, the next object got a fresh empty Metal texture while objects from the frame before kept
// the old one: one storage, two images. The island's Mii visibility test then sampled a frame-old ID buffer on
// alternate frames (portraits popping above Miis while panning).
static NSMutableDictionary<NSNumber *, id<MTLTexture>> *g_alias_mtl;
static NSNumber *alias_key(const void *pool, int64_t off) { return @((uint64_t)(uintptr_t)pool * 0x9E3779B97F4A7C15ull ^ (uint64_t)off); }
// Formats ever registered at each storage (gfx_texture_init, g_tlock held). MTLTextureUsagePixelFormatView turns off
// the GPU's lossless compression of a texture (every render-target load/store and sample then moves full bandwidth),
// so a texture only gets it when its storage is also used with a format other than its own or its sRGB twin (an
// alias format view, alias_lookup). Swizzle, level and sRGB views don't need it. Island, Mac: GPU busy -14%.
// NXRT_PFV=1: every texture keeps it (the old behaviour).
static NSMutableDictionary<NSNumber *, NSMutableSet<NSNumber *> *> *g_fmt_at;
static uint64_t g_pfv_missed;
// Keyed by storage and size: alias_lookup only shares same-size textures (the engine's transient render targets reuse
// storage at other sizes and formats every frame; those never alias).
static NSNumber *fmt_at_key(const NxTexDesc *d) {
    return @(alias_key(d->pool, d->offset).unsignedLongLongValue ^ ((uint64_t)d->w << 40 | (uint64_t)d->h << 20) * 0xBF58476D1CE4E5B9ull);
}
static void fmt_at_note(const NxTexDesc *d) {
    if (!d->pool) return;
    if (!g_fmt_at) g_fmt_at = [NSMutableDictionary new];
    NSNumber *k = fmt_at_key(d);
    NSMutableSet *s = g_fmt_at[k];
    if (!s) g_fmt_at[k] = s = [NSMutableSet set];
    [s addObject:@(d->format)];
}
static int srgb_twin(MTLPixelFormat a, MTLPixelFormat b) {
    static const MTLPixelFormat pairs[][2] = {{MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm_sRGB},
                                               {MTLPixelFormatBGRA8Unorm, MTLPixelFormatBGRA8Unorm_sRGB}};
    if (a == b) return 1;
    for (int i = 0; i < 2; i++)
        if ((a == pairs[i][0] && b == pairs[i][1]) || (a == pairs[i][1] && b == pairs[i][0])) return 1;
    return 0;
}
// A new compressible texture with no uploaded content: fresh uncompressed memory reads as zeros (what the game got so
// far), compressed memory as garbage (dark boxes behind the X/Y prompts, magenta past the window crop): clear it.
static void clear_new(id<MTLTexture> t) {
    id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
    NSUInteger slices = t.textureType == MTLTextureType3D ? 0
                      : t.arrayLength * (t.textureType == MTLTextureTypeCube || t.textureType == MTLTextureTypeCubeArray ? 6 : 1);
    for (NSUInteger l = 0; l < t.mipmapLevelCount; l++)
        for (NSUInteger s = 0; s < (slices ? slices : MAX(1, t.depth >> l)); s++) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            if (is_depth(t.pixelFormat)) {
                if (t.pixelFormat != MTLPixelFormatStencil8) {
                    rp.depthAttachment.texture = t, rp.depthAttachment.level = l, rp.depthAttachment.slice = s;
                    rp.depthAttachment.loadAction = MTLLoadActionClear, rp.depthAttachment.clearDepth = 0;
                    rp.depthAttachment.storeAction = MTLStoreActionStore;
                }
                if (t.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 || t.pixelFormat == MTLPixelFormatStencil8) {
                    rp.stencilAttachment.texture = t, rp.stencilAttachment.level = l, rp.stencilAttachment.slice = s;
                    rp.stencilAttachment.loadAction = MTLLoadActionClear, rp.stencilAttachment.clearStencil = 0;
                    rp.stencilAttachment.storeAction = MTLStoreActionStore;
                }
            } else {
                rp.colorAttachments[0].texture = t, rp.colorAttachments[0].level = l;
                if (slices) rp.colorAttachments[0].slice = s; else rp.colorAttachments[0].depthPlane = s;
                rp.colorAttachments[0].loadAction = MTLLoadActionClear, rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            }
            [[cmd renderCommandEncoderWithDescriptor:rp] endEncoding];
            g_clear_new_passes++;
            g_clear_new_bytes += (uint64_t)MAX(1, t.width >> l) * MAX(1, t.height >> l) * 4;
        }
    [cmd commit];
    g_clear_new_n++;
}
static int needs_pfv(const NxTexDesc *d, MTLPixelFormat pf) {
    static int all = -1;
    if (all < 0) all = getenv("NXRT_PFV") != NULL;
    if (all || is_compressed(d->format) || bc_decoded(d->format) || d->format == 64) return 1;   // 64: not renderable (no zero clear)
    if (!d->pool || !g_fmt_at) return 0;
    for (NSNumber *f in g_fmt_at[fmt_at_key(d)])
        if (!srgb_twin(mtl_for(f.intValue), pf)) return 1;
    return 0;
}
// NVN textures currently using each storage's Metal texture (owner included).
static NSMutableDictionary<NSNumber *, NSMutableSet<NSValue *> *> *g_alias_users;
static void alias_use(NSNumber *k, const void *tex) {
    if (!g_alias_users) g_alias_users = [NSMutableDictionary new];
    NSMutableSet *u = g_alias_users[k];
    if (!u) g_alias_users[k] = u = [NSMutableSet set];
    [u addObject:[NSValue valueWithPointer:tex]];
}
// The owner goes: another NVN texture still using the storage's Metal texture takes over; with none left the
// entry and the texture go.
static void alias_forget(const void *tex) {
    if (!g_alias) return;
    NxTexDesc d;
    nx_nvn_texture_desc(tex, &d);
    if (!d.pool) return;
    NSNumber *k = alias_key(d.pool, d.offset);
    NSMutableSet *u = g_alias_users[k];
    [u removeObject:[NSValue valueWithPointer:tex]];
    NSData *v = g_alias[k];
    if (!v || ((const AliasEnt *)v.bytes)->tex != tex) return;
    NSValue *heir = u.anyObject;
    if (!heir) {
        [g_alias removeObjectForKey:k];
        [g_alias_mtl removeObjectForKey:k];
        [g_alias_users removeObjectForKey:k];
        return;
    }
    AliasEnt e = *(const AliasEnt *)v.bytes;
    NxTexDesc hd;
    nx_nvn_texture_desc(heir.pointerValue, &hd);
    e.tex = heir.pointerValue, e.format = hd.format;
    g_alias[k] = [NSData dataWithBytes:&e length:sizeof e];
}
// Another NVN texture still uses the Metal texture at this storage (after alias_forget of the finalized one).
static int alias_in_use(const NxTexDesc *d) {
    if (!g_alias || !d->pool) return 0;
    return g_alias[alias_key(d->pool, d->offset)] != nil;
}
static int has_stencil(MTLPixelFormat f) {
#if TARGET_OS_OSX
    if (f == MTLPixelFormatDepth24Unorm_Stencil8) return 1;
#endif
    return f == MTLPixelFormatDepth32Float_Stencil8;
}
static uint64_t g_alias_shared, g_alias_views, g_alias_takeovers;
// A Metal texture of another NVN texture at the same storage that `tex` can use, or nil (then `tex` gets its
// own and may become the primary).
static id<MTLTexture> alias_lookup(const void *tex, const NxTexDesc *d, MTLPixelFormat pf, int *takeover) {
    static int off = -1;
    if (off < 0) off = getenv("NXRT_NOALIAS") != NULL;
    *takeover = 0;
    if (off || !d->pool) return nil;
    if (!g_alias) g_alias = [NSMutableDictionary new];
    NSNumber *k = alias_key(d->pool, d->offset);
    NSData *v = g_alias[k];
    const AliasEnt *e = v.bytes;
    static int dbg = -1, ndbg;
    if (dbg < 0) dbg = getenv("NXRT_ALIASDBG") != NULL;
    if (dbg && is_depth(pf) && ndbg++ < 200)
        nx_log("aliasdbg: depth texture %p %dx%d fmt %d pool %p +%#llx: primary %p (fmt %d)", tex, d->w, d->h, d->format, d->pool,
               (unsigned long long)d->offset, e ? e->tex : NULL, e ? e->format : -1);
    if (!e || e->pool != d->pool || e->offset != d->offset || e->tex == tex) return nil;
    id<MTLTexture> pt = g_alias_mtl[k];
    if (!pt && e->tex) {
        NSArray *ph = [g_mtltex objectForKey:KEY(e->tex)];
        pt = ph && ph[1] != [NSNull null] ? ph[1] : nil;
    }
    if (!pt || (int)pt.width != d->w || (int)pt.height != (d->target == 0 || d->target == 3 ? 1 : d->h)) {
        if (dbg && pt && ndbg++ < 200)
            nx_log("aliasdbg: texture %p %dx%d fmt %d shares storage with %p %lux%lu fmt %d: not aliased (size / format)", tex, d->w, d->h,
                   d->format, e->tex, (unsigned long)pt.width, (unsigned long)pt.height, e->format);
        return nil;
    }
    MTLPixelFormat ppf = pt.pixelFormat;
    id<MTLTexture> use = nil;
    const char *how = "shared";
    if (ppf == pf) use = pt;
    else if (is_depth(pf) && is_depth(ppf)) {
        if (has_stencil(pf) && !has_stencil(ppf)) { *takeover = 1; return nil; }
        use = pt;
    } else if (!is_depth(pf) && !is_depth(ppf) && !is_compressed(d->format) && !is_compressed(e->format) &&
               nvn_fmt(d->format) && nvn_fmt(e->format) && nvn_fmt(d->format)->bpb == nvn_fmt(e->format)->bpb) {
        if (!(pt.usage & MTLTextureUsagePixelFormatView) && !srgb_twin(ppf, pf)) {   // registered after the primary was made
            if (g_pfv_missed++ < 20)
                nx_log("gfx: alias: texture %p (fmt %d) can't view %p (fmt %d) without PixelFormatView: own texture", tex, d->format, e->tex, e->format);
            return nil;
        }
        use = [pt newTextureViewWithPixelFormat:pf];
        how = "format view";
    }
    if (!use) {
        if (dbg && ndbg++ < 200)
            nx_log("aliasdbg: texture %p %dx%d fmt %d shares storage with %p %lux%lu fmt %d: not aliased (size / format)", tex, d->w, d->h,
                   d->format, e->tex, (unsigned long)pt.width, (unsigned long)pt.height, e->format);
        return nil;
    }
    // Mip levels: a texture needing more levels than the shared Metal texture has takes over the storage (the
    // portrait encoder's 256x256 source shared a 1-level texture, so its mip draws were dropped); one needing
    // fewer gets a view of just its levels (never samples mips it doesn't have).
    int want = d->levels > 0 ? d->levels : 1, maxl = 1;
    while ((MAX(d->w, d->h) >> maxl) > 0) maxl++;
    want = MIN(want, maxl);
    if (want > (int)pt.mipmapLevelCount) {
        static int nt;
        if (nt++ < 20)
            nx_log("gfx: alias: texture %p (%dx%d fmt %d, %d levels) takes over storage from %p (%lu levels)", tex, d->w, d->h, d->format, want,
                   e->tex, (unsigned long)pt.mipmapLevelCount);
        *takeover = 1;
        return nil;
    }
    if (want < (int)pt.mipmapLevelCount && (pt.textureType == MTLTextureType2D || pt.textureType == MTLTextureType2DArray)) {
        id<MTLTexture> lv = [pt newTextureViewWithPixelFormat:use.pixelFormat textureType:pt.textureType levels:NSMakeRange(0, want)
                                                       slices:NSMakeRange(0, pt.arrayLength)];
        if (lv) use = lv, how = "level view";
    }
    alias_use(k, tex);
    if (use == pt) g_alias_shared++; else g_alias_views++;
    static int nlog;
    if (nlog++ < 40)
        nx_log("gfx: alias: texture %p (%dx%d fmt %d) uses %p's Metal texture (%s, NVN fmt %d) at the same storage", tex, d->w, d->h,
               d->format, e->tex, how, e->format);
    return use;
}
static void alias_set_primary(const void *tex, const NxTexDesc *d, int takeover, id<MTLTexture> t) {
    if (!d->pool || !g_alias) return;
    if (!g_alias_mtl) g_alias_mtl = [NSMutableDictionary new];
    NSNumber *k = alias_key(d->pool, d->offset);
    NSData *v = g_alias[k];
    const AliasEnt *e = v.bytes;
    if (e && e->tex && e->tex != tex && !takeover && [g_mtltex objectForKey:KEY(e->tex)]) return;   // keep the live primary
    if (e && e->tex && takeover) {   // the old primary re-resolves to this one at its next use
        NSArray *old = [g_mtltex objectForKey:KEY(e->tex)];
        [g_mtltex removeObjectForKey:KEY(e->tex)];
        if (old && old[1] != [NSNull null]) gfx_texture_dropped(old[1]);
        g_alias_takeovers++;
        nx_log("gfx: alias: texture %p (fmt %d) takes over storage from %p (fmt %d)", tex, d->format, e->tex, e->format);
    }
    AliasEnt n = {d->pool, d->offset, tex, d->format};
    g_alias[k] = [NSData dataWithBytes:&n length:sizeof n];
    g_alias_mtl[k] = t;
    [g_alias_users removeObjectForKey:k];   // a new image at this storage: earlier users keep the old one
    alias_use(k, tex);
}

static id<MTLTexture> texture_mtl(const void *tex);
static int swap_restore(const void *tex, uint64_t serial, id<MTLTexture> t);
static void swap_forget(const void *tex);
id<MTLTexture> gfx_texture_mtl(const void *tex) {
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    id<MTLTexture> t = texture_mtl(tex);
    uint64_t dt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;
    g_tex_lookup_ns += dt;
    __atomic_fetch_add(&g_tex_lookup_n_stat, 1, __ATOMIC_RELAXED), __atomic_fetch_add(&g_tex_lookup_ns_stat, dt, __ATOMIC_RELAXED);
    return t;
}
static id<MTLTexture> texture_mtl(const void *tex) {
    if (!tex) return nil;
    @autoreleasepool {
        reg_init();
        static int hash_started;
        if (!__atomic_exchange_n(&hash_started, 1, __ATOMIC_ACQ_REL) && !getenv("NXRT_NOTEXHASH")) {
            pthread_t th;
            pthread_create(&th, NULL, hash_thread, NULL);
            pthread_detach(th);
        }
        pthread_mutex_lock(&g_tlock);
        if (!g_mtltex)
            g_mtltex = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                                             valueOptions:NSPointerFunctionsStrongMemory];
        NSMutableData *rd = [g_texreg objectForKey:KEY(tex)];
        TexRecord r = {.tex = tex};
        if (rd) memcpy(&r, rd.bytes, sizeof r);
        else nx_nvn_texture_desc(tex, &r.d);
        NSArray *hit = [g_mtltex objectForKey:KEY(tex)];
        if (hit && ((TexMeta *)((NSMutableData *)hit[0]).bytes)->serial == r.serial) {
            id t = hit[1];
            if (t == [NSNull null]) t = nil;
            TexMeta *m = ((NSMutableData *)hit[0]).mutableBytes;
            extern volatile int g_gfx_frame;
            m->last_used = g_gfx_frame;
            int st0 = m->state;
            if (t && storage_changed(m)) {
                static long snap = -1;
                if (snap < 0) snap = getenv("NXRT_TEXSNAP") ? strtol(getenv("NXRT_TEXSNAP"), NULL, 16) : 0;
                if (snap && (long)tex == snap) {
                    extern volatile int g_gfx_frame;
                    nx_log("texsnap: frame %d re-upload from the pool (state was %d)", g_gfx_frame, st0);
                }
                upload_pool(t, &r, m);
                g_reuploads++, g_reupload_bytes += m->hi - m->lo;
            }
            pthread_mutex_unlock(&g_tlock);
            return t;
        }
        const void *old_mtl = hit && hit[1] != [NSNull null] ? (__bridge const void *)hit[1] : NULL;
        if (hit && hit[1] != [NSNull null]) {   // re-initialized: the old texture goes
            static int nlog;
            if (getenv("NXRT_ALIASDBG") && nlog++ < 60)
                nx_log("aliasdbg: texture %p re-initialized (%dx%d fmt %d pool %p +%#llx); old metal %p %lux%lu fmt %lu", tex, r.d.w, r.d.h,
                       r.d.format, r.d.pool, (unsigned long long)r.d.offset, hit[1], (unsigned long)((id<MTLTexture>)hit[1]).width,
                       (unsigned long)((id<MTLTexture>)hit[1]).height, (unsigned long)((id<MTLTexture>)hit[1]).pixelFormat);
            gfx_texture_dropped(hit[1]);
        }
        const NxTexDesc *d = &r.d;
        MTLPixelFormat pf = mtl_for(d->format);
        const NvnFmt *f = nvn_fmt(d->format);
        TexMeta meta = {.serial = r.serial, .seq = g_dirty_seq, .state = TEX_NODATA};
        if (pf == MTLPixelFormatInvalid || !f || d->w <= 0 || d->h <= 0 || d->w > 16384 || d->h > 16384) {
            static int logged;
            if (logged++ < 16) nx_log("gfx: no Metal texture for %p (%dx%d nvn format %d target %d)", tex, d->w, d->h, d->format, d->target);
            [g_mtltex setObject:@[[NSMutableData dataWithBytes:&meta length:sizeof meta], [NSNull null]] forKey:KEY(tex)];
            pthread_mutex_unlock(&g_tlock);
            return nil;
        }
        int takeover;
        id<MTLTexture> shared = alias_lookup(tex, d, pf, &takeover);
        {   // NXRT_ALIASDBG_OFF=<pool offset hex>: every Metal texture decision for textures at that storage offset
            static long woff = -2;
            if (woff == -2) woff = getenv("NXRT_ALIASDBG_OFF") ? strtol(getenv("NXRT_ALIASDBG_OFF"), NULL, 16) : -1;
            static int nl;
            extern volatile int g_gfx_frame;
            if (woff >= 0 && d->offset == woff && nl++ < 200)
                nx_log("aliasdbg: frame %d texture %p %dx%d fmt %d pool %p +%#llx -> %s %p", g_gfx_frame, tex, d->w, d->h, d->format, d->pool,
                       (unsigned long long)d->offset, shared ? "shares" : "NEW metal", shared);
        }
        if (shared) {
            swap_forget(tex);   // a swapped-out copy of its own is stale now
            meta.state = TEX_GPU;   // the storage's content is on the GPU (the primary's texture)
            [g_mtltex setObject:@[[NSMutableData dataWithBytes:&meta length:sizeof meta], shared] forKey:KEY(tex)];
            pthread_mutex_unlock(&g_tlock);
            return shared;
        }
        {   // audit: which NVN texture targets the game creates (7 = RECTANGLE, unnormalized coords)
            static uint32_t seen;
            if (d->target >= 0 && d->target < 32 && !(seen & (1u << d->target))) {
                seen |= 1u << d->target;
                nx_log("gfx: first texture with target %d (%dx%d format %d)", d->target, d->w, d->h, d->format);
            }
        }
        int levels = d->levels > 0 ? d->levels : 1, layers = 1, depth = 1;
        int max_levels = 1;
        while ((MAX(d->w, d->h) >> max_levels) > 0) max_levels++;
        if (levels > max_levels) {
            static int n;
            if (n++ < 8) nx_log("gfx: texture %p %dx%d asks for %d levels, clamped to %d", tex, d->w, d->h, levels, max_levels);
            levels = max_levels;
        }
        MTLTextureDescriptor *td = [MTLTextureDescriptor new];
        td.pixelFormat = pf;
        td.width = d->w;
        td.height = d->h;
        td.mipmapLevelCount = levels;
        switch (d->target) {
        case 0: td.textureType = MTLTextureType1D; td.height = 1; break;
        case 2: td.textureType = MTLTextureType3D; depth = d->d > 0 ? d->d : 1; td.depth = depth; break;
        case 3: td.textureType = MTLTextureType1DArray; layers = d->h; td.height = 1; td.arrayLength = layers; break;
        case 4: td.textureType = MTLTextureType2DArray; layers = d->d > 0 ? d->d : 1; td.arrayLength = layers; break;
        case 5: td.textureType = MTLTextureType2DMultisample; td.sampleCount = d->samples; break;
        case 6: td.textureType = MTLTextureType2DMultisampleArray; td.sampleCount = d->samples; layers = d->d; td.arrayLength = layers; break;
        case 8: td.textureType = MTLTextureTypeCube; layers = 6; break;
        case 9: td.textureType = MTLTextureTypeCubeArray; layers = d->d > 0 ? d->d : 6; td.arrayLength = layers / 6;
#if TARGET_OS_SIMULATOR
            // The simulator GPU has no cube arrays (the A15 has): same slices as a 2D array; shaders sampling cube
            // arrays are skipped there (shader_load).
            td.textureType = MTLTextureType2DArray, td.arrayLength = layers;
#endif
            break;
        default: td.textureType = MTLTextureType2D; break;
        }
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageShaderRead | (needs_pfv(d, pf) ? MTLTextureUsagePixelFormatView : 0);
        if (getenv("NXRT_PFVLOG") && d->w >= 256 && !is_compressed(d->format)) {
            NSMutableString *fs = [NSMutableString string];
            for (NSNumber *f in g_fmt_at[fmt_at_key(d)]) [fs appendFormat:@" %@", f];
            nx_log("pfvlog: %p %dx%d fmt %d -> %s (formats at storage:%s)", tex, d->w, d->h, d->format,
                   td.usage & MTLTextureUsagePixelFormatView ? "PFV" : "compressible", fs.UTF8String);
        }
        if (!is_compressed(d->format) && d->format != 64) td.usage |= MTLTextureUsageRenderTarget;
        if (bc_decoded(d->format)) td.usage |= MTLTextureUsageShaderWrite;   // the decode kernel writes it
        id<MTLTexture> recycled = recycle_get(d, td);
        id<MTLTexture> t = recycled ? recycled : [g_dev newTextureWithDescriptor:td];
        meta.levels = levels, meta.layers = layers;
        extern volatile int g_gfx_frame;
        meta.last_used = meta.created = g_gfx_frame;
        meta.bytes = t ? t.allocatedSize : 0;
        if (t && swap_restore(tex, r.serial, t)) meta.state = TEX_GPU;   // swapped out while unused (texture budget)
        else if (t) upload_pool(t, &r, &meta);
        if (t && !recycled && !(t.usage & MTLTextureUsagePixelFormatView) && (meta.state == TEX_EMPTY || meta.state == TEX_NODATA)) {
            static int lf = -2;   // NXRT_CLEARNEWLOG=<frame>: the new textures cleared in that frame
            if (lf == -2) lf = getenv("NXRT_CLEARNEWLOG") ? atoi(getenv("NXRT_CLEARNEWLOG")) : -1;
            if (lf == g_gfx_frame)
                nx_log("clearnew: frame %d %p %dx%dx%d fmt %d target %d levels %d pool %p +%#llx serial %llu (old metal %p)", g_gfx_frame, tex, d->w, d->h,
                       d->d, d->format, d->target, levels, d->pool, (unsigned long long)d->offset, (unsigned long long)r.serial, old_mtl);
            clear_new(t);
        }
        [g_mtltex setObject:@[[NSMutableData dataWithBytes:&meta length:sizeof meta], t ? (id)t : (id)[NSNull null]] forKey:KEY(tex)];
        if (t) alias_set_primary(tex, d, takeover, t);
        pthread_mutex_unlock(&g_tlock);
        return t;
    }
}

// ---- swapping idle GPU-written textures to a file -------------------------------------------
// GPU-written textures (render targets, the GPU-encoded Mii faces, copies) are the only copy of their content, so the
// budget could not drop them: ~190 of ~330 MB of them sat unused for >300 frames on the maxed island. Under budget
// pressure, one unused for GPU_SWAP_AGE frames is copied to a shared buffer (blit), written to a file in the temp
// directory and dropped; texture_mtl restores it from the file (or the buffer, while the write is still pending) at
// its next use instead of uploading the guest storage (which is stale for these). The guest memory is never written.
// Only plain colour formats (mtl_bpp), single-sample, 2D / 2D array / cube (array) textures. NXRT_NOTEXSWAP=1: off.
enum { GPU_SWAP_AGE = 300 };
typedef struct {
    uint64_t serial;
    uint64_t id;          // file name
    uint64_t bytes;
    MTLPixelFormat pf;
    NSUInteger w, h, levels, slices;
} SwapRec;

static int mtl_bpp(MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatR8Unorm: return 1;
    case MTLPixelFormatRG8Unorm: case MTLPixelFormatR16Float: case MTLPixelFormatR16Unorm: return 2;
    case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatBGRA8Unorm:
    case MTLPixelFormatBGRA8Unorm_sRGB: case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatRG11B10Float:
    case MTLPixelFormatR32Float: case MTLPixelFormatRG16Float: case MTLPixelFormatRG16Unorm: case MTLPixelFormatRGB9E5Float: return 4;
    case MTLPixelFormatRGBA16Float: case MTLPixelFormatRGBA16Unorm: case MTLPixelFormatRG32Float: return 8;
    case MTLPixelFormatRGBA32Float: return 16;
    default: return 0;
    }
}
static NSUInteger tex_slices(id<MTLTexture> t) {
    return t.arrayLength * (t.textureType == MTLTextureTypeCube || t.textureType == MTLTextureTypeCubeArray ? 6 : 1);
}
static int swappable(id<MTLTexture> t) {
    MTLTextureType y = t.textureType;
    return t.sampleCount == 1 && mtl_bpp(t.pixelFormat) &&
           (y == MTLTextureType2D || y == MTLTextureType2DArray || y == MTLTextureTypeCube || y == MTLTextureTypeCubeArray);
}
static NSString *swap_path(uint64_t id) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"nxrt-texswap"];
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];   // a previous run's
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%llu", (unsigned long long)id]];
}
// Blit every (slice, level) of t into buf, tightly packed in that order (the file layout).
static void swap_copy(id<MTLBlitCommandEncoder> b, id<MTLTexture> t, id<MTLBuffer> buf, int to_texture) {
    NSUInteger off = 0, bpp = mtl_bpp(t.pixelFormat);
    for (NSUInteger s = 0; s < tex_slices(t); s++)
        for (NSUInteger l = 0; l < t.mipmapLevelCount; l++) {
            NSUInteger w = MAX(1, t.width >> l), h = MAX(1, t.height >> l), row = w * bpp;
            if (to_texture)
                [b copyFromBuffer:buf sourceOffset:off sourceBytesPerRow:row sourceBytesPerImage:row * h sourceSize:MTLSizeMake(w, h, 1)
                        toTexture:t destinationSlice:s destinationLevel:l destinationOrigin:MTLOriginMake(0, 0, 0)];
            else
                [b copyFromTexture:t sourceSlice:s sourceLevel:l sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
                          toBuffer:buf destinationOffset:off destinationBytesPerRow:row destinationBytesPerImage:row * h];
            off += row * h;
        }
}
static NSUInteger swap_bytes(id<MTLTexture> t) {
    NSUInteger n = 0, bpp = mtl_bpp(t.pixelFormat);
    for (NSUInteger l = 0; l < t.mipmapLevelCount; l++) n += MAX(1, t.width >> l) * bpp * MAX(1, t.height >> l);
    return n * tex_slices(t);
}
static void swap_forget(const void *tex) {   // under g_tlock
    NSArray *v = g_swapped ? [g_swapped objectForKey:KEY(tex)] : nil;
    if (!v) return;
    const SwapRec *sr = ((NSMutableData *)v[0]).bytes;
    if (v[1] == [NSNull null]) unlink(swap_path(sr->id).fileSystemRepresentation);
    [g_swapped removeObjectForKey:KEY(tex)];
}
// texture_mtl, under g_tlock: t was just made for tex (serial). Fills it from the swap and returns 1 if there is one.
static int swap_restore(const void *tex, uint64_t serial, id<MTLTexture> t) {
    NSArray *v = g_swapped ? [g_swapped objectForKey:KEY(tex)] : nil;
    if (!v) return 0;
    SwapRec sr = *(const SwapRec *)((NSMutableData *)v[0]).bytes;
    id<MTLBuffer> buf = v[1] == [NSNull null] ? nil : v[1];
    // Re-initialized since the swap (new serial or shape): a new texture whose content is in the guest pool; the swap is stale.
    if (!(sr.serial == serial && t && sr.pf == t.pixelFormat && sr.w == t.width && sr.h == t.height &&
          sr.levels == t.mipmapLevelCount && sr.slices == tex_slices(t) && sr.bytes == swap_bytes(t))) {
        swap_forget(tex);
        g_swap_stale_n++;
        return 0;
    }
    int ok = 1;
    if (!buf) {
        buf = [g_dev newBufferWithLength:sr.bytes options:MTLResourceStorageModeShared];
        int fd = open(swap_path(sr.id).fileSystemRepresentation, O_RDONLY);
        ok = buf && fd >= 0 && pread(fd, buf.contents, sr.bytes, 0) == (ssize_t)sr.bytes;
        if (fd >= 0) close(fd);
    }
    swap_forget(tex);
    if (!ok) {
        nx_log("gfx: texture swap: could not restore %p (%lux%lu)", tex, (unsigned long)sr.w, (unsigned long)sr.h);
        return 0;
    }
    id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
    id<MTLBlitCommandEncoder> b = [cmd blitCommandEncoder];
    swap_copy(b, t, buf, 1);
    [b endEncoding];
    [cmd commit];
    g_swap_in_n++, g_swap_in_bytes += sr.bytes;
    return 1;
}

// ---- texture budget -----------------------------------------------------------------------
// The game keeps every texture of the island alive (NVN objects are never finalized while panning), so our Metal
// copies only grew: 940 -> 1,460 MB on the maxed island (BC decoded to RGBA8 is 4-8x the guest size), and the
// phone was killed. The guest pool still holds each texture's data, so a texture uploaded from it can be dropped and
// uploaded again at its next use (texture_mtl re-creates it like a new one). Once per frame: when Metal memory is
// over the budget (or, on iOS, little is left before the jetsam limit), the least recently used such textures go,
// oldest first (ages below). Not dropped: GPU-written ones (render targets,
// copies, clears, WriteTexels: the Metal texture is the only copy), storage shared by aliased textures, NODATA.
// NXRT_TEXBUDGET=<MB> (Metal allocated; default iOS 700, Mac 0 = off), NXRT_TEXBUDGET_RESERVE=<MB>
// (iOS: trim hard while less than this is left before the jetsam limit, default 600).
// Two limits: over the budget only textures unused for TRIM_SOFT_AGE frames go (a working set a little over the
// budget doesn't churn: a 700 MB budget under the island's ~850 MB re-decoded ~2 textures every frame); over the hard
// limit (budget + 25%, or the iOS reserve) anything not drawn in the last TRIM_HARD_AGE frames (fast pans: a
// 90-frame minimum still let them reach 1.4 GB).
enum { TRIM_SOFT_AGE = 60, TRIM_HARD_AGE = 6 };
// Residency (gfx_cmd.m residency_sync): the Metal textures the GPU renders into (GPU-written or never holding CPU data:
// render targets, depth; all_states: every texture), of at least min_bytes, each once (aliases share one texture; views
// give their parent).
NSArray *gfx_texture_rt_list(uint64_t min_bytes, int all_states) {
    NSMutableArray *out = [NSMutableArray array];
    NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsObjectPointerPersonality];
    pthread_mutex_lock(&g_tlock);
    for (id k in g_mtltex) {
        NSArray *v = [g_mtltex objectForKey:k];
        if (v[1] == [NSNull null]) continue;
        const TexMeta *m = ((NSMutableData *)v[0]).bytes;
        if (!all_states && (m->state & 3) != TEX_GPU && (m->state & 3) != TEX_NODATA) continue;
        id<MTLTexture> t = v[1];
        if (t.parentTexture) t = t.parentTexture;
        if (t.allocatedSize < min_bytes || [seen containsObject:t]) continue;
        [seen addObject:t];
        [out addObject:t];
    }
    pthread_mutex_unlock(&g_tlock);
    return out;
}

void gfx_texture_trim(void) {
    static long budget = -1, reserve;
    if (budget < 0) {
#if TARGET_OS_IPHONE
        budget = 700, reserve = 600;
#else
        budget = 0, reserve = 0;
#endif
        if (getenv("NXRT_TEXBUDGET")) budget = atol(getenv("NXRT_TEXBUDGET"));
        if (getenv("NXRT_TEXBUDGET_RESERVE")) reserve = atol(getenv("NXRT_TEXBUDGET_RESERVE"));
        budget <<= 20, reserve <<= 20;
        if (budget || reserve) nx_log("gfx: texture budget %ld MB of Metal memory, reserve %ld MB", budget >> 20, reserve >> 20);
    }
    if (!budget && !reserve) return;
    if (!g_mtltex || !g_dev) return;
    int64_t used = (int64_t)g_dev.currentAllocatedSize;
    int64_t over = budget ? used - budget : 0, hard = budget ? used - budget * 5 / 4 : 0;
#if TARGET_OS_IPHONE
    if (reserve) hard = MAX(hard, (int64_t)reserve - (int64_t)os_proc_available_memory()), over = MAX(over, hard);
#endif
    if (over <= 0) return;
    int min_age = hard > 0 ? TRIM_HARD_AGE : TRIM_SOFT_AGE;
    extern volatile int g_gfx_frame;
    int now = g_gfx_frame;
    @autoreleasepool {
        pthread_mutex_lock(&g_tlock);
        typedef struct { const void *tex; int last; uint64_t bytes; } Cand;
        NSUInteger cap = g_mtltex.count, n = 0;
        Cand *c = malloc(sizeof *c * (cap ? cap : 1));
        for (id k in g_mtltex) {
            NSArray *v = [g_mtltex objectForKey:k];
            const TexMeta *m = ((NSMutableData *)v[0]).bytes;
            if (v[1] == [NSNull null] || (m->state != TEX_UPLOADED && m->state != TEX_EMPTY) || now - m->last_used < min_age) continue;
            if (n < cap) c[n++] = (Cand){(__bridge const void *)k, m->last_used, m->bytes};
        }
        qsort_b(c, n, sizeof *c, ^int(const void *a, const void *b) { return ((const Cand *)a)->last - ((const Cand *)b)->last; });
        int64_t freed = 0;
        int dropped = 0;
        NSMutableArray *gone = [NSMutableArray array];
        for (NSUInteger i = 0; i < n && freed < over + (16 << 20); i++) {
            const void *tex = c[i].tex;
            NSArray *v = [g_mtltex objectForKey:KEY(tex)];
            id<MTLTexture> t = v[1];
            NxTexDesc d;
            nx_nvn_texture_desc(tex, &d);
            if (d.pool && g_alias) {   // shared storage: only when no other NVN texture uses this Metal texture
                NSNumber *ak = alias_key(d.pool, d.offset);
                NSSet *u = g_alias_users[ak];
                if (u.count > 1 || (u.count == 1 && ![u containsObject:[NSValue valueWithPointer:tex]])) continue;
                if (g_alias_mtl[ak] == t) [g_alias_mtl removeObjectForKey:ak];
            }
            static int dbg = -1, ndbg;
            if (dbg < 0) dbg = getenv("NXRT_TRIMDBG") != NULL;
            if (dbg && ndbg++ < 3000) {
                const TexMeta *m = ((NSMutableData *)v[0]).bytes;
                nx_log("trimdbg: frame %d drop %p %dx%dx%d fmt %d target %d levels %d state %d last %d created %d %.2f MB guest %llu B",
                       now, tex, d.w, d.h, d.d, d.format, d.target, d.levels, m->state, m->last_used, m->created, m->bytes / 1048576.0,
                       (unsigned long long)(m->hi - m->lo));
            }
            [g_mtltex removeObjectForKey:KEY(tex)];
            [gone addObject:t];
            freed += c[i].bytes, dropped++;
        }
        free(c);
        // Still over: swap out GPU-written textures unused for GPU_SWAP_AGE frames, least recently used first.
        static int noswap = -1;
        if (noswap < 0) noswap = getenv("NXRT_NOTEXSWAP") != NULL;
        if (freed < over + (16 << 20) && !noswap) {
            n = 0;
            c = malloc(sizeof *c * (cap ? cap : 1));
            for (id k in g_mtltex) {
                NSArray *v = [g_mtltex objectForKey:k];
                const TexMeta *m = ((NSMutableData *)v[0]).bytes;
                if (v[1] == [NSNull null] || m->state != TEX_GPU || now - m->last_used < GPU_SWAP_AGE || !swappable(v[1])) continue;
                if (n < cap) c[n++] = (Cand){(__bridge const void *)k, m->last_used, m->bytes};
            }
            qsort_b(c, n, sizeof *c, ^int(const void *a, const void *b) { return ((const Cand *)a)->last - ((const Cand *)b)->last; });
            id<MTLCommandBuffer> cmd = nil;
            id<MTLBlitCommandEncoder> b = nil;
            NSMutableArray *outs = [NSMutableArray array];   // @[tex key, buffer, id]
            static uint64_t next_id;
            for (NSUInteger i = 0; i < n && freed < over + (16 << 20); i++) {
                const void *tex = c[i].tex;
                NSArray *v = [g_mtltex objectForKey:KEY(tex)];
                id<MTLTexture> t = v[1];
                // Shared storage (aliases): this Metal texture is someone else's too; leave it.
                NSSet *hold = nil;
                NxTexDesc d;
                nx_nvn_texture_desc(tex, &d);
                NSNumber *ak = d.pool && g_alias ? alias_key(d.pool, d.offset) : nil;
                if (ak) {
                    hold = g_alias_users[ak];
                    if (hold.count > 1 || (hold.count == 1 && ![hold containsObject:[NSValue valueWithPointer:tex]])) continue;
                }
                BOOL other = NO;   // aliases of other textures that resolved to this one (TEX_GPU entries sharing it)
                for (id k2 in g_mtltex)
                    if ((__bridge const void *)k2 != tex && ((NSArray *)[g_mtltex objectForKey:k2])[1] == t) { other = YES; break; }
                if (other) continue;
                NSUInteger bytes = swap_bytes(t);
                id<MTLBuffer> buf = [g_dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
                if (!buf) break;
                if (!cmd) cmd = [g_queue commandBuffer], b = [cmd blitCommandEncoder];
                swap_copy(b, t, buf, 0);
                if (ak && g_alias_mtl[ak] == t) [g_alias_mtl removeObjectForKey:ak];
                SwapRec sr = {((const TexMeta *)((NSMutableData *)v[0]).bytes)->serial, ++next_id, bytes, t.pixelFormat,
                              t.width, t.height, t.mipmapLevelCount, tex_slices(t)};
                if (!g_swapped)
                    g_swapped = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                                                      valueOptions:NSPointerFunctionsStrongMemory];
                [g_swapped setObject:@[[NSMutableData dataWithBytes:&sr length:sizeof sr], buf] forKey:KEY(tex)];
                [outs addObject:@[[NSValue valueWithPointer:tex], buf, @(sr.id)]];
                [g_mtltex removeObjectForKey:KEY(tex)];
                [gone addObject:t];
                freed += c[i].bytes, dropped++;
                g_swap_out_n++, g_swap_out_bytes += bytes;
            }
            free(c);
            if (cmd) {
                [b endEncoding];
                // After the copy: write each buffer to its file, then release the buffer (unless restored meanwhile).
                [cmd addCompletedHandler:^(id<MTLCommandBuffer> cb) {
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        for (NSArray *o in outs) {
                            id<MTLBuffer> buf = o[1];
                            uint64_t sid = [o[2] unsignedLongLongValue];
                            NSString *path = swap_path(sid);
                            int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
                            int ok = fd >= 0 && write(fd, buf.contents, buf.length) == (ssize_t)buf.length;
                            if (fd >= 0) close(fd);
                            pthread_mutex_lock(&g_tlock);
                            const void *tex = [o[0] pointerValue];
                            NSArray *v = [g_swapped objectForKey:KEY(tex)];
                            if (v && ((const SwapRec *)((NSMutableData *)v[0]).bytes)->id == sid) {
                                if (ok) [g_swapped setObject:@[v[0], [NSNull null]] forKey:KEY(tex)];   // the file holds it now
                            } else unlink(path.fileSystemRepresentation);   // restored or forgotten before the write
                            pthread_mutex_unlock(&g_tlock);
                        }
                    });
                }];
                [cmd commit];
            }
        }
        g_trim_n += dropped, g_trim_bytes += freed, g_trim_frames++;
        pthread_mutex_unlock(&g_tlock);
        for (id<MTLTexture> t in gone) gfx_texture_dropped(t);   // views and copies go too (each retains its texture)
        static int nlog;
        if (dropped && nlog++ < 20)
            nx_log("gfx: texture budget: frame %d dropped %d textures (%.1f MB), %.1f MB over", now, dropped, freed / 1048576.0, over / 1048576.0);
    }
}
