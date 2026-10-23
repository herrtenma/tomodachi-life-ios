#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include "nxrt.h"

static pthread_key_t g_key;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static void make_key(void) {
    if (pthread_key_create(&g_key, NULL)) nx_fatal("pthread_key_create failed");
}

static uint64_t read_tpidrro(void) {
    uint64_t v;
    __asm__ volatile("mrs %0, tpidrro_el0" : "=r"(v));
    return v & ~7ull;
}

// Offset of our key's slot from TPIDRRO_EL0 (the trampolines load [tpidrro + off]).
// Checked against pthread_getspecific so a libpthread layout change fails loudly.
uint64_t nx_tsd_key_offset(void) {
    pthread_once(&g_once, make_key);
    uint64_t off = (uint64_t)g_key * 8;
    void *probe = (void *)0x5157e5d0c0ffee00ull;
    pthread_setspecific(g_key, probe);
    void *seen = *(void **)(read_tpidrro() + off);
    if (seen != probe) nx_fatal("TSD layout check failed (key %lu)", (unsigned long)g_key);
    pthread_setspecific(g_key, NULL);
    return off;
}

static void *map(size_t size) {
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) nx_fatal("mmap %zu failed", size);
    return p;
}

GuestThread *nx_thread_new(uint32_t handle) {
    GuestThread *t = calloc(1, sizeof *t);
    t->handle = handle;
    t->obj.type = KO_THREAD;
    t->obj.ptr = t;
    t->obj.refs = 1;
    t->run_core = -1;
    pthread_cond_init(&t->cv, NULL);
    static uint32_t next_id = 1;
    t->id = __atomic_fetch_add(&next_id, 1, __ATOMIC_RELAXED);
    t->tls_region = map(0x4000);           // Horizon TLS region: 0x200 bytes, page here
    t->tpidrro = (uint64_t)t->tls_region;
    t->host_stack_size = 1 << 20;
    t->host_stack = map(t->host_stack_size);
    // Guard page: host code on this stack (SVC handlers, NVN calls into Metal) must fault here
    // instead of silently overwriting the mapping below (possibly another thread's stack).
    if (mprotect(t->host_stack, 0x4000, PROT_NONE)) nx_fatal("host stack guard mprotect failed");
    t->host_stack_top = (uint64_t)(t->host_stack + t->host_stack_size);
    return t;
}

// Every bound guest thread with its host thread (GuestThreads are never freed): the freeze watchdog labels threads.
// Binds are serialized by thread creation, so the plain counter is enough.
static GuestThread *g_bound[256];
static pthread_t g_bound_host[256];
static int g_nbound;
void nx_thread_bind(GuestThread *t) {
    pthread_once(&g_once, make_key);
    pthread_setspecific(g_key, t);
    int i = __atomic_load_n(&g_nbound, __ATOMIC_ACQUIRE);
    if (i < 256) g_bound[i] = t, g_bound_host[i] = pthread_self(), __atomic_store_n(&g_nbound, i + 1, __ATOMIC_RELEASE);
}
GuestThread *nx_thread_by_host(pthread_t p) {
    for (int i = 0, n = __atomic_load_n(&g_nbound, __ATOMIC_ACQUIRE); i < n; i++)
        if (g_bound_host[i] == p) return g_bound[i];
    return NULL;
}

GuestThread *nx_current(void) {
    return pthread_getspecific(g_key);
}

uint64_t nx_host_stack_top(void) {
    GuestThread *t = nx_current();
    if (!t) nx_fatal("SVC from a host thread with no guest thread");
    return t->host_stack_top;
}

#include <mach/mach.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <time.h>
#include <mach/mach_time.h>
#include <unistd.h>
enum { CPU_SLOTS = 512 };

// NXRT_PERF (gfx_draw_stats): CPU time per host thread over the last stats interval, split by core type, with each
// cluster's effective clock (cycles / time): is the encode on the efficiency cores, and at what clock. Per-thread
// counts come from proc_pidinfo flavor 34 (PROC_PIDTHREADCOUNTS, xnu recount; private, not in the SDK headers):
// one entry per perf level, [0] performance cores, [1] efficiency cores (checked on an M2 with a background and a
// user-interactive spinning thread). Guest threads are named "guest <id> p<priority>" (+ "main" / "submit").
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
typedef struct { uint64_t instructions, cycles, user_mach, system_mach, energy_nj; } ThreadCounts;
typedef struct { uint16_t len, reserved0; uint32_t reserved1; ThreadCounts lvl[4]; } ThreadCountsReply;
enum { CPU_TOP = 12 };
static struct { uint64_t tid, ns[2], cyc[2]; int seen; } g_cpu_last[CPU_SLOTS];
typedef struct { char name[48]; int pri; double ns[2], cyc[2]; } CpuRow;
static int cpu_row_cmp(const void *a, const void *b) {
    double x = ((const CpuRow *)a)->ns[0] + ((const CpuRow *)a)->ns[1], y = ((const CpuRow *)b)->ns[0] + ((const CpuRow *)b)->ns[1];
    return x < y ? 1 : x > y ? -1 : 0;
}
void nx_thread_cpu_stats(int frames) {
    static mach_timebase_info_data_t tb;
    static int unavailable;
    if (!tb.denom) mach_timebase_info(&tb);
    if (unavailable || frames <= 0) return;
    thread_act_array_t list;
    mach_msg_type_number_t n;
    if (task_threads(mach_task_self(), &list, &n) != KERN_SUCCESS) return;
    static CpuRow rows[CPU_SLOTS];
    int nr = 0;
    double tot[2] = {0}, totcyc[2] = {0};
    for (int i = 0; i < CPU_SLOTS; i++) g_cpu_last[i].seen = 0;
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        thread_identifier_info_data_t id;
        mach_msg_type_number_t c = THREAD_IDENTIFIER_INFO_COUNT;
        struct thread_extended_info ext;
        mach_msg_type_number_t ce = THREAD_EXTENDED_INFO_COUNT;
        ThreadCountsReply r = {0};
        if (thread_info(list[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&id, &c) == KERN_SUCCESS &&
            thread_info(list[i], THREAD_EXTENDED_INFO, (thread_info_t)&ext, &ce) == KERN_SUCCESS) {
            if (proc_pidinfo(getpid(), 34, id.thread_id, &r, sizeof r) <= 0) {
                unavailable = 1;
                nx_log("cpu: per-thread core-type counts unavailable (proc_pidinfo PROC_PIDTHREADCOUNTS failed)");
            }
            int slot = -1, fresh = -1;
            for (int k = 0; k < CPU_SLOTS && slot < 0; k++) {
                if (g_cpu_last[k].tid == id.thread_id) slot = k;
                else if (fresh < 0 && !g_cpu_last[k].tid) fresh = k;
            }
            if (slot < 0 && fresh >= 0) slot = fresh, g_cpu_last[slot].tid = id.thread_id;
            if (slot >= 0 && nr < CPU_SLOTS) {
                CpuRow *w = &rows[nr++];
                g_cpu_last[slot].seen = 1;
                snprintf(w->name, sizeof w->name, "%s", ext.pth_name[0] ? ext.pth_name : "?");
                if (!ext.pth_name[0]) snprintf(w->name, sizeof w->name, "tid %llu", (unsigned long long)id.thread_id);
                w->pri = ext.pth_priority;
                for (int l = 0; l < 2; l++) {
                    uint64_t ns = l < r.len ? (r.lvl[l].user_mach + r.lvl[l].system_mach) * tb.numer / tb.denom : 0;
                    uint64_t cy = l < r.len ? r.lvl[l].cycles : 0;
                    w->ns[l] = ns >= g_cpu_last[slot].ns[l] ? (double)(ns - g_cpu_last[slot].ns[l]) : 0;
                    w->cyc[l] = cy >= g_cpu_last[slot].cyc[l] ? (double)(cy - g_cpu_last[slot].cyc[l]) : 0;
                    g_cpu_last[slot].ns[l] = ns, g_cpu_last[slot].cyc[l] = cy;
                    tot[l] += w->ns[l], totcyc[l] += w->cyc[l];
                }
            }
        }
        mach_port_deallocate(mach_task_self(), list[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)list, n * sizeof *list);
    for (int k = 0; k < CPU_SLOTS; k++)   // exited threads free their slot
        if (g_cpu_last[k].tid && !g_cpu_last[k].seen) memset(&g_cpu_last[k], 0, sizeof g_cpu_last[k]);
    if (unavailable) return;
    static int first = 1;
    if (first) {   // the first interval counts from thread start: skip it
        first = 0;
        return;
    }
    qsort(rows, nr, sizeof *rows, cpu_row_cmp);
    nx_log("cpu: %d threads, %.1f ms CPU/frame: P cores %.1f ms at %.2f GHz, E cores %.1f ms at %.2f GHz", nr,
           (tot[0] + tot[1]) / 1e6 / frames, tot[0] / 1e6 / frames, tot[0] ? totcyc[0] / tot[0] : 0.0, tot[1] / 1e6 / frames,
           tot[1] ? totcyc[1] / tot[1] : 0.0);
    double rest = 0;
    for (int i = 0; i < nr; i++) {
        double all = (rows[i].ns[0] + rows[i].ns[1]) / 1e6 / frames;
        if (i >= CPU_TOP || all < 0.1) {
            rest += all;
            continue;
        }
        nx_log("cpu:   %-32s pri %2d: %5.2f ms/frame, %3.0f%% on P (%.2f GHz), E %.2f ms (%.2f GHz)", rows[i].name, rows[i].pri, all,
               100 * rows[i].ns[0] / (rows[i].ns[0] + rows[i].ns[1]), rows[i].ns[0] ? rows[i].cyc[0] / rows[i].ns[0] : 0.0,
               rows[i].ns[1] / 1e6 / frames, rows[i].ns[1] ? rows[i].cyc[1] / rows[i].ns[1] : 0.0);
    }
    if (rest > 0) nx_log("cpu:   other threads %.2f ms/frame", rest);
}

// NXRT_HITCHLOG=<ms>: each frame whose present-to-present time passes <ms>, one "hitch:" line with what the frame
// spent (encode wall / CPU, compile waits, texture uploads, shader loads, new pipelines, GPU busy, fence blocking, pace
// sleep) and the threads that used the most CPU in it; every 600 frames a count of slow frames. Per frame it reads every
// thread's CPU time (task_threads + THREAD_BASIC_INFO, ~70 threads).
typedef struct { uint64_t tid, ns, d; int seen; thread_act_t port; } HitchThread;
static int hitch_cmp(const void *a, const void *b) {
    uint64_t x = ((const HitchThread *)a)->d, y = ((const HitchThread *)b)->d;
    return x < y ? 1 : x > y ? -1 : 0;
}
void nx_hitch_frame(int frame) {
    static double thr = -1;
    if (thr < 0) thr = getenv("NXRT_HITCHLOG") ? atof(getenv("NXRT_HITCHLOG")) : 0;
    if (thr <= 0) return;
    static HitchThread th[CPU_SLOTS];
    static uint64_t last_t, last_c[10];
    static int nslow[4], ninterval;
    static double worst;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), c[10], tot = 0;
    void gfx_hitch_counters(uint64_t c[10]);
    gfx_hitch_counters(c);
    // This process's paging: does a slow frame wait on the compressor / swap? (the system-wide host_statistics64
    // counts update in batches, not per frame)
    static uint64_t last_vm[4];
    uint64_t vmv[4] = {0};
    task_vm_info_data_t tv;
    mach_msg_type_number_t tvc = TASK_VM_INFO_COUNT;
    task_events_info_data_t te;
    mach_msg_type_number_t tec = TASK_EVENTS_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&tv, &tvc) == KERN_SUCCESS) vmv[0] = (uint32_t)tv.decompressions, vmv[2] = (uint64_t)tv.ledger_swapins;
    if (task_info(mach_task_self(), TASK_EVENTS_INFO, (task_info_t)&te, &tec) == KERN_SUCCESS) vmv[1] = (uint32_t)te.faults, vmv[3] = (uint32_t)te.pageins;
    thread_act_array_t list;
    mach_msg_type_number_t n = 0;
    if (task_threads(mach_task_self(), &list, &n) != KERN_SUCCESS) return;
    for (int k = 0; k < CPU_SLOTS; k++) th[k].seen = 0, th[k].d = 0, th[k].port = 0;
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        thread_identifier_info_data_t id;
        mach_msg_type_number_t ci = THREAD_IDENTIFIER_INFO_COUNT;
        thread_basic_info_data_t bi;
        mach_msg_type_number_t cb = THREAD_BASIC_INFO_COUNT;
        if (thread_info(list[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&id, &ci) != KERN_SUCCESS ||
            thread_info(list[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &cb) != KERN_SUCCESS)
            continue;
        uint64_t ns = (uint64_t)(bi.user_time.seconds + bi.system_time.seconds) * 1000000000ull +
                      (uint64_t)(bi.user_time.microseconds + bi.system_time.microseconds) * 1000ull;
        int slot = -1, fresh = -1;
        for (int k = 0; k < CPU_SLOTS && slot < 0; k++) {
            if (th[k].tid == id.thread_id) slot = k;
            else if (fresh < 0 && !th[k].tid) fresh = k;
        }
        if (slot < 0 && fresh >= 0) slot = fresh, th[slot].tid = id.thread_id, th[slot].ns = ns;
        if (slot < 0) continue;
        th[slot].d = ns >= th[slot].ns ? ns - th[slot].ns : 0, th[slot].ns = ns, th[slot].seen = 1, th[slot].port = list[i];
        tot += th[slot].d;
    }
    double ms = last_t ? (now - last_t) / 1e6 : 0;
    if (last_t && ms > thr) {
        static HitchThread top[CPU_SLOTS];
        memcpy(top, th, sizeof top);
        qsort(top, CPU_SLOTS, sizeof *top, hitch_cmp);
        char line[512];
        int o = 0;
        for (int k = 0; k < 6 && top[k].d >= 500000; k++) {
            struct thread_extended_info ext;
            mach_msg_type_number_t ce = THREAD_EXTENDED_INFO_COUNT;
            if (top[k].port && thread_info(top[k].port, THREAD_EXTENDED_INFO, (thread_info_t)&ext, &ce) == KERN_SUCCESS && ext.pth_name[0])
                o += snprintf(line + o, sizeof line - o, " %s %.1f,", ext.pth_name, top[k].d / 1e6);
            else {   // a dispatch worker: its queue's label (read while it may change: diagnostics only)
                thread_identifier_info_data_t id;
                mach_msg_type_number_t ci = THREAD_IDENTIFIER_INFO_COUNT;
                dispatch_queue_t q = top[k].port && thread_info(top[k].port, THREAD_IDENTIFIER_INFO, (thread_info_t)&id, &ci) == KERN_SUCCESS &&
                                             id.dispatch_qaddr ? *(dispatch_queue_t __unsafe_unretained *)id.dispatch_qaddr : NULL;
                const char *ql = q ? dispatch_queue_get_label(q) : NULL;
                o += snprintf(line + o, sizeof line - o, " tid %llu [%s] %.1f,", (unsigned long long)top[k].tid, ql ? ql : "", top[k].d / 1e6);
            }
        }
        nx_log("hitch: frame %d %.1f ms: encode %.1f (CPU %.1f), compile waits %.1f, uploads %.1f (%.1f MB), shader loads %.1f, %llu new pipelines, "
               "GPU busy %.1f, fence blocking %.1f, pace %.1f; process CPU %.1f ms; paging %llu decompressed, %llu faults, %llu swapped in, "
               "%llu paged in; top threads:%s", frame, ms, (c[0] - last_c[0]) / 1e6,
               (c[1] - last_c[1]) / 1e6, (c[2] - last_c[2]) / 1e6, (c[3] - last_c[3]) / 1e6, (c[4] - last_c[4]) / 1e6, (c[5] - last_c[5]) / 1e6,
               (unsigned long long)(c[6] - last_c[6]), (c[7] - last_c[7]) / 1e6, (c[8] - last_c[8]) / 1e6, (c[9] - last_c[9]) / 1e6, tot / 1e6, (unsigned long long)(vmv[0] - last_vm[0]),
               (unsigned long long)(vmv[1] - last_vm[1]), (unsigned long long)(vmv[2] - last_vm[2]), (unsigned long long)(vmv[3] - last_vm[3]), line);
    }
    if (last_t) {
        static uint64_t vm_sum[4];
        for (int k = 0; k < 4; k++) vm_sum[k] += vmv[k] - last_vm[k];
        nslow[0] += ms > 17.5, nslow[1] += ms > 20, nslow[2] += ms > 34, nslow[3] += ms > 50, worst = ms > worst ? ms : worst;
        if (++ninterval == 600) {
            nx_log("hitch: frames %d-%d: %d over 17.5 ms, %d over 20, %d over 34, %d over 50; worst %.1f ms; paging %llu decompressed, "
                   "%llu faults, %llu swapped in, %llu paged in", frame - 599, frame, nslow[0], nslow[1], nslow[2], nslow[3], worst,
                   (unsigned long long)vm_sum[0], (unsigned long long)vm_sum[1], (unsigned long long)vm_sum[2], (unsigned long long)vm_sum[3]);
            memset(nslow, 0, sizeof nslow), memset(vm_sum, 0, sizeof vm_sum), ninterval = 0, worst = 0;
        }
    }
    for (int k = 0; k < CPU_SLOTS; k++)   // exited threads free their slot
        if (th[k].tid && !th[k].seen) memset(&th[k], 0, sizeof th[k]);
    for (mach_msg_type_number_t i = 0; i < n; i++) mach_port_deallocate(mach_task_self(), list[i]);
    vm_deallocate(mach_task_self(), (vm_address_t)list, n * sizeof *list);
    memcpy(last_c, c, sizeof last_c), memcpy(last_vm, vmv, sizeof last_vm), last_t = now;
}
