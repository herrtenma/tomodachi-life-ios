// nxrt: native runtime for the Switch code of Tomodachi Life (macOS / iOS, arm64).
// The game's own ARM64 code runs directly; this runtime replaces the Horizon kernel
// (SVCs) and, later, the system services and NVN.
#pragma once
#include <stddef.h>
#include <stdint.h>

// ---- Horizon result codes (module 1 = kernel)
enum {
    RES_INVALID_SIZE = 0xCA01, RES_INVALID_ADDRESS = 0xCC01, RES_OUT_OF_RESOURCE = 0xCE01,
    RES_INVALID_HANDLE = 0xE401, RES_INVALID_STATE = 0xFA01, RES_INVALID_ENUM = 0xF001,
    RES_TIMEOUT = 0xEA01, RES_CANCELLED = 0xEC01, RES_NOT_FOUND = 0xF201,
};
enum { PSEUDO_CURRENT_THREAD = 0xFFFF8000u, PSEUDO_CURRENT_PROCESS = 0xFFFF8001u };

// ---- kernel objects
enum { KO_THREAD = 1, KO_EVENT_WRITE, KO_EVENT_READ, KO_SESSION, KO_SHMEM, KO_TMEM, KO_OTHER };
typedef struct KObject {
    int type;
    int refs;
    void *ptr;
    void (*destroy)(struct KObject *);
} KObject;
typedef struct KEvent { int signaled; } KEvent;
typedef struct KTmem { uint64_t addr, size; uint32_t perm; } KTmem;   // transfer memory
typedef struct KShmem { size_t size; uint8_t *backing; uint64_t maps[8]; int nmaps; } KShmem;

// ---- per-guest-thread block, found through a pthread key (Darwin TSD, TPIDRRO_EL0).
// Field offsets 0 and 8 are baked into the trampolines (spill.py GT_TPIDR/GT_TPIDRRO).
#include <pthread.h>
typedef struct GuestThread {
    uint64_t tpidr;            // +0x00 guest TPIDR_EL0 (compiler thread_local base)
    uint64_t tpidrro;          // +0x08 guest TPIDRRO_EL0 (Horizon TLS region, 0x200 bytes)
    uint64_t host_stack_top;   // +0x10 stack the SVC handlers run on
    uint32_t handle;           //       kernel handle of this thread
    uint32_t id;
    uint8_t *tls_region;
    uint8_t *host_stack;
    size_t host_stack_size;
    KObject obj;               // type KO_THREAD, ptr = this
    pthread_t host;
    pthread_cond_t cv;         // waits sleep here (under g_klock)
    int wait_done, cancel_sync, exited;
    uint32_t wait_result;
    uint64_t entry, arg, stack_top;
    int32_t priority, core;
    uint64_t core_mask;        // affinity; 0 = just `core`
    int32_t run_core;          // emulated core this thread holds while running guest code, -1 none (cores.c)
    int preempt;               // a higher-priority thread wants run_core (cores.c)
} GuestThread;

// ---- emulated cores (cores.c): one running guest thread per core
int nx_cores_on(void);
void nx_core_enter(void);   // take the current thread's core (blocks)
void nx_core_leave(void);   // give it up (blocking SVCs, long host calls)
void nx_core_migrate(void); // the current thread's core changed
void nx_core_sync_preemption(void); // SVC 0x36: yield after a deferred preemption
int nx_core_current(const GuestThread *t);
void nx_cores_stats(void);

// ---- guest address space (mem.c)
typedef struct AddressSpace {
    uint64_t base, size;
    uint64_t heap_base, heap_size, heap_used;
    uint64_t alias_base, alias_size;
    uint64_t stack_base, stack_size;
} AddressSpace;
extern AddressSpace g_as;
void nx_as_init(void);
int nx_map_anon(uint64_t addr, uint64_t size);
int nx_unmap(uint64_t addr, uint64_t size);
int nx_alias(uint64_t dst, uint64_t src, uint64_t size);
int nx_unalias(uint64_t dst, uint64_t src, uint64_t size);

// regions for svcQueryMemory (svc.c)
enum { MS_FREE = 0, MS_CODE = 3, MS_CODE_DATA = 4, MS_NORMAL = 5, MS_ALIAS = 7,
       MS_STACK = 0xB, MS_TLS = 0xC, MS_TRANSFERED = 0xD };
enum { PERM_NONE = 0, PERM_R = 1, PERM_RW = 3, PERM_RX = 5 };
void nx_region_add(uint64_t base, uint64_t size, uint32_t state, uint32_t perm);
int nx_region_get(int i, uint64_t *base, uint64_t *size, uint32_t *perm);
void nx_region_remove(uint64_t base, uint64_t size);

// ---- kernel (kernel.c)
extern pthread_mutex_t g_klock;
uint32_t nx_handle_new(KObject *o);
KObject *nx_handle_get(uint32_t h);
int nx_handle_close(uint32_t h);
uint32_t nx_wait_locked(GuestThread *t, int64_t timeout_ns);
void nx_wake_locked(GuestThread *t, uint32_t result);
uint32_t nx_wait_sync(const uint32_t *handles, int count, int64_t timeout_ns, int32_t *index);
void nx_event_create(uint32_t *write_h, uint32_t *read_h);
KEvent *nx_event_new_readable(uint32_t *read_h);
uint32_t nx_event_set(uint32_t h, int value);
void nx_event_signal_obj(KEvent *e);
uint32_t nx_arbitrate_lock(uint32_t owner, uint64_t addr, uint32_t tag);
uint32_t nx_arbitrate_unlock(uint64_t addr);
uint32_t nx_cv_wait(uint64_t mutex, uint64_t key, uint32_t tag, int64_t timeout_ns);
uint32_t nx_cv_signal(uint64_t key, int32_t count);
uint32_t nx_wait_for_address(uint64_t addr, uint32_t type, int32_t value, int64_t timeout_ns);
uint32_t nx_signal_to_address(uint64_t addr, uint32_t type, int32_t value, int32_t count);
uint32_t nx_thread_create(uint64_t entry, uint64_t arg, uint64_t stack_top, int32_t prio,
                          int32_t core, uint32_t *out_handle);
uint32_t nx_thread_start(uint32_t h);
_Noreturn void nx_thread_exit(void);
void nx_thread_cancel_sync(uint32_t h);
KShmem *nx_shmem_new(size_t size, uint32_t *out_handle);
uint32_t nx_shmem_map(uint32_t h, uint64_t addr, uint64_t size);
uint32_t nx_shmem_unmap(uint32_t h, uint64_t addr);
void nx_shmem_write(KShmem *s, size_t off, const void *p, size_t n);

// ---- loaded modules
typedef struct Module {
    const char *name;
    uint8_t *base;
    size_t size;               // 16 KB aligned, bss included
    size_t text_size, ro_off, ro_size, data_off, data_size, bss_size;
} Module;

enum { NX_MAX_MODULES = 8 };
typedef struct Image {
    uint8_t *base;
    size_t size;
    Module mod[NX_MAX_MODULES];
    int nmod;
} Image;

extern Image g_image;

// loader.c
int nx_load_image(const char *dir);                 // rtld, main, subsdk9, sdk from <dir>
Module *nx_module(const char *name);
void nx_set_runtime_table(uint64_t tsd_key_off, void *svc_entry);

// thread.c
GuestThread *nx_current(void);
GuestThread *nx_thread_new(uint32_t handle);
void nx_thread_bind(GuestThread *t);                // make t current for this host thread
int nx_guest_qos(void);                            // NXRT_GUEST_QOS mode (kernel.c)
void nx_guest_qos_raise(const char *role);         // name this thread "... <role>"; split mode: user-interactive
void nx_thread_cpu_stats(int frames);              // NXRT_PERF: CPU per thread, P/E split (thread.c)
GuestThread *nx_thread_by_host(pthread_t p);         // the guest thread bound to a host thread, or NULL
uint64_t nx_tsd_key_offset(void);

// svc.c
void nx_svc_dispatch(uint64_t num, uint64_t *regs); // regs[0..17] = guest x0..x17
uint64_t nx_host_stack_top(void);                   // for svc_entry.S

// svc_entry.S
void nx_svc_entry(void);
void nx_enter_guest(uint64_t entry, uint64_t x0, uint64_t x1, uint64_t sp);

// log.c
void nx_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
_Noreturn void nx_fatal(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

// content.c: RomFS read straight from the XCI
int nx_content_open(const char *xci_path, const char *keys_path);
uint64_t nx_romfs_size(void);
int nx_romfs_read(uint64_t off, void *dst, size_t n);
uint8_t *nx_system_data_file(uint64_t program_id, const char *fname, uint64_t *size);
