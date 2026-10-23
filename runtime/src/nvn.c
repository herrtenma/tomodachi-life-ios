#include <time.h>
// NVN, replaced at the API level. The game gets every NVN function through
// nvnBootstrapLoader / nvnDeviceGetProcAddress; we hand back host functions.
// Stage 1: one logging stub per name with a naming-convention default, to learn which
// functions the game uses and to reach the first nvnQueuePresentTexture.
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gfx.h"
#include "nvn_formats.h"
#include "nxrt.h"

enum { MAX_PROCS = 1024 };
static char *g_names[MAX_PROCS];
static int g_nprocs;
static int g_called[MAX_PROCS];
static uint64_t g_ret[MAX_PROCS];
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static uint64_t default_return(const char *name) {
    // NVNboolean results that mean success when true
    static const char *const bool_ok[] = {"Initialize", "SetShaders", "MapVirtual", NULL};
    for (int i = 0; bool_ok[i]; i++)
        if (strstr(name, bool_ok[i])) return 1;
    return 0;
}

uint64_t nx_nvn_calls[1100];
static char g_is_stub[MAX_PROCS];      // still the logging stub (set in proc_for)          // per-proc call counts, bumped by the thunk (nvn_thunks.S)

// NXRT_NVNSTATS: per-frame call counts of every NVN function; stubs are marked.
void nx_nvn_dump_stats(int frames) {
    static uint64_t base[1100];
    nx_log("nvn: calls over %d frames (* = still a stub):", frames);
    for (int i = 0; i < g_nprocs; i++) {
        uint64_t n = __atomic_load_n(&nx_nvn_calls[i], __ATOMIC_RELAXED);
        if (n != base[i])
            nx_log("nvn:   %8.1f/frame %s%s", (double)(n - base[i]) / frames, g_names[i],
                   g_is_stub[i] ? " *" : "");
        base[i] = n;
    }
}

static uint64_t stub_body(int i) {
    if (!g_called[i]) {
        g_called[i] = 1;
        nx_log("nvn: %s (first call)", g_names[i]);
    }
    return g_ret[i];
}

// 1024 distinct entry points: stub_N() knows its own index.
#define S(n) static uint64_t stub_##n(void) { return stub_body(n); }
#define S10(n) S(n##0) S(n##1) S(n##2) S(n##3) S(n##4) S(n##5) S(n##6) S(n##7) S(n##8) S(n##9)
#define S100(n) S10(n##0) S10(n##1) S10(n##2) S10(n##3) S10(n##4) S10(n##5) S10(n##6) S10(n##7) S10(n##8) S10(n##9)
S10() S10(1) S10(2) S10(3) S10(4) S10(5) S10(6) S10(7) S10(8) S10(9)
S100(1) S100(2) S100(3) S100(4) S100(5) S100(6) S100(7) S100(8) S100(9)
S10(100) S10(101)
S(1020) S(1021) S(1022) S(1023)
#undef S
#define S(n) stub_##n,
static uint64_t (*const g_stubs[MAX_PROCS])(void) = {
    S10() S10(1) S10(2) S10(3) S10(4) S10(5) S10(6) S10(7) S10(8) S10(9)
    S100(1) S100(2) S100(3) S100(4) S100(5) S100(6) S100(7) S100(8) S100(9)
    S10(100) S10(101)
    S(1020) S(1021) S(1022) S(1023)
};

// ---- real implementations (override the logging stubs) ------------------------------
// Values the game checks are taken from its own code (main+0x904c3c: major == 55,
// minor >= 15). Unknown pnames get 256: most device integers are alignments/limits.
// GPU timestamps: NVN converts report ticks to ns with x625/384 (Ryujinx uses the same ratio). Counter
// reports (gfx_cmd.m) write ticks of a GPU-busy clock; nx_gpu_ticks() is the host clock in the same unit.
uint64_t nx_gpu_ticks(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) * 384 / 625;
}
static uint64_t dev_timestamp_ns(void *device, const uint64_t *counter) {
    (void)device;
    // The engine times each frame's GPU work (TIMESTAMP_TOP before the first draw, TIMESTAMP after the
    // last; converted at main+0x1d3df10/0x1d3df3c and main+0x1902ec) and scales scene detail by it. Report
    // timestamps come from the GPU-busy clock (gfx_cmd.m commit_cmd): GPU execution time only. (Command-
    // buffer completion times included our CPU encoding and culled half the island.)
    // Default for now: 0 ns (the GPU looks free; the game never lowers detail), as before. NXRT_GPU_TIMESTAMPS=1:
    // the GPU-busy clock (not yet verified whether the game lowers detail at ~16 ms; HANDOFF next tasks).
    static int real = -1;
    if (real < 0) real = getenv("NXRT_GPU_TIMESTAMPS") && atoi(getenv("NXRT_GPU_TIMESTAMPS")) != 0;
    uint64_t v = real && counter ? counter[1] * 625 / 384 : 0;   // NVNcounterData {counter, timestamp}
    static int n = -1, from;   // NXRT_TSLOG=<frame>: log 400 conversions from that frame on (1 = from the start)
    if (n < 0) n = getenv("NXRT_TSLOG") ? 0 : 1 << 30, from = getenv("NXRT_TSLOG") ? atoi(getenv("NXRT_TSLOG")) : 0;
    extern volatile int g_gfx_frame;
    if (n < 400 && g_gfx_frame >= from) {
        n++;
        Module *m = nx_module("main");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wframe-address"
        uint8_t *lr = __builtin_return_address(1);   // the thunk's frame: the guest caller
#pragma clang diagnostic pop
        nx_log("tslog: frame %d counter %p -> %llu ns from main+%#lx", g_gfx_frame, (const void *)counter, (unsigned long long)v,
               m && lr >= m->base && lr < m->base + m->size ? (long)(lr - m->base) : -1L);
    }
    return v;
}
static uint64_t dev_current_timestamp_ns(void *device) {
    (void)device;
    return nx_gpu_ticks() * 625 / 384;
}
static void dev_get_integer(void *device, int pname, int *out) {
    int v;
    switch (pname) {
    case 0: v = 55; break;                               // API major version
    case 1: v = 15; break;                               // API minor version
    case 15: v = 32; break;                              // texture descriptor size (Maxwell TIC entry)
    case 16: v = 32; break;                              // sampler descriptor size (Maxwell TSC entry)
    case 17: v = 256; break;                             // reserved texture descriptors
    case 18: v = 256; break;                             // reserved sampler descriptors
    case 20: v = 8; break;                               // command buffer control alignment
    case 25: v = 0x1000; break;                          // shader scratch memory alignment
    case 26: v = 0x20000; break;                         // shader scratch memory granularity
    default: v = 256; break;
    }
    static uint64_t seen[4];
    if (pname < 256 && !(seen[pname / 64] >> (pname % 64) & 1)) {
        seen[pname / 64] |= 1ull << (pname % 64);
        nx_log("nvn: nvnDeviceGetInteger(%d) -> %d", pname, v);
    }
    if (out) *out = v;
}

// ---- object model ------------------------------------------------------------------
// The game owns every NVN object's memory (opaque, fixed size). We keep our state
// inline in the first 48 bytes so copies of builders stay valid.
typedef struct { void *memory; uint64_t size; int32_t flags; } PoolBuilder;
typedef struct { void *memory; uint64_t size; int32_t flags; uint32_t pad; uint64_t gpu; } Pool;
typedef struct { Pool *pool; int64_t offset; uint64_t size; } BufferBuilder;
typedef struct { Pool *pool; int64_t offset; uint64_t size; } Buffer;
typedef struct { Pool *pool; int64_t offset; int32_t w, h, d, levels, format, target, flags, samples; } TexBuilder;
typedef struct { Pool *pool; int64_t offset; int32_t w, h, d, levels, format, target, flags, samples; } Texture;

static uint64_t g_next_gpu = 0x100000000ull;           // fake GPU virtual addresses

static void pool_builder_defaults(PoolBuilder *b) { memset(b, 0, 48); }
static void pool_builder_set_storage(PoolBuilder *b, void *mem, uint64_t size) { b->memory = mem; b->size = size; }
static void pool_builder_set_flags(PoolBuilder *b, int32_t flags) { b->flags = flags; }
// GPU address -> host: pools get increasing fake GPU ranges, recorded in order.
enum { MAX_POOLS = 8192 };
static struct { uint64_t gpu, size; uint8_t *mem; } g_pools[MAX_POOLS];
static int g_npools;
static pthread_mutex_t g_pool_lock = PTHREAD_MUTEX_INITIALIZER;

// NXRT_POOLLOG=<min size hex>: log pools of at least that size (frame, flags, non-zero bytes, guest caller).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wframe-address"   // the thunk's frame: the guest caller
__attribute__((noinline)) static void pool_log(const PoolBuilder *b, uint64_t gpu) {
    static long min = -2;
    if (min == -2) min = getenv("NXRT_POOLLOG") ? strtol(getenv("NXRT_POOLLOG"), NULL, 16) : -1;
    if (min < 0 || b->size < (uint64_t)min) return;
    uint64_t nz = 0;
    for (uint64_t q = 0; b->memory && q + 8 <= b->size; q += 8) nz += *(const uint64_t *)((const uint8_t *)b->memory + q) != 0;
    extern volatile int g_gfx_frame;
    Module *m = nx_module("main");
    uint8_t *lr = __builtin_return_address(2);
    nx_log("poollog: frame %d pool memory %p gpu %#llx size %#llx flags %#x: %llu non-zero 8-byte words, from main+%#lx", g_gfx_frame, b->memory,
           (unsigned long long)gpu, (unsigned long long)b->size, b->flags, (unsigned long long)nz, m && lr >= m->base && lr < m->base + m->size ? (long)(lr - m->base) : -1L);
}
#pragma clang diagnostic pop

static uint64_t pool_initialize(Pool *p, const PoolBuilder *b) {
    p->memory = b->memory;
    p->size = b->size;
    p->flags = b->flags;
    pthread_mutex_lock(&g_pool_lock);
    p->gpu = g_next_gpu;
    g_next_gpu += (b->size + 0xFFFF) & ~0xFFFFull;
    // Entries are append-only and never change once published: lookups read the count (acquire) without the lock.
    if (g_npools < MAX_POOLS) {
        g_pools[g_npools] = (typeof(g_pools[0])){p->gpu, b->size, b->memory};
        __atomic_store_n(&g_npools, g_npools + 1, __ATOMIC_RELEASE);
    }
    pthread_mutex_unlock(&g_pool_lock);
    pool_log(b, p->gpu);
    return 1;
}

// Index of the last pool starting at or below a GPU address (-1 if none). Pools start on 64 KB pages
// and never overlap, so each page belongs to at most one pool: a direct-mapped cache of page -> index
// skips the binary search (its cache misses over thousands of pools were ~9% of draw encoding).
// Entries pack (page << 16 | index + 1) in one word; the pool table is append-only, so they never go stale.
enum { POOLCACHE_N = 4096 };
static uint64_t g_poolcache[POOLCACHE_N];
static int pool_find(uint64_t gpu) {
    uint64_t page = gpu >> 16, *e = &g_poolcache[(page ^ page >> 12) & (POOLCACHE_N - 1)];
    uint64_t v = __atomic_load_n(e, __ATOMIC_RELAXED);
    if (v && v >> 16 == page) return (int)(v & 0xFFFF) - 1;
    int lo = 0, hi = __atomic_load_n(&g_npools, __ATOMIC_ACQUIRE) - 1, hit = -1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (g_pools[mid].gpu <= gpu) hit = mid, lo = mid + 1;
        else hi = mid - 1;
    }
    // Only cache pages inside the pool's own 64 KB-rounded range: a page past its end may get a new pool later.
    if (hit >= 0 && page < (g_pools[hit].gpu + g_pools[hit].size + 0xFFFF) >> 16) __atomic_store_n(e, page << 16 | (uint64_t)(hit + 1), __ATOMIC_RELAXED);
    return hit;
}

// Pool containing a GPU address: returns its index (stable) and fills memory, size and offset.
int nx_nvn_gpu_pool(uint64_t gpu, uint8_t **mem, uint64_t *size, uint64_t *off) {
    int hit = pool_find(gpu);
    if (hit >= 0 && (gpu - g_pools[hit].gpu >= g_pools[hit].size || !g_pools[hit].mem)) hit = -1;
    if (hit >= 0) *mem = g_pools[hit].mem, *size = g_pools[hit].size, *off = gpu - g_pools[hit].gpu;
    return hit;
}

void *nx_nvn_gpu_to_host(uint64_t gpu, uint64_t *avail) {
    int hit = pool_find(gpu);
    void *r = NULL;
    if (hit >= 0 && gpu - g_pools[hit].gpu < g_pools[hit].size && g_pools[hit].mem) {
        r = g_pools[hit].mem + (gpu - g_pools[hit].gpu);
        if (avail) *avail = g_pools[hit].size - (gpu - g_pools[hit].gpu);
    }
    return r;
}
static void *pool_map(const Pool *p) { return p->memory; }
// The pool's memory goes back to the game: command lists recorded into it are gone (gfx_cmd.m list lifetime). Its GPU
// range stays in g_pools (never reused: g_next_gpu only grows).
static void pool_finalize(Pool *p) {
    void gfx_lists_forget(uint64_t gpu, uint64_t size);
    if (p && p->size) gfx_lists_forget(p->gpu, p->size);
}
static uint64_t pool_get_address(const Pool *p) { return p->gpu; }
static uint64_t pool_get_size(const Pool *p) { return p->size; }
static int32_t pool_get_flags(const Pool *p) { return p->flags; }
// CPU writes made visible to the GPU: textures over that storage are uploaded again (gfx_textures.m).
static void pool_flush_range(const Pool *p, int64_t off, uint64_t size) {
    if (p && p->memory && off >= 0 && (uint64_t)off < p->size) gfx_note_cpu_write((uint8_t *)p->memory + off, size < p->size - off ? size : p->size - off);
}

// nvnMemoryPoolMapVirtual(pool, count, requests): maps physical pool pages into a virtual pool. Not modelled yet;
// NXRT_VMAPLOG=1 logs the requests ({physical pool, physical offset, virtual offset, size, storage class}).
typedef struct { Pool *phys; int64_t phys_off, virt_off; uint64_t size; int32_t storage_class, pad; } MapRequest;
static uint64_t pool_map_virtual(Pool *p, int32_t n, const MapRequest *rq) {
    static int on = -1, nlog;
    if (on < 0) on = getenv("NXRT_VMAPLOG") != NULL;
    extern volatile int g_gfx_frame;
    for (int i = 0; on && rq && i < n && nlog < 400; i++, nlog++)
        nx_log("vmap: frame %d virtual pool %p (flags %#x size %#llx) +%#llx <- physical %p +%#llx size %#llx class %d", g_gfx_frame, (void *)p,
               p ? p->flags : 0, p ? (unsigned long long)p->size : 0ull, (long long)rq[i].virt_off, (void *)rq[i].phys, (long long)rq[i].phys_off,
               (unsigned long long)rq[i].size, rq[i].storage_class);
    return 1;
}

// nvnMemoryPoolInvalidateMappedRange: the CPU is about to read memory the GPU wrote. Pools are shared
// with Metal buffers, so buffer writes are already there. NXRT_INVLOG=1 logs the calls (caller, range).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wframe-address"   // the thunk's frame: the guest caller
// NXRT_INVLOG=<from>-<to>: every call in those frames, plus a summary of the 0x14d0-byte occlusion block
// the game reads (frame stamp at +0x14c0, 8-byte {0, max depth} tile entries from +0x1c0).
static void pool_invalidate_range(const Pool *p, int64_t off, uint64_t size) {
    static int on = -1, n, lo = 0, hi = 1 << 30;
    if (on < 0) {
        const char *e = getenv("NXRT_INVLOG");
        on = e != NULL;
        if (e && strchr(e, '-')) lo = atoi(e), hi = atoi(strchr(e, '-') + 1);
    }
    extern volatile int g_gfx_frame;
    if (!on || g_gfx_frame < lo || g_gfx_frame > hi || n++ >= 4000) return;
    Module *m = nx_module("main");
    uint8_t *lr = __builtin_return_address(1);
    if (p && p->memory && size >= 0x14d0 && off >= 0 && (uint64_t)off + 0x14d0 <= p->size) {
        const uint8_t *blk = (const uint8_t *)p->memory + off;
        int nz = 0, ntile = (0x14c0 - 0x1c0) / 8;
        float mn = 1e9f, mx = -1e9f;
        for (int i = 0; i < ntile; i++) {
            float f;
            memcpy(&f, blk + 0x1c0 + 8 * i + 4, 4);
            if (f != 0) nz++;
            if (f < mn) mn = f;
            if (f > mx) mx = f;
        }
        float m0[4];
        memcpy(m0, blk + 0x40, 16);
        nx_log("invlog: frame %d block +%#llx stamp %u: %d of %d tiles non-zero, max depth %.4f..%.4f, mat row0 %.3f %.3f %.3f %.3f",
               g_gfx_frame, (long long)off, *(const uint32_t *)(blk + 0x14c0), nz, ntile, mn, mx, m0[0], m0[1], m0[2], m0[3]);
    }
    nx_log("invlog: pool %p mem %p size %#llx flags %#x gpu %#llx: off %#llx size %#llx from main+%#lx", (const void *)p,
           p ? p->memory : NULL, p ? (unsigned long long)p->size : 0ull, p ? p->flags : 0, p ? (unsigned long long)p->gpu : 0ull,
           (long long)off, (unsigned long long)size, m && lr >= m->base && lr < m->base + m->size ? (long)(lr - m->base) : -1L);
}
#pragma clang diagnostic pop

static void buffer_builder_defaults(BufferBuilder *b) { memset(b, 0, 48); }
static void buffer_builder_set_storage(BufferBuilder *b, Pool *pool, int64_t off, uint64_t size) {
    b->pool = pool; b->offset = off; b->size = size;
}
static uint64_t buffer_initialize(Buffer *buf, const BufferBuilder *b) { memcpy(buf, b, sizeof *buf); return 1; }
static void *buffer_map(const Buffer *b) { return b->pool ? (uint8_t *)b->pool->memory + b->offset : NULL; }
static uint64_t buffer_get_address(const Buffer *b) { return b->pool ? b->pool->gpu + b->offset : 0; }
static uint64_t buffer_get_size(const Buffer *b) { return b->size; }

static void tex_builder_defaults(TexBuilder *b) {
    memset(b, 0, 48);
    b->w = b->h = b->d = b->levels = b->samples = 1;
    gfx_texbuilder_defaults(b);
}
static void tex_builder_set_size1d(TexBuilder *b, int32_t w) { b->w = w; }
static void tex_builder_set_size2d(TexBuilder *b, int32_t w, int32_t h) { b->w = w; b->h = h; }
static void tex_builder_set_size3d(TexBuilder *b, int32_t w, int32_t h, int32_t d) { b->w = w; b->h = h; b->d = d; }
static void tex_builder_set_width(TexBuilder *b, int32_t w) { b->w = w; }
static void tex_builder_set_height(TexBuilder *b, int32_t h) { b->h = h; }
static void tex_builder_set_depth(TexBuilder *b, int32_t d) { b->d = d; }
static void tex_builder_set_levels(TexBuilder *b, int32_t n) { b->levels = n; }
static void tex_builder_set_format(TexBuilder *b, int32_t f) { b->format = f; }
static void tex_builder_set_target(TexBuilder *b, int32_t t) { b->target = t; }
static void tex_builder_set_flags(TexBuilder *b, int32_t f) { b->flags = f; }
static void tex_builder_set_samples(TexBuilder *b, int32_t n) { b->samples = n ? n : 1; }
static void tex_builder_set_storage(TexBuilder *b, Pool *pool, int64_t off) { b->pool = pool; b->offset = off; }
// Storage size with the Tegra block-linear rules (the game sizes its own heaps with this, so
// an estimate that is too big exhausts them). Unknown formats count as 4 bytes per texel.
static uint64_t tex_storage_size(const TexBuilder *b) {
    const NvnFmt *f = nvn_fmt(b->format);
    int bpb = f ? f->bpb : 4, bw = f ? f->bw : 1, bh = f ? f->bh : 1;
    uint32_t w = b->w > 0 ? b->w : 1, h = b->h > 0 ? b->h : 1, d = b->d > 0 ? b->d : 1;
    uint32_t levels = b->levels > 0 ? b->levels : 1, layers = 1, depth = 1;
    switch (b->target) {
    case 2: depth = d; break;                       // 3D
    case 3: layers = h; h = 1; break;               // 1D array
    case 4: case 6: layers = d; break;              // 2D array (multisample)
    case 8: layers = 6; break;                      // cube
    case 9: layers = d; break;                      // cube array (d counts faces)
    }
    int gh = nvn_gob_height((h + bh - 1) / bh);
    uint64_t layer = 0;
    for (uint32_t l = 0; l < levels; l++) {
        uint32_t mw = w >> l ? w >> l : 1, mh = h >> l ? h >> l : 1, md = depth >> l ? depth >> l : 1;
        uint32_t wb = (mw + bw - 1) / bw, hb = (mh + bh - 1) / bh;
        layer += nvn_surface_size(wb, hb, bpb, nvn_mip_gob_height(gh, hb)) * md;
    }
    if (layers > 1) layer = (layer + 512ull * gh - 1) / (512ull * gh) * (512ull * gh);
    return layer * layers * (b->samples > 0 ? b->samples : 1);
}
static uint64_t tex_builder_get_storage_size(const TexBuilder *b) { return tex_storage_size(b); }
// Display and compressible surfaces want big-page alignment; plain textures 512 bytes (one GOB).
static uint64_t tex_builder_get_storage_alignment(const TexBuilder *b) { return b->flags & 0x9 ? 0x10000 : 0x200; }
static uint64_t tex_initialize(Texture *t, const TexBuilder *b) {
    void nx_wide_base(void);
    nx_wide_base();   // widescreen: before the renderer sizes its targets (ui_touch.c)
    static int on = -1;
    if (on < 0) on = getenv("NXRT_TEXSIZELOG") != NULL;   // recon: each distinct large size once, with its caller
    if (on && b->w >= 320 && b->h >= 180) {
        static int seen[128][2], n;
        int k = 0;
        while (k < n && !(seen[k][0] == b->w && seen[k][1] == b->h)) k++;
        if (k == n && n < 128) {
            seen[n][0] = b->w, seen[n++][1] = b->h;
            Module *m = nx_module("main");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wframe-address"
            uint8_t *lr = __builtin_return_address(1);
#pragma clang diagnostic pop
            nx_log("tex: size %dx%d first from main+%#lx", b->w, b->h, (long)(lr - m->base));
            int bw, bh;   // NXRT_TEXSIZEBT=<w>x<h>: guest backtrace of that size's first creation
            if (getenv("NXRT_TEXSIZEBT") && sscanf(getenv("NXRT_TEXSIZEBT"), "%dx%d", &bw, &bh) == 2 && bw == b->w && bh == b->h) {
                void nx_backtrace_from(uint64_t fp);
                nx_backtrace_from((uint64_t)__builtin_frame_address(0));
            }
        }
    }
    memcpy(t, b, sizeof *t);
    gfx_texture_init(t, b);
    uint64_t size = tex_storage_size(b);
    if (b->pool && (uint64_t)b->offset + size > b->pool->size) {
        static int n;
        if (n++ < 12)
            nx_log("nvn: texture %dx%dx%d fmt %d levels %d at pool offset %#llx size %#llx OVERFLOWS pool size %#llx",
                   b->w, b->h, b->d, b->format, b->levels, (unsigned long long)b->offset, (unsigned long long)size,
                   (unsigned long long)b->pool->size);
    }
    return 1;
}
static int32_t tex_get_width(const Texture *t) { return t->w; }
static int32_t tex_get_height(const Texture *t) { return t->h; }
static int32_t tex_get_depth(const Texture *t) { return t->d; }
static int32_t tex_get_format(const Texture *t) { return t->format; }
static uint64_t tex_get_storage_size(const Texture *t) { return tex_storage_size((const TexBuilder *)t); }
void nx_nvn_texture_info(const void *tex, int32_t *w, int32_t *h, int32_t *format) {
    const Texture *t = tex;
    *w = t->w; *h = t->h; *format = t->format;
}
void nx_nvn_texture_desc(const void *tex, NxTexDesc *o) {
    const Texture *t = tex;
    memset(o, 0, sizeof *o);
    o->w = t->w; o->h = t->h; o->d = t->d; o->levels = t->levels; o->format = t->format;
    o->target = t->target; o->flags = t->flags; o->samples = t->samples;
    o->pool = t->pool, o->offset = t->offset;
    if (t->pool && t->pool->memory && t->offset >= 0 && (uint64_t)t->offset < t->pool->size) {
        o->pool_data = (const uint8_t *)t->pool->memory + t->offset;
        o->pool_avail = t->pool->size - t->offset;
        o->pool_flags = t->pool->flags;
    }
}

// ---- samplers: state recorded by the builder, read back by the Get* functions ---------
typedef NxSamplerState SamplerState;
static void smp_defaults(SamplerState *s) {
    memset(s, 0, sizeof *s);
    s->lod_max = 1000.0f;
    s->aniso = 1.0f;
}
static void smp_set_min_mag(SamplerState *s, int32_t mn, int32_t mg) { s->min = mn; s->mag = mg; }
static void smp_set_wrap(SamplerState *s, int32_t a, int32_t b, int32_t c) { s->wrap_s = a; s->wrap_t = b; s->wrap_r = c; }
static void smp_set_lod_clamp(SamplerState *s, float a, float b) { s->lod_min = a; s->lod_max = b; }
static void smp_set_lod_bias(SamplerState *s, float b) { s->lod_bias = b; }
static void smp_set_compare(SamplerState *s, int32_t m, int32_t f) { s->cmp_mode = m; s->cmp_func = f; }
static void smp_set_border(SamplerState *s, const float *c) { if (c) memcpy(s->border, c, 16); }
static void smp_set_aniso(SamplerState *s, float a) { s->aniso = a; }
static void smp_set_reduction(SamplerState *s, int32_t r) { s->reduction = r; }
static uint64_t smp_initialize(SamplerState *dst, const SamplerState *b) { memcpy(dst, b, sizeof *dst); return 1; }
static void smp_get_min_mag(const SamplerState *s, int32_t *mn, int32_t *mg) { if (mn) *mn = s->min; if (mg) *mg = s->mag; }
static void smp_get_wrap(const SamplerState *s, int32_t *a, int32_t *b, int32_t *c) {
    if (a) *a = s->wrap_s; if (b) *b = s->wrap_t; if (c) *c = s->wrap_r;
}
static void smp_get_lod_clamp(const SamplerState *s, float *a, float *b) { if (a) *a = s->lod_min; if (b) *b = s->lod_max; }
static float smp_get_lod_bias(const SamplerState *s) { return s->lod_bias; }
static void smp_get_compare(const SamplerState *s, int32_t *m, int32_t *f) { if (m) *m = s->cmp_mode; if (f) *f = s->cmp_func; }
static void smp_get_border(const SamplerState *s, float *c) { if (c) memcpy(c, s->border, 16); }
static float smp_get_aniso(const SamplerState *s) { return s->aniso; }
static int32_t smp_get_reduction(const SamplerState *s) { return s->reduction; }

// ---- texture views: NVNtextureView is small (28 bytes of state smashed the game's
// stack), so the state is packed into 16 bytes.
typedef NxTexView TexView;
_Static_assert(sizeof(TexView) == 16, "TexView must stay 16 bytes");
static void tv_defaults(TexView *v) { memset(v, 0, sizeof *v); v->swizzle = 2 | 3 << 4 | 4 << 8 | 5 << 12; }
static void tv_set_levels(TexView *v, int32_t base, int32_t n) { v->base_level = base; v->num_levels = n; v->set |= 1; }
static void tv_set_layers(TexView *v, int32_t mn, int32_t n) { v->min_layer = mn; v->num_layers = n; v->set |= 2; }
static void tv_set_target(TexView *v, int32_t t) { v->target = t; v->set |= 4; }
static void tv_set_format(TexView *v, int32_t f) { v->format = f; v->set |= 8; }
static void tv_set_swizzle(TexView *v, int32_t r, int32_t g, int32_t b, int32_t a) {
    v->swizzle = (r & 15) | (g & 15) << 4 | (b & 15) << 8 | (a & 15) << 12;
    v->set |= 16;
}
static void tv_set_ds_mode(TexView *v, int32_t m) { v->ds_mode = m; }
static uint64_t tv_get_levels(const TexView *v, int32_t *base, int32_t *n) {
    if (base) *base = v->base_level; if (n) *n = v->num_levels; return v->set & 1;
}
static uint64_t tv_get_layers(const TexView *v, int32_t *mn, int32_t *n) {
    if (mn) *mn = v->min_layer; if (n) *n = v->num_layers; return (v->set >> 1) & 1;
}
static uint64_t tv_get_target(const TexView *v, int32_t *t) { if (t) *t = v->target; return (v->set >> 2) & 1; }

// ---- textures: getters with outputs ------------------------------------------------
static int32_t tex_get_target(const Texture *t) { return t->target; }
static int32_t tex_get_samples(const Texture *t) { return t->samples; }
static int32_t tex_get_levels(const Texture *t) { return t->levels; }
static int32_t tex_get_flags(const Texture *t) { return t->flags; }
static uint64_t tex_get_stride(const Texture *t) { return (uint64_t)t->w * 4; }
static void tex_get_swizzle(const Texture *t, int32_t *r, int32_t *g, int32_t *b, int32_t *a) {
    if (r) *r = 2; if (g) *g = 3; if (b) *b = 4; if (a) *a = 5;
}
static int32_t tex_builder_get_storage_class(const TexBuilder *b) { return 1; }
static uint64_t tex_builder_get_zcull_size(const TexBuilder *b) { return 0; }

// ---- window, queue, command buffers ------------------------------------------------
typedef struct { int32_t count, active, present_interval, next; } WindowState;
static void win_builder_defaults(WindowState *w) { memset(w, 0, sizeof *w); w->present_interval = 1; }
static void win_builder_set_textures(WindowState *w, int32_t n, void *const *tex) {
    w->count = n;
    if (!w->active) w->active = n;
    gfx_window_builder_textures(w, n, tex);
}
static void win_builder_set_num_active(WindowState *w, int32_t n) { w->active = n; }
// Present interval (vsyncs per present): recorded only; gfx pacing is 60 Hz. Logged to see what the game asks for.
int g_present_interval = 1;
static void win_set_present_interval(void *w, int32_t n) {
    static int logged;
    if (n != g_present_interval || !logged++) {
        nx_log("nvn: present interval %d (window/builder %p)", n, w);
        void nx_backtrace_from(uint64_t fp);
        if (getenv("NXRT_TICKPROBE")) nx_backtrace_from((uint64_t)__builtin_frame_address(0));
    }
    g_present_interval = n;
}
// Crop: the part of the window texture that is shown (handheld: 1280x720 at the top left of the 1920x1080 textures).
static void win_set_crop(void *w, int32_t x, int32_t y, int32_t cw, int32_t ch) {
    void nx_wide_base(void);   // widescreen (ui_touch.c)
    nx_wide_base();
    static int n;
    if (n++ < 4) {
        nx_log("nvn: window crop %d,%d %dx%d", x, y, cw, ch);
        void nx_backtrace_from(uint64_t fp);
        if (n == 1 && getenv("NXRT_CROPBT")) nx_backtrace_from((uint64_t)__builtin_frame_address(0));
    }
    gfx_window_set_crop(w, x, y, cw, ch);
}
static uint64_t win_initialize(WindowState *w, const WindowState *b) {
    memcpy(w, b, sizeof *w);
    gfx_window_init(w, b);
    return 1;
}
static int32_t win_acquire(WindowState *w, void *sync, int32_t *index) {
    int32_t n = w->active > 0 ? w->active : (w->count > 0 ? w->count : 2);
    if (index) *index = w->next;
    w->next = (w->next + 1) % n;
    return 0;                                           // NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS
}
static uint64_t queue_memory_size(const void *b) { return 0x100000; }

// ---- handles: encoding from the SDK's own helpers (sdk+0x4c2af0..0x4c2b1c):
// texture = tex | sampler << 20 | 1 << 32; image / texel fetch = id | 1 << 32.
static uint64_t dev_texture_handle(void *d, int32_t tex, int32_t smp) {
    return (uint64_t)(int64_t)(int32_t)((uint32_t)tex | (uint32_t)smp << 20) | (1ull << 32);
}
static uint64_t dev_single_handle(void *d, int32_t id) { return (uint64_t)(int64_t)id | (1ull << 32); }

// bind probes (shaders.c, NXRT_BINDPROBE)
void bp_bind_program(void *, const void *, int32_t);
void bp_bind_uniform(void *, int32_t, int32_t, uint64_t, int64_t);
void bp_bind_storage(void *, int32_t, int32_t, uint64_t, int64_t);
void bp_bind_texture(void *, int32_t, int32_t, uint64_t);
void bp_bind_textures_deferred(void *, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
void bp_bind_vertex_buffer(void *, int32_t, uint64_t, int64_t);
void bp_bind_vertex_attrib(void *, int32_t, const uint32_t *);
void bp_bind_vertex_stream(void *, int32_t, const uint32_t *);
void bp_draw_elements_instanced(void *, int32_t, int32_t, int32_t, uint64_t, int32_t, int32_t, int32_t);
void bp_draw_elements(void *, int32_t, int32_t, int32_t, uint64_t);
void bp_draw_arrays_instanced(void *, int32_t, int32_t, int32_t, int32_t, int32_t);
void bp_window_origin_mode(void *, int32_t), bp_depth_mode(void *, int32_t);
void bp_viewport(void *, int32_t, int32_t, int32_t, int32_t);
void bp_scissor(void *, int32_t, int32_t, int32_t, int32_t);
void sz_vattrib(void *), sz_vstream(void *), sz_blend(void *), sz_chmask(void *), sz_color(void *), sz_ds(void *),
    sz_poly(void *), sz_ms(void *);

static const struct { const char *name; void *fn; } g_impl[] = {
    {"nvnDeviceGetTextureHandle", (void *)dev_texture_handle},
    {"nvnDeviceGetTexelFetchHandle", (void *)dev_single_handle},
    {"nvnDeviceGetImageHandle", (void *)dev_single_handle},
    {"nvnSamplerBuilderSetDefaults", (void *)smp_defaults},
    {"nvnSamplerBuilderSetMinMagFilter", (void *)smp_set_min_mag},
    {"nvnSamplerBuilderSetWrapMode", (void *)smp_set_wrap},
    {"nvnSamplerBuilderSetLodClamp", (void *)smp_set_lod_clamp},
    {"nvnSamplerBuilderSetLodBias", (void *)smp_set_lod_bias},
    {"nvnSamplerBuilderSetCompare", (void *)smp_set_compare},
    {"nvnSamplerBuilderSetBorderColor", (void *)smp_set_border},
    {"nvnSamplerBuilderSetMaxAnisotropy", (void *)smp_set_aniso},
    {"nvnSamplerBuilderSetReductionFilter", (void *)smp_set_reduction},
    {"nvnSamplerInitialize", (void *)smp_initialize},
    {"nvnSamplerGetMinMagFilter", (void *)smp_get_min_mag},
    {"nvnSamplerGetWrapMode", (void *)smp_get_wrap},
    {"nvnSamplerGetLodClamp", (void *)smp_get_lod_clamp},
    {"nvnSamplerGetLodBias", (void *)smp_get_lod_bias},
    {"nvnSamplerGetCompare", (void *)smp_get_compare},
    {"nvnSamplerGetBorderColor", (void *)smp_get_border},
    {"nvnSamplerGetMaxAnisotropy", (void *)smp_get_aniso},
    {"nvnSamplerGetReductionFilter", (void *)smp_get_reduction},
    {"nvnTextureViewSetDefaults", (void *)tv_defaults},
    {"nvnTextureViewSetLevels", (void *)tv_set_levels},
    {"nvnTextureViewSetLayers", (void *)tv_set_layers},
    {"nvnTextureViewSetTarget", (void *)tv_set_target},
    {"nvnTextureViewSetFormat", (void *)tv_set_format},
    {"nvnTextureViewSetSwizzle", (void *)tv_set_swizzle},
    {"nvnTextureViewSetDepthStencilMode", (void *)tv_set_ds_mode},
    {"nvnTextureViewGetLevels", (void *)tv_get_levels},
    {"nvnTextureViewGetLayers", (void *)tv_get_layers},
    {"nvnTextureViewGetTarget", (void *)tv_get_target},
    {"nvnTextureGetTarget", (void *)tex_get_target},
    {"nvnTextureGetSamples", (void *)tex_get_samples},
    {"nvnTextureGetLevels", (void *)tex_get_levels},
    {"nvnTextureGetFlags", (void *)tex_get_flags},
    {"nvnTextureGetStride", (void *)tex_get_stride},
    {"nvnTextureGetSwizzle", (void *)tex_get_swizzle},
    {"nvnTextureBuilderGetStorageClass", (void *)tex_builder_get_storage_class},
    {"nvnTextureBuilderGetZCullStorageSize", (void *)tex_builder_get_zcull_size},
    {"nvnWindowBuilderSetPresentInterval", (void *)win_set_present_interval},
    {"nvnWindowSetPresentInterval", (void *)win_set_present_interval},
    {"nvnWindowSetCrop", (void *)win_set_crop},
    {"nvnWindowBuilderSetDefaults", (void *)win_builder_defaults},
    {"nvnWindowBuilderSetTextures", (void *)win_builder_set_textures},
    {"nvnWindowBuilderSetNumActiveTextures", (void *)win_builder_set_num_active},
    {"nvnWindowInitialize", (void *)win_initialize},
    {"nvnWindowAcquireTexture", (void *)win_acquire},
    {"nvnQueueBuilderGetQueueMemorySize", (void *)queue_memory_size},
    {"nvnQueuePresentTexture", (void *)gfx_queue_present},
    {"nvnDeviceGetInteger", (void *)dev_get_integer},
    {"nvnDeviceGetTimestampInNanoseconds", (void *)dev_timestamp_ns},
    {"nvnDeviceGetCurrentTimestampInNanoseconds", (void *)dev_current_timestamp_ns},
    {"nvnMemoryPoolBuilderSetDefaults", (void *)pool_builder_defaults},
    {"nvnMemoryPoolBuilderSetStorage", (void *)pool_builder_set_storage},
    {"nvnMemoryPoolBuilderSetFlags", (void *)pool_builder_set_flags},
    {"nvnMemoryPoolInitialize", (void *)pool_initialize},
    {"nvnMemoryPoolMap", (void *)pool_map},
    {"nvnMemoryPoolFinalize", (void *)pool_finalize},
    {"nvnMemoryPoolGetBufferAddress", (void *)pool_get_address},
    {"nvnMemoryPoolGetSize", (void *)pool_get_size},
    {"nvnMemoryPoolGetFlags", (void *)pool_get_flags},
    {"nvnMemoryPoolFlushMappedRange", (void *)pool_flush_range},
    {"nvnMemoryPoolInvalidateMappedRange", (void *)pool_invalidate_range},
    {"nvnMemoryPoolMapVirtual", (void *)pool_map_virtual},
    {"nvnBufferBuilderSetDefaults", (void *)buffer_builder_defaults},
    {"nvnBufferBuilderSetStorage", (void *)buffer_builder_set_storage},
    {"nvnBufferInitialize", (void *)buffer_initialize},
    {"nvnBufferMap", (void *)buffer_map},
    {"nvnBufferGetAddress", (void *)buffer_get_address},
    {"nvnBufferGetSize", (void *)buffer_get_size},
    {"nvnTextureBuilderSetDefaults", (void *)tex_builder_defaults},
    {"nvnTextureBuilderSetSize1D", (void *)tex_builder_set_size1d},
    {"nvnTextureBuilderSetSize2D", (void *)tex_builder_set_size2d},
    {"nvnTextureBuilderSetSize3D", (void *)tex_builder_set_size3d},
    {"nvnTextureBuilderSetWidth", (void *)tex_builder_set_width},
    {"nvnTextureBuilderSetHeight", (void *)tex_builder_set_height},
    {"nvnTextureBuilderSetDepth", (void *)tex_builder_set_depth},
    {"nvnTextureBuilderSetLevels", (void *)tex_builder_set_levels},
    {"nvnTextureBuilderSetFormat", (void *)tex_builder_set_format},
    {"nvnTextureBuilderSetTarget", (void *)tex_builder_set_target},
    {"nvnTextureBuilderSetFlags", (void *)tex_builder_set_flags},
    {"nvnTextureBuilderSetSamples", (void *)tex_builder_set_samples},
    {"nvnTextureBuilderSetStorage", (void *)tex_builder_set_storage},
    {"nvnTextureBuilderGetStorageSize", (void *)tex_builder_get_storage_size},
    {"nvnTextureBuilderGetStorageAlignment", (void *)tex_builder_get_storage_alignment},
    {"nvnTextureInitialize", (void *)tex_initialize},
    {"nvnTextureFinalize", (void *)gfx_texture_finalize},
    {"nvnProgramSetShaders", (void *)gfx_program_set_shaders},
    {"nvnDeviceSetWindowOriginMode", (void *)bp_window_origin_mode},
    {"nvnDeviceSetDepthMode", (void *)bp_depth_mode},
    {"nvnProgramSetShadersExt", (void *)gfx_program_set_shaders_ext},
    {"nvnTextureBuilderSetPackagedTextureData", (void *)gfx_texbuilder_packaged_data},
    {"nvnTextureBuilderSetPackagedTextureLayout", (void *)gfx_texbuilder_packaged_layout},
    {"nvnTextureBuilderSetStride", (void *)gfx_texbuilder_stride},
    {"nvnTextureBuilderSetSwizzle", (void *)gfx_texbuilder_swizzle},
    {"nvnTextureWriteTexels", (void *)gfx_texture_write_texels},
    {"nvnTextureGetWidth", (void *)tex_get_width},
    {"nvnTextureGetHeight", (void *)tex_get_height},
    {"nvnTextureGetDepth", (void *)tex_get_depth},
    {"nvnTextureGetFormat", (void *)tex_get_format},
    {"nvnTextureGetStorageSize", (void *)tex_get_storage_size},
};

// Every proc handed to the game is a thunk (nvn_thunks.S) that runs the real function
// on the thread's host stack; nx_nvn_targets[i] is the real function.
extern char nx_nvn_thunks[];
void *nx_nvn_targets[1100];
uint64_t nx_tsd_key_off;

static void *thunk(int i) { return nx_nvn_thunks + 8 * i; }

static void *proc_for(const char *name) {
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < g_nprocs; i++)
        if (!strcmp(g_names[i], name)) {
            pthread_mutex_unlock(&g_lock);
            return thunk(i);
        }
    if (g_nprocs == MAX_PROCS) nx_fatal("nvn: more than %d procs", MAX_PROCS);
    int i = g_nprocs++;
    g_names[i] = strdup(name);
    g_ret[i] = default_return(name);
    nx_nvn_targets[i] = (void *)g_stubs[i];
    g_is_stub[i] = 1;
    for (unsigned k = 0; k < sizeof g_impl / sizeof *g_impl; k++)
        if (!strcmp(g_impl[k].name, name)) nx_nvn_targets[i] = g_impl[k].fn, g_is_stub[i] = 0;
    void *gfx = gfx_proc_for(name);
    if (gfx) nx_nvn_targets[i] = gfx, g_is_stub[i] = 0;
    pthread_mutex_unlock(&g_lock);
    return thunk(i);
}

static void *nvn_device_get_proc_address(void *device, const char *name) {
    return name ? proc_for(name) : NULL;
}

void *nx_nvn_bootstrap_loader(const char *name) {
    static int logged;
    if (!logged++) nx_log("nvn: nvnBootstrapLoader is now ours");
    if (!name) return NULL;
    if (!strcmp(name, "nvnDeviceGetProcAddress")) {
        void *t = proc_for(name);                        // thunked like every other proc
        nx_nvn_targets[(int)(((char *)t - nx_nvn_thunks) / 8)] = (void *)nvn_device_get_proc_address;
        return t;
    }
    return proc_for(name);
}

int nx_nvn_proc_count(void) { return g_nprocs; }

void find_proc_slot(const char *name);
// NXRT_GFXDBG helper: where the game keeps its pointers to some NVN procs (scan main's image).
void nx_nvn_find_proc_slots(void) {
    static const char *const names[] = {"nvnCommandBufferEndRecording", "nvnCommandBufferCallCommands",
                                        "nvnQueueSubmitCommands", "nvnCommandBufferCopyCommands", NULL};
    Module *m = nx_module("main");
    static const char *const mods[] = {"rtld", "main", "subsdk9", "sdk"};
    uint64_t gotv = *(uint64_t *)(m->base + 0x32e1fb8);
    uint64_t fn = gotv ? *(uint64_t *)gotv : 0;
    for (int k = 0; k < 4; k++) {
        Module *mm = nx_module(mods[k]);
        if (!mm) continue;
        if (gotv >= (uint64_t)mm->base && gotv < (uint64_t)mm->base + mm->size)
            nx_log("nvn: [main+0x32e1fb8] = %s+%#llx", mods[k], (unsigned long long)(gotv - (uint64_t)mm->base));
        if (fn >= (uint64_t)mm->base && fn < (uint64_t)mm->base + mm->size)
            nx_log("nvn: -> function %s+%#llx", mods[k], (unsigned long long)(fn - (uint64_t)mm->base));
    }
    nx_log("nvn: [main+0x32e1fb8] = %#llx -> %#llx (thunks at %p)", (unsigned long long)gotv, (unsigned long long)fn, (void *)nx_nvn_thunks);
    for (int k = 0; names[k]; k++) find_proc_slot(names[k]);
}

// Where the game keeps a pointer to an NVN proc: slots holding the thunk in main/sdk, and main GOT
// entries pointing at those slots (main reaches NVN through sdk's dispatch table at sdk+0xc333e8).
void find_proc_slot(const char *name) {
    int idx = -1;
    for (int i = 0; i < g_nprocs; i++)
        if (!strcmp(g_names[i], name)) idx = i;
    if (idx < 0) { nx_log("nvn: %s never looked up", name); return; }
    uint64_t want = (uint64_t)thunk(idx);
    Module *main = nx_module("main");
    static const char *const mods[] = {"main", "sdk"};
    for (int k = 0; k < 2; k++) {
        Module *mm = nx_module(mods[k]);
        for (uint64_t o = 0; mm && o + 8 <= mm->size; o += 8) {
            if (*(uint64_t *)(mm->base + o) != want) continue;
            nx_log("nvn: %s+%#llx holds %s", mods[k], (unsigned long long)o, name);
            uint64_t slot = (uint64_t)(mm->base + o);
            for (uint64_t g = 0; g + 8 <= main->size; g += 8)
                if (*(uint64_t *)(main->base + g) == slot) nx_log("nvn:   main+%#llx points to it", (unsigned long long)g);
        }
    }
}

// NXRT_GOTNAME=<main offset>[,...]: name the NVN proc behind a main GOT entry (GOT -> slot -> thunk).
void nx_nvn_gotname_env(void) {
    static int done;
    const char *e = getenv("NXRT_GOTNAME");
    if (done || !e) return;
    done = 1;
    Module *m = nx_module("main");
    char buf[1024];
    snprintf(buf, sizeof buf, "%s", e);
    for (char *t = strtok(buf, ","); t; t = strtok(NULL, ",")) {
        uint64_t off = strtoull(t, NULL, 16), slot = *(uint64_t *)(m->base + off), fn = 0;
        if (slot) memcpy(&fn, (void *)slot, 8);
        const char *name = "?";
        for (int i = 0; i < g_nprocs; i++)
            if ((uint64_t)thunk(i) == fn) name = g_names[i];
        nx_log("nvn: GOT main+%#llx -> slot %#llx -> %#llx = %s", (unsigned long long)off, (unsigned long long)slot,
               (unsigned long long)fn, name);
    }
}

// NXRT_FINDPTR=<main offset>[,...]: where main's image holds a pointer to main+offset (vtables).
void nx_findptr_env(void) {
    static int done;
    const char *e = getenv("NXRT_FINDPTR");
    if (done || !e) return;
    done = 1;
    Module *m = nx_module("main");
    char buf[1024];
    snprintf(buf, sizeof buf, "%s", e);
    for (char *t = strtok(buf, ","); t; t = strtok(NULL, ",")) {
        uint64_t want = (uint64_t)m->base + strtoull(t, NULL, 16);
        for (uint64_t o = 0; o + 8 <= m->size; o += 8)
            if (*(uint64_t *)(m->base + o) == want) nx_log("findptr: main+%s at main+%#llx", t, (unsigned long long)o);
    }
}

// NXRT_FINDPROC=name[,name...]: run find_proc_slot once the game has looked its procs up.
void nx_nvn_findproc_env(void) {
    static int done;
    const char *e = getenv("NXRT_FINDPROC");
    if (done || !e) return;
    done = 1;
    char buf[1024];
    snprintf(buf, sizeof buf, "%s", e);
    for (char *t = strtok(buf, ","); t; t = strtok(NULL, ",")) find_proc_slot(t);
}
