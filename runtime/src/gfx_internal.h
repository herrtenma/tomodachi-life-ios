// Shared between the Objective-C graphics files.
#pragma once
#import <Metal/Metal.h>

extern id<MTLDevice> g_dev;
extern id<MTLCommandQueue> g_queue;
void gfx_init(void);
id<MTLRenderPipelineState> gfx_blit_pso(MTLPixelFormat target);   // full-screen sampled copy
id<MTLRenderPipelineState> gfx_blit_rect_pso(MTLPixelFormat target);   // same, source rect at fragment buffer 0
int gfx_write_png(const char *path, const void *rgba, NSUInteger w, NSUInteger h);
void gfx_texdump_at_frame(int frame);                                // gfx_textures.m
void gfx_texture_write_texels(const void *tex, const void *view, const int32_t *region, const void *data);
uint16_t gfx_texture_swizzle(const void *tex);                       // NVN swizzle of a texture (0x5432 = identity)
id<MTLTexture> gfx_texture_mtl(const void *tex);                     // Metal texture for an NVN texture
void gfx_texture_mark_gpu(const void *tex);                          // GPU-written: never re-upload from the pool
// Render targets in CPU-readable pools (the game reads them back, e.g. picking): layout to write level 0 back.
typedef struct { uint8_t *dst; uint64_t avail; int w, h, bpb, gh; int64_t stride; } NxReadback;
int gfx_texture_readback_info(const void *tex, NxReadback *out);
void gfx_texture_store(const NxReadback *rb, const uint8_t *lin);   // linear rows (w * bpb) -> guest layout
void gfx_texture_stats(int frames);
void gfx_texture_trim(void);                                      // once per frame: keep Metal textures under the budget
NSArray *gfx_texture_rt_list(uint64_t min_bytes, int all_states); // render targets (or all) of at least that size (residency set)
void gfx_texture_dropped(id<MTLTexture> t);                         // gfx_cmd.m: forget views/copies of a released texture
// iOS: the app is inactive/backgrounded (no GPU work may be submitted); commits and presents wait until it is back.
extern volatile int g_gfx_background;
void gfx_wait_foreground(void);
int gfx_texture_state(const void *tex, uintptr_t *lo, uintptr_t *hi);   // diagnostics
MTLPixelFormat gfx_mtl_format(int nvn);
MTLPixelFormat gfx_mtl_format_raw(int nvn);                          // BC stays BC (gfx_mtl_format may decode it)
// gfx_bcdec.m: BC textures decoded on the GPU where the device can't sample them (iPhone A15)
int gfx_bc_emulated(void);
int gfx_bc_mode(MTLPixelFormat f);
MTLPixelFormat gfx_bc_host_format(MTLPixelFormat f);
void gfx_bc_decode(id<MTLComputeCommandEncoder> e, id<MTLBuffer> src, NSUInteger off, NSUInteger row, MTLPixelFormat bc,
                   id<MTLTexture> dst, NSUInteger slice, NSUInteger level, NSUInteger x, NSUInteger y, NSUInteger w, NSUInteger h);
