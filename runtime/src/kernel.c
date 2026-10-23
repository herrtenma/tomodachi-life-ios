// Kernel objects: handles, threads, events, waiting, and Horizon's three sync families
// (mutex handoff, process-wide condition variables, address arbiter). Semantics follow
// Atmosphère's open-source kernel (KConditionVariable, KAddressArbiter).
// One global lock; each guest thread sleeps on its own condition variable.
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdio.h>
#include <mach/mach.h>
#include <pthread/qos.h>
#include <TargetConditionals.h>

#include "nxrt.h"

pthread_mutex_t g_klock = PTHREAD_MUTEX_INITIALIZER;

// ---- handles -----------------------------------------------------------------------

enum { MAX_HANDLES = 4096, HANDLE_BASE = 0x100 };
static KObject *g_handles[MAX_HANDLES];

uint32_t nx_handle_new(KObject *o) {
    for (int i = 0; i < MAX_HANDLES; i++)
        if (!g_handles[i]) {
            g_handles[i] = o;
            o->refs++;
            return HANDLE_BASE + i;
        }
    nx_fatal("out of handles");
}

KObject *nx_handle_get(uint32_t h) {
    if (h == PSEUDO_CURRENT_THREAD) return &nx_current()->obj;
    if (h < HANDLE_BASE || h >= HANDLE_BASE + MAX_HANDLES) return NULL;
    return g_handles[h - HANDLE_BASE];
}

int nx_handle_close(uint32_t h) {
    if (h < HANDLE_BASE || h >= HANDLE_BASE + MAX_HANDLES || !g_handles[h - HANDLE_BASE]) return -1;
    KObject *o = g_handles[h - HANDLE_BASE];
    g_handles[h - HANDLE_BASE] = NULL;
    if (--o->refs == 0 && o->destroy) o->destroy(o);
    return 0;
}

// ---- waiting -----------------------------------------------------------------------
// Called with g_klock held. Sleeps until woken (t->wait_done) or the deadline passes.
// Returns the wait result set by the waker, or RES_TIMEOUT.

static void deadline_from(struct timespec *ts, int64_t timeout_ns) {
    clock_gettime(CLOCK_REALTIME, ts);
    int64_t ns = ts->tv_nsec + timeout_ns % 1000000000;
    ts->tv_sec += timeout_ns / 1000000000 + ns / 1000000000;
    ts->tv_nsec = ns % 1000000000;
}

uint32_t nx_wait_locked(GuestThread *t, int64_t timeout_ns) {
    struct timespec ts;
    if (timeout_ns > 0) deadline_from(&ts, timeout_ns);
    while (!t->wait_done) {
        if (timeout_ns < 0) {
            pthread_cond_wait(&t->cv, &g_klock);
        } else if (pthread_cond_timedwait(&t->cv, &g_klock, &ts) == ETIMEDOUT && !t->wait_done) {
            return RES_TIMEOUT;
        }
    }
    return t->wait_result;
}

void nx_wake_locked(GuestThread *t, uint32_t result) {
    t->wait_done = 1;
    t->wait_result = result;
    pthread_cond_signal(&t->cv);
}

// Any change that might satisfy a WaitSynchronization wakes every thread in one.
static GuestThread *g_syncwait[256];
static int g_nsyncwait;

static void sync_changed_locked(void) {
    for (int i = 0; i < g_nsyncwait; i++) pthread_cond_signal(&g_syncwait[i]->cv);
}

static int signaled_locked(KObject *o) {
    switch (o->type) {
    case KO_EVENT_READ: return ((KEvent *)o->ptr)->signaled;
    case KO_THREAD: return ((GuestThread *)o->ptr)->exited;
    default: return 0;
    }
}

uint32_t nx_wait_sync(const uint32_t *handles, int count, int64_t timeout_ns, int32_t *index) {
    GuestThread *t = nx_current();
    pthread_mutex_lock(&g_klock);
    KObject *objs[64];
    for (int i = 0; i < count; i++)
        if (!(objs[i] = nx_handle_get(handles[i]))) {
            pthread_mutex_unlock(&g_klock);
            static int warned;
            if (!warned++) nx_log("WaitSynchronization: invalid handle %#x (index %d of %d)", handles[i], i, count);
            return RES_INVALID_HANDLE;
        }
    struct timespec ts;
    if (timeout_ns > 0) deadline_from(&ts, timeout_ns);
    g_syncwait[g_nsyncwait++] = t;
    uint32_t res = RES_TIMEOUT;
    for (;;) {
        int hit = -1;
        for (int i = 0; i < count && hit < 0; i++)
            if (signaled_locked(objs[i])) hit = i;
        if (hit >= 0) {
            *index = hit;
            res = 0;
            break;
        }
        if (t->cancel_sync) {
            t->cancel_sync = 0;
            res = RES_CANCELLED;
            break;
        }
        if (timeout_ns == 0) break;
        if (timeout_ns < 0) pthread_cond_wait(&t->cv, &g_klock);
        else if (pthread_cond_timedwait(&t->cv, &g_klock, &ts) == ETIMEDOUT) break;
    }
    for (int i = 0; i < g_nsyncwait; i++)
        if (g_syncwait[i] == t) {
            g_syncwait[i] = g_syncwait[--g_nsyncwait];
            break;
        }
    pthread_mutex_unlock(&g_klock);
    return res;
}

// ---- events ------------------------------------------------------------------------

void nx_event_create(uint32_t *write_h, uint32_t *read_h) {
    KEvent *e = calloc(1, sizeof *e);
    KObject *w = calloc(1, sizeof *w), *r = calloc(1, sizeof *r);
    w->type = KO_EVENT_WRITE;
    w->ptr = e;
    r->type = KO_EVENT_READ;
    r->ptr = e;
    *write_h = nx_handle_new(w);
    *read_h = nx_handle_new(r);
}

KEvent *nx_event_new_readable(uint32_t *read_h) {   // for service-side events
    KEvent *e = calloc(1, sizeof *e);
    KObject *r = calloc(1, sizeof *r);
    r->type = KO_EVENT_READ;
    r->ptr = e;
    *read_h = nx_handle_new(r);
    return e;
}

uint32_t nx_event_set(uint32_t h, int value) {
    pthread_mutex_lock(&g_klock);
    KObject *o = nx_handle_get(h);
    uint32_t res = 0;
    if (!o || (o->type != KO_EVENT_WRITE && o->type != KO_EVENT_READ)) {
        res = RES_INVALID_HANDLE;
    } else {
        ((KEvent *)o->ptr)->signaled = value;
        if (value) sync_changed_locked();
    }
    pthread_mutex_unlock(&g_klock);
    return res;
}

void nx_event_signal_obj(KEvent *e) {
    pthread_mutex_lock(&g_klock);
    e->signaled = 1;
    sync_changed_locked();
    pthread_mutex_unlock(&g_klock);
}

// ---- mutexes and condition variables (KConditionVariable) --------------------------
// Waiter entries: a thread waiting to own the mutex at `addr`, currently owned by
// `owner` (handle). `tag` is the value the waiter will write when it becomes owner.

#define HANDLE_WAIT_MASK 0x40000000u

typedef struct Waiter {
    GuestThread *t;
    uint64_t addr;       // mutex address (mutex waiters) or condvar key (cv waiters)
    uint64_t mutex;      // cv waiters: the mutex to reacquire
    uint32_t tag;        // value to write as new owner
    uint32_t owner;      // mutex waiters: owner handle
    int is_cv;
    struct Waiter *next;
} Waiter;

static Waiter *g_waiters;

static void waiter_add(Waiter *w) {
    Waiter **p = &g_waiters;
    while (*p) p = &(*p)->next;
    w->next = NULL;
    *p = w;
}

static void waiter_remove(Waiter *w) {
    for (Waiter **p = &g_waiters; *p; p = &(*p)->next)
        if (*p == w) {
            *p = w->next;
            return;
        }
}

static uint32_t thread_handle(GuestThread *t) { return t->handle; }

// RemoveWaiterByKey: the first mutex waiter on `addr` owned by `owner`; remaining ones
// are transferred to the new owner. Returns it (removed) and the count found.
static Waiter *remove_waiter_by_key(uint32_t owner, uint64_t addr, int *count) {
    Waiter *first = NULL;
    *count = 0;
    for (Waiter *w = g_waiters; w; w = w->next)
        if (!w->is_cv && w->owner == owner && w->addr == addr) {
            (*count)++;
            if (!first) first = w;
        }
    if (!first) return NULL;
    waiter_remove(first);
    for (Waiter *w = g_waiters; w; w = w->next)
        if (!w->is_cv && w->owner == owner && w->addr == addr) w->owner = thread_handle(first->t);
    return first;
}

// Hand the mutex at addr from the current owner to its next waiter (or free it).
static void unlock_to_next_locked(uint32_t owner, uint64_t addr) {
    int n;
    Waiter *next = remove_waiter_by_key(owner, addr, &n);
    uint32_t v = 0;
    if (next) {
        v = next->tag;
        if (n > 1) v |= HANDLE_WAIT_MASK;
        nx_wake_locked(next->t, 0);
    }
    __atomic_store_n((uint32_t *)addr, v, __ATOMIC_SEQ_CST);
}

uint32_t nx_arbitrate_lock(uint32_t owner, uint64_t addr, uint32_t tag) {
    GuestThread *t = nx_current();
    pthread_mutex_lock(&g_klock);
    uint32_t v = __atomic_load_n((uint32_t *)addr, __ATOMIC_SEQ_CST);
    if (v != (owner | HANDLE_WAIT_MASK)) {
        pthread_mutex_unlock(&g_klock);
        return 0;
    }
    Waiter w = {.t = t, .addr = addr, .tag = tag, .owner = owner};
    t->wait_done = 0;
    waiter_add(&w);
    uint32_t res = nx_wait_locked(t, -1);
    pthread_mutex_unlock(&g_klock);
    return res;
}

uint32_t nx_arbitrate_unlock(uint64_t addr) {
    pthread_mutex_lock(&g_klock);
    unlock_to_next_locked(nx_current()->handle, addr);
    pthread_mutex_unlock(&g_klock);
    return 0;
}

uint32_t nx_cv_wait(uint64_t mutex, uint64_t key, uint32_t tag, int64_t timeout_ns) {
    GuestThread *t = nx_current();
    pthread_mutex_lock(&g_klock);
    // "Has waiters" first, then release the mutex (Horizon's order). The other way round, a signaller could take the
    // mutex in user mode between the two, see no waiters, skip SignalProcessWideKey, and this thread slept forever
    // (found in the BDSP port: boot stalled at random with every thread parked in condvar waits).
    __atomic_store_n((uint32_t *)key, 1, __ATOMIC_SEQ_CST);   // has waiters
    unlock_to_next_locked(t->handle, mutex);
    if (timeout_ns == 0) {
        pthread_mutex_unlock(&g_klock);
        return RES_TIMEOUT;
    }
    Waiter w = {.t = t, .addr = key, .mutex = mutex, .tag = tag, .is_cv = 1};
    t->wait_done = 0;
    waiter_add(&w);
    uint32_t res = nx_wait_locked(t, timeout_ns);
    if (res == RES_TIMEOUT) waiter_remove(&w);   // still queued (cv or mutex): drop it
    pthread_mutex_unlock(&g_klock);
    return res;
}

// SignalImpl: try to take the mutex for a woken cv waiter, else queue it on the owner.
static void cv_signal_one_locked(Waiter *w) {
    uint32_t *m = (uint32_t *)w->mutex;
    uint32_t prev = __atomic_load_n(m, __ATOMIC_SEQ_CST);
    for (;;) {
        uint32_t want = prev == 0 ? w->tag : prev | HANDLE_WAIT_MASK;
        if (__atomic_compare_exchange_n(m, &prev, want, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) break;
    }
    if (prev == 0) {
        nx_wake_locked(w->t, 0);
    } else {
        w->is_cv = 0;
        w->addr = w->mutex;
        w->owner = prev & ~HANDLE_WAIT_MASK;
        waiter_add(w);   // woken later by the owner's unlock
    }
}

uint32_t nx_cv_signal(uint64_t key, int32_t count) {
    pthread_mutex_lock(&g_klock);
    int n = 0;
    for (Waiter *w = g_waiters; w && (count <= 0 || n < count);) {
        Waiter *next = w->next;
        if (w->is_cv && w->addr == key) {
            waiter_remove(w);
            cv_signal_one_locked(w);
            n++;
        }
        w = next;
    }
    int more = 0;
    for (Waiter *w = g_waiters; w; w = w->next)
        if (w->is_cv && w->addr == key) more = 1;
    if (!more) __atomic_store_n((uint32_t *)key, 0, __ATOMIC_SEQ_CST);
    pthread_mutex_unlock(&g_klock);
    return 0;
}

// ---- address arbiter (KAddressArbiter) ---------------------------------------------

enum { ARB_WAIT_LESS = 0, ARB_DEC_WAIT_LESS = 1, ARB_WAIT_EQUAL = 2 };
enum { SIG_SIGNAL = 0, SIG_INC_IF_EQUAL = 1, SIG_MODIFY_BY_WAITERS_IF_EQUAL = 2 };

uint32_t nx_wait_for_address(uint64_t addr, uint32_t type, int32_t value, int64_t timeout_ns) {
    GuestThread *t = nx_current();
    pthread_mutex_lock(&g_klock);
    int32_t *p = (int32_t *)addr, cur = __atomic_load_n(p, __ATOMIC_SEQ_CST);
    int wait;
    if (type == ARB_WAIT_LESS) wait = cur < value;
    else if (type == ARB_DEC_WAIT_LESS) {
        // Atomic like Horizon's DecrementIfLessThan: guest threads update the word with their own
        // atomics (no kernel lock), so a plain load + store could overwrite their change.
        while ((wait = cur < value) && !__atomic_compare_exchange_n(p, &cur, cur - 1, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) {}
    } else if (type == ARB_WAIT_EQUAL) wait = cur == value;
    else {
        pthread_mutex_unlock(&g_klock);
        return RES_INVALID_ENUM;
    }
    if (!wait) {
        pthread_mutex_unlock(&g_klock);
        return RES_INVALID_STATE;
    }
    if (timeout_ns == 0) {
        pthread_mutex_unlock(&g_klock);
        return RES_TIMEOUT;
    }
    Waiter w = {.t = t, .addr = addr, .is_cv = 2};
    t->wait_done = 0;
    waiter_add(&w);
    uint32_t res = nx_wait_locked(t, timeout_ns);
    if (res == RES_TIMEOUT) waiter_remove(&w);
    pthread_mutex_unlock(&g_klock);
    return res;
}

static int arb_waiters(uint64_t addr) {
    int n = 0;
    for (Waiter *w = g_waiters; w; w = w->next)
        if (w->is_cv == 2 && w->addr == addr) n++;
    return n;
}

static void arb_wake(uint64_t addr, int32_t count) {
    int n = 0;
    if (getenv("NXRT_TRACE")) {
        int total = 0, here = 0;
        for (Waiter *w = g_waiters; w; w = w->next) { total++; if (w->is_cv == 2 && w->addr == addr) here++; }
        nx_log("    arbiter: wake %#llx count %d: %d waiting here, %d waiters total", (unsigned long long)addr, count, here, total);
    }
    for (Waiter *w = g_waiters; w && (count <= 0 || n < count);) {
        Waiter *next = w->next;
        if (w->is_cv == 2 && w->addr == addr) {
            waiter_remove(w);
            nx_wake_locked(w->t, 0);
            n++;
        }
        w = next;
    }
}

uint32_t nx_signal_to_address(uint64_t addr, uint32_t type, int32_t value, int32_t count) {
    pthread_mutex_lock(&g_klock);
    int32_t *p = (int32_t *)addr;
    uint32_t res = 0;
    if (type == SIG_SIGNAL) {
        arb_wake(addr, count);
    } else if (type == SIG_INC_IF_EQUAL || type == SIG_MODIFY_BY_WAITERS_IF_EQUAL) {
        // New value as Horizon computes it (Atmosphère KAddressArbiter, 7.0.0+): for the waiter-count
        // variant, "others" counts the waiters after the first, capped just past count.
        int32_t nv = value + 1;
        if (type == SIG_MODIFY_BY_WAITERS_IF_EQUAL) {
            int n = arb_waiters(addr);
            if (count <= 0) nv = n > 0 ? value - 2 : value + 1;
            else if (n > 0) {
                int others = n - 1 > count + 1 ? count + 1 : n - 1;
                nv = others == 0 ? value + 1 : others <= count ? value - 1 : value;
            }
        }
        // Compare-and-swap (UpdateIfEqual): the guest may change the word concurrently.
        int32_t cur = value;
        if (!__atomic_compare_exchange_n(p, &cur, nv, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) {
            if (getenv("NXRT_TRACE"))
                nx_log("    arbiter: signal %#llx type %u expected %d but memory is %d (%d waiters)",
                       (unsigned long long)addr, type, value, cur, arb_waiters(addr));
            res = RES_INVALID_STATE;
        } else {
            arb_wake(addr, count);
        }
    } else {
        res = RES_INVALID_ENUM;
    }
    pthread_mutex_unlock(&g_klock);
    return res;
}

// ---- threads -----------------------------------------------------------------------

void nx_crash_thread_init(void);

// Guest threads are the game's frame: its main loop, job workers and the thread that submits (and so runs our whole
// Metal encode). Default QoS let the system put them on efficiency cores / lower clocks between bursts.
// NXRT_GUEST_QOS (from the BOTW port): 0 default QoS; 1 all user-interactive (Mac default); 2 split (iOS default):
// user-initiated, and the main guest thread (main.c) and the thread that submits (gfx_cmd.m nx_guest_qos_raise) raise
// themselves to user-interactive, so on the A15 (2 P-cores) the encode and the game's main loop get the P-cores first.
int nx_guest_qos(void) {
    static int mode = -1;
    if (mode < 0) {
        mode = TARGET_OS_IPHONE ? 2 : 1;
        if (getenv("NXRT_GUEST_QOS")) mode = atoi(getenv("NXRT_GUEST_QOS"));
        nx_log("threads: guest QoS %s", mode == 0 ? "default" : mode == 1 ? "all user-interactive" : "split (main + submit user-interactive, others user-initiated)");
    }
    return mode;
}
void nx_guest_qos_raise(const char *role) {   // once per thread: renamed "<name> <role>"; modes 1-2: to user-interactive
    static __thread int raised;
    if (raised) return;
    raised = 1;
    char name[64] = "";
    pthread_getname_np(pthread_self(), name, sizeof name);
    size_t n = strlen(name);
    snprintf(name + n, sizeof name - n, "%s%s", n ? " " : "", role);
    pthread_setname_np(name);
    if (!nx_guest_qos()) return;   // mode 1 too: the apps start the main guest thread at default QoS
    int err = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    // Scheduler priority after the raise: 47 when it took effect; 31 in a clamped task (e.g. started from a shell
    // without a GUI session: there every QoS runs at 31, so P/E A/B runs need the app or the phone).
    struct thread_extended_info ext = {0};
    mach_msg_type_number_t ce = THREAD_EXTENDED_INFO_COUNT;
    mach_port_t self = mach_thread_self();
    thread_info(self, THREAD_EXTENDED_INFO, (thread_info_t)&ext, &ce);
    mach_port_deallocate(mach_task_self(), self);
    GuestThread *t = nx_current();
    nx_log("threads: %s (guest thread %u) raised to user-interactive (%s, scheduler priority %d)", role, t ? t->id : 0,
           err ? "failed" : "ok", ext.pth_priority);
}

static void *host_thread_main(void *arg) {
    GuestThread *t = arg;
    char name[32];
    snprintf(name, sizeof name, "guest %u p%d", t->id, t->priority);   // per-thread CPU stats (thread.c nx_thread_cpu_stats)
    pthread_setname_np(name);
    nx_crash_thread_init();
    nx_thread_bind(t);
    nx_core_enter();
    nx_enter_guest(t->entry, t->arg, 0, t->stack_top);
    return NULL;
}

uint32_t nx_thread_create(uint64_t entry, uint64_t arg, uint64_t stack_top, int32_t prio,
                          int32_t core, uint32_t *out_handle) {
    GuestThread *t = nx_thread_new(0);
    t->entry = entry;
    t->arg = arg;
    t->stack_top = stack_top;
    t->priority = prio;
    t->core = core < 0 ? 0 : core;
    pthread_mutex_lock(&g_klock);
    t->handle = nx_handle_new(&t->obj);
    pthread_mutex_unlock(&g_klock);
    *out_handle = t->handle;
    return 0;
}

uint32_t nx_thread_start(uint32_t h) {
    KObject *o = nx_handle_get(h);
    if (!o || o->type != KO_THREAD) return RES_INVALID_HANDLE;
    GuestThread *t = o->ptr;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int qos = nx_guest_qos();   // see above
    if (qos) pthread_attr_set_qos_class_np(&attr, qos == 1 ? QOS_CLASS_USER_INTERACTIVE : QOS_CLASS_USER_INITIATED, 0);
    if (pthread_create(&t->host, &attr, host_thread_main, t)) return RES_OUT_OF_RESOURCE;
    return 0;
}

_Noreturn void nx_thread_exit(void) {
    GuestThread *t = nx_current();
    nx_core_leave();
    pthread_mutex_lock(&g_klock);
    t->exited = 1;
    sync_changed_locked();
    pthread_mutex_unlock(&g_klock);
    pthread_exit(NULL);
}

void nx_thread_cancel_sync(uint32_t h) {
    pthread_mutex_lock(&g_klock);
    KObject *o = nx_handle_get(h);
    if (o && o->type == KO_THREAD) {
        GuestThread *t = o->ptr;
        t->cancel_sync = 1;
        pthread_cond_signal(&t->cv);
    }
    pthread_mutex_unlock(&g_klock);
}

// ---- shared memory -----------------------------------------------------------------
// Host pages are 16 KB and Horizon's are 4 KB, so a guest mapping cannot alias the
// object. Each mapping is a copy kept in sync by the writer (services write through
// nx_shmem_write; guest-created objects are copied on map).

KShmem *nx_shmem_new(size_t size, uint32_t *out_handle) {
    KShmem *s = calloc(1, sizeof *s);
    s->size = size;
    s->backing = calloc(1, size);
    KObject *o = calloc(1, sizeof *o);
    o->type = KO_SHMEM;
    o->ptr = s;
    pthread_mutex_lock(&g_klock);
    *out_handle = nx_handle_new(o);
    pthread_mutex_unlock(&g_klock);
    return s;
}

uint32_t nx_shmem_map(uint32_t h, uint64_t addr, uint64_t size) {
    KObject *o = nx_handle_get(h);
    if (!o || o->type != KO_SHMEM) return RES_INVALID_HANDLE;
    KShmem *s = o->ptr;
    if (size > s->size || s->nmaps == 8) return RES_INVALID_SIZE;
    memcpy((void *)addr, s->backing, size);
    s->maps[s->nmaps++] = addr;
    return 0;
}

uint32_t nx_shmem_unmap(uint32_t h, uint64_t addr) {
    KObject *o = nx_handle_get(h);
    if (!o || o->type != KO_SHMEM) return RES_INVALID_HANDLE;
    KShmem *s = o->ptr;
    for (int i = 0; i < s->nmaps; i++)
        if (s->maps[i] == addr) s->maps[i] = s->maps[--s->nmaps];
    return 0;
}

void nx_shmem_write(KShmem *s, size_t off, const void *p, size_t n) {
    memcpy(s->backing + off, p, n);
    for (int i = 0; i < s->nmaps; i++) memcpy((uint8_t *)s->maps[i] + off, p, n);
}
