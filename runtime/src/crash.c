// Crash reporting: faulting address, PC/LR as module+offset, registers.
#include <dlfcn.h>
#include <mach/mach.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ucontext.h>
#include <time.h>
#include <unistd.h>

#include "nxrt.h"

#include <execinfo.h>
void nx_crash_marker_write(void);   // app_online.m: .crashed, so the next launch offers to send a report
static void on_abort(int sig) {
    nx_crash_marker_write();
    void *frames[48];
    int n = backtrace(frames, 48);
    fprintf(stderr, "\n*** SIGABRT, host backtrace:\n");
    backtrace_symbols_fd(frames, n, 2);
    signal(SIGABRT, SIG_DFL);
    abort();
}

static void where(char *out, size_t n, uint64_t addr) {
    for (int i = 0; i < g_image.nmod; i++) {
        Module *m = &g_image.mod[i];
        if (addr >= (uint64_t)m->base && addr < (uint64_t)m->base + m->size) {
            snprintf(out, n, "%s+%#llx", m->name, (unsigned long long)(addr - (uint64_t)m->base));
            return;
        }
    }
    Dl_info di;   // host code: symbol+offset (crash-time only, so dladdr's cost doesn't matter)
    if (dladdr((void *)addr, &di) && di.dli_sname) {
        snprintf(out, n, "%#llx (%s+%#llx)", (unsigned long long)addr, di.dli_sname,
                 (unsigned long long)(addr - (uint64_t)di.dli_saddr));
        return;
    }
    snprintf(out, n, "%#llx", (unsigned long long)addr);
}

// NXRT_WATCH=<hex addr>: write-watch an address (page protection, re-armed every 1 ms).
static uint64_t g_watch, g_watch_page;
static volatile int g_watch_armed;
#include <pthread.h>
#include <sys/mman.h>
static void *watch_rearm(void *arg) {
    for (;;) {
        usleep(1000);
        if (g_watch_page) {                   // unconditional: remaps (MAP_FIXED) drop protection
            g_watch_armed = 1;
            mprotect((void *)g_watch_page, 0x4000, getenv("NXRT_WATCH_READ") ? PROT_NONE : PROT_READ);
        }
    }
    return NULL;
}
// NXRT_OBJWATCH=1: log every distinct (guest PC, field offset) that touches a registered NVN object.
// Our runtime never reads or writes these objects (state is keyed by address), so every access is
// the game reading or writing the real driver's private fields.
static struct { uint64_t base, size; const char *label; } g_objs[256];
static int g_nobjs;
static pthread_mutex_t g_obj_lock = PTHREAD_MUTEX_INITIALIZER;
void nx_watch_object(const void *p, uint64_t size, const char *label) {
    if (!getenv("NXRT_OBJWATCH")) return;
    pthread_mutex_lock(&g_obj_lock);
    int dup = 0;
    for (int i = 0; i < g_nobjs; i++) dup |= g_objs[i].base == (uint64_t)p;
    if (!dup && g_nobjs < 256) g_objs[g_nobjs++] = (typeof(g_objs[0])){(uint64_t)p, size, label};
    pthread_mutex_unlock(&g_obj_lock);
}
static void *obj_rearm(void *arg) {
    for (;;) {
        usleep(2000);
        for (int i = 0; i < g_nobjs; i++) {
            uint64_t a = g_objs[i].base & ~0x3FFFull, b = (g_objs[i].base + g_objs[i].size + 0x3FFF) & ~0x3FFFull;
            mprotect((void *)a, b - a, PROT_NONE);
        }
    }
    return NULL;
}
static int obj_fault(_STRUCT_ARM_THREAD_STATE64 *ss, uint64_t fa) {
    int hit = -1, page = 0;
    for (int i = 0; i < g_nobjs; i++) {
        if (fa >= g_objs[i].base && fa < g_objs[i].base + g_objs[i].size) hit = i;
        uint64_t a = g_objs[i].base & ~0x3FFFull, b = (g_objs[i].base + g_objs[i].size + 0x3FFF) & ~0x3FFFull;
        if (fa >= a && fa < b) page = 1;
    }
    if (!page) return 0;
    if (hit >= 0) {
        static struct { uint64_t pc; uint32_t off; } seen[512];
        static int nseen;
        uint64_t pcv = (uint64_t)__darwin_arm_thread_state64_get_pc(*ss);
        uint32_t off = (uint32_t)(fa - g_objs[hit].base);
        int k = 0;
        while (k < nseen && !(seen[k].pc == pcv && seen[k].off == off)) k++;
        if (k == nseen && nseen < 512) {
            seen[nseen].pc = pcv, seen[nseen++].off = off;
            char pcs[64];
            where(pcs, sizeof pcs, pcv);
            fprintf(stderr, "objwatch: %s +%#x touched by %s (insn %08x)\n", g_objs[hit].label, off, pcs, *(uint32_t *)pcv);
        }
    }
    uint64_t pg = fa & ~0x3FFFull;
    mprotect((void *)pg, 0x4000, PROT_READ | PROT_WRITE);
    return 1;
}

// NXRT_PEEKLOOP=<hex addr>:<len>: print guest memory every second (to watch a heap fill up).
static void *peek_loop(void *arg) {
    const char *p = getenv("NXRT_PEEKLOOP");
    uint64_t a = strtoull(p, NULL, 16) & ~7ull, n = strchr(p, ':') ? strtoull(strchr(p, ':') + 1, NULL, 0) : 0x40;
    for (int t = 0;; t++) {
        sleep(1);
        char line[1024];
        int o = snprintf(line, sizeof line, "peekloop t=%ds:", t + 1);
        for (uint64_t i = 0; i < n && o < (int)sizeof line - 20; i += 8)
            o += snprintf(line + o, sizeof line - o, " %llx", (unsigned long long)*(volatile uint64_t *)(a + i));
        fprintf(stderr, "%s\n", line);
    }
    return NULL;
}

// Arms (addr != 0) or disarms the write watch at run time (recon probes: watch only around one input).
void nx_watch_set(uint64_t addr) {
    static int started;
    if (!addr) {
        uint64_t pg = g_watch_page;
        g_watch_page = 0;
        if (pg) usleep(3000), mprotect((void *)pg, 0x4000, PROT_READ | PROT_WRITE);
        return;
    }
    g_watch = addr, g_watch_page = addr & ~0x3FFFull;
    if (!started) {
        started = 1;
        pthread_t t;
        pthread_create(&t, NULL, watch_rearm, NULL);
    }
    nx_log("watch: write-watching %#llx", (unsigned long long)addr);
}
void nx_watch_init(void) {
    if (getenv("NXRT_OBJWATCH")) {
        pthread_t ot;
        pthread_create(&ot, NULL, obj_rearm, NULL);
    }
    if (getenv("NXRT_PEEKLOOP")) {
        pthread_t pt;
        pthread_create(&pt, NULL, peek_loop, NULL);
    }
    const char *w = getenv("NXRT_WATCH");
    if (!w) return;
    g_watch = strtoull(w, NULL, 16);
    g_watch_page = g_watch & ~0x3FFFull;
    pthread_t t;
    pthread_create(&t, NULL, watch_rearm, NULL);
    nx_log("watch: write-watching %#llx", (unsigned long long)g_watch);
}

// Emulate one integer store at pc (for the precise write watch). Returns 1 if done.
static uint64_t reg(_STRUCT_ARM_THREAD_STATE64 *ss, int r, int sp_ok) {
    if (r == 31) return sp_ok ? ss->__sp : 0;
    if (r == 29) return ss->__fp;
    if (r == 30) return ss->__lr;
    return ss->__x[r];
}
static void set_reg(_STRUCT_ARM_THREAD_STATE64 *ss, int r, uint64_t v) {
    if (r == 31) ss->__sp = v; else if (r == 29) ss->__fp = v; else if (r == 30) ss->__lr = v; else ss->__x[r] = v;
}
static int emulate_store(_STRUCT_ARM_THREAD_STATE64 *ss, uint32_t w, uint64_t *addr, uint64_t *val, int *size) {
    int rt = w & 31, rn = (w >> 5) & 31;
    if ((w & 0x3B000000) == 0x39000000 && !((w >> 22) & 3)) {          // STR imm unsigned offset
        int sz = 1 << (w >> 30);
        uint64_t a = reg(ss, rn, 1) + ((w >> 10) & 0xFFF) * sz;
        uint64_t v = reg(ss, rt, 0);
        memcpy((void *)a, &v, sz);
        *addr = a; *val = v; *size = sz;
        return 1;
    }
    if ((w & 0x3B200000) == 0x38000000 && !((w >> 22) & 3)) {          // STUR / STR pre/post
        int sz = 1 << (w >> 30), mode = (w >> 10) & 3;
        int64_t imm = (int64_t)((w >> 12) & 0x1FF) << 55 >> 55;
        uint64_t b = reg(ss, rn, 1), a = mode == 1 ? b : b + imm;       // 1 = post-index
        uint64_t v = reg(ss, rt, 0);
        memcpy((void *)a, &v, sz);
        if (mode == 1 || mode == 3) set_reg(ss, rn, b + imm);
        *addr = a; *val = v; *size = sz;
        return 1;
    }
    if ((w & 0x3B200C00) == 0x38200800 && !((w >> 22) & 3)) {          // STR register offset
        int sz = 1 << (w >> 30), rm = (w >> 16) & 31, opt = (w >> 13) & 7, S = (w >> 12) & 1;
        uint64_t off = reg(ss, rm, 0);
        if (opt == 2) off = (uint32_t)off; else if (opt == 6) off = (uint64_t)(int64_t)(int32_t)off;
        if (S) off <<= (w >> 30);
        uint64_t a = reg(ss, rn, 1) + off, v = reg(ss, rt, 0);
        memcpy((void *)a, &v, sz);
        *addr = a; *val = v; *size = sz;
        return 1;
    }
    if ((w & 0x7C400000) == 0x28000000 && (w >> 30) != 1) {          // STP (32/64), not SIMD
        int sz = (w >> 31) ? 8 : 4, mode = (w >> 23) & 3, rt2 = (w >> 10) & 31;
        int64_t imm = ((int64_t)((w >> 15) & 0x7F) << 57 >> 57) * sz;
        uint64_t b = reg(ss, rn, 1), a = mode == 1 ? b : b + imm;
        uint64_t v1 = reg(ss, rt, 0), v2 = reg(ss, rt2, 0);
        memcpy((void *)a, &v1, sz);
        memcpy((void *)(a + sz), &v2, sz);
        if (mode == 1 || mode == 3) set_reg(ss, rn, b + imm);
        *addr = a; *val = v1; *size = 2 * sz;
        return 1;
    }
    return 0;
}

// At a crash: every other thread that has guest code on its stack, suspended, with PC/LR, x0/x19 and its
// frame records (what was the rest of the game doing at that moment? races between game threads).
static int in_guest(uint64_t a) {
    for (int i = 0; i < g_image.nmod; i++)
        if (a >= (uint64_t)g_image.mod[i].base && a < (uint64_t)g_image.mod[i].base + g_image.mod[i].size) return 1;
    return 0;
}
static void other_threads(void) {
    thread_act_array_t list;
    mach_msg_type_number_t n;
    if (task_threads(mach_task_self(), &list, &n) != KERN_SUCCESS) return;
    thread_t self = mach_thread_self();
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        if (list[i] == self || thread_suspend(list[i]) != KERN_SUCCESS) continue;
        arm_thread_state64_t st;
        mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(list[i], ARM_THREAD_STATE64, (thread_state_t)&st, &cnt) != KERN_SUCCESS) continue;
        uint64_t pc = arm_thread_state64_get_pc(st), lr = arm_thread_state64_get_lr(st), fp = arm_thread_state64_get_fp(st);
        uint64_t ret[16];
        int nr = 0;
        int guest = in_guest(pc) || in_guest(lr);
        for (int k = 0; k < 16 && fp && !(fp & 7); k++) {
            uint64_t *rec = (uint64_t *)fp;
            if (!rec[1]) break;
            ret[nr++] = rec[1];
            guest |= in_guest(rec[1]);
            if (rec[0] <= fp) break;
            fp = rec[0];
        }
        if (!guest) continue;
        char w1[64], w2[64];
        where(w1, sizeof w1, pc), where(w2, sizeof w2, lr);
        fprintf(stderr, "  other thread %u: pc %s lr %s x0 %#llx x19 %#llx\n", (unsigned)list[i], w1, w2,
                (unsigned long long)st.__x[0], (unsigned long long)st.__x[19]);
        for (int k = 0; k < nr; k++) {
            where(w1, sizeof w1, ret[k]);
            fprintf(stderr, "      #%-2d %s\n", k, w1);
        }
    }
}
static void on_crash(int sig, siginfo_t *si, void *uc_) {
    ucontext_t *uc = uc_;
    _STRUCT_ARM_THREAD_STATE64 *ss = &uc->uc_mcontext->__ss;
    uint64_t fa = (uint64_t)si->si_addr;
    int gfx_wp_fault(uintptr_t a);
    if ((sig == SIGSEGV || sig == SIGBUS) && gfx_wp_fault((uintptr_t)fa)) return;   // write-tracked texture storage
    nx_crash_marker_write();
    if (g_nobjs && (sig == SIGSEGV || sig == SIGBUS) && obj_fault(ss, fa)) return;
    // NXRT_WATCH_READ=1: the page is fully protected; log each distinct PC that touches it, then open
    // the page until the re-arm thread protects it again (1 ms).
    if (g_watch_page && getenv("NXRT_WATCH_READ") && (sig == SIGSEGV || sig == SIGBUS) && fa >= g_watch_page &&
        fa < g_watch_page + 0x4000) {
        static uint64_t seen[64];
        static int nseen;
        uint64_t pcv = (uint64_t)__darwin_arm_thread_state64_get_pc(*ss);
        int k = 0;
        while (k < nseen && seen[k] != pcv) k++;
        if (k == nseen && nseen < 64) {
            seen[nseen++] = pcv;
            char pcs[64], lrs[64];
            where(pcs, sizeof pcs, pcv);
            where(lrs, sizeof lrs, (uint64_t)__darwin_arm_thread_state64_get_lr(*ss));
            GuestThread *t = nx_current();
            fprintf(stderr, "watch: access %#llx by %s (lr %s) thread %u\n", (unsigned long long)fa, pcs, lrs, t ? t->id : 0);
        }
        mprotect((void *)g_watch_page, 0x4000, PROT_READ | PROT_WRITE);
        return;
    }
    if (g_watch_page && getenv("NXRT_WATCH_EXACT") && (sig == SIGSEGV || sig == SIGBUS) && fa >= g_watch_page &&
        fa < g_watch_page + 0x4000) {
        uint64_t pcv = (uint64_t)__darwin_arm_thread_state64_get_pc(*ss), a, v;
        int sz;
        mprotect((void *)g_watch_page, 0x4000, PROT_READ | PROT_WRITE);
        int ok = emulate_store(ss, *(uint32_t *)pcv, &a, &v, &sz);
        mprotect((void *)g_watch_page, 0x4000, PROT_READ);
        if (ok) {
            if (a < g_watch + 8 && a + sz > g_watch) {
                char pcs[64];
                where(pcs, sizeof pcs, pcv);
                GuestThread *t = nx_current();
                fprintf(stderr, "watch: %s (thread %u) wrote %#llx (%d bytes) at %#llx\n", pcs, t ? t->id : 0,
                        (unsigned long long)v, sz, (unsigned long long)a);
                char lrs[64];
                where(lrs, sizeof lrs, (uint64_t)__darwin_arm_thread_state64_get_lr(*ss));
                fprintf(stderr, "        lr %s\n", lrs);
                uint64_t fp = ss->__fp;
                for (int i = 0; i < 8 && fp && !(fp & 7); i++) {
                    uint64_t *rec = (uint64_t *)fp;
                    where(lrs, sizeof lrs, rec[1]);
                    fprintf(stderr, "        #%d %s\n", i, lrs);
                    if (rec[0] <= fp) break;
                    fp = rec[0];
                }
            }
            __darwin_arm_thread_state64_set_pc_fptr(*ss, (void *)(pcv + 4));
            return;
        }
        // not an integer store we emulate: fall through to the window method below
    }
    if (g_watch_page && (sig == SIGSEGV || sig == SIGBUS) && fa >= g_watch_page && fa < g_watch_page + 0x4000) {
        static int page_hits;
        if (getenv("NXRT_WATCH_PAGE") && page_hits++ < 60) {
            char pcs[64];
            where(pcs, sizeof pcs, (uint64_t)__darwin_arm_thread_state64_get_pc(*ss));
            fprintf(stderr, "watch: page write at %#llx by %s\n", (unsigned long long)fa, pcs);
        }
        static int span = -1;   // NXRT_WATCH_SPAN=<bytes>: report writes this far around the address (default 16)
        if (span < 0) span = getenv("NXRT_WATCH_SPAN") ? atoi(getenv("NXRT_WATCH_SPAN")) : 16;
        if (fa + span > g_watch && fa < g_watch + span) {
            char pc[64], lr[64];
            where(pc, sizeof pc, (uint64_t)__darwin_arm_thread_state64_get_pc(*ss));
            where(lr, sizeof lr, (uint64_t)__darwin_arm_thread_state64_get_lr(*ss));
            GuestThread *t = nx_current();
            fprintf(stderr, "watch: write to %#llx by %s (lr %s) thread %u, old value %#llx\n", (unsigned long long)fa, pc,
                    lr, t ? t->id : 0, (unsigned long long)*(uint64_t *)g_watch);
            uint64_t fp = ss->__fp;
            for (int i = 0; i < 6 && fp && !(fp & 7); i++) {
                uint64_t *rec = (uint64_t *)fp;
                char w[64];
                where(w, sizeof w, rec[1]);
                fprintf(stderr, "        #%d %s\n", i, w);
                if (rec[0] <= fp) break;
                fp = rec[0];
            }
        }
        g_watch_armed = 0;
        mprotect((void *)g_watch_page, 0x4000, PROT_READ | PROT_WRITE);
        return;                                              // retry the write
    }
    char pc[64], lr[64];
    where(pc, sizeof pc, (uint64_t)__darwin_arm_thread_state64_get_pc(*ss));
    where(lr, sizeof lr, (uint64_t)__darwin_arm_thread_state64_get_lr(*ss));
    GuestThread *t = nx_current();
    fprintf(stderr, "\n*** signal %d (%s) at %s, fault address %p, thread %u\n", sig, strsignal(sig), pc,
            si->si_addr, t ? t->id : 0);
    fprintf(stderr, "    lr = %s, sp = %#llx\n", lr, (unsigned long long)__darwin_arm_thread_state64_get_sp(*ss));
    for (int i = 0; i < 29; i += 4)
        fprintf(stderr, "    x%-2d %016llx  x%-2d %016llx  x%-2d %016llx  x%-2d %016llx\n", i,
                (unsigned long long)ss->__x[i], i + 1, (unsigned long long)ss->__x[i + 1], i + 2,
                (unsigned long long)ss->__x[i + 2], i + 3, (unsigned long long)(i + 3 < 29 ? ss->__x[i + 3] : 0));
    // NXRT_DUMP=x19: dump the object a register points to, and its vtable
    const char *dump = getenv("NXRT_DUMP");
    if (dump && dump[0] == 'x') {
        int r = atoi(dump + 1);
        uint64_t obj = r >= 0 && r < 29 ? ss->__x[r] : 0;
        fprintf(stderr, "    dump x%d = %#llx\n", r, (unsigned long long)obj);
        if (obj > 0x100000000ull && !(obj & 7)) {
            uint64_t *o = (uint64_t *)obj;
            for (int i = 0; i < 6; i++) { char w[64]; where(w, sizeof w, o[i]); fprintf(stderr, "      +%#x: %s\n", i * 8, w); }
            uint64_t vt = o[0];
            if (vt > 0x100000000ull && !(vt & 7))
                for (int i = 0; i < 16; i++) { char w[64]; where(w, sizeof w, ((uint64_t *)vt)[i]); fprintf(stderr, "      vt[%#x]: %s\n", i * 8, w); }
        }
    }
    // NXRT_HEX=x20:0x600: hex-dump that many bytes from where a register points
    const char *hex = getenv("NXRT_HEX");
    if (hex && hex[0] == 'x') {
        int r = atoi(hex + 1);
        const char *c = strchr(hex, ':');
        uint64_t n = c ? strtoull(c + 1, NULL, 0) : 0x100;
        uint64_t p = r >= 0 && r < 29 ? ss->__x[r] & ~7ull : 0;
        fprintf(stderr, "    hex x%d = %#llx\n", r, (unsigned long long)p);
        for (uint64_t i = 0; p > 0x100000000ull && i < n; i += 16)
            fprintf(stderr, "      +%05llx: %016llx %016llx\n", (unsigned long long)i,
                    (unsigned long long)((uint64_t *)(p + i))[0], (unsigned long long)((uint64_t *)(p + i))[1]);
    }
    // NXRT_PEEK=<hex addr>:<len>: hex-dump guest memory at a fixed address (guest heap addresses
    // repeat from run to run)
    const char *peek = getenv("NXRT_PEEK");
    if (peek) {
        uint64_t a = strtoull(peek, NULL, 16) & ~7ull, n = strchr(peek, ':') ? strtoull(strchr(peek, ':') + 1, NULL, 0) : 0x80;
        fprintf(stderr, "    peek %#llx:\n", (unsigned long long)a);
        for (uint64_t i = 0; i < n; i += 16)
            fprintf(stderr, "      +%04llx: %016llx %016llx\n", (unsigned long long)i, (unsigned long long)((uint64_t *)(a + i))[0],
                    (unsigned long long)((uint64_t *)(a + i))[1]);
    }
    // NXRT_PEEK_STR=<hex addr>: print the C string whose pointer is stored at that address
    const char *ps = getenv("NXRT_PEEK_STR");
    if (ps) {
        const char *str = *(const char **)(strtoull(ps, NULL, 16) & ~7ull);
        fprintf(stderr, "    peek string: \"%.120s\"\n", str ? str : "(null)");
    }
    // frame-pointer backtrace (guest code keeps x29 frame records)
    uint64_t fp = ss->__fp;
    for (int i = 0; i < 24 && fp && !(fp & 7); i++) {
        uint64_t *rec = (uint64_t *)fp;
        uint64_t ret = rec[1];
        if (!ret) break;
        char w[64];
        where(w, sizeof w, ret);
        fprintf(stderr, "    #%-2d %s\n", i, w);
        if (rec[0] <= fp) break;
        fp = rec[0];
    }
    if (nx_current()) fprintf(stderr, "    crashing guest thread %u on core %d\n", nx_current()->id, nx_current()->core);
    other_threads();
    _exit(128 + sig);
}

// NXRT_PCDUMP=<seconds>: every so often, log the pc and lr of every thread that is inside game code, as module+offset
// (finds where the game spins; `sample` can't attach reliably and the image moves between runs).
static const char *guest_where(uint64_t a, char *buf, size_t n) {
    for (int i = 0; i < g_image.nmod; i++) {
        const Module *m = &g_image.mod[i];
        if (a >= (uint64_t)m->base && a < (uint64_t)m->base + m->size) {
            snprintf(buf, n, "%s+%#llx", m->name, (unsigned long long)(a - (uint64_t)m->base));
            return buf;
        }
    }
    return NULL;
}
static void *pcdump_thread(void *arg) {
    int every = (int)(intptr_t)arg;
    for (;;) {
        sleep((unsigned)every);
        thread_act_array_t th;
        mach_msg_type_number_t n;
        if (task_threads(mach_task_self(), &th, &n) != KERN_SUCCESS) continue;
        thread_t self = mach_thread_self();
        for (mach_msg_type_number_t i = 0; i < n; i++) {
            if (th[i] != self && thread_suspend(th[i]) == KERN_SUCCESS) {
                arm_thread_state64_t st;
                mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
                if (thread_get_state(th[i], ARM_THREAD_STATE64, (thread_state_t)&st, &cnt) == KERN_SUCCESS) {
                    char a[64], b[64];
                    uint64_t pc = arm_thread_state64_get_pc(st), lr = arm_thread_state64_get_lr(st);
                    const char *wp = guest_where(pc, a, sizeof a), *wl = guest_where(lr, b, sizeof b);
                    if (wp) nx_log("pcdump: thread %u pc %s lr %s x0 %#llx x1 %#llx x8 %#llx", i, wp, wl ? wl : "host",
                                   (unsigned long long)st.__x[0], (unsigned long long)st.__x[1], (unsigned long long)st.__x[8]);
                }
                thread_resume(th[i]);
            }
            mach_port_deallocate(mach_task_self(), th[i]);
        }
        mach_port_deallocate(mach_task_self(), self);
        vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof(thread_t));
    }
    return NULL;
}

// Freeze watchdog (NXRT_WATCHDOG=<seconds>, default 5, 0 = off): when no frame has been presented for that long
// (after the first frame, app in the foreground), log every thread: guest id/priority/core, registers and a
// frame-pointer backtrace (guest code as module+offset, host code as image+offset for atos against the dSYM), then
// the emulated cores' owners/waiters and the GPU queue. Again after 4x as long: the same pcs = a deadlock, moving
// pcs = a spin. Threads are suspended only while their registers and stack records are copied (no locks, no
// malloc), and stack reads go through vm_read_overwrite, so a bad frame pointer can't fault the watchdog.
extern volatile int g_gfx_frame, g_gfx_background;
static void wd_where(char *out, size_t n, uint64_t a) {
    if (guest_where(a, out, n)) return;
    Dl_info di;
    if (a && dladdr((void *)a, &di) && di.dli_fname) {
        const char *f = strrchr(di.dli_fname, '/') ? strrchr(di.dli_fname, '/') + 1 : di.dli_fname;
        if (di.dli_sname)
            snprintf(out, n, "%s+%#llx (%s+%#llx)", f, (unsigned long long)(a - (uint64_t)di.dli_fbase), di.dli_sname,
                     (unsigned long long)(a - (uint64_t)di.dli_saddr));
        else snprintf(out, n, "%s+%#llx", f, (unsigned long long)(a - (uint64_t)di.dli_fbase));
        return;
    }
    snprintf(out, n, "%#llx", (unsigned long long)a);
}
typedef struct {
    thread_t th;
    uint64_t pc, lr, sp, x0, x1, nret, ret[24];
} WdSnap;
static void watchdog_dump(int pass, double secs) {
    static WdSnap s[512];
    thread_act_array_t list;
    mach_msg_type_number_t n;
    if (task_threads(mach_task_self(), &list, &n) != KERN_SUCCESS) return;
    thread_t self = mach_thread_self();
    int ns = 0;
    for (mach_msg_type_number_t i = 0; i < n && ns < 512; i++) {
        if (list[i] == self || thread_suspend(list[i]) != KERN_SUCCESS) continue;
        arm_thread_state64_t st;
        mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(list[i], ARM_THREAD_STATE64, (thread_state_t)&st, &cnt) == KERN_SUCCESS) {
            WdSnap *w = &s[ns++];
            w->th = list[i], w->pc = arm_thread_state64_get_pc(st), w->lr = arm_thread_state64_get_lr(st);
            w->sp = arm_thread_state64_get_sp(st), w->x0 = st.__x[0], w->x1 = st.__x[1], w->nret = 0;
            uint64_t fp = arm_thread_state64_get_fp(st);
            int switches = 0;   // the chain may cross from the host stack to the guest stack once (SVC entry)
            for (int k = 0; k < 24 && fp && !(fp & 7); k++) {
                uint64_t rec[2];
                vm_size_t got = 0;
                if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp, sizeof rec, (vm_address_t)rec, &got) != KERN_SUCCESS ||
                    got != sizeof rec || !rec[1])
                    break;
                w->ret[w->nret++] = rec[1];
                if (rec[0] <= fp && switches++) break;
                fp = rec[0];
            }
        }
        thread_resume(list[i]);
    }
    nx_log("watchdog: no frame presented for %.0f s (frame %d), dump %d: %d threads", secs, g_gfx_frame, pass, ns);
    for (int i = 0; i < ns; i++) {
        WdSnap *w = &s[i];
        char name[64] = "", a[96], b[96], who[96] = "host";
        pthread_t p = pthread_from_mach_thread_np(w->th);
        if (p) pthread_getname_np(p, name, sizeof name);
        GuestThread *g = p ? nx_thread_by_host(p) : NULL;
        if (g)
            snprintf(who, sizeof who, "guest %u prio %d core %d holds %d%s", g->id, g->priority, g->core, g->run_core,
                     g->exited ? " exited" : "");
        wd_where(a, sizeof a, w->pc), wd_where(b, sizeof b, w->lr);
        nx_log("watchdog: thread %u '%s' %s: pc %s lr %s sp %#llx x0 %#llx x1 %#llx", (unsigned)w->th, name, who, a, b,
               (unsigned long long)w->sp, (unsigned long long)w->x0, (unsigned long long)w->x1);
        for (uint64_t k = 0; k < w->nret; k++) {
            wd_where(a, sizeof a, w->ret[k]);
            nx_log("watchdog:     #%-2llu %s", (unsigned long long)k, a);
        }
    }
    for (mach_msg_type_number_t i = 0; i < n; i++) mach_port_deallocate(mach_task_self(), list[i]);
    mach_port_deallocate(mach_task_self(), self);
    vm_deallocate(mach_task_self(), (vm_address_t)list, n * sizeof(thread_t));
    void nx_cores_dump(void), gfx_watchdog_dump(void);
    nx_cores_dump();
    gfx_watchdog_dump();
}
static void *watchdog_thread(void *arg) {
    int limit = 0, last = -1, dumps = 0;
    uint64_t since = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    pthread_setname_np("nxrt watchdog");
    for (;;) {
        sleep(1);
        int f = g_gfx_frame;
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (f && !limit) {   // read at the first frame: iOS sets env.txt values after the handlers are installed
            limit = getenv("NXRT_WATCHDOG") ? atoi(getenv("NXRT_WATCHDOG")) : 5;
            if (limit <= 0) return NULL;
        }
        if (f != last || !f || g_gfx_background) {
            if (dumps && f != last) nx_log("watchdog: frames resumed (frame %d) after %.1f s", f, (now - since) / 1e9);
            last = f, since = now, dumps = 0;
            continue;
        }
        double secs = (now - since) / 1e9;
        if (dumps < 2 && secs >= (dumps ? 4.0 : 1.0) * limit) watchdog_dump(++dumps, secs);
    }
    return NULL;
}

void nx_crash_handler_install(void) {
    {
        pthread_t t;
        pthread_create(&t, NULL, watchdog_thread, NULL);
    }
    if (getenv("NXRT_PCDUMP")) {
        pthread_t t;
        pthread_create(&t, NULL, pcdump_thread, (void *)(intptr_t)(atoi(getenv("NXRT_PCDUMP")) > 0 ? atoi(getenv("NXRT_PCDUMP")) : 5));
    }
    stack_t alt = {.ss_sp = malloc(1 << 16), .ss_size = 1 << 16};
    sigaltstack(&alt, NULL);
    struct sigaction sa = {0};
    sa.sa_sigaction = on_crash;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
    // SIGABRT (malloc errors, uncaught exceptions): host backtrace only, then the default action.
    signal(SIGABRT, on_abort);
}

// Each new host thread needs its own alternate signal stack.
void nx_crash_thread_init(void) {
    stack_t alt = {.ss_sp = malloc(1 << 16), .ss_size = 1 << 16};
    sigaltstack(&alt, NULL);
}

void nx_backtrace_from(uint64_t fp) {
    for (int i = 0; i < 24 && fp && !(fp & 7); i++) {
        uint64_t *rec = (uint64_t *)fp;
        uint64_t ret = rec[1];
        if (!ret) break;
        char w[64];
        where(w, sizeof w, ret);
        fprintf(stderr, "    #%-2d %s\n", i, w);
        if (rec[0] <= fp) break;
        fp = rec[0];
    }
}
