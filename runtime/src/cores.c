// Emulated CPU cores: at most one guest thread runs per core, as on Horizon.
//
// Every guest thread is a host thread, so without this two threads pinned to the same core ran in
// parallel. The game keys per-core data on GetCurrentProcessorNumber and relies on same-core threads
// never overlapping: the SDK font-engine state per core (two core-0 threads shared it and crashed in
// FSS_* during load), per-core arenas, ...
//
// A thread owns its core while it runs guest code. It gives the core up in blocking SVCs and long host
// calls (nx_core_leave / nx_core_enter) and takes it back afterwards. A free core goes to the
// highest-priority waiter (lowest number; ties first come). A thread that becomes ready only takes the
// core ahead of waiters if it has strictly higher priority, and it preempts a running lower-priority
// owner: SIGUSR2 to the owner, whose handler gives the core up if it was interrupted in guest code
// (Horizon preempts at any instruction). In host code the owner reaches a release point soon; the
// waiter re-signals every millisecond until then.
//
// NXRT_NOCORES=1: off (threads run freely, as before).
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ucontext.h>
#include <time.h>

#include "nxrt.h"

enum { NCORES = 4, MAXWAIT = 256 };
typedef struct {
    pthread_mutex_t m;
    pthread_cond_t cv;
    GuestThread *owner;
    int nwait;
    GuestThread *wait[MAXWAIT];
    uint64_t seq[MAXWAIT];
} Core;
static Core g_cores[NCORES];
static uint64_t g_seq;
static int g_on = -1;
static uint64_t g_preempts, g_preempt_misses, g_preempt_deferred;

int nx_cores_on(void) {
    if (g_on < 0) {
        g_on = !getenv("NXRT_NOCORES");
        for (int i = 0; i < NCORES; i++) pthread_mutex_init(&g_cores[i].m, NULL), pthread_cond_init(&g_cores[i].cv, NULL);
        if (g_on) {
            void nx_cores_signal_init(void);
            nx_cores_signal_init();
        }
        nx_log("cores: %s", g_on ? "one running guest thread per emulated core" : "off (NXRT_NOCORES)");
    }
    return g_on;
}

static int core_of(const GuestThread *t) { return t->core >= 0 && t->core < NCORES ? t->core : 0; }

// The waiter that runs next: lowest priority number, then earliest arrival. -1 if none.
static int best_waiter(const Core *c) {
    int b = -1;
    for (int i = 0; i < c->nwait; i++)
        if (b < 0 || c->wait[i]->priority < c->wait[b]->priority ||
            (c->wait[i]->priority == c->wait[b]->priority && c->seq[i] < c->seq[b]))
            b = i;
    return b;
}

static void acquire(GuestThread *t) {
    int k = core_of(t);
    Core *c = &g_cores[k];
    pthread_mutex_lock(&c->m);
    int b = best_waiter(c);
    if (!c->owner && (b < 0 || t->priority < c->wait[b]->priority)) {
        c->owner = t;
        t->run_core = k;
        pthread_mutex_unlock(&c->m);
        return;
    }
    if (c->nwait == MAXWAIT) nx_fatal("cores: more than %d threads waiting for core %d", MAXWAIT, k);
    int me = c->nwait++;
    c->wait[me] = t, c->seq[me] = ++g_seq;
    for (;;) {
        if (!c->owner) {
            b = best_waiter(c);
            if (c->wait[b] == t) break;
        } else if (c->owner->priority > t->priority) {
            // Preempt a lower-priority owner (it yields if it is in guest code; else retry in 1 ms).
            __atomic_store_n(&c->owner->preempt, 1, __ATOMIC_RELEASE);
            pthread_kill(c->owner->host, SIGUSR2);
        }
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_nsec += 1000000;
        if (ts.tv_nsec >= 1000000000) ts.tv_sec++, ts.tv_nsec -= 1000000000;
        pthread_cond_timedwait(&c->cv, &c->m, &ts);
    }
    for (int i = 0; i < c->nwait; i++)
        if (c->wait[i] == t) {
            c->wait[i] = c->wait[c->nwait - 1], c->seq[i] = c->seq[c->nwait - 1];
            c->nwait--;
            break;
        }
    c->owner = t;
    t->run_core = k;
    pthread_mutex_unlock(&c->m);
}

static void release(GuestThread *t) {
    if (t->run_core < 0) return;
    Core *c = &g_cores[t->run_core];
    pthread_mutex_lock(&c->m);
    if (c->owner == t) c->owner = NULL;
    t->run_core = -1;
    __atomic_store_n(&t->preempt, 0, __ATOMIC_RELEASE);
    if (c->nwait) pthread_cond_broadcast(&c->cv);
    pthread_mutex_unlock(&c->m);
}

// Start running guest code on the current thread (thread start, after a blocking call).
void nx_core_enter(void) {
    GuestThread *t = nx_current();
    if (!t || !nx_cores_on() || t->run_core >= 0) return;
    acquire(t);
}
// Stop running guest code (blocking SVC, long host call, thread exit).
void nx_core_leave(void) {
    GuestThread *t = nx_current();
    if (!t || !nx_cores_on()) return;
    release(t);
}
// SetThreadCoreMask on the current thread: move to the new core now.
void nx_core_migrate(void) {
    GuestThread *t = nx_current();
    if (!t || !nx_cores_on() || t->run_core < 0 || t->run_core == core_of(t)) return;
    release(t);
    acquire(t);
}
// The core a thread runs on (GetCurrentProcessorNumber): the one it holds.
int nx_core_current(const GuestThread *t) { return t->run_core >= 0 ? t->run_core : core_of(t); }

static int in_guest(uint64_t a) {
    for (int i = 0; i < g_image.nmod; i++)
        if (a >= (uint64_t)g_image.mod[i].base && a < (uint64_t)g_image.mod[i].base + g_image.mod[i].size) return 1;
    return 0;
}
// Horizon's ThreadLocalRegion: u16 disable_count at +0x100, u16 interrupt_flag at +0x102. The SDK's spin locks
// (sdk+0x13eeb0: ldaxr/wfe loop) raise disable_count while they hold the lock, and the kernel never switches
// such a thread out: it sets interrupt_flag, and the thread calls SynchronizePreemptionState (SVC 0x36) once it
// unlocks. Preempting inside froze the game: the holder (prio 49) waited for its core while the higher-priority
// thread that took it (prio 48) spun on the lock forever (session 25, watchdog at frame 72).
// NXRT_PREEMPT_ANY=1: old behaviour (preempt regardless).
static int dispatch_disabled(GuestThread *t) {
    static int any = -1;
    if (any < 0) any = getenv("NXRT_PREEMPT_ANY") != NULL;
    if (any || !t->tls_region) return 0;
    volatile uint16_t *tlr = (volatile uint16_t *)(t->tls_region + 0x100);
    if (!tlr[0]) return 0;
    tlr[1] = 1;   // interrupt_flag: the guest calls SVC 0x36 after unlocking
    return 1;
}
// Preemption request: yield the core if this thread was interrupted in guest code. The guest code holds
// no host locks there, so waiting here is like Horizon switching the thread out.
static void on_preempt(int sig, siginfo_t *si, void *uc_) {
    GuestThread *t = nx_current();
    if (!t || t->run_core < 0 || !__atomic_load_n(&t->preempt, __ATOMIC_ACQUIRE)) return;
    ucontext_t *uc = uc_;
    if (!in_guest((uint64_t)uc->uc_mcontext->__ss.__pc)) {
        g_preempt_misses++;
        return;
    }
    if (dispatch_disabled(t)) {
        g_preempt_deferred++;
        return;
    }
    g_preempts++;
    release(t);
    acquire(t);
}
// SVC 0x36 SynchronizePreemptionState: the guest left a dispatch-disabled section after a deferred
// preemption: clear interrupt_flag and give the core to the waiter now.
void nx_core_sync_preemption(void) {
    GuestThread *t = nx_current();
    if (!t) return;
    if (t->tls_region) ((volatile uint16_t *)(t->tls_region + 0x100))[1] = 0;
    if (!nx_cores_on() || t->run_core < 0 || !__atomic_load_n(&t->preempt, __ATOMIC_ACQUIRE)) return;
    g_preempts++;
    release(t);
    acquire(t);
}
void nx_cores_signal_init(void) {
    struct sigaction sa = {0};
    sa.sa_sigaction = on_preempt;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESTART;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGUSR2, &sa, NULL);
}
// Freeze watchdog (crash.c): each core's owner and waiters. trylock only: a stuck thread may hold the core lock.
void nx_cores_dump(void) {
    if (g_on <= 0) return;
    for (int i = 0; i < NCORES; i++) {
        Core *c = &g_cores[i];
        if (pthread_mutex_trylock(&c->m)) {
            nx_log("watchdog: core %d: lock held", i);
            continue;
        }
        char w[512];
        int n = 0;
        for (int k = 0; k < c->nwait && n < (int)sizeof w - 32; k++)
            n += snprintf(w + n, sizeof w - n, " %u(p%d)", c->wait[k]->id, c->wait[k]->priority);
        w[n] = 0;
        nx_log("watchdog: core %d: owner %s%u (prio %d), %d waiting:%s", i, c->owner ? "thread " : "none ", c->owner ? c->owner->id : 0,
               c->owner ? c->owner->priority : 0, c->nwait, w);
        pthread_mutex_unlock(&c->m);
    }
}
void nx_cores_stats(void) {
    if (g_on > 0) nx_log("cores: %llu preemptions, %llu requests while in host code, %llu deferred (dispatch disabled)",
                         (unsigned long long)g_preempts, (unsigned long long)g_preempt_misses, (unsigned long long)g_preempt_deferred);
}
