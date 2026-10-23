// Shader capture (graphics step 3). nvnProgramSetShaders(program, count, NVNshaderData[count])
// with NVNshaderData = {GPU address of the code, pointer to the GLSLC control section}.
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gfx.h"
#include "nxrt.h"

static void hexline(const char *tag, const uint8_t *p, int n) {
    char buf[512];
    int k = 0;
    for (int i = 0; i < n && k < (int)sizeof buf - 4; i++) k += snprintf(buf + k, sizeof buf - k, "%02x%s", p[i], i % 4 == 3 ? " " : "");
    nx_log("%s %s", tag, buf);
}

static void probe(const char *fn, void *program, int32_t count, const uint8_t *stages, int stride) {
    static int calls;
    if (!getenv("NXRT_SHADERPROBE") || calls++ >= 6) return;
    nx_log("shader: %s(program %p, %d stages, entry stride %d)", fn, program, count, stride);
    for (int i = 0; i < count && i < 6; i++) {
        const uint8_t *e = stages + i * stride;
        hexline("shader:   entry", e, stride);
        uint64_t gpu, avail = 0;
        const uint8_t *ctl;
        memcpy(&gpu, e, 8);
        memcpy(&ctl, e + 8, 8);
        const uint8_t *code = nx_nvn_gpu_to_host(gpu, &avail);
        nx_log("shader:   [%d] code gpu %#llx -> host %p (%#llx avail), control %p", i, (unsigned long long)gpu, code,
               (unsigned long long)avail, ctl);
        if (code) for (int r = 0; r < 4; r++) hexline("shader:     code", code + r * 32, 32);
        if (ctl) for (int r = 0; r < 8; r++) hexline("shader:     ctl ", ctl + r * 32, 32);
    }
}

// Maxwell code ends where every path has exited; for dumping we take everything up to the
// self-branch that follows the last EXIT (0xE2400FFFF..07 is "BRA -8"), capped at 512 KB.
static uint64_t code_size(const uint8_t *code, uint64_t avail) {
    uint64_t cap = avail < (512 << 10) ? avail : (512 << 10);
    for (uint64_t off = 0x80; off + 8 <= cap; off += 8) {
        uint64_t w;
        memcpy(&w, code + off, 8);
        if (w == 0xE2400FFFFF87000Full || w == 0xE2400FFFFF07000Full) return off + 8;
    }
    return cap;
}

// Stage kind: graphics blobs carry an SPH at +0x30 (type in bits 10..12); compute blobs have a
// different NVN header magic (0x12345679), no SPH, and code at +0x100.
static const char *stage_kind(const uint8_t *code) {
    static const char *const kind[] = {"?", "vs", "tcs", "tes", "gs", "fs", "?", "?"};
    uint32_t magic, sph0;
    memcpy(&magic, code, 4);
    memcpy(&sph0, code + 0x30, 4);
    return magic == 0x12345679 ? "cs" : kind[(sph0 >> 10) & 7];
}

static uint64_t fnv(const uint8_t *p, uint64_t n) {
    uint64_t h = 1469598103934665603ull;
    for (uint64_t i = 0; i < n; i++) h = (h ^ p[i]) * 1099511628211ull;
    return h;
}

// program -> stage hashes (what BindProgram binds), open addressing on the program address.
enum { PROG_SLOTS = 1 << 14 };
static struct { const void *program; int n; NxStage st[6]; } g_progs[PROG_SLOTS];
static pthread_mutex_t g_prog_lock = PTHREAD_MUTEX_INITIALIZER;

void nx_xlat_note(uint64_t hash, const char *kind, const uint8_t *code, size_t n, const uint8_t *c1, size_t c1n,
                  const uint8_t *ctl, size_t ctln);
static void program_set(const void *program, const uint8_t *stages, int32_t count, int stride) {
    pthread_mutex_lock(&g_prog_lock);
    unsigned i = (unsigned)((uintptr_t)program >> 4) & (PROG_SLOTS - 1);
    while (g_progs[i].program && g_progs[i].program != program) i = (i + 1) & (PROG_SLOTS - 1);
    g_progs[i].program = program;
    g_progs[i].n = 0;
    for (int k = 0; k < count && k < 6; k++) {
        uint64_t gpu, avail = 0;
        memcpy(&gpu, stages + k * stride, 8);
        const uint8_t *code = nx_nvn_gpu_to_host(gpu, &avail);
        if (!code || avail < 0x80) continue;
        uint64_t n = code_size(code, avail);
        NxStage *st = &g_progs[i].st[g_progs[i].n++];
        st->hash = fnv(code + 0x30, n - 0x30);
        snprintf(st->kind, sizeof st->kind, "%s", stage_kind(code));
        // Driver constant buffer 1 = the program's constant data: control +0x700 = offset in the
        // code blob, +0x6FC = size (GLSLC control section, magic 0x98761234).
        const uint8_t *ctl;
        memcpy(&ctl, stages + k * stride + 8, 8);
        st->c1_addr = st->c1_size = 0;
        const uint8_t *c1 = NULL;
        size_t c1n = 0;
        if (ctl && *(const uint32_t *)ctl == 0x98761234) {
            uint32_t off = *(const uint32_t *)(ctl + 0x700), size = *(const uint32_t *)(ctl + 0x6FC);
            if (size) st->c1_addr = gpu + off, st->c1_size = size;
            if (size && off + (uint64_t)size <= avail) c1 = code + off, c1n = size;
        }
        // shader_xlat.m: translated in the background unless already in the shader cache. Compute stages need the
        // control section (0x880 bytes: local size, shared / local memory).
        int cs = !strcmp(st->kind, "cs");
        nx_xlat_note(st->hash, st->kind, code, n, c1, c1n, cs && ctl ? ctl : NULL, cs && ctl ? 0x880 : 0);
    }
    pthread_mutex_unlock(&g_prog_lock);
}

// Stage hashes of a program: returns the count, fills hash/kind.
int gfx_program_info(const void *program, NxStage *out) {
    pthread_mutex_lock(&g_prog_lock);
    unsigned i = (unsigned)((uintptr_t)program >> 4) & (PROG_SLOTS - 1);
    while (g_progs[i].program && g_progs[i].program != program) i = (i + 1) & (PROG_SLOTS - 1);
    int n = g_progs[i].program ? g_progs[i].n : 0;
    memcpy(out, g_progs[i].st, n * sizeof *out);
    pthread_mutex_unlock(&g_prog_lock);
    return n;
}

int gfx_program_stages(const void *program, uint64_t *hash, const char **kind) {
    static __thread NxStage st[6];
    int n = gfx_program_info(program, st);
    for (int k = 0; k < n; k++) hash[k] = st[k].hash, kind[k] = st[k].kind;
    return n;
}

// NXRT_CTLDUMP=<dir>: first 0x1000 bytes of each stage's control section, plus 0x2000 bytes of
// the code buffer after the code (to find the program's constant data).
static void capture_ctl(const uint8_t *stages, int32_t count, int stride) {
    const char *dir = getenv("NXRT_CTLDUMP");
    static int n;
    if (!dir || n >= 40) return;
    for (int i = 0; i < count; i++) {
        uint64_t gpu, avail = 0;
        const uint8_t *ctl;
        memcpy(&gpu, stages + i * stride, 8);
        memcpy(&ctl, stages + i * stride + 8, 8);
        const uint8_t *code = nx_nvn_gpu_to_host(gpu, &avail);
        if (!code || !ctl) continue;
        uint64_t sz = code_size(code, avail);
        char path[1024];
        snprintf(path, sizeof path, "%s/%02d_%016llx.ctl", dir, n, (unsigned long long)fnv(code + 0x30, sz - 0x30));
        FILE *f = fopen(path, "wb");
        if (f) fwrite(ctl, 1, 0x1000, f), fclose(f);
        snprintf(path, sizeof path, "%s/%02d_code_tail_%llx.bin", dir, n, (unsigned long long)sz);
        f = fopen(path, "wb");
        if (f) fwrite(code, 1, sz + 0x2000 < avail ? sz + 0x2000 : avail, f), fclose(f);
        n++;
    }
}

// NXRT_SHADERDUMP=<dir>: every unique stage as <hash>.<vs|fs|..>.bin (NVN header + SPH + code).
static void capture(const uint8_t *stages, int32_t count, int stride) {
    capture_ctl(stages, count, stride);
    const char *dir = getenv("NXRT_SHADERDUMP");
    static uint64_t seen[16384];
    static int nseen, calls;
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    if (!dir) return;
    pthread_mutex_lock(&lock);
    calls++;
    for (int i = 0; i < count; i++) {
        uint64_t gpu, avail = 0;
        memcpy(&gpu, stages + i * stride, 8);
        const uint8_t *code = nx_nvn_gpu_to_host(gpu, &avail);
        if (!code || avail < 0x80) continue;
        uint64_t n = code_size(code, avail), h = fnv(code + 0x30, n - 0x30);
        int k = 0;
        while (k < nseen && seen[k] != h) k++;
        if (k < nseen || nseen == 16384) continue;
        seen[nseen++] = h;
        const char *kind = stage_kind(code);
        char path[1024];
        snprintf(path, sizeof path, "%s/%016llx.%s.bin", dir, (unsigned long long)h, kind);
        FILE *f = fopen(path, "wb");
        if (f) fwrite(code, 1, n, f), fclose(f);
        // Constant buffer 1 next to it as <hash>.<kind>.c1: the translator needs it to resolve BRX jump tables.
        const uint8_t *ctl;
        memcpy(&ctl, stages + i * stride + 8, 8);
        if (ctl && *(const uint32_t *)ctl == 0x98761234) {
            uint32_t off = *(const uint32_t *)(ctl + 0x700), size = *(const uint32_t *)(ctl + 0x6FC);
            if (size && off + (uint64_t)size <= avail) {
                snprintf(path, sizeof path, "%s/%016llx.%s.c1", dir, (unsigned long long)h, kind);
                if ((f = fopen(path, "wb"))) fwrite(code + off, 1, size, f), fclose(f);
            }
            // Compute: the control section too (<hash>.cs.ctl, 0x880 bytes); it holds the local size
            // and shared/local memory sizes the translator needs.
            if (!strcmp(kind, "cs")) {
                snprintf(path, sizeof path, "%s/%016llx.cs.ctl", dir, (unsigned long long)h);
                if ((f = fopen(path, "wb"))) fwrite(ctl, 1, 0x880, f), fclose(f);
            }
        }
        if (nseen % 50 == 0) nx_log("shader: %d unique stages from %d SetShaders calls", nseen, calls);
    }
    pthread_mutex_unlock(&lock);
}

uint64_t gfx_program_set_shaders(void *program, int32_t count, const void *stages) {
    probe("SetShaders", program, count, stages, 16);
    capture(stages, count, 16);
    program_set(program, stages, count, 16);
    return 1;
}

// NVNshaderDataExt is 24 bytes: {code GPU address, control, 8 more bytes}.
uint64_t gfx_program_set_shaders_ext(void *program, int32_t count, const void *stages) {
    probe("SetShadersExt", program, count, stages, 24);
    capture(stages, count, 24);
    program_set(program, stages, count, 24);
    return 1;
}

// ---- NXRT_BINDPROBE=<frame>: log the command stream recorded during that frame ----------
extern volatile int g_gfx_frame;
static int bp_on(void) {
    static int target = -2, last;
    if (target == -2) {   // NXRT_BINDPROBE=<frame>, <first>-<last> or all
        const char *e = getenv("NXRT_BINDPROBE");
        target = !e ? -1 : !strcmp(e, "all") ? -3 : atoi(e);
        last = e && strchr(e, '-') ? atoi(strchr(e, '-') + 1) : target;
    }
    static long lines, max = -1;   // NXRT_BINDPROBE_MAX=<lines> (default 400000)
    if (max < 0) max = getenv("NXRT_BINDPROBE_MAX") ? atol(getenv("NXRT_BINDPROBE_MAX")) : 400000;
    return (target == -3 || (target >= 0 && g_gfx_frame >= target && g_gfx_frame <= last)) && lines++ < max;
}
int bp_enabled(void) { return bp_on(); }
void bp_bind_program(void *cb, const void *program, int32_t stages) {
    if (!bp_on()) return;
    uint64_t h[6];
    const char *k[6];
    int n = gfx_program_stages(program, h, k);
    char buf[256];
    int o = 0;
    for (int i = 0; i < n; i++) o += snprintf(buf + o, sizeof buf - o, " %016llx.%s", (unsigned long long)h[i], k[i]);
    nx_log("bp: %p BindProgram %p stages %#x:%s", cb, program, stages, buf);
}
void bp_bind_uniform(void *cb, int32_t stage, int32_t index, uint64_t addr, int64_t size) {
    if (bp_on()) nx_log("bp: %p BindUniformBuffer stage %d index %d addr %#llx size %#llx", cb, stage, index,
                        (unsigned long long)addr, (long long)size);
}
void bp_bind_storage(void *cb, int32_t stage, int32_t index, uint64_t addr, int64_t size) {
    if (bp_on()) nx_log("bp: %p BindStorageBuffer stage %d index %d addr %#llx size %#llx", cb, stage, index,
                        (unsigned long long)addr, (long long)size);
}
void bp_bind_texture(void *cb, int32_t stage, int32_t index, uint64_t handle) {
    if (bp_on()) nx_log("bp: %p BindTexture stage %d index %d handle %#llx", cb, stage, index, (unsigned long long)handle);
}
void bp_bind_textures_deferred(void *cb, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5) {
    if (bp_on()) nx_log("bp: %p BindTexturesDeferred %#llx %#llx %#llx %#llx %#llx", cb, (unsigned long long)a1,
                        (unsigned long long)a2, (unsigned long long)a3, (unsigned long long)a4, (unsigned long long)a5);
}
void bp_bind_vertex_buffer(void *cb, int32_t index, uint64_t addr, int64_t size) {
    if (bp_on()) nx_log("bp: %p BindVertexBuffer %d addr %#llx size %#llx", cb, index, (unsigned long long)addr, (long long)size);
}
void bp_bind_vertex_attrib(void *cb, int32_t n, const uint32_t *attribs) {
    if (!bp_on()) return;
    nx_log("bp: %p BindVertexAttribState %d at %p", cb, n, attribs);
}
void bp_bind_vertex_stream(void *cb, int32_t n, const uint32_t *streams) {
    if (!bp_on()) return;
    nx_log("bp: %p BindVertexStreamState %d at %p", cb, n, streams);
}
void bp_draw_elements_instanced(void *cb, int32_t mode, int32_t type, int32_t count, uint64_t index_addr, int32_t base_vertex, int32_t base_instance, int32_t instances) {
    if (bp_on()) nx_log("bp: %p DrawElementsInstanced mode %d type %d count %d index %#llx baseVertex %d baseInstance %d instances %d", cb, mode, type, count, (unsigned long long)index_addr, base_vertex, base_instance, instances);
}
void bp_draw_elements(void *cb, int32_t mode, int32_t type, int32_t count, uint64_t index_addr) {
    if (bp_on()) nx_log("bp: %p DrawElements mode %d type %d count %d index %#llx", cb, mode, type, count, (unsigned long long)index_addr);
}
void bp_draw_arrays_instanced(void *cb, int32_t mode, int32_t first, int32_t count, int32_t base_instance, int32_t instances) {
    if (bp_on()) nx_log("bp: %p DrawArraysInstanced mode %d first %d count %d baseInstance %d instances %d", cb, mode, first, count, base_instance, instances);
}
void bp_window_origin_mode(void *device, int32_t mode) {
    static int n;
    if (n++ < 8) nx_log("bp: nvnDeviceSetWindowOriginMode(%d)", mode);   // 0 = lower left, 1 = upper left
}
void bp_depth_mode(void *device, int32_t mode) {
    static int n;
    if (n++ < 8) nx_log("bp: nvnDeviceSetDepthMode(%d)", mode);   // 0 = NEAR_IS_MINUS_W (-1..1), 1 = NEAR_IS_ZERO
}

// State-object sizes: log the first calls' object pointers (consecutive array elements).
#define SIZE_PROBE(fn, label)                                                              \
    void fn(void *obj) {                                                                   \
        static int n;                                                                      \
        if (getenv("NXRT_SIZEPROBE") && n++ < 24) nx_log("sz: %s %p", label, obj);         \
    }
SIZE_PROBE(sz_vattrib, "VertexAttribState")
SIZE_PROBE(sz_vstream, "VertexStreamState")
SIZE_PROBE(sz_blend, "BlendState")
SIZE_PROBE(sz_chmask, "ChannelMaskState")
SIZE_PROBE(sz_color, "ColorState")
SIZE_PROBE(sz_ds, "DepthStencilState")
SIZE_PROBE(sz_poly, "PolygonState")
SIZE_PROBE(sz_ms, "MultisampleState")
void bp_viewport(void *cb, int32_t x, int32_t y, int32_t w, int32_t h) {
    if (bp_on()) nx_log("bp: %p SetViewport %d %d %d %d", cb, x, y, w, h);
}
void bp_scissor(void *cb, int32_t x, int32_t y, int32_t w, int32_t h) {
    if (bp_on()) nx_log("bp: %p SetScissor %d %d %d %d", cb, x, y, w, h);
}

void bp_set_rt(void *cb, int32_t n, void *const *colors, void *depth) {
    if (!bp_on()) return;
    char buf[512];
    int o = 0;
    for (int i = 0; i < n && i < 8 && colors; i++) {
        int32_t w = 0, h = 0, f = 0;
        if (colors[i]) nx_nvn_texture_info(colors[i], &w, &h, &f);
        o += snprintf(buf + o, sizeof buf - o, " [%p %dx%d f%d]", colors[i], w, h, f);
    }
    int32_t w = 0, h = 0, f = 0;
    if (depth) nx_nvn_texture_info(depth, &w, &h, &f);
    nx_log("bp: %p SetRenderTargets %d:%s depth [%p %dx%d f%d]", cb, n, buf, depth, w, h, f);
}
