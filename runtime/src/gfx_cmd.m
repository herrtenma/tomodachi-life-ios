// Graphics step 4: NVN command buffers recorded on the host and replayed on Metal.
//
// Recording: every nvnCommandBuffer* call the game makes appends a small op to a per-command-
// buffer stream (thread-local fast path). EndRecording turns the stream into a handle;
// QueueSubmitCommands replays handles on one Metal queue.
//
// Binding model (see docs §7, measured on the game):
//   Maxwell cbuf slot = NVN uniform index + 3; slot 1 = the program's constant data
//   (code + control[0x700], size control[0x6FC]); slot 0 = unused by the game.
//   Shader texture handle h = 8 + 2 * NVN texture index (BindTexture or BindTexturesDeferred).
//   NVN texture handles are ours: texture id | sampler id << 20 | 1 << 32 (nvn.c).
//   Translated MSL: [[buffer(0)]] support buffer, guest cbufs/textures at the bindings listed in
//   work/shaders/spv/<hash>.json, sampler slot = texture binding % 16, vertex stream s at
//   [[buffer(29 - s)]], missing attributes read zeros from [[buffer(30)]].
// Buffers are read in place: each memory pool is one zero-copy MTLBuffer.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/stat.h>
#include <pthread.h>
#include <sys/mman.h>
#include <stdarg.h>
#include <stdatomic.h>

#include "gfx.h"
#include "gfx_internal.h"
#include "nvn_formats.h"
#include "nxrt.h"

#define KEY(p) ((__bridge id)(void *)(p))

// GPU safety. Bad draws can fault the GPU; macOS then resets it, and repeated resets once froze the
// whole Mac (2026-10-07). So:
//   NXRT_DRAW=1          execute the game's draws on the GPU (default: record only, nothing drawn)
//   NXRT_DRAW_LIMIT=N    execute at most N draws per frame (grow it step by step)
//   NXRT_DRAW=check      validate every draw on the CPU only; no render passes or draws reach the GPU
// and the first GPU error stops all GPU work and exits the process.
static volatile int g_gpu_dead;
static int draw_check_only(void) {
    static int on = -1;
    if (on < 0) on = getenv("NXRT_DRAW") && !strcmp(getenv("NXRT_DRAW"), "check");
    return on;
}
static int draws_enabled(void) {
    static int on = -1;
    if (on < 0) on = getenv("NXRT_DRAW") != NULL;
    return on && !g_gpu_dead;
}
// NXRT_SWEEP=<start frame>:<step>:<count>[:<base>]: frames start .. start+count-1 draw
// base + (f - start + 1) * step draws, and each is saved as a screenshot (gfx_metal.m); finds which
// draws produce an artifact.
int nx_sweep(int frame, long *limit) {
    static int start = -2, step, count, base;
    if (start == -2) {
        start = -1;
        if (getenv("NXRT_SWEEP")) sscanf(getenv("NXRT_SWEEP"), "%d:%d:%d:%d", &start, &step, &count, &base);
    }
    if (start < 0 || frame < start || frame >= start + count) return 0;
    if (limit) *limit = base + (long)(frame - start + 1) * step;
    return 1;
}
static long draw_limit(void) {
    static long n = -2;
    if (n == -2) n = getenv("NXRT_DRAW_LIMIT") ? atol(getenv("NXRT_DRAW_LIMIT")) : -1;
    extern volatile int g_gfx_frame;
    long sw;
    if (nx_sweep(g_gfx_frame, &sw)) return sw;
    return n;
}
static void gpu_failed(id<MTLCommandBuffer> c) {
    if (g_gfx_background) {   // iOS refuses GPU work from the background (the frame in flight when the app left): not fatal
        static int n;
        if (n++ < 8) nx_log("gfx: command buffer refused while in the background: %s", c.error.localizedDescription.UTF8String);
        return;
    }
    if (__atomic_exchange_n(&g_gpu_dead, 1, __ATOMIC_SEQ_CST)) return;
    nx_log("gfx: GPU ERROR, stopping: %s", c.error.localizedDescription.UTF8String);
    nx_log("gfx: no further GPU work is submitted; exiting so the GPU is not reset repeatedly");
    fflush(NULL);
    _exit(3);
}

static uint64_t g_vcheck_bad;
// getenv read once per call site (getenv walks the whole environment; several ran per draw or per op).
#define ENV(name) ({ static const char *env_v_ = (const char *)1; if (env_v_ == (const char *)1) env_v_ = getenv(name); env_v_; })
static int dbg(void) {
    static int on = -1;
    if (on < 0) on = getenv("NXRT_GFXDBG") != NULL;
    return on;
}

// ---- enum histograms (to check the NVN enum values assumed below against the game) ----
// Lock-free open addressing over (label pointer, value): called per draw from several threads, the old
// NSDictionary/NSCountedSet version under one mutex cost ~35% of the encode thread. The lock is only
// taken to claim an empty entry; a key is published by its label pointer (release), so lookups don't lock.
enum { HIST_N = 16384 };
static struct { const char *_Atomic what; long v; _Atomic unsigned long n; } g_hist[HIST_N];
static pthread_mutex_t g_hist_lock = PTHREAD_MUTEX_INITIALIZER;
static void hist(const char *what, long v) {
    if (!dbg()) return;
    size_t i = (((uintptr_t)what >> 3) * 0x9E3779B97F4A7C15ull ^ (uint64_t)v * 0xC2B2AE3D27D4EB4Full) >> 50;
    for (int probe = 0; probe < HIST_N; probe++, i = (i + 1) & (HIST_N - 1)) {
        const char *w = atomic_load_explicit(&g_hist[i].what, memory_order_acquire);
        if (!w) {
            pthread_mutex_lock(&g_hist_lock);
            w = atomic_load_explicit(&g_hist[i].what, memory_order_relaxed);
            if (!w) g_hist[i].v = v, atomic_store_explicit(&g_hist[i].what, w = what, memory_order_release);
            pthread_mutex_unlock(&g_hist_lock);
        }
        if (w == what && g_hist[i].v == v) { atomic_fetch_add_explicit(&g_hist[i].n, 1, memory_order_relaxed); return; }
    }
}
// NXRT_STAGETIME=1: encode time per draw() stage, printed as us/draw with the stats (Step 0 of the
// encode performance plan). Off by default: the timers themselves cost a little per draw.
enum { ST_PREP, ST_VALIDATE, ST_FEEDBACK, ST_PASS, ST_PIPE, ST_STATE, ST_BIND_VS, ST_BIND_FS, ST_DRAW, ST_N };
static const char *const g_st_name[ST_N] = {"prep", "validate", "feedback", "begin_pass", "pipeline", "state", "bind vs", "bind fs", "vb/ib+draw"};
static uint64_t g_st_ticks[ST_N + 1], g_st_calls;   // [ST_N] = whole draw() calls, early returns included
static int stagetime(void) {
    static int on = -1;
    if (on < 0) on = getenv("NXRT_STAGETIME") != NULL;
    return on;
}
#define ST_MARK(k) do { if (st_on) { uint64_t st_n = mach_absolute_time(); g_st_ticks[k] += st_n - st_t; st_t = st_n; } } while (0)
static int hist_cmp(const void *a, const void *b) {
    const size_t *x = a, *y = b;
    int c = strcmp(g_hist[*x].what, g_hist[*y].what);
    return c ? c : (g_hist[*x].v > g_hist[*y].v) - (g_hist[*x].v < g_hist[*y].v);
}
void gfx_hist_dump(void) {
    if (!dbg()) return;
    static size_t idx[HIST_N];
    size_t n = 0;
    for (size_t i = 0; i < HIST_N; i++)
        if (atomic_load_explicit(&g_hist[i].what, memory_order_acquire)) idx[n++] = i;
    qsort(idx, n, sizeof *idx, hist_cmp);   // equal labels from different call sites merge into one line
    for (size_t i = 0; i < n;) {
        const char *k = g_hist[idx[i]].what;
        NSMutableString *line = [NSMutableString string];
        for (; i < n && !strcmp(g_hist[idx[i]].what, k); i++)
            [line appendFormat:@" %ldx%lu", g_hist[idx[i]].v, atomic_load_explicit(&g_hist[idx[i]].n, memory_order_relaxed)];
        nx_log("gfx: enum %s:%s", k, line.UTF8String);
    }
}

// ---- state objects (the game owns the memory; sizes measured or from the NVN headers) ----
typedef struct { uint32_t format : 9, stream : 5, offset : 18; } NvVAttr;       // 4 bytes (measured)
typedef struct { uint32_t stride, divisor; } NvVStream;                           // 8 bytes (measured)
typedef struct { uint8_t target, src, dst, srca, dsta, eq, eqa, pad; } NvBlend;   // 8
typedef struct { uint8_t blend_mask, logic_op, alpha_test, pad; } NvColor;         // 4
typedef struct { uint32_t write; } NvChMask;                                       // 4: bit 4*i+c = channel c of target i on
typedef struct { uint64_t dt : 1, dw : 1, df : 4, st : 1, sff : 4, sfb : 4, ff : 4, fzf : 4, fzp : 4, bf : 4, bzf : 4, bzp : 4; } NvDS; // 8
typedef struct { uint32_t cull : 2, front : 1, mode : 2, offset : 3; } NvPoly;    // 4
typedef struct { uint8_t enable, samples, a2c, pad; } NvMS;                        // 4
_Static_assert(sizeof(NvVAttr) == 4 && sizeof(NvVStream) == 8 && sizeof(NvBlend) == 8 && sizeof(NvColor) == 4 &&
               sizeof(NvChMask) == 4 && sizeof(NvDS) == 8 && sizeof(NvPoly) == 4 && sizeof(NvMS) == 4, "NVN state sizes");

static void vattr_defaults(NvVAttr *a) { memset(a, 0, sizeof *a); }
static void vattr_set_format(NvVAttr *a, int32_t fmt, int64_t offset) {
    a->format = fmt; a->offset = (uint32_t)offset;
    hist("vertex format", fmt);
}
static void vattr_set_stream(NvVAttr *a, int32_t s) { a->stream = s; }
static void vstream_defaults(NvVStream *s) { memset(s, 0, sizeof *s); }
static void vstream_set_stride(NvVStream *s, int64_t stride) { s->stride = (uint32_t)stride; }
static void vstream_set_divisor(NvVStream *s, int32_t d) { s->divisor = d; }
static void blend_defaults(NvBlend *b) { *b = (NvBlend){0, 2, 1, 2, 1, 1, 1, 0}; }   // ONE, ZERO, ADD
static void blend_set_target(NvBlend *b, int32_t t) { b->target = t; }
static void blend_set_func(NvBlend *b, int32_t s, int32_t d, int32_t sa, int32_t da) {
    b->src = s; b->dst = d; b->srca = sa; b->dsta = da;
    hist("blend func", s * 1000 + d);
}
static void blend_set_eq(NvBlend *b, int32_t rgb, int32_t a) { b->eq = rgb; b->eqa = a; hist("blend eq", rgb); }
static void color_defaults(NvColor *c) { *c = (NvColor){0, 3, 8, 0}; }                 // no blend, COPY, ALWAYS
static void color_set_blend(NvColor *c, int32_t i, int32_t on) {
    if (i >= 0 && i < 8) c->blend_mask = (c->blend_mask & ~(1 << i)) | (!!on << i);
}
static void color_set_logic_op(NvColor *c, int32_t op) { c->logic_op = op; hist("logic op", op); }
static void color_set_alpha_test(NvColor *c, int32_t f) { c->alpha_test = f; hist("alpha test", f); }
static void chmask_defaults(NvChMask *m) { m->write = 0xFFFFFFFF; }
static void chmask_set(NvChMask *m, int32_t i, int32_t r, int32_t g, int32_t b, int32_t a) {
    if (i < 0 || i >= 8) return;
    uint32_t bits = !!r | !!g << 1 | !!b << 2 | !!a << 3;
    m->write = (m->write & ~(0xFu << 4 * i)) | bits << 4 * i;
}
static void ds_defaults(NvDS *d) {
    memset(d, 0, sizeof *d);
    d->dw = 1; d->df = 2;                                                          // write on, LESS
    d->sff = d->sfb = 8;                                                           // ALWAYS
    d->ff = d->fzf = d->fzp = d->bf = d->bzf = d->bzp = 1;                         // KEEP
}
static void ds_set_depth_test(NvDS *d, int32_t on) { d->dt = !!on; }
static void ds_set_depth_write(NvDS *d, int32_t on) { d->dw = !!on; }
static void ds_set_depth_func(NvDS *d, int32_t f) { d->df = f; hist("depth func", f); }
static void ds_set_stencil_test(NvDS *d, int32_t on) { d->st = !!on; }
static void ds_set_stencil_func(NvDS *d, int32_t face, int32_t f) {
    if (face & 1) d->sff = f;
    if (face & 2) d->sfb = f;
    hist("stencil func", f);
}
static void ds_set_stencil_op(NvDS *d, int32_t face, int32_t fail, int32_t zfail, int32_t zpass) {
    if (face & 1) d->ff = fail, d->fzf = zfail, d->fzp = zpass;
    if (face & 2) d->bf = fail, d->bzf = zfail, d->bzp = zpass;
    hist("stencil op", fail * 100 + zfail * 10 + zpass);
}
static void poly_defaults(NvPoly *p) { *p = (NvPoly){0, 1, 2, 0}; }                     // no cull, CCW, FILL
static void poly_set_cull(NvPoly *p, int32_t f) { p->cull = f; hist("cull face", f); }
static void poly_set_front(NvPoly *p, int32_t f) { p->front = f; hist("front face", f); }
static void poly_set_mode(NvPoly *p, int32_t m) { p->mode = m; hist("polygon mode", m); }
static void poly_set_offset(NvPoly *p, int32_t bits) {
    static uint32_t seen;   // each distinct enable mask once
    if (bits >= 0 && bits < 32 && !(__atomic_fetch_or(&seen, 1u << bits, __ATOMIC_RELAXED) & (1u << bits)))
        nx_log("gfx: PolygonOffsetEnables %#x (first use)", bits);
    p->offset = bits;
}
static void rtdump_note(const void *tex);
static void ms_defaults(NvMS *m) { *m = (NvMS){1, 0, 0, 0}; }
static void ms_set_enable(NvMS *m, int32_t on) { m->enable = !!on; }
static void ms_set_samples(NvMS *m, int32_t n) { m->samples = n; }
static void ms_set_a2c(NvMS *m, int32_t on) { m->a2c = !!on; }

// ---- texture / sampler pools ---------------------------------------------------------
typedef struct { const void *tex; NxTexView view; int has_view; const void *pool; } TexSlot;
static TexSlot *g_texslots;
static NxSamplerState *g_smpslots;
static int g_ntex, g_nsmp;
static pthread_mutex_t g_pool_lock = PTHREAD_MUTEX_INITIALIZER;

static volatile uint64_t g_tex_gen = 1;   // texture bind cache generation (see bind_stage)
typedef struct {
    uint64_t gen;
    const void *tex;
    uintptr_t base;                         // gfx_texture_mtl(tex): the Metal texture t was made from
    uint16_t view_sw;
    int16_t view_fmt;
    MTLTextureType type;
    __unsafe_unretained id<MTLTexture> t;   // kept alive by the texture/view caches until its base is
                                            // dropped (gfx_texture_dropped invalidates those entries)
} TexBindCache;
enum { TEXCACHE_N = 4096 };
static TexBindCache g_bindcache[TEXCACHE_N];
// Registrations and drops invalidate only the entries they affect (bumping the generation for each wiped the
// whole cache ~40 times a frame: 2/3 of all misses were stale entries). An entry is invalidated by zeroing its
// generation, which leaves t readable for a bind racing on another thread, as a generation bump did.
// NXRT_TEXGEN_ALL=1: the old global bump.
static int texgen_all(void) {
    static int on = -1;
    if (on < 0) on = getenv("NXRT_TEXGEN_ALL") != NULL;
    return on;
}
static void bindcache_forget(const void *tex, uintptr_t base) {
    for (int i = 0; i < TEXCACHE_N; i++)
        if ((tex && g_bindcache[i].tex == tex) || (base && g_bindcache[i].base == base)) g_bindcache[i].gen = 0;
}
// gfx_texture_mtl on the encode thread, cached per submit (g_tex_gen, from BOTW): each texture still goes through
// texture_mtl (registry lock, LRU mark, re-upload check) once per submit, as the bind cache does, instead of at every
// pass, feedback draw and bind-cache miss (texture_mtl was ~7% of the island's encode). Only the encode thread fills
// an entry; gfx_texture_dropped (any thread) zeroes the gen of a dropped texture's entries, and tmc_sweep lets go of
// them at the next submit so dropped textures aren't kept alive. A drop while an entry is being filled leaves it
// uncached (g_tmc_drops). NXRT_TMC=0 off.
enum { TMC_N = 4096 };
static struct { const void *tex; _Atomic uint64_t gen; _Atomic uintptr_t base; __strong id<MTLTexture> t; } g_tmc[TMC_N];
static _Atomic uint64_t g_tmc_drops;
static int tmc_on(void) {
    static int on = -1;
    if (on < 0) on = !getenv("NXRT_TMC") || atoi(getenv("NXRT_TMC"));
    return on;
}
static id<MTLTexture> tex_mtl_cached(const void *tex) {
    if (!tex) return nil;
    if (!tmc_on()) return gfx_texture_mtl(tex);
    __typeof__(&g_tmc[0]) c = &g_tmc[((uintptr_t)tex >> 4) * 0x9E3779B97F4A7C15ull >> 52];
    if (c->tex != tex || atomic_load_explicit(&c->gen, memory_order_acquire) != g_tex_gen) {
        uint64_t drops = atomic_load_explicit(&g_tmc_drops, memory_order_acquire);
        atomic_store_explicit(&c->gen, 0, memory_order_release);
        id<MTLTexture> t = gfx_texture_mtl(tex);
        c->tex = tex, c->t = t;
        atomic_store_explicit(&c->base, (uintptr_t)(__bridge void *)t, memory_order_release);
        if (atomic_load_explicit(&g_tmc_drops, memory_order_acquire) != drops) return t;   // a drop meanwhile: maybe this one
        atomic_store_explicit(&c->gen, g_tex_gen, memory_order_release);
    }
    return c->t;
}
static void tmc_dropped(uintptr_t base) {   // any thread
    atomic_fetch_add_explicit(&g_tmc_drops, 1, memory_order_acq_rel);
    for (int i = 0; i < TMC_N; i++)
        if (atomic_load_explicit(&g_tmc[i].base, memory_order_acquire) == base) atomic_store_explicit(&g_tmc[i].gen, 0, memory_order_release);
}
static void tmc_sweep(void) {   // encode thread, once per submit
    for (int i = 0; i < TMC_N; i++)
        if (g_tmc[i].t && !atomic_load_explicit(&g_tmc[i].gen, memory_order_acquire))
            g_tmc[i].t = nil, g_tmc[i].tex = NULL, atomic_store_explicit(&g_tmc[i].base, 0, memory_order_release);
}
static void texpool_register(void *pool, int32_t id, const void *tex, const NxTexView *view) {
    if (texgen_all()) g_tex_gen++;
    else bindcache_forget(tex, 0);
    hist("texgen bumps: 0 register, 1 drop, 2 submit", 0);
    if (id < 0 || id >= (1 << 20)) return;
    pthread_mutex_lock(&g_pool_lock);
    if (id >= g_ntex) {
        int n = id + 1024;
        g_texslots = realloc(g_texslots, n * sizeof *g_texslots);
        memset(g_texslots + g_ntex, 0, (n - g_ntex) * sizeof *g_texslots);
        g_ntex = n;
    }
    if (dbg()) {   // audit: one global table for all texture pools; count pools and cross-pool id reuse
        static void *pools[16];
        static int npools, collisions;
        int k = 0;
        while (k < npools && pools[k] != pool) k++;
        if (k == npools && npools < 16) { pools[npools++] = pool; nx_log("gfx: audit: texture pool #%d %p (first id %d)", k, pool, id); }
        if (g_texslots[id].tex && g_texslots[id].tex != tex && g_texslots[id].pool != pool && collisions++ < 10)
            nx_log("gfx: audit: texture id %d registered in pool %p after pool %p (different texture)", id, pool, g_texslots[id].pool);
    }
    g_texslots[id].pool = pool;
    g_texslots[id].tex = tex;
    g_texslots[id].has_view = view != NULL;
    if (view) g_texslots[id].view = *view;
    pthread_mutex_unlock(&g_pool_lock);
}
static void smppool_register(void *pool, int32_t id, const NxSamplerState *s) {
    if (id < 0 || id >= (1 << 12) || !s) return;
    pthread_mutex_lock(&g_pool_lock);
    if (id >= g_nsmp) {
        int n = id + 256;
        g_smpslots = realloc(g_smpslots, n * sizeof *g_smpslots);
        memset(g_smpslots + g_nsmp, 0, (n - g_nsmp) * sizeof *g_smpslots);
        g_nsmp = n;
    }
    g_smpslots[id] = *s;
    hist("sampler min", s->min);
    hist("sampler mag", s->mag);
    hist("sampler wrap", s->wrap_s);
    hist("sampler compare", s->cmp_mode * 100 + s->cmp_func);
    pthread_mutex_unlock(&g_pool_lock);
}

// ---- recording -----------------------------------------------------------------------
enum {
    OP_RT = 1, OP_CLEAR_COLOR, OP_CLEAR_DS, OP_CLEAR_TEX, OP_PROGRAM, OP_UBO, OP_SSBO, OP_TEX, OP_TEX_DEFERRED,
    OP_VBUF, OP_VATTR, OP_VSTREAM, OP_BLEND, OP_COLOR, OP_CHMASK, OP_DS, OP_POLY, OP_MS, OP_BLEND_COLOR,
    OP_VIEWPORT, OP_SCISSOR, OP_DEPTH_RANGE, OP_POLY_OFFSET, OP_DEPTH_CLAMP, OP_STENCIL, OP_DRAW_ELEM,
    OP_DRAW_ARRAYS, OP_UPDATE_UBO, OP_DISCARD, OP_SIGNAL_EVENT, OP_REPORT_COUNTER, OP_COPY_TEX, OP_DISPATCH, OP_RENDER_ENABLE,
    OP_MARK,   // NXRT_VCHECK=2: which list a CallCommands inlined here (diagnostics only)
    OP_BARRIER,
};
typedef struct { uint32_t type : 8, size : 24; } OpHdr;
typedef struct { int32_t n; const void *color[8]; const void *depth; int16_t level[8], layer[8], dlevel, dlayer, vfmt[8]; } OpRT;   // views: level / layer / format
typedef struct { int32_t index, mask; float rgba[4]; } OpClearColor;
typedef struct { float depth; int32_t depth_mask, stencil, stencil_mask; } OpClearDS;
typedef struct { const void *tex; int32_t region[6], has_region, mask, level, nlevels, layer, nlayers; float rgba[4]; } OpClearTex;
typedef struct { int32_t n; NxStage st[6]; } OpProgram;
typedef struct { int32_t stage, index; uint64_t addr, size; } OpBuf;
typedef struct { int32_t stage, index; uint64_t handle; } OpTex;
typedef struct { int32_t stage, first, count; const uint64_t *handles; } OpTexDeferred;
typedef struct { int32_t n; NvVAttr a[32]; } OpVAttr;
typedef struct { int32_t n; NvVStream s[32]; } OpVStream;
typedef struct { float x, y, w, h; } OpRect;
typedef struct { int32_t face, ref, mask, vmask, which; } OpStencil;
typedef struct { int32_t mode, type, count, base_vertex, base_instance, instances; uint64_t index_addr; } OpDrawElem;
typedef struct { int32_t mode, first, count, base_instance, instances; } OpDrawArrays;
typedef struct { uint64_t addr; int64_t offset, size, buf_size; uint8_t data[]; } OpUpdateUbo;
typedef struct { int32_t x, y, z; } OpDispatch;   // workgroup counts
typedef struct { int32_t mode; const uint64_t *counters; } OpRenderEnable;   // mode: 0 off, 1 on, 2/3 conditional EQUAL / NOT_EQUAL

typedef struct { const void *src, *dst; int32_t sreg[6], dreg[6], flags, slevel, slayer, dlevel, dlayer; } OpCopyTex;   // regions: x, y, z, w, h, d
typedef struct { uint32_t *mem; int32_t mode; uint32_t value; } OpSignal;      // mode 0 write, 1 add
typedef struct { uint64_t *mem; int32_t type; } OpCounter;

// cm_*: the command memory the game gave this command buffer (GPU addresses, see the list lifetime below): the chunk
// of the last AddCommandMemory, the cursor where the next list starts, the cursor at BeginRecording, and whether
// memory was added since then; the last list ended here (handle, start) for listgc_trim_last.
typedef struct Rec { const void *cb; uint8_t *p; size_t len, cap; uint64_t cm_lo, cm_hi, cm_cur, cm_beg, cm_last_h, cm_last_lo; int cm_new; uint32_t cm_site; } Rec;
enum { REC_SLOTS = 4096 };
static Rec *g_recs[REC_SLOTS];
static pthread_mutex_t g_rec_lock = PTHREAD_MUTEX_INITIALIZER;
static __thread struct { uint32_t emits, begins, ends, calls, after_begin; const void *begin_cb, *emit_cb; void *begin_rec, *emit_rec; size_t len_at_end; } tl_recstat;   // NXRT_CHUNKPROBE
static __thread const void *tl_cb;
static __thread Rec *tl_rec;

static Rec *rec_get(const void *cb) {
    if (tl_cb == cb && tl_rec) return tl_rec;
    pthread_mutex_lock(&g_rec_lock);
    unsigned i = (unsigned)((uintptr_t)cb >> 4) & (REC_SLOTS - 1);
    while (g_recs[i] && g_recs[i]->cb != cb) i = (i + 1) & (REC_SLOTS - 1);
    if (!g_recs[i]) {
        g_recs[i] = calloc(1, sizeof(Rec));
        g_recs[i]->cb = cb;
    }
    Rec *r = g_recs[i];
    pthread_mutex_unlock(&g_rec_lock);
    tl_cb = cb;
    tl_rec = r;
    return r;
}

static uint64_t g_rec_ops[40], g_exec_ops[40], g_ended, g_submitted, g_called;
static uint64_t g_raw_midrec;   // recordings whose raw-write pointers were set mid-recording (stats)
static void emit(const void *cb, int type, const void *payload, size_t size) {
    __atomic_fetch_add(&g_rec_ops[type], 1, __ATOMIC_RELAXED);
    {   // the engine's inline fast paths write raw methods at [cb+0] while [cb+0] + n <= [cb+8]; we keep
        // both 0 so it always uses the API. Who sets them mid-recording?
        uint64_t *f = (uint64_t *)cb;
        if (f[0] || f[1]) {
            static int n;
            if (n++ < 12)
                nx_log("gfx: raw-write pointers set mid-recording on %p before op %d: [cb+0] %#llx [cb+8] %#llx (diff %lld)", cb, type,
                       (unsigned long long)f[0], (unsigned long long)f[1], (long long)(f[1] - f[0]));
            __atomic_fetch_add(&g_raw_midrec, 1, __ATOMIC_RELAXED);
            f[0] = f[1] = 0;
        }
    }
    Rec *r = rec_get(cb);
    tl_recstat.emits++, tl_recstat.emit_cb = cb, tl_recstat.emit_rec = r, tl_recstat.after_begin++;
    size_t need = sizeof(OpHdr) + ((size + 7) & ~7ul);
    if (r->len + need > r->cap) {
        r->cap = (r->len + need) * 2 + 4096;
        r->p = realloc(r->p, r->cap);
    }
    OpHdr h = {.type = type, .size = (uint32_t)((size + 7) & ~7ul)};
    memcpy(r->p + r->len, &h, sizeof h);
    memcpy(r->p + r->len + sizeof h, payload, size);
    r->len += need;
}

// Recorded handles, in two generations: when the current one holds HANDLE_GEN_BYTES (and at least
// HANDLE_KEEP handles) the old generation is dropped and the current one becomes old. Using a handle from the old generation moves it back,
// so lists recorded at boot and replayed every frame stay alive. (A full scan for unused handles
// every 1024 recordings, under the lock the recording threads need, cost ~10 scans per frame.)
enum { HANDLE_KEEP = 8192, HANDLE_GEN_BYTES = 64 << 20 };
static uint64_t g_handles_bytes;   // bytes recorded into the current generation
static pthread_mutex_t g_handle_lock = PTHREAD_MUTEX_INITIALIZER;
// Recorded op streams, keyed by handle: a C open-addressing table (NSNumber-keyed dictionaries
// were the hot spot once the engine issued ~20k CallCommands/frame). Blobs dropped by the collector
// wait in a grave table for one more round before they are freed (see handle_lookup).
typedef struct { size_t len; uint32_t end_lr; int refs, dead; uint8_t bytes[]; } Blob;   // end_lr: guest site of EndRecording;
                                                                                    // refs/dead: NXRT_LISTGC=2 (see listgc below)
typedef struct { uint64_t handle; uint32_t end_lr, call_lr; } OpMark;
typedef struct { uint64_t *keys; Blob **vals; size_t cap, count; } HTab;
static HTab g_hcur, g_hold;

static size_t ht_slot(const HTab *t, uint64_t k) { return (size_t)((k * 0x9E3779B97F4A7C15ull) >> 20) & (t->cap - 1); }
static Blob *ht_get(const HTab *t, uint64_t k) {
    if (!t->cap) return NULL;
    for (size_t i = ht_slot(t, k);; i = (i + 1) & (t->cap - 1)) {
        if (!t->keys[i]) return NULL;
        if (t->keys[i] == k) return t->vals[i];
    }
}
static void ht_put(HTab *t, uint64_t k, Blob *v) {
    if ((t->count + 1) * 2 > t->cap) {   // grow, keeping load <= 1/2
        HTab n = {calloc(t->cap ? t->cap * 2 : 1024, 8), calloc(t->cap ? t->cap * 2 : 1024, 8), t->cap ? t->cap * 2 : 1024, 0};
        for (size_t i = 0; i < t->cap; i++)
            if (t->keys[i]) ht_put(&n, t->keys[i], t->vals[i]);
        free(t->keys), free(t->vals);
        *t = n;
    }
    size_t i = ht_slot(t, k);
    while (t->keys[i] && t->keys[i] != k) i = (i + 1) & (t->cap - 1);
    if (!t->keys[i]) t->count++;
    t->keys[i] = k;
    t->vals[i] = v;
}
static void ht_del(HTab *t, uint64_t k) {   // linear probing: backward-shift deletion
    if (!t->cap) return;
    size_t i = ht_slot(t, k);
    while (t->keys[i] != k) {
        if (!t->keys[i]) return;
        i = (i + 1) & (t->cap - 1);
    }
    t->count--;
    for (size_t j = i;;) {
        t->keys[i] = 0;
        for (;;) {
            j = (j + 1) & (t->cap - 1);
            if (!t->keys[j]) return;
            size_t h = ht_slot(t, t->keys[j]);
            if (i <= j ? (i < h && h <= j) : (i < h || h <= j)) continue;   // home lies cyclically in (i, j]
            break;
        }
        t->keys[i] = t->keys[j], t->vals[i] = t->vals[j];
        i = j;
    }
}

// Generations: cur (recorded or used since the last rotation), hold (the previous one), scan (the
// one before, being scanned by the background collector) and grave (dropped by the last scan but
// kept one more round: a lookup brings a list back, which covers handles the game moved while the
// scan ran). Lookups move a handle to cur (from scan they share the blob: the collector keeps it).
static HTab g_hscan, g_hgrave;
static const Blob *g_empty_blob_p(void);
static Blob *listgc_unretire(uint64_t h);
static int g_scanning;   // a background scan of g_hscan is running
static const Blob *handle_lookup(uint64_t h) {   // g_handle_lock held
    if (h == (0x7E56ull << 48 | 1)) return g_empty_blob_p();   // LIST_EMPTY (listgc below)
    Blob *d = ht_get(&g_hcur, h);
    if (d) return d;
    if ((d = ht_get(&g_hold, h))) {
        ht_del(&g_hold, h);
        ht_put(&g_hcur, h, d);
    } else if ((d = ht_get(&g_hscan, h))) {
        ht_put(&g_hcur, h, d);   // g_hscan stays unchanged while the collector reads it
    } else if ((d = ht_get(&g_hgrave, h))) {
        ht_del(&g_hgrave, h);
        ht_put(&g_hcur, h, d);
        static uint64_t back;
        if (back++ % 1000 == 0) nx_log("gfx: handle GC: %llu dropped lists brought back by a later use", (unsigned long long)back);
    } else if ((d = listgc_unretire(h))) {
        ht_put(&g_hcur, h, d);
    }
    return d;
}
// Conservative reachability: a handle of the scanned generation survives if its value appears
// anywhere in guest memory (heap, every writable mapped region, module data/bss). Baked lists (e.g.
// main+0x402a74's model lists) are first called long after they are recorded; only unreferenced
// handles are dropped. Pages that were never touched are skipped (mincore), so the scan doesn't
// fault in untouched heap. Pages macOS compressed or swapped out (MINCORE_PAGED_OUT) must be read
// too: skipping them dropped live lists whose handles sat in idle memory (model/mesh lists recorded
// at load), ~100k dropped calls by frame 1800 in GPU runs. Their draws inherited other meshes' state.
// (NVN pools can't be skipped: the engine keeps its own structures there, 500k+ handles found.)
// The scan runs on its own thread (it reads ~2 GB, 0.3-1.4 s): it only reads g_hscan and guest
// memory, and collects the referenced handles; the swap itself is a few pointer moves.
static uint64_t g_scan_paged_out;   // pages read because they were compressed/swapped (stats)
static uint64_t g_swaps, g_swap_ns, g_encode_ns, g_gpu_ns;   // timing stats since the last gfx_draw_stats
// GPU busy time: the union of command buffer [GPUStartTime, GPUEndTime] intervals. Command buffers overlap
// at their edges, so the plain sum (g_gpu_ns) counts the overlap twice. Completion handlers run in order.
static uint64_t g_gpu_busy_ns, g_gpu_last_end_ns;
// GPU-busy clock for counter timestamps (ns): advances only while our command buffers execute (union of
// GPUStartTime..GPUEndTime, in completion order), so the engine's GPU frame timer measures GPU work, not our
// CPU encoding or the gaps where the GPU waits for it. NXRT_GPU_TIME_SCALE=<f> scales it (e.g. 2 = act like
// a GPU half as fast, to test the game's own detail scaling).
static pthread_mutex_t g_vclock_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_vclock_ns, g_vclock_last_end;
static uint64_t g_draw_seq, g_cmd_first_draw;   // encoded draws (never reset): a report's place in its command buffer
typedef struct { uint64_t *mem; int32_t type; uint64_t pos; } CounterWrite;
typedef struct { uint64_t *k; size_t n, cap; } KeyList;
static void scan_collect_referenced(const uint8_t *base, size_t size, KeyList *found) {
    const size_t page = 0x4000, chunk = 1 << 20;
    char vec[(1 << 20) / 0x4000 + 2];   // one entry per 16 KB page; +2 slack
    uintptr_t a = (uintptr_t)base & ~(uintptr_t)(page - 1);   // mincore counts pages from a page-aligned start
    size = (((uintptr_t)base + size + page - 1) & ~(uintptr_t)(page - 1)) - a;
    base = (const uint8_t *)a;
    for (size_t off = 0; off < size; off += chunk) {
        size_t n = MIN(chunk, size - off);
        if (mincore((void *)(base + off), n, vec)) continue;
        for (size_t pg = 0; pg * page < n; pg++) {
            if (!(vec[pg] & (MINCORE_INCORE | MINCORE_PAGED_OUT))) continue;
            const uint64_t *w = (const uint64_t *)(base + off + pg * page);
            if (!(vec[pg] & MINCORE_INCORE)) g_scan_paged_out++;
            for (size_t i8 = 0; i8 < page / 8; i8 += 8) {
                uint64_t any = 0;   // branch-free test of 8 words (NEON compares): almost no group holds a tag (BOTW: scans 5x faster)
                for (size_t j = 0; j < 8; j++) any |= (w[i8 + j] >> 48) == 0x7E57;
                if (!any) continue;
                for (size_t i = i8; i < i8 + 8; i++) {
                    if ((w[i] >> 48) != 0x7E57 || !ht_get(&g_hscan, w[i])) continue;
                    if (found->n == found->cap) found->cap = found->cap * 2 + 4096, found->k = realloc(found->k, found->cap * 8);
                    found->k[found->n++] = w[i];
                }
            }
        }
    }
}
static void *handle_scan_thread(void *arg) {
    // The scan reads the whole guest heap: on the efficiency cores, so it doesn't take a performance core from the game
    // or the encoder; at the render thread's level only while it holds g_handle_lock (EndRecording and submits take
    // it). Utility, not background: iOS throttles background threads hard (BOTW on the iPhone 14: 3-7 s scans).
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    KeyList found = {0};
    scan_collect_referenced((const uint8_t *)g_as.heap_base, g_as.heap_used, &found);
    uint64_t rb, rs;
    uint32_t rp;
    for (int r = 0; nx_region_get(r, &rb, &rs, &rp); r++)   // every writable guest region (stacks, aliases, ...)
        if ((rp & PERM_RW) == PERM_RW) scan_collect_referenced((const uint8_t *)rb, rs, &found);
    for (int i = 0; i < g_image.nmod; i++) {
        Module *m = &g_image.mod[i];
        scan_collect_referenced(m->base + m->data_off, m->size - m->data_off, &found);
    }
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    pthread_mutex_lock(&g_handle_lock);
    // Free what the previous scan dropped and nobody used since, then sort this generation: used
    // meanwhile (already in cur/hold), referenced (back to cur) or dropped (to the grave).
    for (size_t i = 0; i < g_hgrave.cap; i++)
        if (g_hgrave.keys[i]) free(g_hgrave.vals[i]);
    free(g_hgrave.keys), free(g_hgrave.vals);
    memset(&g_hgrave, 0, sizeof g_hgrave);
    size_t kept = 0, dropped = 0, used = 0;
    for (size_t i = 0; i < found.n; i++) {
        Blob *b = ht_get(&g_hscan, found.k[i]);
        if (b && !ht_get(&g_hcur, found.k[i]) && !ht_get(&g_hold, found.k[i])) ht_put(&g_hcur, found.k[i], b), kept++;
    }
    for (size_t i = 0; i < g_hscan.cap; i++) {
        uint64_t k = g_hscan.keys[i];
        if (!k || ht_get(&g_hcur, k) || ht_get(&g_hold, k)) {
            if (k) used++;
            continue;
        }
        ht_put(&g_hgrave, k, g_hscan.vals[i]);
        dropped++;
    }
    used -= kept;
    free(g_hscan.keys), free(g_hscan.vals);
    memset(&g_hscan, 0, sizeof g_hscan);
    g_scanning = 0;
    uint64_t ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;
    g_swaps++, g_swap_ns += ns;
    static int nlog;
    if (nlog++ < 20)
        nx_log("gfx: handle GC (background): %zu referenced, %zu used meanwhile, %zu dropped (recoverable one more round), "
               "scan %.1f ms (%llu paged-out pages read so far)",
               kept, used, dropped, ns / 1e6, (unsigned long long)g_scan_paged_out);
    pthread_mutex_unlock(&g_handle_lock);
    free(found.k);
    return NULL;
}
static int handle_swap_generations(void) {   // g_handle_lock held; 0 if a scan is still running
    if (g_scanning) return 0;   // rotate on a later recording
    g_hscan = g_hold;
    g_hold = g_hcur;
    memset(&g_hcur, 0, sizeof g_hcur);
    if (!g_hscan.count) return 1;
    g_scanning = 1;
    pthread_t t;
    pthread_create(&t, NULL, handle_scan_thread, NULL);
    pthread_detach(t);
    return 1;
}

// Handles carry a tag so they stand out in memory scans (real NVN handles are GPU addresses).
static uint64_t g_next_handle = 0x7E57000000001000ull;
// Autosubmit: handles ended since the last QueueSubmitCommands, in EndRecording order. The engine
// does not submit worker lists while memory used reads 0, so we execute them before each submit.
static NSMutableArray<NSNumber *> *g_pending;
static NSMutableSet<NSNumber *> *g_called_set;   // handles the engine itself inlined with CallCommands (not autosubmitted)

// ---- List lifetime by command memory (NXRT_LISTGC) ----
// Real NVN: a handle names commands written into the command memory the game gave its command buffer. Once the game
// gives that memory to another recording (AddCommandMemory over it) the old commands are overwritten, so it never calls
// that handle again. agl sub-allocates each recording from pool rings by what GetCommandMemoryUsed reports, so a list
// lives in [start, start + reported size) of its command buffer's memory and dies when an AddCommandMemory overlaps
// that range. The size the game passes to AddCommandMemory is not what it owns: agl hands over free heap space (0x200
// every time), records, then keeps only the bytes reported used, so the next recording may start inside that 0x200.
// Hence a list dies when a later list's own range (written bytes) overlaps it, not the added range. NXRT_LISTGC=1 (shadow): ranges are tracked next to the memory-scan collector, and a list called after
// its memory was reused is logged.
typedef struct { uint64_t *keys, *a, *b; size_t cap, count; } LTab;   // handle -> two words
static size_t lt_slot(const LTab *t, uint64_t k) { return (size_t)((k * 0x9E3779B97F4A7C15ull) >> 20) & (t->cap - 1); }
static int lt_get(const LTab *t, uint64_t k, uint64_t *a, uint64_t *b) {
    if (!t->cap) return 0;
    for (size_t i = lt_slot(t, k);; i = (i + 1) & (t->cap - 1)) {
        if (!t->keys[i]) return 0;
        if (t->keys[i] == k) {
            if (a) *a = t->a[i];
            if (b) *b = t->b[i];
            return 1;
        }
    }
}
static void lt_put(LTab *t, uint64_t k, uint64_t a, uint64_t b) {
    if ((t->count + 1) * 2 > t->cap) {
        size_t nc = t->cap ? t->cap * 2 : 4096;
        LTab n = {calloc(nc, 8), calloc(nc, 8), calloc(nc, 8), nc, 0};
        for (size_t i = 0; i < t->cap; i++)
            if (t->keys[i]) lt_put(&n, t->keys[i], t->a[i], t->b[i]);
        free(t->keys), free(t->a), free(t->b);
        *t = n;
    }
    size_t i = lt_slot(t, k);
    while (t->keys[i] && t->keys[i] != k) i = (i + 1) & (t->cap - 1);
    if (!t->keys[i]) t->count++;
    t->keys[i] = k, t->a[i] = a, t->b[i] = b;
}
static void lt_del(LTab *t, uint64_t k) {   // backward-shift deletion, as ht_del
    if (!t->cap) return;
    size_t i = lt_slot(t, k);
    while (t->keys[i] != k) {
        if (!t->keys[i]) return;
        i = (i + 1) & (t->cap - 1);
    }
    t->count--;
    for (size_t j = i;;) {
        t->keys[i] = 0;
        for (;;) {
            j = (j + 1) & (t->cap - 1);
            if (!t->keys[j]) return;
            size_t h = lt_slot(t, t->keys[j]);
            if (i <= j ? (i < h && h <= j) : (i < h || h <= j)) continue;
            break;
        }
        t->keys[i] = t->keys[j], t->a[i] = t->a[j], t->b[i] = t->b[j];
        i = j;
    }
}
// 4 KB pages of command memory -> handles of the lists touching them (entries of dead lists are dropped lazily).
typedef struct { uint64_t page; uint32_t n, cap; uint64_t *h; } LPage;
static struct { LPage *e; size_t cap, count; } g_lpages;
static LPage *lpage_get(uint64_t page, int create) {
    if (create && (g_lpages.count + 1) * 2 > g_lpages.cap) {
        size_t nc = g_lpages.cap ? g_lpages.cap * 2 : 4096;
        LPage *ne = calloc(nc, sizeof *ne);
        for (size_t i = 0; i < g_lpages.cap; i++) {
            if (!g_lpages.e[i].page) continue;
            size_t j = (size_t)((g_lpages.e[i].page * 0x9E3779B97F4A7C15ull) >> 20) & (nc - 1);
            while (ne[j].page) j = (j + 1) & (nc - 1);
            ne[j] = g_lpages.e[i];
        }
        free(g_lpages.e);
        g_lpages.e = ne, g_lpages.cap = nc;
    }
    if (!g_lpages.cap) return NULL;
    for (size_t i = (size_t)((page * 0x9E3779B97F4A7C15ull) >> 20) & (g_lpages.cap - 1);; i = (i + 1) & (g_lpages.cap - 1)) {
        if (g_lpages.e[i].page == page) return &g_lpages.e[i];
        if (!g_lpages.e[i].page) {
            if (!create) return NULL;
            g_lpages.count++;
            g_lpages.e[i].page = page;
            return &g_lpages.e[i];
        }
    }
}
static int memused_on(void);
// 0: memory scan only; 1: shadow (scan + range checks); 3 (default with memory-used reporting: the hybrid, below): the
// scan plus early retirement of lists whose command memory was reused; 2 (BOTW's default, wrong for Tomodachi: see
// listgc_kill_end): lists live by their command memory alone, no scan. In mode 2 a handle is its command memory address (with a tag), as on the Switch: the
// game re-records the same commands into the same place and keeps calling the handle it got the first time, which
// must run what is there now. A new list frees every older one its range overlaps (refs: lookups in progress).
static int listgc_mode(void) {
    static int m = -1;
    if (m < 0) m = getenv("NXRT_LISTGC") ? atoi(getenv("NXRT_LISTGC")) : memused_on() ? 3 : 0;
    return m;
}
enum { LIST_TAG = 0x7E56ull << 48 };
static const uint64_t LIST_EMPTY = LIST_TAG | 1;   // every empty list (the game reports 0 bytes used and records the next one there)
static Blob g_empty_blob;
static const Blob *g_empty_blob_p(void) { return &g_empty_blob; }
static void blob_free_dead(Blob *b) {   // g_handle_lock held: b left the table
    if (b == &g_empty_blob) return;
    if (b->refs) b->dead = 1;
    else free(b);
}
static void blob_acquire(const Blob *b) { if (b) ((Blob *)b)->refs++; }   // g_handle_lock held
static void blob_release(const Blob *b) {   // takes g_handle_lock
    if (!b || (listgc_mode() != 2 && listgc_mode() != 3)) return;
    pthread_mutex_lock(&g_handle_lock);
    Blob *m = (Blob *)b;
    if (!--m->refs && m->dead) free(m);
    pthread_mutex_unlock(&g_handle_lock);
}
static int listgc_log(void) {   // NXRT_LISTGC_LOG=<frame>: log command memory adds and list ranges in that frame
    static int f = -2;
    if (f == -2) f = getenv("NXRT_LISTGC_LOG") ? atoi(getenv("NXRT_LISTGC_LOG")) : -1;
    extern volatile int g_gfx_frame;
    return f >= 0 && g_gfx_frame == f;
}
static LTab g_lranges;   // live lists: handle -> [lo, hi) of command memory
static LTab g_ldead;     // shadow: lists whose memory was reused -> frame, guest site of that AddCommandMemory
static uint64_t g_lnomem, g_lkilled, g_lviolations;   // lists ended without command memory; lists killed; dead lists called
// Shadow mode, what mode 2 would have done with each dead list called: its start address now begins another live list
// (re-recorded in place: mode 2's handle is the address, so the call runs that list; identical bytes or not), or no
// live list starts there (mode 2 loses the call).
static LTab g_lstart, g_laddr;   // handle -> start address (kept after death); start address -> live handle there
static uint64_t g_lv_same, g_lv_ident, g_lv_lost;
static void listgc_register(uint64_t h, uint64_t lo, uint64_t hi) {   // g_handle_lock held
    lt_put(&g_lranges, h, lo, hi);
    if (listgc_mode() == 1) lt_put(&g_lstart, h, lo, 0), lt_put(&g_laddr, lo, h, 0);
    for (uint64_t p = lo >> 12; p <= (hi - 1) >> 12; p++) {
        LPage *e = lpage_get(p + 1, 1);   // +1: page 0 marks an empty entry
        if (e->n == e->cap) e->cap = e->cap * 2 + 4, e->h = realloc(e->h, e->cap * 8);
        e->h[e->n++] = h;
    }
}
// NXRT_LISTGC_SITE=<main offset of EndRecording's caller>: shadow mode logs how lists ended there are placed and what
// overwrites them (diagnostics for lists the game calls after their memory was reused).
static long listgc_site(void) {
    static long s = -2;
    if (s == -2) s = getenv("NXRT_LISTGC_SITE") ? strtol(getenv("NXRT_LISTGC_SITE"), NULL, 16) : -1;
    return s;
}
static __thread long g_end_lr;
// Tomodachi (unlike BOTW's agl) does not place the next list at start + the size we report: its cursor moves by its own
// count (main+0x1a59e8 lists: 0x124 after a list we reported as 0x188, 0x198 after 0x13c; the memory comes from a heap
// shared with other data). So a list owns its memory only up to where the game starts the next list on that command
// buffer (listgc_trim_last). Even so, small long-lived lists (main+0x1a6314's, a 36-byte boot list) are still called
// after a later list overlapped them: BOTW's no-scan mode 2 would lose ~1,000 calls a frame here, hence the hybrid.
// A new list kills the older lists its reported extent overlaps; NXRT_LISTGC_KILL=start: only those its start falls in
// (fewer kills, more lists left for the scan: 104k live instead of 36k).
static uint64_t listgc_kill_end(uint64_t lo, uint64_t size) {
    static int start = -1;
    if (start < 0) start = getenv("NXRT_LISTGC_KILL") && !strcmp(getenv("NXRT_LISTGC_KILL"), "start");
    return start ? lo + 4 : lo + size;
}
struct Rec;
static void listgc_trim_last(struct Rec *r, uint64_t lo);
static void listgc_retire(uint64_t h);
static void listgc_kill_range(uint64_t lo, uint64_t hi, uint32_t site) {   // g_handle_lock held
    extern volatile int g_gfx_frame;
    for (uint64_t p = lo >> 12; p <= (hi - 1) >> 12; p++) {
        LPage *e = lpage_get(p + 1, 0);
        if (!e) continue;
        uint32_t k = 0;
        for (uint32_t i = 0; i < e->n; i++) {
            uint64_t h = e->h[i], a, b;
            if (!lt_get(&g_lranges, h, &a, &b)) continue;   // already dead: drop the entry
            if (a < hi && lo < b) {
                if (listgc_mode() == 2) {
                    Blob *old = ht_get(&g_hcur, h);
                    if (old) ht_del(&g_hcur, h), blob_free_dead(old);
                }
                if (listgc_log()) nx_log("listgc:   kills %#llx [%#llx,%#llx)", (unsigned long long)h, (unsigned long long)a, (unsigned long long)b);
                lt_del(&g_lranges, h);
                g_lkilled++;
                if (listgc_mode() == 1) lt_put(&g_ldead, h, (uint64_t)g_gfx_frame, site);
                if (listgc_mode() == 3) listgc_retire(h);
                if (listgc_mode() == 1 && listgc_site() >= 0) {
                    const Blob *v = ht_get(&g_hcur, h);
                    if (!v) v = ht_get(&g_hold, h);
                    if (!v) v = ht_get(&g_hscan, h);
                    static int nk;
                    if (v && v->end_lr == listgc_site() && nk++ < 60)
                        nx_log("listgc site: frame %d %#llx [%#llx,%#llx) killed by [%#llx,%#llx) ended at main+%#lx (add from main+%#x)", g_gfx_frame,
                               (unsigned long long)h, (unsigned long long)a, (unsigned long long)b, (unsigned long long)lo, (unsigned long long)hi,
                               g_end_lr, site);
                }
                continue;
            }
            e->h[k++] = h;
        }
        e->n = k;
    }
}
static void listgc_trim_last(struct Rec *r, uint64_t lo) {   // g_handle_lock held: memory added to r's command buffer at lo
    uint64_t a, b;
    if (r->cm_last_h && lo > r->cm_last_lo && lt_get(&g_lranges, r->cm_last_h, &a, &b) && a == r->cm_last_lo && lo < b)
        lt_put(&g_lranges, r->cm_last_h, a, lo);
}
// ---- Hybrid (NXRT_LISTGC=3) ----
// The memory scan keeps every list the game may still call, but on the island it ran back to back (a 64 MB generation
// filled every ~15 frames with per-frame scene lists, each scan reading ~2 GB): a whole core, on the phone too. In
// the hybrid a list whose command memory a later list reused (the rule above) leaves the scanned tables at once and
// waits GRACE frames in g_retired; its bytes no longer fill the generation, so scans become rare. If the game calls a
// retired list anyway, it is brought back and the guest site that recorded it (Blob end_lr) is exempted from early
// retirement from then on (main+0x1a6314's long-lived lists are the known case: our sizes are not the game's). A call
// after GRACE frames would find nothing: "unknown command handles" in the stats (0 under the scan alone).
enum { RETIRE_RING = 1 << 18 };
static LTab g_retired;                                     // handle -> frame retired, Blob pointer
static struct { uint64_t h, frame; } *g_retire_ring;       // retirement order, for expiry
static size_t g_retire_head, g_retire_tail;
static uint64_t g_retired_n, g_retired_bytes_live, g_retire_freed, g_unretired, g_retire_skipped;
static uint32_t g_exempt[256];                             // end_lr sites never retired early
static int g_nexempt;
static LTab g_tombs;                                       // freed retired lists: handle -> end_lr, frame freed (loss diagnostics)
static uint64_t g_tomb_hits;
// Only lists of at least NXRT_LISTGC_MIN bytes (default 1024) retire early: the per-frame scene lists (1-64 KB) are
// what fills the generations; small lists can be long-lived (a 36-byte boot list is called every frame for good).
static size_t retire_min(void) {
    static long m = -1;
    if (m < 0) m = getenv("NXRT_LISTGC_MIN") ? atol(getenv("NXRT_LISTGC_MIN")) : 1024;
    return (size_t)m;
}
static int retire_grace(void) {
    static int g = -1;
    if (g < 0) g = getenv("NXRT_LISTGC_GRACE") ? atoi(getenv("NXRT_LISTGC_GRACE")) : 16;
    return g;
}
static int site_exempt(uint32_t lr) {
    for (int i = 0; i < g_nexempt; i++)
        if (g_exempt[i] == lr) return 1;
    return 0;
}
static void listgc_retire(uint64_t h) {   // g_handle_lock held: h's command memory was reused
    HTab *t = &g_hcur;
    Blob *b = ht_get(t, h);
    if (!b) b = ht_get(t = &g_hold, h);
    // Lists the collector is reading (scan, grave) stay with it; exempt sites stay under the scan.
    if (!b || b == &g_empty_blob || b->len < retire_min() || ht_get(&g_hscan, h) || ht_get(&g_hgrave, h) || site_exempt(b->end_lr)) {
        if (b) g_retire_skipped++;
        return;
    }
    if (!g_retire_ring) g_retire_ring = calloc(RETIRE_RING, sizeof *g_retire_ring);
    if (g_retire_tail - g_retire_head == RETIRE_RING) return;   // ring full: leave it to the scan
    extern volatile int g_gfx_frame;
    ht_del(t, h);
    if (t == &g_hcur) g_handles_bytes -= MIN(g_handles_bytes, b->len + 64);
    lt_put(&g_retired, h, (uint64_t)g_gfx_frame, (uint64_t)(uintptr_t)b);
    g_retire_ring[g_retire_tail++ % RETIRE_RING] = (typeof(*g_retire_ring)){h, (uint64_t)g_gfx_frame};
    g_retired_n++, g_retired_bytes_live += b->len;
}
static Blob *listgc_unretire(uint64_t h) {   // g_handle_lock held: the game called a retired list
    uint64_t frame, p;
    if (listgc_mode() != 3 || !lt_get(&g_retired, h, &frame, &p)) return NULL;
    lt_del(&g_retired, h);
    Blob *b = (Blob *)(uintptr_t)p;
    g_retired_bytes_live -= MIN(g_retired_bytes_live, b->len);
    g_unretired++;
    if (!site_exempt(b->end_lr) && g_nexempt < 256) {
        g_exempt[g_nexempt++] = b->end_lr;
        extern volatile int g_gfx_frame;
        nx_log("gfx: listgc: list %#llx (ended at main+%#x, %zu bytes) called at frame %d, %d frames after its memory was reused: "
               "lists from main+%#x stay under the memory scan", (unsigned long long)h, b->end_lr, b->len, g_gfx_frame,
               g_gfx_frame - (int)frame, b->end_lr);
    }
    return b;
}
static void listgc_expire(void) {   // once per submit: free retired lists older than the grace period
    if (listgc_mode() != 3 || !g_retire_ring) return;
    extern volatile int g_gfx_frame;
    pthread_mutex_lock(&g_handle_lock);
    while (g_retire_head != g_retire_tail) {
        typeof(*g_retire_ring) e = g_retire_ring[g_retire_head % RETIRE_RING];
        if ((int64_t)e.frame + retire_grace() > g_gfx_frame) break;
        g_retire_head++;
        uint64_t frame, p;
        if (!lt_get(&g_retired, e.h, &frame, &p) || frame != e.frame) continue;   // brought back meanwhile
        lt_del(&g_retired, e.h);
        Blob *b = (Blob *)(uintptr_t)p;
        g_retired_bytes_live -= MIN(g_retired_bytes_live, b->len);
        g_retire_freed++;
        if (g_tombs.count > (1 << 20)) free(g_tombs.keys), free(g_tombs.a), free(g_tombs.b), memset(&g_tombs, 0, sizeof g_tombs);
        lt_put(&g_tombs, e.h, b->end_lr, (uint64_t)g_gfx_frame);
        blob_free_dead(b);
    }
    pthread_mutex_unlock(&g_handle_lock);
}
static uint64_t g_lpool_freed;   // lists freed with their memory pool
void gfx_lists_forget(uint64_t gpu, uint64_t size) {   // nvnMemoryPoolFinalize
    if (listgc_mode() != 2) return;
    pthread_mutex_lock(&g_handle_lock);
    uint64_t k0 = g_lkilled;
    listgc_kill_range(gpu, gpu + size, 0);
    g_lpool_freed += g_lkilled - k0;
    pthread_mutex_unlock(&g_handle_lock);
}
static void listgc_check_call(uint64_t h, const Blob *d) {   // g_handle_lock held: a list is about to be used
    uint64_t frame, site;
    if (!listgc_mode() || !lt_get(&g_ldead, h, &frame, &site)) return;
    extern volatile int g_gfx_frame;
    static LTab seen;   // log each list once
    g_lviolations++;
    uint64_t lo = 0, cur = 0;
    lt_get(&g_lstart, h, &lo, NULL);
    if (lt_get(&g_laddr, lo, &cur, NULL) && lt_get(&g_lranges, cur, NULL, NULL)) {
        const Blob *n = ht_get(&g_hcur, cur);
        if (!n) n = ht_get(&g_hold, cur);
        if (!n) n = ht_get(&g_hscan, cur);
        g_lv_same++;
        if (n && d && n->len == d->len && !memcmp(n->bytes, d->bytes, d->len)) {
            g_lv_ident++;
            return;
        }
        static int ndiff;
        if (ndiff++ < 20)
            nx_log("gfx: listgc: list %#llx (ended at main+%#x, %zu bytes) called at frame %d: re-recorded in place as %#llx with "
                   "different bytes (%zu, ended at main+%#x)", (unsigned long long)h, d ? d->end_lr : 0, d ? d->len : 0, g_gfx_frame,
                   (unsigned long long)cur, n ? n->len : 0, n ? n->end_lr : 0);
        return;
    }
    g_lv_lost++;
    if (lt_get(&seen, h, NULL, NULL)) return;
    lt_put(&seen, h, 0, 0);
    if (seen.count <= 60)
        nx_log("gfx: listgc: list %#llx (ended at main+%#x, %zu bytes) used at frame %d after its memory was reused at frame %llu "
               "(AddCommandMemory from main+%#llx)", (unsigned long long)h, d ? d->end_lr : 0, d ? d->len : 0, g_gfx_frame,
               (unsigned long long)frame, (unsigned long long)site);
}

static uint64_t g_unknown_handles;   // CallCommands/SubmitCommands of handles we no longer (or never) had
static const Blob *ops_for_handle(uint64_t h) {   // g_handle_lock held
    const Blob *d = handle_lookup(h);
    if (d) listgc_check_call(h, d);
    static int missing;
    uint64_t lr, freed;
    if (!d && listgc_mode() == 3 && lt_get(&g_tombs, h, &lr, &freed)) {   // a list retired early, then freed: lost
        g_tomb_hits++;
        if (!site_exempt((uint32_t)lr) && g_nexempt < 256) {
            g_exempt[g_nexempt++] = (uint32_t)lr;
            extern volatile int g_gfx_frame;
            nx_log("gfx: listgc: LOST list %#llx (ended at main+%#llx), called at frame %d after it was freed at frame %llu: lists from "
                   "there stay under the memory scan now", (unsigned long long)h, (unsigned long long)lr, g_gfx_frame, (unsigned long long)freed);
        }
    }
    if (!d) g_unknown_handles++;
    if (!d && missing++ < 8) nx_log("gfx: unknown command handle %#llx", (unsigned long long)h);
    return d;
}

// NVNcommandBuffer private fields: +0x00 = raw command write pointer, +0x08 = its end. The engine
// inlines some binds (main+0x1c4458: uniform buffers) as raw Maxwell methods written at [cb+0]
// when [cb+0] + size <= [cb+8], and otherwise calls the NVN function. We keep both 0 so the
// engine always takes the API path, which we record in order. Worker command buffers live on
// thread stacks, so without this the fields held stack garbage (writes to random addresses).
static uint64_t g_cb_dirty;
static void cb_reset_raw(void *cb) {
    uint64_t *f = cb;
    if (f[0] || f[1]) g_cb_dirty++;
    f[0] = f[1] = 0;
}
// NXRT_NORAW=1: clear the engine's "inline raw methods" flag ([[main+0x32d8a70]], tested by the
// fast paths in main+0x1c4458) so every bind goes through the NVN API. Experimental.
static void noraw_flag(void) {
    static int done;
    if (done || !ENV("NXRT_NORAW")) return;
    Module *m = nx_module("main");
    uint32_t *flag = m ? *(uint32_t **)(m->base + 0x32d8a70) : NULL;
    if (!flag) return;   // relocation not applied yet
    done = 1;
    const char *names[] = {"rtld", "main", "subsdk9", "sdk"};
    long where = -1;
    const char *mod = "?";
    for (int i = 0; i < 4; i++) {
        Module *x = nx_module(names[i]);
        if (x && (uint8_t *)flag >= x->base && (uint8_t *)flag < x->base + x->size) where = (uint8_t *)flag - x->base, mod = names[i];
    }
    nx_log("gfx: raw-method flag at %s+%#lx = %u, forcing 0", mod, where, *flag);
    *flag = 0;
}
static uint64_t cb_initialize(void *cb, void *device) {
    noraw_flag();
    cb_reset_raw(cb);
    return 1;
}
int bp_enabled(void);
static void cb_begin(void *cb) {
    noraw_flag();
    if (bp_enabled()) nx_log("bp: %p BeginRecording", cb);
    cb_reset_raw(cb);
    Rec *r = rec_get(cb);
    r->len = 0;
    r->cm_beg = r->cm_cur, r->cm_new = 0;
    tl_recstat.begins++, tl_recstat.begin_cb = cb, tl_recstat.begin_rec = rec_get(cb), tl_recstat.after_begin = 0;
}
// The engine asks for memory used right after EndRecording (main+0x181d00) and submits only lists
// that report non-zero. With non-zero values it also takes a boot path that exhausts its
// "MiiBodyBaseModel" heap (it relies on private NVN state we don't model yet), so by default we
// report 0 and execute the lists ourselves (autosubmit below). NXRT_MEMUSED=1: report sizes.
static int memused_on(void) {
    static int on = -1;
    if (on < 0) on = getenv("NXRT_MEMUSED") != NULL;
    return on;
}
// NXRT_MEMLOG=1: log command/control memory traffic with the guest caller.
static int memlog_on(void) {
    static int on = -1;
    if (on < 0) on = getenv("NXRT_MEMLOG") != NULL;
    return on;
}
static long main_off(void *p) {
    static Module *m;
    if (!m) m = nx_module("main");
    return m && (uint8_t *)p >= m->base && (uint8_t *)p < m->base + m->size ? (long)((uint8_t *)p - m->base) : -1;
}
// NXRT_MEMUSED_SITES=<main offset>[,...]: report memory used only to these guest call sites (return
// addresses); everyone else reads 0. For finding which engine subsystem misbehaves with real values.
static long g_memused_sites[64];
static int g_memused_nsites;   // -2: no filter (every site); >= 0: the list
static void memused_sites_parse(void) {
    const char *e = getenv("NXRT_MEMUSED_SITES");
    if (!e) { g_memused_nsites = -2; return; }
    char buf[1024];
    snprintf(buf, sizeof buf, "%s", e);
    int n = 0;
    for (char *t = strtok(buf, ","); t && n < 64; t = strtok(NULL, ",")) g_memused_sites[n++] = strtol(t, NULL, 16);
    g_memused_nsites = n;
}
static int memused_site_ok(void *lr) {
    // Parsed exactly once: worker threads call this concurrently. The old lazy init re-ran on every
    // call and briefly left the count at 0, so a concurrent caller matched no site and reported 0 bytes
    // used; the engine then dropped that scene-list chunk for the frame (the flicker / popping).
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, memused_sites_parse);
    long *sites = g_memused_sites;
    int nsites = g_memused_nsites;
    if (nsites == -2) return 1;
    static Module *m;
    if (!m) m = nx_module("main");
    long off = (uint8_t *)lr - m->base;
    for (int i = 0; i < nsites; i++)
        if (sites[i] == off) return 1;
    return 0;
}
// The NVN thunk leaves a frame record whose return address is the guest caller.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wframe-address"
// Real NVN reports the pushbuffer bytes recorded. The engine measures small lists, then allocates
// exactly that much from model heaps sized for real hardware (128 KB "MiiBodyBaseModel"): a fixed
// 0x100 + 0x20 exhausted it within 2 s. Our op stream is about the size of the Maxwell methods.
// NXRT_COLLECTLOG=1: at the scene-list measure (guest LR main+0x179ef8) log the list object (guest
// x20, saved by the thunk just below its frame record) and its pass collector ([guest sp + 0x68]).
static void collect_log(const uint64_t *fp, int64_t used) {
    static int on = -1, n;
    if (on < 0) on = getenv("NXRT_COLLECTLOG") != NULL;
    if (!on || n >= 20000) return;
    n++;
    uint64_t list = fp[-1], sp = (uint64_t)fp + 16;
    uint64_t coll = *(const uint64_t *)(sp + 0x68);
    uint64_t handle = *(const uint64_t *)(list + 0x50);
    const int32_t *cnt = (const int32_t *)(coll + 0xc8);
    nx_log("collect: list %#llx handle %#llx used %#llx -> collector %#llx (count %d cap %d)", (unsigned long long)list,
           (unsigned long long)handle, (unsigned long long)used, (unsigned long long)coll, cnt[0], cnt[1]);
}
uint64_t nx_objprobe[8], nx_objret[4];   // NXRT_OBJPROBE (src/probe_hooks.S)
// NXRT_CHUNKPROBE=<from>-<to>: one line per scene-list chunk measured in those frames:
// "ck: <frame> pass <p> mask <m> range <start>+<count> objects <n> masked <k> used <bytes>".
uint64_t nx_cpret[5];
static __thread struct { uint64_t pass; uint32_t mask, start, count, visits, masked, lodskip, notready; } tl_chunk;
void nx_cprobe(uint64_t *r, int id) {
    if (id == 1) {
        tl_chunk.pass = r[0];
        tl_chunk.mask = *(const uint32_t *)r[3];
        tl_chunk.start = *(const uint32_t *)r[5];
        tl_chunk.count = *(const uint32_t *)(r[5] + 4);
        tl_chunk.visits = tl_chunk.masked = tl_chunk.lodskip = tl_chunk.notready = 0;
        memset(&tl_recstat, 0, sizeof tl_recstat);
    } else if (id == 2) {
        tl_chunk.visits++;
        if (!((uint32_t)r[10] & (uint32_t)r[8])) tl_chunk.masked++;
    } else if (id == 3) {   // regs: [0..15] x0-x15, [16] x18, [17] x30, [18] x19, [19] x20, ...
        if (((*(const uint16_t *)(r[10] + 0x1c) >> 4) & 7) <= (uint32_t)r[19]) tl_chunk.lodskip++;
    } else if (id == 4) {
        if (!(r[0] & 1)) tl_chunk.notready++;
    }
}
static void chunk_log(int64_t used, const void *cb, size_t len_read) {
    static int lo = -2, hi;
    if (lo == -2) {
        lo = -1;
        if (getenv("NXRT_CHUNKPROBE")) sscanf(getenv("NXRT_CHUNKPROBE"), "%d-%d", &lo, &hi);
    }
    extern volatile int g_gfx_frame;
    if (lo < 0 || g_gfx_frame < lo || g_gfx_frame > hi) return;
    GuestThread *t = nx_current();
    const uint64_t *f = cb;
    nx_log("ck: %d t%u pass %llx mask %x range %u+%d objects %u masked %u lodskip %u notready %u used %lld emits %u begins %u calls %u cb %p begin_cb %p emit_cb %p raw %llx/%llx | after_begin %u ends %u len_at_end %zu rec begin %p emit %p now %p len %zu read %zu",
           g_gfx_frame, t ? t->id : 0, (unsigned long long)tl_chunk.pass, tl_chunk.mask, tl_chunk.start, (int)tl_chunk.count, tl_chunk.visits,
           tl_chunk.masked, tl_chunk.lodskip, tl_chunk.notready, (long long)used, tl_recstat.emits, tl_recstat.begins, tl_recstat.calls, cb, tl_recstat.begin_cb, tl_recstat.emit_cb,
           (unsigned long long)f[0], (unsigned long long)f[1], tl_recstat.after_begin, tl_recstat.ends, tl_recstat.len_at_end,
           tl_recstat.begin_rec, tl_recstat.emit_rec, (void *)rec_get(cb), rec_get(cb)->len, len_read);
}
uint64_t nx_objthr[64][8];               // per host thread: visits, mask, lod, not-ready skips, owner
static int64_t cb_command_used(void *cb) {
    size_t len = rec_get(cb)->len;
    int64_t v = (memused_on() || getenv("NXRT_MEMUSED_SITES")) && memused_site_ok(__builtin_return_address(1)) && len ? (int64_t)((len + 3) & ~3ul) : 0;
    if (memlog_on()) nx_log("memlog: %p GetCommandMemoryUsed -> %#llx (ops %zu bytes) from main+%#lx", cb, (long long)v, rec_get(cb)->len, main_off(__builtin_return_address(1)));
    if (main_off(__builtin_return_address(1)) == 0x179ef8) collect_log(__builtin_frame_address(1), v);
    if (main_off(__builtin_return_address(1)) == 0x179ef8) {   // scene-list chunk measure (NXRT_FRAMEDRAWS)
        extern uint64_t g_scene_lists[2];
        __atomic_fetch_add(&g_scene_lists[v == 0], 1, __ATOMIC_RELAXED);
        chunk_log(v, cb, len);
        if (v == 0 && getenv("NXRT_OBJPROBE")) {
            uint64_t tp;
            __asm__ volatile("mrs %0, tpidrro_el0" : "=r"(tp));
            const uint64_t *row = nx_objthr[(tp >> 23) & 63];
            extern volatile int g_gfx_frame;
            nx_log("objprobe: frame %d empty chunk: %llu objects, %llu mask, %llu lod, %llu not-ready skips%s; last masked object %#llx "
                   "(mask now %#x, pass mask %#x)", g_gfx_frame, row[0], row[1], row[2], row[3], row[4] == tp ? "" : " (row owned by another thread)",
                   (unsigned long long)nx_objprobe[5], nx_objprobe[5] ? *(const uint32_t *)(nx_objprobe[5] + 8) : 0, (uint32_t)nx_objprobe[6]);
        }
    }
    return v;
}
// Control memory: always 0. A non-zero value made the engine's measure pass (main+0x402a8c)
// exhaust the model heap; the "has content" test only needs command memory used.
static int64_t cb_control_used(void *cb) {
    int64_t v = 0;
    if (memlog_on()) nx_log("memlog: %p GetControlMemoryUsed -> %#llx from main+%#lx", cb, (long long)v, main_off(__builtin_return_address(1)));
    return v;
}
#pragma clang diagnostic pop
// NXRT_TRACE_LR=<main offset>: when EndRecording is called from that guest return address, log the
// guest frame chain once (the thunk's frame record links to the guest frames).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wframe-address"
// NXRT_TRACE_BIG=<bytes>: the same for the first 3 lists that end with at least that many op bytes.
static void trace_guest_caller(size_t len) {
    static long want = -2, big = -2;
    static int done, nbig;
    if (want == -2) want = getenv("NXRT_TRACE_LR") ? strtol(getenv("NXRT_TRACE_LR"), NULL, 16) : -1;
    if (big == -2) big = getenv("NXRT_TRACE_BIG") ? atol(getenv("NXRT_TRACE_BIG")) : -1;
    long lr = main_off(__builtin_return_address(1));
    if (want >= 0 && !done && lr == want) done = 1;
    else if (big >= 0 && (long)len >= big && nbig < 3) nbig++;
    else return;
    const uint64_t *fp = __builtin_frame_address(1);   // thunk frame: {guest x29, guest x30}
    nx_log("trace: EndRecording (%zu op bytes) from main+%#lx", len, lr);
    for (int i = 0; fp && i < 16; i++) {
        uint64_t lr = fp[1];
        nx_log("trace:   #%d main+%#lx", i, main_off((void *)lr));
        fp = (const uint64_t *)fp[0];
    }
}
#pragma clang diagnostic pop
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wframe-address"
static uint64_t cb_end(void *cb) {
    g_end_lr = main_off(__builtin_return_address(1));
#pragma clang diagnostic pop
    trace_guest_caller(rec_get(cb)->len);
    @autoreleasepool {
        Rec *r = rec_get(cb);
        tl_recstat.ends++, tl_recstat.len_at_end = r->len;
        Blob *d = malloc(sizeof(Blob) + r->len);                   // len stays until the next Begin:
        if (!d) {   // out of memory (iPhone): lose this list (an unknown handle draws nothing) rather than crash
            static int nfail;
            if (nfail++ < 8) nx_log("gfx: EndRecording: malloc of %zu bytes failed, list dropped", sizeof(Blob) + r->len);
            pthread_mutex_lock(&g_handle_lock);
            uint64_t h = ++g_next_handle;
            pthread_mutex_unlock(&g_handle_lock);
            return h;
        }
        d->len = r->len;
        d->end_lr = (uint32_t)g_end_lr;
        d->refs = d->dead = 0;
        memcpy(d->bytes, r->p, r->len);
                                                                   // the engine asks for memory used after End
        __atomic_fetch_add(&g_ended, 1, __ATOMIC_RELAXED);
        pthread_mutex_lock(&g_handle_lock);
        if (listgc_mode() == 2 && r->cm_hi) {
            uint64_t lo = r->cm_new ? r->cm_lo : r->cm_beg, size = (r->len + 3) & ~3ul, h = LIST_EMPTY;
            if (!size) free(d);
            else {
                h = LIST_TAG | lo;
                listgc_kill_range(lo, listgc_kill_end(lo, size), r->cm_site);   // also the previous list at this address (same handle)
                ht_put(&g_hcur, h, d);
                listgc_register(h, lo, lo + size);
                r->cm_last_h = h, r->cm_last_lo = lo;
            }
            if (listgc_log())
                nx_log("listgc: cb %p end %#llx [%#llx,+%#llx) %s from main+%#lx", cb, (unsigned long long)h, (unsigned long long)lo,
                       (unsigned long long)size, r->cm_new ? "new chunk" : "cursor", g_end_lr);
            r->cm_cur = lo + size;
            pthread_mutex_unlock(&g_handle_lock);
            return h;
        }
        if (listgc_mode() == 2) g_lnomem++;   // no command memory: a counter handle that lives forever
        uint64_t h = ++g_next_handle;
        if (bp_enabled())
            nx_log("bp: %p EndRecording -> %#llx (%lu bytes) from main+%#lx", cb, (unsigned long long)h, (unsigned long)d->len, g_end_lr);
        ht_put(&g_hcur, h, d);
        if (listgc_mode() == 1 || listgc_mode() == 3) {   // the list occupies its reported size from where it started in the command memory
            uint64_t lo = r->cm_new ? r->cm_lo : r->cm_beg, size = (r->len + 3) & ~3ul;
            if (!r->cm_hi) g_lnomem++;
            else {
                listgc_kill_range(lo, listgc_kill_end(lo, size ? size : 4), r->cm_site);   // the commands just written overwrite older lists there
                listgc_register(h, lo, lo + (size ? size : 4));
                r->cm_last_h = h, r->cm_last_lo = lo;
            }
            static int nr;
            if (listgc_site() >= 0 && g_end_lr == listgc_site() && nr++ < 60) {
                extern volatile int g_gfx_frame;
                nx_log("listgc site: frame %d cb %p end %#llx [%#llx,+%#llx) %s, chunk [%#llx,%#llx) begin cursor %#llx", g_gfx_frame, cb,
                       (unsigned long long)h, (unsigned long long)lo, (unsigned long long)size, r->cm_new ? "new chunk" : "cursor",
                       (unsigned long long)r->cm_lo, (unsigned long long)r->cm_hi, (unsigned long long)r->cm_beg);
            }
            if (listgc_log())
                nx_log("listgc: cb %p end %#llx [%#llx,+%#llx) %s from main+%#lx", cb, (unsigned long long)h, (unsigned long long)lo,
                       (unsigned long long)size, r->cm_new ? "new chunk" : "cursor", g_end_lr);
            r->cm_cur = lo + size;
        }
        if (!memused_on() && d->len && draws_enabled()) {
            if (!g_pending) g_pending = [NSMutableArray new];
            [g_pending addObject:@(h)];
        }
        extern volatile int g_gfx_frame;
        if (dbg() && (g_gfx_frame == 900 || g_gfx_frame == 901))
            nx_log("gfx: dbg end cb %p -> %#llx (%lu bytes)", cb, (unsigned long long)h, (unsigned long)d->len);
        // Generation swap by bytes, not count: with real memory-used reporting the engine bakes
        // lists while loading and first calls some of them thousands of recordings later.
        g_handles_bytes += d->len + 64;
        if (listgc_mode() != 2 && g_handles_bytes > HANDLE_GEN_BYTES && g_hcur.count > HANDLE_KEEP && handle_swap_generations()) {
            g_handles_bytes = 0;
        }
        pthread_mutex_unlock(&g_handle_lock);
        return h;
    }
}
static __thread long g_call_lr;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wframe-address"
static void cb_call_entry(void *cb, int32_t n, const uint64_t *handles);
static void cb_call(void *cb, int32_t n, const uint64_t *handles) {
    g_call_lr = main_off(__builtin_return_address(1));
    static int clog = -1;
    if (clog < 0) clog = getenv("NXRT_COLLECTLOG") != NULL;
    if (clog && g_call_lr == 0x1856e8) {   // executor main+0x1850f0: log who asked for this pass
        const uint64_t *fp = __builtin_frame_address(1), *gfp = (const uint64_t *)fp[0];
        nx_log("collect: executor called from main+%#lx", main_off((void *)gfp[1]));
        static int chains;
        if (chains++ < 2)
            for (int i = 0; gfp && i < 20; i++, gfp = (const uint64_t *)gfp[0]) nx_log("collect:   #%d main+%#lx", i, main_off((void *)gfp[1]));
    }
    cb_call_entry(cb, n, handles);
}
#pragma clang diagnostic pop
static int vcheck_marks(void) {
    static int on = -1;
    if (on < 0) on = getenv("NXRT_VCHECK") && atoi(getenv("NXRT_VCHECK")) >= 2;
    return on;
}
// NXRT_LOWDIFF: draw ops inlined per CallCommands site (guest LR) per frame, double-buffered.
typedef struct { uint32_t lr; uint32_t n[2], calls[2]; } SiteTally;
static SiteTally g_sites[1024];
static volatile int g_site_cur;
static int lowdiff_on(void);
static void site_tally(uint32_t lr, const Blob *d) {
    uint32_t nd = 0;
    for (size_t o = 0; o + sizeof(OpHdr) <= d->len;) {
        OpHdr h;
        memcpy(&h, d->bytes + o, sizeof h);
        if (h.type == OP_DRAW_ELEM || h.type == OP_DRAW_ARRAYS) nd++;
        o += sizeof h + h.size;
    }
    int c = g_site_cur;
    for (unsigned i = (lr * 2654435761u) >> 22, k = 0; k < 1024; i = (i + 1) & 1023, k++) {
        SiteTally *e = &g_sites[i];
        if (!e->lr) __atomic_compare_exchange_n(&e->lr, &(uint32_t){0}, lr, 0, __ATOMIC_RELAXED, __ATOMIC_RELAXED);
        if (e->lr == lr) { __atomic_fetch_add(&e->n[c], nd, __ATOMIC_RELAXED); __atomic_fetch_add(&e->calls[c], 1, __ATOMIC_RELAXED); return; }
    }
}
static OpMark g_marks[8];   // the last inlined lists seen by the executor (NXRT_VCHECK=2)
static unsigned g_nmarks;
static void cb_call_entry(void *cb, int32_t n, const uint64_t *handles) {
    @autoreleasepool {
        static int clog = -1, ncl;
        if (clog < 0) clog = getenv("NXRT_COLLECTLOG") != NULL;
        if (clog && g_call_lr == 0x1856e8)
            for (int32_t i = 0; i < n && handles && ncl < 20000; i++, ncl++)
                nx_log("collect: called %#llx into %p", (unsigned long long)handles[i], cb);
        if (bp_enabled())
            for (int32_t i = 0; i < n && handles; i++)
                nx_log("bp: %p CallCommands %#llx from main+%#lx", cb, (unsigned long long)handles[i], g_call_lr);
        for (int32_t i = 0; i < n && handles; i++) {
            pthread_mutex_lock(&g_handle_lock);
            const Blob *d = ops_for_handle(handles[i]);
            blob_acquire(d);
            pthread_mutex_unlock(&g_handle_lock);
            if (!d) {
                if (vcheck_marks()) {   // end_lr 0xFFFFFFFF: the called list was unknown at record time (skipped)
                    OpMark mk = {handles[i], 0xFFFFFFFFu, (uint32_t)g_call_lr};
                    emit(cb, OP_MARK, &mk, sizeof mk);
                }
                continue;
            }
            g_called++;
            tl_recstat.calls++;
            if (lowdiff_on()) site_tally((uint32_t)g_call_lr, d);
            if (dbg()) hist("called handle bytes (log2)", d->len ? 64 - __builtin_clzll(d->len) : 0);
            if (!memused_on()) {   // only autosubmit needs to know which lists the engine inlined
                pthread_mutex_lock(&g_handle_lock);
                if (!g_called_set) g_called_set = [NSMutableSet new];
                [g_called_set addObject:@(handles[i])];
                pthread_mutex_unlock(&g_handle_lock);
            }
            if (vcheck_marks()) {
                OpMark mk = {handles[i], d->end_lr, (uint32_t)g_call_lr};
                emit(cb, OP_MARK, &mk, sizeof mk);
            }
            Rec *r = rec_get(cb);
            if (r->len + d->len > r->cap) r->cap = (r->len + d->len) * 2, r->p = realloc(r->p, r->cap);
            memcpy(r->p + r->len, d->bytes, d->len);
            r->len += d->len;
            blob_release(d);
        }
    }
}

// Command/control memory the game gives each command buffer (to see what it writes there).
typedef struct { const void *cb; uint8_t *mem; uint64_t size; int control; } MemChunk;
static MemChunk g_chunks[4096];
static __thread uint32_t tl_add_site;   // guest caller of the AddCommandMemory being handled (listgc log)
static int g_nchunks;
static void cb_add_memory(const void *cb, void *pool, int64_t offset, int64_t size, int control) {
    uint8_t *mem = NULL;
    if (control) mem = pool;                                         // AddControlMemory(cb, ptr, size)
    else {                                                            // AddCommandMemory(cb, pool, offset, size)
        uint64_t avail;
        mem = pool ? (uint8_t *)nx_nvn_gpu_to_host(((const uint64_t *)pool)[3] + offset, &avail) : NULL;
    }
    pthread_mutex_lock(&g_rec_lock);
    g_chunks[g_nchunks++ % 4096] = (MemChunk){cb, mem, (uint64_t)size, control};
    pthread_mutex_unlock(&g_rec_lock);
    if (!control && pool && size > 0 && listgc_mode()) {
        uint64_t lo = ((const uint64_t *)pool)[3] + offset;
        Rec *r = rec_get(cb);
        r->cm_lo = r->cm_cur = lo, r->cm_hi = lo + size, r->cm_new = 1;
        pthread_mutex_lock(&g_handle_lock);
        if (listgc_log()) nx_log("listgc: cb %p add [%#llx,+%#llx) from main+%#x", cb, (unsigned long long)lo, (unsigned long long)size, tl_add_site);
        r->cm_site = tl_add_site;
        listgc_trim_last(r, lo);
        pthread_mutex_unlock(&g_handle_lock);
    }
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wframe-address"
static void cb_add_control(void *cb, void *mem, int64_t size) {
    if (memlog_on()) nx_log("memlog: %p AddControlMemory %p size %#llx from main+%#lx", cb, mem, (long long)size, main_off(__builtin_return_address(1)));
    cb_add_memory(cb, mem, 0, size, 1);
}
static void cb_add_command(void *cb, void *pool, int64_t off, int64_t size) {
    tl_add_site = (uint32_t)main_off(__builtin_return_address(1));
    if (memlog_on())
        nx_log("memlog: %p AddCommandMemory pool %p off %#llx size %#llx from main+%#lx", cb, pool, (long long)off, (long long)size,
               main_off(__builtin_return_address(1)));
    cb_add_memory(cb, pool, off, size, 0);
}
#pragma clang diagnostic pop
static void scan_chunks_for_handles(uint64_t lo, uint64_t hi) {
    int hits = 0;
    for (int i = 0; i < (g_nchunks < 4096 ? g_nchunks : 4096) && hits < 40; i++) {
        const MemChunk *c = &g_chunks[i];
        if (!c->mem) continue;
        for (uint64_t o = 0; o + 8 <= c->size && hits < 40; o += 4) {
            uint64_t v;
            memcpy(&v, c->mem + o, 8);
            if (v >= lo && v <= hi) {
                nx_log("gfx: dbg handle %#llx found in %s memory of cb %p at +%#llx", (unsigned long long)v,
                       c->control ? "control" : "command", c->cb, (unsigned long long)o);
                hits++;
            }
        }
    }
    nx_log("gfx: dbg scanned %d chunks for handles %#llx..%#llx: %d hits", g_nchunks, (unsigned long long)lo, (unsigned long long)hi, hits);
}

// probes (shaders.c, NXRT_BINDPROBE)
void bp_bind_program(void *, const void *, int32_t);
void bp_bind_uniform(void *, int32_t, int32_t, uint64_t, int64_t);
void bp_bind_texture(void *, int32_t, int32_t, uint64_t);
void bp_draw_elements_instanced(void *, int32_t, int32_t, int32_t, uint64_t, int32_t, int32_t, int32_t);
void bp_set_rt(void *, int32_t, void *const *, void *);

// NXRT_CLEARLOG=<frame>: record-time log of clears and render-target binds (command buffer, guest call site).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wframe-address"
#define CLEARLOG(fmt, ...) do { \
    static int f_ = -2; \
    if (f_ == -2) f_ = getenv("NXRT_CLEARLOG") ? atoi(getenv("NXRT_CLEARLOG")) : -1; \
    extern volatile int g_gfx_frame; \
    if (f_ == g_gfx_frame) nx_log("clearlog: cb %p at main+%#lx " fmt, cb, main_off(__builtin_return_address(1)), __VA_ARGS__); \
} while (0)
static void cb_set_rt(void *cb, int32_t n, void *const *colors, void *const *views, void *depth, void *dview) {
    CLEARLOG("set rt n %d color0 %p depth %p", n, n > 0 && colors ? colors[0] : NULL, depth);
    bp_set_rt(cb, n, colors, depth);
    OpRT o = {.n = n < 0 ? 0 : n > 8 ? 8 : n, .depth = depth};
    // Texture views select the mip level / layer (cube face) rendered to: mip chains and cubemap faces.
    for (int i = 0; i < o.n && colors; i++) {
        o.color[i] = colors[i];
        const NxTexView *v = views ? views[i] : NULL;
        if (v && (v->set & 1)) o.level[i] = v->base_level;
        if (v && (v->set & 2)) o.layer[i] = v->min_layer;
        if (v && (v->set & 8)) o.vfmt[i] = (int16_t)v->format;   // e.g. an RGBA8_SRGB view of an RGBA8 window texture
    }
    const NxTexView *dv = dview;
    if (dv && (dv->set & 1)) o.dlevel = dv->base_level;
    if (dv && (dv->set & 2)) o.dlayer = dv->min_layer;
    emit(cb, OP_RT, &o, sizeof o);
}
static void cb_clear_color(void *cb, int32_t index, const float *c, int32_t mask) {
    CLEARLOG("clear color%d mask %#x", index, mask);
    OpClearColor o = {.index = index, .mask = mask};
    if (c) memcpy(o.rgba, c, 16);
    emit(cb, OP_CLEAR_COLOR, &o, sizeof o);
}
static void cb_clear_ds(void *cb, float depth, int32_t depth_mask, int32_t stencil, int32_t stencil_mask) {
    CLEARLOG("clear depth %d (%g) stencil %d", depth_mask, depth, stencil_mask);
    OpClearDS o = {depth, depth_mask, stencil, stencil_mask};
    emit(cb, OP_CLEAR_DS, &o, sizeof o);
}
#pragma clang diagnostic pop
static void cb_clear_tex(void *cb, void *tex, void *view, const int32_t *region, const float *c, int32_t mask) {
    OpClearTex o = {.tex = tex, .has_region = region != NULL, .mask = mask, .nlevels = 1, .nlayers = 1};
    if (region) memcpy(o.region, region, sizeof o.region);
    // The view picks the mip levels / layers cleared (the Mii face bake clears the small levels it doesn't draw;
    // clearing level 0 instead wiped the face: no eyes up close).
    const NxTexView *cv = view;
    if (cv && (cv->set & 1)) o.level = cv->base_level, o.nlevels = cv->num_levels ? cv->num_levels : 1;
    if (cv && (cv->set & 2)) o.layer = cv->min_layer, o.nlayers = cv->num_layers ? cv->num_layers : 1;
    if (getenv("NXRT_CLEARTEXLOG")) {
        const NxTexView *v = view;
        NxTexDesc d = {0};
        nx_nvn_texture_desc(tex, &d);
        static int n;
        if (n++ < 200)
            nx_log("cleartex: %p %dx%d levels %d view set %#x level %d+%d layer %d+%d region %s %d,%d,%d %dx%dx%d mask %#x rgba %g %g %g %g",
                   tex, d.w, d.h, d.levels, v ? v->set : 0, v ? v->base_level : 0, v ? v->num_levels : 0, v ? v->min_layer : 0, v ? v->num_layers : 0,
                   region ? "yes" : "no", region ? region[0] : 0, region ? region[1] : 0, region ? region[2] : 0, region ? region[3] : 0,
                   region ? region[4] : 0, region ? region[5] : 0, mask, c ? c[0] : 0, c ? c[1] : 0, c ? c[2] : 0, c ? c[3] : 0);
    }
    if (c) memcpy(o.rgba, c, 16);
    emit(cb, OP_CLEAR_TEX, &o, sizeof o);
}
static void cb_bind_program(void *cb, const void *program, int32_t stages) {
    bp_bind_program(cb, program, stages);
    OpProgram o;
    o.n = gfx_program_info(program, o.st);
    emit(cb, OP_PROGRAM, &o, sizeof o);
}
static void cb_bind_ubo(void *cb, int32_t stage, int32_t index, uint64_t addr, int64_t size) {
    bp_bind_uniform(cb, stage, index, addr, size);
    OpBuf o = {stage, index, addr, (uint64_t)size};
    emit(cb, OP_UBO, &o, sizeof o);
}
void bp_bind_storage(void *, int32_t, int32_t, uint64_t, int64_t);
static void cb_bind_ssbo(void *cb, int32_t stage, int32_t index, uint64_t addr, int64_t size) {
    bp_bind_storage(cb, stage, index, addr, size);
    OpBuf o = {stage, index, addr, (uint64_t)size};
    emit(cb, OP_SSBO, &o, sizeof o);
}
static void cb_bind_texture(void *cb, int32_t stage, int32_t index, uint64_t handle) {
    bp_bind_texture(cb, stage, index, handle);
    OpTex o = {stage, index, handle};
    emit(cb, OP_TEX, &o, sizeof o);
}
static void cb_dispatch(void *cb, int32_t x, int32_t y, int32_t z) {
    OpDispatch o = {x, y, z};
    emit(cb, OP_DISPATCH, &o, sizeof o);
}
static void cb_bind_textures_deferred(void *cb, int32_t stage, int32_t first, int32_t count, const uint64_t *handles) {
    OpTexDeferred o = {stage, first, count, handles};
    emit(cb, OP_TEX_DEFERRED, &o, sizeof o);
}
void bp_bind_vertex_buffer(void *, int32_t, uint64_t, int64_t);
void bp_bind_vertex_attrib(void *, int32_t, const uint32_t *);
void bp_bind_vertex_stream(void *, int32_t, const uint32_t *);
static void cb_bind_vbuf(void *cb, int32_t index, uint64_t addr, int64_t size) {
    bp_bind_vertex_buffer(cb, index, addr, size);
    OpBuf o = {0, index, addr, (uint64_t)size};
    emit(cb, OP_VBUF, &o, sizeof o);
}
static void cb_bind_vattr(void *cb, int32_t n, const NvVAttr *a) {
    bp_bind_vertex_attrib(cb, n, (const uint32_t *)a);
    OpVAttr o = {.n = n < 0 ? 0 : n > 32 ? 32 : n};
    if (a) memcpy(o.a, a, o.n * sizeof *a);
    emit(cb, OP_VATTR, &o, offsetof(OpVAttr, a) + o.n * sizeof *a);
}
static void cb_bind_vstream(void *cb, int32_t n, const NvVStream *s) {
    bp_bind_vertex_stream(cb, n, (const uint32_t *)s);
    OpVStream o = {.n = n < 0 ? 0 : n > 32 ? 32 : n};
    if (s) memcpy(o.s, s, o.n * sizeof *s);
    emit(cb, OP_VSTREAM, &o, offsetof(OpVStream, s) + o.n * sizeof *s);
}
static void cb_bind_blend(void *cb, const NvBlend *b) { if (b) emit(cb, OP_BLEND, b, sizeof *b); }
static void cb_bind_color(void *cb, const NvColor *c) { if (c) emit(cb, OP_COLOR, c, sizeof *c); }
static void cb_bind_chmask(void *cb, const NvChMask *m) { if (m) emit(cb, OP_CHMASK, m, sizeof *m); }
static void cb_bind_ds(void *cb, const NvDS *d) { if (d) emit(cb, OP_DS, d, sizeof *d); }
static void cb_bind_poly(void *cb, const NvPoly *p) { if (p) emit(cb, OP_POLY, p, sizeof *p); }
static void cb_bind_ms(void *cb, const NvMS *m) { if (m) emit(cb, OP_MS, m, sizeof *m); }
static void cb_blend_color(void *cb, const float *c) {
    float v[4] = {0};
    if (c) memcpy(v, c, 16);
    emit(cb, OP_BLEND_COLOR, v, 16);
}
static void cb_viewport(void *cb, int32_t x, int32_t y, int32_t w, int32_t h) {
    OpRect o = {x, y, w, h};
    emit(cb, OP_VIEWPORT, &o, sizeof o);
}
static void cb_viewports(void *cb, int32_t first, int32_t count, const float *r) {
    if (first == 0 && count > 0 && r) emit(cb, OP_VIEWPORT, r, sizeof(OpRect));
}
static void cb_scissor(void *cb, int32_t x, int32_t y, int32_t w, int32_t h) {
    OpRect o = {x, y, w, h};
    emit(cb, OP_SCISSOR, &o, sizeof o);
}
static void cb_scissors(void *cb, int32_t first, int32_t count, const int32_t *r) {
    if (first == 0 && count > 0 && r) cb_scissor(cb, r[0], r[1], r[2], r[3]);
}
static void cb_depth_range(void *cb, float n, float f) {
    float v[2] = {n, f};
    emit(cb, OP_DEPTH_RANGE, v, sizeof v);
}
static void cb_poly_offset(void *cb, float factor, float units, float clamp) {
    float v[3] = {factor, units, clamp};
    emit(cb, OP_POLY_OFFSET, v, sizeof v);
}
static void cb_depth_clamp(void *cb, int32_t on) { emit(cb, OP_DEPTH_CLAMP, &on, sizeof on); }
static void cb_stencil_ref(void *cb, int32_t face, int32_t ref) {
    OpStencil o = {face, ref, 0, 0, 0};
    emit(cb, OP_STENCIL, &o, sizeof o);
}
static void cb_stencil_mask(void *cb, int32_t face, int32_t mask) {
    OpStencil o = {face, 0, mask, 0, 1};
    emit(cb, OP_STENCIL, &o, sizeof o);
}
static void cb_stencil_vmask(void *cb, int32_t face, int32_t mask) {
    OpStencil o = {face, 0, 0, mask, 2};
    emit(cb, OP_STENCIL, &o, sizeof o);
}
static void cb_draw_elements_instanced(void *cb, int32_t mode, int32_t type, int32_t count, uint64_t index_addr,
                                       int32_t base_vertex, int32_t base_instance, int32_t instances) {
    bp_draw_elements_instanced(cb, mode, type, count, index_addr, base_vertex, base_instance, instances);
    OpDrawElem o = {mode, type, count, base_vertex, base_instance, instances, index_addr};
    emit(cb, OP_DRAW_ELEM, &o, sizeof o);
}
static void cb_draw_elements(void *cb, int32_t mode, int32_t type, int32_t count, uint64_t index_addr) {
    cb_draw_elements_instanced(cb, mode, type, count, index_addr, 0, 0, 1);
}
static void cb_draw_elements_base_vertex(void *cb, int32_t mode, int32_t type, int32_t count, uint64_t index_addr, int32_t bv) {
    cb_draw_elements_instanced(cb, mode, type, count, index_addr, bv, 0, 1);
}
static void cb_draw_arrays_instanced(void *cb, int32_t mode, int32_t first, int32_t count, int32_t base_instance, int32_t instances) {
    OpDrawArrays o = {mode, first, count, base_instance, instances};
    emit(cb, OP_DRAW_ARRAYS, &o, sizeof o);
}
static void cb_draw_arrays(void *cb, int32_t mode, int32_t first, int32_t count) {
    cb_draw_arrays_instanced(cb, mode, first, count, 0, 1);
}
static void cb_update_ubo(void *cb, uint64_t addr, int64_t size, int64_t offset, int64_t data_size, const void *data) {
    if (data_size <= 0 || data_size > 0x10000 || !data) return;
    size_t n = sizeof(OpUpdateUbo) + data_size;
    OpUpdateUbo *o = malloc(n);
    o->addr = addr; o->offset = offset; o->size = data_size; o->buf_size = size;
    memcpy(o->data, data, data_size);
    emit(cb, OP_UPDATE_UBO, o, n);
    free(o);
}
// nvnCommandBufferCopyTextureToTexture(cmd, src, srcView, srcRegion, dst, dstView, dstRegion, flags).
// Views are ignored (level 0, layer 0). Likely how the game puts its final image into the window.
static void cb_copy_tex(void *cb, const void *src, const void *sview, const int32_t *sreg, const void *dst, const void *dview,
                        const int32_t *dreg, int32_t flags) {
    OpCopyTex o = {src, dst, {0}, {0}, flags, 0, 0, 0, 0};
    if (sreg) memcpy(o.sreg, sreg, sizeof o.sreg);
    if (dreg) memcpy(o.dreg, dreg, sizeof o.dreg);
    const NxTexView *sv = sview, *dv = dview;
    if (sv && (sv->set & 1)) o.slevel = sv->base_level;
    if (sv && (sv->set & 2)) o.slayer = sv->min_layer;
    if (dv && (dv->set & 1)) o.dlevel = dv->base_level;
    if (dv && (dv->set & 2)) o.dlayer = dv->min_layer;
    static int n;   // NXRT_COPYLOG=1 (or =<frame>: from that frame on): up to 400 copies, with formats
    static int from = -2;
    extern volatile int g_gfx_frame;
    if (from == -2) from = getenv("NXRT_COPYLOG") ? atoi(getenv("NXRT_COPYLOG")) : -1;
    if (n < 6 || (from >= 0 && g_gfx_frame >= from && n < 400)) {
        NxTexDesc sd = {0}, dd = {0};
        nx_nvn_texture_desc(src, &sd);
        nx_nvn_texture_desc(dst, &dd);
        nx_log("gfx: frame %d CopyTextureToTexture %p fmt %d L%d (%d,%d %dx%d) -> %p fmt %d L%d (%d,%d %dx%d) flags %#x", g_gfx_frame, src,
               sd.format, o.slevel, o.sreg[0], o.sreg[1], o.sreg[3], o.sreg[4], dst, dd.format, o.dlevel, o.dreg[0], o.dreg[1], o.dreg[3],
               o.dreg[4], flags);
        n++;
    }
    emit(cb, OP_COPY_TEX, &o, sizeof o);
}
static void cb_rasterizer_discard(void *cb, int32_t on) { emit(cb, OP_DISCARD, &on, sizeof on); }

// Events: a 32-bit value in pool memory that the GPU writes when it reaches the signal. The
// engine reads the memory itself (it never calls nvnEventGetValue) to know when the GPU is done
// with a frame, so the write happens when our Metal command buffer completes.
typedef struct { uint32_t *mem; } NvEvent;    // our state inside NVNeventBuilder / NVNevent
static void event_builder_defaults(NvEvent *b) { b->mem = NULL; }
static void event_builder_storage(NvEvent *b, const void *pool, int64_t offset) {
    uint64_t avail;
    b->mem = pool ? nx_nvn_gpu_to_host(((const uint64_t *)pool)[3] + offset, &avail) : NULL;
}
static uint64_t event_initialize(NvEvent *e, const NvEvent *b) { e->mem = b->mem; return 1; }
static uint32_t event_get_value(const NvEvent *e) { return e->mem ? __atomic_load_n(e->mem, __ATOMIC_ACQUIRE) : 0; }
static void event_signal(NvEvent *e, int32_t mode, uint32_t value) {     // CPU-side signal
    if (!e->mem) return;
    if (mode == 1) __atomic_fetch_add(e->mem, value, __ATOMIC_RELEASE);
    else __atomic_store_n(e->mem, value, __ATOMIC_RELEASE);
}
static void cb_signal_event(void *cb, const NvEvent *e, int32_t mode, int32_t location, int32_t flags, uint32_t value) {
    static int logged;
    if (dbg() && logged++ < 4) nx_log("gfx: SignalEvent(%p mem %p, mode %d, location %d, flags %#x, value %u)", e, e ? e->mem : NULL, mode, location, flags, value);
    if (!e || !e->mem) return;
    OpSignal o = {e->mem, mode, value};
    emit(cb, OP_SIGNAL_EVENT, &o, sizeof o);
}
// Counters: the GPU writes {value, timestamp} (16 bytes) to a buffer address.
// Conditional rendering (NVN): SetRenderEnable(bool) switches draws off/on; SetRenderEnableConditional
// (mode, address) renders only if the two 64-bit counter values at address and address + 16 compare
// equal (mode 0) / not equal (mode 1). NXRT_RELOG=1 logs the first calls.
// NXRT_RELOG=<from>-<to>: every call in that frame range (plain NXRT_RELOG=1: the first 40 of each).
static int relog_lo = -1, relog_hi = -1;
static int relog(void) {
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("NXRT_RELOG");
        on = e != NULL;
        if (e && strchr(e, '-')) relog_lo = atoi(e), relog_hi = atoi(strchr(e, '-') + 1);
    }
    if (on && relog_lo >= 0) {
        extern volatile int g_gfx_frame;
        return g_gfx_frame >= relog_lo && g_gfx_frame <= relog_hi ? 2 : 0;
    }
    return on;
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wframe-address"   // guest caller, see the note above
// nvnCommandBufferBarrier(flags): on Maxwell, draws see earlier rendering into a texture they sample
// only after a barrier that invalidates the texture cache. Render-target feedback copies are
// refreshed per barrier epoch (see resolve_feedback).
static void cb_barrier(void *cb, int32_t flags) { emit(cb, OP_BARRIER, &flags, sizeof flags); }
static void cb_render_enable(void *cb, int32_t on) {
    static int n;
    if (relog() && (relog_lo >= 0 || n++ < 40)) nx_log("re: %p SetRenderEnable %d from main+%#lx", cb, on, main_off(__builtin_return_address(1)));
    OpRenderEnable o = {on ? 1 : 0, NULL};
    emit(cb, OP_RENDER_ENABLE, &o, sizeof o);
}
static void cb_render_enable_cond(void *cb, int32_t mode, uint64_t addr) {
    uint64_t avail = 0;
    const uint64_t *mem = nx_nvn_gpu_to_host(addr, &avail);
    static int n;
    if (relog() && (relog_lo >= 0 || n++ < 40))
        nx_log("re: %p SetRenderEnableConditional mode %d addr %#llx (%s): values %#llx / %#llx from main+%#lx", cb, mode,
               (unsigned long long)addr, mem && avail >= 32 ? "mapped" : "UNMAPPED", mem && avail >= 32 ? (unsigned long long)mem[0] : 0ull,
               mem && avail >= 32 ? (unsigned long long)mem[2] : 0ull, main_off(__builtin_return_address(1)));
    OpRenderEnable o = {mode == 1 ? 3 : 2, mem && avail >= 32 ? mem : NULL};
    emit(cb, OP_RENDER_ENABLE, &o, sizeof o);
}
#pragma clang diagnostic pop
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wframe-address"   // guest caller
static void cb_report_counter(void *cb, int32_t type, uint64_t addr) {
    if (dbg()) hist("ReportCounter type", type);
    extern volatile int g_gfx_frame;
    static uint64_t seen;                       // first use of each counter type, with its caller
    if (type >= 0 && type < 64 && !(__atomic_fetch_or(&seen, 1ull << type, __ATOMIC_RELAXED) & (1ull << type)))
        nx_log("gfx: first ReportCounter type %d (frame %d) from main+%#lx", type, g_gfx_frame, main_off(__builtin_return_address(1)));
    static int n;
    uint64_t avail = 0;
    uint64_t *mem = nx_nvn_gpu_to_host(addr, &avail);
    if (relog() && (relog_lo >= 0 || n++ < 40))
        nx_log("re: %p ReportCounter type %d addr %#llx (host %p) from main+%#lx", cb, type, (unsigned long long)addr, (void *)mem,
               main_off(__builtin_return_address(1)));
    if (!mem || avail < 16) return;
    OpCounter o = {mem, type};
    emit(cb, OP_REPORT_COUNTER, &o, sizeof o);
}
#pragma clang diagnostic pop

// ---- Metal resources -----------------------------------------------------------------
static pthread_mutex_t g_exec_lock = PTHREAD_MUTEX_INITIALIZER;
enum { POOLBUF_MAX = 8192 };   // nvn.c MAX_POOLS; pool indices are stable
static __strong id<MTLBuffer> g_poolbufs[POOLBUF_MAX];   // pool index -> zero-copy buffer
static uint64_t g_poolbuf_base[POOLBUF_MAX];            // pool index -> host offset of buffer start

// NXRT_RESIDENCY (Mac default 2, iOS 0): 1 = the wrapped pools and the big render targets go into a residency set
// attached to the queue (macOS 15 / iOS 18), so the system's memory compressor leaves their pages alone. From the BOTW
// port (its session 22): GPU stalls of 35-67 ms after menus and resolution changes, each with 10-13k page
// decompressions in Metal's submit thread, were the unused parts of big targets compressed and brought back before the
// GPU could go on. Pools join when wrapped; textures by residency_sync every RES_SYNC submits (added when new, removed
// once gone from the texture table). 2 = every texture of RES_MIN_BYTES or more, sampled ones too.
// The phone's SDK (iPhoneOS16.5) predates MTLResidencySet: compiled out there (iOS default is off anyway).
#if __has_include(<Metal/MTLResidencySet.h>)
enum { RES_SYNC = 60, RES_MIN_BYTES = 1 << 20 };
static __strong id g_rset;   // id<MTLResidencySet>
static NSMutableSet *g_rset_tex;   // the textures in it
static int g_rset_dirty;
static pthread_mutex_t g_rset_lock = PTHREAD_MUTEX_INITIALIZER;
static int residency_on(void) {
    static int on = -1;
    if (on < 0) on = getenv("NXRT_RESIDENCY") ? atoi(getenv("NXRT_RESIDENCY")) : !TARGET_OS_IPHONE * 2;   // iOS: untested
    return on;
}
static id residency_set(void) {   // g_rset_lock held
    if (!g_rset)
        if (@available(macOS 15.0, iOS 18.0, *)) {
            MTLResidencySetDescriptor *d = [MTLResidencySetDescriptor new];
            d.label = @"nxrt";
            d.initialCapacity = 8192;
            NSError *err = nil;
            g_rset = [g_dev newResidencySetWithDescriptor:d error:&err];
            if (g_rset) [g_queue addResidencySet:g_rset];
            g_rset_tex = [NSMutableSet set];
            nx_log("gfx: residency set (pools, render targets): %s", g_rset ? "on" : err.localizedDescription.UTF8String);
        }
    return g_rset;
}
static void residency_add(id<MTLBuffer> b) {
    if (!residency_on()) return;
    if (@available(macOS 15.0, iOS 18.0, *)) {
        pthread_mutex_lock(&g_rset_lock);
        id<MTLResidencySet> rs = residency_set();
        if (rs) [rs addAllocation:b], g_rset_dirty = 1;
        pthread_mutex_unlock(&g_rset_lock);
    }
}
static void residency_sync(void) {   // once per submit: textures every RES_SYNC, then commit what changed
    if (!residency_on()) return;
    if (@available(macOS 15.0, iOS 18.0, *)) {
        static int n;
        NSArray *live = n++ % RES_SYNC == 0 ? gfx_texture_rt_list(RES_MIN_BYTES, residency_on() >= 2) : nil;
        pthread_mutex_lock(&g_rset_lock);
        id<MTLResidencySet> rs = residency_set();
        if (rs && live) {
            NSSet *now = [NSSet setWithArray:live];
            int added = 0, removed = 0;
            for (id<MTLTexture> t in [g_rset_tex copy])
                if (![now containsObject:t]) [rs removeAllocation:t], [g_rset_tex removeObject:t], removed++;
            for (id<MTLTexture> t in live)
                if (![g_rset_tex containsObject:t]) [rs addAllocation:t], [g_rset_tex addObject:t], added++;
            if (added || removed) g_rset_dirty = 1;
            static int nlog;
            if ((added || removed) && nlog++ < 12)
                nx_log("gfx: residency set: %lu textures (+%d -%d), %.0f MB total resident", (unsigned long)g_rset_tex.count, added,
                       removed, rs.allocatedSize / 1048576.0);
        }
        if (rs && g_rset_dirty) [rs commit], g_rset_dirty = 0;
        pthread_mutex_unlock(&g_rset_lock);
    }
}
#else
static void residency_add(id<MTLBuffer> b) { (void)b; }
static void residency_sync(void) {}
#endif

// MTLBuffer + offset for a GPU address (the pool's memory, wrapped once without copying). A raw pointer (the buffer
// lives in g_poolbufs): callers keep it unretained, and the id return's ARC handshake ran ~5,000 times a frame.
#define buf_for(gpu, offset) ((__bridge id<MTLBuffer>)buf_for_raw(gpu, offset))
static inline __attribute__((always_inline)) void *buf_for_raw(uint64_t gpu, NSUInteger *offset) {
    uint8_t *mem;
    uint64_t size, off;
    int idx = nx_nvn_gpu_pool(gpu, &mem, &size, &off);
    if (idx < 0 || idx >= POOLBUF_MAX) return NULL;
    __unsafe_unretained id<MTLBuffer> b = g_poolbufs[idx];
    if (!b) {
        id<MTLBuffer> nb = nil;
        uintptr_t start = (uintptr_t)mem & ~(uintptr_t)0x3FFF;
        uintptr_t end = ((uintptr_t)mem + size + 0x3FFF) & ~(uintptr_t)0x3FFF;
        // 64 KB of slack past the pool when that host memory is mapped (guest memory is one host mapping, so it
        // usually is): a cbuf bound near the pool's end whose reach the shader doesn't bound (cbuf_reach: 64 KB)
        // then binds in place instead of being copied to the arena each draw (from the BOTW port; 1,266 copies/frame
        // on the island). The GPU reads what follows, as Maxwell would. NXRT_POOL_SLACK=0: off.
        static int slack_on = -1;
        if (slack_on < 0) slack_on = !(getenv("NXRT_POOL_SLACK") && !atoi(getenv("NXRT_POOL_SLACK")));
        vm_address_t ra = end;   // vm_region_64: iOS has no mach_vm.h
        vm_size_t rs = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        if (slack_on && vm_region_64(mach_task_self(), &ra, &rs, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, &obj) == KERN_SUCCESS &&
            ra <= end && ra + rs >= end + 0x10000 && (info.protection & VM_PROT_READ))
            nb = [g_dev newBufferWithBytesNoCopy:(void *)start length:end + 0x10000 - start options:MTLResourceStorageModeShared deallocator:nil];
        if (!nb) nb = [g_dev newBufferWithBytesNoCopy:(void *)start length:end - start options:MTLResourceStorageModeShared deallocator:nil];
        if (!nb) {
            nx_log("gfx: cannot wrap pool %d (%p, %#llx bytes)", idx, mem, (unsigned long long)size);
            return NULL;
        }
        g_poolbufs[idx] = nb;
        b = nb;
        residency_add(nb);
        static uint64_t wrapped;
        wrapped += nb.length;
        nx_log("gfx: wrapped pool %d: %#llx bytes%s (total wrapped %llu MB)", idx, (unsigned long long)nb.length,
               nb.length > end - start ? " (+64 KB slack)" : "", (unsigned long long)(wrapped >> 20));
        g_poolbuf_base[idx] = (uintptr_t)mem - start;
    }
    *offset = g_poolbuf_base[idx] + off;
    return (__bridge void *)b;
}

// How far into the cbuf at [[buffer(binding)]] the shader reads: the shaders declare every cbuf as
// float4 _m0[4096] (64 KB), but most only index it with constants (`fp_c9._m0[41]`). Returns 16 * (max
// index + 1) when every use is such a constant index, else 0x10000. Binds whose pool ends within that
// reach need an arena copy (the GPU would read past the buffer); the rest bind in place.
static int cbuf_reach(NSString *msl, int binding) {
    NSRegularExpression *pre = [NSRegularExpression
        regularExpressionWithPattern:[NSString stringWithFormat:@"constant (\\w+)& (\\w+) \\[\\[buffer\\(%d\\)\\]\\]", binding] options:0 error:nil];
    NSTextCheckingResult *pm = [pre firstMatchInString:msl options:0 range:NSMakeRange(0, msl.length)];
    if (!pm) return 0x10000;
    NSString *ty = [msl substringWithRange:[pm rangeAtIndex:1]], *name = [msl substringWithRange:[pm rangeAtIndex:2]];
    if (![msl containsString:[NSString stringWithFormat:@"struct %@\n{\n    float4 _m0[4096];\n};", ty]]) return 0x10000;
    NSRegularExpression *use = [NSRegularExpression
        regularExpressionWithPattern:[NSString stringWithFormat:@"\\b%@\\b(\\._m0\\[(\\d+)\\])?", name] options:0 error:nil];
    int uses = 0, consts = 0, mx = -1;
    for (NSTextCheckingResult *m in [use matchesInString:msl options:0 range:NSMakeRange(0, msl.length)]) {
        uses++;
        if ([m rangeAtIndex:2].location == NSNotFound) continue;
        consts++;
        mx = MAX(mx, [[msl substringWithRange:[m rangeAtIndex:2]] intValue]);
    }
    // uses - 1: the parameter declaration itself
    return uses - 1 == consts && mx < 4096 ? (mx + 1) * 16 : 0x10000;
}

// Translated shader: function + the resources it reads.
@interface NxShader : NSObject {
@public
    id<MTLFunction> fn;
    volatile int ready;   // 0 compiling, 1 ready, -1 failed (set by the async compile)
    int ncb, ntex, nattr, nsb, uses_support;
    int cb_slot[24], cb_binding[24], sb_binding[16], sb_cboff[16];
    int cb_reach[24];     // bytes of the cbuf the shader can read (cbuf_reach), 0x10000 if not provable
    int local[3];         // compute workgroup size
    int tex_handle[64], tex_binding[64], tex_cbuf[64];
    int arr_i;            // cbuf texture array (mslfix `// nxrt-texarray`): index in tex_*, else -1
    int arr_slots, arr_stride, arr_noffs, arr_offs[16];
    MTLTextureType tex_type[64];
    int attr_loc[32];
    char attr_kind[32];   // 'f' float, 'i' int, 'u' uint
    uint64_t locs;        // VS: varying locations written (main0_out); FS: read (main0_in)
    NSString *msl, *name;
}
@end
@implementation NxShader
@end

static NSMutableDictionary<NSString *, id> *g_shaders;   // "<hash>.<kind>" -> NxShader or NSNull

static MTLTextureType msl_texture_type(NSString *t) {
    if ([t hasPrefix:@"texture2d_array"] || [t hasPrefix:@"depth2d_array"]) return MTLTextureType2DArray;
    if ([t hasPrefix:@"texturecube_array"] || [t hasPrefix:@"depthcube_array"]) return MTLTextureTypeCubeArray;
    if ([t hasPrefix:@"texturecube"] || [t hasPrefix:@"depthcube"]) return MTLTextureTypeCube;
    if ([t hasPrefix:@"texture3d"]) return MTLTextureType3D;
    if ([t hasPrefix:@"texture1d_array"]) return MTLTextureType1DArray;
    if ([t hasPrefix:@"texture1d"]) return MTLTextureType1D;
    if ([t hasPrefix:@"texture2d_ms"] || [t hasPrefix:@"depth2d_ms"]) return MTLTextureType2DMultisample;
    if ([t hasPrefix:@"texture_buffer"]) return MTLTextureTypeTextureBuffer;
    return MTLTextureType2D;
}

static NxShader *shader_load(uint64_t hash, const char *kind);
static NSString *shader_msl(NxShader *s);

// Shader functions come precompiled from <NXRT_SHADERS>/shaders.metallib (tools/shadertool/build_metallib.py): one
// function per MSL text, named h_<FNV-1a 64 of the text>, so base shaders and the variants derived from them below
// are found by hashing the exact source that would otherwise be compiled. A miss compiles that source asynchronously
// as before (tens of ms per shader on the Mac, far more on the phone: the title-screen stalls). Misses are logged
// and, with NXRT_SHADER_MISSDIR (default in the simulator: Documents/shader_misses), saved for the next metallib.
static uint64_t g_fn_hits, g_fn_misses, g_fn_ns;
static uint64_t msl_hash(NSString *msl) {   // FNV-1a 64 of the UTF-8 text (build_metallib.py hashes the file bytes)
    uint64_t h = 0xcbf29ce484222325ull;
    for (const unsigned char *p = (const unsigned char *)msl.UTF8String; *p; p++) h = (h ^ *p) * 0x100000001b3ull;
    return h;
}
// h: msl_hash of the source; source() is only called on a miss (shaders from the index have no text loaded).
static void msl_function_h(uint64_t h, NSString *(^source)(void), void (^done)(id<MTLFunction> fn, NSError *err)) {
    static id<MTLLibrary> lib;
    static int tried;
    if (!tried) {
        tried = 1;
        const char *root = getenv("NXRT_SHADERS") ? getenv("NXRT_SHADERS") : "shaders";
        NSString *path = [NSString stringWithFormat:@"%s/shaders.metallib", root];
        NSError *err = nil;
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        // NXRT_METALLIB=0: compile every shader from source (A/B)
        if (!(getenv("NXRT_METALLIB") && !atoi(getenv("NXRT_METALLIB"))) && [NSFileManager.defaultManager fileExistsAtPath:path]) lib = [g_dev newLibraryWithURL:[NSURL fileURLWithPath:path] error:&err];
        nx_log("gfx: precompiled shaders %s: %s (%lu functions, %.0f ms)", path.UTF8String, lib ? "loaded" : err ? err.localizedDescription.UTF8String : "none",
               (unsigned long)lib.functionNames.count, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6);
    }
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    id<MTLFunction> fn = lib ? [lib newFunctionWithName:[NSString stringWithFormat:@"h_%016llx", (unsigned long long)h]] : nil;
    g_fn_ns += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;
    if (fn) {
        g_fn_hits++;
        done(fn, nil);
        return;
    }
    g_fn_misses++;
    if (lib) {
        static int n;
        if (n++ < 20) nx_log("gfx: shader %016llx not in the metallib, compiling it", (unsigned long long)h);
    }
    NSString *msl = source();
    if (!msl) {
        done(nil, nil);
        return;
    }
    const char *dir = getenv("NXRT_SHADER_MISSDIR");
    if (dir) {
        mkdir(dir, 0755);
        [msl writeToFile:[NSString stringWithFormat:@"%s/%016llx.metal", dir, (unsigned long long)h] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    MTLCompileOptions *opt = [MTLCompileOptions new];
    opt.languageVersion = MTLLanguageVersion3_0;
    opt.preserveInvariance = YES;   // [[position, invariant]] (mslfix drop_optnone)
    [g_dev newLibraryWithSource:msl options:opt completionHandler:^(id<MTLLibrary> l, NSError *err) {
        done([l newFunctionWithName:@"main0"], err);
    }];
}
static void msl_function(NSString *msl, void (^done)(id<MTLFunction> fn, NSError *err)) {
    msl_function_h(msl_hash(msl), ^{ return msl; }, done);
}
// Slow-encode diagnostics: time blocked on compiles, time loading shaders (file + JSON + regex parsing), counts.
static uint64_t g_compile_wait_ns, g_compile_waits, g_shader_load_ns, g_shader_loads, g_pipes_created;
// NXRT_HITCHLOG (thread.c nx_hitch_frame): running totals, never reset (the stats lines reset theirs each interval).
static uint64_t g_hitch_encode_ns, g_hitch_encode_cpu_ns, g_hitch_gpu_ns, g_hitch_block_ns, g_stat_block_ns;   // g_stat_block_ns: per stats interval
void gfx_hitch_counters(uint64_t c[10]) {
    extern uint64_t g_tex_upload_ns, g_tex_upload_bytes, g_present_pace_ns;
    c[0] = g_hitch_encode_ns, c[1] = g_hitch_encode_cpu_ns, c[2] = g_compile_wait_ns, c[3] = g_tex_upload_ns;
    c[4] = g_tex_upload_bytes, c[5] = g_shader_load_ns, c[6] = g_pipes_created, c[7] = __atomic_load_n(&g_hitch_gpu_ns, __ATOMIC_RELAXED);
    c[8] = __atomic_load_n(&g_hitch_block_ns, __ATOMIC_RELAXED), c[9] = g_present_pace_ns;
}
// Waits for an asynchronous shader / pipeline compile (*ready leaves 0) and returns the result (1 ok, -1
// failed). Draws used to be dropped until the compile finished: harmless for per-frame rendering, but
// one-time GPU work done at load was lost for good (the water's shore map, baked in ~33 passes at boot
// while their pipelines compiled, stayed all zero, so the sea had no shallow band). NXRT_COMPILE_DROP=1:
// old behavior. Waits over 20 ms are logged.
static int wait_compiled(volatile int *ready) {
    static int drop = -1;
    if (drop < 0) drop = getenv("NXRT_COMPILE_DROP") != NULL;
    int r = __atomic_load_n(ready, __ATOMIC_ACQUIRE);
    if (r || drop) return r;
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    while ((r = __atomic_load_n(ready, __ATOMIC_ACQUIRE)) == 0) usleep(100);
    g_compile_wait_ns += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0, g_compile_waits++;
    uint64_t ms = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1000000;
    static int n;
    extern volatile int g_gfx_frame;
    if (ms > 20 && n++ < 40) nx_log("gfx: waited %llu ms for a shader/pipeline compile (frame %d)", (unsigned long long)ms, g_gfx_frame);
    return r;
}
// Direct-mapped front cache (two lookups per draw; formatting the name each time was a hot spot).
// Shaders are never freed (g_shaders keeps them), so unretained pointers are safe.
static NxShader *shader_get(uint64_t hash, const char *kind) {
    static struct { uint64_t hash; char kind; __unsafe_unretained NxShader *s; int valid; } cache[4096];
    unsigned i = (unsigned)(hash ^ hash >> 32 ^ (uint8_t)kind[0]) & 4095;
    if (cache[i].valid && cache[i].hash == hash && cache[i].kind == kind[0]) return cache[i].s;
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    NxShader *s = shader_load(hash, kind);
    g_shader_load_ns += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0, g_shader_loads++;
    cache[i].hash = hash, cache[i].kind = kind[0], cache[i].s = s, cache[i].valid = 1;
    return s;
}

// A fragment shader reading varyings its vertex shader doesn't write: Maxwell links that (the inputs
// read a default), Metal refuses the pipeline. Variant of the FS with those inputs replaced by
// constants (0, 0, 0, 1), compiled asynchronously; nil while it compiles or if it fails.
static NxShader *fs_variant(NxShader *fs, uint64_t missing) {
    static NSMutableDictionary<NSString *, NxShader *> *variants;
    if (!variants) variants = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%@-%llx", fs->name, (unsigned long long)missing];
    NxShader *v = variants[key];
    if (!v) {
        v = [NxShader new];
        memcpy(&v->ncb, &fs->ncb, (const char *)&fs->locs - (const char *)&fs->ncb);
        v->locs = fs->locs & ~missing, v->name = key;
        variants[key] = v;
        NSMutableString *m = [shader_msl(fs) mutableCopy];
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
            @"\n\\s*(\\w+) (\\w+) \\[\\[user\\(locn(\\d+)\\)[^\\]]*\\]\\];" options:0 error:nil];
        NSArray<NSTextCheckingResult *> *hits = [re matchesInString:m options:0 range:NSMakeRange(0, m.length)];
        int removed = 0, total = (int)hits.count;
        for (NSTextCheckingResult *h in hits.reverseObjectEnumerator) {
            int l = [[m substringWithRange:[h rangeAtIndex:3]] intValue];
            if (l >= 64 || !(missing >> l & 1)) continue;
            NSString *type = [m substringWithRange:[h rangeAtIndex:1]], *member = [m substringWithRange:[h rangeAtIndex:2]];
            NSString *def = [type hasSuffix:@"4"] ? [NSString stringWithFormat:@"%@(0, 0, 0, 1)", type] : [NSString stringWithFormat:@"%@(0)", type];
            [m deleteCharactersInRange:h.range];
            [m replaceOccurrencesOfString:[NSString stringWithFormat:@"\\bin\\.%@\\b", member] withString:def
                                  options:NSRegularExpressionSearch range:NSMakeRange(0, m.length)];
            removed++;
        }
        if (removed == total) {   // no inputs left: drop the empty stage_in struct parameter
            [m replaceOccurrencesOfString:@"main0_in in [[stage_in]], " withString:@"" options:0 range:NSMakeRange(0, m.length)];
            [m replaceOccurrencesOfString:@", main0_in in [[stage_in]]" withString:@"" options:0 range:NSMakeRange(0, m.length)];
            [m replaceOccurrencesOfString:@"main0_in in [[stage_in]]" withString:@"" options:0 range:NSMakeRange(0, m.length)];
        }
        nx_log("gfx: FS variant %s (inputs %#llx not written by the VS: %d replaced)", key.UTF8String, (unsigned long long)missing, removed);
        msl_function(m, ^(id<MTLFunction> fn, NSError *err) {
            if (!fn) nx_log("gfx: FS variant %s does not compile: %s", key.UTF8String, err.localizedDescription.UTF8String);
            v->fn = fn;
            __atomic_store_n(&v->ready, fn ? 1 : -1, __ATOMIC_RELEASE);
        });
    }
    return __atomic_load_n(&v->ready, __ATOMIC_ACQUIRE) == 1 ? v : nil;
}

// Integer render targets. The translator declares every colour output float4 (the offline graphics state has
// no target formats); the Maxwell code writes raw bits (e.g. as_type<float>(packed block) in the BC3 portrait
// encoder), and Metal needs uint/int outputs for integer formats. Variant of the FS whose outputs to those
// targets are uint4/int4, bit-cast from the float values at each return. Waits for the compile (one-time bakes).
static int mtl_int_kind(MTLPixelFormat f) {   // 1 unsigned, 2 signed, 0 float/normalized
    switch (f) {
    case MTLPixelFormatR8Uint: case MTLPixelFormatR16Uint: case MTLPixelFormatR32Uint: case MTLPixelFormatRG8Uint: case MTLPixelFormatRG16Uint:
    case MTLPixelFormatRG32Uint: case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRGBA16Uint: case MTLPixelFormatRGBA32Uint:
    case MTLPixelFormatRGB10A2Uint: return 1;
    case MTLPixelFormatR8Sint: case MTLPixelFormatR16Sint: case MTLPixelFormatR32Sint: case MTLPixelFormatRG8Sint: case MTLPixelFormatRG16Sint:
    case MTLPixelFormatRG32Sint: case MTLPixelFormatRGBA8Sint: case MTLPixelFormatRGBA16Sint: case MTLPixelFormatRGBA32Sint: return 2;
    default: return 0;
    }
}
static NxShader *fs_int_variant(NxShader *fs, uint32_t umask, uint32_t smask) {
    static NSMutableDictionary<NSString *, NxShader *> *variants;
    if (!variants) variants = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%@-out%x-%x", fs->name, umask, smask];
    NxShader *v = variants[key];
    if (!v) {
        v = [NxShader new];
        memcpy(&v->ncb, &fs->ncb, (const char *)&fs->locs - (const char *)&fs->ncb);
        v->locs = fs->locs, v->name = key;
        variants[key] = v;
        NSMutableString *m = [shader_msl(fs) mutableCopy];
        NSMutableString *decl = [NSMutableString string], *store = [NSMutableString string];
        int changed = 0;
        for (int i = 0; i < 8; i++) {
            if (!((umask | smask) >> i & 1)) continue;
            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
                [NSString stringWithFormat:@"\\bfloat(\\d?) (\\w+) \\[\\[color\\(%d\\)\\]\\]", i] options:0 error:nil];
            NSTextCheckingResult *h = [re firstMatchInString:m options:0 range:NSMakeRange(0, m.length)];
            if (!h) continue;
            NSString *n = [m substringWithRange:[h rangeAtIndex:1]], *member = [m substringWithRange:[h rangeAtIndex:2]];
            NSString *it = [NSString stringWithFormat:@"%@%@", umask >> i & 1 ? @"uint" : @"int", n];
            [m replaceCharactersInRange:h.range withString:[NSString stringWithFormat:@"%@ %@ [[color(%d)]]", it, member, i]];
            [m replaceOccurrencesOfString:[NSString stringWithFormat:@"\\bout\\.%@\\b", member] withString:[NSString stringWithFormat:@"nx_%@", member]
                                  options:NSRegularExpressionSearch range:NSMakeRange(0, m.length)];
            [decl appendFormat:@"\n    float%@ nx_%@ = float%@(0);", n, member, n];
            [store appendFormat:@"out.%@ = as_type<%@>(nx_%@); ", member, it, member];
            changed++;
        }
        [m replaceOccurrencesOfString:@"main0_out out = {};" withString:[NSString stringWithFormat:@"main0_out out = {};%@", decl] options:0
                                range:NSMakeRange(0, m.length)];
        [m replaceOccurrencesOfString:@"return out;" withString:[NSString stringWithFormat:@"{ %@return out; }", store] options:0
                                range:NSMakeRange(0, m.length)];
        nx_log("gfx: FS variant %s (%d integer outputs)", key.UTF8String, changed);
        msl_function(m, ^(id<MTLFunction> f, NSError *err) {
            if (!f) nx_log("gfx: FS variant %s does not compile: %s", key.UTF8String, err.localizedDescription.UTF8String);
            v->fn = f;
            __atomic_store_n(&v->ready, f ? 1 : -1, __ATOMIC_RELEASE);
        });
    }
    return wait_compiled(&v->ready) == 1 ? v : nil;
}

// Integer vertex formats. The translator declares every vertex input float (its graphics state has no
// attribute types offline), and Metal converts integer formats to float *values* (3 -> 3.0), while
// the Maxwell code expects the raw bits in the attribute register (R8UI bone indices etc.). Variant of
// the VS with those inputs declared uint/int and bit-cast back to float; nil while it compiles.
static int vfmt_int(int f) {   // 1 unsigned, 2 signed, 0 float/normalized
    switch (f) {
    case 3: case 8: case 11: case 15: case 20: case 23: case 27: case 32: case 35: case 39: case 44: case 47: return 1;
    case 4: case 9: case 12: case 16: case 21: case 24: case 28: case 33: case 36: case 40: case 45: case 48: return 2;
    default: return 0;
    }
}
static NxShader *vs_variant(NxShader *vs, uint32_t umask, uint32_t smask) {
    static NSMutableDictionary<NSString *, NxShader *> *variants;
    if (!variants) variants = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%@-u%x-s%x", vs->name, umask, smask];
    NxShader *v = variants[key];
    if (!v) {
        v = [NxShader new];
        memcpy(&v->ncb, &vs->ncb, (const char *)&vs->locs - (const char *)&vs->ncb);
        v->locs = vs->locs, v->name = key, v->msl = shader_msl(vs);
        variants[key] = v;
        NSMutableString *m = [v->msl mutableCopy];
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
            @"(float)(\\d?) (\\w+) \\[\\[attribute\\((\\d+)\\)\\]\\];" options:0 error:nil];
        NSArray<NSTextCheckingResult *> *hits = [re matchesInString:m options:0 range:NSMakeRange(0, m.length)];
        int changed = 0;
        for (NSTextCheckingResult *h in hits.reverseObjectEnumerator) {
            int l = [[m substringWithRange:[h rangeAtIndex:4]] intValue];
            int sgn = l < 32 && (smask >> l & 1), uns = l < 32 && (umask >> l & 1);
            if (!sgn && !uns) continue;
            NSString *n = [m substringWithRange:[h rangeAtIndex:2]], *member = [m substringWithRange:[h rangeAtIndex:3]];
            [m replaceCharactersInRange:[h rangeAtIndex:1] withString:sgn ? @"int" : @"uint"];
            NSString *pat = [NSString stringWithFormat:@"\\bin\\.%@\\b", member];
            [m replaceOccurrencesOfString:pat withString:[NSString stringWithFormat:@"as_type<float%@>(in.%@)", n, member]
                                  options:NSRegularExpressionSearch range:NSMakeRange(0, m.length)];
            changed++;
            for (int k = 0; k < v->nattr; k++)
                if (v->attr_loc[k] == l) v->attr_kind[k] = sgn ? 'i' : 'u';
        }
        // the declaration itself was rewritten too ("in.X" does not occur there), uses now read as_type<>(in.X)
        nx_log("gfx: VS variant %s (%d integer inputs)", key.UTF8String, changed);
        msl_function(m, ^(id<MTLFunction> fn, NSError *err) {
            if (!fn) nx_log("gfx: VS variant %s does not compile: %s", key.UTF8String, err.localizedDescription.UTF8String);
            v->fn = fn;
            __atomic_store_n(&v->ready, fn ? 1 : -1, __ATOMIC_RELEASE);
        });
    }
    return __atomic_load_n(&v->ready, __ATOMIC_ACQUIRE) == 1 ? v : nil;
}

// What a shader needs at draw time (resources, attributes, varyings), parsed from its MSL text and the translator's
// JSON. Regex work: ~3 ms per shader on the Mac, done on the encode thread the first time a shader is drawn (1.1 s
// of the cold title-screen stall), so builds ship it precomputed in shaders.index (gfx_build_shader_index).
static void shader_parse(NxShader *s, NSString *msl, NSData *json, const char *kind) {
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    for (NSDictionary *c in j[@"cbuffers"]) {
        if (s->ncb == 24) break;
        s->cb_slot[s->ncb] = [c[@"slot"] intValue];
        s->cb_binding[s->ncb] = [c[@"binding"] intValue];
        s->cb_reach[s->ncb] = cbuf_reach(msl, s->cb_binding[s->ncb]);
        s->ncb++;
    }
    // Storage buffers the MSL still declares (SPIRV-Cross drops unused ones: 156 fragment shaders list
    // a storage buffer that their MSL never binds).
    for (NSDictionary *b in j[@"sbuffers"]) {
        if (s->nsb == 16) break;
        int binding = [b[@"binding"] intValue];
        if ([msl rangeOfString:[NSString stringWithFormat:@"[[buffer(%d)]]", binding]].location == NSNotFound) continue;
        s->sb_cboff[s->nsb] = [b[@"cbOffset"] intValue];
        s->sb_binding[s->nsb++] = binding;
    }
    NSRange io = [msl rangeOfString:kind[0] == 'f' ? @"struct main0_in\n{" : @"struct main0_out\n{"];
    if (io.location != NSNotFound && (kind[0] == 'v' || kind[0] == 'f')) {
        NSRange end = [msl rangeOfString:@"};" options:0 range:NSMakeRange(io.location, msl.length - io.location)];
        NSString *body = [msl substringWithRange:NSMakeRange(io.location, end.location - io.location)];
        NSRegularExpression *lre = [NSRegularExpression regularExpressionWithPattern:@"user\\(locn(\\d+)\\)" options:0 error:nil];
        for (NSTextCheckingResult *m in [lre matchesInString:body options:0 range:NSMakeRange(0, body.length)]) {
            int l = [[body substringWithRange:[m rangeAtIndex:1]] intValue];
            if (l < 64) s->locs |= 1ull << l;
        }
    }
    NSArray *ls = j[@"localSize"];
    for (int k = 0; k < 3; k++) s->local[k] = [ls isKindOfClass:[NSArray class]] && ls.count == 3 ? [ls[k] intValue] : 1;
    // MSL texture parameter types of the entry point, by binding
    NSMutableDictionary<NSNumber *, NSString *> *types = [NSMutableDictionary new];
    NSRegularExpression *tre = [NSRegularExpression regularExpressionWithPattern:@"(\\w+)<\\w+(?:, access::\\w+)?> \\w+ \\[\\[texture\\((\\d+)\\)\\]\\]" options:0 error:nil];
    for (NSTextCheckingResult *m in [tre matchesInString:msl options:0 range:NSMakeRange(0, msl.length)])
        types[@([[msl substringWithRange:[m rangeAtIndex:2]] intValue])] = [msl substringWithRange:[m rangeAtIndex:1]];
    s->arr_i = -1;
    int arr_binding = -1;
    if ([msl hasPrefix:@"// nxrt-texarray "]) {
        char offs[256] = "";
        if (sscanf(msl.UTF8String, "// nxrt-texarray %d slots %d stride %d offs %255s", &arr_binding, &s->arr_slots, &s->arr_stride, offs) != 4)
            arr_binding = -1;
        for (char *p = offs; arr_binding >= 0 && s->arr_stride && *p && s->arr_noffs < 16; p++) {
            s->arr_offs[s->arr_noffs++] = (int)strtol(p, &p, 10);
            if (!*p) break;
        }
    }
    for (NSDictionary *t in j[@"textures"]) {
        if (s->ntex == 64) break;
        if ([t[@"binding"] intValue] == arr_binding) s->arr_i = s->ntex;
        int b = [t[@"binding"] intValue];
        s->tex_handle[s->ntex] = [t[@"handle"] intValue];
        s->tex_cbuf[s->ntex] = [t[@"cbufSlot"] intValue];
        s->tex_binding[s->ntex] = b;
        s->tex_type[s->ntex++] = msl_texture_type(types[@(b)] ?: @"texture2d");
    }
    NSRegularExpression *are = [NSRegularExpression regularExpressionWithPattern:@"(\\w+) \\w+ \\[\\[attribute\\((\\d+)\\)\\]\\]" options:0 error:nil];
    for (NSTextCheckingResult *m in [are matchesInString:msl options:0 range:NSMakeRange(0, msl.length)]) {
        if (s->nattr == 32) break;
        NSString *ty = [msl substringWithRange:[m rangeAtIndex:1]];
        s->attr_kind[s->nattr] = [ty hasPrefix:@"uint"] ? 'u' : [ty hasPrefix:@"int"] ? 'i' : 'f';
        s->attr_loc[s->nattr++] = [[msl substringWithRange:[m rangeAtIndex:2]] intValue];
    }
    s->uses_support = [msl rangeOfString:@"[[buffer(0)]]"].location != NSNotFound;
}

// shaders.index: the parsed fields of every shader (NxShader from ncb through locs, plain data), the FNV-1a hash of
// its MSL text (the metallib function name) and flags, made on the Mac by `nxrt --shader-index <shaders> <out>`
// (same code and struct layout as the app: both arm64 clang builds; the block size in the header must match).
enum { SIDX_CUBE_ARRAY = 1 };   // samples a cube array (skipped in the simulator)
typedef struct { char magic[4]; uint32_t version, block, count; } SidxHeader;
typedef struct { char name[24]; uint64_t msl_hash; uint32_t flags, pad; } SidxEntry;   // followed by the block
static size_t shader_block_size(void) {
    static size_t n;
    if (!n) {
        NxShader *t = [NxShader new];
        n = (size_t)((char *)&t->locs + sizeof t->locs - (char *)&t->ncb);
    }
    return n;
}
static NSString *shaders_root(void) {
    return @(getenv("NXRT_SHADERS") ? getenv("NXRT_SHADERS") : "shaders");
}
// A shader's MSL text, read when first needed (variants, a metallib miss): shaders from the index have none loaded.
static NSString *shader_msl(NxShader *s) {
    if (!s->msl && s->name && [s->name rangeOfString:@"-"].location == NSNotFound)
        s->msl = [NSString stringWithContentsOfFile:[NSString stringWithFormat:@"%@/msl/%@.metal", shaders_root(), s->name]
                                           encoding:NSUTF8StringEncoding error:nil];
    return s->msl;
}
static NxShader *shader_from_index(NSString *name, uint64_t *msl_hash_out, uint32_t *flags) {
    static NSData *data;
    static NSDictionary<NSString *, NSNumber *> *where;
    static int tried;
    if (!tried) {
        tried = 1;
        NSString *path = [shaders_root() stringByAppendingPathComponent:@"shaders.index"];
        NSData *d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
        const SidxHeader *h = d.bytes;
        size_t es = sizeof(SidxEntry) + shader_block_size();
        if (d.length >= sizeof *h && !memcmp(h->magic, "NXSI", 4) && h->version == 1 && h->block == shader_block_size() &&
            d.length >= sizeof *h + (size_t)h->count * es) {
            NSMutableDictionary *w = [NSMutableDictionary dictionaryWithCapacity:h->count];
            for (uint32_t i = 0; i < h->count; i++) {
                const SidxEntry *e = (const SidxEntry *)((const char *)d.bytes + sizeof *h + i * es);
                w[[[NSString alloc] initWithBytes:e->name length:strnlen(e->name, sizeof e->name) encoding:NSUTF8StringEncoding]] =
                    @(sizeof *h + i * es);
            }
            data = d, where = w;
        }
        nx_log("gfx: shader index %s: %s", path.UTF8String, where ? [NSString stringWithFormat:@"%lu shaders", (unsigned long)where.count].UTF8String
                                                                     : d ? "wrong format or struct layout, parsing MSL instead" : "none");
    }
    NSNumber *off = where[name];
    if (!off) return nil;
    const SidxEntry *e = (const SidxEntry *)((const char *)data.bytes + off.unsignedLongValue);
    NxShader *s = [NxShader new];
    memcpy(&s->ncb, e + 1, shader_block_size());
    *msl_hash_out = e->msl_hash, *flags = e->flags;
    return s;
}


// Binary archives. <NXRT_SHADERS>/pipelines.metallib holds final GPU binaries of the game's pipelines, built offline
// by metal-tt for the phone's GPU (tools/shadertool/build_pipelines.sh) from descriptors recorded on the Mac with
// NXRT_HARVEST=<file>: a pipeline found there is not compiled at all (cold title screen: ~4 s of pipeline compiles on
// the Mac). Only pipelines whose functions come from the metallib (h_<hash>) are recorded: metal-tt resolves them there.
static id<MTLBinaryArchive> g_pipe_archive, g_harvest;
static uint64_t g_harvested;
// Recording goes into chunks <NXRT_HARVEST>-<k>.metallib of the descriptors added since the last good save: Metal
// refuses to serialize an archive holding certain pipelines ("expecting 'fragment' stage in pipeline no. N"), which
// would lose everything recorded with them; a failing chunk is retried pipeline by pipeline and saved without those.
static NSMutableArray *g_harvest_pending;   // MTLRenderPipelineDescriptor / MTLComputePipelineDescriptor copies
static int g_harvest_chunk, g_harvest_dropped;
static void pipe_archives_init(void) {
    static int done;
    if (done) return;
    done = 1;
    MTLBinaryArchiveDescriptor *ad = [MTLBinaryArchiveDescriptor new];
    // On the phone it sits next to the save (Documents/nxrt, the working directory), not in the app: LiveContainer
    // tries to sign every Mach-O in an app, and this GPU binary is one ("Failed to Sign ... pipelines.metallib").
    NSString *path = getenv("NXRT_PIPEARCHIVE_PATH") ? @(getenv("NXRT_PIPEARCHIVE_PATH"))
                   : [NSFileManager.defaultManager fileExistsAtPath:@"pipelines.metallib"] ? [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:@"pipelines.metallib"]
                   : [shaders_root() stringByAppendingPathComponent:@"pipelines.metallib"];
    if (!(getenv("NXRT_PIPEARCHIVE") && !atoi(getenv("NXRT_PIPEARCHIVE"))) && [NSFileManager.defaultManager fileExistsAtPath:path]) {
        NSError *err = nil;
        ad.url = [NSURL fileURLWithPath:path];
        g_pipe_archive = [g_dev newBinaryArchiveWithDescriptor:ad error:&err];
        nx_log("gfx: pipeline archive %s: %s", path.UTF8String, g_pipe_archive ? "loaded" : err.localizedDescription.UTF8String);
    }
    if (getenv("NXRT_HARVEST")) {
        g_harvest = [g_dev newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:nil];
        g_harvest_pending = [NSMutableArray new];
        nx_log("gfx: recording pipelines into %s-<n>.metallib%s", getenv("NXRT_HARVEST"), g_harvest ? "" : " FAILED");
    }
}
static int archive_add(id<MTLBinaryArchive> a, id d) {
    return [d isKindOfClass:MTLRenderPipelineDescriptor.class] ? [a addRenderPipelineFunctionsWithDescriptor:d error:nil]
                                                                : [a addComputePipelineFunctionsWithDescriptor:d error:nil];
}
static void harvest_save(void) {
    if (!g_harvest || !g_harvest_pending.count) return;
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%s-%d.metallib", getenv("NXRT_HARVEST"), g_harvest_chunk]];
    NSError *err = nil;
    if (![g_harvest serializeToURL:url error:&err]) {
        id<MTLBinaryArchive> keep = [g_dev newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:nil];
        NSURL *tmp = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%s-test.metallib", getenv("NXRT_HARVEST")]];
        for (id d in g_harvest_pending) {
            id<MTLBinaryArchive> one = [g_dev newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:nil];
            if (archive_add(one, d) && [one serializeToURL:tmp error:nil]) archive_add(keep, d);
            else if (g_harvest_dropped++ < 16) {
                MTLRenderPipelineDescriptor *r = [d isKindOfClass:MTLRenderPipelineDescriptor.class] ? d : nil;
                nx_log("gfx: pipeline %s/%s can't be archived, not recorded", r.vertexFunction.name.UTF8String ?: "compute",
                       r.fragmentFunction.name.UTF8String ?: "");
            }
        }
        [NSFileManager.defaultManager removeItemAtURL:tmp error:nil];
        if (![keep serializeToURL:url error:&err]) {
            nx_log("gfx: saving pipeline chunk %d failed: %s", g_harvest_chunk, err.localizedDescription.UTF8String);
            return;
        }
    }
    g_harvest_chunk++;
    [g_harvest_pending removeAllObjects];
    g_harvest = [g_dev newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:nil];
}
static int from_metallib(id<MTLFunction> f) { return !f || [f.name hasPrefix:@"h_"]; }
static void harvest_add(id d) {   // a pipeline descriptor whose functions come from the metallib
    if (!archive_add(g_harvest, d)) return;
    [g_harvest_pending addObject:[d copy]];
    if (++g_harvested % 64 == 0) harvest_save();
}
static void harvest_render(MTLRenderPipelineDescriptor *d) {
    // vertex-only (depth) pipelines: archives can't serialize them ("expecting 'fragment' stage"); they compile fast
    if (g_harvest && d.fragmentFunction && from_metallib(d.vertexFunction) && from_metallib(d.fragmentFunction)) harvest_add(d);
}

// ---- On-device pipeline cache (iOS default; NXRT_PIPECACHE=0 off, =1 on the Mac too: the Mac app sets it) ----
// From the BOTW port (its session 14).
// The phone compiled the same pipelines again in every session (dozens every few seconds outdoors: the stutter, and
// CPU heat). New pipelines whose functions come from the metallib are added, on a utility queue, to a binary archive
// that is written to pipecache/<n>.metallib (the working directory: Documents/nxrt, the Mac's runtime/) with the hashes of their keys in
// <n>.keys; at the next launch every chunk is loaded and handed to pipeline creation, so those pipelines are fetched
// from the archive instead of compiled, and are not recorded again. A chunk is written once, when it holds PC_CHUNK
// pipelines or after PC_SAVE_NS without new ones (a session killed by iOS loses little): Metal fails to serialize an
// archive a second time after more pipelines were added ("expecting 'fragment' stage in pipeline no. N").
enum { PC_CHUNK = 64 };
static const uint64_t PC_SAVE_NS = 20000000000ull;
static int g_pc_on = -1;
static NSArray<id<MTLBinaryArchive>> *g_pc_archives;   // what pipeline creation searches (+ the shipped archive)
static NSMutableSet<NSNumber *> *g_pc_known;           // key hashes already archived or being recorded
static dispatch_queue_t g_pc_queue;
static id<MTLBinaryArchive> g_pc_cur;                  // the chunk being filled (queue only)
static NSMutableArray *g_pc_cur_desc;                  // its descriptors, for a pipeline-by-pipeline retry
static NSMutableData *g_pc_cur_keys;
static int g_pc_chunk, g_pc_unsaved;
static uint64_t g_pc_last_add_ns, g_pc_loaded, g_pc_recorded;
static void pc_init(void) {
    if (g_pc_on >= 0) return;
#if TARGET_OS_IPHONE
    g_pc_on = !(getenv("NXRT_PIPECACHE") && !atoi(getenv("NXRT_PIPECACHE")));
#else
    g_pc_on = getenv("NXRT_PIPECACHE") && atoi(getenv("NXRT_PIPECACHE"));
#endif
    NSMutableArray *arcs = [NSMutableArray new];
    if (g_pipe_archive) [arcs addObject:g_pipe_archive];
    if (g_pc_on) {
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:@"pipecache" withIntermediateDirectories:YES attributes:nil error:nil];
        g_pc_known = [NSMutableSet new];
        for (NSString *f in [fm contentsOfDirectoryAtPath:@"pipecache" error:nil]) {
            if (![f hasSuffix:@".metallib"]) continue;
            int n = f.intValue;
            if (![f isEqualToString:[NSString stringWithFormat:@"%d.metallib", n]]) {   // a leftover temporary
                [fm removeItemAtPath:[@"pipecache" stringByAppendingPathComponent:f] error:nil];
                continue;
            }
            NSString *base = [@"pipecache" stringByAppendingPathComponent:@(n).stringValue];
            NSData *keys = [NSData dataWithContentsOfFile:[base stringByAppendingString:@".keys"]];
            MTLBinaryArchiveDescriptor *ad = [MTLBinaryArchiveDescriptor new];
            ad.url = [NSURL fileURLWithPath:[base stringByAppendingString:@".metallib"]];
            NSError *err = nil;
            id<MTLBinaryArchive> a = keys ? [g_dev newBinaryArchiveWithDescriptor:ad error:&err] : nil;
            if (!a) {   // unreadable (OS update changed the GPU compiler, a half-written chunk): drop it
                nx_log("gfx: pipeline cache chunk %d dropped: %s", n, keys ? err.localizedDescription.UTF8String : "no keys");
                [fm removeItemAtPath:[base stringByAppendingString:@".metallib"] error:nil];
                [fm removeItemAtPath:[base stringByAppendingString:@".keys"] error:nil];
                continue;
            }
            [arcs addObject:a];
            const uint64_t *k = keys.bytes;
            for (size_t i = 0; i < keys.length / 8; i++) [g_pc_known addObject:@(k[i])];
            g_pc_loaded += keys.length / 8;
            if (n >= g_pc_chunk) g_pc_chunk = n + 1;
        }
        g_pc_queue = dispatch_queue_create("nxrt.pipecache", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        nx_log("gfx: pipeline cache: %llu pipelines in %d chunks loaded, recording new ones into pipecache/%d.metallib",
               (unsigned long long)g_pc_loaded, (int)arcs.count - (g_pipe_archive != nil), g_pc_chunk);
    }
    g_pc_archives = arcs;
}
static void pc_save(void) {   // queue: write the current chunk (whole) and its keys
    if (!g_pc_cur || !g_pc_unsaved) return;
    NSString *base = [@"pipecache" stringByAppendingPathComponent:@(g_pc_chunk).stringValue];
    NSURL *url = [NSURL fileURLWithPath:[base stringByAppendingString:@".tmp"]];
    NSError *err = nil;
    if (![g_pc_cur serializeToURL:url error:&err]) {
        // Metal refuses to serialize some pipelines ("expecting 'fragment' stage ..."): keep the ones that work alone
        id<MTLBinaryArchive> keep = [g_dev newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:nil];
        NSMutableArray *kd = [NSMutableArray new];
        NSMutableData *kk = [NSMutableData new];
        NSURL *tmp = [NSURL fileURLWithPath:[base stringByAppendingString:@".one"]];
        for (NSUInteger i = 0; i < g_pc_cur_desc.count; i++) {
            id d = g_pc_cur_desc[i];
            id<MTLBinaryArchive> one = [g_dev newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:nil];
            if (archive_add(one, d) && [one serializeToURL:tmp error:nil] && archive_add(keep, d))
                [kd addObject:d], [kk appendBytes:(const uint64_t *)g_pc_cur_keys.bytes + i length:8];
        }
        [NSFileManager.defaultManager removeItemAtURL:tmp error:nil];
        nx_log("gfx: pipeline cache: chunk %d kept %lu of %lu pipelines (%s)", g_pc_chunk, (unsigned long)kd.count,
               (unsigned long)g_pc_cur_desc.count, err.localizedDescription.UTF8String);
        g_pc_cur = keep, g_pc_cur_desc = kd, g_pc_cur_keys = kk;
        if (![g_pc_cur serializeToURL:url error:&err]) {
            nx_log("gfx: pipeline cache: saving chunk %d failed: %s", g_pc_chunk, err.localizedDescription.UTF8String);
            return;
        }
    }
    // keys after the archive, each by rename: a chunk without keys is dropped at load, never trusted half-written
    [NSFileManager.defaultManager removeItemAtPath:[base stringByAppendingString:@".metallib"] error:nil];
    rename(url.path.fileSystemRepresentation, [base stringByAppendingString:@".metallib"].fileSystemRepresentation);
    [g_pc_cur_keys writeToFile:[base stringByAppendingString:@".keys"] atomically:YES];
    g_pc_unsaved = 0;
    g_pc_cur = nil, g_pc_chunk++;
}
// A pipeline about to be created: search the cache, and record it if it is new. kh: hash of its key (stable across runs).
static void pc_prepare(id d, uint64_t kh) {
    pc_init();
    if (g_pc_archives.count) [d setBinaryArchives:g_pc_archives];
    if (!g_pc_on) return;
    NSNumber *k = @(kh);
    if ([g_pc_known containsObject:k]) return;
    [g_pc_known addObject:k];
    id copy = [d copy];
    [copy setBinaryArchives:nil];
    dispatch_async(g_pc_queue, ^{
        if (!g_pc_cur) {
            g_pc_cur = [g_dev newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:nil];
            g_pc_cur_desc = [NSMutableArray new], g_pc_cur_keys = [NSMutableData new];
        }
        if (!archive_add(g_pc_cur, copy)) return;
        [g_pc_cur_desc addObject:copy];
        [g_pc_cur_keys appendBytes:&kh length:8];
        g_pc_recorded++;
        g_pc_last_add_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        g_pc_unsaved++;
        if (g_pc_cur_desc.count >= PC_CHUNK) pc_save();
    });
}
static void pc_tick(void) {   // once per submit: save a chunk that got quiet
    if (g_pc_on <= 0 || !g_pc_unsaved) return;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now - __atomic_load_n(&g_pc_last_add_ns, __ATOMIC_RELAXED) > PC_SAVE_NS) {
        __atomic_store_n(&g_pc_last_add_ns, now, __ATOMIC_RELAXED);
        dispatch_async(g_pc_queue, ^{ pc_save(); });
    }
}

static uint64_t g_index_hits;
static NxShader *shader_load(uint64_t hash, const char *kind) {
    NSString *name = [NSString stringWithFormat:@"%016llx.%s", (unsigned long long)hash, kind];
    id hit = g_shaders[name];
    if (hit) return hit == [NSNull null] ? nil : hit;
    // NXRT_FSDEBUG=<fs hash>: that fragment shader outputs solid magenta and never discards (shows
    // where its draws land).
    char hx[20];
    snprintf(hx, sizeof hx, "%016llx", (unsigned long long)hash);
    int dbg = getenv("NXRT_FSDEBUG") && kind[0] == 'f' && strstr(getenv("NXRT_FSDEBUG"), hx);   // one hash or a list
    uint64_t mh = 0;
    uint32_t flags = 0;
    NSString *msl = nil;
    NxShader *s = dbg ? nil : shader_from_index(name, &mh, &flags);
    if (s) g_index_hits++;
    else if (!dbg) {
        static int n;
        if (n++ < 10) nx_log("gfx: shader %s not in the shader index", name.UTF8String);
    }
    if (s && getenv("NXRT_SIDX_VERIFY")) {   // the index must equal parsing the MSL here
        NSData *json = [NSData dataWithContentsOfFile:[NSString stringWithFormat:@"%@/spv/%@.json", shaders_root(), name]];
        s->name = name;
        NSString *t = shader_msl(s);
        NxShader *p = [NxShader new];
        if (t && json) shader_parse(p, t, json, kind);
        int same = t && json && !memcmp(&p->ncb, &s->ncb, shader_block_size()) && msl_hash(t) == mh;
        static int bad, good;
        if (!same) nx_log("gfx: shader index MISMATCH for %s", name.UTF8String), bad++;
        else if (++good % 100 == 0) nx_log("gfx: shader index verified %d shaders, %d mismatches", good, bad);
        s->msl = nil;
    }
    if (!s) {   // not in the index (or NXRT_FSDEBUG): parse the MSL
        NSString *root = shaders_root();
        NSString *mpath = [NSString stringWithFormat:@"%@/msl/%@.metal", root, name], *jpath = [NSString stringWithFormat:@"%@/spv/%@.json", root, name];
        int nx_xlat_wait(const char *name);
        if (![NSFileManager.defaultManager fileExistsAtPath:mpath]) nx_xlat_wait(name.UTF8String);   // still being translated (shader_xlat.m)
        msl = [NSString stringWithContentsOfFile:mpath encoding:NSUTF8StringEncoding error:nil];
        NSData *json = [NSData dataWithContentsOfFile:jpath];
        if (!msl || !json) {
            static int n;
            if (n++ < 32) nx_log("gfx: no translation for shader %s", name.UTF8String);
            g_shaders[name] = [NSNull null];
            return nil;
        }
        if (dbg) {   // NXRT_FSDEBUG (above): patch the FS to magenta
            NSRegularExpression *cre = [NSRegularExpression regularExpressionWithPattern:@"float4 (\\w+) \\[\\[color\\(0\\)\\]\\]" options:0 error:nil];
            NSTextCheckingResult *cm = [cre firstMatchInString:msl options:0 range:NSMakeRange(0, msl.length)];
            if (cm) {
                NSString *mem = [msl substringWithRange:[cm rangeAtIndex:1]];
                NSMutableString *m = [msl mutableCopy];
                [m replaceOccurrencesOfString:@"discard_fragment();" withString:@";" options:0 range:NSMakeRange(0, m.length)];
                // in.nx_fc: the fragment position (for NXRT_FSDEBUG_EXPR, e.g. depth as colour)
                [m replaceOccurrencesOfString:@"struct main0_in\n{\n" withString:@"struct main0_in\n{\n    float4 nx_fc [[position]];\n"
                                      options:0 range:NSMakeRange(0, m.length)];
                const char *ex = getenv("NXRT_FSDEBUG_EXPR");   // e.g. "float4(_45, 0.0, 0.0, 1.0)" (names from the .metal)
                [m replaceOccurrencesOfString:@"return out;" withString:[NSString stringWithFormat:@"out.%@ = %s; return out;", mem, ex ? ex : "float4(1.0, 0.0, 1.0, 1.0)"]
                                      options:0 range:NSMakeRange(0, m.length)];
                msl = m;
                nx_log("gfx: NXRT_FSDEBUG: %s patched to magenta", name.UTF8String);
            }
        }
        s = [NxShader new];
        shader_parse(s, msl, json, kind);
        mh = msl_hash(msl);
        flags = [msl rangeOfString:@"cube_array<"].location != NSNotFound ? SIDX_CUBE_ARRAY : 0;
    }
    // Hand-written replacements (<dir>/<name>.metal, e.g. a better AA): same bindings as the translated shader, so its
    // parsed block stays; only the function's source changes (compiled at run time). NXRT_HDSHADERS=<dir> (default 0 =
    // off); NXRT_HDSKIP=<hash list> leaves those shaders original (A/B).
    const char *hd = getenv("NXRT_HDSHADERS") ? getenv("NXRT_HDSHADERS") : "0";
    if (!dbg && strcmp(hd, "0") && !(getenv("NXRT_HDSKIP") && strstr(getenv("NXRT_HDSKIP"), hx))) {
        NSString *r = [NSString stringWithContentsOfFile:[NSString stringWithFormat:@"%s/%@.metal", hd, name] encoding:NSUTF8StringEncoding error:nil];
        if (r) {
            msl = r, mh = msl_hash(r);
            nx_log("gfx: shader %s replaced from %s", name.UTF8String, hd);
        }
    }
#if TARGET_OS_SIMULATOR
    if (flags & SIDX_CUBE_ARRAY) {   // no cube arrays on the simulator GPU
        nx_log("gfx: simulator: shader %s samples a cube array, its draws are skipped", name.UTF8String);
        g_shaders[name] = [NSNull null];
        return nil;
    }
#endif
    s->msl = msl, s->name = name;
    // Function from the metallib, else compiled asynchronously: compiling MSL takes tens of ms per shader, and doing
    // it inside the game's submit stalled frames for minutes once thousands of draws were enabled. Draws using the
    // shader wait for it (wait_compiled; the completion only touches this object).
    msl_function_h(mh, ^{ return shader_msl(s); }, ^(id<MTLFunction> fn, NSError *err) {
        if (!fn) nx_log("gfx: shader %s does not compile: %s", name.UTF8String, err.localizedDescription.UTF8String);
        s->fn = fn;
        __atomic_store_n(&s->ready, fn ? 1 : -1, __ATOMIC_RELEASE);
    });
    g_shaders[name] = s;
    return s;
}

// nxrt --shader-index <shaders dir> <out>: parse every translated shader (msl/*.metal + spv/*.json) into shaders.index.
int gfx_build_shader_index(const char *dir, const char *out) {
    setenv("NXRT_SHADERS", dir, 1);
    NSString *root = shaders_root();
    NSArray<NSString *> *files = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:[root stringByAppendingPathComponent:@"msl"] error:nil]
        sortedArrayUsingSelector:@selector(compare:)];
    NSMutableData *body = [NSMutableData data];
    uint32_t count = 0;
    for (NSString *f in files) {
        if (![f hasSuffix:@".metal"]) continue;
        NSString *name = f.stringByDeletingPathExtension;
        NSString *kind = name.pathExtension;
        NSString *msl = [NSString stringWithContentsOfFile:[NSString stringWithFormat:@"%@/msl/%@", root, f] encoding:NSUTF8StringEncoding error:nil];
        NSData *json = [NSData dataWithContentsOfFile:[NSString stringWithFormat:@"%@/spv/%@.json", root, name]];
        if (!msl || !json || name.length >= 24) continue;
        NxShader *s = [NxShader new];
        shader_parse(s, msl, json, kind.UTF8String);
        SidxEntry e;
        memset(&e, 0, sizeof e);
        memcpy(e.name, name.UTF8String, name.length);
        e.msl_hash = msl_hash(msl);
        e.flags = [msl rangeOfString:@"cube_array<"].location != NSNotFound ? SIDX_CUBE_ARRAY : 0;
        [body appendBytes:&e length:sizeof e];
        [body appendBytes:&s->ncb length:shader_block_size()];
        count++;
    }
    SidxHeader h = {{'N', 'X', 'S', 'I'}, 1, (uint32_t)shader_block_size(), count};
    NSMutableData *d = [NSMutableData dataWithBytes:&h length:sizeof h];
    [d appendData:body];
    if (![d writeToFile:@(out) atomically:YES]) return 1;
    printf("%s: %u shaders, %zu-byte blocks, %.1f MB\n", out, count, shader_block_size(), d.length / 1e6);
    return 0;
}

// ---- enum translation (NVN values as recalled from the public headers; NXRT_GFXDBG prints
// histograms of what the game uses) ----
static MTLBlendFactor blend_factor(int f) {
    switch (f) {
    case 1: return MTLBlendFactorZero;
    case 2: return MTLBlendFactorOne;
    case 3: return MTLBlendFactorSourceColor;
    case 4: return MTLBlendFactorOneMinusSourceColor;
    case 5: return MTLBlendFactorSourceAlpha;
    case 6: return MTLBlendFactorOneMinusSourceAlpha;
    case 7: return MTLBlendFactorDestinationAlpha;
    case 8: return MTLBlendFactorOneMinusDestinationAlpha;
    case 9: return MTLBlendFactorDestinationColor;
    case 10: return MTLBlendFactorOneMinusDestinationColor;
    case 11: return MTLBlendFactorSourceAlphaSaturated;
    case 16: return MTLBlendFactorSource1Color;
    case 17: return MTLBlendFactorOneMinusSource1Color;
    case 18: return MTLBlendFactorSource1Alpha;
    case 19: return MTLBlendFactorOneMinusSource1Alpha;
    case 97: return MTLBlendFactorBlendColor;
    case 98: return MTLBlendFactorOneMinusBlendColor;
    case 99: return MTLBlendFactorBlendAlpha;
    case 100: return MTLBlendFactorOneMinusBlendAlpha;
    default: return MTLBlendFactorOne;
    }
}
static MTLBlendOperation blend_op(int e) {
    switch (e) {
    case 2: return MTLBlendOperationSubtract;
    case 3: return MTLBlendOperationReverseSubtract;
    case 4: return MTLBlendOperationMin;
    case 5: return MTLBlendOperationMax;
    default: return MTLBlendOperationAdd;
    }
}
static MTLCompareFunction compare(int f) {
    switch (f) {
    case 1: return MTLCompareFunctionNever;
    case 2: return MTLCompareFunctionLess;
    case 3: return MTLCompareFunctionEqual;
    case 4: return MTLCompareFunctionLessEqual;
    case 5: return MTLCompareFunctionGreater;
    case 6: return MTLCompareFunctionNotEqual;
    case 7: return MTLCompareFunctionGreaterEqual;
    default: return MTLCompareFunctionAlways;
    }
}
static MTLStencilOperation stencil_op(int o) {
    switch (o) {
    case 2: return MTLStencilOperationZero;
    case 3: return MTLStencilOperationReplace;
    case 4: return MTLStencilOperationIncrementClamp;
    case 5: return MTLStencilOperationDecrementClamp;
    case 6: return MTLStencilOperationInvert;
    case 7: return MTLStencilOperationIncrementWrap;
    case 8: return MTLStencilOperationDecrementWrap;
    default: return MTLStencilOperationKeep;
    }
}
// Vertex formats: the NVN texture formats, read as float (normalized or converted).
static MTLVertexFormat vertex_format(int f) {
    switch (f) {
    case 1: return MTLVertexFormatUCharNormalized;   case 2: return MTLVertexFormatCharNormalized;
    case 3: return MTLVertexFormatUChar;             case 4: return MTLVertexFormatChar;
    case 5: return MTLVertexFormatHalf;              case 6: return MTLVertexFormatUShortNormalized;
    case 7: return MTLVertexFormatShortNormalized;   case 8: return MTLVertexFormatUShort;
    case 9: return MTLVertexFormatShort;             case 10: return MTLVertexFormatFloat;
    case 11: return MTLVertexFormatUInt;             case 12: return MTLVertexFormatInt;
    case 13: return MTLVertexFormatUChar2Normalized; case 14: return MTLVertexFormatChar2Normalized;
    case 15: return MTLVertexFormatUChar2;           case 16: return MTLVertexFormatChar2;
    case 17: return MTLVertexFormatHalf2;            case 18: return MTLVertexFormatUShort2Normalized;
    case 19: return MTLVertexFormatShort2Normalized; case 20: return MTLVertexFormatUShort2;
    case 21: return MTLVertexFormatShort2;           case 22: return MTLVertexFormatFloat2;
    case 23: return MTLVertexFormatUInt2;            case 24: return MTLVertexFormatInt2;
    case 25: return MTLVertexFormatUChar3Normalized; case 26: return MTLVertexFormatChar3Normalized;
    case 27: return MTLVertexFormatUChar3;           case 28: return MTLVertexFormatChar3;
    case 29: return MTLVertexFormatHalf3;            case 30: return MTLVertexFormatUShort3Normalized;
    case 31: return MTLVertexFormatShort3Normalized; case 32: return MTLVertexFormatUShort3;
    case 33: return MTLVertexFormatShort3;           case 34: return MTLVertexFormatFloat3;
    case 35: return MTLVertexFormatUInt3;            case 36: return MTLVertexFormatInt3;
    case 37: return MTLVertexFormatUChar4Normalized; case 38: return MTLVertexFormatChar4Normalized;
    case 39: return MTLVertexFormatUChar4;           case 40: return MTLVertexFormatChar4;
    case 41: return MTLVertexFormatHalf4;            case 42: return MTLVertexFormatUShort4Normalized;
    case 43: return MTLVertexFormatShort4Normalized; case 44: return MTLVertexFormatUShort4;
    case 45: return MTLVertexFormatShort4;           case 46: return MTLVertexFormatFloat4;
    case 47: return MTLVertexFormatUInt4;            case 48: return MTLVertexFormatInt4;
    case 61: return MTLVertexFormatUInt1010102Normalized;
    case 105: return MTLVertexFormatInt1010102Normalized;   // RGB10A2SN: normals/tangents (checked: unit vectors, w = ±1)
    // MTLVertexFormatFloatRG11B10 (54): macOS 14 / iOS 17; the iOS build's SDK (16.5) lacks the name
    case 63: if (@available(macOS 14.0, iOS 17.0, *)) return (MTLVertexFormat)54; return MTLVertexFormatInvalid;
    default: return MTLVertexFormatInvalid;
    }
}

// Sampler cache: open addressing over the raw state bytes (an NSData-keyed dictionary cost ~9% of encode).
enum { SMP_CACHE = 4096 };
static NxSamplerState g_smp_keys[SMP_CACHE];
static __strong id<MTLSamplerState> g_smp_vals[SMP_CACHE];
// Returns a raw pointer (the table or its overflow list owns every sampler): callers keep it unretained, and the id
// return's ARC handshake ran per texture per draw.
#define sampler_for(s) ((__bridge id<MTLSamplerState>)sampler_for_raw(s))
static void *sampler_for_raw(const NxSamplerState *s) {
    // Hashed per 64-bit word (the byte-wise FNV over 64 bytes ran per texture per draw: ~4% of encode).
    _Static_assert(sizeof *s % 8 == 0, "sampler state is whole words");
    uint64_t hsh = 0, w;
    for (size_t i = 0; i < sizeof *s; i += 8) memcpy(&w, (const uint8_t *)s + i, 8), hsh = (hsh ^ w) * 0x9E3779B97F4A7C15ull, hsh ^= hsh >> 29;
    size_t slot = hsh & (SMP_CACHE - 1);
    for (int probe = 0; probe < SMP_CACHE && g_smp_vals[slot]; probe++, slot = (slot + 1) & (SMP_CACHE - 1))
        if (!memcmp(&g_smp_keys[slot], s, sizeof *s)) return (__bridge void *)g_smp_vals[slot];
    id<MTLSamplerState> hit;
    MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
    // min: NEAREST, LINEAR, NEAREST_MIPMAP_NEAREST, LINEAR_MIPMAP_NEAREST, NEAREST_MIPMAP_LINEAR, LINEAR_MIPMAP_LINEAR
    d.minFilter = s->min == 1 || s->min == 3 || s->min == 5 ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    d.mipFilter = s->min == 2 || s->min == 3 ? MTLSamplerMipFilterNearest : s->min >= 4 ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNotMipmapped;
    d.magFilter = s->mag == 1 ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    // wrap: CLAMP, REPEAT, MIRROR_CLAMP, MIRROR_CLAMP_TO_EDGE, MIRROR_CLAMP_TO_BORDER, CLAMP_TO_BORDER, MIRRORED_REPEAT, CLAMP_TO_EDGE
    MTLSamplerAddressMode (^wrap)(int) = ^MTLSamplerAddressMode(int w) {
        switch (w) {
        case 1: return MTLSamplerAddressModeRepeat;
        case 2: case 3: case 4: return MTLSamplerAddressModeMirrorClampToEdge;
        case 5: return MTLSamplerAddressModeClampToBorderColor;
        case 6: return MTLSamplerAddressModeMirrorRepeat;
        default: return MTLSamplerAddressModeClampToEdge;
        }
    };
    d.sAddressMode = wrap(s->wrap_s);
    d.tAddressMode = wrap(s->wrap_t);
    d.rAddressMode = wrap(s->wrap_r);
    d.maxAnisotropy = s->aniso >= 2 ? (NSUInteger)MIN(s->aniso, 16.0f) : 1;
    d.lodMinClamp = MAX(s->lod_min, 0.0f);
    d.lodMaxClamp = MAX(s->lod_max, d.lodMinClamp);
    if (s->cmp_mode) d.compareFunction = compare(s->cmp_func);
    d.borderColor = s->border[3] > 0.5f ? (s->border[0] > 0.5f ? MTLSamplerBorderColorOpaqueWhite : MTLSamplerBorderColorOpaqueBlack)
                                        : MTLSamplerBorderColorTransparentBlack;
    if (ENV("NXRT_SMPLOG"))   // each distinct sampler state once (what Metal can't express: lod_bias, reduction)
        nx_log("smplog: min %d mag %d wrap %d/%d/%d cmp %d/%d reduction %d lod %.2f..%.2f bias %.2f aniso %.1f", s->min, s->mag,
               s->wrap_s, s->wrap_t, s->wrap_r, s->cmp_mode, s->cmp_func, s->reduction, s->lod_min, s->lod_max, s->lod_bias, s->aniso);
    hit = [g_dev newSamplerStateWithDescriptor:d];
    if (!g_smp_vals[slot]) g_smp_keys[slot] = *s, g_smp_vals[slot] = hit;   // (a full table just stops caching)
    else {   // callers keep samplers unretained (bind_stage): one the table can't hold is kept here for good
        static NSMutableArray *overflow;
        if (!overflow) overflow = [NSMutableArray new];
        if (hit) [overflow addObject:hit];
    }
    return (__bridge void *)hit;
}

// ---- execution state (persists across submits, like the GPU's) ------------------------
static struct {
    OpRT rt;
    OpProgram prog;
    OpBuf ubo[6][16], ssbo[6][16], vb[32];
    uint64_t tex[6][64];
    const uint64_t *tex_def[6][64];
    OpVAttr attr;
    OpVStream stream;
    NvBlend blend[8];
    NvColor color;
    NvChMask chmask;
    NvDS ds;
    NvPoly poly;
    NvMS ms;
    float blend_color[4], depth_near, depth_far, poly_offset[3];
    OpRect viewport, scissor;
    int has_viewport, has_scissor, depth_clamp, discard;
    OpRenderEnable render_enable;
    const void *vb_blob[32];   // diagnostics: the executed list that last bound each stream
    uint64_t vb_draw[32];      // and the draw count then
    int32_t stencil_ref[2], stencil_mask[2], stencil_vmask[2];
} S;
static int S_init;
static const Blob *g_exec_blob;   // the list being executed, and draws executed so far (diagnostics)
static uint64_t g_exec_draws;

static id<MTLCommandBuffer> E_cmd;
static id<MTLRenderCommandEncoder> E;
static int E_w, E_h, E_samples;
static MTLPixelFormat E_color[8], E_depth, E_stencil;
// The open pass's depth buffer is 24-bit on the Switch (NVN DEPTH24 / DEPTH24_STENCIL8) but D32F here. Depth-EQUAL
// redraws of nearly coplanar meshes (a Mii's face mask over its head) pass on 24-bit hardware, where both round to
// the same value, and fail in float; NXRT_EQ24=1 turns those tests into LESS_EQUAL with a bias of about one
// 24-bit step toward the camera (NXRT_EQ24_BIAS=<units>). Off by default: it lets the mask pass, but a coplanar
// mesh drawn after it then covers it too (session 14), so the eyes are still missing.
static int E_depth24;
static int eq24_on(void) {
    static int on = -1;
    if (on < 0) on = getenv("NXRT_EQ24") && atoi(getenv("NXRT_EQ24")) != 0;
    return on;
}
static int pend_clear_color_mask;
static float pend_clear_color[8][4];
static int pend_clear_depth, pend_clear_stencil;
static float pend_depth;
static int pend_stencil;
static id<MTLCommandBuffer> g_last_commit;
static NSMutableData *g_completion_writes;    // OpSignal / OpCounter for the command buffer being built
static uint64_t g_stats_reoff;   // draws dropped by SetRenderEnable(Conditional)
static uint64_t g_stats_draws, g_stats_skipped, g_stats_pending, g_draws_at_submit;   // pending: shader/pipeline still compiling
static uint64_t g_completed_seq;
typedef struct { uint64_t seq, draws, t; } CmdRec;
static CmdRec g_ring[16];
static uint64_t g_ring_n;

static void exec_init(void) {
    if (S_init) return;
    S_init = 1;
    for (int i = 0; i < 8; i++) blend_defaults(&S.blend[i]), S.blend[i].target = i;
    color_defaults(&S.color);
    chmask_defaults(&S.chmask);
    ds_defaults(&S.ds);
    poly_defaults(&S.poly);
    ms_defaults(&S.ms);
    S.depth_far = 1;
    S.render_enable.mode = 1;
    S.stencil_mask[0] = S.stencil_mask[1] = S.stencil_vmask[0] = S.stencil_vmask[1] = 0xFF;
    g_shaders = [NSMutableDictionary new];
}

static int g_in_submit;           // queue_submit is encoding (E_cmd may be committed in chunks)
// Render-pass cost stats: on Apple GPUs each pass loads its attachments into tile memory and stores them.
static uint64_t g_pass_n, g_pass_empty, g_pass_load_bytes, g_pass_store_bytes, g_pass_draws_at_begin;
// NXRT_PASSLOG frame: root Metal textures sampled by the open pass (dependency analysis)
static const void *g_pass_smp[512];
static int g_pass_nsmp, g_passlog_on;
static uint64_t g_pass_last_fs;   // NXRT_PASSLOG: the pass's last fragment shader
static __strong id<MTLTexture> g_pass_c0;   // the open pass's color attachment 0 (fxaa_after)
static int g_pass_c0_lv, g_pass_c0_ly;
static long g_pass_key;   // w*100000 + h*10 + color 0 loaded (pass histogram, GFXDBG)
// NXRT_GPUPROF=1: GPU time per render pass (timestamps at the pass's start and end, Metal counter
// sample buffers), grouped by target size/format and the first fragment shader drawn in it.
enum { PROF_SAMPLES = 4096 };
typedef struct { uint32_t w, h, fmt; uint64_t fs; } ProfKey;
static int g_prof = -1;
static id<MTLCounterSet> g_prof_set;
static NSMutableArray<id<MTLCounterSampleBuffer>> *g_prof_pool;
static id<MTLCounterSampleBuffer> g_prof_sb;   // for E_cmd
static int g_prof_n;                           // samples used in g_prof_sb (2 per pass)
static ProfKey g_prof_keys[PROF_SAMPLES / 2];
static int g_prof_pass = -1;                   // the open pass's index in g_prof_keys, -1 if not sampled
static NSMutableDictionary<NSString *, NSNumber *> *g_prof_ns, *g_prof_cnt;   // key -> GPU ticks, passes
static pthread_mutex_t g_prof_lock = PTHREAD_MUTEX_INITIALIZER;
static int64_t g_prof_off;   // CPU (mach ticks) - GPU timestamp, both 24 MHz on Apple silicon
static int prof_on(void) {
    if (g_prof < 0) {
        g_prof = getenv("NXRT_GPUPROF") != NULL;
        if (g_prof) {
            for (id<MTLCounterSet> c in g_dev.counterSets)
                if ([c.name isEqualToString:MTLCommonCounterSetTimestamp]) g_prof_set = c;
            if (!g_prof_set || ![g_dev supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) g_prof = 0;
            g_prof_pool = [NSMutableArray new], g_prof_ns = [NSMutableDictionary new], g_prof_cnt = [NSMutableDictionary new];
            MTLTimestamp c, g;
            [g_dev sampleTimestamps:&c gpuTimestamp:&g];
            g_prof_off = (int64_t)c - (int64_t)g;
        }
    }
    return g_prof;
}
// Reserves 2 samples in this command buffer's sample buffer; -1 if profiling is off or it is full.
static int prof_reserve(ProfKey key) {
    if (!prof_on()) return -1;
    if (!g_prof_sb) {
        pthread_mutex_lock(&g_prof_lock);
        g_prof_sb = g_prof_pool.lastObject;
        if (g_prof_sb) [g_prof_pool removeLastObject];
        pthread_mutex_unlock(&g_prof_lock);
        if (!g_prof_sb) {
            MTLCounterSampleBufferDescriptor *d = [MTLCounterSampleBufferDescriptor new];
            d.counterSet = g_prof_set;
            d.sampleCount = PROF_SAMPLES;
            d.storageMode = MTLStorageModeShared;
            g_prof_sb = [g_dev newCounterSampleBufferWithDescriptor:d error:nil];
            if (!g_prof_sb) return -1;
        }
        g_prof_n = 0;
    }
    if (g_prof_n + 2 > PROF_SAMPLES) return -1;
    g_prof_keys[g_prof_n / 2] = key;
    g_prof_n += 2;
    return g_prof_n - 2;
}
// Called when a pass descriptor is ready: attach start/end samples if there is room.
static void prof_pass(MTLRenderPassDescriptor *rp, int w, int h, MTLPixelFormat fmt) {
    g_prof_pass = -1;
    int i = prof_reserve((ProfKey){(uint32_t)w, (uint32_t)h, (uint32_t)fmt, 0});
    if (i < 0) return;
    rp.sampleBufferAttachments[0].sampleBuffer = g_prof_sb;
    rp.sampleBufferAttachments[0].startOfVertexSampleIndex = i;
    rp.sampleBufferAttachments[0].endOfVertexSampleIndex = MTLCounterDontSample;
    rp.sampleBufferAttachments[0].startOfFragmentSampleIndex = MTLCounterDontSample;
    rp.sampleBufferAttachments[0].endOfFragmentSampleIndex = i + 1;
    g_prof_pass = i / 2;
}
// Blit and compute encoders, timestamped under NXRT_GPUPROF (key: size 0x0, fmt = kind: 1 feedback copy,
// 2 texture copy, 3 compute with its shader hash, 4 render-target dump).
static id<MTLBlitCommandEncoder> prof_blit(uint32_t kind) {
    int i = prof_reserve((ProfKey){0, 0, kind, 0});
    if (i < 0) return [E_cmd blitCommandEncoder];
    MTLBlitPassDescriptor *d = [MTLBlitPassDescriptor blitPassDescriptor];
    d.sampleBufferAttachments[0].sampleBuffer = g_prof_sb;
    d.sampleBufferAttachments[0].startOfEncoderSampleIndex = i;
    d.sampleBufferAttachments[0].endOfEncoderSampleIndex = i + 1;
    return [E_cmd blitCommandEncoderWithDescriptor:d];
}
static id<MTLComputeCommandEncoder> prof_compute(uint64_t hash) {
    int i = prof_reserve((ProfKey){0, 0, 3, hash});
    if (i < 0) return [E_cmd computeCommandEncoder];
    MTLComputePassDescriptor *d = [MTLComputePassDescriptor computePassDescriptor];
    d.sampleBufferAttachments[0].sampleBuffer = g_prof_sb;
    d.sampleBufferAttachments[0].startOfEncoderSampleIndex = i;
    d.sampleBufferAttachments[0].endOfEncoderSampleIndex = i + 1;
    return [E_cmd computeCommandEncoderWithDescriptor:d];
}
// At commit: resolve this command buffer's samples when it completes.
static void prof_commit(id<MTLCommandBuffer> cb) {
    if (!g_prof_sb) return;
    id<MTLCounterSampleBuffer> sb = g_prof_sb;
    int n = g_prof_n;
    NSData *keys = [NSData dataWithBytes:g_prof_keys length:(size_t)(n / 2) * sizeof(ProfKey)];
    g_prof_sb = nil, g_prof_n = 0, g_prof_pass = -1;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
        NSData *d = n ? [sb resolveCounterRange:NSMakeRange(0, n)] : nil;
        const MTLCounterResultTimestamp *ts = d.bytes;
        const ProfKey *k = keys.bytes;
        // Samples of passes without vertex/fragment work are never written (stale values from an earlier
        // use of the buffer): keep only timestamps inside this command buffer's GPU time. On Apple silicon
        // the counter timestamps are nanoseconds of host time (the clock of GPUStartTime).
        uint64_t lo = (uint64_t)(c.GPUStartTime * 1e9), hi = (uint64_t)(c.GPUEndTime * 1e9);
        lo = lo > 100000 ? lo - 100000 : 0, hi += 100000;   // 100 us slack
        // Passes overlap on the GPU (a pass's vertex work starts while earlier passes finish), so a pass's
        // cost is its end minus the previous pass's end: the marginal time it adds. These sum to the
        // command buffer's GPU time.
        uint64_t prev_end = lo + 100000;
        pthread_mutex_lock(&g_prof_lock);
        for (int i = 0; ts && i < n / 2; i++) {
            uint64_t a = ts[2 * i].timestamp, b = ts[2 * i + 1].timestamp;
            if (a == MTLCounterErrorValue || b == MTLCounterErrorValue || b < a || a < lo || b > hi) {
                g_prof_cnt[@"(unmeasured passes)"] = @(g_prof_cnt[@"(unmeasured passes)"].unsignedLongLongValue + 1);
                continue;
            }
            NSString *key = [NSString stringWithFormat:@"%4ux%-4u fmt %3u fs %016llx", k[i].w, k[i].h, k[i].fmt, (unsigned long long)k[i].fs];
            uint64_t cost = b > prev_end ? b - prev_end : 0;
            if (b > prev_end) prev_end = b;
            g_prof_ns[key] = @(g_prof_ns[key].unsignedLongLongValue + cost);
            g_prof_cnt[key] = @(g_prof_cnt[key].unsignedLongLongValue + 1);
        }
        [g_prof_pool addObject:sb];
        pthread_mutex_unlock(&g_prof_lock);
    }];
}
static void prof_dump(int frames) {
    if (!prof_on()) return;
    double ns_per_tick = 1.0;   // timestamps are nanoseconds (see prof_commit)
    pthread_mutex_lock(&g_prof_lock);
    NSArray *sorted = [g_prof_ns keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
    double total = 0;
    for (NSString *key in g_prof_ns) total += g_prof_ns[key].doubleValue;
    nx_log("gpuprof: %.1f passes/frame not measurable (no vertex/fragment work)", g_prof_cnt[@"(unmeasured passes)"].doubleValue / frames);
    nx_log("gpuprof: %.1f ms/frame in %lu kinds of render passes (timestamp unit %.3f ns)", total * ns_per_tick / 1e6 / frames,
           (unsigned long)g_prof_ns.count, ns_per_tick);
    int shown = 0;
    for (NSString *key in sorted) {
        if (shown++ >= 25) break;
        nx_log("gpuprof: %6.2f ms/frame %5.1f passes/frame  %s", g_prof_ns[key].doubleValue * ns_per_tick / 1e6 / frames,
               g_prof_cnt[key].doubleValue / frames, key.UTF8String);
    }
    [g_prof_ns removeAllObjects], [g_prof_cnt removeAllObjects];
    pthread_mutex_unlock(&g_prof_lock);
}
static int px_bytes(MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatRGBA32Float: return 16;
    case MTLPixelFormatRGBA16Float: case MTLPixelFormatRGBA16Unorm: case MTLPixelFormatRG32Float: return 8;
    case MTLPixelFormatDepth32Float_Stencil8: return 5;
    case MTLPixelFormatR8Unorm: return 1;
    case MTLPixelFormatRG8Unorm: case MTLPixelFormatR16Float: case MTLPixelFormatDepth16Unorm: return 2;
    default: return 4;
    }
}
static uint64_t g_stats_chunks;   // mid-submit commits (stats)
static void commit_cmd(int cont);
static void flush_clears(void);
static void subdirty_mark(id<MTLTexture> t, int level, int slice);
// Commit at the next pass boundary once this many draws are encoded (NXRT_CHUNK_DRAWS). The game waits for
// each frame's GPU work before going on (SyncWait), so the GPU work left after the last commit is on the
// critical path: 400 -> 60 took the island from 28.5-29.1 fps to a steady 30 (the cap), 3 of 3 runs.
static int chunk_draws(void) {
    static int n;
    if (!n) n = getenv("NXRT_CHUNK_DRAWS") ? MAX(1, atoi(getenv("NXRT_CHUNK_DRAWS"))) : 60;
    return n;
}
// Colour targets of the open pass that the game reads back on the CPU (gfx_texture_readback_info).
static __strong id<MTLTexture> g_pass_rbt[8];
static NxReadback g_pass_rb[8];
static int g_pass_nrb;
static void readback_targets(void) {
    for (int i = 0; i < g_pass_nrb; i++) {
        id<MTLTexture> t = g_pass_rbt[i];
        NxReadback rb = g_pass_rb[i];
        g_pass_rbt[i] = nil;
        NSUInteger row = (NSUInteger)rb.w * rb.bpb;
        id<MTLBuffer> b = [g_dev newBufferWithLength:row * rb.h options:MTLResourceStorageModeShared];
        if (!b) continue;
        id<MTLBlitCommandEncoder> bl = [E_cmd blitCommandEncoder];
        [bl copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(rb.w, rb.h, 1)
                   toBuffer:b destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * rb.h];
        [bl endEncoding];
        // NXRT_RBLOG=<from>-<to>: each readback's frame at encode and when it lands in guest memory (vs NXRT_INVLOG reads)
        static int rl = -1, rlo, rhi;
        if (rl < 0) {
            const char *e = getenv("NXRT_RBLOG");
            rl = e != NULL;
            if (e) rlo = atoi(e), rhi = strchr(e, '-') ? atoi(strchr(e, '-') + 1) : 1 << 30;
        }
        extern volatile int g_gfx_frame;
        int ef = g_gfx_frame, lg = rl && ef >= rlo && ef <= rhi;
        uint64_t t0 = lg ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0;
        [E_cmd addCompletedHandler:^(id<MTLCommandBuffer> c) {
            gfx_texture_store(&rb, b.contents);
            static int t3 = -1, nt3;
            if (t3 < 0) t3 = getenv("NXRT_TEX3DLOG") != NULL;
            if (t3 && rb.bpb == 8 && rb.w == 256 && rb.h == 256 && ef % 300 == 0 && nt3++ < 12) {   // the sky colour table (RGBA16F): channel maxima
                const __fp16 *h = b.contents;
                float mx[4] = {0};
                for (int q = 0; q < 256 * 256 * 4; q++) mx[q & 3] = fmaxf(mx[q & 3], (float)h[q]);
                nx_log("tex3d: sky table %p frame %d max RGBA %g %g %g %g; row 128: %g %g %g", rb.dst, ef, mx[0], mx[1], mx[2], mx[3],
                       (float)h[(128 * 256 + 128) * 4], (float)h[(128 * 256 + 128) * 4 + 1], (float)h[(128 * 256 + 128) * 4 + 2]);
            }
            if (lg && rb.w == 32 && rb.bpb == 2) {   // picking / visibility rows: per row, the IDs its 32 samples returned
                const uint16_t *px = b.contents;
                for (int y = 0; y < rb.h; y++) {
                    char line[400];
                    int o = 0, any = 0;
                    uint16_t ids[32];
                    int cnt[32], nid = 0;
                    for (int x = 0; x < 32; x++) {
                        uint16_t v = px[y * 32 + x];
                        if (v == 0xFFFF) continue;
                        any = 1;
                        int q = 0;
                        while (q < nid && ids[q] != v) q++;
                        if (q == nid) ids[nid] = v, cnt[nid++] = 0;
                        cnt[q]++;
                    }
                    if (!any) continue;
                    for (int q = 0; q < nid && o < 360; q++) o += snprintf(line + o, sizeof line - o, " %04x*%d", ids[q], cnt[q]);
                    nx_log("rbrow: frame %d %p row %d:%s", ef, rb.dst, y, line);
                }
            }
            if (lg)
                nx_log("rblog: %dx%d -> %p encoded frame %d, stored at frame %d (+%.1f ms)", rb.w, rb.h, rb.dst, ef, g_gfx_frame,
                       (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6);
        }];
    }
    g_pass_nrb = 0;
}
// Rendering into a block-compressed texture through an uncompressed view of the same bytes per block (the
// Mii portraits: the game's GPU BC3 encoder renders 256x256 RGBA_DXT5 textures through RGBA32UI views, one
// texel = one 4x4 block, every mip level). Metal can neither render to nor make such views of compressed
// formats, so the pass renders into a shadow texture (blocks wide/high, one per level, kept with the
// compressed texture) and end_pass copies it into the compressed level through a buffer.
static __strong id<MTLTexture> g_pass_blk_src[8], g_pass_blk_dst[8];
static int g_pass_blk_level[8], g_pass_blk_slice[8], g_pass_blk_fmt[8], g_pass_nblk;
static char g_blk_key;
static id<MTLTexture> block_shadow(id<MTLTexture> t, const void *nvn_tex, int view_fmt, int level, int slice) {
    if (!view_fmt || t.textureType != MTLTextureType2D || slice != 0 || level < 0 || level >= (int)t.mipmapLevelCount) return nil;
    NxTexDesc d = {0};
    nx_nvn_texture_desc(nvn_tex, &d);
    const NvnFmt *cf = nvn_fmt(d.format), *vf = nvn_fmt(view_fmt);
    MTLPixelFormat vpf = gfx_mtl_format(view_fmt);
    if (!cf || !vf || cf->bw == 1 || vf->bw != 1 || cf->bpb != vf->bpb || vpf == MTLPixelFormatInvalid) return nil;
    NSUInteger bw = (MAX(1, t.width >> level) + cf->bw - 1) / cf->bw, bh = (MAX(1, t.height >> level) + cf->bh - 1) / cf->bh;
    NSMutableDictionary *per = objc_getAssociatedObject(t, &g_blk_key);
    if (!per) objc_setAssociatedObject(t, &g_blk_key, per = [NSMutableDictionary new], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSNumber *key = @((uint64_t)vpf << 8 | (uint64_t)level);
    id<MTLTexture> sh = per[key];
    if (!sh) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:vpf width:bw height:bh mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        sh = [g_dev newTextureWithDescriptor:td];
        if (!sh) return nil;
        per[key] = sh;
        static int n;
        if (n++ < 8) nx_log("gfx: block render target: %p (%lux%lu fmt %d) level %d through view fmt %d -> shadow %lux%lu", nvn_tex,
                            (unsigned long)t.width, (unsigned long)t.height, d.format, level, view_fmt, (unsigned long)bw, (unsigned long)bh);
    }
    if (g_pass_nblk < 8) {
        int k = g_pass_nblk++;
        g_pass_blk_src[k] = sh, g_pass_blk_dst[k] = t, g_pass_blk_level[k] = level, g_pass_blk_slice[k] = slice, g_pass_blk_fmt[k] = d.format;
    }
    return sh;
}
static void block_resolve(void) {
    for (int i = 0; i < g_pass_nblk; i++) {
        id<MTLTexture> sh = g_pass_blk_src[i], t = g_pass_blk_dst[i];
        int lv = g_pass_blk_level[i];
        g_pass_blk_src[i] = g_pass_blk_dst[i] = nil;
        NSUInteger bpb = 0;
        switch (sh.pixelFormat) {
        case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Sint: case MTLPixelFormatRGBA32Float: bpb = 16; break;
        case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRG32Float: case MTLPixelFormatRGBA16Uint:
        case MTLPixelFormatRGBA16Sint: case MTLPixelFormatRGBA16Float: bpb = 8; break;
        default: break;
        }
        if (!bpb) continue;
        NSUInteger row = sh.width * bpb;
        id<MTLBuffer> b = [g_dev newBufferWithLength:row * sh.height options:MTLResourceStorageModePrivate];
        if (!b) continue;
        id<MTLBlitCommandEncoder> bl = [E_cmd blitCommandEncoder];
        [bl copyFromTexture:sh sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(sh.width, sh.height, 1)
                   toBuffer:b destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * sh.height];
        MTLPixelFormat raw = gfx_mtl_format_raw(g_pass_blk_fmt[i]);
        if (gfx_bc_mode(raw) && gfx_bc_emulated()) {   // decoded BC texture: decode the rendered blocks into it
            [bl endEncoding];
            id<MTLComputeCommandEncoder> ce = [E_cmd computeCommandEncoder];
            gfx_bc_decode(ce, b, 0, row, raw, t, g_pass_blk_slice[i], lv, 0, 0, MAX(1, t.width >> lv), MAX(1, t.height >> lv));
            [ce endEncoding];
            continue;
        }
        [bl copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:row * sh.height
                sourceSize:MTLSizeMake(MAX(1, t.width >> lv), MAX(1, t.height >> lv), 1) toTexture:t
          destinationSlice:g_pass_blk_slice[i] destinationLevel:lv destinationOrigin:MTLOriginMake(0, 0, 0)];
        [bl endEncoding];
    }
    g_pass_nblk = 0;
}
// NXRT_TEXSNAP=<NVN texture ptr hex>: after every pass that renders into that texture (level 0..n), log its
// level-0 content when the GPU is done (non-zero texels, mean RGBA). First 60 passes.
static __strong id<MTLTexture> g_snap_t;
static int g_snap_level;
static const void *g_snap_nvn;
static void texsnap_end(void) {
    if (!g_snap_t) return;
    static int n;
    id<MTLTexture> t = g_snap_t.parentTexture ? g_snap_t.parentTexture : g_snap_t;
    int lv = g_snap_level;
    g_snap_t = nil;
    if (n++ >= 400 || t.pixelFormat == MTLPixelFormatInvalid) return;
    if (lv < 0 || lv >= (int)t.mipmapLevelCount) lv = 0;
    NSUInteger w = MAX(1, t.width >> lv), h = MAX(1, t.height >> lv), row = w * 4;
    id<MTLBuffer> b = [g_dev newBufferWithLength:row * h options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> bl = [E_cmd blitCommandEncoder];
    [bl copyFromTexture:t sourceSlice:0 sourceLevel:lv sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:b
      destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * h];
    [bl endEncoding];
    extern volatile int g_gfx_frame;
    int frame = g_gfx_frame;
    const void *nvn = g_snap_nvn;
    int k_n = n;
    [E_cmd addCompletedHandler:^(id<MTLCommandBuffer> c) {
        const uint8_t *p = b.contents;
        uint64_t nz = 0, sum[4] = {0};
        for (NSUInteger i = 0; i < w * h; i++) {
            if (p[4 * i] | p[4 * i + 1] | p[4 * i + 2] | p[4 * i + 3]) nz++;
            for (int k = 0; k < 4; k++) sum[k] += p[4 * i + k];
        }
        const char *dir = getenv("NXRT_TEXSNAP_DIR");   // raw RGBA level 0 after each pass (alpha shown as white background mix)
        if (dir) {
            uint8_t *o = malloc(w * h * 4);
            for (NSUInteger i = 0; i < w * h; i++) {   // composite over white so transparent areas are visible
                unsigned a = p[4 * i + 3];
                for (int k = 0; k < 3; k++) o[4 * i + k] = (uint8_t)((p[4 * i + k] * a + 255 * (255 - a)) / 255);
                o[4 * i + 3] = 255;
            }
            char path[1024];
            snprintf(path, sizeof path, "%s/snap_f%d_l%d_%p_%d.png", dir, frame, lv, nvn, k_n);
            gfx_write_png(path, o, (int)w, (int)h);
            free(o);
        }
        nx_log("texsnap: %p frame %d pass into level %d -> that level has %llu non-zero texels, mean %.1f %.1f %.1f %.1f", nvn, frame, lv,
               (unsigned long long)nz, sum[0] / (double)(w * h), sum[1] / (double)(w * h), sum[2] / (double)(w * h), sum[3] / (double)(w * h));
    }];
}
static void end_pass(void) {
    int had = E != nil;
    if (E && g_stats_draws == g_pass_draws_at_begin) g_pass_empty++;
    if (E && dbg()) {
        hist("pass: w*100000+h*10+loaded", g_pass_key);
        hist("pass: draws in pass", (long)MIN(g_stats_draws - g_pass_draws_at_begin, 9999));
    }
    if (E) [E endEncoding];
    E = nil;
    if (had && g_pass_nrb) readback_targets();
    if (had && g_pass_nblk) block_resolve();
    if (had) texsnap_end();
    if (had && g_in_submit && E_cmd && g_stats_draws - g_draws_at_submit >= (uint64_t)chunk_draws()) commit_cmd(1);
}

static id<MTLTexture> format_view(id<MTLTexture> t, int nvn_view_fmt);
// Diagnostics: why an open pass ended (GFXDBG histogram "pass end reason").
enum { PE_CLEAR_FLUSH, PE_FEEDBACK, PE_SNAPSHOT, PE_COMPUTE, PE_RT, PE_RT_SAME, PE_CLEAR_COLOR, PE_CLEAR_DS, PE_CLEAR_TEX, PE_COPY, PE_SUBMIT, PE_SPLIT, PE_N };
// Per end reason: passes ended, and attachment bytes the next pass loaded back (stats line).
static uint64_t g_pe_n[PE_N], g_pe_load[PE_N];
// Attachment traffic per attachment kind (w, h, Metal format, level, color/depth): loads, stores, passes.
enum { ATT_N = 64 };
static struct { long key; uint64_t load, store, n, cleared; } g_att[ATT_N];
static void att_note(id<MTLTexture> t, int level, int depth, MTLLoadAction la, uint64_t b) {
    long key = ((long)MAX(1, (int)t.width >> level) * 10000 + MAX(1, (int)t.height >> level)) * 10000 + (long)t.pixelFormat * 10 + depth;
    for (int i = 0; i < ATT_N; i++)
        if (!g_att[i].key || g_att[i].key == key) {
            g_att[i].key = key, g_att[i].n++, g_att[i].store += b;
            if (la == MTLLoadActionLoad) g_att[i].load += b;
            if (la == MTLLoadActionClear) g_att[i].cleared++;
            return;
        }
}
static int g_pe_last = 10;
// NXRT_PASSLOG=<frame>: every pass of that frame: attachments, load actions, draws, why it ended.
static char g_passlog_desc[1024];
static void end_pass_why(int why) {
    if (E) g_pe_n[why]++, g_pe_last = why;
    static int plf = -2;
    if (plf == -2) plf = ENV("NXRT_PASSLOG") ? atoi(ENV("NXRT_PASSLOG")) : -1;
    extern volatile int g_gfx_frame;
    if (E && plf == g_gfx_frame) {
        static const char *const nm[PE_N] = {"clear flush", "feedback", "snapshot", "compute", "rt", "rt same", "clear color", "clear ds", "clear tex", "copy", "submit", "split"};
        char sm[48 * 16] = "";
        int k = 0;
        for (int o = 0; k < g_pass_nsmp && k < 48; k++) o += snprintf(sm + o, sizeof sm - o, " m%p", g_pass_smp[k]);
        nx_log("passlog: frame %d %s draws %llu (last fs %016llx) -> ended by %s; samples%s", g_gfx_frame, g_passlog_desc,
               (unsigned long long)(g_stats_draws - g_pass_draws_at_begin), (unsigned long long)g_pass_last_fs, nm[why], sm);
        while (k < g_pass_nsmp) {   // the rest of a long sample list on continuation lines
            sm[0] = 0;
            for (int o = 0, e = k + 48; k < g_pass_nsmp && k < e; k++) o += snprintf(sm + o, sizeof sm - o, " m%p", g_pass_smp[k]);
            nx_log("passlog+:%s", sm);
        }
    }
    if (E && dbg()) hist("pass end reason: 0 clear flush, 1 feedback, 2 snapshot, 3 compute, 4 rt, 5 rt same, 6 clear color, 7 clear ds, 8 clear tex, 9 copy, 10 submit", why);
    end_pass();
}
// NXRT_PASSLOG: work between passes (compute, copies, texture clears) as event lines
static void passlog_event(const char *what, id<MTLTexture> a, id<MTLTexture> b) {
    static int plf = -2;
    if (plf == -2) plf = ENV("NXRT_PASSLOG") ? atoi(ENV("NXRT_PASSLOG")) : -1;
    extern volatile int g_gfx_frame;
    if (plf != g_gfx_frame) return;
    while (a.parentTexture) a = a.parentTexture;
    while (b.parentTexture) b = b.parentTexture;
    nx_log("passlog: frame %d event %s m%p -> m%p", g_gfx_frame, what, a, b);
}
static void eb_reset(void);
// flush_clears: the pass attaches only the targets with a pending clear (color by mask; the depth/stencil texture
// if depth or stencil is cleared). Attaching the others loaded and stored them for nothing (a 1080p color
// around a depth clear: 16 MB). NXRT_CLEARFLUSH_ALL=1: old (every target).
static int g_clear_only;
static int begin_pass(void) {
    if (E) return 1;
    g_pass_nrb = 0;
    for (; g_pass_nblk > 0; g_pass_nblk--) g_pass_blk_src[g_pass_nblk - 1] = g_pass_blk_dst[g_pass_nblk - 1] = nil;
    if (draw_check_only()) return 0;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    int w = 0, h = 0, samples = 1, any = 0;
    for (int i = 0; i < 8; i++) E_color[i] = MTLPixelFormatInvalid;
    g_pass_c0 = nil;
    E_depth = E_stencil = MTLPixelFormatInvalid, E_depth24 = 0;
    for (int i = 0; i < S.rt.n; i++) {
        if (g_clear_only && !(pend_clear_color_mask & 1 << i)) continue;
        id<MTLTexture> t = tex_mtl_cached(S.rt.color[i]);
        int blk = 0;   // rendering into a compressed texture through an uncompressed view: shadow target (level 0)
        if (t && !(t.usage & MTLTextureUsageRenderTarget)) {
            id<MTLTexture> sh = block_shadow(t, S.rt.color[i], S.rt.vfmt[i], S.rt.level[i], S.rt.layer[i]);
            if (sh) t = sh, blk = 1;
        }
        if (t && !(t.usage & MTLTextureUsageRenderTarget)) {
            static int nlog;
            if (nlog++ < 20) {
                NxTexDesc d = {0};
                nx_nvn_texture_desc(S.rt.color[i], &d);
                extern volatile int g_gfx_frame;
                char sh[120] = "";
                for (int k = 0, o = 0; k < S.prog.n && o < (int)sizeof sh; k++)
                    o += snprintf(sh + o, sizeof sh - o, " %s %016llx", S.prog.st[k].kind, (unsigned long long)S.prog.st[k].hash);
                nx_log("gfx: frame %d render target %p rt%d skipped: not renderable (%dx%d fmt %d, view fmt %d, level %d) program:%s", g_gfx_frame,
                       S.rt.color[i], i, d.w, d.h, d.format, S.rt.vfmt[i], S.rt.level[i], sh);
            }
        }
        if (!t || !(t.usage & MTLTextureUsageRenderTarget)) continue;
        if (ENV("NXRT_TEXWATCH_SIZE")) {   // which shaders render into the watched size (see gfx_texture_mark_gpu)
            int ww = 0, wh = 0, wf = -1;   // <w>x<h>[:<nvn format>]
            sscanf(ENV("NXRT_TEXWATCH_SIZE"), "%dx%d:%d", &ww, &wh, &wf);
            NxTexDesc wd = {0};
            if (wf >= 0) nx_nvn_texture_desc(S.rt.color[i], &wd);
            static int n;
            if ((int)t.width == ww && (int)t.height == wh && (wf < 0 || wd.format == wf) && n++ < 200) {
                extern volatile int g_gfx_frame;
                char sh[200] = "";
                int o = 0;
                for (int k = 0; k < S.prog.n; k++)
                    o += snprintf(sh + o, sizeof sh - o, " %s %016llx", S.prog.st[k].kind, (unsigned long long)S.prog.st[k].hash);
                nx_log("texwatch: frame %d pass into rt%d %p (%lux%lu fmt %lu) program:%s", g_gfx_frame, i, S.rt.color[i], (unsigned long)t.width,
                       (unsigned long)t.height, (unsigned long)t.pixelFormat, sh);
            }
        }
        gfx_texture_mark_gpu(S.rt.color[i]);
        if (!blk) t = format_view(t, S.rt.vfmt[i]);
        int lv = blk ? 0 : S.rt.level[i], ly = blk ? 0 : S.rt.layer[i];
        NSUInteger slices = t.textureType == MTLTextureType3D ? MAX(1, t.depth >> lv)
                          : t.arrayLength * (t.textureType == MTLTextureTypeCube || t.textureType == MTLTextureTypeCubeArray ? 6 : 1);
        if (lv < 0 || lv >= (int)t.mipmapLevelCount || ly < 0 || ly >= (int)slices) {   // GPU safety
            static int nskip;
            if (nskip++ < 400) nx_log("gfx: render target %p rt%d skipped: level %d / layer %d outside %lux%lu (%lu levels, %lu slices)", S.rt.color[i], i,
                                     lv, ly, (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.mipmapLevelCount, (unsigned long)slices);
            continue;
        }
        rp.colorAttachments[i].texture = t;
        {
            static long snap = -1;
            static int snap_w, snap_h;   // NXRT_TEXSNAP=<w>x<h>: every target of that size instead of one texture
            if (snap < 0) {
                const char *e = getenv("NXRT_TEXSNAP");
                snap = e && strncmp(e, "0x", 2) && sscanf(e, "%dx%d", &snap_w, &snap_h) == 2 ? 1 : e ? strtol(e, NULL, 16) : 0;
            }
            if (snap && (snap_w ? (int)t.width == snap_w && (int)t.height == snap_h && lv == 0 : (long)S.rt.color[i] == snap) &&
                t.pixelFormat != MTLPixelFormatInvalid) g_snap_t = t, g_snap_level = lv, g_snap_nvn = S.rt.color[i];
        }
        {
            NxReadback rb;
            static int rb_off = -1;   // NXRT_NOREADBACK=1: never copy render targets back to CPU-readable storage
            if (rb_off < 0) rb_off = getenv("NXRT_NOREADBACK") != NULL;
            if (!rb_off && !blk && lv == 0 && ly == 0 && t.textureType == MTLTextureType2D && gfx_texture_readback_info(S.rt.color[i], &rb) &&
                px_bytes(t.pixelFormat) == rb.bpb && t.width >= (NSUInteger)rb.w && t.height >= (NSUInteger)rb.h && g_pass_nrb < 8) {
                g_pass_rbt[g_pass_nrb] = t, g_pass_rb[g_pass_nrb++] = rb;
                static int logged;
                if (logged++ < 8) nx_log("gfx: readback target %p %dx%d bpb %d %s -> %p", S.rt.color[i], rb.w, rb.h, rb.bpb,
                                         rb.stride > 0 ? "pitch" : "block-linear", rb.dst);
            } else if (ENV("NXRT_RBLOG") && !rb_off && gfx_texture_readback_info(S.rt.color[i], &rb) && lv == 0) {
                static int nrej;
                extern volatile int g_gfx_frame;
                if (nrej++ < 40)
                    nx_log("rblog: frame %d target %p -> %p NOT read back: blk %d lv %d ly %d type %lu px %d bpb %d metal %lux%lu need %dx%d nrb %d",
                           g_gfx_frame, S.rt.color[i], rb.dst, blk, lv, ly, (unsigned long)t.textureType, px_bytes(t.pixelFormat), rb.bpb,
                           (unsigned long)t.width, (unsigned long)t.height, rb.w, rb.h, g_pass_nrb);
            }
        }
        {
            extern volatile int g_gfx_frame;
            static int f = -2;
            if (f == -2) f = getenv("NXRT_DEPTHDBG") ? atoi(getenv("NXRT_DEPTHDBG")) : -1;
            if (f == g_gfx_frame && t.pixelFormat == MTLPixelFormatR32Float)
                nx_log("depthdbg: pass color%d nvn %p metal %p %lux%lu R32F load %s", i, S.rt.color[i], t, (unsigned long)t.width,
                       (unsigned long)t.height, pend_clear_color_mask & 1 << i ? "clear" : "load");
        }
        rp.colorAttachments[i].level = lv;
        if (t.textureType == MTLTextureType3D) rp.colorAttachments[i].depthPlane = ly;
        else rp.colorAttachments[i].slice = ly;
        subdirty_mark(t, lv, ly);
        rp.colorAttachments[i].storeAction = MTLStoreActionStore;
        if (pend_clear_color_mask & 1 << i) {
            rp.colorAttachments[i].loadAction = MTLLoadActionClear;
            float *c = pend_clear_color[i];
            rp.colorAttachments[i].clearColor = MTLClearColorMake(c[0], c[1], c[2], c[3]);
        } else rp.colorAttachments[i].loadAction = MTLLoadActionLoad;
        if (i == 0) g_pass_c0 = t, g_pass_c0_lv = lv, g_pass_c0_ly = ly;   // fxaa_after
        E_color[i] = t.pixelFormat;
        int tw = MAX(1, (int)t.width >> lv), th = MAX(1, (int)t.height >> lv);
        w = w ? MIN(w, tw) : tw;
        h = h ? MIN(h, th) : th;
        samples = (int)t.sampleCount;
        any = 1;
    }
    if (S.rt.depth && (!g_clear_only || pend_clear_depth || pend_clear_stencil)) {
        id<MTLTexture> t = tex_mtl_cached(S.rt.depth);
        int lv = S.rt.dlevel, ly = S.rt.dlayer;
        NSUInteger slices = t ? t.arrayLength * (t.textureType == MTLTextureTypeCube || t.textureType == MTLTextureTypeCubeArray ? 6 : 1) : 0;
        if (t && (t.pixelFormat == MTLPixelFormatDepth32Float || t.pixelFormat == MTLPixelFormatDepth16Unorm ||
                  t.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) &&
            lv >= 0 && lv < (int)t.mipmapLevelCount && ly >= 0 && ly < (int)slices) {
            rp.depthAttachment.texture = t;
            {   // NXRT_DEPTHDBG=<frame>: depth attachments and depth-format textures sampled in that frame
                extern volatile int g_gfx_frame;
                static int f = -2;
                if (f == -2) f = getenv("NXRT_DEPTHDBG") ? atoi(getenv("NXRT_DEPTHDBG")) : -1;
                if (f == g_gfx_frame) nx_log("depthdbg: pass depth nvn %p metal %p fmt %lu load %s", S.rt.depth, t, (unsigned long)t.pixelFormat,
                                             pend_clear_depth ? "clear" : "load");
            }
            rp.depthAttachment.level = lv;
            rp.depthAttachment.slice = ly;
            subdirty_mark(t, lv, ly);
            rp.depthAttachment.storeAction = MTLStoreActionStore;
            rp.depthAttachment.loadAction = pend_clear_depth ? MTLLoadActionClear : MTLLoadActionLoad;
            rp.depthAttachment.clearDepth = pend_depth;
            E_depth = t.pixelFormat;
            {
                NxTexDesc dd = {0};
                nx_nvn_texture_desc(S.rt.depth, &dd);
                E_depth24 = eq24_on() && (dd.format == 51 || dd.format == 53);
            }
            if (t.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
                rp.stencilAttachment.texture = t;
                rp.stencilAttachment.level = lv;
                rp.stencilAttachment.slice = ly;
                rp.stencilAttachment.storeAction = MTLStoreActionStore;
                rp.stencilAttachment.loadAction = pend_clear_stencil ? MTLLoadActionClear : MTLLoadActionLoad;
                rp.stencilAttachment.clearStencil = pend_stencil;
                E_stencil = t.pixelFormat;
            }
            int tw = MAX(1, (int)t.width >> lv), th = MAX(1, (int)t.height >> lv);
            w = w ? MIN(w, tw) : tw;
            h = h ? MIN(h, th) : th;
            samples = (int)t.sampleCount;
            any = 1;
        }
    }
    pend_clear_color_mask = pend_clear_depth = pend_clear_stencil = 0;
    if (!any) return 0;
    for (int i = 0; i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *c = rp.colorAttachments[i];
        if (!c.texture) continue;
        uint64_t b = (uint64_t)MAX(1, (int)c.texture.width >> c.level) * MAX(1, (int)c.texture.height >> c.level) * px_bytes(c.texture.pixelFormat);
        if (c.loadAction == MTLLoadActionLoad) g_pass_load_bytes += b, g_pe_load[g_pe_last] += b;
        att_note(c.texture, (int)c.level, 0, c.loadAction, b);
        g_pass_store_bytes += b;
    }
    if (rp.depthAttachment.texture) {
        id<MTLTexture> t = rp.depthAttachment.texture;
        uint64_t b = (uint64_t)MAX(1, (int)t.width >> rp.depthAttachment.level) * MAX(1, (int)t.height >> rp.depthAttachment.level) * px_bytes(t.pixelFormat);
        if (rp.depthAttachment.loadAction == MTLLoadActionLoad) g_pass_load_bytes += b, g_pe_load[g_pe_last] += b;
        att_note(t, (int)rp.depthAttachment.level, 1, rp.depthAttachment.loadAction, b);
        g_pass_store_bytes += b;
    }
    g_pass_n++;
    g_pass_draws_at_begin = g_stats_draws;
    {
        static int plf = -2;
        if (plf == -2) plf = ENV("NXRT_PASSLOG") ? atoi(ENV("NXRT_PASSLOG")) : -1;
        extern volatile int g_gfx_frame;
        g_passlog_on = plf == g_gfx_frame, g_pass_nsmp = 0;
        if (plf == g_gfx_frame) {
            int o = 0;
            for (int i = 0; i < 8; i++) {
                MTLRenderPassColorAttachmentDescriptor *c = rp.colorAttachments[i];
                if (c.texture)
                    o += snprintf(g_passlog_desc + o, sizeof g_passlog_desc - o, "c%d %p[m%p] %lux%lu/%lu:%lu fmt %lu %s; ", i, S.rt.color[i],
                                  c.texture.parentTexture ? c.texture.parentTexture : c.texture,(unsigned long)c.texture.width,
                                  (unsigned long)c.texture.height, (unsigned long)c.level, (unsigned long)(c.slice + c.depthPlane), (unsigned long)c.texture.pixelFormat,
                                  c.loadAction == MTLLoadActionLoad ? "load" : "clear");
            }
            if (rp.depthAttachment.texture)
                snprintf(g_passlog_desc + o, sizeof g_passlog_desc - o, "d %p[m%p] %lux%lu/%lu:%lu %s", S.rt.depth, rp.depthAttachment.texture,(unsigned long)rp.depthAttachment.texture.width,
                         (unsigned long)rp.depthAttachment.texture.height, (unsigned long)rp.depthAttachment.level, (unsigned long)rp.depthAttachment.slice, rp.depthAttachment.loadAction == MTLLoadActionLoad ? "load" : "clear");
        }
    }
    prof_pass(rp, w, h, rp.colorAttachments[0].texture ? rp.colorAttachments[0].texture.pixelFormat : (rp.depthAttachment.texture ? rp.depthAttachment.texture.pixelFormat : 0));
    g_pass_key = (long)w * 100000 + h * 10 + (rp.colorAttachments[0].texture && rp.colorAttachments[0].loadAction == MTLLoadActionLoad);
    E = [E_cmd renderCommandEncoderWithDescriptor:rp];
    eb_reset();
    E_w = w;
    E_h = h;
    E_samples = samples;
    return E != nil;
}
// Clears are deferred into the next pass's load action, so a clear followed by draws is one pass and
// consecutive clears (color, depth, stencil) merge. Before anything that needs the cleared contents
// without drawing (render target switch, copy, compute, end of submit) they run as their own pass.
static void flush_clears(void) {
    if (!pend_clear_color_mask && !pend_clear_depth && !pend_clear_stencil) return;
    static int all = -1;
    if (all < 0) all = getenv("NXRT_CLEARFLUSH_ALL") != NULL;
    g_clear_only = !all && !E;
    begin_pass();
    g_clear_only = 0;
    end_pass_why(PE_CLEAR_FLUSH);
}

// Pipeline built asynchronously (see shader_get); nil until ready.
@interface NxPipe : NSObject {
@public
    id<MTLRenderPipelineState> pso;
    volatile int ready;
}
@end
@implementation NxPipe
@end

// Hash of a zero-initialized key struct (size a multiple of 8), for the C front caches below: building an
// NSData key and hashing it in an NSDictionary per draw cost ~10% of encode.
static uint64_t key_hash(const void *k, size_t n) {
    const uint64_t *w = k;
    uint64_t h = 0x9E3779B97F4A7C15ull;
    for (size_t i = 0; i < n / 8; i++) h = (h ^ w[i]) * 0xFF51AFD7ED558CCDull, h ^= h >> 32;
    return h;
}

typedef struct {
    uint64_t vs, fs;
    uint32_t color[8], depth, stencil, samples, chmask, blend_mask, a2c;
    NvBlend blend[8];
    struct { uint16_t fmt; uint8_t stream, kind; uint32_t offset; } attr[32];
    struct { uint32_t stride, divisor; } stream[16];
} PipeKey;
_Static_assert(sizeof(PipeKey) % 8 == 0, "key_hash");

static id<MTLRenderPipelineState> pipeline_for(__unsafe_unretained NxShader *vs, __unsafe_unretained NxShader *fs, uint64_t vsh, uint64_t fsh) {
    static NSMutableDictionary<NSData *, NxPipe *> *cache;
    if (!cache) cache = [NSMutableDictionary new];
    PipeKey k;
    memset(&k, 0, sizeof k);
    k.vs = vsh;
    k.fs = fsh;
    for (int i = 0; i < 8; i++) k.color[i] = (uint32_t)E_color[i];
    k.depth = (uint32_t)E_depth;
    k.stencil = (uint32_t)E_stencil;
    k.samples = E_samples;
    k.chmask = S.chmask.write;
    k.blend_mask = S.color.blend_mask;
    k.a2c = S.ms.a2c;
    for (int i = 0; i < 8; i++)
        if (S.color.blend_mask & 1 << i) k.blend[i] = S.blend[i];
    for (int i = 0; i < vs->nattr; i++) {
        int loc = vs->attr_loc[i];
        if (loc < S.attr.n && S.attr.a[loc].format) {
            NvVAttr a = S.attr.a[loc];
            k.attr[i].fmt = a.format;
            k.attr[i].stream = a.stream;
            k.attr[i].offset = a.offset;
            if (a.stream < 16 && a.stream < S.stream.n)
                k.stream[a.stream].stride = S.stream.s[a.stream].stride, k.stream[a.stream].divisor = S.stream.s[a.stream].divisor;
        }
        k.attr[i].kind = vs->attr_kind[i];
    }
    // The last draw's pipeline first (BOTW): consecutive draws mostly share it, and its key stays in the CPU cache (the
    // front table is ~1 MB: hashing the key and comparing a cold entry cost more).
    static PipeKey last_k;
    static __unsafe_unretained id<MTLRenderPipelineState> last_v;   // owned by the front table / dictionary for good
    if (last_v && !memcmp(&last_k, &k, sizeof k)) return last_v;
    enum { FRONT_N = 2048 };   // direct-mapped front cache over the dictionary (ready pipelines only)
    static PipeKey front_k[FRONT_N];
    static __strong id<MTLRenderPipelineState> front_v[FRONT_N];
    size_t fi = key_hash(&k, sizeof k) & (FRONT_N - 1);
    if (front_v[fi] && !memcmp(&front_k[fi], &k, sizeof k)) {
        last_k = k, last_v = front_v[fi];
        return last_v;
    }
    NSData *key = [NSData dataWithBytes:&k length:sizeof k];
    NxPipe *hit = cache[key];
    if (hit) {
        if (wait_compiled(&hit->ready) != 1) return nil;
        front_k[fi] = k, front_v[fi] = hit->pso;
        return hit->pso;
    }

    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    uint32_t umask = 0, smask = 0;
    for (int i = 0; i < vs->nattr; i++)
        if (vs->attr_loc[i] < 32 && k.attr[i].stream < 14) {
            int t = vfmt_int(k.attr[i].fmt);
            if (t == 1) umask |= 1u << vs->attr_loc[i];
            if (t == 2) smask |= 1u << vs->attr_loc[i];
        }
    if (umask | smask) {
        vs = vs_variant(vs, umask, smask);
        if (!vs) return nil;   // compiling (or failed): skip the draw, retry next time
    }
    d.vertexFunction = vs->fn;
    if (fs && (fs->locs & ~vs->locs)) {
        fs = fs_variant(fs, fs->locs & ~vs->locs);
        if (!fs) return nil;   // compiling (or failed): skip the draw, retry next time
    }
    {
        uint32_t ou = 0, os = 0;
        for (int i = 0; i < 8; i++) ou |= (mtl_int_kind(E_color[i]) == 1) << i, os |= (mtl_int_kind(E_color[i]) == 2) << i;
        if (fs && (ou | os) && !(fs = fs_int_variant(fs, ou, os))) return nil;
    }
    d.fragmentFunction = fs ? fs->fn : nil;
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    int dummy = 0;
    for (int i = 0; i < vs->nattr; i++) {
        int loc = vs->attr_loc[i];
        MTLVertexFormat f = k.attr[i].fmt ? vertex_format(k.attr[i].fmt) : MTLVertexFormatInvalid;
        if (f == MTLVertexFormatInvalid || k.attr[i].stream >= 14) {
            if (k.attr[i].fmt) {
                static int n;
                if (n++ < 16) nx_log("gfx: vertex format %d not mapped (attribute %d)", k.attr[i].fmt, loc);
            }
            vd.attributes[loc].format = vs->attr_kind[i] == 'f' ? MTLVertexFormatFloat4 : vs->attr_kind[i] == 'i' ? MTLVertexFormatInt4 : MTLVertexFormatUInt4;
            vd.attributes[loc].bufferIndex = 30;
            vd.attributes[loc].offset = 0;
            dummy = 1;
            continue;
        }
        int s = k.attr[i].stream;
        vd.attributes[loc].format = f;
        vd.attributes[loc].offset = k.attr[i].offset;
        vd.attributes[loc].bufferIndex = 29 - s;
        uint32_t stride = k.stream[s].stride;
        vd.layouts[29 - s].stride = stride ? stride : 16;
        if (!stride) {
            vd.layouts[29 - s].stepFunction = MTLVertexStepFunctionConstant;
            vd.layouts[29 - s].stepRate = 0;
        } else if (k.stream[s].divisor) {
            vd.layouts[29 - s].stepFunction = MTLVertexStepFunctionPerInstance;
            vd.layouts[29 - s].stepRate = k.stream[s].divisor;
        }
    }
    if (dummy) {
        vd.layouts[30].stride = 16;
        vd.layouts[30].stepFunction = MTLVertexStepFunctionConstant;
        vd.layouts[30].stepRate = 0;
    }
    d.vertexDescriptor = vd;
    for (int i = 0; i < 8; i++) {
        d.colorAttachments[i].pixelFormat = E_color[i];
        if (E_color[i] == MTLPixelFormatInvalid) continue;
        uint32_t m = S.chmask.write >> 4 * i & 0xF;
        d.colorAttachments[i].writeMask = (m & 1 ? MTLColorWriteMaskRed : 0) | (m & 2 ? MTLColorWriteMaskGreen : 0) |
                                          (m & 4 ? MTLColorWriteMaskBlue : 0) | (m & 8 ? MTLColorWriteMaskAlpha : 0);
        if (S.color.blend_mask & 1 << i) {
            NvBlend b = S.blend[i];
            d.colorAttachments[i].blendingEnabled = YES;
            d.colorAttachments[i].sourceRGBBlendFactor = blend_factor(b.src);
            d.colorAttachments[i].destinationRGBBlendFactor = blend_factor(b.dst);
            d.colorAttachments[i].sourceAlphaBlendFactor = blend_factor(b.srca);
            d.colorAttachments[i].destinationAlphaBlendFactor = blend_factor(b.dsta);
            d.colorAttachments[i].rgbBlendOperation = blend_op(b.eq);
            d.colorAttachments[i].alphaBlendOperation = blend_op(b.eqa);
        }
    }
#if TARGET_OS_SIMULATOR
    {   // The simulator GPU has 32 bytes of render-target storage per pixel (the A15 takes the game's G-buffers):
        // pipelines over that abort in Metal validation there, so their draws are skipped in the simulator only.
        uint32_t px = 0;
        for (int i = 0; i < 8; i++) {
            MTLPixelFormat f = E_color[i];
            if (f == MTLPixelFormatInvalid) continue;
            uint32_t sz = f >= MTLPixelFormatRGBA32Uint && f <= MTLPixelFormatRGBA32Float ? 16
                        : (f >= MTLPixelFormatRG32Uint && f <= MTLPixelFormatRG32Float) || (f >= MTLPixelFormatRGBA16Unorm && f <= MTLPixelFormatRGBA16Float) ? 8
                        // packed and sRGB formats take more tile storage than their texel size (8 x RG11B10Float = 64 bytes)
                        : (f >= MTLPixelFormatRGB10A2Unorm && f <= MTLPixelFormatRGB9E5Float) || f == MTLPixelFormatRGBA8Unorm_sRGB ||
                          f == MTLPixelFormatBGRA8Unorm_sRGB ? 8
                        : f <= MTLPixelFormatR8Sint ? 1
                        : f <= MTLPixelFormatB5G6R5Unorm ? 2 : 4;
            px = (px + sz - 1) / sz * sz + sz;
        }
        if (px > 32) {
            static int n;
            if (n++ < 8) nx_log("gfx: simulator: pipeline %016llx/%016llx needs %u bytes of render-target storage per pixel, skipped",
                                (unsigned long long)vsh, (unsigned long long)fsh, px);
            NxPipe *skip = [NxPipe new];
            skip->ready = -1;
            cache[key] = skip;
            return nil;
        }
    }
#endif
    d.depthAttachmentPixelFormat = E_depth;
    d.stencilAttachmentPixelFormat = E_stencil;
    d.rasterSampleCount = E_samples;
    d.alphaToCoverageEnabled = S.ms.a2c;
    NxPipe *pipe = [NxPipe new];
    cache[key] = pipe;
    g_pipes_created++;
    pipe_archives_init();
    harvest_render(d);
    if (from_metallib(d.vertexFunction) && d.fragmentFunction && from_metallib(d.fragmentFunction)) pc_prepare(d, key_hash(&k, sizeof k));
    else if (g_pipe_archive) d.binaryArchives = @[g_pipe_archive];
    if (d.binaryArchives.count && getenv("NXRT_PIPEARCHIVE_CHECK")) {   // is this pipeline in the archive? (diagnostic, synchronous)
        static int hits, misses;
        NSError *e = nil;
        id<MTLRenderPipelineState> t = [g_dev newRenderPipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss
                                                                         reflection:nil error:&e];
        if (t) hits++;
        else if (misses++ < 6) nx_log("gfx: archive miss %s/%s: %s", d.vertexFunction.name.UTF8String, d.fragmentFunction.name.UTF8String ?: "-",
                                      e.localizedDescription.UTF8String);
        if ((hits + misses) % 100 == 0) nx_log("gfx: pipeline archive: %d hits, %d misses", hits, misses);
    }
    [g_dev newRenderPipelineStateWithDescriptor:d completionHandler:^(id<MTLRenderPipelineState> p, NSError *err) {
        if (!p) {
            static int n;
            if (n++ < 24) nx_log("gfx: pipeline %016llx/%016llx failed: %s", (unsigned long long)vsh, (unsigned long long)fsh,
                                 err.localizedDescription.UTF8String);
        }
        pipe->pso = p;
        __atomic_store_n(&pipe->ready, p ? 1 : -1, __ATOMIC_RELEASE);
    }];
    return wait_compiled(&pipe->ready) == 1 ? pipe->pso : nil;
}

static id<MTLDepthStencilState> ds_state(void) {
    static NSMutableDictionary<NSData *, id<MTLDepthStencilState>> *cache;
    if (!cache) cache = [NSMutableDictionary new];
    typedef struct { NvDS ds; int32_t rmask[2], wmask[2], has_depth, has_stencil; } DsKey;
    _Static_assert(sizeof(DsKey) % 8 == 0, "key_hash");
    DsKey k;
    memset(&k, 0, sizeof k);
    k.ds = S.ds;
    memcpy(k.rmask, S.stencil_vmask, 8);
    memcpy(k.wmask, S.stencil_mask, 8);
    k.has_depth = E_depth != MTLPixelFormatInvalid ? 1 + E_depth24 : 0;
    k.has_stencil = E_stencil != MTLPixelFormatInvalid;
    enum { FRONT_N = 256 };
    static DsKey front_k[FRONT_N];
    static __strong id<MTLDepthStencilState> front_v[FRONT_N];
    size_t fi = key_hash(&k, sizeof k) & (FRONT_N - 1);
    if (front_v[fi] && !memcmp(&front_k[fi], &k, sizeof k)) return front_v[fi];
    NSData *key = [NSData dataWithBytes:&k length:sizeof k];
    id<MTLDepthStencilState> hit = cache[key];
    if (hit) {
        front_k[fi] = k, front_v[fi] = hit;
        return hit;
    }
    MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
    if (k.has_depth && S.ds.dt) {
        d.depthCompareFunction = k.has_depth == 2 && S.ds.df == 3 ? MTLCompareFunctionLessEqual : compare(S.ds.df);
        d.depthWriteEnabled = S.ds.dw;
    }
    if (k.has_stencil && S.ds.st) {
        MTLStencilDescriptor *f = [MTLStencilDescriptor new], *b = [MTLStencilDescriptor new];
        f.stencilCompareFunction = compare(S.ds.sff);
        f.stencilFailureOperation = stencil_op(S.ds.ff);
        f.depthFailureOperation = stencil_op(S.ds.fzf);
        f.depthStencilPassOperation = stencil_op(S.ds.fzp);
        f.readMask = S.stencil_vmask[0];
        f.writeMask = S.stencil_mask[0];
        b.stencilCompareFunction = compare(S.ds.sfb);
        b.stencilFailureOperation = stencil_op(S.ds.bf);
        b.depthFailureOperation = stencil_op(S.ds.bzf);
        b.depthStencilPassOperation = stencil_op(S.ds.bzp);
        b.readMask = S.stencil_vmask[1];
        b.writeMask = S.stencil_mask[1];
        d.frontFaceStencil = f;
        d.backFaceStencil = b;
    }
    hit = [g_dev newDepthStencilStateWithDescriptor:d];
    cache[key] = hit;
    return hit;
}

static id<MTLTexture> dummy_texture(MTLTextureType type) {
    static NSMutableDictionary<NSNumber *, id<MTLTexture>> *cache;
    if (!cache) cache = [NSMutableDictionary new];
    id<MTLTexture> t = cache[@(type)];
    if (t) return t;
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = type == MTLTextureTypeTextureBuffer ? MTLTextureType2D : type;
    d.pixelFormat = MTLPixelFormatRGBA8Unorm;
    d.width = d.height = 1;
    if (type == MTLTextureType2DArray || type == MTLTextureTypeCubeArray) d.arrayLength = 1;
    if (type == MTLTextureType2DMultisample) d.sampleCount = 1, d.textureType = MTLTextureType2D;
    d.storageMode = MTLStorageModeShared;
    t = [g_dev newTextureWithDescriptor:d];
    cache[@(type)] = t;
    return t;
}

// Views and feedback copies per Metal texture, keyed by its address (not retained). They were
// weak-key NSMapTables, but a view retains its parent texture, so no texture that ever got a view was
// freed: every re-created transient render target leaked (~36 MB/frame until the system killed nxrt).
// gfx_textures.m calls gfx_texture_dropped() when it replaces or finalizes a texture.
static pthread_mutex_t g_view_lock = PTHREAD_MUTEX_INITIALIZER;
// Keyed by the texture's address (opaque map keys): NSValue keys (box, hash, isEqualToValue: per lookup) were ~6% of the island's encode.
static NSMapTable *ptr_map(void) {
    return [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                                 valueOptions:NSPointerFunctionsStrongMemory];
}
static NSMapTable<id, NSMutableDictionary *> *g_views;
static NSMapTable<id, id<MTLTexture>> *g_fb_copies;
static NSMapTable<id, NSNumber *> *g_fb_epochs;   // feedback copy -> epoch it was made in (resolve_feedback)
static NSMutableDictionary *views_for(id<MTLTexture> t) {   // g_view_lock held
    if (!g_views) g_views = ptr_map();
    NSMutableDictionary *per = [g_views objectForKey:t];
    if (!per) [g_views setObject:(per = [NSMutableDictionary new]) forKey:t];
    return per;
}
// Subresources (level << 16 | slice) written since the texture's feedback copy was refreshed, so the
// copy updates only those (render-target cube arrays were copied whole: up to 768 faces x levels).
// SUB_ALL: unknown or whole-texture write.
enum { SUB_ALL = 0x7FFFFFFF };
static NSMapTable<id, NSMutableIndexSet *> *g_subdirty;
static void subdirty_mark(id<MTLTexture> t, int level, int slice) {
    if (!t) return;
    pthread_mutex_lock(&g_view_lock);
    if ([g_fb_copies objectForKey:t]) {   // only textures that have a feedback copy
        if (!g_subdirty) g_subdirty = ptr_map();
        NSMutableIndexSet *set = [g_subdirty objectForKey:t];
        if (!set) [g_subdirty setObject:(set = [NSMutableIndexSet new]) forKey:t];
        [set addIndex:level < 0 || slice < 0 || t.textureType == MTLTextureType3D ? SUB_ALL : (NSUInteger)level << 16 | (NSUInteger)slice];
    }
    pthread_mutex_unlock(&g_view_lock);
}
void gfx_texture_dropped(id<MTLTexture> t) {
    if (!t) return;
    if (texgen_all()) g_tex_gen++;
    else bindcache_forget(NULL, (uintptr_t)(__bridge void *)t);
    tmc_dropped((uintptr_t)(__bridge void *)t);
    hist("texgen bumps: 0 register, 1 drop, 2 submit", 1);
    pthread_mutex_lock(&g_view_lock);
    [g_subdirty removeObjectForKey:t];
    NSMutableDictionary *per = [g_views objectForKey:t];
    for (NSNumber *mk in per)   // mip views (mip_view) go with t below; drop their own views too
        if (mk.unsignedLongLongValue >> 40 == 3 && per[mk] != (id)[NSNull null]) [g_views removeObjectForKey:per[mk]];
    id<MTLTexture> c = [g_fb_copies objectForKey:t];
    if (c) [g_views removeObjectForKey:c];
    [g_fb_copies removeObjectForKey:t];
    [g_fb_epochs removeObjectForKey:t];
    [g_views removeObjectForKey:t];
    pthread_mutex_unlock(&g_view_lock);
}

// Texture as the shader declares it (2D <-> 2D array <-> cube views where Metal allows).
static id<MTLTexture> texture_as(id<MTLTexture> t, MTLTextureType want) {
    if (!t || t.textureType == want) return t;
    pthread_mutex_lock(&g_view_lock);
    NSMutableDictionary *per = views_for(t);
    pthread_mutex_unlock(&g_view_lock);
    id<MTLTexture> v = per[@(want)];
    if (v) return v == (id)[NSNull null] ? nil : v;
    NSUInteger slices = t.arrayLength * (t.textureType == MTLTextureTypeCube || t.textureType == MTLTextureTypeCubeArray ? 6 : 1);
    if (want == MTLTextureTypeCube && slices < 6) v = nil;
    else if (want == MTLTextureTypeCubeArray && slices % 6) v = nil;
    else
        v = [t newTextureViewWithPixelFormat:t.pixelFormat textureType:want levels:NSMakeRange(0, t.mipmapLevelCount)
                                      slices:NSMakeRange(0, want == MTLTextureType2D ? 1 : want == MTLTextureTypeCube ? 6 : slices)];
    per[@(want)] = v ?: (id)[NSNull null];
    return v;
}

// Texture swizzles (NVN packing r | g << 4 | b << 8 | a << 12; ZERO 0, ONE 1, R..A 2..5 like Metal's
// MTLTextureSwizzle). The sampled result is the pool view's swizzle applied over the texture's own.
static uint16_t swizzle_compose(uint16_t tex_sw, uint16_t view_sw) {
    uint16_t out = 0;
    for (int c = 0; c < 4; c++) {
        int s = view_sw >> 4 * c & 15;
        int r = s < 2 ? s : s <= 5 ? tex_sw >> 4 * (s - 2) & 15 : 2 + c;
        out |= (uint16_t)(r > 5 ? 2 + c : r) << 4 * c;
    }
    return out;
}
// NVN texture views can change the format (RGBA8 <-> RGBA8_SRGB): rendering through an sRGB view
// encodes, sampling through one decodes. Metal: a format view of the texture (sRGB pairs only for now;
// other mismatches are counted in the GFXDBG histogram "view format ignored").
static int srgb_pair(MTLPixelFormat a, MTLPixelFormat b) {
    static const MTLPixelFormat p[][2] = {{MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm_sRGB},
                                          {MTLPixelFormatBGRA8Unorm, MTLPixelFormatBGRA8Unorm_sRGB},
                                          {MTLPixelFormatBC1_RGBA, MTLPixelFormatBC1_RGBA_sRGB},
                                          {MTLPixelFormatBC2_RGBA, MTLPixelFormatBC2_RGBA_sRGB},
                                          {MTLPixelFormatBC3_RGBA, MTLPixelFormatBC3_RGBA_sRGB},
                                          {MTLPixelFormatBC7_RGBAUnorm, MTLPixelFormatBC7_RGBAUnorm_sRGB}};
    for (size_t i = 0; i < sizeof p / sizeof *p; i++)
        if ((a == p[i][0] && b == p[i][1]) || (a == p[i][1] && b == p[i][0])) return 1;
    return 0;
}
static NSMutableDictionary *views_for(id<MTLTexture> t);
static id<MTLTexture> format_view(id<MTLTexture> t, int nvn_view_fmt) {
    if (!t || !nvn_view_fmt) return t;
    MTLPixelFormat pf = gfx_mtl_format(nvn_view_fmt);
    if (pf == MTLPixelFormatInvalid || pf == t.pixelFormat) return t;
    if (!srgb_pair(t.pixelFormat, pf)) {
        if (dbg()) hist("view format ignored (metal texture*1000+view)", (long)t.pixelFormat * 1000 + pf);
        return t;
    }
    pthread_mutex_lock(&g_view_lock);
    NSMutableDictionary *per = views_for(t);
    pthread_mutex_unlock(&g_view_lock);
    NSNumber *key = @(2ull << 40 | pf);
    id<MTLTexture> v = per[key];
    if (!v) {
        v = [t newTextureViewWithPixelFormat:pf];
        per[key] = v ?: (id)[NSNull null];
        static int n;
        if (n++ < 10) nx_log("gfx: format view %lu -> %lu (%lux%lu)", (unsigned long)t.pixelFormat, (unsigned long)pf, (unsigned long)t.width,
                             (unsigned long)t.height);
    }
    return v == (id)[NSNull null] ? t : v;
}
static id<MTLTexture> texture_swizzled(id<MTLTexture> t, MTLTextureType want, uint16_t sw) {
    if (!t || sw == 0x5432) return texture_as(t, want);
    pthread_mutex_lock(&g_view_lock);
    NSMutableDictionary *per = views_for(t);
    pthread_mutex_unlock(&g_view_lock);
    NSNumber *key = @(1ull << 40 | (uint64_t)want << 16 | sw);
    id<MTLTexture> v = per[key];
    if (v) return v == (id)[NSNull null] ? nil : v;
    NSUInteger slices = t.arrayLength * (t.textureType == MTLTextureTypeCube || t.textureType == MTLTextureTypeCubeArray ? 6 : 1);
    MTLTextureType type = want;
    if ((want == MTLTextureTypeCube && slices < 6) || (want == MTLTextureTypeCubeArray && slices % 6) || t.textureType == MTLTextureType3D ||
        t.sampleCount > 1)
        type = t.textureType;
    MTLTextureSwizzleChannels ch = MTLTextureSwizzleChannelsMake((MTLTextureSwizzle)(sw & 15), (MTLTextureSwizzle)(sw >> 4 & 15),
                                                                 (MTLTextureSwizzle)(sw >> 8 & 15), (MTLTextureSwizzle)(sw >> 12 & 15));
    v = [t newTextureViewWithPixelFormat:t.pixelFormat textureType:type levels:NSMakeRange(0, t.mipmapLevelCount)
                                  slices:NSMakeRange(0, type == MTLTextureType2D ? 1 : type == MTLTextureTypeCube ? 6 : slices) swizzle:ch];
    per[key] = v ?: (id)[NSNull null];
    return v;
}

// Zeroed, writable stand-in for buffers we cannot resolve yet (driver cbuf 0, storage buffers whose
// address lives in driver cbuf 0): shaders read zeros and write harmlessly instead of faulting the GPU.
static id<MTLBuffer> dummy_buffer(void) {
    static id<MTLBuffer> b;
    if (!b) b = [g_dev newBufferWithLength:1 << 20 options:MTLResourceStorageModeShared];
    return b;
}

// Upload arena for constant buffers that can't be bound in place. Chunks are 8 MB with 64 KB of
// slack at the end (the translated shaders declare every cbuf as 64 KB, so reads past the copied
// data stay inside the chunk). A submit takes chunks from the free list; its completion returns them.
enum { ARENA_CHUNK = 8 << 20, ARENA_SLACK = 0x10000, ARENA_KEEP_MAX = 32 };
// Spare chunks kept after a command buffer completes: adaptive. A fixed 4 made the phone allocate (and zero) several
// new 8 MB shared buffers every frame (it uses ~11): +1 per miss, -1 after 300 frames without one.
static int g_arena_keep = 8;
static uint64_t g_arena_miss, g_arena_miss_stat;
static pthread_mutex_t g_arena_lock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableArray<id<MTLBuffer>> *g_arena_free;
static NSMutableArray<id<MTLBuffer>> *A_used;     // chunks used by the command buffer being built
static id<MTLBuffer> A_buf;
static NSUInteger A_off;

static id<MTLBuffer> arena_copy(const void *src, size_t n, NSUInteger *off) {
    n = MIN(n, (size_t)ARENA_SLACK);
    if (!A_buf || A_off + n > ARENA_CHUNK - ARENA_SLACK) {
        pthread_mutex_lock(&g_arena_lock);
        A_buf = g_arena_free.lastObject;
        if (A_buf) [g_arena_free removeLastObject];
        pthread_mutex_unlock(&g_arena_lock);
        if (!A_buf) {
            A_buf = [g_dev newBufferWithLength:ARENA_CHUNK options:MTLResourceStorageModeShared];
            g_arena_miss++, g_arena_miss_stat++;
            if (g_arena_keep < ARENA_KEEP_MAX) g_arena_keep++;
        }
        [A_used addObject:A_buf];
        A_off = 0;
    }
    *off = A_off;
    memcpy((uint8_t *)A_buf.contents + A_off, src, n);
    A_off = (A_off + n + 255) & ~(NSUInteger)255;   // Metal: constant buffer offsets 256-aligned on macOS
    return A_buf;
}

// Zero-padded copy of a vertex stream: the bound `size` bytes, then zeros up to `need` (see validate_draw).
static id<MTLBuffer> arena_vertex_pad(const void *src, size_t size, size_t need, NSUInteger *off) {
    if (!A_buf || A_off + need > ARENA_CHUNK - ARENA_SLACK) {
        pthread_mutex_lock(&g_arena_lock);
        A_buf = g_arena_free.lastObject;
        if (A_buf) [g_arena_free removeLastObject];
        pthread_mutex_unlock(&g_arena_lock);
        if (!A_buf) {
            A_buf = [g_dev newBufferWithLength:ARENA_CHUNK options:MTLResourceStorageModeShared];
            g_arena_miss++, g_arena_miss_stat++;
            if (g_arena_keep < ARENA_KEEP_MAX) g_arena_keep++;
        }
        [A_used addObject:A_buf];
        A_off = 0;
    }
    *off = A_off;
    memcpy((uint8_t *)A_buf.contents + A_off, src, size);
    memset((uint8_t *)A_buf.contents + A_off + size, 0, need - size);
    A_off = (A_off + need + 255) & ~(NSUInteger)255;
    return A_buf;
}

// ---- storage buffers ----------------------------------------------------------------------
// The translated shader names each storage buffer by the driver-cbuf-0 word that holds its address
// (JSON cbOffset). NVN fills driver cbuf 0 itself, so the layout is inferred from the game:
//   graphics: word 68 + 64 * Maxwell stage (VS 0, FS 4) + 4 * NVN index (all 5 VS use 68, all FS 324)
//   compute:  see cs_ssbo_index; uniform buffers 5+ are read this way too (index 16 + UBO index here).
// NVN stages: 0 vertex, 1 fragment, ... 5 compute.
// Accesses are clamped to the bound NVN size (or the pool end if the bind has no size). Particle shaders
// bind 0x10-byte buffers and index by thread, but threads past the particle count exit early.
static int cs_ssbo_index(int cboff);
static int ssbo_index(int stage, int cboff) {
    if (stage == 5) return cs_ssbo_index(cboff);
    int ms = stage == 0 ? 0 : stage == 1 ? 4 : -1;
    int w = cboff - 68 - 64 * ms;
    return ms < 0 || w < 0 || w % 4 || w / 4 >= 16 ? -1 : w / 4;
}
static uint64_t gpu_avail(uint64_t gpu);
// Bound range of the shader's i-th storage buffer: 0 if the address is unknown or not inside one pool.
// *size = NVN size, *limit = bytes to the end of the pool.
static int ssbo_range(int stage, const NxShader *sh, int i, uint64_t *addr, uint64_t *size, uint64_t *limit) {
    int idx = ssbo_index(stage, sh->sb_cboff[i]);
    if (idx < 0 || idx >= 32) return 0;
    const OpBuf *b = idx < 16 ? &S.ssbo[stage][idx] : &S.ubo[stage][idx - 16];
    uint64_t avail = gpu_avail(b->addr);
    if (!b->addr || avail < 4 || b->addr % 4) return 0;
    *addr = b->addr, *size = b->size, *limit = MIN(avail, 0xFFFFFFFCull);
    return 1;
}
// Words of each storage-buffer binding (16 + k) for the clamp mslfix.py puts on every access, plus the
// buffers themselves. Unresolved ones get the zeroed dummy (callers reject such draws/dispatches first).
static void ssbo_bind(int stage, const NxShader *sh, void (^set)(id<MTLBuffer>, NSUInteger, int), void (^set_words)(const uint32_t *, size_t)) {
    if (!sh->nsb) return;
    uint32_t words[16];
    for (int k = 0; k < 16; k++) words[k] = (uint32_t)(dummy_buffer().length / 4);
    for (int i = 0; i < sh->nsb; i++) {
        uint64_t addr, size, limit;
        NSUInteger off = 0;
        id<MTLBuffer> b = ssbo_range(stage, sh, i, &addr, &size, &limit) ? buf_for(addr, &off) : nil;
        int k = sh->sb_binding[i] - 16;
        // Clamp to the bound NVN size (the pool end when unsized): clamping only to the pool end let the
        // particle shaders write past their buffers into neighbouring vertex data (exploded geometry).
        if (b && k >= 0 && k < 16) words[k] = (uint32_t)(MIN(MIN(size ? size : limit, limit), b.length - off) / 4);
        else b = dummy_buffer(), off = 0;
        set(b, off, sh->sb_binding[i]);
    }
    set_words(words, sizeof words);
}

// UpdateUniformBuffer is ordered with the draws on the GPU, but we apply it to pool memory at encode
// time and the GPU reads that memory later: every draw in the command buffer would see the last
// update (per-draw matrices -> geometry in the wrong place). So buffer ranges the game ever updates
// are remembered, and binds that overlap one get a snapshot from the upload arena (the memory as of
// that point in the command stream).
enum { UPD_MAX = 1024 };
static struct { uint64_t lo, hi; } g_upd[UPD_MAX];
static int g_nupd;
static uint64_t g_stats_snap, g_stats_snap_reused;
static uint64_t g_cbcopy[3], g_cbcopy_bytes;   // cbuf arena copies: [0] pool end < 64 KB away, [1] offset not 256-aligned, [2] both
static uint64_t g_upd_seq;   // buffer writes applied at encode time (snapshot reuse in bind_stage)
static void upd_note(uint64_t addr, uint64_t size) {
    g_upd_seq++;
    uint64_t hi = addr + (size ? size : 0x10000);
    for (int i = 0; i < g_nupd; i++)
        if (g_upd[i].lo == addr) { if (hi > g_upd[i].hi) g_upd[i].hi = hi; return; }
    if (g_nupd < UPD_MAX) g_upd[g_nupd].lo = addr, g_upd[g_nupd++].hi = hi;
}
static int upd_overlaps(uint64_t addr, uint64_t size) {
    uint64_t hi = addr + (size ? size : 0x10000);
    for (int i = 0; i < g_nupd; i++)
        if (addr < g_upd[i].hi && g_upd[i].lo < hi) return 1;
    return 0;
}

// NXRT_UBOCOPY=1: snapshot every constant-buffer bind at encode time (tests whether the CPU rewrites
// uniform memory before the GPU reads it).
static int ubo_copy_all(void) {
    static int on = -1;
    if (on < 0) on = getenv("NXRT_UBOCOPY") && atoi(getenv("NXRT_UBOCOPY"));
    return on;
}

// The NVN texture and sampler bound for a shader's i-th texture (bindless handle via BindTexture(s)).
static const void *stage_texture_sw(int stage, __unsafe_unretained const NxShader *sh, int i, NxSamplerState *ss, int *have_smp, uint16_t *view_sw);
static const void *resolve_handle(uint64_t h, NxSamplerState *ss, int *have_smp, uint16_t *view_sw);
static __thread int g_view_fmt;   // view format of the last resolve_handle (0 = the texture's own)
static const void *stage_texture(int stage, __unsafe_unretained const NxShader *sh, int i, NxSamplerState *ss, int *have_smp) {
    uint16_t sw;
    return stage_texture_sw(stage, sh, i, ss, have_smp, &sw);
}
// Per-draw memo of resolved texture handles (BOTW): a draw resolves each of its textures twice (detect_feedback,
// bind_stage), each under g_pool_lock, and its bindings don't change in between. g_resolve_serial moves per draw
// (draw_body) and dispatch (bind_stage with a compute encoder); all of it runs under g_exec_lock. NXRT_RESOLVE_MEMO=0 off.
static uint64_t g_resolve_serial = 1;
static const void *stage_texture_sw_raw(int stage, __unsafe_unretained const NxShader *sh, int i, NxSamplerState *ss, int *have_smp, uint16_t *view_sw);
static const void *stage_texture_sw(int stage, __unsafe_unretained const NxShader *sh, int i, NxSamplerState *ss, int *have_smp, uint16_t *view_sw) {
    enum { RM_TEX = 32 };
    static struct { uint64_t serial; __unsafe_unretained const NxShader *sh; const void *tex; NxSamplerState ss; int have, view_fmt; uint16_t sw; } memo[6][RM_TEX];
    static int on = -1;
    if (on < 0) on = !ENV("NXRT_RESOLVE_MEMO") || atoi(ENV("NXRT_RESOLVE_MEMO"));
    if (!on || stage < 0 || stage >= 6 || i < 0 || i >= RM_TEX) return stage_texture_sw_raw(stage, sh, i, ss, have_smp, view_sw);
    __typeof__(&memo[0][0]) m = &memo[stage][i];
    if (m->serial == g_resolve_serial && m->sh == sh) {
        if (m->have) *ss = m->ss;
        *have_smp = m->have, *view_sw = m->sw, g_view_fmt = m->view_fmt;
        return m->tex;
    }
    const void *tex = stage_texture_sw_raw(stage, sh, i, ss, have_smp, view_sw);
    m->serial = g_resolve_serial, m->sh = sh, m->tex = tex, m->have = *have_smp, m->sw = *view_sw, m->view_fmt = g_view_fmt;
    if (*have_smp) m->ss = *ss;
    return tex;
}
static const void *stage_texture_sw_raw(int stage, __unsafe_unretained const NxShader *sh, int i, NxSamplerState *ss, int *have_smp, uint16_t *view_sw) {
    int idx = (sh->tex_handle[i] - 8) / 2;
    g_view_fmt = 0;
    *have_smp = 0;
    *view_sw = 0x5432;
    uint64_t h;
    if (sh->tex_cbuf[i] != -1) {
        // Bindless: the handle is a 32-bit word in a uniform buffer (cbuf slot >= 3 = UBO index slot - 3),
        // at word offset tex_handle (Ryujinx cbuf operands count in words). Same packing as bound handles.
        int slot = sh->tex_cbuf[i];
        if (slot < 3 || slot - 3 >= 16) return NULL;
        const OpBuf *u = &S.ubo[stage][slot - 3];
        uint64_t off = (uint64_t)sh->tex_handle[i] * 4, av = 0;
        if (!u->addr || (u->size && off + 4 > u->size)) return NULL;
        const uint8_t *m = nx_nvn_gpu_to_host(u->addr + off, &av);
        if (!m || av < 4) return NULL;
        h = *(const uint32_t *)m;
        static int peek_on = -1;
        if (peek_on < 0) peek_on = getenv("NXRT_ARRAYPEEK") != NULL;
        if (sh->tex_handle[i] == 0 && peek_on) {
            // audit: cbuf texture arrays (BindlessToArray; element k = word 2k). Log the UBO's 256-byte
            // records and the texture ids at the handle offsets the shaders use.
            static int peeks;
            if (peeks++ < 6) {
                nx_log("arraypeek: shader %s stage %d slot %d ubo size 0x%llx avail 0x%llx", sh->name.UTF8String,
                       stage, slot, (unsigned long long)u->size, (unsigned long long)av);
                static const int offs[] = {224, 264, 272, 280, 288, 296, 304, 312};
                uint64_t n = MIN(u->size ? u->size : av, av) / 256;
                for (uint64_t k = 0; k < n && k < 64; k++) {
                    char line[256]; int p = 0;
                    for (int q = 0; q < 8; q++) {
                        uint32_t w = *(const uint32_t *)(m + k * 256 + offs[q]);
                        p += snprintf(line + p, sizeof line - p, " +%d=%x/%x", offs[q], w & 0xFFFFF, w >> 20);
                    }
                    nx_log("arraypeek:  rec %llu%s", (unsigned long long)k, line);
                }
            }
        }
    } else {
        if (idx < 0 || idx >= 64) return NULL;
        h = S.tex_def[stage][idx] ? *S.tex_def[stage][idx] : S.tex[stage][idx];
    }
    return resolve_handle(h, ss, have_smp, view_sw);
}
// A packed texture handle (texture id 20 bits, sampler id 12 bits) -> NVN texture and sampler state.
static const void *resolve_handle(uint64_t h, NxSamplerState *ss, int *have_smp, uint16_t *view_sw) {
    uint32_t tid = h & 0xFFFFF, sid = (h >> 20) & 0xFFF;
    const void *tex = NULL;
    *have_smp = 0;
    *view_sw = 0x5432;
    g_view_fmt = 0;
    pthread_mutex_lock(&g_pool_lock);
    if (h && (int)tid < g_ntex) {
        tex = g_texslots[tid].tex;
        if (g_texslots[tid].has_view && g_texslots[tid].view.swizzle) *view_sw = g_texslots[tid].view.swizzle;
        g_view_fmt = g_texslots[tid].has_view && (g_texslots[tid].view.set & 8) ? g_texslots[tid].view.format : 0;
    }
    if (h && (int)sid < g_nsmp && ss) *ss = g_smpslots[sid], *have_smp = 1;
    pthread_mutex_unlock(&g_pool_lock);
    return tex;
}

// Render-target feedback: the game samples a texture that is also attached to the current pass (the
// tone map and FXAA read and write the HDR target: same-pixel read-modify-write, fine on Maxwell).
// In one Metal pass the sampled memory is stale (the pass's earlier draws are still in tile memory),
// so before such a draw the pass is ended (stored), the texture copied, and the copy is sampled.
static const void *g_fb_from[8];
static id<MTLTexture> g_fb_to[8];
static int g_nfb;
static uint64_t g_stats_feedback;
static uint64_t g_barrier_epoch;            // executed nvnCommandBufferBarrier calls
static id<MTLTexture> feedback_copy(id<MTLTexture> t) {
    pthread_mutex_lock(&g_view_lock);
    if (!g_fb_copies) g_fb_copies = ptr_map();
    id<MTLTexture> c = [g_fb_copies objectForKey:t];
    pthread_mutex_unlock(&g_view_lock);
    int fresh = !c;
    if (!c) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor new];
        d.textureType = t.textureType;
        d.pixelFormat = t.pixelFormat;
        d.width = t.width, d.height = t.height, d.depth = t.depth;
        d.mipmapLevelCount = t.mipmapLevelCount;
        d.arrayLength = t.arrayLength;
        d.sampleCount = t.sampleCount;
        d.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        d.storageMode = MTLStorageModePrivate;
        c = [g_dev newTextureWithDescriptor:d];
        if (!c) return nil;
        pthread_mutex_lock(&g_view_lock);
        [g_fb_copies setObject:c forKey:t];
        pthread_mutex_unlock(&g_view_lock);
    }
    if (dbg()) {
        hist("feedback copy: w*10000+h", (long)t.width * 10000 + (long)t.height);
        hist("feedback copy: levels*1000+slices*10+type", (long)t.mipmapLevelCount * 1000 + (long)t.arrayLength * 10 + (long)t.textureType);
    }
    pthread_mutex_lock(&g_view_lock);
    NSMutableIndexSet *dirty = fresh ? nil : [g_subdirty objectForKey:t];
    [g_subdirty removeObjectForKey:t];
    pthread_mutex_unlock(&g_view_lock);
    if (!fresh && !dirty.count) return c;   // nothing written since the last refresh
    id<MTLBlitCommandEncoder> b = prof_blit(1);
    if (fresh || [dirty containsIndex:SUB_ALL]) [b copyFromTexture:t toTexture:c];
    else
        [dirty enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
            NSUInteger lv = idx >> 16, sl = idx & 0xFFFF;
            NSUInteger slices = t.arrayLength * (t.textureType == MTLTextureTypeCube || t.textureType == MTLTextureTypeCubeArray ? 6 : 1);
            if (lv < t.mipmapLevelCount && sl < slices)
                [b copyFromTexture:t sourceSlice:sl sourceLevel:lv toTexture:c destinationSlice:sl destinationLevel:lv sliceCount:1 levelCount:1];
        }];
    [b endEncoding];
    return c;
}
// Fills g_fb_from with the sampled textures that are attachments of the current pass (CPU only).
// NXRT_FBLOG=1 logs the first hits.
static void detect_feedback(NxShader *const *sh, const int *stages, int n, const NxStage *pfs) {
    g_nfb = 0;
    const void *att[9];
    int natt = 0;
    for (int i = 0; i < S.rt.n && i < 8; i++)
        if (S.rt.color[i]) att[natt++] = S.rt.color[i];
    if (S.rt.depth) att[natt++] = S.rt.depth;
    for (int k = 0; k < n; k++) {
        if (!sh[k]) continue;
        for (int i = 0; i < sh[k]->ntex && g_nfb < 8; i++) {
            NxSamplerState ss;
            int have;
            const void *tex = stage_texture(stages[k], sh[k], i, &ss, &have);
            int hit = 0;
            for (int a = 0; a < natt && tex; a++) hit |= att[a] == tex;
            for (int f = 0; f < g_nfb; f++) hit &= g_fb_from[f] != tex;
            if (hit) {
                g_fb_from[g_nfb++] = tex;
                static int fblog = -1, nseen;
                static uint64_t seen[256];
                if (fblog < 0) fblog = getenv("NXRT_FBLOG") != NULL;
                uint64_t key = (stages[k] && pfs ? pfs->hash : 0) ^ (uint64_t)(uintptr_t)tex * 0x9E3779B97F4A7C15ull;
                int fresh = 1;
                for (int q = 0; q < nseen; q++) fresh &= seen[q] != key;
                if (fblog && fresh && nseen < 256) {
                    seen[nseen++] = key;
                    extern volatile int g_gfx_frame;
                    int which = -1;
                    for (int a = 0; a < S.rt.n && a < 8; a++)
                        if (S.rt.color[a] == tex) which = a;
                    NxTexDesc td = {0};
                    nx_nvn_texture_desc(tex, &td);
                    nx_log("feedback: frame %d %s %016llx binding %d samples %s %p (%dx%d fmt %d); ds test %d write %d func %d, blend %#x",
                           g_gfx_frame, stages[k] ? "fs" : "vs", stages[k] && pfs ? (unsigned long long)pfs->hash : 0ull, sh[k]->tex_binding[i],
                           which >= 0 ? "color attachment" : "depth attachment", tex, td.w, td.h, td.format, S.ds.dt, S.ds.dw, S.ds.df,
                           S.color.blend_mask);
                }
            }
        }
    }
}
// Called with the pass open, before any state is set on E; may end and reopen the pass.
// A copy stays valid until the next barrier or frame: without a barrier Maxwell doesn't guarantee that
// sampling sees the draws since (texture cache), so reusing it is faithful, and it avoids ending the
// pass (tile store + reload) and a full-texture copy per draw. NXRT_FB_ALWAYS=1: copy for every draw.
static uint64_t g_stats_fb_copies, g_stats_fb_views;
// View of levels [0, lv), all slices, of a 2D, 2D array, cube or cube array texture (cached per texture and
// level count; dropped with it).
static id<MTLTexture> mip_view(id<MTLTexture> t, int lv) {
    NSNumber *key = @(3ull << 40 | (unsigned)lv);
    pthread_mutex_lock(&g_view_lock);
    NSMutableDictionary *per = views_for(t);
    id<MTLTexture> v = per[key];
    pthread_mutex_unlock(&g_view_lock);
    if (v) return v;
    NSUInteger slices = t.arrayLength * (t.textureType == MTLTextureTypeCube || t.textureType == MTLTextureTypeCubeArray ? 6 : 1);
    v = [t newTextureViewWithPixelFormat:t.pixelFormat textureType:t.textureType levels:NSMakeRange(0, lv) slices:NSMakeRange(0, slices)];
    if (!v) return nil;
    pthread_mutex_lock(&g_view_lock);
    per[key] = v;
    pthread_mutex_unlock(&g_view_lock);
    return v;
}
static void passlog_event(const char *what, id<MTLTexture> a, id<MTLTexture> b);
// A feedback source with a pending clear (the copy must see the cleared contents: open the pass first).
// Other pending clears don't matter to the copy (a depth clear left a 0-draw pass of every 1080p target).
// NXRT_FB_CLEARWAIT=1: old (any pending clear).
static int fb_pending_clear(void) {
    static int old = -1;
    if (old < 0) old = getenv("NXRT_FB_CLEARWAIT") != NULL;
    if (old) return pend_clear_color_mask || pend_clear_depth || pend_clear_stencil;
    if (!pend_clear_color_mask && !pend_clear_depth && !pend_clear_stencil) return 0;
    for (int f = 0; f < g_nfb; f++) {   // by root Metal texture (aliases of one storage share it)
        id<MTLTexture> src = tex_mtl_cached(g_fb_from[f]);
        while (src.parentTexture) src = src.parentTexture;
        for (int i = 0; i < S.rt.n && i < 8; i++) {
            if (!(pend_clear_color_mask & 1 << i)) continue;
            id<MTLTexture> t = tex_mtl_cached(S.rt.color[i]);
            while (t.parentTexture) t = t.parentTexture;
            if (!src || src == t) return 1;
        }
        if (pend_clear_depth || pend_clear_stencil) {
            id<MTLTexture> t = tex_mtl_cached(S.rt.depth);
            while (t.parentTexture) t = t.parentTexture;
            if (!src || src == t) return 1;
        }
    }
    return 0;
}
static void resolve_feedback(void) {
    if (!g_nfb) return;
    static int always = -1;
    if (always < 0) always = getenv("NXRT_FB_ALWAYS") != NULL;
    extern volatile int g_gfx_frame;
    uint64_t epoch = (uint64_t)g_gfx_frame << 32 | (uint32_t)g_barrier_epoch;
    int need = 0;
    for (int f = 0; f < g_nfb; f++) {
        id<MTLTexture> t = tex_mtl_cached(g_fb_from[f]);
        // Rendering into mip L > 0 while sampling the same texture (downsample chains): not feedback on
        // the same subresource. Sample a view of levels [0, L) instead of copying (Metal allows reading
        // and writing different mip levels of one texture through views). Arrays and cube arrays too:
        // their mip chains (environment cubes, 2D arrays) were ~30 of the island's 37 copies per frame.
        int lv = -1;
        for (int a = 0; a < S.rt.n && a < 8; a++)
            if (S.rt.color[a] == g_fb_from[f]) lv = S.rt.level[a];
        MTLTextureType ty = t ? t.textureType : MTLTextureType2D;
        if (!always && t && lv > 0 && lv < (int)t.mipmapLevelCount &&
            (ty == MTLTextureType2D || ty == MTLTextureType2DArray || ty == MTLTextureTypeCube || ty == MTLTextureTypeCubeArray)) {
            g_fb_to[f] = mip_view(t, lv);
            if (g_fb_to[f]) {
                g_stats_fb_views++;
                continue;
            }
        }
        pthread_mutex_lock(&g_view_lock);
        id<MTLTexture> c = t ? [g_fb_copies objectForKey:t] : nil;
        NSNumber *at = t ? [g_fb_epochs objectForKey:t] : nil;
        pthread_mutex_unlock(&g_view_lock);
        if (!always && c && at && at.unsignedLongLongValue == epoch) g_fb_to[f] = c;
        else g_fb_to[f] = nil, need = 1;
    }
    g_stats_feedback++;
    if (!need) return;
    end_pass_why(PE_FEEDBACK);
    for (int f = 0; f < g_nfb; f++) {
        if (g_fb_to[f]) continue;
        id<MTLTexture> t = tex_mtl_cached(g_fb_from[f]);
        if (dbg()) {
            int lv = -1, ly = -1;
            for (int a = 0; a < S.rt.n && a < 8; a++)
                if (S.rt.color[a] == g_fb_from[f]) lv = S.rt.level[a], ly = S.rt.layer[a];
            hist("feedback copy: type*1000000+rt level*1000+rt layer", (long)t.textureType * 1000000 + lv * 1000 + ly);
        }
        g_fb_to[f] = feedback_copy(t);
        passlog_event("feedback copy", t, g_fb_to[f]);
        g_stats_fb_copies++;
        pthread_mutex_lock(&g_view_lock);
        if (!g_fb_epochs) g_fb_epochs = ptr_map();
        if (t) [g_fb_epochs setObject:@(epoch) forKey:t];
        pthread_mutex_unlock(&g_view_lock);
    }
    begin_pass();
}

// Keyed by (texture, view swizzle, declared type), not by binding slot: consecutive meshes bind different
// textures to the same slot, so a per-slot cache missed on most draws (~18% of encode in gfx_texture_mtl).
// TexBindCache and g_bindcache are declared above texpool_register (targeted invalidation).

// Shadow of what is bound on the current render encoder (reset by begin_pass with each new encoder):
// binds that would set the same object again are skipped, and a buffer that only moves gets
// set*BufferOffset. [0] vertex, [1] fragment. Slots filled by setBytes hold a token (constant data) or
// NULL (unknown: the next bind always goes through). The command buffer retains bound objects, so a
// pointer can't be reused by a new object while it is in the shadow.
enum { EB_BUF = 31, EB_TEX = 128, EB_SMP = 16 };
static struct { const void *buf[EB_BUF]; NSUInteger off[EB_BUF]; const void *tex[EB_TEX], *smp[EB_SMP]; } g_eb[2];
static const void *g_eb_pso, *g_eb_dss;
static void eb_reset(void) { memset(g_eb, 0, sizeof g_eb), g_eb_pso = g_eb_dss = NULL; }
static void eb_buffer(int fs, __unsafe_unretained id<MTLBuffer> b, NSUInteger off, int i) {   // (unretained: the caller holds b)
    if (i >= 0 && i < EB_BUF) {
        if (g_eb[fs].buf[i] == (__bridge const void *)b) {
            if (g_eb[fs].off[i] == off) return;
            g_eb[fs].off[i] = off;
            if (fs) [E setFragmentBufferOffset:off atIndex:i];
            else [E setVertexBufferOffset:off atIndex:i];
            return;
        }
        g_eb[fs].buf[i] = (__bridge const void *)b, g_eb[fs].off[i] = off;
    }
    if (fs) [E setFragmentBuffer:b offset:off atIndex:i];
    else [E setVertexBuffer:b offset:off atIndex:i];
}
static void eb_bytes(int fs, const void *p, size_t n, int i, const void *token) {   // token: constant data, or NULL
    if (i >= 0 && i < EB_BUF) {
        if (token && g_eb[fs].buf[i] == token) return;
        g_eb[fs].buf[i] = token;
    }
    if (fs) [E setFragmentBytes:p length:n atIndex:i];
    else [E setVertexBytes:p length:n atIndex:i];
}
static void eb_texture(int fs, __unsafe_unretained id<MTLTexture> t, int i) {
    if (g_passlog_on && t) {
        id<MTLTexture> r = t;
        while (r.parentTexture) r = r.parentTexture;
        int k = 0;
        while (k < g_pass_nsmp && g_pass_smp[k] != (__bridge const void *)r) k++;
        if (k == g_pass_nsmp && k < 512) g_pass_smp[g_pass_nsmp++] = (__bridge const void *)r;
    }
    if (i >= 0 && i < EB_TEX) {
        if (g_eb[fs].tex[i] == (__bridge const void *)t) return;
        g_eb[fs].tex[i] = (__bridge const void *)t;
    }
    if (fs) [E setFragmentTexture:t atIndex:i];
    else [E setVertexTexture:t atIndex:i];
}
static void eb_sampler(int fs, __unsafe_unretained id<MTLSamplerState> smp, int i) {
    if (i >= 0 && i < EB_SMP) {
        if (g_eb[fs].smp[i] == (__bridge const void *)smp) return;
        g_eb[fs].smp[i] = (__bridge const void *)smp;
    }
    if (fs) [E setFragmentSamplerState:smp atIndex:i];
    else [E setVertexSamplerState:smp atIndex:i];
}

// Binds a stage's resources: to the render encoder E (stage 0 vertex, 1 fragment), or to compute
// encoder ce (stage 5).
#define SET_BUFFER(b, off, i) (ce ? [ce setBuffer:(b) offset:(off) atIndex:(i)] : eb_buffer(!vs, (b), (off), (i)))
#define SET_BYTES(p, n, i) (ce ? [ce setBytes:(p) length:(n) atIndex:(i)] : eb_bytes(!vs, (p), (n), (i), NULL))
static void bind_stage(int stage, __unsafe_unretained NxShader *sh, const NxStage *pst, __unsafe_unretained id<MTLComputeCommandEncoder> ce) {
    if (ce) g_resolve_serial++;   // a dispatch: its own bindings (stage_texture_sw's memo)
    BOOL vs = stage == 0;
    static float support[1392 / 4];
    static int support_init;
    if (!support_init) {
        support_init = 1;
        for (int i = 0; i < 73; i++) support[(16 + 128 + 48) / 4 + i * 4] = 1.0f;   // render_scale[i] = 1
    }
    if (sh->uses_support) {   // constant after the first fill: bound once per encoder and stage
        // From a buffer of its own, not setBytes: ~190 passes x 2 stages x 1.4 KB a frame of setBytes data made the
        // driver allocate new encoder memory (a kernel call) at pass ends.
        static __strong id<MTLBuffer> supbuf;
        if (!supbuf) supbuf = [g_dev newBufferWithBytes:support length:sizeof support options:MTLResourceStorageModeShared];
        if (ce) [ce setBuffer:supbuf offset:0 atIndex:0];
        else eb_buffer(!vs, supbuf, 0, 0);
    }
    for (int i = 0; i < sh->ncb; i++) {
        int slot = sh->cb_slot[i];
        uint64_t addr = 0, size = 0;
        if (slot == 0 && ce) {
            // Compute shaders read driver cbuf 0 directly (storage-buffer addresses as 64-bit values):
            // a copy with each storage buffer's {address, size} at its cbOffset, zeros elsewhere.
            uint32_t d0[256] = {0};
            for (int k = 0; k < sh->nsb; k++) {
                uint64_t a, n, lim;
                int w = sh->sb_cboff[k];
                if (w >= 0 && w + 2 < 256 && ssbo_range(stage, sh, k, &a, &n, &lim)) d0[w] = (uint32_t)a, d0[w + 1] = (uint32_t)(a >> 32), d0[w + 2] = (uint32_t)n;
            }
            NSUInteger off;
            id<MTLBuffer> b = arena_copy(d0, sizeof d0, &off);
            SET_BUFFER(b, off, sh->cb_binding[i]);
            continue;
        }
        if (slot == 1 && pst) addr = pst->c1_addr, size = pst->c1_size;
        static uint64_t c1peek = 1;   // NXRT_C1PEEK=<shader hash>: log that shader's c1 size and first 64 words once
        if (c1peek == 1) c1peek = getenv("NXRT_C1PEEK") ? strtoull(getenv("NXRT_C1PEEK"), NULL, 16) : 0;
        if (c1peek && slot == 1 && pst && pst->hash == c1peek) {
            c1peek = 0;
            uint64_t av = 0;
            const uint32_t *w = addr ? nx_nvn_gpu_to_host(addr, &av) : NULL;
            nx_log("c1peek: %016llx c1 addr %#llx size %#llx (pool avail %#llx)", (unsigned long long)pst->hash, (unsigned long long)addr,
                   (unsigned long long)size, (unsigned long long)av);
            for (int q = 0; w && q < 64 && (q + 8) * 4 <= (int)av; q += 8)
                nx_log("c1peek:   w%02d: %d %d %d %d %d %d %d %d", q, w[q], w[q + 1], w[q + 2], w[q + 3], w[q + 4], w[q + 5], w[q + 6], w[q + 7]);
        }
        else if (slot >= 3 && slot - 3 < 16) addr = S.ubo[stage][slot - 3].addr, size = S.ubo[stage][slot - 3].size;
        NSUInteger off = 0;
        // Unretained (ARC traffic was ~1/4 of encode): pool buffers live in g_poolbufs, arena chunks in A_used
        // until the command buffer completes, the dummy for good.
        __unsafe_unretained id<MTLBuffer> b = addr ? buf_for(addr, &off) : nil;
        if (!b) b = dummy_buffer(), off = 0;
        else if (upd_overlaps(addr, size) || ubo_copy_all()) {
            // The same range again with no buffer write since, in the same command buffer: the last snapshot still
            // holds that memory (from BOTW). NXRT_SNAPMEMO=0 off.
            static struct { uint64_t addr, n, seq, ring; __unsafe_unretained id<MTLBuffer> b; NSUInteger off; } snap[16];
            static int memo = -1;
            if (memo < 0) memo = !ENV("NXRT_SNAPMEMO") || atoi(ENV("NXRT_SNAPMEMO"));
            // Only what the shader can read (cbuf_reach, 64 KB when not provable), not the whole bound range.
            size_t n = MIN(MIN(size ? size : 0x10000, b.length - off), (size_t)MAX(sh->cb_reach[i], 256));
            unsigned si = (unsigned)((addr >> 4) ^ (addr >> 12) ^ n) & 15;
            if (memo && !ubo_copy_all() && snap[si].b && snap[si].addr == addr && snap[si].n == n && snap[si].seq == g_upd_seq &&
                snap[si].ring == g_ring_n) {
                b = snap[si].b, off = snap[si].off;
                g_stats_snap_reused++;
            } else {
                b = arena_copy((const uint8_t *)b.contents + off, n, &off);
                snap[si].addr = addr, snap[si].n = n, snap[si].seq = g_upd_seq, snap[si].ring = g_ring_n, snap[si].b = b, snap[si].off = off;
            }
            g_stats_snap++;
        } else if (b.length - off < (NSUInteger)sh->cb_reach[i] || off % 256) {
            g_cbcopy[b.length - off < (NSUInteger)sh->cb_reach[i] ? (off % 256 ? 2 : 0) : 1]++, g_cbcopy_bytes += MIN(size ? size : 0x10000, b.length - off);
            // The shader can read past the end of the pool (cbuf_reach; 64 KB when not provable), or
            // Metal wants a 256-aligned offset: bind a copy of the bound range from the upload arena.
            b = arena_copy((const uint8_t *)b.contents + off, MIN(size ? size : 0x10000, b.length - off), &off);
        }
        SET_BUFFER(b, off, sh->cb_binding[i]);
    }
    if (sh->nsb)   // (the blocks cost even when unused)
        ssbo_bind(stage, sh, ^(id<MTLBuffer> b, NSUInteger off, int slot) { SET_BUFFER(b, off, slot); },
                  ^(const uint32_t *w, size_t n) { SET_BYTES(w, n, 15); });
    for (int i = 0; i < sh->ntex; i++) {
        int b = sh->tex_binding[i];
        if (i == sh->arr_i) {
            // Cbuf texture array (mslfix tex_arrays): element k = handle word at byte 8k of the UBO; the
            // shader reads arr[map[k]]. Map the handles at the traced record offsets onto slots 1..n-1
            // (deduplicated by handle; slot 0 = dummy for everything else). One sampler for the array.
            static uint8_t map[8192];
            memset(map, 0, sizeof map);
            id<MTLTexture> slot_tex[128] = {nil};
            uint32_t slot_h[128];
            int nslot = 1, overflow = 0, slots = MIN(sh->arr_slots, 128);
            id<MTLSamplerState> smp = nil;
            int cslot = sh->tex_cbuf[i];
            const OpBuf *u = cslot >= 3 && cslot - 3 < 16 ? &S.ubo[stage][cslot - 3] : NULL;
            uint64_t av = 0;
            const uint8_t *m = u && u->addr ? nx_nvn_gpu_to_host(u->addr, &av) : NULL;
            uint64_t nbytes = m ? MIN(u->size ? u->size : 0x10000, MIN(av, 0x10000)) : 0;
            for (uint64_t k = 0; k < nbytes / 8; k++) {
                uint64_t byte = k * 8;
                if (sh->arr_stride) {
                    int hit = 0;
                    for (int q = 0; q < sh->arr_noffs; q++) hit |= (int)(byte % sh->arr_stride) == sh->arr_offs[q];
                    if (!hit) continue;
                }
                uint32_t h = *(const uint32_t *)(m + byte);
                int s = 0;
                for (int q = 1; q < nslot && !s; q++)
                    if (slot_h[q] == h) s = q;
                if (!s && h) {
                    NxSamplerState ss;
                    int have;
                    uint16_t vsw;
                    const void *tex = resolve_handle(h, &ss, &have, &vsw);
                    id<MTLTexture> mt = gfx_texture_mtl(tex);
                    for (int f = 0; f < g_nfb && !ce; f++)
                        if (g_fb_from[f] == tex && g_fb_to[f]) mt = g_fb_to[f];
                    id<MTLTexture> t = mt ? texture_swizzled(mt, sh->tex_type[i], swizzle_compose(gfx_texture_swizzle(tex), vsw)) : nil;
                    if (t && nslot < slots) {
                        s = nslot++;
                        slot_h[s] = h, slot_tex[s] = t;
                        if (!smp && have) smp = sampler_for(&ss);
                    } else if (t) overflow++;
                }
                map[k] = (uint8_t)s;
            }
            if (dbg()) {
                hist("texarray: slots used per draw", nslot - 1);
                if (overflow) hist("texarray: handles past the slot limit (dummy)", overflow);
            }
            id<MTLTexture> dummy = dummy_texture(sh->tex_type[i]);
            if (!smp) {
                static NxSamplerState def = {1, 1, 7, 7, 7, 0, 0, 0, 0, 1000, 0, 1, {0}};
                smp = sampler_for(&def);
            }
            for (int q = 0; q < slots; q++) {
                id<MTLTexture> t = q < nslot && slot_tex[q] ? slot_tex[q] : dummy;
                if (ce) [ce setTexture:t atIndex:b + q];
                else eb_texture(!vs, t, b + q);
            }
            if (ce) [ce setSamplerState:smp atIndex:b % 16];
            else eb_sampler(!vs, smp, b % 16);
            NSUInteger off;
            id<MTLBuffer> mb = arena_copy(map, sizeof map, &off);
            SET_BUFFER(mb, off, 30);
            continue;
        }
        // Unretained (ARC traffic): a cache hit's view is owned by the bind cache entry, samplers by the sampler
        // table, dummies by their cache; a freshly made view is held by t_hold until it is bound.
        __unsafe_unretained id<MTLTexture> t = nil;
        __unsafe_unretained id<MTLSamplerState> smp = nil;
        id<MTLTexture> t_hold = nil;
        NxSamplerState ss;
        int have_smp;
        uint16_t view_sw;
        const void *tex = stage_texture_sw(stage, sh, i, &ss, &have_smp, &view_sw);
        int view_fmt = g_view_fmt;
        // Per-slot cache of the resolved Metal texture and sampler (resolving every texture of every draw
        // was ~1/3 of encode time). Valid while the texture generation is unchanged: it advances per
        // submit (CPU-written textures are rechecked once per frame) and on texture registration/drops.
        int fb = 0;
        for (int f = 0; f < g_nfb && !ce; f++) fb |= g_fb_from[f] == tex && g_fb_to[f];
        static int nocache = -1;
        if (nocache < 0) nocache = getenv("NXRT_NOBINDCACHE") != NULL;
        TexBindCache *bc = nocache ? NULL
            : &g_bindcache[(((uintptr_t)tex >> 4) * 0x9E3779B97F4A7C15ull ^ view_sw * 0x85EBCA6Bu ^ sh->tex_type[i]) >> 52];
        if (dbg()) hist("texcache: 0 miss, 1 hit, 2 stale generation", !bc || fb ? 0 : bc->gen == g_tex_gen && bc->tex == tex && bc->t ? 1 : bc->tex == tex ? 2 : 0);
        if (bc && !fb && bc->gen == g_tex_gen && bc->tex == tex && bc->view_sw == view_sw && bc->view_fmt == view_fmt && bc->type == sh->tex_type[i] && bc->t) {
            t = bc->t;
            smp = have_smp ? sampler_for(&ss) : nil;
            goto bind_default_smp;
        }
        {
        id<MTLTexture> mt = tex_mtl_cached(tex), base_mt = mt;
        // Old generation only (the per-submit bump: gfx_texture_mtl above still runs once per frame for its LRU
        // mark and re-upload check): the same base texture means the cached view is still the right one.
        if (bc && !fb && bc->gen && bc->tex == tex && bc->base == (uintptr_t)(__bridge void *)mt && bc->view_sw == view_sw &&
            bc->view_fmt == view_fmt && bc->type == sh->tex_type[i] && bc->t && !texgen_all()) {
            bc->gen = g_tex_gen;
            t = bc->t;
            smp = have_smp ? sampler_for(&ss) : nil;
            goto bind_default_smp;
        }
        for (int f = 0; f < g_nfb && !ce; f++)
            if (g_fb_from[f] == tex && g_fb_to[f]) mt = g_fb_to[f];
        mt = format_view(mt, view_fmt);
        t = t_hold = texture_swizzled(mt, sh->tex_type[i], tex ? swizzle_compose(gfx_texture_swizzle(tex), view_sw) : 0x5432);
        if (have_smp) smp = sampler_for(&ss);
        if (dbg()) {   // audit: missing textures and declared-vs-bound type mismatches
            const char *why = !tex ? "audit: texture unresolved (shader handle)" : !mt ? "audit: texture without Metal texture (NVN format)"
                            : !t ? "audit: texture view impossible (declared*100+bound type)" : NULL;
            if (why) {
                NxTexDesc td0 = {0};
                if (tex && !mt) nx_nvn_texture_desc(tex, &td0);
                hist(why, !tex ? (long)sh->tex_handle[i] : !mt ? (long)td0.format : (long)sh->tex_type[i] * 100 + (long)mt.textureType);
            }
            if (mt && t && mt.textureType != sh->tex_type[i]) hist("audit: texture type adapted (declared*100+bound)", (long)sh->tex_type[i] * 100 + (long)mt.textureType);
        }
        if (bc && !fb && t) bc->gen = g_tex_gen, bc->tex = tex, bc->base = (uintptr_t)(__bridge void *)base_mt, bc->view_sw = view_sw, bc->view_fmt = (int16_t)view_fmt, bc->type = sh->tex_type[i], bc->t = t;
        if (!t) t = dummy_texture(sh->tex_type[i]);
        }
    bind_default_smp:
        if (have_smp && (ss.lod_bias != 0 || ss.reduction != 0) && ENV("NXRT_SMPLOG")) {   // who uses what Metal drops
            static uint64_t seen[256];
            uint64_t key = (pst ? pst->hash : 0) * 31 + (uint64_t)i * 7 + (uint64_t)(ss.lod_bias * 100) + (uint64_t)ss.reduction * 1000;
            int k = 0;
            while (k < 256 && seen[k] && seen[k] != key) k++;
            if (k < 256 && !seen[k]) {
                seen[k] = key;
                nx_log("smplog: stage %d shader %016llx texture %d (binding %d): lod bias %.2f reduction %d, texture %lux%lu levels %lu",
                       stage, (unsigned long long)(pst ? pst->hash : 0), i, sh->tex_binding[i], ss.lod_bias, ss.reduction,
                       (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.mipmapLevelCount);
            }
        }
        if (!smp) {
            static NxSamplerState def = {1, 1, 7, 7, 7, 0, 0, 0, 0, 1000, 0, 1, {0}};
            static __strong id<MTLSamplerState> def_smp;
            if (!def_smp) def_smp = sampler_for(&def);
            smp = def_smp;
        }
        {
            extern volatile int g_gfx_frame;
            static int f = -2;
            if (f == -2) f = getenv("NXRT_DEPTHDBG") ? atoi(getenv("NXRT_DEPTHDBG")) : -1;
            static unsigned long long who = 1;    // NXRT_TEXWHO=<nvn texture>: who binds it in the NXRT_DEPTHDBG frame
            if (who == 1) who = getenv("NXRT_TEXWHO") ? strtoull(getenv("NXRT_TEXWHO"), NULL, 16) : 0;
            if (f == g_gfx_frame && who && (uintptr_t)tex == who)
                nx_log("texwho: %s %016llx binding %d (type %lu)", ce ? "cs" : vs ? "vs" : "fs", (unsigned long long)(pst ? pst->hash : 0), b,
                       (unsigned long)sh->tex_type[i]);
            static unsigned long long only = 1;   // NXRT_DEPTHDBG_FS=<fs hash>: every binding of that shader
            if (only == 1) only = getenv("NXRT_DEPTHDBG_FS") ? strtoull(getenv("NXRT_DEPTHDBG_FS"), NULL, 16) : 0;
            if (f == g_gfx_frame && ((only && pst && pst->hash == only) || t.pixelFormat == MTLPixelFormatDepth32Float ||
                                     t.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 || t.pixelFormat == MTLPixelFormatDepth16Unorm))
                nx_log("depthdbg: %s binding %d samples nvn %p metal %p (parent %p) fs %016llx", ce ? "cs" : vs ? "vs" : "fs", b, tex, t,
                       t.parentTexture, (unsigned long long)(pst ? pst->hash : 0));
        }
        if (ce) [ce setTexture:t atIndex:b], [ce setSamplerState:smp atIndex:b % 16];
        else eb_texture(!vs, t, b), eb_sampler(!vs, smp, b % 16);
    }
}
#undef SET_BUFFER
#undef SET_BYTES

// ---- CPU-side draw validation (GPU safety): every check here is something that reads or writes
// outside a resource on the GPU, or that Metal validation rejects. Failing draws are skipped. ----
enum { R_IB_RANGE, R_IB_ALIGN, R_VB_UNBOUND, R_VB_RANGE, R_VB_ALIGN, R_ATTR_STRIDE, R_NEG_VERTEX, R_SLOT_COLLIDE, R_SSBO, R_VB_LIMIT, R_NREASONS };
static const char *const g_reason_name[R_NREASONS] = {
    "index buffer out of range", "index buffer offset misaligned", "attribute stream has no vertex buffer",
    "vertex fetch past buffer end", "vertex buffer offset not 4-aligned", "attribute end past stride",
    "negative vertex index", "buffer slot collision", "storage buffer unresolved", "vertex fetch past bound size (too big to pad)",
};
static uint64_t g_reasons[R_NREASONS], g_checked, g_check_ok, g_with_ssbo;

static int vfmt_size(int f) {
    if (f >= 1 && f <= 48) {
        int comps = (f - 1) / 12 + 1, k = (f - 1) % 12;
        return comps * (k < 4 ? 1 : k < 9 ? 2 : 4);
    }
    return f == 61 || f == 63 || f == 105 ? 4 : 0;
}

// Bytes readable from a GPU address to the end of its pool; 0 if unresolved.
static uint64_t gpu_avail(uint64_t gpu) {
    uint8_t *mem;
    uint64_t size, off;
    if (!gpu || nx_nvn_gpu_pool(gpu, &mem, &size, &off) < 0 || off >= size) return 0;
    return size - off;
}

static int reject(int why, const char *fmt, ...) {
    g_reasons[why]++;
    static int n;
    if (n++ < 24) {
        char msg[512];
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(msg, sizeof msg, fmt, ap);
        va_end(ap);
        nx_log("gfx: draw rejected (%s): %s", g_reason_name[why], msg);
    }
    return 0;
}

static uint64_t vs_hash_for_log;
static void opring_dump(const char *why);
static uint64_t g_vb_need[14];   // per stream: bytes the draw fetches when that is past the bound NVN size, else 0
static uint64_t g_vb_padded;     // draws/streams that needed a zero-padded copy (stats)
// Min/max vertex index of a draw, primitive-restart indices (all ones) excluded. The restart value is
// the type's maximum, so it never lowers the minimum, and the maximum masks it: branch-free loops the
// compiler vectorizes (this scan was ~1/4 of encode time as a per-element switch).
#define INDEX_RANGE(T, R)                                                            \
    {                                                                                \
        const T *p = (const T *)ip;                                                  \
        T mn = (T)R, mx = 0;                                                         \
        for (int i = 0; i < count; i++) {                                            \
            T v = p[i];                                                              \
            mn = v < mn ? v : mn;                                                    \
            T m = v == (T)R ? 0 : v;                                                 \
            mx = m > mx ? m : mx;                                                    \
        }                                                                            \
        *lo = mn, *hi = mx;                                                          \
    }
static void index_range(const uint8_t *ip, int type, int count, uint32_t *lo, uint32_t *hi) {
    if (count <= 0) return;
    if (type == 2) INDEX_RANGE(uint32_t, 0xFFFFFFFFu)
    else if (type == 1) INDEX_RANGE(uint16_t, 0xFFFFu)
    else INDEX_RANGE(uint8_t, 0xFFu)
    // all restart: mn = R, mx = 0 -> lo > hi, handled by the caller (and the old loop gave the same)
}
#undef INDEX_RANGE
static int validate_draw(__unsafe_unretained NxShader *vs, __unsafe_unretained NxShader *fs, const OpDrawElem *de, const OpDrawArrays *da, int instances) {
    g_checked++;
    memset(g_vb_need, 0, sizeof g_vb_need);
    // Highest vertex index the draw fetches.
    int64_t vmin, vmax;
    if (de) {
        int isz = de->type == 2 ? 4 : de->type == 1 ? 2 : 1;
        uint64_t avail = gpu_avail(de->index_addr);
        if ((uint64_t)de->count * isz > avail)
            return reject(R_IB_RANGE, "addr %#llx count %d x %d, %#llx available", (unsigned long long)de->index_addr, de->count,
                          isz, (unsigned long long)avail);
        if (de->index_addr % isz) return reject(R_IB_ALIGN, "addr %#llx size %d", (unsigned long long)de->index_addr, isz);
        uint64_t hav;
        const uint8_t *ip = nx_nvn_gpu_to_host(de->index_addr, &hav);
        uint32_t lo = UINT32_MAX, hi = 0;
        if (ip) index_range(ip, de->type, de->count, &lo, &hi);
        if (lo > hi) lo = hi = 0;
        vmin = (int64_t)lo + de->base_vertex;
        vmax = (int64_t)hi + de->base_vertex;
    } else {
        vmin = da->first;
        vmax = (int64_t)da->first + da->count - 1;
    }
    if (vmin < 0) return reject(R_NEG_VERTEX, "first vertex %lld", (long long)vmin);
    int64_t base_inst = de ? de->base_instance : da->base_instance;

    // Vertex buffer slots: streams at 29 - s, zeros at 30, must not overlap the shader's buffers.
    uint32_t used = 1u << 30 | (vs->uses_support ? 1u : 0);
    for (int i = 0; i < vs->ncb; i++) used |= 1u << vs->cb_binding[i];
    for (int i = 0; i < vs->nsb; i++) used |= 1u << vs->sb_binding[i] | 1u << 15;
    // Storage buffers: every one the MSL uses must resolve to a bound range inside a pool (accesses are
    // clamped to that range by mslfix.py).
    if (vs->nsb || (fs && fs->nsb)) g_with_ssbo++;
    for (int st = 0; st < 2; st++) {
        NxShader *sh = st ? fs : vs;
        for (int i = 0; sh && i < sh->nsb; i++) {
            uint64_t a, n, lim;
            if (!ssbo_range(st, sh, i, &a, &n, &lim))
                return reject(R_SSBO, "%s storage buffer cbOffset %d (index %d) unresolved", st ? "fs" : "vs", sh->sb_cboff[i],
                              ssbo_index(st, sh->sb_cboff[i]));
        }
    }
    for (int i = 0; i < vs->nattr; i++) {
        int loc = vs->attr_loc[i];
        if (loc >= S.attr.n || !S.attr.a[loc].format) continue;
        NvVAttr a = S.attr.a[loc];
        int fsz = vfmt_size(a.format);
        if (!fsz || a.stream >= 14) continue;   // read from the zero buffer instead
        int st = a.stream;
        if (used & 1u << (29 - st)) {
            int shader_slot = 0;
            for (int j = 0; j < vs->ncb; j++) shader_slot |= vs->cb_binding[j] == 29 - st;
            for (int j = 0; j < vs->nsb; j++) shader_slot |= vs->sb_binding[j] == 29 - st;
            if (shader_slot) return reject(R_SLOT_COLLIDE, "stream %d (buffer %d) is also a shader buffer", st, 29 - st);
        }
        uint32_t stride = st < S.stream.n ? S.stream.s[st].stride : 0;
        uint32_t div = st < S.stream.n ? S.stream.s[st].divisor : 0;
        if (dbg()) hist("vertex attribute format (draws)", a.format);
        if (stride && a.offset + (uint32_t)fsz > stride)
            return reject(R_ATTR_STRIDE, "attribute %d offset %u + %d > stride %u", loc, (unsigned)a.offset, fsz, stride);
        uint64_t addr = S.vb[st].addr;
        uint64_t avail = gpu_avail(addr);
        if (!avail) return reject(R_VB_UNBOUND, "attribute %d stream %d (addr %#llx)", loc, st, (unsigned long long)addr);
        if (addr % 4) return reject(R_VB_ALIGN, "stream %d addr %#llx", st, (unsigned long long)addr);
        int64_t last = !stride ? 0 : div ? base_inst + (instances - 1) / div : vmax;
        uint64_t need = (uint64_t)last * stride + a.offset + fsz;
        // Maxwell's vertex array limit (BindVertexBuffer's size): fetches past it read 0, so a draw that
        // inherits another mesh's smaller binding collapses on hardware. Metal has no limit and would read
        // the next stream's bytes (screen-filling triangles): the encoder binds a zero-padded copy.
        if (need <= avail && S.vb[st].size > 0 && need > S.vb[st].size) {
            if (need > ARENA_CHUNK - ARENA_SLACK) {
                extern volatile int g_gfx_frame;
                return reject(R_VB_LIMIT, "frame %d attribute %d stream %d vb %#llx: needs %#llx, bound size %#llx; count %d bv %d",
                              g_gfx_frame, loc, st, (unsigned long long)addr, (unsigned long long)need, (unsigned long long)S.vb[st].size,
                              de ? de->count : da->count, de ? de->base_vertex : da->first);
            }
            g_vb_need[st] = MAX(g_vb_need[st], need);
            g_vb_padded++;
            static int npad;
            if (dbg() && npad++ < 40) {
                extern volatile int g_gfx_frame;
                nx_log("gfx: vb pad: frame %d vs %016llx stream %d stride %u vb %#llx bound %#llx needs %#llx (%lld of %llu vertices past); count %d bv %d",
                       g_gfx_frame, (unsigned long long)vs_hash_for_log, st, stride, (unsigned long long)addr, (unsigned long long)S.vb[st].size,
                       (unsigned long long)need, stride ? (long long)((need - S.vb[st].size + stride - 1) / stride) : 0ll,
                       (unsigned long long)(last + 1), de ? de->count : da->count, de ? de->base_vertex : da->first);
            }
        }
        if (need > avail) {
            extern volatile int g_gfx_frame;
            char idx[96] = "";
            uint64_t hav;
            const uint8_t *ip = de ? nx_nvn_gpu_to_host(de->index_addr, &hav) : NULL;
            for (int k = 0, o = 0; ip && k < 8 && k < de->count; k++)
                o += snprintf(idx + o, sizeof idx - o, " %u", de->type == 2 ? ((const uint32_t *)ip)[k] : ((const uint16_t *)ip)[k]);
            opring_dump("a rejected draw");
            return reject(R_VB_RANGE, "frame %d attribute %d stream %d vb %#llx: index %lld x stride %u + %u needs %#llx, %#llx available "
                          "(NVN size %#llx); draw mode %d type %d count %d ib %#llx bv %d first indices%s",
                          g_gfx_frame, loc, st, (unsigned long long)addr, (long long)last, stride, (unsigned)a.offset,
                          (unsigned long long)need, (unsigned long long)avail, (unsigned long long)S.vb[st].size,
                          de ? de->mode : da->mode, de ? de->type : -1, de ? de->count : da->count,
                          de ? (unsigned long long)de->index_addr : 0ull, de ? de->base_vertex : da->first, idx);
        }
    }
    // NXRT_VCHECK=1: positions (attribute 0 as float3/float4) of up to 64 fetched vertices; flags NaN or
    // |x| > 1e5 (garbage vertex data -> screen-filling triangles).
    static int vcheck = -1;
    if (vcheck < 0) vcheck = getenv("NXRT_VCHECK") != NULL;
    if (vcheck && S.attr.n && (S.attr.a[0].format == 34 || S.attr.a[0].format == 46) && S.attr.a[0].stream < 14) {
        NvVAttr a = S.attr.a[0];
        uint32_t stride = a.stream < S.stream.n ? S.stream.s[a.stream].stride : 0;
        uint64_t hav = 0, vav = 0;
        const uint8_t *ip = de ? nx_nvn_gpu_to_host(de->index_addr, &hav) : NULL;
        const uint8_t *vp = nx_nvn_gpu_to_host(S.vb[a.stream].addr, &vav);
        int bad = 0, n = de ? MIN(de->count, 64) : MIN(da->count, 64);
        float worst = 0;
        for (int i = 0; vp && stride && i < n; i++) {
            int64_t v = de ? (int64_t)(de->type == 2 ? ((const uint32_t *)ip)[i] : de->type == 1 ? ((const uint16_t *)ip)[i] : ip[i]) + de->base_vertex
                           : da->first + i;
            if (v < 0 || (uint64_t)v * stride + a.offset + 12 > vav) continue;
            const float *f = (const float *)(vp + v * stride + a.offset);
            for (int c = 0; c < 3; c++)
                if (!(fabsf(f[c]) < 1e5f)) bad++, worst = isnan(f[c]) ? NAN : MAX(worst, fabsf(f[c]));
        }
        static uint64_t seen[512];
        static int nseen;
        int fresh = bad != 0;
        if (bad) g_vcheck_bad++;
        for (int q = 0; q < nseen && fresh; q++) fresh = seen[q] != vs_hash_for_log;
        if (fresh && nseen < 512) {
            seen[nseen++] = vs_hash_for_log;
            extern volatile int g_gfx_frame;
            opring_dump("a draw with bad positions");
            nx_log("vcheck: frame %d vs %016llx: %d bad position components of %d vertices (worst %g); vb %#llx stride %u fmt %d count %d bv %d",
                   g_gfx_frame, (unsigned long long)vs_hash_for_log, bad, n, worst, (unsigned long long)S.vb[a.stream].addr, stride, a.format,
                   de ? de->count : da->count, de ? de->base_vertex : da->first);
            for (int k = 0; k < S.attr.n && k < 16; k++)
                if (S.attr.a[k].format)
                    nx_log("vcheck:   attr %d fmt %d stream %d offset %u (raw %08x)", k, S.attr.a[k].format, S.attr.a[k].stream,
                           (unsigned)S.attr.a[k].offset, *(const uint32_t *)&S.attr.a[k]);
            for (int k = 0; k < S.stream.n && k < 16; k++)
                nx_log("vcheck:   stream %d stride %u divisor %u vb %#llx size %#llx, bound %s list %llu draws ago", k, S.stream.s[k].stride,
                       S.stream.s[k].divisor, (unsigned long long)S.vb[k].addr, (unsigned long long)S.vb[k].size,
                       S.vb_blob[k] == g_exec_blob ? "in this" : "in an EARLIER", (unsigned long long)(g_exec_draws - S.vb_draw[k]));
            int64_t v0 = de ? (int64_t)(de->type == 2 ? ((const uint32_t *)ip)[0] : ((const uint16_t *)ip)[0]) + de->base_vertex : da->first;
            const float *f0 = (const float *)(vp + v0 * stride + a.offset), *fz = (const float *)vp;
            nx_log("vcheck:   vertex %lld: %g %g %g | vertex 0: %g %g %g | first index %u", (long long)v0, f0[0], f0[1], f0[2], fz[0], fz[1], fz[2],
                   de ? (unsigned)(de->type == 2 ? ((const uint32_t *)ip)[0] : ((const uint16_t *)ip)[0]) : 0u);
            uint32_t ilo = UINT32_MAX, ihi = 0;
            for (int q = 0; de && ip && q < de->count; q++) {
                uint32_t iv = de->type == 2 ? ((const uint32_t *)ip)[q] : de->type == 1 ? ((const uint16_t *)ip)[q] : ip[q];
                ilo = MIN(ilo, iv), ihi = MAX(ihi, iv);
            }
            nx_log("vcheck:   indices %u..%u (+ base vertex %d); bound buffer holds %llu vertices", ilo, ihi, de ? de->base_vertex : 0,
                   stride ? (unsigned long long)(S.vb[a.stream].size / stride) : 0ull);
            for (unsigned q = g_nmarks > 8 ? g_nmarks - 8 : 0; q < g_nmarks; q++)
                nx_log("vcheck:   inlined %#llx (ended at main+%#x) by CallCommands at main+%#x", (unsigned long long)g_marks[q % 8].handle,
                       g_marks[q % 8].end_lr, g_marks[q % 8].call_lr);
        }
    }
    g_check_ok++;
    return 1;
}

// NXRT_RTDUMP_BEFORE=<fs hash>[,<fs hash>...]: in the NXRT_RTDUMP frame, just before the first draw with
// each listed fragment shader, the current color targets are copied aside; the end-of-frame dump
// writes them as <dir>/before_<fs>_<n>.png.
static int g_rtdump_frame;   // defined with the dump below
static int rtdump_frame(void);
static NSMutableArray<id<MTLTexture>> *g_snaps;
static NSMutableArray<NSString *> *g_snap_names;
// NXRT_RTDUMP_EVERY=<k>: in that frame, also snapshot the first color target every k draws that render
// into the NXRT_RTDUMP_TEX texture (a filmstrip within one frame) as before_d<draw index>_rt0.
static void rtdump_before(uint64_t fs_hash, long draw_index) {
    extern volatile int g_gfx_frame;
    static const char *list = (const char *)1;
    static int every = -1, nth;
    static const void *target;
    static const char *after = (const char *)1;
    static char after_pending[24];
    static int after_done;
    if (list == (const char *)1) list = getenv("NXRT_RTDUMP_BEFORE");
    if (every < 0) every = getenv("NXRT_RTDUMP_EVERY") ? atoi(getenv("NXRT_RTDUMP_EVERY")) : 0;
    if (after == (const char *)1) after = getenv("NXRT_RTDUMP_AFTER");
    if ((!list && !every && !after) || rtdump_frame() < 0 || g_gfx_frame != g_rtdump_frame || !E_cmd) return;
    char hex[24];
    if (every && !target && getenv("NXRT_RTDUMP_TEX")) {
        long id = strtol(getenv("NXRT_RTDUMP_TEX"), NULL, 16);
        pthread_mutex_lock(&g_pool_lock);
        target = id >= 0 && id < g_ntex ? g_texslots[id].tex : NULL;
        pthread_mutex_unlock(&g_pool_lock);
    }
    // NXRT_RTDUMP_AFTER=<fs hash>: snapshot right after the first draw with that shader (taken before
    // the next draw), as before_after_<fs>.
    static OpRT after_rt;   // the render targets of the AFTER draw (the next draw may use others)
    const OpRT *R = &S.rt;
    if (after_pending[0]) {
        snprintf(hex, sizeof hex, "%s", after_pending);
        after_pending[0] = 0;
        R = &after_rt;
    } else if (every && target && S.rt.n && S.rt.color[0] == target && nth++ % every == 0) {
        snprintf(hex, sizeof hex, "d%05ld", draw_index);
    } else {
        char h2[20];
        snprintf(h2, sizeof h2, "%016llx", (unsigned long long)fs_hash);
        if (after && !after_done && strstr(after, h2)) {
            after_done = 1;
            after_rt = S.rt;
            snprintf(after_pending, sizeof after_pending, "after_%.12s", h2);
        }
        snprintf(hex, sizeof hex, "%016llx", (unsigned long long)fs_hash);
        if (!list || !strstr(list, hex)) return;
    }
    if (!g_snaps) g_snaps = [NSMutableArray new], g_snap_names = [NSMutableArray new];
    for (NSString *n in g_snap_names)
        if ([n hasPrefix:@(hex)]) return;   // first draw only
    end_pass();
    for (int i = 0; i < R->n && i < 8 && (hex[0] != 'd' || i == 0); i++) {
        id<MTLTexture> t = gfx_texture_mtl(R->color[i]);
        if (!t) continue;
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:t.pixelFormat width:t.width height:t.height mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModePrivate;
        id<MTLTexture> c = [g_dev newTextureWithDescriptor:d];
        id<MTLBlitCommandEncoder> b = [E_cmd blitCommandEncoder];
        [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:(MTLOrigin){0, 0, 0} sourceSize:(MTLSize){t.width, t.height, 1}
                 toTexture:c destinationSlice:0 destinationLevel:0 destinationOrigin:(MTLOrigin){0, 0, 0}];
        [b endEncoding];
        [g_snaps addObject:c];
        [g_snap_names addObject:[NSString stringWithFormat:@"%s_rt%d", hex, i]];
    }
}

// Conditional rendering, evaluated when the draw is encoded (the counters were written by earlier
// command buffers, like the GPU's report latency). The game uses it only for conditional clears
// (SetRenderEnableConditional, ClearColor, ReportCounter to the same address); our counter values are
// never 0, so those render. NXRT_RELOG=<from>-<to> logs each evaluation.
static int render_enabled(void) {
    const OpRenderEnable *r = &S.render_enable;
    if (r->mode < 2) return r->mode;
    if (!r->counters) return 1;
    int equal = r->counters[0] == r->counters[2];
    if (relog() == 2)
        nx_log("re: encode cond %s at %p: %#llx / %#llx -> %s", r->mode == 2 ? "EQUAL" : "NOT_EQUAL", (const void *)r->counters,
               (unsigned long long)r->counters[0], (unsigned long long)r->counters[2], (r->mode == 2 ? equal : !equal) ? "draw" : "skip");
    return r->mode == 2 ? equal : !equal;
}

// NXRT_DRAWLOG=<frame>: log only that frame's draws (any other value: every frame), plus draws
// dropped before encoding and why.
static int drawlog_on(void) {
    static int v = -2;
    if (v == -2) v = !getenv("NXRT_DRAWLOG") ? -1 : atoi(getenv("NXRT_DRAWLOG")) > 1 ? atoi(getenv("NXRT_DRAWLOG")) : 0;
    extern volatile int g_gfx_frame;
    return v == 0 || (v > 0 && g_gfx_frame == v);
}
static void drop_log(const char *why) {
    if (!drawlog_on()) return;
    uint64_t vh = 0, fh = 0;
    for (int i = 0; i < S.prog.n; i++) {
        if (!strcmp(S.prog.st[i].kind, "vs")) vh = S.prog.st[i].hash;
        if (!strcmp(S.prog.st[i].kind, "fs")) fh = S.prog.st[i].hash;
    }
    extern volatile int g_gfx_frame;
    nx_log("draw: frame %d DROPPED (%s) vs %016llx fs %016llx", g_gfx_frame, why, (unsigned long long)vh, (unsigned long long)fh);
}

static void lowdiff_count(uint64_t vs, uint64_t fs);
// NXRT_GPUWATCH=<gpu lo>-<gpu hi> (hex): log draws / dispatches with a storage buffer bound in that range,
// with their shaders (who writes memory the CPU reads back). At most 200 lines (NXRT_GPUWATCH_MAX).
static void gpuwatch(const char *kind) {
    static int on = -1, n, max = 200;
    static uint64_t lo, hi;
    if (on < 0) {
        const char *e = getenv("NXRT_GPUWATCH");
        on = e && sscanf(e, "%llx-%llx", (unsigned long long *)&lo, (unsigned long long *)&hi) == 2;
        if (getenv("NXRT_GPUWATCH_MAX")) max = atoi(getenv("NXRT_GPUWATCH_MAX"));
    }
    if (!on || n >= max) return;
    for (int st = 0; st < 6; st++)
        for (int i = 0; i < 16; i++) {
            const OpBuf *b = &S.ssbo[st][i];
            if (!b->addr || b->addr + b->size <= lo || b->addr >= hi) continue;
            if ((st == 5) != !strcmp(kind, "dispatch")) continue;   // compute bindings stay set across draws
            char sh[160] = "";
            int o = 0;
            for (int k = 0; k < S.prog.n; k++)
                o += snprintf(sh + o, sizeof sh - o, " %s %016llx", S.prog.st[k].kind, (unsigned long long)S.prog.st[k].hash);
            extern volatile int g_gfx_frame;
            nx_log("gpuwatch: frame %d %s ssbo stage %d index %d %#llx+%#llx;%s", g_gfx_frame, kind, st, i, (unsigned long long)b->addr,
                   (unsigned long long)b->size, sh);
            n++;
        }
}

// ---- FXAA after the scene composite (before the UI) ----------------------------------------------------------------
// The game has no anti-aliasing in handheld mode: the island frame is the scene (RG11B10F, linear), bloom, one
// full-screen composite (FS d8a90e5349857c12: tone curves from LUTs), then the UI drawn on top. Right after the composite
// draw, the target is copied and FXAA 3.11 quality (preset 39, ported from the BOTW port's tools/shaders_hd/9d0ae77e..)
// writes it back, so 3D edges are smoothed and UI text stays sharp. Edges are measured on sqrt(luma) (the image is
// linear light: the final copy writes an sRGB view), the blend stays linear. NXRT_FXAA=0 off; NXRT_FXAA_AFTER=<fs hash
// list> (default the composite).
static NSString *const kFxaaMsl = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VOut { float4 pos [[position]]; float2 uv; };\n"
"vertex VOut fxaa_vs(uint vid [[vertex_id]]) {\n"
"    float2 p = float2((vid << 1) & 2, vid & 2);\n"
"    VOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); o.uv = float2(p.x, 1.0 - p.y); return o;\n"
"}\n"
"constant float kSubpixLo = 0.5, kSubpixHi = 1.0, kEdgeThreshold = 0.125, kEdgeThresholdMin = 0.0625;\n"
"constant int kSteps = 12;\n"
"constant float kP[12] = {1.0, 1.0, 1.0, 1.0, 1.0, 1.5, 2.0, 2.0, 2.0, 2.0, 4.0, 8.0};\n"
"fragment float4 fxaa_fs(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
"    const float3 w = float3(0.2126, 0.7152, 0.0722);\n"
"    float2 rcp = 1.0 / float2(t.get_width(), t.get_height());\n"
"    float2 posM = in.uv;\n"
"#define LUMA(p) sqrt(dot(t.sample(s, (p), level(0)).xyz, w))\n"
"#define LUMAO(x, y) sqrt(dot(t.sample(s, posM, level(0), int2(x, y)).xyz, w))\n"
"    float4 rgbaM = t.sample(s, posM, level(0));\n"
"    float lumaM = sqrt(dot(rgbaM.xyz, w));\n"
"    float lumaS = LUMAO(0, 1), lumaE = LUMAO(1, 0), lumaN = LUMAO(0, -1), lumaW = LUMAO(-1, 0);\n"
"    float rangeMax = max(max(max(lumaN, lumaW), max(lumaE, lumaS)), lumaM);\n"
"    float rangeMin = min(min(min(lumaN, lumaW), min(lumaE, lumaS)), lumaM);\n"
"    float range = rangeMax - rangeMin;\n"
"    if (range < max(kEdgeThresholdMin, rangeMax * kEdgeThreshold)) return rgbaM;\n"
"    float lumaNW = LUMAO(-1, -1), lumaSE = LUMAO(1, 1), lumaNE = LUMAO(1, -1), lumaSW = LUMAO(-1, 1);\n"
"    float lumaNS = lumaN + lumaS, lumaWE = lumaW + lumaE;\n"
"    float lumaNESE = lumaNE + lumaSE, lumaNWNE = lumaNW + lumaNE, lumaNWSW = lumaNW + lumaSW, lumaSWSE = lumaSW + lumaSE;\n"
"    float edgeHorz = abs(-2.0 * lumaW + lumaNWSW) + abs(-2.0 * lumaM + lumaNS) * 2.0 + abs(-2.0 * lumaE + lumaNESE);\n"
"    float edgeVert = abs(-2.0 * lumaS + lumaSWSE) + abs(-2.0 * lumaM + lumaWE) * 2.0 + abs(-2.0 * lumaN + lumaNWNE);\n"
"    bool horzSpan = edgeHorz >= edgeVert;\n"
"    float subpixA = (lumaNS + lumaWE) * 2.0 + (lumaNWSW + lumaNESE);\n"
"    if (!horzSpan) lumaN = lumaW, lumaS = lumaE;\n"
"    float lengthSign = horzSpan ? rcp.y : rcp.x;\n"
"    float subpixB = subpixA * (1.0 / 12.0) - lumaM;\n"
"    float gradientN = lumaN - lumaM, gradientS = lumaS - lumaM;\n"
"    float lumaNN = lumaN + lumaM, lumaSS = lumaS + lumaM;\n"
"    bool pairN = abs(gradientN) >= abs(gradientS);\n"
"    float gradient = max(abs(gradientN), abs(gradientS));\n"
"    if (pairN) lengthSign = -lengthSign;\n"
"    float subpixC = saturate(abs(subpixB) / range);\n"
"    float2 posB = posM;\n"
"    float2 offNP = horzSpan ? float2(rcp.x, 0.0) : float2(0.0, rcp.y);\n"
"    if (horzSpan) posB.y += lengthSign * 0.5; else posB.x += lengthSign * 0.5;\n"
"    float2 posN = posB - offNP * kP[0], posP = posB + offNP * kP[0];\n"
"    float subpixF = (-2.0 * subpixC + 3.0) * subpixC * subpixC;\n"
"    if (!pairN) lumaNN = lumaSS;\n"
"    float gradientScaled = gradient * 0.25;\n"
"    bool lumaMLTZero = lumaM - lumaNN * 0.5 < 0.0;\n"
"    float lumaEndN = LUMA(posN) - lumaNN * 0.5, lumaEndP = LUMA(posP) - lumaNN * 0.5;\n"
"    bool doneN = abs(lumaEndN) >= gradientScaled, doneP = abs(lumaEndP) >= gradientScaled;\n"
"    for (int i = 1; i < kSteps && !(doneN && doneP); i++) {\n"
"        if (!doneN) posN -= offNP * kP[i];\n"
"        if (!doneP) posP += offNP * kP[i];\n"
"        if (i == kSteps - 1) break;\n"
"        if (!doneN) lumaEndN = LUMA(posN) - lumaNN * 0.5, doneN = abs(lumaEndN) >= gradientScaled;\n"
"        if (!doneP) lumaEndP = LUMA(posP) - lumaNN * 0.5, doneP = abs(lumaEndP) >= gradientScaled;\n"
"    }\n"
"    float dstN = horzSpan ? posM.x - posN.x : posM.y - posN.y;\n"
"    float dstP = horzSpan ? posP.x - posM.x : posP.y - posM.y;\n"
"    bool goodSpanN = (lumaEndN < 0.0) != lumaMLTZero, goodSpanP = (lumaEndP < 0.0) != lumaMLTZero;\n"
"    bool directionN = dstN < dstP;\n"
"    float pixelOffset = 0.5 - min(dstN, dstP) / (dstP + dstN);\n"
"    float pixelOffsetGood = (directionN ? goodSpanN : goodSpanP) ? pixelOffset : 0.0;\n"
"    float kSubpix = mix(kSubpixLo, kSubpixHi, saturate((float(t.get_height()) - 720.0) / 360.0));\n"
"    float off = max(pixelOffsetGood, subpixF * subpixF * kSubpix);\n"
"    if (horzSpan) posM.y += off * lengthSign; else posM.x += off * lengthSign;\n"
"    return t.sample(s, posM, level(0));\n"
"}\n";
static uint64_t g_fxaa_after[8];
static int g_fxaa_nafter = -1;
static int fxaa_after(uint64_t fs) {
    if (g_fxaa_nafter < 0) {
        g_fxaa_nafter = 0;
        const char *on = getenv("NXRT_FXAA"), *list = getenv("NXRT_FXAA_AFTER");
        if (on && !atoi(on)) return 0;
        for (const char *p = list ? list : "d8a90e5349857c12"; *p && g_fxaa_nafter < 8;) {
            char *end;
            uint64_t h = strtoull(p, &end, 16);
            if (end == p) break;
            g_fxaa_after[g_fxaa_nafter++] = h;
            p = *end ? end + 1 : end;
        }
        nx_log("gfx: FXAA after %d composite shader(s)%s", g_fxaa_nafter, list ? " (NXRT_FXAA_AFTER)" : "");
    }
    for (int i = 0; i < g_fxaa_nafter; i++)
        if (g_fxaa_after[i] == fs) return 1;
    return 0;
}
static void fxaa_pass(void) {
    __strong id<MTLTexture> t = g_pass_c0;
    if (!E || !t || g_pass_c0_lv || g_pass_c0_ly || t.textureType != MTLTextureType2D || t.sampleCount != 1) return;
    static __strong id<MTLRenderPipelineState> pso;
    static __strong id<MTLSamplerState> smp;
    static __strong id<MTLTexture> tmp;
    static MTLPixelFormat pso_fmt;
    static int failed;
    if (failed) return;
    if (!pso || pso_fmt != t.pixelFormat) {
        NSError *err = nil;
        id<MTLLibrary> lib = [g_dev newLibraryWithSource:kFxaaMsl options:nil error:&err];
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"fxaa_vs"];
        d.fragmentFunction = [lib newFunctionWithName:@"fxaa_fs"];
        d.colorAttachments[0].pixelFormat = t.pixelFormat;
        pso = lib ? [g_dev newRenderPipelineStateWithDescriptor:d error:&err] : nil;
        if (!pso) {
            failed = 1;
            nx_log("gfx: FXAA pipeline failed: %s", err.localizedDescription.UTF8String);
            return;
        }
        pso_fmt = t.pixelFormat;
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
        sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        smp = [g_dev newSamplerStateWithDescriptor:sd];
        nx_log("gfx: FXAA on (%lux%lu, format %lu)", (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.pixelFormat);
    }
    if (!tmp || tmp.width != t.width || tmp.height != t.height || tmp.pixelFormat != t.pixelFormat) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:t.pixelFormat width:t.width height:t.height mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        tmp = [g_dev newTextureWithDescriptor:td];
    }
    end_pass();
    id<MTLBlitCommandEncoder> b = [E_cmd blitCommandEncoder];
    [b copyFromTexture:t toTexture:tmp];
    [b endEncoding];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [E_cmd renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:pso];
    [e setFragmentTexture:tmp atIndex:0];
    [e setFragmentSamplerState:smp atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    passlog_event("fxaa", t, t);
}

// The island's visibility queries (FS 21bb2a15470a7fa7: each of its 32x128 output pixels reads the object ID buffer at a
// (u, v) from c3): one block of 32 entries per Mii on the island, 29 of them points over its body, -1 when unused. Their
// centre is the Mii's position on screen this frame (normalised), published for ui_touch.c (tap a Mii: the camera
// steers it under the centre hand). Block k is the same Mii from frame to frame.
enum { PICK_OBJS = 128 };
static float g_pick_obj[PICK_OBJS][2], g_pick_box[PICK_OBJS][4];   // centre; body box u0, v0, u1, v1
static unsigned char g_pick_valid[PICK_OBJS];
static volatile int g_pick_frame = -1;
static void pick_objects_note(void) {
    extern volatile int g_gfx_frame;
    const OpBuf *u = &S.ubo[1][0];
    uint64_t av = 0;
    const float *f = u->addr ? nx_nvn_gpu_to_host(u->addr, &av) : NULL;
    if (!f) return;
    int n = (int)(MIN(av, u->size ? u->size : 0x10000) / 16);
    for (int k = 0; k < PICK_OBJS; k++) {
        float su = 0, sv = 0, bx[4] = {1e9f, 1e9f, -1e9f, -1e9f};
        int c = 0;
        for (int i = 32 * k; i < 32 * k + 29 && i < n; i++)
            if (f[4 * i] != -1 || f[4 * i + 1] != -1) {
                su += f[4 * i], sv += f[4 * i + 1], c++;
                bx[0] = fminf(bx[0], f[4 * i]), bx[1] = fminf(bx[1], f[4 * i + 1]), bx[2] = fmaxf(bx[2], f[4 * i]), bx[3] = fmaxf(bx[3], f[4 * i + 1]);
            }
        g_pick_valid[k] = c > 0;
        if (c) g_pick_obj[k][0] = su / c, g_pick_obj[k][1] = sv / c, memcpy(g_pick_box[k], bx, sizeof bx);
    }
    g_pick_frame = g_gfx_frame;
}
int gfx_pick_objects(float out[][2], float box[][4], unsigned char *valid, int max) {   // -> their frame (-1: none yet)
    int n = MIN(max, PICK_OBJS);
    memcpy(out, g_pick_obj, n * sizeof *g_pick_obj), memcpy(valid, g_pick_valid, n);
    if (box) memcpy(box, g_pick_box, n * sizeof *g_pick_box);
    return g_pick_frame;
}

static void draw_body(const OpDrawElem *de, const OpDrawArrays *da, int st_on, uint64_t st_t);
static void draw(const OpDrawElem *de, const OpDrawArrays *da) {
    if (!stagetime()) { draw_body(de, da, 0, 0); return; }
    uint64_t t0 = mach_absolute_time();
    draw_body(de, da, 1, t0);
    g_st_ticks[ST_N] += mach_absolute_time() - t0;
    g_st_calls++;
}
static void draw_body(const OpDrawElem *de, const OpDrawArrays *da, int st_on, uint64_t st_t) {
    g_resolve_serial++;   // stage_texture_sw's memo: this draw's bindings
    int mode = de ? de->mode : da->mode;
    MTLPrimitiveType prim;
    switch (mode) {
    case 0: prim = MTLPrimitiveTypePoint; break;
    case 1: prim = MTLPrimitiveTypeLine; break;
    case 3: prim = MTLPrimitiveTypeLineStrip; break;
    case 4: prim = MTLPrimitiveTypeTriangle; break;
    case 5: prim = MTLPrimitiveTypeTriangleStrip; break;
    default: hist("unsupported primitive", mode); g_stats_skipped++; return;
    }
    if (draws_enabled() && (S.discard || !render_enabled())) g_stats_reoff++;
    if (S.discard || !draws_enabled() || !render_enabled()) { drop_log(S.discard ? "rasterizer discard" : "render disabled"); return; }
    gpuwatch("draw");
    static long frame_draws, last_frame = -1;
    extern volatile int g_gfx_frame;
    if (g_gfx_frame != last_frame) last_frame = g_gfx_frame, frame_draws = 0;
    if (draw_limit() >= 0 && frame_draws >= draw_limit()) return;
    frame_draws++;
    // Unretained (ARC traffic): shaders, pipelines and depth-stencil states live in their caches for good.
    __unsafe_unretained NxShader *vs = NULL, *fs = NULL;
    const NxStage *pvs = NULL, *pfs = NULL;
    for (int i = 0; i < S.prog.n; i++) {
        if (!strcmp(S.prog.st[i].kind, "vs")) vs = shader_get(S.prog.st[i].hash, "vs"), pvs = &S.prog.st[i];
        if (!strcmp(S.prog.st[i].kind, "fs")) fs = shader_get(S.prog.st[i].hash, "fs"), pfs = &S.prog.st[i];
    }
    if (!vs || (pfs && !fs)) { drop_log("no shader translation"); g_stats_skipped++; return; }
    if (wait_compiled(&vs->ready) != 1 || (fs && wait_compiled(&fs->ready) != 1)) {
        drop_log(vs->ready < 0 || (fs && fs->ready < 0) ? "shader does not compile" : "shader compiling");
        g_stats_pending++;
        return;
    }
    int instances = de ? de->instances : da->instances;
    if (instances <= 0) instances = 1;
    if (de && de->type == 0 && de->count > 0x8000) { hist("u8 indices > 32768", 1); g_stats_skipped++; return; }
    vs_hash_for_log = pvs->hash;
    ST_MARK(ST_PREP);
    if (!validate_draw(vs, fs, de, da, instances)) { drop_log("validation"); g_stats_skipped++; return; }
    ST_MARK(ST_VALIDATE);
    // NXRT_C1DUMP=<vs hash>: print that vertex shader's constant buffer 1 once.
    static uint64_t c1dump = 1;
    if (c1dump == 1) c1dump = getenv("NXRT_C1DUMP") ? strtoull(getenv("NXRT_C1DUMP"), NULL, 16) : 0;
    if (c1dump && pvs->hash == c1dump && pvs->c1_addr) {
        uint64_t av;
        const uint32_t *w = nx_nvn_gpu_to_host(pvs->c1_addr, &av);
        for (uint32_t i = 0; w && i < pvs->c1_size / 4 && i < 64; i += 8)
            nx_log("c1 %016llx +%3u: %08x %08x %08x %08x %08x %08x %08x %08x", (unsigned long long)c1dump, i * 4, w[i], w[i + 1],
                   w[i + 2], w[i + 3], w[i + 4], w[i + 5], w[i + 6], w[i + 7]);
        c1dump = 0;
    }
    // NXRT_CBPEEK=<fs hash>:<cbuf slot>:<byte offset>: log that fragment-stage cbuf word for the first draws using the shader.
    static const char *peek = (const char *)1;
    if (peek == (const char *)1) peek = getenv("NXRT_CBPEEK");
    if (peek && pfs) {
        unsigned long long ph;
        int slot, off;
        static int npeek;
        if (sscanf(peek, "%llx:%d:%i", &ph, &slot, &off) == 3 && pfs->hash == ph && (npeek < 12 || drawlog_on()) && slot >= 3 &&
            slot - 3 < 16) {
            npeek++;
            if (drawlog_on()) {   // in the NXRT_DRAWLOG frame: 4 vec4s from the offset for every draw
                const OpBuf *u4 = &S.ubo[1][slot - 3];
                uint64_t av4 = 0;
                const float *f = u4->addr ? nx_nvn_gpu_to_host(u4->addr + off, &av4) : NULL;
                extern volatile int g_gfx_frame;
                int cnt = 4;   // NXRT_CBPEEK=<fs>:<slot>:<off>:<vec4 count> (default 4)
                const char *c4 = strchr(peek, ':');
                for (int k = 0; c4 && k < 2; k++) c4 = strchr(c4 + 1, ':');
                if (c4) cnt = MAX(4, MIN(4096, atoi(c4 + 1)));
                for (int q = 0; f && q + 4 <= cnt && (uint64_t)(q + 4) * 16 <= av4; q += 4, f += 16)
                    nx_log("cbpeek: frame %d draw #%ld c%d+%#x: (%g %g %g %g) (%g %g %g %g) (%g %g %g %g) (%g %g %g %g)", g_gfx_frame,
                           frame_draws, slot, off + q * 16, f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11], f[12], f[13],
                           f[14], f[15]);
            }
            const OpBuf *u = &S.ubo[1][slot - 3];
            uint64_t av = 0;
            const uint8_t *m = u->addr ? nx_nvn_gpu_to_host(u->addr + off, &av) : NULL;
            uint32_t w = m && av >= 4 ? *(const uint32_t *)m : 0;
            float f4[4] = {0};
            if (m && av >= 16) memcpy(f4, m, 16);
            nx_log("cbpeek: fs %016llx c%d+%#x = %#x (%d, %g); as vec4 (%g, %g, %g, %g) [ubo addr %#llx size %#llx]", ph, slot, off, w,
                   (int)w, *(float *)&w, f4[0], f4[1], f4[2], f4[3], (unsigned long long)u->addr, (unsigned long long)u->size);
        }
    }
    // NXRT_VSPEEK=<vs hash>:<cbuf slot>: in the NXRT_DRAWLOG frame, the first 36 vec4s of that vertex-stage cbuf per draw.
    static const char *vspeek = (const char *)1;
    if (vspeek == (const char *)1) vspeek = getenv("NXRT_VSPEEK");
    if (vspeek && drawlog_on()) {
        unsigned long long vh, vh2 = 0;   // <vs>:<slot> or <vs>+<vs2>:<slot>
        int slot;
        if ((sscanf(vspeek, "%llx+%llx:%d", &vh, &vh2, &slot) == 3 || sscanf(vspeek, "%llx:%d", &vh, &slot) == 2) &&
            (pvs->hash == vh || (vh2 && pvs->hash == vh2)) && slot >= 3 && slot - 3 < 16) {
            const OpBuf *u = &S.ubo[0][slot - 3];
            uint64_t av = 0;
            const float *f = u->addr ? nx_nvn_gpu_to_host(u->addr, &av) : NULL;
            extern volatile int g_gfx_frame;
            for (int q = 0; f && q < 36 && (uint64_t)(q + 1) * 16 <= av; q++) {
                const uint32_t *w = (const uint32_t *)(f + q * 4);
                nx_log("vspeek: frame %d draw #%ld c%d[%d] = (%g %g %g %g) [%#x %#x %#x %#x]", g_gfx_frame, frame_draws, slot, q, f[q * 4],
                       f[q * 4 + 1], f[q * 4 + 2], f[q * 4 + 3], w[0], w[1], w[2], w[3]);
            }
        }
    }
    if (drawlog_on()) {
        extern volatile int g_gfx_frame;
        NxTexDesc rtd = {0};
        if (S.rt.n && S.rt.color[0]) nx_nvn_texture_desc(S.rt.color[0], &rtd);
        nx_log("draw: frame %d #%ld vs %016llx fs %016llx mode %d type %d count %d instances %d base_vertex %d base_instance %d "
               "ib %#llx rt %d color0 %p depth %p c1 vs %#x fs %#x rt0 %dx%d fmt %d storage %p ds test %d write %d func %d "
               "range %g..%g blend %#x cull %d poly offset %#x (%g %g %g) clamp %d vp %g,%g %gx%g scissor %d %g,%g %gx%g atest %d", g_gfx_frame, frame_draws - 1, (unsigned long long)pvs->hash,
               pfs ? (unsigned long long)pfs->hash : 0ull, de ? de->mode : da->mode, de ? de->type : -1, de ? de->count : da->count,
               instances, de ? de->base_vertex : da->first, de ? de->base_instance : da->base_instance,
               de ? (unsigned long long)de->index_addr : 0ull, S.rt.n, S.rt.n ? S.rt.color[0] : NULL, S.rt.depth,
               pvs->c1_size, pfs ? pfs->c1_size : 0, rtd.w, rtd.h, rtd.format, rtd.pool_data, S.ds.dt, S.ds.dw, S.ds.df,
               S.depth_near, S.depth_far, S.color.blend_mask, S.poly.cull, S.poly.offset, S.poly_offset[0], S.poly_offset[1],
               S.poly_offset[2], S.depth_clamp, S.has_viewport ? S.viewport.x : -1, S.has_viewport ? S.viewport.y : -1,
               S.has_viewport ? S.viewport.w : -1, S.has_viewport ? S.viewport.h : -1, S.has_scissor, S.scissor.x, S.scissor.y,
               S.scissor.w, S.scissor.h, S.color.alpha_test);
    }
    // NXRT_DRAWTEX=<fs hash>: for the first draws with that fragment shader, every texture binding
    // (shader handle -> NVN texture index -> pool id -> NVN texture, size, format).
    static const char *drawtex = (const char *)1;
    if (drawtex == (const char *)1) drawtex = getenv("NXRT_DRAWTEX");
    // NXRT_DRAWTEX=all: in the NXRT_DRAWLOG frame, the first draw of every fragment shader (=every: every draw).
    static uint64_t dt_seen[1024];
    static int dt_nseen;
    int dt_every = drawtex && !strcmp(drawtex, "every");
    int dt_all = drawtex && (dt_every || !strcmp(drawtex, "all")) && pfs && fs && drawlog_on();
    for (int q = 0; dt_all && !dt_every && q < dt_nseen; q++) dt_all = dt_seen[q] != pfs->hash;
    if (dt_all && dt_nseen < 1024) dt_seen[dt_nseen++] = pfs->hash;
    if (dt_all || (drawtex && pfs && fs && strtoull(drawtex, NULL, 16) == pfs->hash)) {
        static int ntex_log;
        extern volatile int g_gfx_frame;
        if (dt_all || drawlog_on() || (ntex_log < 4 && (ntex_log == 0 || g_gfx_frame >= 1400) && ++ntex_log)) {
            extern volatile int g_gfx_frame;
            for (int st = 0; st < 2; st++)
            for (int i = 0; i < (st ? fs : vs)->ntex; i++) {
                NxShader *sh = st ? fs : vs;
                int idx = (sh->tex_handle[i] - 8) / 2;
                uint64_t h = idx >= 0 && idx < 64 ? (S.tex_def[st][idx] ? *S.tex_def[st][idx] : S.tex[st][idx]) : 0;
                uint32_t tid = h & 0xFFFFF, sid = (h >> 20) & 0xFFF;
                pthread_mutex_lock(&g_pool_lock);
                const void *tex = h && (int)tid < g_ntex ? g_texslots[tid].tex : NULL;
                int has_view = h && (int)tid < g_ntex ? g_texslots[tid].has_view : 0;
                pthread_mutex_unlock(&g_pool_lock);
                NxTexDesc td = {0};
                if (tex) nx_nvn_texture_desc(tex, &td);
                id<MTLTexture> mt = gfx_texture_mtl(tex);
                nx_log("drawtex: frame %d fs %016llx %s binding %d handle %#x (index %d%s) -> %#llx: pool id %#x sampler %#x tex %p %dx%d fmt %d view %d metal %s type %lu",
                       g_gfx_frame, (unsigned long long)pfs->hash, st ? "fs" : "vs", sh->tex_binding[i], sh->tex_handle[i], idx,
                       sh->tex_cbuf[i] == -1 ? "" : " cbuf-indexed", (unsigned long long)h, tid, sid, tex, td.w, td.h, td.format, has_view,
                       mt ? "ok" : "NONE (dummy)", (unsigned long)mt.textureType);
                if (tex) rtdump_note(tex);   // with NXRT_RTDUMP on the same frame: dump the sampled textures too
                uintptr_t slo = 0, shi = 0;
                int tst = tex ? gfx_texture_state(tex, &slo, &shi) : -1;
                uint64_t nzb = 0;
                for (uintptr_t q = slo; q < shi && shi - slo <= (64u << 20); q += 8) nzb += *(const uint64_t *)q != 0;
                nx_log("drawtex:   pool flags %#x, cache state %d (0 uploaded, 1 empty, 2 gpu, 3 no data), storage %#lx bytes at %p (pool %p +%#llx), %llu non-zero 8-byte words now", td.pool_flags,
                       tst, (unsigned long)(shi - slo), td.pool_data, td.pool, (unsigned long long)td.offset, (unsigned long long)nzb);
                nx_log("drawtex:   swizzle texture %#x view %#x (has view %d)", gfx_texture_swizzle(tex),
                       has_view ? g_texslots[tid].view.swizzle : 0, has_view);
                if (h && (int)sid < g_nsmp) {
                    const NxSamplerState *q = &g_smpslots[sid];
                    nx_log("drawtex:   sampler %#x: min %d mag %d wrap %d/%d/%d border (%g %g %g %g) lod %.2f..%.2f bias %.2f", sid, q->min, q->mag,
                           q->wrap_s, q->wrap_t, q->wrap_r, q->border[0], q->border[1], q->border[2], q->border[3], q->lod_min, q->lod_max,
                           q->lod_bias);
                }
                if (td.pool_data && td.w * td.h <= 4096) {
                    const uint16_t *w16 = (const uint16_t *)td.pool_data;
                    int nz = 0;
                    for (int q = 0; q < td.w * td.h * 4 && q < 0x4000; q++) nz += td.pool_data[q] != 0;
                    nx_log("drawtex:   pool data %p: %d non-zero bytes; first u16: %04x %04x %04x %04x %04x %04x %04x %04x", td.pool_data, nz,
                           w16[0], w16[1], w16[2], w16[3], w16[4], w16[5], w16[6], w16[7]);
                }
            }
        }
    }
    {
        __unsafe_unretained NxShader *shs[2] = {vs, fs};
        int sts[2] = {0, 1};
        detect_feedback(shs, sts, 2, pfs);
        if (g_nfb && draw_check_only()) g_stats_feedback++;
    }
    if (pfs && !draw_check_only()) rtdump_before(pfs->hash, frame_draws - 1);
    ST_MARK(ST_FEEDBACK);
    // With no pass open, copy feedback textures before opening one: opening first loaded every attachment
    // only for resolve_feedback to store it again right away (empty passes, ~32 MB each at 1080p). Pending
    // clears keep the old order: the copy must see the cleared contents.
    {
        // A long pass is split so the GPU can start on it (BOTW's biggest single win): a pass is committed only once
        // it ends, so the island's ~1,400-draw scene passes and ~900-draw shadow pass kept the GPU waiting for their
        // whole encode. The reload costs little on Apple GPUs. NXRT_PASS_SPLIT=<draws> (0 = off, the default: at 30 fps the
        // Mac never waits on the GPU, so no gain shows there; 500 = 5 splits/frame, +52 MB of reloads; A/B it on the phone at 60).
        static int split = -1;
        if (split < 0) split = getenv("NXRT_PASS_SPLIT") ? atoi(getenv("NXRT_PASS_SPLIT")) : 0;
        if (split > 0 && E && g_in_submit && g_stats_draws - g_pass_draws_at_begin >= (uint64_t)split) end_pass_why(PE_SPLIT);
    }
    int fb_early = !draw_check_only() && !E && g_nfb && !fb_pending_clear();
    if (fb_early) resolve_feedback();
    if (draw_check_only() || !begin_pass()) { g_stats_skipped++; return; }
    if (!fb_early) resolve_feedback();
    ST_MARK(ST_PASS);
    if (g_prof_pass >= 0 && !g_prof_keys[g_prof_pass].fs) g_prof_keys[g_prof_pass].fs = pfs ? pfs->hash : 1;
    if (!E) { g_stats_skipped++; return; }
    {   // NXRT_SKIPVS=<vs hash>[:<index count>]: skip those draws (which mesh hides what)
        static long long skipvs = -1;
        static int skipn = -1;   // NXRT_SKIPVS=<vs>[:<index count>]
        if (skipvs < 0) {
            skipvs = getenv("NXRT_SKIPVS") ? (long long)strtoull(getenv("NXRT_SKIPVS"), NULL, 16) : 0;
            const char *c = getenv("NXRT_SKIPVS") ? strchr(getenv("NXRT_SKIPVS"), ':') : NULL;
            skipn = c ? atoi(c + 1) : 0;
        }
        if (skipvs && pvs->hash == (uint64_t)skipvs && (!skipn || (de && de->count == skipn))) return;
    }
    if (g_passlog_on) g_pass_last_fs = pfs ? pfs->hash : 0;
    if (pfs && pfs->hash == 0x21bb2a15470a7fa7ull) pick_objects_note();   // Mii screen positions (ui_touch.c tap-to-centre)
    if (pfs && pfs->hash == 0x21bb2a15470a7fa7ull && ENV("NXRT_PICKPEEK")) {   // recon: the picking draw's query points (c3)
        extern volatile int g_gfx_frame;
        static int last = -1000;
        const OpBuf *u = &S.ubo[1][0];
        uint64_t av = 0;
        const float *f = u->addr ? nx_nvn_gpu_to_host(u->addr, &av) : NULL;
        if (f && g_gfx_frame - last >= 60 && (!ENV("NXRT_PICKPEEK_AT") || g_gfx_frame == atoi(ENV("NXRT_PICKPEEK_AT")))) {
            last = g_gfx_frame;
            int n = 0, nz = 0;
            for (int i = 0; i < 4096 && (uint64_t)(i + 1) * 16 <= MIN(av, u->size ? u->size : 0x10000); i++, n++)
                if (f[4 * i] || f[4 * i + 1]) nz++;
            nx_log("pickpeek: frame %d c3 addr %#llx size %#llx: %d entries, %d non-zero", g_gfx_frame, (unsigned long long)u->addr,
                   (unsigned long long)u->size, n, nz);
            float mn[2] = {1e9f, 1e9f}, mx[2] = {-1e9f, -1e9f};
            for (int i = 0; i < n; i++)
                for (int c = 0; c < 2; c++) mn[c] = fminf(mn[c], f[4 * i + c]), mx[c] = fmaxf(mx[c], f[4 * i + c]);
            NxTexDesc td = {0};
            const void *tx = stage_texture(1, fs, 0, &(NxSamplerState){0}, &(int){0});
            if (tx) nx_nvn_texture_desc(tx, &td);
            nx_log("pickpeek:   u %g..%g v %g..%g; texture 0 %dx%d fmt %d", mn[0], mx[0], mn[1], mx[1], td.w, td.h, td.format);
            for (int i = 0; i < n; i += ENV("NXRT_PICKPEEK_ALL") ? 1 : 512)
                if (f[4 * i] != -1 || !ENV("NXRT_PICKPEEK_ALL")) nx_log("pickpeek:   [%d] %g %g %g %g", i, f[4 * i], f[4 * i + 1], f[4 * i + 2], f[4 * i + 3]);
        }
    }
    __unsafe_unretained id<MTLRenderPipelineState> p = pipeline_for(vs, fs, pvs->hash, pfs ? pfs->hash : 0);
    if (!p) { drop_log("no pipeline"); g_stats_pending++; return; }
    ST_MARK(ST_PIPE);
    if (g_eb_pso != (__bridge const void *)p) [E setRenderPipelineState:p], g_eb_pso = (__bridge const void *)p;
    __unsafe_unretained id<MTLDepthStencilState> dss = ds_state();
    if (g_eb_dss != (__bridge const void *)dss) [E setDepthStencilState:dss], g_eb_dss = (__bridge const void *)dss;
    [E setStencilFrontReferenceValue:S.stencil_ref[0] backReferenceValue:S.stencil_ref[1]];
    [E setCullMode:S.poly.cull == 1 ? MTLCullModeFront : S.poly.cull == 2 ? MTLCullModeBack : MTLCullModeNone];
    [E setFrontFacingWinding:S.poly.front ? MTLWindingCounterClockwise : MTLWindingClockwise];
    [E setTriangleFillMode:S.poly.mode == 1 ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
    [E setDepthClipMode:S.depth_clamp ? MTLDepthClipModeClamp : MTLDepthClipModeClip];
    if (S.poly.offset & 4) [E setDepthBias:S.poly_offset[1] slopeScale:S.poly_offset[0] clamp:S.poly_offset[2]];
    else if (E_depth24 && S.ds.dt && S.ds.df == 3) [E setDepthBias:(ENV("NXRT_EQ24_BIAS") ? -atof(ENV("NXRT_EQ24_BIAS")) : -2) slopeScale:0 clamp:0];   // see E_depth24
    else [E setDepthBias:0 slopeScale:0 clamp:0];
    [E setBlendColorRed:S.blend_color[0] green:S.blend_color[1] blue:S.blend_color[2] alpha:S.blend_color[3]];
    OpRect vp = S.has_viewport ? S.viewport : (OpRect){0, 0, E_w, E_h};
    [E setViewport:(MTLViewport){vp.x, vp.y, vp.w, vp.h, S.depth_near, S.depth_far}];
    int sx = 0, sy = 0, sw = E_w, sh = E_h;
    if (S.has_scissor) {
        sx = MAX(0, (int)S.scissor.x), sy = MAX(0, (int)S.scissor.y);
        sw = MIN(E_w, (int)(S.scissor.x + S.scissor.w)) - sx, sh = MIN(E_h, (int)(S.scissor.y + S.scissor.h)) - sy;
        if (sw <= 0 || sh <= 0) return;
    }
    [E setScissorRect:(MTLScissorRect){(NSUInteger)sx, (NSUInteger)sy, (NSUInteger)sw, (NSUInteger)sh}];
    ST_MARK(ST_STATE);
    bind_stage(0, vs, pvs, nil);
    ST_MARK(ST_BIND_VS);
    if (fs) bind_stage(1, fs, pfs, nil);
    ST_MARK(ST_BIND_FS);
    // vertex streams
    static __strong id<MTLBuffer> zerobuf;   // (a buffer, not setBytes: see bind_stage's support buffer)
    if (!zerobuf) zerobuf = [g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
    eb_buffer(0, zerobuf, 0, 30);
    for (int s = 0; s < 14 && s < 32; s++) {
        if (!S.vb[s].addr) continue;
        NSUInteger off = 0;
        __unsafe_unretained id<MTLBuffer> b = buf_for(S.vb[s].addr, &off);   // see bind_stage
        if (b && g_vb_need[s]) b = arena_vertex_pad((const uint8_t *)b.contents + off, S.vb[s].size, g_vb_need[s], &off);
        if (b) eb_buffer(0, b, off, 29 - s);
    }
    if (de) {
        NSUInteger off = 0;
        __unsafe_unretained id<MTLBuffer> ib = buf_for(de->index_addr, &off);
        if (!ib || de->count <= 0) { g_stats_skipped++; return; }
        if (de->type == 0) {
            // Metal has no 8-bit indices: widen to 16 bits in the upload arena (restart 0xFF -> 0xFFFF).
            // The final full-screen pass into the window is a 6-index u8 draw.
            static uint16_t wide[0x8000];
            const uint8_t *ip = (const uint8_t *)ib.contents + off;
            for (int i = 0; i < de->count; i++) wide[i] = ip[i] == 0xFF ? 0xFFFF : ip[i];
            ib = arena_copy(wide, de->count * 2, &off);
        }
        [E drawIndexedPrimitives:prim indexCount:de->count
                       indexType:de->type == 2 ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16
                     indexBuffer:ib indexBufferOffset:off instanceCount:instances
                      baseVertex:de->base_vertex baseInstance:de->base_instance];
    } else {
        if (da->count <= 0) return;
        [E drawPrimitives:prim vertexStart:da->first vertexCount:da->count instanceCount:instances baseInstance:da->base_instance];
    }
    g_stats_draws++;
    g_draw_seq++;
    lowdiff_count(pvs->hash, pfs ? pfs->hash : 0);
    if (pfs && fxaa_after(pfs->hash)) fxaa_pass();
    ST_MARK(ST_DRAW);
}

// ---- compute ------------------------------------------------------------------------------
// GPU dispatches are opt-in on top of NXRT_DRAW: NXRT_COMPUTE=1 (NXRT_DRAW=check validates them anyway).
// NXRT_CSLOG=1 logs the first dispatches with their storage-buffer bindings.
static int compute_enabled(void) {
    static int on = -1;
    if (on < 0) on = getenv("NXRT_COMPUTE") && atoi(getenv("NXRT_COMPUTE"));
    return on;
}
// Compute driver cbuf 0 (measured 2026-10-07, NXRT_CSLOG): storage buffer i at word 196 + 4i (a chain
// 5bafb5 writes index 0 -> c1e20a reads it as index 1 checks the order), and uniform buffer i at word
// 136 + 4i. Maxwell compute has 8 cbuf slots, so only UBOs 0..4 are real cbufs (c3..c7); the particle
// shaders read UBOs 5/6/7 at words 156/160/164 (largest constant offsets fit those UBOs' sizes).
static int cs_ssbo_index(int cboff) {
    if (cboff >= 196 && (cboff - 196) % 4 == 0 && (cboff - 196) / 4 < 16) return (cboff - 196) / 4;
    if (cboff >= 136 && cboff < 192 && (cboff - 136) % 4 == 0) return 16 + (cboff - 136) / 4;
    return -1;
}
static uint64_t g_cs_done, g_cs_rejected, g_cs_pending;

@interface NxCPipe : NSObject {
@public
    id<MTLComputePipelineState> pso;
    volatile int ready;
}
@end
@implementation NxCPipe
@end

static id<MTLComputePipelineState> compute_pipeline(NxShader *cs, uint64_t hash) {
    static NSMutableDictionary<NSNumber *, NxCPipe *> *cache;
    if (!cache) cache = [NSMutableDictionary new];
    NxCPipe *hit = cache[@(hash)];
    if (hit) return wait_compiled(&hit->ready) == 1 ? hit->pso : nil;
    NxCPipe *pipe = [NxCPipe new];
    cache[@(hash)] = pipe;
    pipe_archives_init();
    MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new];
    d.computeFunction = cs->fn;
    if (g_harvest && from_metallib(cs->fn)) harvest_add(d);
    if (g_pipe_archive) d.binaryArchives = @[g_pipe_archive];
    [g_dev newComputePipelineStateWithDescriptor:d options:MTLPipelineOptionNone
                               completionHandler:^(id<MTLComputePipelineState> p, MTLComputePipelineReflection *refl, NSError *err) {
        if (!p) nx_log("gfx: compute pipeline %016llx failed: %s", (unsigned long long)hash, err.localizedDescription.UTF8String);
        pipe->pso = p;
        __atomic_store_n(&pipe->ready, p ? 1 : -1, __ATOMIC_RELEASE);
    }];
    return wait_compiled(&pipe->ready) == 1 ? pipe->pso : nil;
}

static int cs_reject(const char *fmt, ...) {
    g_cs_rejected++;
    static int n;
    if (n++ < 24) {
        char msg[512];
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(msg, sizeof msg, fmt, ap);
        va_end(ap);
        nx_log("gfx: dispatch rejected: %s", msg);
    }
    return 0;
}

static void dispatch(const OpDispatch *d) {
    if (!draws_enabled()) return;
    gpuwatch("dispatch");
    const NxStage *pcs = NULL;
    for (int i = 0; i < S.prog.n; i++)
        if (!strcmp(S.prog.st[i].kind, "cs")) pcs = &S.prog.st[i];
    if (!pcs) { cs_reject("no compute stage bound"); return; }
    NxShader *cs = shader_get(pcs->hash, "cs");
    static int cslog = -1, nlog;
    if (cslog < 0) cslog = getenv("NXRT_CSLOG") != NULL;
    if (cslog && nlog++ < 40) {
        extern volatile int g_gfx_frame;
        char sb[512] = "", bound[1024] = "";
        int o = 0;
        for (int i = 0; cs && i < cs->nsb; i++) o += snprintf(sb + o, sizeof sb - o, " %d", cs->sb_cboff[i]);
        o = 0;
        for (int st = 0; st < 6; st++)
            for (int i = 0; i < 16; i++)
                if (S.ssbo[st][i].addr)
                    o += snprintf(bound + o, sizeof bound - o, " [%d.%d %#llx+%#llx]", st, i, (unsigned long long)S.ssbo[st][i].addr,
                                  (unsigned long long)S.ssbo[st][i].size);
        for (int i = 0; i < 16; i++)
            if (S.ubo[5][i].addr)
                o += snprintf(bound + o, sizeof bound - o, " [ubo %d %#llx+%#llx]", i, (unsigned long long)S.ubo[5][i].addr,
                              (unsigned long long)S.ubo[5][i].size);
        nx_log("cs: frame %d %016llx groups %dx%dx%d local %dx%dx%d; cbOffsets%s; bound%s", g_gfx_frame, (unsigned long long)pcs->hash,
               d->x, d->y, d->z, cs ? cs->local[0] : 0, cs ? cs->local[1] : 0, cs ? cs->local[2] : 0, sb, bound);
    }
    if (!cs) { cs_reject("no translation for %016llx", (unsigned long long)pcs->hash); return; }
    if (wait_compiled(&cs->ready) != 1) { g_cs_pending++; return; }
    // GPU safety: sane sizes, and every storage buffer inside a pool (accesses are clamped to it).
    if (d->x <= 0 || d->y <= 0 || d->z <= 0 || d->x > 65535 || d->y > 65535 || d->z > 65535) {
        cs_reject("%016llx groups %dx%dx%d", (unsigned long long)pcs->hash, d->x, d->y, d->z);
        return;
    }
    if (cs->local[0] * cs->local[1] * cs->local[2] > 1024 || cs->local[0] < 1 || cs->local[1] < 1 || cs->local[2] < 1) {
        cs_reject("%016llx local size %dx%dx%d", (unsigned long long)pcs->hash, cs->local[0], cs->local[1], cs->local[2]);
        return;
    }
    for (int i = 0; i < cs->nsb; i++) {
        uint64_t a, n, lim;
        if (!ssbo_range(5, cs, i, &a, &n, &lim)) {
            cs_reject("%016llx storage buffer cbOffset %d (index %d) unresolved", (unsigned long long)pcs->hash, cs->sb_cboff[i],
                      ssbo_index(5, cs->sb_cboff[i]));
            return;
        }
    }
    if (draw_check_only() || !compute_enabled()) { g_cs_done++; return; }
    id<MTLComputePipelineState> p = compute_pipeline(cs, pcs->hash);
    if (!p) { g_cs_pending++; return; }
    flush_clears();
    end_pass_why(PE_COMPUTE);
    passlog_event("compute", nil, nil);
    id<MTLComputeCommandEncoder> ce = prof_compute(pcs->hash);
    [ce setComputePipelineState:p];
    bind_stage(5, cs, pcs, ce);
    [ce dispatchThreadgroups:MTLSizeMake(d->x, d->y, d->z) threadsPerThreadgroup:MTLSizeMake(cs->local[0], cs->local[1], cs->local[2])];
    [ce endEncoding];
    g_cs_done++;
}

static void rtdump_note(const void *tex);
// NXRT_ALIASLOG=<host address hex>[-<end hex>]: log render targets / copy and clear destinations whose storage lies
// within 64 KB of that address (or in that range) (finds the texture object that really writes another one's storage).
static void alias_check(const char *what, const void *tex, int level, int layer) {
    static uintptr_t watch = 1, wend;
    if (watch == 1) {
        const char *e = getenv("NXRT_ALIASLOG");
        watch = e ? (uintptr_t)strtoull(e, NULL, 16) : 0;
        wend = e && strchr(e, '-') ? (uintptr_t)strtoull(strchr(e, '-') + 1, NULL, 16) : watch + 0x10000;
    }
    static uintptr_t wpool = 1;   // NXRT_ALIASLOG_POOL=<pool object hex>: then the range is pool offsets (pools without CPU memory)
    if (wpool == 1) wpool = getenv("NXRT_ALIASLOG_POOL") ? (uintptr_t)strtoull(getenv("NXRT_ALIASLOG_POOL"), NULL, 16) : 0;
    if (!watch && !wpool) return;
    if (!tex) return;
    NxTexDesc d = {0};
    nx_nvn_texture_desc(tex, &d);
    uintptr_t p = wpool ? ((uintptr_t)d.pool == wpool ? (uintptr_t)d.offset + 1 : 0) : (uintptr_t)d.pool_data;
    if (wpool && p) p--;
    static int n, from = -1;   // NXRT_ALIASLOG_FROM=<frame>
    extern volatile int g_gfx_frame;
    if (from < 0) from = getenv("NXRT_ALIASLOG_FROM") ? atoi(getenv("NXRT_ALIASLOG_FROM")) : 0;
    if (g_gfx_frame >= from && (wpool ? (uintptr_t)d.pool == wpool : p != 0) && p + 0x10000 > watch && p < wend && n++ < 200) {
        nx_log("alias: frame %d %s tex %p storage %p +%#llx (%+lld from watch) %dx%d fmt %d target %d levels %d level %d layer %d", g_gfx_frame, what,
               tex, d.pool_data, (unsigned long long)d.offset, (long long)(p - watch), d.w, d.h, d.format, d.target, d.levels, level, layer);
    }
}
// Ring of the last executed ops (type + first 48 payload bytes), dumped when a draw fails validation
// or VCHECK finds garbage positions: what bound the state the bad draw used.
static struct { uint8_t type; uint8_t pay[48]; const Blob *blob; } g_opring[32];
static unsigned g_opring_n;
static void opring_dump(const char *why) {
    static int dumps;
    if (dumps++ >= 6) return;
    nx_log("opring: last ops before %s (oldest first):", why);
    for (unsigned q = g_opring_n > 32 ? g_opring_n - 32 : 0; q < g_opring_n; q++) {
        const typeof(g_opring[0]) *r = &g_opring[q % 32];
        const OpBuf *b = (const void *)r->pay;
        const OpDrawElem *de = (const void *)r->pay;
        const OpMark *mk = (const void *)r->pay;
        switch (r->type) {
        case OP_VBUF: nx_log("opring:   VBUF  %d addr %#llx size %#llx (list %p)", b->index, (unsigned long long)b->addr, (unsigned long long)b->size, r->blob); break;
        case OP_DRAW_ELEM: nx_log("opring:   DRAW  count %d bv %d ib %#llx inst %d (list %p)", de->count, de->base_vertex, (unsigned long long)de->index_addr, de->instances, r->blob); break;
        case OP_MARK: nx_log("opring:   MARK  list %#llx ended at main+%#x, called at main+%#x", (unsigned long long)mk->handle, mk->end_lr, mk->call_lr); break;
        default: nx_log("opring:   op %d (list %p)", r->type, r->blob); break;
        }
    }
}
static void exec_ops(const Blob *d) {
    g_exec_blob = d;
    const uint8_t *p = d->bytes, *end = p + d->len;
    while (p + sizeof(OpHdr) <= end) {
        OpHdr h;
        memcpy(&h, p, sizeof h);
        const void *o = p + sizeof h;
        p += sizeof h + h.size;
        if (h.type < 40) g_exec_ops[h.type]++;
        if (h.type != OP_TEX && h.type != OP_UBO) {   // keep the ring to state that matters for vertex fetch
            typeof(g_opring[0]) *r = &g_opring[g_opring_n++ % 32];
            r->type = h.type, r->blob = d;
            memcpy(r->pay, o, MIN((size_t)h.size, sizeof r->pay));
        }
        switch (h.type) {
        case OP_RT:
            // The same targets again: keep the open pass (ending it stored and reloaded every attachment,
            // ~48 MB/frame on the island) and any pending clears (clears end the pass, so with a pass open
            // there are none; without one they still apply to these targets).
            if (!memcmp(&S.rt, o, sizeof S.rt)) break;
            flush_clears();
            end_pass_why(PE_RT);
            memcpy(&S.rt, o, sizeof S.rt);
            for (int i = 0; i < S.rt.n; i++) rtdump_note(S.rt.color[i]), alias_check("render target", S.rt.color[i], S.rt.level[i], S.rt.layer[i]);
            if (S.rt.depth && ENV("NXRT_RTDUMP_DEPTH")) rtdump_note(S.rt.depth);
            break;
        case OP_CLEAR_COLOR: {
            const OpClearColor *c = o;
            if (c->index < 0 || c->index >= 8 || !(c->mask & 0xF)) break;
            {
                extern volatile int g_gfx_frame;
                static int f = -2;
                if (f == -2) f = getenv("NXRT_DEPTHDBG") ? atoi(getenv("NXRT_DEPTHDBG")) : -1;
                if (f == g_gfx_frame)
                    nx_log("depthdbg: clear color%d (%g %g %g %g) mask %#x rt n %d tex %p; scissor %s %g,%g %gx%g viewport %g,%g %gx%g", c->index,
                           c->rgba[0], c->rgba[1], c->rgba[2], c->rgba[3], c->mask, S.rt.n, c->index < S.rt.n ? S.rt.color[c->index] : NULL,
                           S.has_scissor ? "set" : "none", S.scissor.x, S.scissor.y, S.scissor.w, S.scissor.h, S.viewport.x, S.viewport.y,
                           S.viewport.w, S.viewport.h);
            }
            if (!render_enabled()) break;   // conditional rendering gates clears too (the engine's clear-once slots)
            end_pass_why(PE_CLEAR_COLOR);
            pend_clear_color_mask |= 1 << c->index;   // applied as the next pass's load action (flush_clears)
            memcpy(pend_clear_color[c->index], c->rgba, 16);
            break;
        }
        case OP_CLEAR_DS: {
            const OpClearDS *c = o;
            {
                extern volatile int g_gfx_frame;
                static int f = -2;
                if (f == -2) f = getenv("NXRT_DEPTHDBG") ? atoi(getenv("NXRT_DEPTHDBG")) : -1;
                if (f == g_gfx_frame)
                    nx_log("depthdbg: clear depth %d (%g) stencil %d (%d) depth tex %p render enable mode %d -> %d discard %d; scissor %s %g,%g %gx%g",
                           c->depth_mask, c->depth, c->stencil_mask, c->stencil, S.rt.depth, S.render_enable.mode, render_enabled(), S.discard, S.has_scissor ? "set" : "none", S.scissor.x, S.scissor.y, S.scissor.w,
                           S.scissor.h);
            }
            if (!render_enabled()) break;
            end_pass_why(PE_CLEAR_DS);
            if (c->depth_mask) pend_clear_depth = 1, pend_depth = c->depth;
            if (c->stencil_mask) pend_clear_stencil = 1, pend_stencil = c->stencil;
            break;
        }
        case OP_CLEAR_TEX: {
            const OpClearTex *c = o;
            alias_check("clear", c->tex, 0, 0);
            id<MTLTexture> t = gfx_texture_mtl(c->tex);
            if (!t || !(t.usage & MTLTextureUsageRenderTarget) || draw_check_only()) break;
            gfx_texture_mark_gpu(c->tex);
            flush_clears();
            end_pass_why(PE_CLEAR_TEX);
            passlog_event("clear tex", nil, t);
            NSUInteger slices = t.textureType == MTLTextureType3D ? 1
                              : t.arrayLength * (t.textureType == MTLTextureTypeCube || t.textureType == MTLTextureTypeCubeArray ? 6 : 1);
            for (int lv = c->level; lv < c->level + c->nlevels && lv < (int)t.mipmapLevelCount; lv++) {
                int lw = MAX(1, (int)t.width >> lv), lh = MAX(1, (int)t.height >> lv);
                if (c->has_region && (c->region[0] > 0 || c->region[1] > 0 || c->region[3] < lw || c->region[4] < lh)) {
                    static int n;   // partial-region clears aren't implemented: leave the texels alone
                    if (n++ < 8) nx_log("gfx: ClearTexture of a partial region skipped (%d,%d %dx%d of level %d %dx%d)", c->region[0], c->region[1],
                                        c->region[3], c->region[4], lv, lw, lh);
                    continue;
                }
                for (int ly = c->layer; ly < c->layer + c->nlayers && ly < (int)slices; ly++) {
                    subdirty_mark(t, lv, ly);
                    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                    rp.colorAttachments[0].texture = t;
                    rp.colorAttachments[0].level = lv;
                    rp.colorAttachments[0].slice = ly;
                    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                    rp.colorAttachments[0].clearColor = MTLClearColorMake(c->rgba[0], c->rgba[1], c->rgba[2], c->rgba[3]);
                    [[E_cmd renderCommandEncoderWithDescriptor:rp] endEncoding];
                }
            }
            break;
        }
        case OP_PROGRAM: memcpy(&S.prog, o, sizeof S.prog); break;
        case OP_UBO: {
            const OpBuf *b = o;
            if (b->stage >= 0 && b->stage < 6 && b->index >= 0 && b->index < 16) S.ubo[b->stage][b->index] = *b;
            break;
        }
        case OP_SSBO: {
            const OpBuf *b = o;
            if (b->stage >= 0 && b->stage < 6 && b->index >= 0 && b->index < 16) S.ssbo[b->stage][b->index] = *b;
            break;
        }
        case OP_TEX: {
            const OpTex *t = o;
            if (t->stage >= 0 && t->stage < 6 && t->index >= 0 && t->index < 64)
                S.tex[t->stage][t->index] = t->handle, S.tex_def[t->stage][t->index] = NULL;
            break;
        }
        case OP_TEX_DEFERRED: {
            const OpTexDeferred *t = o;
            for (int i = 0; i < t->count && t->stage >= 0 && t->stage < 6; i++)
                if (t->first + i >= 0 && t->first + i < 64) S.tex_def[t->stage][t->first + i] = t->handles + i;
            break;
        }
        case OP_MARK: memcpy(&g_marks[g_nmarks++ % 8], o, sizeof(OpMark)); break;
        case OP_BARRIER: {
            int32_t flags;
            memcpy(&flags, o, 4);
            if (flags & 0x10) g_barrier_epoch++;   // NVN_BARRIER_INVALIDATE_TEXTURE: sampling now sees prior rendering
            if (dbg()) hist("barrier flags", flags);
            break;
        }
        case OP_VBUF: {
            const OpBuf *b = o;
            if (b->index >= 0 && b->index < 32) S.vb[b->index] = *b, S.vb_blob[b->index] = g_exec_blob, S.vb_draw[b->index] = g_exec_draws;
            break;
        }
        case OP_VATTR: memset(&S.attr, 0, sizeof S.attr); memcpy(&S.attr, o, h.size < sizeof S.attr ? h.size : sizeof S.attr); break;
        case OP_VSTREAM: memset(&S.stream, 0, sizeof S.stream); memcpy(&S.stream, o, h.size < sizeof S.stream ? h.size : sizeof S.stream); break;
        case OP_BLEND: {
            const NvBlend *b = o;
            if (b->target < 8) S.blend[b->target] = *b;
            break;
        }
        case OP_COLOR: memcpy(&S.color, o, sizeof S.color); break;
        case OP_CHMASK: memcpy(&S.chmask, o, sizeof S.chmask); break;
        case OP_DS: memcpy(&S.ds, o, sizeof S.ds); break;
        case OP_POLY: memcpy(&S.poly, o, sizeof S.poly); break;
        case OP_MS: memcpy(&S.ms, o, sizeof S.ms); break;
        case OP_BLEND_COLOR: memcpy(S.blend_color, o, 16); break;
        case OP_VIEWPORT: memcpy(&S.viewport, o, sizeof S.viewport); S.has_viewport = 1; break;
        case OP_SCISSOR: memcpy(&S.scissor, o, sizeof S.scissor); S.has_scissor = 1; break;
        case OP_DEPTH_RANGE: memcpy(&S.depth_near, o, 4); memcpy(&S.depth_far, (const float *)o + 1, 4); break;
        case OP_POLY_OFFSET: memcpy(S.poly_offset, o, 12); break;
        case OP_DEPTH_CLAMP: memcpy(&S.depth_clamp, o, 4); break;
        case OP_DISCARD: memcpy(&S.discard, o, 4); break;
        case OP_STENCIL: {
            const OpStencil *s = o;
            for (int f = 0; f < 2; f++) {
                if (!(s->face & (1 << f))) continue;
                if (s->which == 0) S.stencil_ref[f] = s->ref;
                else if (s->which == 1) S.stencil_mask[f] = s->mask;
                else S.stencil_vmask[f] = s->vmask;
            }
            break;
        }
        case OP_SIGNAL_EVENT: [g_completion_writes appendBytes:"E" length:1]; [g_completion_writes appendBytes:o length:sizeof(OpSignal)]; break;
        case OP_REPORT_COUNTER:
            if (drawlog_on()) {
                extern volatile int g_gfx_frame;
                const OpCounter *oc = (const OpCounter *)o;
                nx_log("draw: frame %d COUNTER type %d mem %p", g_gfx_frame, oc->type, (void *)oc->mem);
            }
            if (relog() == 2) {
                extern volatile int g_gfx_frame;
                nx_log("re: frame %d exec counter type %d host %p after %llu draws (total)", g_gfx_frame, ((const OpCounter *)o)->type,
                       (void *)((const OpCounter *)o)->mem, (unsigned long long)(g_stats_draws + g_stats_skipped));
            }
            {
                // Timestamp reports (NVN types 0 and 16) carry counter value 0, written in stream order: the
                // engine's clear-once scheme is SetRenderEnableConditional(NOT_EQUAL, slot) -> Clear ->
                // ReportCounter(16, slot); the zero makes the slot's two values equal so later passes on the same
                // target skip the clear (a Mii prepass depth was wiped before its EQUAL colour pass otherwise).
                // Conditions are evaluated as ops execute, so the value must land now, not at GPU completion.
                // NXRT_COUNTER_SEQ=1: the old increasing counter, written at completion.
                static int seq_mode = -1;
                if (seq_mode < 0) seq_mode = getenv("NXRT_COUNTER_SEQ") != NULL;
                const OpCounter *oc = o;
                if (!seq_mode && (oc->type == 0 || oc->type == 16)) __atomic_store_n(&oc->mem[0], 0, __ATOMIC_RELEASE);
                CounterWrite w = {oc->mem, oc->type | (!seq_mode && (oc->type == 0 || oc->type == 16) ? 0x10000 : 0), g_draw_seq};
                [g_completion_writes appendBytes:"C" length:1];
                [g_completion_writes appendBytes:&w length:sizeof w];
            }
            break;
        case OP_COPY_TEX: {
            const OpCopyTex *c = o;
            alias_check("copy dest", c->dst, c->dlevel, c->dlayer);
            id<MTLTexture> st = gfx_texture_mtl(c->src), dt = gfx_texture_mtl(c->dst);
            if (!st || !dt || draw_check_only() || !draws_enabled()) break;
            gfx_texture_mark_gpu(c->dst);
            int sw = c->sreg[3], sh = c->sreg[4], dw = c->dreg[3], dh = c->dreg[4];
            if (sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0) break;
            // bounds of the chosen levels/layers (GPU safety)
            if (c->slevel >= (int)st.mipmapLevelCount || c->dlevel >= (int)dt.mipmapLevelCount) break;
            if (c->slayer >= (int)st.arrayLength || c->dlayer >= (int)dt.arrayLength) break;
            int stw = MAX(1, (int)st.width >> c->slevel), sth = MAX(1, (int)st.height >> c->slevel);
            int dtw = MAX(1, (int)dt.width >> c->dlevel), dth = MAX(1, (int)dt.height >> c->dlevel);
            if (c->sreg[0] < 0 || c->sreg[1] < 0 || c->sreg[0] + sw > stw || c->sreg[1] + sh > sth) break;
            if (c->dreg[0] < 0 || c->dreg[1] < 0 || c->dreg[0] + dw > dtw || c->dreg[1] + dh > dth) break;
            if (st == dt && c->slevel == c->dlevel && c->slayer == c->dlayer) break;   // same subresource: not supported
            flush_clears();
            end_pass_why(PE_COPY);
            passlog_event("copy", st, dt);
            if (sw == dw && sh == dh && st.pixelFormat == dt.pixelFormat && st.sampleCount == dt.sampleCount) {
                id<MTLBlitCommandEncoder> b = prof_blit(2);
                [b copyFromTexture:st sourceSlice:c->slayer sourceLevel:c->slevel
                      sourceOrigin:(MTLOrigin){(NSUInteger)c->sreg[0], (NSUInteger)c->sreg[1], 0}
                        sourceSize:(MTLSize){(NSUInteger)sw, (NSUInteger)sh, 1} toTexture:dt destinationSlice:c->dlayer
                  destinationLevel:c->dlevel destinationOrigin:(MTLOrigin){(NSUInteger)c->dreg[0], (NSUInteger)c->dreg[1], 0}];
                [b endEncoding];
            } else if (dt.usage & MTLTextureUsageRenderTarget && st.textureType == MTLTextureType2D && dt.textureType == MTLTextureType2D) {
                id<MTLTexture> sv = [st newTextureViewWithPixelFormat:st.pixelFormat textureType:MTLTextureType2D
                                                               levels:NSMakeRange(c->slevel, 1) slices:NSMakeRange(0, 1)];
                id<MTLTexture> dv = [dt newTextureViewWithPixelFormat:dt.pixelFormat textureType:MTLTextureType2D
                                                               levels:NSMakeRange(c->dlevel, 1) slices:NSMakeRange(0, 1)];
                if (!sv || !dv) break;
                st = sv;
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = dv;
                rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> e = [E_cmd renderCommandEncoderWithDescriptor:rp];
                [e setRenderPipelineState:gfx_blit_rect_pso(dt.pixelFormat)];
                [e setViewport:(MTLViewport){c->dreg[0], c->dreg[1], dw, dh, 0, 1}];
                float r[4] = {(float)c->sreg[0] / stw, (float)c->sreg[1] / sth, (float)sw / stw, (float)sh / sth};
                [e setFragmentBytes:r length:sizeof r atIndex:0];
                [e setFragmentTexture:st atIndex:0];
                [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [e endEncoding];
            }
            break;
        }
        case OP_DRAW_ELEM: g_exec_draws++; draw(o, NULL); break;
        case OP_DRAW_ARRAYS: draw(NULL, o); break;
        case OP_DISPATCH: dispatch(o); break;
        case OP_RENDER_ENABLE: memcpy(&S.render_enable, o, sizeof S.render_enable); break;
        case OP_UPDATE_UBO: {
            // Applied at encode time; binds of updated buffers take snapshots (see upd_note).
            const OpUpdateUbo *u = o;
            uint64_t avail = 0;
            uint8_t *dst = nx_nvn_gpu_to_host(u->addr + u->offset, &avail);
            if (ENV("NXRT_NOUPDATE")) break;
            static int logged;
            if (dbg() && logged++ < 6)
                nx_log("gfx: UpdateUniformBuffer addr %#llx offset %#llx size %#llx -> host %p (avail %#llx)",
                       (unsigned long long)u->addr, (unsigned long long)u->offset, (unsigned long long)u->size, dst,
                       (unsigned long long)avail);
            if (dst && (uint64_t)u->size <= avail) memcpy(dst, u->data, u->size), upd_note(u->addr, u->buf_size);
            break;
        }
        }
    }
}

// ---- NXRT_RTDUMP=<dir> (+ NXRT_RTDUMP_FRAME=N, default 1500): every color render target bound
// in frame N, in first-bind order, as <dir>/<order>_<w>x<h>_f<NVN format>_<texture>.png. Each is an
// RGBA8 copy of level 0 / slice 0 (float targets clamped to 0..1), taken after the frame's GPU work,
// so a target reused within the frame shows its last contents. NXRT_RTDUMP_TEX=<pool id hex>,...
// adds the textures behind those texture-pool ids. With NXRT_SWEEP=<start>:<step>:<count> instead,
// every sweep frame dumps only the NXRT_RTDUMP_TEX textures, as <dir>/sweep_<draws>_<texture>.png:
// a filmstrip of a target across the frame's draws. ----
static int g_rtdump_frame = -2;
static const char *g_rtdump_dir;
static NSMutableArray<NSValue *> *g_rtdump_list;
static int rtdump_frame(void) {
    if (g_rtdump_frame == -2) {
        g_rtdump_dir = getenv("NXRT_RTDUMP");
        g_rtdump_frame = g_rtdump_dir ? (getenv("NXRT_RTDUMP_FRAME") ? atoi(getenv("NXRT_RTDUMP_FRAME")) : 1500) : -1;
    }
    return g_rtdump_frame;
}
static void rtdump_note(const void *tex) {
    extern volatile int g_gfx_frame;
    if (!tex || rtdump_frame() < 0 || g_gfx_frame != g_rtdump_frame || nx_sweep(g_gfx_frame, NULL)) return;
    if (!g_rtdump_list) g_rtdump_list = [NSMutableArray new];
    NSValue *v = [NSValue valueWithPointer:tex];
    if (![g_rtdump_list containsObject:v] && g_rtdump_list.count < 128) [g_rtdump_list addObject:v];
}
static int float_sampleable(MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatR8Unorm: case MTLPixelFormatRG8Unorm: case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB:
    case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB: case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatRG11B10Float:
    case MTLPixelFormatR16Float: case MTLPixelFormatRG16Float: case MTLPixelFormatRGBA16Float: case MTLPixelFormatR32Float:
    case MTLPixelFormatRG32Float: case MTLPixelFormatRGBA32Float: case MTLPixelFormatR16Unorm: case MTLPixelFormatRG16Unorm:
    case MTLPixelFormatRGBA16Unorm: case MTLPixelFormatDepth32Float: case MTLPixelFormatDepth16Unorm: return 1;
    default: return 0;
    }
}
static void rtdump_maybe(void) {
    extern volatile int g_gfx_frame;
    static int done, last_sweep = -1;
    if (rtdump_frame() < 0 || draw_check_only() || !draws_enabled()) return;
    long lim = 0;
    int f = g_gfx_frame - 1;                       // the frame whose draws were executed last
    int sweep = f != last_sweep && nx_sweep(f, &lim);
    if (sweep) {
        last_sweep = f;
        g_rtdump_list = [NSMutableArray new];
    } else {
        if (done || g_gfx_frame <= g_rtdump_frame) return;
        done = 1;
    }
    if (!g_rtdump_list) g_rtdump_list = [NSMutableArray new];
    char ids[256];
    snprintf(ids, sizeof ids, "%s", getenv("NXRT_RTDUMP_TEX") ? getenv("NXRT_RTDUMP_TEX") : "");
    for (char *t = strtok(ids, ","); t; t = strtok(NULL, ",")) {
        long id = strtol(t, NULL, 16);
        pthread_mutex_lock(&g_pool_lock);
        const void *tex = id >= 0 && id < g_ntex ? g_texslots[id].tex : NULL;
        pthread_mutex_unlock(&g_pool_lock);
        nx_log("gfx: rtdump: texture pool id %#lx -> NVN texture %p", id, tex);
        if (tex && ![g_rtdump_list containsObject:[NSValue valueWithPointer:tex]]) [g_rtdump_list addObject:[NSValue valueWithPointer:tex]];
    }
    [g_last_commit waitUntilCompleted];
    for (NSUInteger k = 0; !sweep && k < g_snaps.count; k++) {
        id<MTLTexture> src = g_snaps[k];
        if (src.width * src.height <= 256 && src.pixelFormat == MTLPixelFormatRGBA32Float) {   // small float snapshots: values
            id<MTLBuffer> rb = [g_dev newBufferWithLength:src.width * src.height * 16 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> c2 = [g_queue commandBuffer];
            id<MTLBlitCommandEncoder> b2 = [c2 blitCommandEncoder];
            [b2 copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:(MTLOrigin){0, 0, 0} sourceSize:(MTLSize){src.width, src.height, 1}
                       toBuffer:rb destinationOffset:0 destinationBytesPerRow:src.width * 16 destinationBytesPerImage:src.width * src.height * 16];
            [b2 endEncoding];
            [c2 commit];
            [c2 waitUntilCompleted];
            const float *f = rb.contents;
            char vals[600];
            int o = 0;
            int nz = 0;
            for (int q = 0; q < (int)(src.width * src.height); q++) {
                if (!f[q * 4] && !f[q * 4 + 1] && !f[q * 4 + 2] && !f[q * 4 + 3]) continue;
                if (nz++ < 8)
                    o += snprintf(vals + o, sizeof vals - o, " [%d,%d](%.3g %.3g %.3g %.3g)", q % (int)src.width, q / (int)src.width, f[q * 4],
                                  f[q * 4 + 1], f[q * 4 + 2], f[q * 4 + 3]);
            }
            nx_log("gfx: rtdump: snapshot %s: %d non-zero texels:%s", g_snap_names[k].UTF8String, nz, vals);
        }
        if (!float_sampleable(src.pixelFormat)) continue;
        NSUInteger w = src.width, h = src.height;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> dst = [g_dev newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = dst;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLRenderCommandEncoder> e = [cmd renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:gfx_blit_rect_pso(MTLPixelFormatRGBA8Unorm)];
        float r[4] = {0, 0, 1, 1};
        [e setFragmentBytes:r length:sizeof r atIndex:0];
        [e setFragmentTexture:src atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        [cmd commit];
        [cmd waitUntilCompleted];
        uint8_t *px = malloc(w * h * 4);
        [dst getBytes:px bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
        char path[1024];
        snprintf(path, sizeof path, "%s/before_%s.png", g_rtdump_dir, g_snap_names[k].UTF8String);
        gfx_write_png(path, px, w, h);
        free(px);
        nx_log("gfx: rtdump: snapshot %s (%lux%lu) -> %s", g_snap_names[k].UTF8String, (unsigned long)w, (unsigned long)h, path);
    }
    int order = 0;
    for (NSValue *v in g_rtdump_list) {
        const void *tex = v.pointerValue;
        id<MTLTexture> t = gfx_texture_mtl(tex);
        NxTexDesc desc = {0};
        nx_nvn_texture_desc(tex, &desc);
        order++;
        if (t && t.sampleCount == 1 && (t.pixelFormat == MTLPixelFormatDepth32Float || t.pixelFormat == MTLPixelFormatDepth32Float_Stencil8)) {
            // NXRT_RTDUMP_DEPTH=1: depth targets as raw little-endian float32, <order>_depth_<w>x<h>_<texture>.f32
            id<MTLBuffer> rb = [g_dev newBufferWithLength:t.width * t.height * 4 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> c2 = [g_queue commandBuffer];
            id<MTLBlitCommandEncoder> b2 = [c2 blitCommandEncoder];
            [b2 copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:(MTLOrigin){0, 0, 0} sourceSize:(MTLSize){t.width, t.height, 1}
                       toBuffer:rb destinationOffset:0 destinationBytesPerRow:t.width * 4 destinationBytesPerImage:t.width * t.height * 4
                        options:t.pixelFormat == MTLPixelFormatDepth32Float ? MTLBlitOptionNone : MTLBlitOptionDepthFromDepthStencil];
            [b2 endEncoding];
            [c2 commit];
            [c2 waitUntilCompleted];
            char path[1024];
            snprintf(path, sizeof path, "%s/%02d_depth_%lux%lu_%p.f32", g_rtdump_dir, order, (unsigned long)t.width, (unsigned long)t.height, tex);
            FILE *fp = fopen(path, "wb");
            if (fp) fwrite(rb.contents, 4, t.width * t.height, fp), fclose(fp);
            nx_log("gfx: rtdump: depth %p -> %s", tex, path);
            continue;
        }
        if (t && getenv("NXRT_RTDUMP_MIPS") && t.mipmapLevelCount > 1 && t.sampleCount == 1 &&
            (t.pixelFormat == MTLPixelFormatRGBA8Unorm || t.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB)) {
            // NXRT_RTDUMP_MIPS=1: every mip level of RGBA8 textures, alpha composited over white
            for (NSUInteger lv = 0; lv < t.mipmapLevelCount; lv++) {
                NSUInteger w = MAX(1, t.width >> lv), h = MAX(1, t.height >> lv);
                uint8_t *px = malloc(w * h * 4);
                id<MTLBuffer> rb = [g_dev newBufferWithLength:w * h * 4 options:MTLResourceStorageModeShared];
                id<MTLCommandBuffer> c2 = [g_queue commandBuffer];
                id<MTLBlitCommandEncoder> b2 = [c2 blitCommandEncoder];
                [b2 copyFromTexture:t sourceSlice:0 sourceLevel:lv sourceOrigin:(MTLOrigin){0, 0, 0} sourceSize:(MTLSize){w, h, 1}
                           toBuffer:rb destinationOffset:0 destinationBytesPerRow:w * 4 destinationBytesPerImage:w * h * 4];
                [b2 endEncoding];
                [c2 commit];
                [c2 waitUntilCompleted];
                const uint8_t *p = rb.contents;
                for (NSUInteger i = 0; i < w * h; i++) {
                    unsigned a = p[4 * i + 3];
                    for (int k = 0; k < 3; k++) px[4 * i + k] = (uint8_t)((p[4 * i + k] * a + 255 * (255 - a)) / 255);
                    px[4 * i + 3] = 255;
                }
                char path[1024];
                snprintf(path, sizeof path, "%s/%02d_mip%lu_%lux%lu_%p.png", g_rtdump_dir, order, (unsigned long)lv, (unsigned long)w, (unsigned long)h, tex);
                gfx_write_png(path, px, (int)w, (int)h);
                free(px);
            }
        }
        if (!t || t.sampleCount > 1 || !float_sampleable(t.pixelFormat)) {
            nx_log("gfx: rtdump: %02d %p %dx%d NVN fmt %d skipped (Metal format %lu)", order, tex, desc.w, desc.h, desc.format,
                   (unsigned long)t.pixelFormat);
            continue;
        }
        id<MTLTexture> src = t.textureType == MTLTextureType2D ? t
            : [t newTextureViewWithPixelFormat:t.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(0, 1) slices:NSMakeRange(0, 1)];
        if (t.width * t.height <= 256 && (t.pixelFormat == MTLPixelFormatRGBA32Float || t.pixelFormat == MTLPixelFormatRGBA16Float ||
                                          t.pixelFormat == MTLPixelFormatR32Float || t.pixelFormat == MTLPixelFormatRG32Float)) {
            NSUInteger bpp = t.pixelFormat == MTLPixelFormatRGBA32Float ? 16 : t.pixelFormat == MTLPixelFormatRG32Float ? 8
                           : t.pixelFormat == MTLPixelFormatRGBA16Float ? 8 : 4;
            id<MTLBuffer> rb = [g_dev newBufferWithLength:t.width * t.height * bpp options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> c2 = [g_queue commandBuffer];
            id<MTLBlitCommandEncoder> b2 = [c2 blitCommandEncoder];
            [b2 copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:(MTLOrigin){0, 0, 0} sourceSize:(MTLSize){t.width, t.height, 1}
                       toBuffer:rb destinationOffset:0 destinationBytesPerRow:t.width * bpp destinationBytesPerImage:t.width * t.height * bpp];
            [b2 endEncoding];
            [c2 commit];
            [c2 waitUntilCompleted];
            char vals[512];
            int o = 0;
            for (int q = 0; q < 4 && q < (int)(t.width * t.height); q++) {
                float f[4] = {0};
                if (bpp == 16) memcpy(f, (const uint8_t *)rb.contents + q * 16, 16);
                else if (t.pixelFormat == MTLPixelFormatRGBA16Float)
                    for (int c = 0; c < 4; c++) f[c] = (float)((const __fp16 *)rb.contents)[q * 4 + c];
                else memcpy(f, (const uint8_t *)rb.contents + q * bpp, bpp);
                o += snprintf(vals + o, sizeof vals - o, " (%g %g %g %g)", f[0], f[1], f[2], f[3]);
            }
            nx_log("gfx: rtdump: %p %lux%lu texels:%s", tex, (unsigned long)t.width, (unsigned long)t.height, vals);
        }
        NSUInteger w = t.width, h = t.height;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> dst = [g_dev newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = dst;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLRenderCommandEncoder> e = [cmd renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:gfx_blit_rect_pso(MTLPixelFormatRGBA8Unorm)];
        float r[4] = {0, 0, 1, 1};
        [e setFragmentBytes:r length:sizeof r atIndex:0];
        [e setFragmentTexture:src atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        [cmd commit];
        [cmd waitUntilCompleted];
        uint8_t *px = malloc(w * h * 4);
        [dst getBytes:px bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
        uint64_t sum = 0;
        for (NSUInteger i = 0; i < w * h * 4; i += 4) sum += px[i] + px[i + 1] + px[i + 2];
        char path[1024];
        if (sweep) snprintf(path, sizeof path, "%s/sweep_%05ld_%p.png", g_rtdump_dir, lim, tex);
        else snprintf(path, sizeof path, "%s/%02d_%lux%lu_f%d_%p.png", g_rtdump_dir, order, (unsigned long)w, (unsigned long)h, desc.format, tex);
        gfx_write_png(path, px, w, h);
        free(px);
        nx_log("gfx: rtdump: %02d %p %lux%lu NVN fmt %d type %lu: mean rgb %.1f -> %s", order, tex, (unsigned long)w, (unsigned long)h,
               desc.format, (unsigned long)t.textureType, sum / (3.0 * w * h), path);
    }
}

// Commits the command buffer being encoded: its arena chunks and completion writes (events, counters)
// go with it. cont = 1: mid-submit (see end_pass), encoding continues in a new command buffer, so the
// GPU starts on the frame's first passes while the rest is still being encoded.
static pthread_mutex_t g_done_lock = PTHREAD_MUTEX_INITIALIZER;   // signaled when a command buffer completes
static pthread_cond_t g_done_cond = PTHREAD_COND_INITIALIZER;
static void commit_cmd(int cont) {
    gfx_wait_foreground();
    NSData *writes = g_completion_writes.length ? g_completion_writes : nil;
    uint64_t first = g_cmd_first_draw, last = g_draw_seq;
    g_cmd_first_draw = g_draw_seq;
    [E_cmd addCompletedHandler:^(id<MTLCommandBuffer> c) {
        static double scale = -1;
        if (scale < 0) scale = getenv("NXRT_GPU_TIME_SCALE") && atof(getenv("NXRT_GPU_TIME_SCALE")) > 0 ? atof(getenv("NXRT_GPU_TIME_SCALE")) : 1;
        uint64_t a = (uint64_t)(c.GPUStartTime * 1e9), b = (uint64_t)(c.GPUEndTime * 1e9), busy = 0;
        pthread_mutex_lock(&g_vclock_lock);
        if (a < g_vclock_last_end) a = g_vclock_last_end;
        if (b > a) busy = (uint64_t)((b - a) * scale);
        if (b > g_vclock_last_end) g_vclock_last_end = b;
        uint64_t start = g_vclock_ns;
        g_vclock_ns += busy;
        pthread_mutex_unlock(&g_vclock_lock);
        if (!writes) return;
        const uint8_t *p = writes.bytes, *end = p + writes.length;
        while (p < end) {
            if (*p++ == 'E') {
                OpSignal s;
                memcpy(&s, p, sizeof s);
                p += sizeof s;
                if (s.mode == 1) __atomic_fetch_add(s.mem, s.value, __ATOMIC_RELEASE);
                else __atomic_store_n(s.mem, s.value, __ATOMIC_RELEASE);
            } else {
                CounterWrite k;
                memcpy(&k, p, sizeof k);
                p += sizeof k;
                // {counter, timestamp}. The engine diffs pairs of reports read from memory; with a
                // constant (or a time shared by every report in one command buffer) the difference was
                // 0, so objects tested while the camera moved counted as hidden and vanished until it
                // stopped. The counter strictly increases per report (command buffers complete in order).
                // The timestamp is the GPU-busy clock at the report's place in this command buffer (by
                // draws encoded before it), in GPU ticks (ns * 384 / 625, as NVN converts back).
                static uint64_t seq;
                double frac = last > first ? (double)(k.pos - first) / (double)(last - first) : 0;
                uint64_t ns = start + (uint64_t)(busy * frac);
                if (!(k.type & 0x10000)) k.mem[0] = ++seq * 1024;   // timestamp reports: counter 0, already written
                k.mem[1] = ns * 384 / 625;
            }
        }
    }];
    g_completion_writes = nil;
    NSArray<id<MTLBuffer>> *chunks = A_used;
    A_used = nil;
    A_buf = nil;
    [E_cmd addCompletedHandler:^(id<MTLCommandBuffer> c) {
        pthread_mutex_lock(&g_arena_lock);
        if (!g_arena_free) g_arena_free = [NSMutableArray new];
        [g_arena_free addObjectsFromArray:chunks];
        // Spikes (loading) leave chunks nobody needs afterwards: keep a few spare, release the rest.
        if (g_arena_free.count > (NSUInteger)g_arena_keep)
            [g_arena_free removeObjectsInRange:NSMakeRange(g_arena_keep, g_arena_free.count - g_arena_keep)];
        pthread_mutex_unlock(&g_arena_lock);
    }];
    uint64_t ndraws = g_stats_draws - g_draws_at_submit, seq = g_ring_n;
    g_draws_at_submit = g_stats_draws;
    [E_cmd addCompletedHandler:^(id<MTLCommandBuffer> c) {
        if (c.status == MTLCommandBufferStatusError) gpu_failed(c);
        __atomic_store_n(&g_completed_seq, seq, __ATOMIC_RELEASE);
        pthread_mutex_lock(&g_done_lock);   // wake SyncWait
        pthread_cond_broadcast(&g_done_cond);
        pthread_mutex_unlock(&g_done_lock);
        double ms = (c.GPUEndTime - c.GPUStartTime) * 1000;
        __atomic_fetch_add(&g_gpu_ns, (uint64_t)(ms * 1e6), __ATOMIC_RELAXED);
        uint64_t a = (uint64_t)(c.GPUStartTime * 1e9), b = (uint64_t)(c.GPUEndTime * 1e9);
        if (a < g_gpu_last_end_ns) a = g_gpu_last_end_ns;
        if (b > a) __atomic_fetch_add(&g_gpu_busy_ns, b - a, __ATOMIC_RELAXED), __atomic_fetch_add(&g_hitch_gpu_ns, b - a, __ATOMIC_RELAXED);
        if (b > g_gpu_last_end_ns) g_gpu_last_end_ns = b;
        static int slow;
        if (ms > 100 && slow++ < 20)
            nx_log("gfx: slow command buffer #%llu: %.0f ms on the GPU, %llu draws", (unsigned long long)seq, ms, (unsigned long long)ndraws);
    }];
    prof_commit(E_cmd);
    [E_cmd commit];
    g_ring[g_ring_n % 16] = (CmdRec){g_ring_n, ndraws, clock_gettime_nsec_np(CLOCK_UPTIME_RAW)};
    g_ring_n++;
    g_last_commit = E_cmd;
    if (cont) {
        g_stats_chunks++;
        E_cmd = [g_queue commandBuffer];
        A_used = [NSMutableArray new];
        A_buf = nil;
        g_completion_writes = [NSMutableData new];
    }
}

static void queue_submit_inner(void *queue, int32_t n, const uint64_t *handles);
// Encoding takes ~20 ms of host work: other threads on this emulated core may run meanwhile (on the
// Switch the GPU does this work, not the core).
static void queue_submit(void *queue, int32_t n, const uint64_t *handles) {
    nx_core_leave();
    queue_submit_inner(queue, n, handles);
    nx_core_enter();
}
static void queue_submit_inner(void *queue, int32_t n, const uint64_t *handles) {
    @autoreleasepool {
        gfx_init();
        pthread_mutex_lock(&g_exec_lock);
        exec_init();
        rtdump_maybe();
        extern volatile int g_gfx_frame;
        if (dbg() && (g_gfx_frame == 900 || g_gfx_frame == 901)) {
            for (int32_t i = 0; i < n && handles; i++)
                nx_log("gfx: dbg submit queue %p handle[%d/%d] %#llx", queue, i, n, (unsigned long long)handles[i]);
            if (g_gfx_frame == 900 && n && handles) {
                uint64_t lo = handles[0] - 0x100, hi = handles[0] - 1;
                int hits = 0;
                const uint8_t *base = (const uint8_t *)g_as.heap_base;
                for (uint64_t o = 0; o + 8 <= g_as.heap_used && hits < 60; o += 8) {
                    uint64_t v;
                    memcpy(&v, base + o, 8);
                    if (v >= lo && v <= hi) {
                        nx_log("gfx: dbg heap+%#llx (%p) holds handle %#llx; next qwords %#llx %#llx %#llx", (unsigned long long)o,
                               base + o, (unsigned long long)v, (unsigned long long)((const uint64_t *)(base + o))[1],
                               (unsigned long long)((const uint64_t *)(base + o))[2], (unsigned long long)((const uint64_t *)(base + o))[3]);
                        hits++;
                    }
                }
                nx_log("gfx: dbg heap scan %#llx bytes: %d hits", (unsigned long long)g_as.heap_used, hits);
                scan_chunks_for_handles(lo, hi);
                nx_log("gfx: dbg %d memory chunks added so far", g_nchunks);
            }
        }
        if (bp_enabled())
            for (int32_t i = 0; i < n && handles; i++) nx_log("bp: queue SubmitCommands %#llx", (unsigned long long)handles[i]);
        nx_guest_qos_raise("submit");   // the encode runs on this thread
        residency_sync();
        listgc_expire();
        E_cmd = [g_queue commandBuffer];
        g_in_submit = 1;
        g_tex_gen++;
        if (tmc_on()) tmc_sweep();
        hist("texgen bumps: 0 register, 1 drop, 2 submit", 2);
        uint64_t t_encode = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), c_encode = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
        A_used = [NSMutableArray new];
        A_buf = nil;
        g_completion_writes = [NSMutableData new];
        pthread_mutex_lock(&g_handle_lock);
        NSArray<NSNumber *> *pending = g_pending;
        g_pending = nil;
        NSSet<NSNumber *> *called = g_called_set;
        g_called_set = nil;
        pthread_mutex_unlock(&g_handle_lock);
        NSMutableSet<NSNumber *> *submitted = called ? [called mutableCopy] : [NSMutableSet set];
        for (int32_t i = 0; i < n && handles; i++) [submitted addObject:@(handles[i])];
        for (NSNumber *h in pending) {
            if ([submitted containsObject:h]) continue;
            pthread_mutex_lock(&g_handle_lock);
            const Blob *d = handle_lookup(h.unsignedLongLongValue);
            blob_acquire(d);
            pthread_mutex_unlock(&g_handle_lock);
            if (d) exec_ops(d);
            blob_release(d);
        }
        for (int32_t i = 0; i < n && handles; i++) {
            pthread_mutex_lock(&g_handle_lock);
            const Blob *d = ops_for_handle(handles[i]);
            blob_acquire(d);
            pthread_mutex_unlock(&g_handle_lock);
            if (d) exec_ops(d);
            blob_release(d);
            g_submitted++;
        }
        flush_clears();
        pc_tick();
        g_in_submit = 0;
        end_pass_why(PE_SUBMIT);
        g_encode_ns += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t_encode;
        g_hitch_encode_ns += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t_encode;
        g_hitch_encode_cpu_ns += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c_encode;
        double encode_ms = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t_encode) / 1e6;
        static int slow_encode;
        extern uint64_t g_tex_upload_ns, g_tex_upload_n, g_tex_upload_bytes, g_tex_lookup_ns;
        static uint64_t up_ns0, up_n0, up_b0, lk_ns0, cw_ns0, cw_n0, sl_ns0, sl_n0, pc0, fh0, fm0, fn_ns0;
        if (encode_ms > 200 && slow_encode++ < 40)
            nx_log("gfx: slow encode: %.0f ms for %llu draws; texture lookups %.0f ms, of which %llu uploads %.0f ms (%.1f MB); "
                   "%llu compile waits %.0f ms; %llu shader loads %.0f ms (metallib %llu hits, %llu misses, lookups %.0f ms); %llu new pipelines", encode_ms,
                   (unsigned long long)(g_stats_draws - g_draws_at_submit), (g_tex_lookup_ns - lk_ns0) / 1e6,
                   (unsigned long long)(g_tex_upload_n - up_n0), (g_tex_upload_ns - up_ns0) / 1e6, (g_tex_upload_bytes - up_b0) / 1e6,
                   (unsigned long long)(g_compile_waits - cw_n0), (g_compile_wait_ns - cw_ns0) / 1e6,
                   (unsigned long long)(g_shader_loads - sl_n0), (g_shader_load_ns - sl_ns0) / 1e6, (unsigned long long)(g_fn_hits - fh0),
                   (unsigned long long)(g_fn_misses - fm0), (g_fn_ns - fn_ns0) / 1e6, (unsigned long long)(g_pipes_created - pc0));
        up_ns0 = g_tex_upload_ns, up_n0 = g_tex_upload_n, up_b0 = g_tex_upload_bytes, lk_ns0 = g_tex_lookup_ns;
        cw_ns0 = g_compile_wait_ns, cw_n0 = g_compile_waits, sl_ns0 = g_shader_load_ns, sl_n0 = g_shader_loads, pc0 = g_pipes_created;
        fh0 = g_fn_hits, fm0 = g_fn_misses, fn_ns0 = g_fn_ns;
        static int submits;
        if (g_harvest && ++submits % 600 == 0) harvest_save();   // NXRT_HARVEST: keep the file current (runs end by being killed)
        commit_cmd(0);
        E_cmd = nil;
        pthread_mutex_unlock(&g_exec_lock);
    }
}

// Recently committed command buffers, dumped when a wait times out (which one is blocking?).
static void dump_ring(void) {
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    for (uint64_t i = g_ring_n > 16 ? g_ring_n - 16 : 0; i < g_ring_n; i++) {
        CmdRec r = g_ring[i % 16];
        nx_log("gfx:   cmdbuf #%llu: %llu draws, committed %.0f ms ago", (unsigned long long)r.seq, (unsigned long long)r.draws,
               (now - r.t) / 1e6);
    }
}

// Freeze watchdog (crash.c): GPU queue state and which of our locks are held. trylock only (a stuck thread may own them).
void gfx_watchdog_dump(void) {
    extern volatile int g_gfx_frame;
    int exec = pthread_mutex_trylock(&g_exec_lock), done = pthread_mutex_trylock(&g_done_lock),
        arena = pthread_mutex_trylock(&g_arena_lock), klock = pthread_mutex_trylock(&g_klock);
    int status = -1;
    if (!exec && g_last_commit) status = (int)g_last_commit.status;
    nx_log("watchdog: gfx: frame %d, %llu command buffers committed, completed through #%llu, last commit status %d%s; locks held:%s%s%s%s",
           g_gfx_frame, (unsigned long long)g_ring_n, (unsigned long long)__atomic_load_n(&g_completed_seq, __ATOMIC_ACQUIRE), status,
           exec ? " (exec lock held: status unknown)" : "", exec ? " exec" : "", done ? " done" : "", arena ? " arena" : "",
           klock ? " kernel" : "");
    dump_ring();
    if (!klock) pthread_mutex_unlock(&g_klock);
    if (!arena) pthread_mutex_unlock(&g_arena_lock);
    if (!done) pthread_mutex_unlock(&g_done_lock);
    if (!exec) pthread_mutex_unlock(&g_exec_lock);
}

// Fences: a sync object remembers the last committed command buffer; waiting really waits.
static NSMapTable *g_syncs;
static void queue_fence_sync(void *queue, void *sync, int32_t cond, int32_t flags) {
    @autoreleasepool {
        pthread_mutex_lock(&g_exec_lock);
        if (!g_syncs) g_syncs = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality valueOptions:NSPointerFunctionsStrongMemory];
        if (g_last_commit) [g_syncs setObject:g_last_commit forKey:KEY(sync)];
        else [g_syncs removeObjectForKey:KEY(sync)];
        pthread_mutex_unlock(&g_exec_lock);
    }
}
static int32_t sync_wait_inner(void *sync, uint64_t timeout);
// The game's thread gives up its emulated core while it waits for the GPU (cores.c).
static int32_t sync_wait(void *sync, uint64_t timeout) {
    if (!timeout) return sync_wait_inner(sync, timeout);
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    nx_core_leave();
    int32_t r = sync_wait_inner(sync, timeout);
    nx_core_enter();
    __atomic_fetch_add(&g_hitch_block_ns, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0, __ATOMIC_RELAXED);
    __atomic_fetch_add(&g_stat_block_ns, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0, __ATOMIC_RELAXED);
    return r;
}
static int32_t sync_wait_inner(void *sync, uint64_t timeout) {
    @autoreleasepool {
        pthread_mutex_lock(&g_exec_lock);
        id<MTLCommandBuffer> c = g_syncs ? [g_syncs objectForKey:KEY(sync)] : nil;
        pthread_mutex_unlock(&g_exec_lock);
        if (!c || c.status >= MTLCommandBufferStatusCompleted) return 0;   // ALREADY_SIGNALED
        static int block = -1;   // NXRT_SYNCBLOCK=1 (diagnostic): never report "still busy", wait instead
        if (block < 0) block = getenv("NXRT_SYNCBLOCK") != NULL;
        if (block) {
            static uint64_t n;
            if (n++ % 1000 == 0) nx_log("gfx: SYNCBLOCK: blocking wait #%llu (timeout was %llu ns)", (unsigned long long)n, (unsigned long long)timeout);
            [c waitUntilCompleted];
            return 1;
        }
        if (timeout == 0) return 2;                                          // TIMEOUT_EXPIRED
        // Woken by the completion handler (commit_cmd); polling every 1 ms added ~0.5 ms per wait.
        uint64_t end = clock_gettime_nsec_np(CLOCK_REALTIME) + 2000000000ull;
        pthread_mutex_lock(&g_done_lock);
        while (c.status < MTLCommandBufferStatusCompleted && clock_gettime_nsec_np(CLOCK_REALTIME) < end) {
            uint64_t t = MIN(end, clock_gettime_nsec_np(CLOCK_REALTIME) + 5000000ull);   // re-check at least every 5 ms
            struct timespec ts = {(time_t)(t / 1000000000ull), (long)(t % 1000000000ull)};
            pthread_cond_timedwait(&g_done_cond, &g_done_lock, &ts);
        }
        pthread_mutex_unlock(&g_done_lock);
        if (c.status < MTLCommandBufferStatusCompleted) {
            static int n;
            if (n++ < 4) {
                nx_log("gfx: SyncWait: command buffer still not complete after 2 s (status %d); completed through #%llu", (int)c.status,
                       (unsigned long long)__atomic_load_n(&g_completed_seq, __ATOMIC_ACQUIRE));
                pthread_mutex_lock(&g_exec_lock);
                dump_ring();
                pthread_mutex_unlock(&g_exec_lock);
            }
            return 2;
        }
        return 1;                                                            // CONDITION_SATISFIED
    }
}
static void queue_finish(void *queue) {
    pthread_mutex_lock(&g_exec_lock);
    id<MTLCommandBuffer> c = g_last_commit;
    pthread_mutex_unlock(&g_exec_lock);
    nx_core_leave();
    [c waitUntilCompleted];
    nx_core_enter();
}

// Ring filled by src/probe_hooks.S (NXRT_EXECPROBE): pass executor calls with their early-out tests.
struct { uint64_t idx, ret, pad[2]; struct { uint64_t lr, renderer, req; uint32_t req_mask, pad; uint64_t pass; uint32_t pass_mask, pass_2c, renderer_b, pad2[3]; } e[4096]; } nx_probe;
struct { uint64_t calls, ret, last; } nx_probe2;   // view-job probe (src/probe_hooks.S)
struct { uint64_t calls, ret, last; } nx_probe3;   // stage probe: G
static void view_probe_dump(void) {
    const uint8_t *R = (const uint8_t *)__atomic_load_n(&nx_probe2.last, __ATOMIC_ACQUIRE);
    if (!R) { nx_log("viewprobe: no view job yet"); return; }
    int32_t count = *(const int32_t *)(R + 0x378);
    const uint8_t *const *views = *(const uint8_t *const *const *)(R + 0x380);
    nx_log("viewprobe: %llu jobs; R %p, %d views", (unsigned long long)nx_probe2.calls, R, count);
    const uint8_t *G = (const uint8_t *)__atomic_load_n(&nx_probe3.last, __ATOMIC_ACQUIRE);
    nx_log("viewprobe: stage calls %llu, G %p%s", (unsigned long long)nx_probe3.calls, G, G == R ? " (same as R)" : "");
    if (G) R = G;
    const uint8_t *sr = *(const uint8_t *const *)(R + 0x3b80);
    if (sr) {
        const uint64_t *vt = *(const uint64_t *const *)sr;
        nx_log("viewprobe: [R+0x3b80] = %p vtable main+%#lx", sr, main_off((void *)vt));
        for (int k = 0; k < 24; k++) nx_log("viewprobe:   slot +%#x -> main+%#lx", k * 8, main_off((void *)vt[k]));
    } else nx_log("viewprobe: [R+0x3b80] = NULL");
    nx_log("viewprobe: [R+0x3210] = %p, [R+0x3b88] = %p", *(void *const *)(R + 0x3210), *(void *const *)(R + 0x3b88));
    for (int i = 0; i < count && i < 64 && views; i++) {
        const uint8_t *v = views[i];
        if (!v) continue;
        nx_log("viewprobe:   [%d] %p vtable main+%#lx flags88 %#x flags8a %#x +94 %#x", i, v, main_off(*(void *const *)v),
               *(const uint16_t *)(v + 0x88), *(const uint16_t *)(v + 0x8a), *(const uint32_t *)(v + 0x94));
    }
}
// Stage delegate probe ring (src/probe_hooks.S): which render-stage events arrive, and the early-outs.
struct { uint64_t calls, ret, pad[2]; struct { uint64_t ev, obj, fn, adj; } e[1024]; } nx_probe4;
static void stage_probe_dump(void) {
    static uint64_t seen;
    uint64_t end = __atomic_load_n(&nx_probe4.calls, __ATOMIC_ACQUIRE), start = end > seen + 1024 ? end - 1024 : seen;
    seen = end;
    NSCountedSet *by = [NSCountedSet new];
    for (uint64_t i = start; i < end; i++) {
        typeof(nx_probe4.e[0]) e = nx_probe4.e[i & 1023];
        NSString *why = @"";
        if (e.fn == (uint64_t)nx_module("main")->base + 0x222ed88 && !(e.adj & 1) && e.obj) {
            const uint8_t *o = (const uint8_t *)(e.obj + ((int64_t)e.adj >> 1));
            uint16_t f884 = *(const uint16_t *)(o + 0x884);
            uint64_t p228 = *(const uint64_t *)(o + 0x228), g = *(const uint64_t *)(o + 0x888);
            uint8_t f8e9 = o[0x8e9];
            static int shown;
            if (!shown++) nx_log("stageprobe: stage object %p (+0x8e9 at %p)", o, o + 0x8e9);
            why = [NSString stringWithFormat:@" obj+0x884&0x10 %d, obj+0x228 %s, G %s, obj+0x8e9 bit3 %d", (f884 & 0x10) != 0,
                                             p228 ? "set" : "0", g ? "set" : "NULL", (f8e9 >> 3) & 1];
        } else why = [NSString stringWithFormat:@" other handler main+%#lx", main_off((void *)e.fn)];
        [by addObject:[NSString stringWithFormat:@"stage %u flag %u%@", (uint32_t)e.ev, (uint32_t)(e.ev >> 32), why]];
    }
    nx_log("stageprobe: %llu events", (unsigned long long)end);
    for (NSString *k in by) nx_log("stageprobe: %5lu x %s", (unsigned long)[by countForObject:k], k.UTF8String);
}
struct { uint64_t calls, ret, last; } nx_probe5;   // scene state machine probe: S
struct { uint64_t calls, ret, last; } nx_probe6;   // timed sequence probe: T
struct { uint64_t calls, ret, last; } nx_probe7;   // boot sequence owner M
static void boot_probe_dump(void) {
    const uint8_t *fo = *(const uint8_t *const *)(nx_module("main")->base + 0x32cb6e8);
    fo = fo ? *(const uint8_t *const *)fo : NULL;
    if (fo) nx_log("bootprobe: [[main+0x32cb6e8]] = %p: +0x10 %d +0x18 %d +0x1c %u", fo, *(const int32_t *)(fo + 0x10), *(const int32_t *)(fo + 0x18), fo[0x1c]);
    static int vt_once;
    if (fo && !vt_once++) {
        const uint64_t *vt = *(const uint64_t *const *)fo;
        nx_log("bootprobe: frame object vtable main+%#lx", main_off((void *)vt));
        for (int k = 0; k < 16; k++) nx_log("bootprobe:   slot +%#x main+%#lx", k * 8, main_off((void *)vt[k]));
        const uint64_t *q = (const uint64_t *)fo;
        nx_log("bootprobe:   words %llx %llx %llx %llx %llx %llx", q[0], q[1], q[2], q[3], q[4], q[5]);
    }
    const uint64_t *M = (const uint64_t *)nx_probe7.last;
    if (!M) { nx_log("bootprobe: not registered"); return; }
    char line[512];
    int o = 0;
    for (int i = 0; i < 16; i++) o += snprintf(line + o, sizeof line - o, " %llx", (unsigned long long)M[i]);
    nx_log("bootprobe: M %p words:%s", M, line);
    static int once;
    if (once++) return;
    const uint8_t *st = (const uint8_t *)M[10];
    for (int i = 0; st && i < (int)(uint32_t)M[9] && i < 32; i++)
        nx_log("bootprobe:   state %2d exec main+%#lx", i, main_off(*(void *const *)(st + i * 0x40 + 0x20)));
}
static void exec_probe_dump(void) {
    boot_probe_dump();
    const uint8_t *T = (const uint8_t *)nx_probe6.last;
    if (T) nx_log("seqprobe: %llu calls, T %p: +0x24 %d +0x43 %u +0x9c %u +0xa0 %d +0xa4 %d +0xa8 %d +0xac %d +0xc8 %u", (unsigned long long)nx_probe6.calls, T,
                  *(const int32_t *)(T + 0x24), T[0x43], T[0x9c], *(const int32_t *)(T + 0xa0), *(const int32_t *)(T + 0xa4),
                  *(const int32_t *)(T + 0xa8), *(const int32_t *)(T + 0xac), T[0xc8]);
    else nx_log("seqprobe: main+0x7ad02c never called");
    const uint8_t *S5 = (const uint8_t *)nx_probe5.last;
    if (S5) nx_log("stateprobe: %llu calls, S %p: +0x4e8 %u +0x4e9 %u +0x4ec %#x +0xcc %d +0xec %#x +0xf4 %u +0x100 %p", (unsigned long long)nx_probe5.calls,
                   S5, S5[0x4e8], S5[0x4e9], S5[0x4ec], *(const int32_t *)(S5 + 0xcc), *(const uint32_t *)(S5 + 0xec), S5[0xf4], *(void *const *)(S5 + 0x100));
    stage_probe_dump();
    view_probe_dump();
    static uint64_t seen;
    uint64_t end = __atomic_load_n(&nx_probe.idx, __ATOMIC_ACQUIRE), start = end > seen + 4096 ? end - 4096 : seen;
    seen = end;
    nx_log("execprobe: %llu executor calls so far", (unsigned long long)end);
    NSCountedSet *by = [NSCountedSet new];
    for (uint64_t i = start; i < end; i++) {
        typeof(nx_probe.e[0]) e = nx_probe.e[i & 4095];
        [by addObject:[NSString stringWithFormat:@"main+%#lx req %#x & pass %#x, pass+0x2c %d, renderer+0xb %d%s",
                                                 main_off((void *)e.lr), e.req_mask, e.pass ? e.pass_mask : 0, e.pass ? (int)e.pass_2c : -1,
                                                 e.renderer_b & 1, e.pass ? "" : " (no pass)"]];
    }
    for (NSString *k in by) nx_log("execprobe: %4lu x %s", (unsigned long)[by countForObject:k], k.UTF8String);
}

// NXRT_SKIPPROBE ring (src/probe_hooks.S): the engine's bind function found a mesh's wrapper slot
// for this frame's variant not ready (bit 1 clear) and skipped the bind. Are the other variants of
// that slot ready (reader and writer disagree on the frame), or none (the wrapper job is late)?
struct { uint64_t calls, skip, ret, pad; struct { uint64_t slot, variant, item, renderer; uint8_t flags[4]; uint32_t rframe;
                                                  uint8_t item1d, item8_14, pad2[6]; uint64_t t, pad3; } e[1024]; } nx_skipprobe;
static void skip_probe_dump(void) {
    static uint64_t seen;
    uint64_t end = __atomic_load_n(&nx_skipprobe.calls, __ATOMIC_ACQUIRE), start = end > seen + 1024 ? end - 1024 : seen;
    seen = end;
    nx_log("skipprobe: %llu skips so far, %llu ready binds", (unsigned long long)end, (unsigned long long)nx_skipprobe.pad);
    NSCountedSet *by = [NSCountedSet new];
    for (uint64_t i = start; i < end; i++) {
        typeof(nx_skipprobe.e[0]) e = nx_skipprobe.e[i & 1023];
        char fl[16];
        for (int v = 0; v < 4; v++) fl[v] = "0123"[e.flags[v] & 3];
        fl[4] = 0;
        [by addObject:[NSString stringWithFormat:@"variant %llu, slot flags v0..3 = %s, renderer frame %u, item+0x1d&3 %d, [item+8]+0x14 %#x",
                                                 (unsigned long long)e.variant, fl, e.rframe, e.item1d & 3, e.item8_14]];
    }
    int shown = 0;
    for (NSString *k in by)
        if (shown++ < 24) nx_log("skipprobe: %4lu x %s", (unsigned long)[by countForObject:k], k.UTF8String);
}

// NXRT_VOBJPROBE ring (src/probe_hooks.S): vertex objects that had no valid attributes when the
// fallback ran (bind list baked empty). Re-read now: built since = a race with the bake.
struct { uint64_t calls, skip, ret, pass; struct { const uint8_t *vobj; uint64_t lr; } e[256]; } nx_vobjprobe;
static void vobj_probe_dump(void) {
    uint64_t end = __atomic_load_n(&nx_vobjprobe.calls, __ATOMIC_ACQUIRE);
    nx_log("vobjprobe: %llu empty-attribute skips, %llu normal binds so far", (unsigned long long)end, (unsigned long long)nx_vobjprobe.pass);
    NSCountedSet *by = [NSCountedSet new];
    for (uint64_t i = end > 256 ? end - 256 : 0; i < end; i++) {
        typeof(nx_vobjprobe.e[0]) e = nx_vobjprobe.e[i & 255];
        [by addObject:[NSString stringWithFormat:@"caller main+%#lx, valid attributes now %u of %u", main_off((void *)e.lr), e.vobj[0x225], e.vobj[0x224]]];
    }
    for (NSString *k in by) nx_log("vobjprobe: %4lu x %s", (unsigned long)[by countForObject:k], k.UTF8String);
}

// NXRT_LOWDIFF=1: per-frame draw counts by (vs, fs); when a frame has <90% of the previous frame's
// draws, log the shader pairs that lost draws (which objects vanished in a flicker frame).
typedef struct { uint64_t vs, fs; uint32_t n[2]; } LowDiff;
static LowDiff g_lowdiff[4096];
static int g_lowdiff_cur;
static int lowdiff_on(void) {
    static int on = -1;
    if (on < 0) on = getenv("NXRT_LOWDIFF") != NULL;
    return on;
}
static void lowdiff_count(uint64_t vs, uint64_t fs) {
    if (!lowdiff_on()) return;
    uint64_t h = (vs * 0x9E3779B97F4A7C15ull) ^ fs;
    for (unsigned i = (unsigned)(h >> 52), k = 0; k < 4096; i = (i + 1) & 4095, k++) {
        LowDiff *e = &g_lowdiff[i];
        if (!e->vs && !e->fs) e->vs = vs, e->fs = fs;
        if (e->vs == vs && e->fs == fs) { e->n[g_lowdiff_cur]++; return; }
    }
}
static void lowdiff_frame(int frame, uint64_t draws) {
    static uint64_t prev;
    if (!lowdiff_on()) return;
    int c = g_lowdiff_cur, p = c ^ 1;
    if (prev && draws * 10 < prev * 9) {
        nx_log("lowdiff: frame %d has %llu draws (previous %llu); pairs that lost draws:", frame, (unsigned long long)draws, (unsigned long long)prev);
        for (int i = 0; i < 4096; i++) {
            LowDiff *e = &g_lowdiff[i];
            if (e->n[p] > e->n[c])
                nx_log("lowdiff:   vs %016llx fs %016llx %u -> %u", (unsigned long long)e->vs, (unsigned long long)e->fs, e->n[p], e->n[c]);
        }
    }
    if (prev && draws * 10 < prev * 9)
        for (int i = 0; i < 1024; i++) {
            SiteTally *e = &g_sites[i];
            int sc = g_site_cur;
            if (e->lr && e->n[sc ^ 1] != e->n[sc])
                nx_log("lowdiff:   site main+%#x draw ops %u -> %u (calls %u -> %u)", e->lr, e->n[sc ^ 1], e->n[sc], e->calls[sc ^ 1], e->calls[sc]);
        }
    {
        int sn = g_site_cur ^ 1;
        for (int i = 0; i < 1024; i++) g_sites[i].n[sn] = g_sites[i].calls[sn] = 0;
        g_site_cur = sn;
    }
    prev = draws;
    for (int i = 0; i < 4096; i++) g_lowdiff[i].n[p] = 0;
    g_lowdiff_cur = p;
}

uint64_t g_scene_lists[2];   // scene-list chunks measured: non-empty, empty
uint64_t nx_passprobe[8];   // NXRT_PASSPROBE counters (src/probe_hooks.S)
uint64_t nx_racering[4 + 65536 * 4], nx_chunkret;   // NXRT_RACEPROBE ring (src/probe_hooks.S)
// NXRT_RACEPROBE=<from>-<to>: per frame in that range, log the ring entries since the last present:
// "rp: <frame> E <entry> <count> <ticks>" (executor read) / "A <entry> <index> <ticks>" (append).
static void race_dump(int frame) {
    static int lo = -1, hi;
    static uint64_t seen;
    if (lo < 0 && sscanf(getenv("NXRT_RACEPROBE"), "%d-%d", &lo, &hi) != 2) lo = 0, hi = 0;
    uint64_t end = __atomic_load_n(&nx_racering[0], __ATOMIC_ACQUIRE), start = end > seen + 65536 ? end - 65536 : seen;
    seen = end;
    if (frame < lo || frame > hi) return;
    for (uint64_t i = start; i < end; i++) {
        const uint64_t *e = &nx_racering[4 + (i & 65535) * 4];
        if ((e[3] & 0xff) == 3)
            nx_log("rp: %d C %llx %d %d %llu passcount %d", frame, (unsigned long long)e[0], (int)(e[1] >> 32), (int)(int32_t)e[1],
                   (unsigned long long)e[2], (int)(e[3] >> 8));
        else
            nx_log("rp: %d %c %llx %lld %llu", frame, e[3] == 1 ? 'E' : 'A', (unsigned long long)(e[0] - 0xc8), (long long)(int32_t)e[1],
                   (unsigned long long)e[2]);
    }
}

// Draws encoded so far (gfx_metal.m's snapshot: this frame's count from the difference; gfx_draw_stats may reset it).
uint64_t gfx_draws_total(void) { return g_stats_draws; }
void gfx_frame_draws(uint64_t out[6]) {
    if (getenv("NXRT_RACEPROBE")) {
        extern volatile int g_gfx_frame;
        race_dump(g_gfx_frame);
    }
    {
        static uint64_t last2[2];
        uint64_t a = g_scene_lists[0] - last2[0], b = g_scene_lists[1] - last2[1];
        last2[0] += a, last2[1] += b;
        extern volatile int g_gfx_frame;
        static uint64_t lastskip;
        uint64_t sk = __atomic_load_n(&nx_skipprobe.calls, __ATOMIC_RELAXED), dsk = sk - lastskip;
        lastskip = sk;
        static uint64_t lo[4];
        uint64_t od[4];
        for (int i = 0; i < 4; i++) od[i] = nx_objprobe[i] - lo[i], lo[i] += od[i];
        extern uint64_t g_fs_stat[3];
        static uint64_t lfs[3];
        uint64_t fsd[3];
        for (int i = 0; i < 3; i++) fsd[i] = g_fs_stat[i] - lfs[i], lfs[i] += fsd[i];
        if (getenv("NXRT_FRAMEDRAWS") && fsd[0])
            nx_log("fs: frame %d RomFS reads %llu, %llu KB, %.2f ms", g_gfx_frame, fsd[0], fsd[1] >> 10, fsd[2] / 1e6);
        if (getenv("NXRT_FRAMEDRAWS"))
            nx_log("sl: frame %d scene-list chunks %llu non-empty, %llu empty; wrapper-not-ready skips %llu; objects %llu, skipped mask %llu lod %llu not-ready %llu",
                   g_gfx_frame, a, b, dsk, od[0], od[1], od[2], od[3]);
    }
    if (getenv("NXRT_PASSPROBE")) {
        static uint64_t last[5];
        uint64_t d[5];
        for (int i = 0; i < 5; i++) d[i] = __atomic_load_n(&nx_passprobe[i], __ATOMIC_RELAXED) - last[i], last[i] += d[i];
        extern volatile int g_gfx_frame;
        nx_log("pp: frame %d cache misses %llu, passes %llu, lists %llu, baked %llu, passes with unbaked lists %llu", g_gfx_frame,
               d[0], d[1], d[2], d[3], d[4]);
    }
    static uint64_t last[6];
    uint64_t now[6] = {g_stats_draws, g_stats_skipped, g_stats_reoff, g_called, g_submitted, g_ended};
    for (int i = 0; i < 6; i++) {
        if (now[i] < last[i]) last[i] = 0;   // reset by gfx_draw_stats
        out[i] = now[i] - last[i];
        last[i] = now[i];
    }
    extern volatile int g_gfx_frame;
    lowdiff_frame(g_gfx_frame, out[0]);
}

void gfx_draw_stats(int frames) {
    nx_cores_stats();
    nx_thread_cpu_stats(frames);
    if (getenv("NXRT_VCHECK")) nx_log("gfx: vcheck: %.1f draws/frame with garbage positions", (double)g_vcheck_bad / frames), g_vcheck_bad = 0;
    if (getenv("NXRT_VOBJPROBE")) vobj_probe_dump();
    prof_dump(frames);
    if (getenv("NXRT_SKIPPROBE")) skip_probe_dump();
    nx_log("gfx: %llu calls/submits of unknown command handles so far (lists dropped)", (unsigned long long)g_unknown_handles);
    if (listgc_mode()) {
        pthread_mutex_lock(&g_handle_lock);
        nx_log("gfx: listgc: %zu lists live, %llu killed (memory reused), %llu ended without command memory, %llu used after their "
               "memory was reused; %zu pages; %llu freed with their pool", g_lranges.count, (unsigned long long)g_lkilled, (unsigned long long)g_lnomem,
               (unsigned long long)g_lviolations, g_lpages.count, (unsigned long long)g_lpool_freed);
        if (listgc_mode() == 3)
            nx_log("gfx: listgc hybrid: %llu lists retired early, %llu freed, %.1f MB waiting (%d frames), %llu brought back, %llu kept for "
                   "the scan, %d exempt sites, %llu calls of lists freed too early", (unsigned long long)g_retired_n, (unsigned long long)g_retire_freed, g_retired_bytes_live / 1048576.0,
                   retire_grace(), (unsigned long long)g_unretired, (unsigned long long)g_retire_skipped, g_nexempt, (unsigned long long)g_tomb_hits);
        if (listgc_mode() == 1)
            nx_log("gfx: listgc shadow: of those calls, %llu found a list re-recorded at the same address (%llu identical bytes), "
                   "%llu found none (mode 2 would lose them)", (unsigned long long)g_lv_same, (unsigned long long)g_lv_ident, (unsigned long long)g_lv_lost);
        pthread_mutex_unlock(&g_handle_lock);
    }
    if (stagetime() && g_stats_draws) {
        static mach_timebase_info_data_t tb;
        if (!tb.denom) mach_timebase_info(&tb);
        char line[512];
        int o = 0;
        double per = (double)tb.numer / tb.denom / 1e3 / g_stats_draws;   // ticks -> us per executed draw
        for (int k = 0; k < ST_N; k++) o += snprintf(line + o, sizeof line - o, " %s %.2f,", g_st_name[k], g_st_ticks[k] * per);
        nx_log("gfx: encode us/draw (NXRT_STAGETIME):%s draw() total %.2f (%llu calls); whole encode %.2f", line,
               g_st_ticks[ST_N] * per, (unsigned long long)g_st_calls, g_encode_ns / 1e3 / g_stats_draws);
        memset(g_st_ticks, 0, sizeof g_st_ticks), g_st_calls = 0;
    }
    nx_log("gfx: time per frame: encode %.1f ms, GPU %.1f ms (busy %.1f ms), handle GC %.1f ms in the background (%llu scans in %d frames); "
           "%.1f mid-submit commits/frame; game blocked in SyncWait %.1f ms/frame", g_encode_ns / 1e6 / frames,
           __atomic_load_n(&g_gpu_ns, __ATOMIC_RELAXED) / 1e6 / frames, __atomic_load_n(&g_gpu_busy_ns, __ATOMIC_RELAXED) / 1e6 / frames, g_swap_ns / 1e6 / frames, (unsigned long long)g_swaps, frames,
           (double)g_stats_chunks / frames, __atomic_exchange_n(&g_stat_block_ns, 0, __ATOMIC_RELAXED) / 1e6 / frames);
    g_stats_chunks = 0;
    nx_log("gfx: render passes/frame: %.1f (%.1f with no draws), attachments loaded %.0f MB/frame, stored %.0f MB/frame",
           (double)g_pass_n / frames, (double)g_pass_empty / frames, g_pass_load_bytes / 1048576.0 / frames, g_pass_store_bytes / 1048576.0 / frames);
    g_pass_n = g_pass_empty = g_pass_load_bytes = g_pass_store_bytes = 0;
    {
        static const char *const nm[PE_N] = {"clear flush", "feedback", "snapshot", "compute", "rt", "rt same", "clear color", "clear ds", "clear tex", "copy", "submit", "split"};
        char line[1024];
        int o = 0;
        for (int k = 0; k < PE_N; k++)
            if (g_pe_n[k] || g_pe_load[k])
                o += snprintf(line + o, sizeof line - o, " %s %.1f (%.0f MB),", nm[k], (double)g_pe_n[k] / frames, g_pe_load[k] / 1048576.0 / frames);
        nx_log("gfx: pass ends/frame by reason (MB the next pass loaded back):%s", line);
        for (int k = 0; k < ATT_N && g_att[k].key; k++)
            if (g_att[k].load + g_att[k].store >= (uint64_t)frames << 20)
                nx_log("gfx:   attachment %ldx%ld fmt %ld %s: %.1f passes/frame (%.1f cleared), loaded %.0f MB, stored %.0f MB per frame",
                       g_att[k].key / 100000000, g_att[k].key / 10000 % 10000, g_att[k].key % 10000 / 10,
                       g_att[k].key % 10 ? "depth" : "color", (double)g_att[k].n / frames, (double)g_att[k].cleared / frames,
                       g_att[k].load / 1048576.0 / frames, g_att[k].store / 1048576.0 / frames);
        memset(g_att, 0, sizeof g_att);
        memset(g_pe_n, 0, sizeof g_pe_n), memset(g_pe_load, 0, sizeof g_pe_load);
    }
    g_swaps = g_swap_ns = g_encode_ns = 0;
    __atomic_store_n(&g_gpu_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&g_gpu_busy_ns, 0, __ATOMIC_RELAXED);
    if (getenv("NXRT_EXECPROBE")) exec_probe_dump();
    nx_log("gfx: %.1f draws/frame executed, %.1f skipped, %.1f waiting for shader/pipeline compiles", (double)g_stats_draws / frames,
           (double)g_stats_skipped / frames, (double)g_stats_pending / frames);
    g_stats_draws = g_stats_skipped = g_stats_pending = g_draws_at_submit = 0;
    nx_log("gfx: %.1f draws/frame sampled their own render target (%.1f fresh copies, %.1f mip views, the rest reused a copy); "
           "%.1f cbuf binds/frame snapshotted (%.1f reused the last copy; %d updated ranges)",
           (double)g_stats_feedback / frames, (double)g_stats_fb_copies / frames, (double)g_stats_fb_views / frames,
           (double)g_stats_snap / frames, (double)g_stats_snap_reused / frames, g_nupd);
    g_stats_feedback = g_stats_snap = g_stats_snap_reused = g_stats_fb_copies = g_stats_fb_views = 0;
    nx_log("gfx: cbuf copies/frame: %.1f near pool end, %.1f unaligned offset, %.1f both; %.2f MB/frame", (double)g_cbcopy[0] / frames,
           (double)g_cbcopy[1] / frames, (double)g_cbcopy[2] / frames, g_cbcopy_bytes / 1048576.0 / frames);
    memset(g_cbcopy, 0, sizeof g_cbcopy), g_cbcopy_bytes = 0;
    nx_log("gfx: %.1f dispatches/frame %s, %.1f rejected, %.1f waiting for compiles", (double)g_cs_done / frames,
           draw_check_only() || !compute_enabled() ? "validated" : "executed", (double)g_cs_rejected / frames, (double)g_cs_pending / frames);
    g_cs_done = g_cs_rejected = g_cs_pending = 0;
    if (g_cb_dirty) nx_log("gfx: %llu command buffers had raw-write pointers set (cleared)", (unsigned long long)g_cb_dirty);
    if (g_raw_midrec) nx_log("gfx: %llu ops found raw-write pointers set mid-recording (cleared)", (unsigned long long)g_raw_midrec);
    g_cb_dirty = 0;
    if (g_checked) {
        nx_log("gfx: validated %.1f draws/frame: %.1f pass, %.1f use storage buffers", (double)g_checked / frames,
               (double)g_check_ok / frames, (double)g_with_ssbo / frames);
        for (int r = 0; r < R_NREASONS; r++)
            if (g_reasons[r]) nx_log("gfx:   rejected %9.1f/frame: %s", (double)g_reasons[r] / frames, g_reason_name[r]);
        gfx_texture_stats(frames);
        pthread_mutex_lock(&g_arena_lock);
        nx_log("gfx: memory: arena chunks free %lu (%d MB each), keep %d, %.2f new chunks/frame", (unsigned long)g_arena_free.count,
               ARENA_CHUNK >> 20, g_arena_keep, (double)g_arena_miss_stat / frames);
        if (!g_arena_miss_stat && g_arena_keep > 4) g_arena_keep--;
        g_arena_miss_stat = 0;
        pthread_mutex_unlock(&g_arena_lock);
        {
            uint64_t fb = 0;
            pthread_mutex_lock(&g_view_lock);
            for (id<MTLTexture> c in g_fb_copies.objectEnumerator) fb += c.allocatedSize;
            nx_log("gfx: memory: feedback copies %lu (%.0f MB)", (unsigned long)g_fb_copies.count, fb / 1048576.0);
            pthread_mutex_unlock(&g_view_lock);
        }
        if (g_vb_padded) nx_log("gfx:   %9.1f/frame vertex streams fetched past their bound size (zero-padded)", (double)g_vb_padded / frames);
        memset(g_reasons, 0, sizeof g_reasons);
        g_checked = g_check_ok = g_with_ssbo = g_vb_padded = 0;
    }
    nx_log("gfx: handles ended %.1f/frame, submitted %.1f, called %.1f", (double)g_ended / frames,
           (double)g_submitted / frames, (double)g_called / frames);
    for (int t = 0; t < 40; t++)
        if (g_rec_ops[t] || g_exec_ops[t])
            nx_log("gfx:   op %2d recorded %9.1f/frame executed %9.1f", t, (double)g_rec_ops[t] / frames, (double)g_exec_ops[t] / frames);
    memset(g_rec_ops, 0, sizeof g_rec_ops), memset(g_exec_ops, 0, sizeof g_exec_ops);
    g_ended = g_submitted = g_called = 0;
    gfx_hist_dump();
}

// ---- registration ------------------------------------------------------------------------
static const struct { const char *name; void *fn; } g_procs[] = {
    {"nvnVertexAttribStateSetDefaults", vattr_defaults}, {"nvnVertexAttribStateSetFormat", vattr_set_format},
    {"nvnVertexAttribStateSetStreamIndex", vattr_set_stream},
    {"nvnVertexStreamStateSetDefaults", vstream_defaults}, {"nvnVertexStreamStateSetStride", vstream_set_stride},
    {"nvnVertexStreamStateSetDivisor", vstream_set_divisor},
    {"nvnBlendStateSetDefaults", blend_defaults}, {"nvnBlendStateSetBlendTarget", blend_set_target},
    {"nvnBlendStateSetBlendFunc", blend_set_func}, {"nvnBlendStateSetBlendEquation", blend_set_eq},
    {"nvnColorStateSetDefaults", color_defaults}, {"nvnColorStateSetBlendEnable", color_set_blend},
    {"nvnColorStateSetLogicOp", color_set_logic_op}, {"nvnColorStateSetAlphaTest", color_set_alpha_test},
    {"nvnChannelMaskStateSetDefaults", chmask_defaults}, {"nvnChannelMaskStateSetChannelMask", chmask_set},
    {"nvnDepthStencilStateSetDefaults", ds_defaults}, {"nvnDepthStencilStateSetDepthTestEnable", ds_set_depth_test},
    {"nvnDepthStencilStateSetDepthWriteEnable", ds_set_depth_write}, {"nvnDepthStencilStateSetDepthFunc", ds_set_depth_func},
    {"nvnDepthStencilStateSetStencilTestEnable", ds_set_stencil_test}, {"nvnDepthStencilStateSetStencilFunc", ds_set_stencil_func},
    {"nvnDepthStencilStateSetStencilOp", ds_set_stencil_op},
    {"nvnPolygonStateSetDefaults", poly_defaults}, {"nvnPolygonStateSetCullFace", poly_set_cull},
    {"nvnPolygonStateSetFrontFace", poly_set_front}, {"nvnPolygonStateSetPolygonMode", poly_set_mode},
    {"nvnPolygonStateSetPolygonOffsetEnables", poly_set_offset},
    {"nvnMultisampleStateSetDefaults", ms_defaults}, {"nvnMultisampleStateSetMultisampleEnable", ms_set_enable},
    {"nvnMultisampleStateSetSamples", ms_set_samples}, {"nvnMultisampleStateSetAlphaToCoverageEnable", ms_set_a2c},
    {"nvnTexturePoolRegisterTexture", texpool_register}, {"nvnSamplerPoolRegisterSampler", smppool_register},
    {"nvnCommandBufferInitialize", cb_initialize}, {"nvnCommandBufferBeginRecording", cb_begin}, {"nvnCommandBufferEndRecording", cb_end},
    {"nvnCommandBufferGetCommandMemoryUsed", cb_command_used}, {"nvnCommandBufferGetControlMemoryUsed", cb_control_used},
    {"nvnCommandBufferCopyTextureToTexture", cb_copy_tex},
    {"nvnCommandBufferCallCommands", cb_call}, {"nvnCommandBufferCopyCommands", cb_call},   // copy = append the ops, like Call
    {"nvnCommandBufferSetRenderTargets", cb_set_rt}, {"nvnCommandBufferClearColor", cb_clear_color},
    {"nvnCommandBufferClearDepthStencil", cb_clear_ds}, {"nvnCommandBufferClearTexture", cb_clear_tex},
    {"nvnCommandBufferBindProgram", cb_bind_program}, {"nvnCommandBufferBindUniformBuffer", cb_bind_ubo},
    {"nvnCommandBufferBindStorageBuffer", cb_bind_ssbo}, {"nvnCommandBufferBindTexture", cb_bind_texture},
    {"nvnCommandBufferBindTexturesDeferred", cb_bind_textures_deferred},
    {"nvnCommandBufferBindVertexBuffer", cb_bind_vbuf}, {"nvnCommandBufferBindVertexAttribState", cb_bind_vattr},
    {"nvnCommandBufferBindVertexStreamState", cb_bind_vstream},
    {"nvnCommandBufferBindBlendState", cb_bind_blend}, {"nvnCommandBufferBindColorState", cb_bind_color},
    {"nvnCommandBufferBindChannelMaskState", cb_bind_chmask}, {"nvnCommandBufferBindDepthStencilState", cb_bind_ds},
    {"nvnCommandBufferBindPolygonState", cb_bind_poly}, {"nvnCommandBufferBindMultisampleState", cb_bind_ms},
    {"nvnCommandBufferSetBlendColor", cb_blend_color}, {"nvnCommandBufferSetViewport", cb_viewport},
    {"nvnCommandBufferSetViewports", cb_viewports}, {"nvnCommandBufferSetScissor", cb_scissor},
    {"nvnCommandBufferSetScissors", cb_scissors}, {"nvnCommandBufferSetDepthRange", cb_depth_range},
    {"nvnCommandBufferSetPolygonOffsetClamp", cb_poly_offset}, {"nvnCommandBufferSetDepthClamp", cb_depth_clamp},
    {"nvnCommandBufferSetStencilRef", cb_stencil_ref}, {"nvnCommandBufferSetStencilMask", cb_stencil_mask},
    {"nvnCommandBufferSetStencilValueMask", cb_stencil_vmask},
    {"nvnCommandBufferSetRasterizerDiscard", cb_rasterizer_discard},
    {"nvnCommandBufferDrawElementsInstanced", cb_draw_elements_instanced},
    {"nvnCommandBufferDrawElements", cb_draw_elements},
    {"nvnCommandBufferDrawElementsBaseVertex", cb_draw_elements_base_vertex},
    {"nvnCommandBufferDrawArrays", cb_draw_arrays}, {"nvnCommandBufferDrawArraysInstanced", cb_draw_arrays_instanced},
    {"nvnCommandBufferUpdateUniformBuffer", cb_update_ubo}, {"nvnCommandBufferDispatchCompute", cb_dispatch},
    {"nvnQueueSubmitCommands", queue_submit},
    {"nvnEventBuilderSetDefaults", event_builder_defaults}, {"nvnEventBuilderSetStorage", event_builder_storage},
    {"nvnEventInitialize", event_initialize}, {"nvnEventGetValue", event_get_value}, {"nvnEventSignal", event_signal},
    {"nvnCommandBufferSignalEvent", cb_signal_event}, {"nvnCommandBufferReportCounter", cb_report_counter},
    {"nvnCommandBufferBarrier", cb_barrier},
    {"nvnCommandBufferSetRenderEnable", cb_render_enable}, {"nvnCommandBufferSetRenderEnableConditional", cb_render_enable_cond},
    {"nvnCommandBufferAddControlMemory", cb_add_control}, {"nvnCommandBufferAddCommandMemory", cb_add_command}, {"nvnQueueFenceSync", queue_fence_sync},
    {"nvnSyncWait", sync_wait}, {"nvnQueueFinish", queue_finish},
};

void *gfx_proc_for(const char *name) {
    for (size_t i = 0; i < sizeof g_procs / sizeof *g_procs; i++)
        if (!strcmp(g_procs[i].name, name)) return g_procs[i].fn;
    return NULL;
}
