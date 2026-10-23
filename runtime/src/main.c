// nxrt entry: load the patched modules, create the main guest thread, run rtld.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <TargetConditionals.h>

#include "gfx.h"
#include "ipc.h"

void nx_regions_from_image(void);
void nx_region_add(uint64_t base, uint64_t size, uint32_t state, uint32_t perm);

static const char *g_dir;

// Loads the game and runs it on the calling thread (never returns).
static void guest_main(void) {
    void nx_crash_thread_init(void);
    nx_crash_thread_init();
    nx_load_image(g_dir);
    nx_regions_from_image();
    nx_as_init();
    nx_services_init();
    const char *xci = getenv("NXRT_XCI") ? getenv("NXRT_XCI") : "../Tomodachi Life Living the Dream.xci";
    char keys[1024];
    snprintf(keys, sizeof keys, "%s/.switch/prod.keys", getenv("HOME"));
    if (getenv("NXRT_KEYS")) snprintf(keys, sizeof keys, "%s", getenv("NXRT_KEYS"));
    nx_content_open(xci, keys);

    uint64_t key_off = nx_tsd_key_offset();
    extern uint64_t nx_tsd_key_off;
    nx_tsd_key_off = key_off;
    nx_set_runtime_table(key_off, (void *)nx_svc_entry);
    nx_log("tsd key offset %#llx, svc_entry %p", (unsigned long long)key_off, (void *)nx_svc_entry);

    // Main thread: 1 MiB stack (main.npdm), TLS region, host stack for SVC handlers.
    GuestThread *t = nx_thread_new(0);
    pthread_mutex_lock(&g_klock);
    t->handle = nx_handle_new(&t->obj);
    pthread_mutex_unlock(&g_klock);
    t->priority = 44;
    size_t stack_size = 1 << 20;
    uint8_t *stack = mmap(NULL, stack_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    nx_region_add((uint64_t)stack, stack_size, MS_STACK, PERM_RW);
    nx_region_add((uint64_t)t->tls_region, 0x4000, MS_TLS, PERM_RW);
    nx_thread_bind(t);
    char tname[32];
    snprintf(tname, sizeof tname, "guest %u p%d", t->id, t->priority);   // thread.c nx_thread_cpu_stats
    pthread_setname_np(tname);
    nx_guest_qos_raise("main");

    Module *rtld = nx_module("rtld");
    void nx_watch_init(void);
    nx_watch_init();
    nx_log("entering rtld at %p", rtld->base);
    nx_core_enter();
    // rtld's entry: x0 = 0 (normal start), x1 = main thread handle.
    nx_enter_guest((uint64_t)rtld->base, 0, t->handle, (uint64_t)(stack + stack_size));
}

#if TARGET_OS_IPHONE
// iOS: the app (src/ios/app_ios.m) owns main(); it sets the paths (NXRT_XCI, NXRT_KEYS, NXRT_SHADERS, cwd)
// and starts the game on its own thread once the view exists.
void nx_ios_main(int argc, char **argv, void (*guest_main)(void));
int main(int argc, char **argv) {
    void nx_crash_handler_install(void);
    nx_crash_handler_install();
    nx_ios_main(argc, argv, guest_main);
    return 0;
}
#else
int main(int argc, char **argv) {
    if (argc == 4 && !strcmp(argv[1], "--shader-index")) {   // build tool: nxrt --shader-index <shaders dir> <out>
        int gfx_build_shader_index(const char *dir, const char *out);
        return gfx_build_shader_index(argv[2], argv[3]);
    }
    g_dir = argc > 1 ? argv[1] : "work";
    // The Mac app bundle (make app) opened from the Finder: the game's folder from its Info.plist, the log next to it.
    const char *nx_mac_bundle_home(void), *home = argc == 1 ? nx_mac_bundle_home() : NULL;
    if (home && !chdir(home)) {
        g_dir = "../work";
        freopen("nxrt.log", "w", stderr);
        setvbuf(stderr, NULL, _IOLBF, 0);
    }
    void nx_apply_mode(void);
    nx_apply_mode();   // NXRT_MODE=quality | performance (ui_touch.c)
    void nx_crash_handler_install(void);
    nx_crash_handler_install();
    // The window's event loop needs the process main thread; the game then runs on its own.
    // NXRT_HEADLESS=1: no window (frames are still executed and paced).
    if (getenv("NXRT_HEADLESS")) guest_main();
    else gfx_run_app(guest_main);
    return 0;
}
#endif
