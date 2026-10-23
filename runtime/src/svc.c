// Horizon SVCs, implemented on the host. Register conventions follow the sdk's own
// wrapper functions (each `svc #N` sits in a tiny wrapper that shows its outputs).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nxrt.h"

// ---- memory map for svcQueryMemory -------------------------------------------------

typedef struct { uint64_t base, size; uint32_t state, perm; } Region;
static Region g_regions[256];
static int g_nregions;

void nx_region_add(uint64_t base, uint64_t size, uint32_t state, uint32_t perm) {
    if (g_nregions == 256) nx_fatal("too many regions");
    int i = g_nregions++;
    while (i > 0 && g_regions[i - 1].base > base) {
        g_regions[i] = g_regions[i - 1];
        i--;
    }
    g_regions[i] = (Region){base, size, state, perm};
}

// Iterate the region map (no lock: regions only change on map/unmap SVCs; callers tolerate staleness).
int nx_region_get(int i, uint64_t *base, uint64_t *size, uint32_t *perm) {
    if (i < 0 || i >= g_nregions) return 0;
    *base = g_regions[i].base, *size = g_regions[i].size, *perm = g_regions[i].perm;
    return 1;
}

// Remove [base, base+size) from the map, splitting regions that straddle its edges.
void nx_region_remove(uint64_t base, uint64_t size) {
    uint64_t end = base + size;
    Region keep[256];
    int n = 0;
    for (int i = 0; i < g_nregions; i++) {
        Region r = g_regions[i];
        uint64_t rend = r.base + r.size;
        if (rend <= base || r.base >= end) {
            keep[n++] = r;
            continue;
        }
        if (r.base < base) keep[n++] = (Region){r.base, base - r.base, r.state, r.perm};
        if (rend > end) keep[n++] = (Region){end, rend - end, r.state, r.perm};
    }
    memcpy(g_regions, keep, n * sizeof(Region));
    g_nregions = n;
}

void nx_regions_from_image(void) {
    for (int i = 0; i < g_image.nmod; i++) {
        Module *m = &g_image.mod[i];
        uint64_t b = (uint64_t)m->base;
        nx_region_add(b, m->ro_off, MS_CODE, PERM_RX);
        nx_region_add(b + m->ro_off, m->data_off - m->ro_off, MS_CODE, PERM_R);
        nx_region_add(b + m->data_off, m->size - m->data_off, MS_CODE_DATA, PERM_RW);
    }
}

// MemoryInfo: base, size, state, attr, perm, ipc_refcount, device_refcount, pad
typedef struct { uint64_t base, size; uint32_t state, attr, perm, ipc, dev, pad; } MemoryInfo;

static void query(uint64_t addr, MemoryInfo *mi) {
    memset(mi, 0, sizeof *mi);
    uint64_t free_lo = 0;
    for (int i = 0; i < g_nregions; i++) {
        Region *r = &g_regions[i];
        if (addr < r->base) {                       // in the free gap before r
            mi->base = free_lo;
            mi->size = r->base - free_lo;
            return;
        }
        if (addr < r->base + r->size) {
            mi->base = r->base;
            mi->size = r->size;
            mi->state = r->state;
            mi->perm = r->perm;
            return;
        }
        free_lo = r->base + r->size;
    }
    mi->base = free_lo;                             // free up to the top of the address space
    mi->size = 0 - free_lo;
}

// ---- dispatch ----------------------------------------------------------------------

static const char *const svc_names[0x80] = {
    [0x01] = "SetHeapSize", [0x02] = "SetMemoryPermission", [0x03] = "SetMemoryAttribute",
    [0x04] = "MapMemory", [0x05] = "UnmapMemory", [0x06] = "QueryMemory",
    [0x07] = "ExitProcess", [0x08] = "CreateThread", [0x09] = "StartThread",
    [0x0A] = "ExitThread", [0x0B] = "SleepThread", [0x0C] = "GetThreadPriority",
    [0x0D] = "SetThreadPriority", [0x0E] = "GetThreadCoreMask", [0x0F] = "SetThreadCoreMask",
    [0x10] = "GetCurrentProcessorNumber", [0x11] = "SignalEvent", [0x12] = "ClearEvent",
    [0x13] = "MapSharedMemory", [0x14] = "UnmapSharedMemory", [0x15] = "CreateTransferMemory",
    [0x16] = "CloseHandle", [0x17] = "ResetSignal", [0x18] = "WaitSynchronization",
    [0x19] = "CancelSynchronization", [0x1A] = "ArbitrateLock", [0x1B] = "ArbitrateUnlock",
    [0x1C] = "WaitProcessWideKeyAtomic", [0x1D] = "SignalProcessWideKey",
    [0x1E] = "GetSystemTick", [0x1F] = "ConnectToNamedPort", [0x21] = "SendSyncRequest",
    [0x22] = "SendSyncRequestWithUserBuffer", [0x23] = "SendAsyncRequestWithUserBuffer",
    [0x24] = "GetProcessId", [0x25] = "GetThreadId", [0x26] = "Break",
    [0x27] = "OutputDebugString", [0x28] = "ReturnFromException", [0x29] = "GetInfo",
    [0x2A] = "FlushEntireDataCache", [0x2C] = "MapPhysicalMemory",
    [0x2D] = "UnmapPhysicalMemory", [0x2F] = "GetDebugFutureThreadInfo",
    [0x32] = "SetThreadActivity", [0x33] = "GetThreadContext3", [0x34] = "WaitForAddress",
    [0x35] = "SignalToAddress", [0x36] = "SynchronizePreemptionState",
    [0x40] = "CreateSession", [0x41] = "AcceptSession", [0x43] = "ReplyAndReceive",
    [0x44] = "ReplyAndReceiveWithUserBuffer", [0x45] = "CreateEvent",
    [0x4B] = "CreateCodeMemory", [0x50] = "CreateSharedMemory", [0x51] = "MapTransferMemory",
    [0x52] = "UnmapTransferMemory", [0x70] = "CreatePort", [0x72] = "ConnectToPort",
};

static const char *svc_name(uint64_t n) {
    return n < 0x80 && svc_names[n] ? svc_names[n] : "?";
}

static _Noreturn void unimplemented(uint64_t num, uint64_t *r) {
    nx_log("unimplemented SVC %#llx %s", (unsigned long long)num, svc_name(num));
    for (int i = 0; i < 8; i++) nx_log("  x%d = %#llx", i, (unsigned long long)r[i]);
    nx_fatal("stopping at the first unimplemented SVC");
}

static uint64_t g_count;
static int g_trace = 1;

#include <mach/mach_time.h>
#include <sched.h>
#include <time.h>
#include <unistd.h>

// Switch counter: 19.2 MHz. mach_continuous_time, which keeps counting while the device sleeps, like the counter the
// game's own code reads (its mrs CNTPCT_EL0 -> CNTVCT_EL0 x4/5, nxrecomp spill.py). With mach_absolute_time (stops in
// sleep) the island clock ran ahead by all the phone's sleep since boot (10.8 h in a phone run; equal on the Mac,
// which hadn't slept). NXRT_CLOCK_MACH=1: mach_absolute_time (old).
uint64_t nx_host_time_units(void) {
    static int abs_ = -1;
    if (abs_ < 0) abs_ = getenv("NXRT_CLOCK_MACH") != NULL;
    return abs_ ? mach_absolute_time() : mach_continuous_time();
}
static uint64_t system_tick(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    __uint128_t ns = (__uint128_t)nx_host_time_units() * tb.numer / tb.denom;
    return (uint64_t)(ns * 192 / 10000);
}

static uint64_t get_info(uint32_t id0, uint32_t handle, uint64_t id1, uint32_t *res) {
    *res = 0;
    switch (id0) {
    case 0: return 0xF;                                   // core mask
    case 1: return 0xFFFFFFFFFFFFFFFFull;                 // priority mask
    case 2: return g_as.alias_base;
    case 3: return g_as.alias_size;
    case 4: return g_as.heap_base;
    case 5: return g_as.heap_size;
    case 6: case 0x15: return 0xCD500000;                 // application pool (~3.2 GiB)
    case 7: case 0x16: return g_as.heap_used + g_image.size;
    case 8: return 0;                                     // debugger attached
    case 9: return 0;                                     // resource limit handle
    case 0xA: return 0;                                   // idle tick count
    case 0xB: {                                           // random entropy; NXRT_SEED=<n> makes it repeatable
        static uint64_t seed = 1;
        if (seed == 1) seed = getenv("NXRT_SEED") ? strtoull(getenv("NXRT_SEED"), NULL, 0) | 2 : 0;
        if (!seed) return ((uint64_t)arc4random() << 32) | arc4random();
        seed ^= seed << 13, seed ^= seed >> 7, seed ^= seed << 17;
        return seed;
    }
    case 0xC: return g_as.base;                           // ASLR region
    case 0xD: return g_as.size;
    case 0xE: return g_as.stack_base;
    case 0xF: return g_as.stack_size;
    case 0x10: case 0x11: return 0;                       // system resource size
    case 0x12: return 0x010051F0207B2000ull;              // program id
    case 0x14: {                                          // user exception context (SDK writes +0x1C0)
        static void *ctx;
        if (!ctx) ctx = calloc(1, 0x1000);
        return (uint64_t)ctx;
    }
    case 0x17: return 1;                                  // is application
    case 0x18: return 64;                                 // free thread count
    case 0x19: return system_tick();                      // thread tick count (approx)
    case 0x1C: return 0;                                  // alias region extra size (FW 18+)
    default:
        nx_log("GetInfo(%#x, %#x, %#llx): unknown id", id0, handle, (unsigned long long)id1);
        *res = RES_INVALID_ENUM;
        return 0;
    }
}

uint32_t nx_ipc_connect_named_port(const char *name, uint32_t *out_handle);
uint32_t nx_ipc_send_sync_request(uint32_t handle, uint8_t *msg, size_t size);

#define T(...) do { if (g_trace) nx_log(__VA_ARGS__); } while (0)
#define U64(x) ((unsigned long long)(x))

__thread uint64_t *nx_svc_regs;   // the current SVC's saved guest registers (svc_entry.S: [19] = x29)
static void svc_dispatch(uint64_t num, uint64_t *r);
// SVCs that can block give up the thread's emulated core while they run (cores.c).
void nx_svc_dispatch(uint64_t num, uint64_t *r) {
    switch (num) {
    case 0x0B: case 0x18: case 0x1A: case 0x1C: case 0x21: case 0x22: case 0x34:   // Sleep, WaitSynchronization,
        nx_core_leave();                                                           // ArbitrateLock, cv wait, IPC,
        svc_dispatch(num, r);                                                      // WaitForAddress
        nx_core_enter();
        return;
    default:
        svc_dispatch(num, r);
    }
}
static void svc_dispatch(uint64_t num, uint64_t *r) {
    g_count++;
    nx_svc_regs = r;
    static int all = -1;
    if (all < 0) all = getenv("NXRT_TRACE") != NULL;
    if (all && num != 0x27)
        nx_log("#%llu t%u %s(%#llx, %#llx, %#llx, %#llx)", U64(g_count), nx_current()->id, svc_name(num),
               U64(r[0]), U64(r[1]), U64(r[2]), U64(r[3]));
    uint32_t res = 0;
    switch (num) {
    case 0x01: {  // SetHeapSize(_, size) -> x1 addr
        uint64_t size = r[1];
        if (size > g_as.heap_size || size & 0x1FFFFF) { res = RES_INVALID_SIZE; break; }
        if (size > g_as.heap_used) nx_map_anon(g_as.heap_base + g_as.heap_used, size - g_as.heap_used);
        else if (size < g_as.heap_used) nx_unmap(g_as.heap_base + size, g_as.heap_used - size);
        nx_region_remove(g_as.heap_base, g_as.heap_size);
        if (size) nx_region_add(g_as.heap_base, size, MS_NORMAL, PERM_RW);
        g_as.heap_used = size;
        r[1] = g_as.heap_base;
        T("svc SetHeapSize(%#llx) -> %#llx", U64(size), U64(r[1]));
        break;
    }
    case 0x02: case 0x03:  // SetMemoryPermission / SetMemoryAttribute: not enforced
        T("svc %s(%#llx, %#llx, %#llx) -> ok (not enforced)", svc_name(num), U64(r[0]), U64(r[1]), U64(r[2]));
        break;
    case 0x04: {  // MapMemory(dst, src, size)
        if (nx_alias(r[0], r[1], r[2])) { res = RES_INVALID_ADDRESS; break; }
        nx_region_add(r[0], r[2], MS_STACK, PERM_RW);
        T("svc MapMemory(%#llx <- %#llx, %#llx)", U64(r[0]), U64(r[1]), U64(r[2]));
        break;
    }
    case 0x05:  // UnmapMemory(dst, src, size)
        nx_unalias(r[0], r[1], r[2]);
        nx_region_remove(r[0], r[2]);
        T("svc UnmapMemory(%#llx, %#llx, %#llx)", U64(r[0]), U64(r[1]), U64(r[2]));
        break;
    case 0x06: {  // QueryMemory(MemoryInfo *out, _, addr) -> w1 page info
        MemoryInfo mi;
        query(r[2], &mi);
        memcpy((void *)r[0], &mi, sizeof mi);
        r[1] = 0;
        break;
    }
    case 0x08: {  // CreateThread(_, entry, arg, stack_top, prio, core) -> w1 handle
        uint32_t h;
        uint64_t entry = r[1];
        res = nx_thread_create(r[1], r[2], r[3], (int32_t)r[4], (int32_t)r[5], &h);
        r[1] = h;
        T("svc CreateThread(entry %#llx, arg %#llx, sp %#llx, prio %d, core %d) -> %#x",
          U64(entry), U64(r[2]), U64(r[3]), (int)r[4], (int)r[5], h);
        if (getenv("NXRT_CORELOG")) {
            KObject *o = nx_handle_get(h);
            nx_log("core: CreateThread -> thread %u prio %d core %d (by thread %u)", o && o->type == KO_THREAD ? ((GuestThread *)o->ptr)->id : 0,
                   (int)r[4], (int)r[5], nx_current() ? nx_current()->id : 0);
        }
        break;
    }
    case 0x09: res = nx_thread_start((uint32_t)r[0]); T("svc StartThread(%#x)", (uint32_t)r[0]); break;
    case 0x0A: T("svc ExitThread"); nx_thread_exit();
    case 0x0B: {  // SleepThread(ns): 0, -1, -2 are yields
        int64_t ns = (int64_t)r[0];
        if (ns <= 0) sched_yield();
        else { struct timespec ts = {ns / 1000000000, ns % 1000000000}; nanosleep(&ts, NULL); }
        break;
    }
    case 0x0C: {  // GetThreadPriority(_, handle) -> w1
        KObject *o = nx_handle_get((uint32_t)r[1]);
        if (!o || o->type != KO_THREAD) { res = RES_INVALID_HANDLE; break; }
        r[1] = (uint32_t)((GuestThread *)o->ptr)->priority;
        break;
    }
    case 0x0D: {  // SetThreadPriority(handle, prio)
        KObject *o = nx_handle_get((uint32_t)r[0]);
        if (!o || o->type != KO_THREAD) { res = RES_INVALID_HANDLE; break; }
        ((GuestThread *)o->ptr)->priority = (int32_t)r[1];
        break;
    }
    case 0x0E: {  // GetThreadCoreMask(_, _, handle) -> w1 core, x2 mask
        KObject *o = nx_handle_get((uint32_t)r[2]);
        if (!o || o->type != KO_THREAD) { res = RES_INVALID_HANDLE; break; }
        GuestThread *t = o->ptr;
        r[1] = (uint32_t)t->core;
        r[2] = t->core_mask ? t->core_mask : 1ull << t->core;
        break;
    }
    case 0x0F: {  // SetThreadCoreMask(handle, ideal core, mask). The game pins workers to cores and
                  // keys per-core arenas on GetCurrentProcessorNumber, so the ideal core must be real.
        KObject *o = nx_handle_get((uint32_t)r[0]);
        if (!o || o->type != KO_THREAD) { res = RES_INVALID_HANDLE; break; }
        GuestThread *t = o->ptr;
        int32_t core = (int32_t)r[1];
        uint64_t mask = r[2] & 0xF;
        if (core == -2) { core = 0; mask = 1; }          // IdealCoreUseProcessValue (main thread core 0)
        if (!mask) { res = 0xE801; break; }              // InvalidCombination
        if (core == -3) core = t->core;                  // IdealCoreNoUpdate
        if (core == -1)                                  // IdealCoreDontCare: keep it if still allowed,
            core = mask >> t->core & 1 ? t->core : 63 - __builtin_clzll(mask);   // else highest allowed
        if (core < 0 || core > 3 || !(mask >> core & 1)) { res = 0xE801; break; }
        t->core = core;
        t->core_mask = mask;
        if (t == nx_current()) nx_core_migrate();   // others move when they next take a core
        if (getenv("NXRT_CORELOG")) nx_log("core: thread %u -> core %d mask %#llx", t->id, core, U64(mask));
        break;
    }
    case 0x10: r[0] = (uint32_t)nx_core_current(nx_current()); return;   // GetCurrentProcessorNumber -> w0 (the held core)
    case 0x11: res = nx_event_set((uint32_t)r[0], 1); break;          // SignalEvent
    case 0x12: res = nx_event_set((uint32_t)r[0], 0); break;          // ClearEvent
    case 0x17: res = nx_event_set((uint32_t)r[0], 0); break;          // ResetSignal
    case 0x16:  // CloseHandle
        pthread_mutex_lock(&g_klock);
        if (nx_handle_close((uint32_t)r[0])) res = RES_INVALID_HANDLE;
        pthread_mutex_unlock(&g_klock);
        break;
    case 0x18: {  // WaitSynchronization(_, handles, count, timeout) -> w1 index
        int32_t idx = -1;
        if (all && r[2] >= 1) {
            KObject *ko = nx_handle_get(((uint32_t *)r[1])[0]);
            nx_log("    handles: %#x (type %d%s%u)%s", ((uint32_t *)r[1])[0], ko ? ko->type : -1,
                   ko && ko->type == KO_THREAD ? ", thread t" : ", ", ko && ko->type == KO_THREAD ? ((GuestThread *)ko->ptr)->id : 0,
                   r[2] > 1 ? " ..." : "");
        }
        res = nx_wait_sync((const uint32_t *)r[1], (int)r[2], (int64_t)r[3], &idx);
        r[1] = (uint32_t)idx;
        break;
    }
    case 0x19: nx_thread_cancel_sync((uint32_t)r[0]); break;          // CancelSynchronization
    case 0x1A: res = nx_arbitrate_lock((uint32_t)r[0], r[1], (uint32_t)r[2]); break;
    case 0x1B: res = nx_arbitrate_unlock(r[0]); break;
    case 0x1C: res = nx_cv_wait(r[0], r[1], (uint32_t)r[2], (int64_t)r[3]); break;
    case 0x1D: res = nx_cv_signal(r[0], (int32_t)r[1]); break;
    case 0x1E: r[0] = system_tick(); return;                          // GetSystemTick -> x0
    case 0x1F: {  // ConnectToNamedPort(_, name) -> w1 handle
        uint32_t h = 0;
        const char *name = (const char *)r[1];
        res = nx_ipc_connect_named_port(name, &h);
        r[1] = h;
        T("svc ConnectToNamedPort(\"%.8s\") -> %#x", name, h);
        break;
    }
    case 0x21:  // SendSyncRequest(handle): message in the TLS region
        res = nx_ipc_send_sync_request((uint32_t)r[0], nx_current()->tls_region, 0x100);
        break;
    case 0x22:  // SendSyncRequestWithUserBuffer(buf, size, handle)
        res = nx_ipc_send_sync_request((uint32_t)r[2], (uint8_t *)r[0], r[1]);
        break;
    case 0x24: r[1] = 0x51; break;                                    // GetProcessId -> x1
    case 0x25: {  // GetThreadId(_, handle) -> x1
        KObject *o = nx_handle_get((uint32_t)r[1]);
        if (!o || o->type != KO_THREAD) { res = RES_INVALID_HANDLE; break; }
        r[1] = ((GuestThread *)o->ptr)->id;
        break;
    }
    case 0x26:  // Break(reason, info, size)
        if (r[2] == 4 && r[1]) {
            uint32_t rc = *(uint32_t *)r[1];
            nx_log("guest abort result %#x (module %u, description %u)", rc, rc & 0x1FF, (rc >> 9) & 0x1FFF);
        }
        {   // guest backtrace from the caller's frame records
            extern void nx_backtrace_from(uint64_t fp);
            nx_backtrace_from(((uint64_t *)r)[0x92 / 8 + 0] ? ((uint64_t *)r)[0x98 / 8] : 0);
        }
        nx_fatal("guest svcBreak(reason=%#llx, info=%#llx, size=%#llx) after %llu SVCs",
                 U64(r[0]), U64(r[1]), U64(r[2]), U64(g_count));
    case 0x27:  // OutputDebugString(str, size)
        fprintf(stderr, "[guest] %.*s\n", (int)r[1], (const char *)r[0]);
        break;
    case 0x29: {  // GetInfo(_, id0, handle, id1) -> x1
        r[1] = get_info((uint32_t)r[1], (uint32_t)r[2], r[3], &res);
        break;
    }
    case 0x2C:  // MapPhysicalMemory(addr, size)
        if (nx_map_anon(r[0], r[1])) { res = RES_INVALID_ADDRESS; break; }
        nx_region_add(r[0], r[1], MS_NORMAL, PERM_RW);
        T("svc MapPhysicalMemory(%#llx, %#llx)", U64(r[0]), U64(r[1]));
        break;
    case 0x2D:  // UnmapPhysicalMemory(addr, size)
        nx_unmap(r[0], r[1]);
        nx_region_remove(r[0], r[1]);
        break;
    case 0x13:  // MapSharedMemory(handle, addr, size, perm)
        pthread_mutex_lock(&g_klock);
        res = nx_shmem_map((uint32_t)r[0], r[1], r[2]);
        pthread_mutex_unlock(&g_klock);
        if (!res) nx_region_add(r[1], r[2], 6 /* Shared */, PERM_RW);
        T("svc MapSharedMemory(%#x, %#llx, %#llx) -> %#x", (uint32_t)r[0], U64(r[1]), U64(r[2]), res);
        break;
    case 0x14:  // UnmapSharedMemory(handle, addr, size)
        pthread_mutex_lock(&g_klock);
        res = nx_shmem_unmap((uint32_t)r[0], r[1]);
        pthread_mutex_unlock(&g_klock);
        nx_region_remove(r[1], r[2]);
        break;
    case 0x15: {  // CreateTransferMemory(_, addr, size, perm) -> w1 handle
        KTmem *t = calloc(1, sizeof *t);
        t->addr = r[1];
        t->size = r[2];
        t->perm = (uint32_t)r[3];
        KObject *o = calloc(1, sizeof *o);
        o->type = KO_TMEM;
        o->ptr = t;
        pthread_mutex_lock(&g_klock);
        r[1] = nx_handle_new(o);
        pthread_mutex_unlock(&g_klock);
        T("svc CreateTransferMemory(%#llx, %#llx, perm %u) -> %#llx", U64(t->addr), U64(t->size), t->perm, U64(r[1]));
        break;
    }
    case 0x34: res = nx_wait_for_address(r[0], (uint32_t)r[1], (int32_t)r[2], (int64_t)r[3]); break;
    case 0x35: res = nx_signal_to_address(r[0], (uint32_t)r[1], (int32_t)r[2], (int32_t)r[3]); break;
    case 0x36: nx_core_sync_preemption(); break;          // SynchronizePreemptionState (cores.c)
    case 0x45: {  // CreateEvent -> w1 write handle, w2 read handle
        uint32_t w, rd;
        pthread_mutex_lock(&g_klock);
        nx_event_create(&w, &rd);
        pthread_mutex_unlock(&g_klock);
        r[1] = w;
        r[2] = rd;
        break;
    }
    default:
        unimplemented(num, r);
    }
    if (all && res) nx_log("    -> result %#x", res);
    r[0] = res;
}
