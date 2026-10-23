// Guest address space: one big host reservation carved into Horizon's regions.
// Guest-visible state is tracked in the region list (svc.c) for svcQueryMemory; host
// pages are mapped with MAP_FIXED inside the reservation as the guest asks for them.
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <stdio.h>
#include <sys/param.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include "nxrt.h"

#define GiB (1ull << 30)

AddressSpace g_as;

void nx_as_init(void) {
    uint64_t size = 64 * GiB;
    // The whole space is RW and committed lazily: Horizon pages are 4 KB but host pages
    // are 16 KB, so guest mappings at 4 KB granularity cannot be real host mappings.
    // Guest-visible state lives in the region list; MapMemory copies (see nx_alias).
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) nx_fatal("cannot reserve %llu GiB of address space", size / GiB);
    g_as.base = (uint64_t)p;
    g_as.size = size;
    g_as.heap_base = g_as.base;                   // 8 GiB
    g_as.heap_size = 8 * GiB;
    g_as.alias_base = g_as.base + 8 * GiB;        // 16 GiB (MapPhysicalMemory, MapMemory)
    g_as.alias_size = 16 * GiB;
    g_as.stack_base = g_as.base + 24 * GiB;       // 2 GiB (thread stacks via MapMemory)
    g_as.stack_size = 2 * GiB;
    nx_log("address space %#llx..%#llx heap %#llx alias %#llx stack %#llx",
           (unsigned long long)g_as.base, (unsigned long long)(g_as.base + g_as.size),
           (unsigned long long)g_as.heap_base, (unsigned long long)g_as.alias_base,
           (unsigned long long)g_as.stack_base);
}

static int in_as(uint64_t addr, uint64_t size) {
    return addr >= g_as.base && addr + size <= g_as.base + g_as.size && addr + size >= addr;
}

// Fresh zeroed pages for [addr, addr+size): whole host pages are replaced, the 4 KB
// edges inside shared host pages are cleared by hand.
static void zero_range(uint64_t addr, uint64_t size) {
    const uint64_t P = 0x4000;
    uint64_t lo = (addr + P - 1) & ~(P - 1), hi = (addr + size) & ~(P - 1);
    if (lo < hi) {
        mmap((void *)lo, hi - lo, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
        if (addr < lo) memset((void *)addr, 0, lo - addr);
        if (hi < addr + size) memset((void *)hi, 0, addr + size - hi);
    } else {
        memset((void *)addr, 0, size);
    }
}

int nx_map_anon(uint64_t addr, uint64_t size) {
    if (!in_as(addr, size)) return -1;
    zero_range(addr, size);
    return 0;
}

int nx_unmap(uint64_t addr, uint64_t size) {
    if (!in_as(addr, size)) return -1;
    zero_range(addr, size);
    return 0;
}

// svcMapMemory(dst, src, size): Horizon aliases the pages and makes src inaccessible
// until UnmapMemory. Copy in now and copy back on unmap: nothing may touch src meanwhile.
int nx_alias(uint64_t dst, uint64_t src, uint64_t size) {
    if (!in_as(dst, size)) return -1;
    memcpy((void *)dst, (void *)src, size);
    return 0;
}

int nx_unalias(uint64_t dst, uint64_t src, uint64_t size) {
    if (!in_as(dst, size)) return -1;
    memcpy((void *)src, (void *)dst, size);
    zero_range(dst, size);
    return 0;
}

// Memory breakdown (stats line, NXRT_STATS_EVERY): dirty + compressed host memory of our own mappings, by owner:
// the guest's heap / alias / stack regions, the loaded game image, malloc, Metal buffers mapped into the process
// (IOAccelerator), everything else. GPU-private memory (Metal textures) is in the footprint but not mapped, so
// footprint - mapped total ~= GPU-private. vmmap/footprint hang on this process (64 GiB reservation).
void nx_mem_breakdown(char *out, size_t cap) {
    enum { HEAP, ALIAS, STACK, GUEST, IMAGE, MALLOC, IOACCEL, OTHER, N };
    static const char *name[N] = {"guest heap", "guest alias", "guest stack", "guest other", "image", "malloc", "Metal mapped", "other"};
    uint64_t sum[N] = {0};
    uint64_t g_image_base = (uint64_t)(uintptr_t)g_image.base, g_image_size = g_image.size;
    vm_address_t a = 0;
    natural_t depth = 0;
    for (;;) {
        vm_size_t sz = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &a, &sz, &depth, (vm_region_recurse_info_t)&info, &cnt) != KERN_SUCCESS) break;
        if (info.is_submap) { depth++; continue; }
        if (a >= g_as.base && a < g_as.base + g_as.size) { a += sz; continue; }   // guest: mincore below
        uint64_t b = (uint64_t)(info.pages_dirtied + info.pages_swapped_out) * vm_page_size;
        int k = OTHER;
        if (a >= g_image_base && a < g_image_base + g_image_size) k = IMAGE;
        else if (info.user_tag >= 1 && info.user_tag <= 11) k = MALLOC;
        else if (info.user_tag == 100 || info.user_tag == 88) k = IOACCEL;
        sum[k] += b;
        a += sz;
    }
    // Guest regions: resident pages (anonymous memory: resident = touched; compressed pages are missed).
    static unsigned char *vec;
    const uint64_t P = vm_page_size, CH = 1ull << 30;
    if (!vec) vec = malloc(CH / P);
    uint64_t lo[4] = {g_as.heap_base, g_as.alias_base, g_as.stack_base, g_as.stack_base + g_as.stack_size};
    uint64_t hi[4] = {g_as.heap_base + g_as.heap_size, g_as.alias_base + g_as.alias_size, g_as.stack_base + g_as.stack_size, g_as.base + g_as.size};
    for (int r = 0; r < 4 && vec; r++)
        for (uint64_t c = lo[r]; c < hi[r]; c += CH) {
            uint64_t len = MIN(CH, hi[r] - c);
            if (mincore((void *)c, len, (char *)vec)) continue;
            for (uint64_t q = 0; q < len / P; q++) sum[HEAP + r] += (vec[q] & MINCORE_INCORE) ? P : 0;
        }
    size_t n = 0;
    uint64_t tot = 0;
    for (int i = 0; i < N; i++) {
        tot += sum[i];
        n += snprintf(out + n, n < cap ? cap - n : 0, "%s%s %.0f", i ? ", " : "", name[i], sum[i] / 1048576.0);
    }
    n += snprintf(out + n, n < cap ? cap - n : 0, " (mapped total %.0f MB); malloc zones in use:", tot / 1048576.0);
    vm_address_t *zones;
    unsigned nz = 0;
    if (malloc_get_all_zones(mach_task_self(), NULL, &zones, &nz) == KERN_SUCCESS)
        for (unsigned i = 0; i < nz; i++) {
            malloc_zone_t *z = (malloc_zone_t *)zones[i];
            malloc_statistics_t st = {0};
            malloc_zone_statistics(z, &st);
            if (st.size_in_use >= (16u << 20))
                n += snprintf(out + n, n < cap ? cap - n : 0, " %s %.0f MB (%u blocks)", malloc_get_zone_name(z) ? malloc_get_zone_name(z) : "?",
                              st.size_in_use / 1048576.0, st.blocks_in_use);
        }
}

// NXRT_MALLOCHIST=1: live blocks of the default malloc zone by size class (log2), with the stats line.
static uint64_t g_mh_n[40], g_mh_b[40];
static void mh_rec(task_t task, void *ctx, unsigned type, vm_range_t *r, unsigned n) {
    for (unsigned i = 0; i < n; i++) {
        int c = 0;
        while (c < 39 && (1ull << (c + 1)) <= r[i].size) c++;
        g_mh_n[c]++, g_mh_b[c] += r[i].size;
    }
}
static kern_return_t mh_read(task_t t, vm_address_t a, vm_size_t s, void **p) { *p = (void *)a; return KERN_SUCCESS; }
void nx_malloc_hist(void) {
    static int on = -1;
    if (on < 0) on = getenv("NXRT_MALLOCHIST") != NULL;
    if (!on) return;
    malloc_zone_t *z = malloc_default_zone();
    memset(g_mh_n, 0, sizeof g_mh_n), memset(g_mh_b, 0, sizeof g_mh_b);
    z->introspect->force_lock(z);
    z->introspect->enumerator(mach_task_self(), NULL, MALLOC_PTR_IN_USE_RANGE_TYPE, (vm_address_t)z, mh_read, mh_rec);
    z->introspect->force_unlock(z);
    char line[2048];
    size_t n = 0;
    for (int c = 0; c < 40; c++)
        if (g_mh_b[c] >= (1u << 20)) n += snprintf(line + n, sizeof line - n, " [%llu..): %llu x = %.0f MB;", 1ull << c, g_mh_n[c], g_mh_b[c] / 1048576.0);
    nx_log("mem: malloc blocks by size:%s", line);
}

// Calls fn on each run of resident pages of the guest heap (mincore: untouched reserved pages are skipped, so a scan
// doesn't fault the whole reservation in).
void nx_guest_heap_each(void (*fn)(uint8_t *p, size_t n, void *ctx), void *ctx) {
    static unsigned char *vec;
    const uint64_t P = vm_page_size, CH = 1ull << 30;
    if (!vec) vec = malloc(CH / P);
    if (!vec) return;
    for (uint64_t c = g_as.heap_base; c < g_as.heap_base + g_as.heap_size; c += CH) {
        uint64_t len = MIN(CH, g_as.heap_base + g_as.heap_size - c);
        if (mincore((void *)c, len, (char *)vec)) continue;
        uint64_t run = 0;
        for (uint64_t q = 0; q <= len / P; q++) {
            int in = q < len / P && (vec[q] & MINCORE_INCORE);
            if (in) run++;
            else if (run) fn((uint8_t *)(c + (q - run) * P), run * P, ctx), run = 0;
        }
    }
}
