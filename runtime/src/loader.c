// Map the native-flavor NSOs (spill.py SPILL_NATIVE=1) back to back, the way the
// trampolines were laid out: [rtld | main | subsdk9 | sdk], each module 16 KB aligned.
// Linking is left to the game's own rtld, which finds modules through svcQueryMemory.
#include <fcntl.h>
#include <libkern/OSCacheControl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "nxrt.h"

#define PAGE 0x4000ul
#define PAGE_UP(x) (((x) + PAGE - 1) & ~(PAGE - 1))

Image g_image;

typedef struct {
    uint8_t *file;
    size_t file_size;
    uint32_t off[3], mem[3], size[3], bss;
} Nso;

static int read_nso(const char *path, Nso *n) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    struct stat st;
    fstat(fd, &st);
    n->file_size = st.st_size;
    n->file = malloc(n->file_size);
    if (read(fd, n->file, n->file_size) != (ssize_t)n->file_size) nx_fatal("short read %s", path);
    close(fd);
    if (memcmp(n->file, "NSO0", 4)) nx_fatal("%s: not an NSO", path);
    uint32_t flags;
    memcpy(&flags, n->file + 0xC, 4);
    if (flags & 7) nx_fatal("%s: compressed NSO (flags %#x)", path, flags);
    for (int i = 0; i < 3; i++) {
        memcpy(&n->off[i], n->file + 0x10 + i * 0x10, 4);
        memcpy(&n->mem[i], n->file + 0x14 + i * 0x10, 4);
        memcpy(&n->size[i], n->file + 0x18 + i * 0x10, 4);
    }
    memcpy(&n->bss, n->file + 0x3C, 4);
    return 0;
}

static size_t nso_span(const Nso *n) {
    size_t end = 0;
    for (int i = 0; i < 3; i++)
        if (n->mem[i] + n->size[i] > end) end = n->mem[i] + n->size[i];
    return PAGE_UP(end + n->bss);
}

// Plain load/store exclusives (LDXR/STXR/LDXP/STXP without acquire/release) in the loaded modules. From the BOTW port
// (its HANDOFF session 4): its spin locks acquire with plain ldxr/stxr and no barrier, which a Cortex-A57 tolerates and
// Apple cores don't (random crashes until every exclusive became LDAXR/STLXR). Tomodachi shows no such symptom: logged
// only. NXRT_ACQREL=1 (Mac) sets the ordering bit (15) on each one at load, for an A/B if unexplained crashes appear;
// the iPhone's image takes it at build time (tools/nxrecomp/spill.py, ACQREL=1).
static void acqrel_check(int patch) {
    unsigned left = 0;
    for (int k = 0; k < g_image.nmod; k++) {
        Module *m = &g_image.mod[k];
        uint32_t *w = (uint32_t *)m->base;
        unsigned n[4] = {0};
        for (size_t i = 0; i < m->text_size / 4; i++) {
            uint32_t x = w[i];
            int c = (x & 0x3FFFFC00) == 0x085F7C00 ? 0 : (x & 0x3FE0FC00) == 0x08007C00 ? 1
                  : (x & 0xBFFF8000) == 0x887F0000 ? 2 : (x & 0xBFE08000) == 0x88200000 ? 3 : -1;
            if (c < 0) continue;
            if (patch) w[i] = x | 0x8000;
            n[c]++;
        }
        if (n[0] + n[1] + n[2] + n[3])
            nx_log("acqrel: %s: %u ldxr, %u stxr, %u ldxp, %u stxp plain%s", m->name, n[0], n[1], n[2], n[3], patch ? " -> acquire/release" : "");
        left += n[0] + n[1] + n[2] + n[3];
    }
    nx_log("acqrel: %u plain exclusives%s", left, patch && left ? " (patched now: NXRT_ACQREL)" : "");
}

int g_vrr;   // NXRT_VRR / embed.py --vrr: controller patched, pace() (gfx_metal.m) owns the frame rate

#ifdef NXRT_EMBED
// Static image (tools/nxrecomp/embed.py, `make embed`): the NSOs are segments of this binary, already
// patched and signed (text r-x, the rest rw-), so nothing becomes executable at run time (no JIT; iOS).
extern uint8_t nx_img_rtld[], nx_img_main[], nx_img_subsdk9[], nx_img_sdk[];
extern const uint64_t nx_img_info[4 * 7 + 1];
static int load_embedded(void) {
    static const char *names[] = {"rtld", "main", "subsdk9", "sdk"};
    uint8_t *starts[] = {nx_img_rtld, nx_img_main, nx_img_subsdk9, nx_img_sdk};
    uint8_t *at = starts[0];
    g_image.base = at;
    for (int i = 0; i < 4; i++) {
        const uint64_t *r = &nx_img_info[i * 7];
        // The modules must sit back to back as in the mmap layout (the linker places the segments).
        if (starts[i] != at) nx_fatal("embedded image: %s at %p, expected %p (segment order/padding)", names[i], starts[i], at);
        Module *m = &g_image.mod[g_image.nmod++];
        m->name = names[i];
        m->base = at;
        m->text_size = r[0], m->ro_off = r[1], m->ro_size = r[2], m->data_off = r[3], m->data_size = r[4], m->bss_size = r[5];
        m->size = r[6];
        at += m->size;
        nx_log("module %-8s %p..%p  text %#zx ro %#zx+%#zx data %#zx+%#zx bss %#zx (embedded)", m->name,
               m->base, m->base + m->size, m->text_size, m->ro_off, m->ro_size, m->data_off, m->data_size, m->bss_size);
    }
    g_image.size = at - g_image.base;
    nx_log("loader: embedded image, %s%s build", nx_img_info[28] & 1 ? "60 fps" : "30 fps", nx_img_info[28] & 2 ? ", vrr" : "");
    g_vrr = nx_img_info[28] >> 1 & 1;
    {
        void nx_ui_install(Module *m, int patch);
        nx_ui_install(nx_module("main"), 0);
        void nx_wide_setup(Module *m, int patch_code);
        nx_wide_setup(nx_module("main"), 0);
    }
    // Code patches are build-time here (embed.py): the run-time switches would write into signed text. NXRT_FPS=60
    // works at run time (ui_touch.c fps_tick: the frame-rate controller's data).
    static const char *const sw[] = {"NXRT_MININTERVAL", "NXRT_MAXINTERVAL", "NXRT_VRR", "NXRT_TICKPROBE", "NXRT_EXECPROBE",
                                     "NXRT_VOBJPROBE", "NXRT_SKIPPROBE", "NXRT_PASSPROBE", "NXRT_CHUNKPROBE", "NXRT_OBJPROBE",
                                     "NXRT_RACEPROBE"};
    for (unsigned i = 0; i < sizeof sw / sizeof *sw; i++)
        if (getenv(sw[i])) nx_log("loader: %s ignored (embedded image: code patches are applied at build time)", sw[i]);
    acqrel_check(0);
    return 0;
}
#endif

int nx_load_image(const char *dir) {
#ifdef NXRT_EMBED
    (void)dir;
    return load_embedded();
#endif
    static const char *names[] = {"rtld", "main", "subsdk9", "sdk"};
    static const char *files[] = {"rtld.native.nso", "main.native.nso", "subsdk9.native.nso",
                                  "sdk.native.nso"};
    Nso nso[4];
    size_t total = 0;
    for (int i = 0; i < 4; i++) {
        char path[1024];
        snprintf(path, sizeof path, "%s/%s", dir, files[i]);
        if (read_nso(path, &nso[i])) nx_fatal("cannot open %s", path);
        total += nso_span(&nso[i]);
    }
    uint8_t *base = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (base == MAP_FAILED) nx_fatal("mmap image %zu", total);
    g_image.base = base;
    g_image.size = total;

    uint8_t *at = base;
    for (int i = 0; i < 4; i++) {
        Nso *n = &nso[i];
        Module *m = &g_image.mod[g_image.nmod++];
        m->name = names[i];
        m->base = at;
        m->size = nso_span(n);
        m->text_size = n->size[0];
        m->ro_off = n->mem[1];
        m->ro_size = n->size[1];
        m->data_off = n->mem[2];
        m->data_size = n->size[2];
        m->bss_size = n->bss;
        for (int s = 0; s < 3; s++) memcpy(at + n->mem[s], n->file + n->off[s], n->size[s]);
        free(n->file);
        at += m->size;
    }
    {   // ui_touch.c: main's base (touch on the game's UI)
        void nx_ui_install(Module *m, int patch);
        nx_ui_install(nx_module("main"), 1);
    }
    // Host hooks (macOS build: patched in memory before the code becomes executable).
    // Each replaces a function's first 16 bytes with: ldr x16, #8 ; br x16 ; .quad target
    // (x16 is free at function entry). iOS will do this at build time instead.
    extern void *nx_nvn_bootstrap_loader(const char *);
    struct { const char *mod; uint64_t off; void *target; } hooks[] = {
        {"sdk", 0x502d10, (void *)nx_nvn_bootstrap_loader},   // nvnBootstrapLoader
    };
    // NXRT_VOBJPROBE=1: probe on the vertex-bind fallback's "no valid attributes" test, main+0x40046c.
    if (getenv("NXRT_VOBJPROBE")) {
        extern void nx_probe_vobj(void);
        extern struct { uint64_t calls, skip, ret, pass; } nx_vobjprobe;
        Module *m = nx_module("main");
        nx_vobjprobe.skip = (uint64_t)(m->base + 0x4004d4);
        nx_vobjprobe.ret = (uint64_t)(m->base + 0x40047c);
        uint32_t code[4] = {0x58000050, 0xD61F0200, 0, 0};   // ldr x16, #8 ; br x16
        uint64_t t = (uint64_t)nx_probe_vobj;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0x40046c, code, 16);
    }
    // NXRT_SKIPPROBE=1: probe on the bind function's wrapper-ready test, main+0x17c43c (src/probe_hooks.S).
    if (getenv("NXRT_SKIPPROBE")) {
        extern void nx_probe_skip(void);
        extern struct { uint64_t calls, skip, ret, pad; } nx_skipprobe;
        Module *m = nx_module("main");
        nx_skipprobe.skip = (uint64_t)(m->base + 0x17c4d4);
        nx_skipprobe.ret = (uint64_t)(m->base + 0x17c44c);
        uint32_t code[4] = {0x58000050, 0xD61F0200, 0, 0};   // ldr x16, #8 ; br x16
        uint64_t t = (uint64_t)nx_probe_skip;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0x17c43c, code, 16);
    }
    // NXRT_PASSPROBE=1: pass executor outcomes (cache misses, unbaked lists), src/probe_hooks.S.
    if (getenv("NXRT_PASSPROBE")) {
        extern void nx_probe_passmiss(void), nx_probe_passbaked(void);
        extern uint64_t nx_passprobe[8];
        Module *m = nx_module("main");
        nx_passprobe[5] = (uint64_t)(m->base + 0x1854bc);
        nx_passprobe[6] = (uint64_t)(m->base + 0x18532c);
        nx_passprobe[7] = (uint64_t)(m->base + 0x185398);
        uint32_t code[4] = {0x58000050, 0xD61F0200, 0, 0};   // ldr x16, #8 ; br x16
        uint64_t t = (uint64_t)nx_probe_passmiss;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0x1854ac, code, 16);
        t = (uint64_t)nx_probe_passbaked;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0x18531c, code, 16);
    }
    // NXRT_CHUNKPROBE=<from>-<to>: per-chunk object/mask counts through C probes (src/probe_hooks.S).
    if (getenv("NXRT_CHUNKPROBE")) {
        extern void nx_cp_chunk(void), nx_cp_obj(void);
        extern uint64_t nx_cpret[5];
        Module *m = nx_module("main");
        nx_cpret[0] = (uint64_t)(m->base + 0x178b00 + 16);
        nx_cpret[1] = (uint64_t)(m->base + 0x17a260);
        nx_cpret[2] = (uint64_t)(m->base + 0x17a2cc);
        uint32_t code[4] = {0x58000050, 0xD61F0200, 0, 0};   // ldr x16, #8 ; br x16
        uint64_t t = (uint64_t)nx_cp_chunk;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0x178b00, code, 16);
        t = (uint64_t)nx_cp_obj;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0x17a2bc, code, 16);
        extern void nx_cp_lod(void), nx_cp_ready(void);
        nx_cpret[3] = (uint64_t)(m->base + 0x17a334);
        nx_cpret[4] = (uint64_t)(m->base + 0x17a35c);
        t = (uint64_t)nx_cp_lod;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0x17a324, code, 16);
        t = (uint64_t)nx_cp_ready;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0x17a34c, code, 16);
    }
    // NXRT_OBJPROBE=1: scene-list chunk object filters (src/probe_hooks.S).
    if (getenv("NXRT_OBJPROBE")) {
        extern void nx_probe_obja(void), nx_probe_objb(void), nx_probe_objc(void);
        extern uint64_t nx_objret[4];
        Module *m = nx_module("main");
        nx_objret[0] = (uint64_t)(m->base + 0x17a260);
        nx_objret[1] = (uint64_t)(m->base + 0x17a2cc);
        nx_objret[2] = (uint64_t)(m->base + 0x17a334);
        nx_objret[3] = (uint64_t)(m->base + 0x17a35c);
        uint32_t code[4] = {0x58000050, 0xD61F0200, 0, 0};   // ldr x16, #8 ; br x16
        void (*fns[3])(void) = {nx_probe_obja, nx_probe_objb, nx_probe_objc};
        const uint32_t at[3] = {0x17a2bc, 0x17a324, 0x17a34c};
        for (int i = 0; i < 3; i++) {
            uint64_t t = (uint64_t)fns[i];
            memcpy(&code[2], &t, 8);
            memcpy(m->base + at[i], code, 16);
        }
        extern void nx_probe_objentry(void);
        extern uint64_t nx_chunkret;
        nx_chunkret = (uint64_t)(m->base + 0x178b00 + 16);
        uint64_t t = (uint64_t)nx_probe_objentry;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0x178b00, code, 16);
    }
    // NXRT_RACEPROBE=1: timestamped executor reads / collector appends (src/probe_hooks.S).
    if (getenv("NXRT_RACEPROBE")) {
        extern void nx_probe_raceexec(void), nx_probe_raceapp(void);
        extern uint64_t nx_racering[];
        Module *m = nx_module("main");
        nx_racering[1] = (uint64_t)(m->base + 0x18522c);
        nx_racering[2] = (uint64_t)(m->base + 0x17a0c4);
        nx_racering[3] = (uint64_t)(m->base + 0x17a0cc);
        uint32_t code[4] = {0x58000050, 0xD61F0200, 0, 0};   // ldr x16, #8 ; br x16
        uint64_t t = (uint64_t)nx_probe_raceexec;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0x18521c, code, 16);
        t = (uint64_t)nx_probe_raceapp;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0x17a0b4, code, 16);
        extern void nx_probe_racechunk(void);
        extern uint64_t nx_chunkret;
        nx_chunkret = (uint64_t)(m->base + 0x178b00 + 16);
        t = (uint64_t)nx_probe_racechunk;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0x178b00, code, 16);
    }
    // NXRT_MININTERVAL=<n> (NXRT_FPS=60 means n = 1): the game's frame-rate controller (main+0x28b2b8) keeps the
    // present interval in [min, max] vsyncs, min 2 / max 3 as shipped. n = 1 lets it pick 60 fps where a frame fits
    // 16.7 ms (it falls back to 30/20 by itself); the game step (main+0x5e1be4) advances dt = interval / 60 s per
    // frame, so game speed stays right. Every writer of the min is patched so it stays at n:
    //   main+0x90378c   main() init        mov x8, #2  (movk x8, #3, lsl #32 = max follows)
    //   main+0x1d2af84  reset to 2/3       mov x8, #2  (from main+0x16ba640), main+0x1d2af90 mov w8, #2 (ctl+0x44 copy)
    //   main+0x1b45f04  UGC editor exit    mov w1, #2  (the editor itself sets 1 at main+0x1b45c3c)
    //   main+0x187cda8  script setter, clamps to [1, 4]: cap at n instead (mov w9, #4 / cmp w8, #4)
    {
        const char *e = getenv("NXRT_MININTERVAL"), *fps = getenv("NXRT_FPS");
        uint32_t n = e ? (uint32_t)atoi(e) & 0xffff : fps && atoi(fps) >= 60 ? 1 : 0;
        if (n) {
            Module *m = nx_module("main");
            static const struct { uint32_t off, insn, base; } p[] = {
                {0x90378c, 0xD2800048, 0xD2800008},  // mov x8, #n
                {0x1d2af84, 0xD2800048, 0xD2800008}, // mov x8, #n
                {0x1d2af90, 0x52800048, 0x52800008}, // mov w8, #n
                {0x1b45f04, 0x52800041, 0x52800001}, // mov w1, #n
                {0x187cdc4, 0x52800089, 0x52800009}, // mov w9, #n
                {0x187cdd8, 0x7100111F, 0x7100011F}, // cmp w8, #n (imm12 at bit 10)
            };
            for (size_t i = 0; i < sizeof p / sizeof *p; i++) {
                uint32_t insn;
                memcpy(&insn, m->base + p[i].off, 4);
                if (insn != p[i].insn) nx_fatal("NXRT_MININTERVAL: unexpected code at main+%#x (%#x)", p[i].off, insn);
                insn = p[i].base | n << (p[i].base >> 24 == 0x71 ? 10 : 5);
                memcpy(m->base + p[i].off, &insn, 4);
            }
            nx_log("frame rate: min present interval %u (%u fps max)", n, 60 / n);
        }
    }
    // NXRT_VRR=1: no hysteresis in the frame-rate controller. It turns the last frame's work time
    // [fw+0x118] (frame start -> GPU done, no vsync wait) into target = floor(t * 60 + 0.05) + 1 vsyncs, clamped to
    // [min, max]; as shipped it waits ctl+0xc (2) slow frames before stepping up, then holds ctl+0x10 (6) frames, and
    // steps down only one probe at a time (to ctl+0x44, listeners at ctl+0x68 may veto). Patched: interval = target
    // every frame (main+0x28b32c `ldr w9, [x0, #0x40] ; cmp w10, w9` -> `mov w20, w10 ; b 0x28b358`, the store of
    // ctl+0x40 / 60/interval / fw+0x88 / nvnWindowSetPresentInterval). The step still lags the frame by one, so a
    // frame that overruns its interval plays one short step; pace() (gfx_metal.m) catches the wall clock up.
    if (getenv("NXRT_VRR") && atoi(getenv("NXRT_VRR"))) {
        Module *m = nx_module("main");
        static const uint32_t old[2] = {0xB9404009, 0x6B09015F}, new[2] = {0x2A0A03F4, 0x1400000A};
        if (memcmp(m->base + 0x28b32c, old, 8)) nx_fatal("NXRT_VRR: unexpected code at main+0x28b32c");
        memcpy(m->base + 0x28b32c, new, 8);
        g_vrr = 1;
        nx_log("frame rate: controller hysteresis off (NXRT_VRR): pace() picks each frame's step");
    }
    {   // widescreen (ui_touch.c nx_wide_setup): data writes + the UI camera hooks (in memory here, build time on iOS)
        void nx_wide_setup(Module *m, int patch_code);
        nx_wide_setup(nx_module("main"), 1);
    }
    // NXRT_MAXINTERVAL=<n>: the max half (movk x8, #3, lsl #32 at main+0x903794). With MININTERVAL=1 and
    // MAXINTERVAL=1 the controller can't fall back to 30 on slow frames (game-speed tests at a forced step 1).
    if (getenv("NXRT_MAXINTERVAL")) {
        Module *m = nx_module("main");
        uint32_t n = (uint32_t)atoi(getenv("NXRT_MAXINTERVAL")) & 0xffff, insn;
        memcpy(&insn, m->base + 0x903794, 4);
        if (insn != 0xF2C00068) nx_fatal("NXRT_MAXINTERVAL: unexpected code at main+0x903794 (%#x)", insn);
        insn = 0xF2C00008 | n << 5;   // movk x8, #n, lsl #32
        memcpy(m->base + 0x903794, &insn, 4);
    }
    // NXRT_TICKPROBE=<frame>: who calls nn::os::GetSystemTick (main's PLT stub main+0x25cb8c0, GOT slot
    // main+0x32f7028); nx_tickprobe_frame() prints the callers of the 30 frames from that frame on.
    if (getenv("NXRT_TICKPROBE")) {
        extern void nx_probe_tick(void);
        extern uint64_t nx_tickring[];
        Module *m = nx_module("main");
        nx_tickring[1] = (uint64_t)(m->base + 0x32f7028);
        uint32_t code[4] = {0x58000050, 0xD61F0200, 0, 0};   // ldr x16, #8 ; br x16
        uint64_t t = (uint64_t)nx_probe_tick;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0x25cb8c0, code, 16);
    }
    // NXRT_SAVEPROBE=1: entry probe on the game's save request main+0x1d7bf78 (who asks for a save, with what).
    if (getenv("NXRT_SAVEPROBE")) {
        extern void nx_probe_saverq(void);
        extern uint64_t nx_probe_saverq_ret;
        Module *m = nx_module("main");
        uint32_t want[4] = {0xA9BB7BFD, 0xA90167FC, 0x910003FD, 0xA9025FF8}, have[4];
        memcpy(have, m->base + 0x1d7bf78, 16);
        if (memcmp(want, have, 16)) nx_fatal("NXRT_SAVEPROBE: unexpected code at main+0x1d7bf78 (%08x)", have[0]);
        nx_probe_saverq_ret = (uint64_t)(m->base + 0x1d7bf78 + 16);
        uint32_t code[4] = {0x58000050, 0xD61F0200, 0, 0};   // ldr x16, #8 ; br x16
        uint64_t t = (uint64_t)nx_probe_saverq;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0x1d7bf78, code, 16);
    }
    // NXRT_EXECPROBE=1: entry probe on the pass executor main+0x1850f0 (src/probe_hooks.S).
    if (getenv("NXRT_EXECPROBE")) {
        extern void nx_probe_exec(void);
        extern struct { uint64_t idx, ret, pad[2]; } nx_probe;
        Module *m = nx_module("main");
        nx_probe.ret = (uint64_t)(m->base + 0x1850f0 + 16);
        uint32_t code[4] = {0x58000050, 0xD61F0200, 0, 0};   // ldr x16, #8 ; br x16
        uint64_t t = (uint64_t)nx_probe_exec;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0x1850f0, code, 16);
        extern void nx_probe_viewjob(void);
        extern struct { uint64_t calls, ret, last; } nx_probe2;
        nx_probe2.ret = (uint64_t)(m->base + 0x177b3c + 16);
        t = (uint64_t)nx_probe_viewjob;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0x177b3c, code, 16);
        extern void nx_probe_stage(void);
        extern struct { uint64_t calls, ret, last; } nx_probe3;
        nx_probe3.ret = (uint64_t)(m->base + 0x183688 + 16);
        t = (uint64_t)nx_probe_stage;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0x183688, code, 16);
        extern void nx_probe_stagecb(void);
        extern struct { uint64_t calls, ret, pad[2]; } nx_probe4;
        nx_probe4.ret = (uint64_t)(m->base + 0x182ddc + 16);
        t = (uint64_t)nx_probe_stagecb;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0x182ddc, code, 16);
        extern void nx_probe_statem(void);
        extern struct { uint64_t calls, ret, last; } nx_probe5;
        nx_probe5.ret = (uint64_t)(m->base + 0x292894 + 16);
        t = (uint64_t)nx_probe_statem;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0x292894, code, 16);
        extern void nx_probe_seq(void);
        extern struct { uint64_t calls, ret, last; } nx_probe6;
        nx_probe6.ret = (uint64_t)(m->base + 0x7ad02c + 16);
        t = (uint64_t)nx_probe_seq;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0x7ad02c, code, 16);
        extern void nx_probe_boot(void);
        extern struct { uint64_t calls, ret, last; } nx_probe7;
        nx_probe7.ret = (uint64_t)(m->base + 0xa62a80 + 16);
        t = (uint64_t)nx_probe_boot;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + 0xa62a80, code, 16);
    }
    for (unsigned h = 0; h < sizeof hooks / sizeof *hooks; h++) {
        Module *m = nx_module(hooks[h].mod);
        uint32_t code[4] = {0x58000050, 0xD61F0200, 0, 0};   // ldr x16, #8 ; br x16
        uint64_t t = (uint64_t)hooks[h].target;
        memcpy(&code[2], &t, 8);
        memcpy(m->base + hooks[h].off, code, 16);
    }

    acqrel_check(getenv("NXRT_ACQREL") && atoi(getenv("NXRT_ACQREL")));

    // Text (and the read-only data sharing its last page) executable; everything else
    // writable, since rtld relocates data in place.
    for (int i = 0; i < g_image.nmod; i++) {
        Module *m = &g_image.mod[i];
        size_t rx = PAGE_UP(m->text_size);
        sys_icache_invalidate(m->base, rx);
        if (mprotect(m->base, rx, PROT_READ | PROT_EXEC))
            nx_fatal("mprotect RX %s", m->name);
        nx_log("module %-8s %p..%p  text %#zx ro %#zx+%#zx data %#zx+%#zx bss %#zx", m->name,
               m->base, m->base + m->size, m->text_size, m->ro_off, m->ro_size, m->data_off,
               m->data_size, m->bss_size);
    }
    return 0;
}

Module *nx_module(const char *name) {
    for (int i = 0; i < g_image.nmod; i++)
        if (!strcmp(g_image.mod[i].name, name)) return &g_image.mod[i];
    return NULL;
}

// The trampolines read the TSD key offset and the svc_entry address from a table in
// subsdk9's data (nsobuild.py RT_TABLE); its offset is stored at text + 0x80.
void nx_set_runtime_table(uint64_t tsd_key_off, void *svc_entry) {
    Module *m = nx_module("subsdk9");
    uint32_t off;
    memcpy(&off, m->base + 0x80, 4);
    uint8_t *tbl = m->base + off;
    if (memcmp(tbl, "NXRTTBL1", 8)) nx_fatal("runtime table magic missing");
    memcpy(tbl + 8, &tsd_key_off, 8);
    uint64_t e = (uint64_t)svc_entry;
    memcpy(tbl + 16, &e, 8);
}

// NXRT_TICKPROBE=<frame>: called once per present; counts GetSystemTick callers over 30 frames.
static int cmp_u64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}
void nx_tickprobe_frame(int frame) {
    static int start = -2;
    static uint64_t from;
    if (start == -2) start = getenv("NXRT_TICKPROBE") ? atoi(getenv("NXRT_TICKPROBE")) : -1;
    if (start < 0) return;
    extern uint64_t nx_tickring[];
    uint64_t now = __atomic_load_n(&nx_tickring[0], __ATOMIC_ACQUIRE);
    if (frame == start) from = now;
    if (frame != start + 30) return;
    uint64_t n = now - from;
    if (n > 65536) { nx_log("tickprobe: %llu calls in 30 frames, ring too small", (unsigned long long)n); n = 65536; }
    uint64_t *v = malloc(n * 8);
    for (uint64_t i = 0; i < n; i++) v[i] = nx_tickring[2 + ((from + i) & 0xffff)];
    qsort(v, n, 8, cmp_u64);
    Module *m = nx_module("main");
    nx_log("tickprobe: %llu GetSystemTick calls in frames %d..%d", (unsigned long long)n, start, start + 30);
    for (uint64_t i = 0; i < n;) {
        uint64_t j = i;
        while (j < n && v[j] == v[i]) j++;
        uint64_t a = v[i];
        if (a >= (uint64_t)m->base && a < (uint64_t)m->base + m->size)
            nx_log("tickprobe:   main+%#llx  %llu calls (%.1f/frame)", (unsigned long long)(a - (uint64_t)m->base), (unsigned long long)(j - i), (j - i) / 30.0);
        else nx_log("tickprobe:   %#llx  %llu calls", (unsigned long long)a, (unsigned long long)(j - i));
        i = j;
    }
    free(v);
}

uint64_t nx_probe_saverq_ret;
void nx_backtrace_from(uint64_t fp);
void nx_saveprobe_hit(uint64_t mgr, uint64_t x1, uint64_t cb, uint64_t async, uint64_t lr, uint64_t fp) {
    extern volatile int g_gfx_frame;
    Module *m = nx_module("main");
    nx_log("save: frame %d: SAVE REQUEST main+0x1d7bf78(mgr %#llx, x1 %#llx, callback %#llx (vtable main+%#llx), async %llu) "
           "from main+%#llx; mgr+0x94c state %u, +0x950 count %u", g_gfx_frame, (unsigned long long)mgr,
           (unsigned long long)x1, (unsigned long long)cb,
           cb ? (unsigned long long)(*(uint64_t *)cb - (uint64_t)m->base) : 0ull, (unsigned long long)(async & 1),
           (unsigned long long)(lr - (uint64_t)m->base), *(uint32_t *)(mgr + 0x94c), *(uint32_t *)(mgr + 0x950));
    nx_backtrace_from(fp);
}
