// Graphics backend (gfx_metal.m): NVN command buffers recorded on the host, executed on Metal.
#pragma once
#include <stdint.h>

void gfx_run_app(void (*guest_main)(void));   // main thread: window + event loop, guest on a pthread

void gfx_queue_present(void *queue, void *window, int32_t index);
void gfx_window_builder_textures(void *builder, int32_t n, void *const *textures);
void gfx_window_init(void *window, const void *builder);
void gfx_window_set_crop(void *window, int32_t x, int32_t y, int32_t w, int32_t h);   // shown part of the window textures
void *gfx_proc_for(const char *name);          // gfx_cmd.m: NVN functions implemented there

// Sampler and texture-view state kept inline in the game's objects (nvn.c), read by gfx_cmd.m.
typedef struct {
    int32_t min, mag, wrap_s, wrap_t, wrap_r, cmp_mode, cmp_func, reduction;
    float lod_min, lod_max, lod_bias, aniso, border[4];
} NxSamplerState;   // 64 bytes (NVNsamplerBuilder / NVNsampler are larger)
typedef struct {
    uint8_t set, target, base_level, num_levels;
    uint16_t min_layer, num_layers, format, swizzle;   // swizzle: 4 x 4 bits
    uint8_t ds_mode, pad[3];
} NxTexView;        // NVNtextureView is small: 28 bytes smashed the game's stack, 16 is safe

// Texture registry (texture dumps now, Metal textures later). Builder extras that don't fit
// in our inline builder state are kept host-side, keyed by builder address.
void gfx_texbuilder_defaults(void *builder);
void gfx_texbuilder_packaged_data(void *builder, const void *data);
void gfx_texbuilder_packaged_layout(void *builder, const void *layout);
void gfx_texbuilder_stride(void *builder, int64_t stride);
void gfx_texbuilder_swizzle(void *builder, int32_t r, int32_t g, int32_t b, int32_t a);
void gfx_texture_write_texels(const void *tex, const void *view, const int32_t *region, const void *data);
void gfx_texture_init(void *tex, const void *builder);
void gfx_texture_finalize(void *tex);
void gfx_note_cpu_write(const void *p, uint64_t n);   // CPU wrote pool memory the GPU reads (flush)

// nvn.c: texture state kept inline in the game's NVNtexture
typedef struct {
    const uint8_t *pool_data;   // pool storage + offset (NULL without storage)
    uint64_t pool_avail;        // bytes from there to the end of the pool
    int32_t w, h, d, levels, format, target, flags, samples;
    int32_t pool_flags;         // NVN memory pool flags (CPU_UNCACHED 2, CPU_CACHED 4, ...)
    const void *pool;           // storage identity (also for pools without CPU memory): pool object + offset
    int64_t offset;
} NxTexDesc;
void nx_nvn_texture_info(const void *tex, int32_t *w, int32_t *h, int32_t *format);
void nx_nvn_texture_desc(const void *tex, NxTexDesc *out);
void *nx_nvn_gpu_to_host(uint64_t gpu, uint64_t *avail);
int nx_nvn_gpu_pool(uint64_t gpu, uint8_t **mem, uint64_t *size, uint64_t *off);

// shaders.c
typedef struct { uint64_t hash; char kind[4]; uint64_t c1_addr; uint32_t c1_size; } NxStage;
int gfx_program_info(const void *program, NxStage *out);   // up to 6 stages
uint64_t gfx_program_set_shaders(void *program, int32_t count, const void *stages);
uint64_t gfx_program_set_shaders_ext(void *program, int32_t count, const void *stages);
