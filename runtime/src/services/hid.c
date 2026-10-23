// hid — input. The SDK reads controller state from a 0x40000-byte shared memory block
// (ring buffers per device). Player 1 is a Pro Controller; nx_hid_frame refreshes it every frame.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include <pthread.h>
#include "ipc.h"

extern const ServiceDef svc_hid;

static KShmem *g_hid_shm;
static uint32_t g_hid_shm_handle;

KShmem *nx_hid_shared_memory(void) {
    if (!g_hid_shm) g_hid_shm = nx_shmem_new(0x40000, &g_hid_shm_handle);
    return g_hid_shm;
}

// ---- a connected, idle Pro Controller in Player 1's npad block ---------------------
// npad block i at +0x9A00 + i*0x5000 (SDK NpadSharedMemoryAccessor::Attach). Inside
// (libnx HidNpadInternalState): +0x0 style set, +0x4 joy assignment mode, +0x8 full-key
// color, +0x14 joy color, +0x28 full-key LIFO (header 0x20 + 17 entries of 0x30), then
// handheld, dual, left, right, palma, system-ext LIFOs (0x350 each), six-axis LIFOs, ...
#define NPAD_BASE 0x9A00
#define NPAD_SIZE 0x5000
#define LIFO_FULLKEY 0x28
#define LIFO_SIZE 0x350
#define NPAD_DEVICE_TYPE 0x4128          // after 7 common LIFOs + 6 six-axis LIFOs (0x6F8 each)

static uint64_t g_sampling;
static int32_t g_stick[2];   // left stick, -32767..32767 (window keyboard input)
// Touch layer (ui_touch.c): buttons it holds, and a stick that replaces the controller's while on.
static volatile uint64_t g_ui_buttons;
static volatile int32_t g_ui_stick[2], g_ui_stick_on;
static volatile int32_t g_rstick[2];   // right stick: touch layer (pinch / two-finger pan) or NXRT_AUTORSTICK
void nx_hid_rstick(int x, int y) { g_rstick[0] = x, g_rstick[1] = y; }
void nx_hid_ui(uint64_t buttons, int stick_on, int x, int y) {
    g_ui_buttons = buttons;
    g_ui_stick[0] = x, g_ui_stick[1] = y;
    g_ui_stick_on = stick_on;
}

// A real history: one new sample per call in a 17-entry ring, tail = newest. Games find button
// presses by comparing consecutive states (GetNpadStates returns up to 16), so every entry must
// hold the state of its own sample. (Writing the current state into all 17 entries made the
// history all "held": no press edges.)
static uint64_t g_hist_buttons[17];
static int32_t g_hist_stick[17][2], g_hist_rstick[17][2];

// NXRT_HANDHELD=1: the controller is the console with Joy-Cons attached (NpadIdType Handheld,
// npad block 8, handheld LIFO right after the full-key one) instead of a Pro Controller as Player 1.
static int handheld(void) {
    static int h = -1;
    if (h < 0) h = getenv("NXRT_HANDHELD") != NULL;
    return h;
}
#define NPAD_HANDHELD_BLOCK (NPAD_BASE + 8 * NPAD_SIZE)

static void write_fullkey_lifo(uint64_t buttons) {
    KShmem *shm = nx_hid_shared_memory();
    uint64_t base = handheld() ? NPAD_HANDHELD_BLOCK + LIFO_FULLKEY + LIFO_SIZE : NPAD_BASE + LIFO_FULLKEY;
    if (!g_sampling) g_sampling = 16;                      // entries 0..16 start as idle samples 0..16
    g_sampling++;
    uint32_t tail = g_sampling % 17;
    g_hist_buttons[tail] = buttons;
    if (g_ui_stick_on) memcpy(g_hist_stick[tail], (const void *)g_ui_stick, 8);
    else memcpy(g_hist_stick[tail], g_stick, 8);
    memcpy(g_hist_rstick[tail], (const void *)g_rstick, 8);
    for (uint32_t i = 0; i < 17; i++) {
        uint8_t e[0x30] = {0};
        // The SDK reads entries as a seqlock: an odd storage sampling number means
        // "being written" (nn::hid::detail::GetNpadStates retries), so keep them even.
        // Walking back from the tail, sampling numbers drop by exactly 1 per entry.
        uint64_t m = g_sampling - (tail + 17 - i) % 17, seq = m * 2;
        memcpy(e, &seq, 8);                                // atomic storage sequence (even)
        memcpy(e + 8, &m, 8);                              // state.sampling_number
        memcpy(e + 16, &g_hist_buttons[i], 8);             // state.buttons
        memcpy(e + 24, g_hist_stick[i], 8);                // state.analog_stick_l (x, y)
        memcpy(e + 32, g_hist_rstick[i], 8);               // state.analog_stick_r
        uint32_t attrs = handheld() ? 0x3F : 1 | 2;        // IsConnected | IsWired (+ left/right connected, wired)
        memcpy(e + 8 + 0x20, &attrs, 4);                   // state.attributes
        nx_shmem_write(shm, base + 0x20 + i * 0x30, e, sizeof e);
    }
    uint64_t hdr[4] = {0, 17, tail, 17};                   // unused, buffer count, tail, count
    nx_shmem_write(shm, base, hdr, sizeof hdr);
}

// Called once per presented frame: refresh Player 1's full-key LIFO with the current buttons
// (bit 0 A, 1 B, 2 X, 3 Y, 10 Plus, 11 Minus, 12-15 D-pad L/U/R/D as in nn::hid::NpadButton).
// NXRT_AUTOPRESS=<button>[,<button>...] (headless testing; "1" means A): from frame 300, press each
// button for 6 frames, 30 frames apart, and repeat the sequence every 120 frames.
// NXRT_AUTOPRESS_UNTIL=<frame>: stop pressing after that frame (comparable screenshots across runs).
static void write_touch_lifo(void);
static void write_gesture_lifo(void);
void nx_hid_set_touch(int down, int x, int y);
static volatile int g_touch_down, g_touch_tap;
static volatile uint32_t g_touch_x, g_touch_y;
static uint64_t g_buttons, g_latched;   // latched: pressed since the last sample (taps shorter than a frame)
void nx_hid_set_buttons(uint64_t buttons) {
    __atomic_fetch_or(&g_latched, buttons & ~g_buttons, __ATOMIC_RELAXED);
    g_buttons = buttons;
}
void nx_hid_set_stick(int x, int y) { g_stick[0] = x, g_stick[1] = y; }
// Hold buttons for that many samples (a tap on a button prompt, ui_touch.c).
static uint64_t g_hold;
static int g_hold_n;
void nx_hid_press(uint64_t bits, int frames) {
    g_hold = bits;
    __atomic_store_n(&g_hold_n, frames, __ATOMIC_RELEASE);
}
static uint64_t button_bit(const char *n) {
    static const char *const names[] = {"A", "B", "X", "Y", "LSTICK", "RSTICK", "L", "R", "ZL", "ZR", "PLUS", "MINUS",
                                        "LEFT", "UP", "RIGHT", "DOWN"};
    for (int i = 0; i < 16; i++)
        if (!strcasecmp(n, names[i])) return 1ull << i;
    return !strcmp(n, "1") ? 1 : 0;
}
void nx_hid_frame(int frame) {
    static uint64_t seq[4];
    static int nseq = -1;
    if (nseq < 0) {
        nseq = 0;
        const char *e = getenv("NXRT_AUTOPRESS");
        char buf[128];
        snprintf(buf, sizeof buf, "%s", e ? e : "");
        for (char *t = strtok(buf, ","); t && nseq < 4; t = strtok(NULL, ",")) seq[nseq++] = button_bit(t);
    }
    uint64_t b = g_buttons | __atomic_exchange_n(&g_latched, 0, __ATOMIC_RELAXED);
    if (__atomic_load_n(&g_hold_n, __ATOMIC_ACQUIRE) > 0) b |= g_hold, g_hold_n--;
    b |= g_ui_buttons;
    int slot = (frame % 120) / 30;
    static int until = -2;
    if (until == -2) until = getenv("NXRT_AUTOPRESS_UNTIL") ? atoi(getenv("NXRT_AUTOPRESS_UNTIL")) : -1;
    if (nseq && frame >= 300 && (until < 0 || frame <= until) && slot < nseq && frame % 30 < 6) {
        b |= seq[slot];
        if (frame % 30 == 0) nx_log("hid: autopress %#llx (frame %d)", (unsigned long long)seq[slot], frame);
    }
    // NXRT_PRESS_AT=<frame>:<button>[:<frames held, default 3>][,...]: one-shot presses (scripted UI tests).
    static int npa = -1, pa[64][3];
    if (npa < 0) {
        npa = 0;
        const char *e = getenv("NXRT_PRESS_AT");
        char buf[2048], name[16];
        snprintf(buf, sizeof buf, "%s", e ? e : "");
        for (char *t = strtok(buf, ","); t && npa < 64; t = strtok(NULL, ",")) {
            int f, held = 3;
            if (sscanf(t, "%d:%15[A-Za-z0-9]:%d", &f, name, &held) >= 2) {
                pa[npa][0] = f, pa[npa][1] = (int)__builtin_ctzll(button_bit(name) | (1ull << 63)), pa[npa][2] = held;
                npa++;
            }
        }
    }
    for (int i = 0; i < npa; i++)
        if (frame >= pa[i][0] && frame < pa[i][0] + pa[i][2] && pa[i][1] < 63) {
            b |= 1ull << pa[i][1];
            if (frame == pa[i][0]) nx_log("hid: press-at %d (frame %d)", pa[i][1], frame);
        }
    // NXRT_AUTOSTICK=<from>:<to>:<x>:<y>[,...]: hold the left stick at (x, y) (-32767..32767) for those
    // frames (headless camera-movement tests).
    static int nst = -1, st[8][4];
    if (nst < 0) {
        nst = 0;
        const char *e = getenv("NXRT_AUTOSTICK");
        char buf[256];
        snprintf(buf, sizeof buf, "%s", e ? e : "");
        for (char *t = strtok(buf, ","); t && nst < 8; t = strtok(NULL, ","))
            if (sscanf(t, "%d:%d:%d:%d", &st[nst][0], &st[nst][1], &st[nst][2], &st[nst][3]) == 4) nst++;
    }
    for (int i = 0; i < nst; i++)
        if (frame >= st[i][0] && frame <= st[i][1]) {
            g_stick[0] = st[i][2], g_stick[1] = st[i][3];
            b |= (st[i][2] < 0 ? 1ull << 16 : 0) | (st[i][3] > 0 ? 1ull << 17 : 0) | (st[i][2] > 0 ? 1ull << 18 : 0) | (st[i][3] < 0 ? 1ull << 19 : 0);
            break;
        } else if (frame == st[i][1] + 1) g_stick[0] = g_stick[1] = 0;
    // NXRT_AUTORSTICK=<from>:<to>:<x>:<y>[,...]: the right stick, same format (camera tests).
    static int nrs = -1, rs[8][4];
    if (nrs < 0) {
        nrs = 0;
        const char *e = getenv("NXRT_AUTORSTICK");
        char buf[256];
        snprintf(buf, sizeof buf, "%s", e ? e : "");
        for (char *t = strtok(buf, ","); t && nrs < 8; t = strtok(NULL, ","))
            if (sscanf(t, "%d:%d:%d:%d", &rs[nrs][0], &rs[nrs][1], &rs[nrs][2], &rs[nrs][3]) == 4) nrs++;
    }
    for (int i = 0; i < nrs; i++)
        if (frame >= rs[i][0] && frame <= rs[i][1]) g_rstick[0] = rs[i][2], g_rstick[1] = rs[i][3];
        else if (frame == rs[i][1] + 1) g_rstick[0] = g_rstick[1] = 0;
    // NXRT_INPUTREC=<file>: record every change of buttons, left stick and touch as
    // "<frame> <buttons hex> <stick x> <stick y> <touch down> <touch x> <touch y>" lines.
    // NXRT_INPUTPLAY=<file>: replay such a recording (replaces live input; the last line holds until the next).
    static FILE *rec, *play;
    static int recinit;
    static long pl[8] = {-1};
    if (!recinit) {
        recinit = 1;
        if (getenv("NXRT_INPUTREC")) rec = fopen(getenv("NXRT_INPUTREC"), "w");
        if (getenv("NXRT_INPUTPLAY")) play = fopen(getenv("NXRT_INPUTPLAY"), "r");
        if (rec) nx_log("hid: recording input to %s", getenv("NXRT_INPUTREC"));
        if (play) nx_log("hid: replaying input from %s", getenv("NXRT_INPUTPLAY"));
    }
    if (play) {
        static long cur[7], next[7];
        static int have_next, done;
        for (;;) {
            if (!have_next && !done) {
                unsigned long long bb;
                have_next = fscanf(play, "%ld %llx %ld %ld %ld %ld %ld", &next[0], &bb, &next[2], &next[3], &next[4], &next[5], &next[6]) == 7;
                next[1] = (long)bb;
                if (!have_next) done = 1;
            }
            if (have_next && next[0] <= frame) memcpy(cur, next, sizeof cur), have_next = 0;
            else break;
        }
        b = (uint64_t)cur[1];
        g_stick[0] = (int32_t)cur[2], g_stick[1] = (int32_t)cur[3];
        nx_hid_set_touch((int)cur[4], (int)cur[5], (int)cur[6]);
    }
    if (rec) {
        long now[7] = {frame, (long)b, g_stick[0], g_stick[1], g_touch_down || g_touch_tap, g_touch_x, g_touch_y};
        if (memcmp(now + 1, pl + 1, 6 * sizeof(long))) {
            fprintf(rec, "%ld %llx %ld %ld %ld %ld %ld\n", now[0], (unsigned long long)now[1], now[2], now[3], now[4], now[5], now[6]);
            fflush(rec);
            memcpy(pl, now, sizeof pl < sizeof now ? sizeof pl : sizeof now);
        }
    }
    static int inlog = -1;                         // NXRT_FSLOG=1 also logs button changes (to line up with reads)
    static uint64_t lastb;
    if (inlog < 0) inlog = getenv("NXRT_FSLOG") != NULL;
    if (inlog && (b & 0xFFFF) != lastb) nx_log("hid: frame %d buttons %#llx", frame, (unsigned long long)(b & 0xFFFF));
    lastb = b & 0xFFFF;
    if (g_hid_shm) {
        write_fullkey_lifo(b);
        write_touch_lifo();
        static int gest = -1;
        if (gest < 0) gest = getenv("NXRT_NOGESTURE") == NULL;
        if (gest) write_gesture_lifo();
    }
}

// ---- touch screen (window mouse / iOS touches) -------------------------------------------
// Shared memory +0x400 (libnx HidTouchScreenSharedMemoryFormat): LIFO header 0x20, then 17 entries
// of 0x298 = {u64 storage sampling number, HidTouchScreenState}. State: u64 sampling number,
// s32 count, u32 pad, 16 x HidTouchState (0x28: u64 delta time, u32 attributes (1 start, 2 end),
// u32 finger id, u32 x, u32 y (1280x720 space), u32 diameter x/y, u32 angle, u32 pad).
#define TOUCH_BASE 0x400
#define TOUCH_ENTRY 0x298
typedef struct { int down; uint32_t x, y, attrs; } TouchSample;
static TouchSample g_touch_hist[17];
static uint64_t g_touch_sampling;
// g_touch_down (finger on the screen now), g_touch_x/y, g_touch_tap (a press since the last sample): declared above
static int g_touch_was_down;

void nx_hid_set_touch(int down, int x, int y) {
    if (x < 0) x = 0;
    if (x > 1279) x = 1279;
    if (y < 0) y = 0;
    if (y > 719) y = 719;
    g_touch_x = (uint32_t)x;
    g_touch_y = (uint32_t)y;
    if (down && !g_touch_down) g_touch_tap = 1;
    g_touch_down = down;
}

static void write_touch_lifo(void) {
    if (!g_touch_sampling) g_touch_sampling = 16;
    g_touch_sampling++;
    uint32_t tail = g_touch_sampling % 17;
    int down = g_touch_down || g_touch_tap;
    TouchSample t = {down, g_touch_x, g_touch_y, 0};
    if (down && !g_touch_was_down) t.attrs = 1;                     // Start
    else if (!down && g_touch_was_down) {                           // End: one sample with the finger lifting
        t = g_touch_hist[(tail + 16) % 17];
        t.attrs = 2;
        t.down = 1;
    }
    g_touch_tap = 0;
    g_touch_was_down = down;
    g_touch_hist[tail] = t;
    KShmem *shm = nx_hid_shared_memory();
    for (uint32_t i = 0; i < 17; i++) {
        uint8_t e[TOUCH_ENTRY] = {0};
        uint64_t m = g_touch_sampling - (tail + 17 - i) % 17, seq = m * 2;
        TouchSample *h = &g_touch_hist[i];
        int32_t count = h->down ? 1 : 0;
        memcpy(e, &seq, 8);                                         // storage sampling number (even)
        memcpy(e + 8, &m, 8);                                       // state.sampling_number
        memcpy(e + 16, &count, 4);
        if (count) {
            uint8_t *f = e + 24;                                    // touches[0]
            // delta time: one 60 Hz sample in ns (0 made the game's touch speed math divide by zero and spin forever
            // once gestures woke its touch handling up)
            uint64_t dt = 16666667;
            uint32_t w[8] = {h->attrs, 0, h->x, h->y, 15, 15, 0, 0};   // finger 0, 15 px contact
            memcpy(f, &dt, 8);
            memcpy(f + 8, w, sizeof w);
        }
        nx_shmem_write(shm, TOUCH_BASE + 0x20 + i * TOUCH_ENTRY, e, sizeof e);
    }
    uint64_t hdr[4] = {0, 17, tail, 17};
    nx_shmem_write(shm, TOUCH_BASE, hdr, sizeof hdr);
}

// ---- gestures (taps) ----------------------------------------------------------------------------
// The game reads taps as gestures (it calls ActivateGesture / SetGestureOutputRanges), not raw touch points: with only
// the touch LIFO filled, taps did nothing (and its "touch disabled" icon showed). Shared memory +0x3BA00 (libnx
// HidGestureSharedMemoryFormat): LIFO header 0x20, then 17 entries of 0x68 = {u64 storage sampling number,
// HidGestureState: u64 sampling number, u64 context number, u32 type, u32 direction, u32 x, u32 y, s32 delta x/y,
// f32 velocity x/y, u32 attributes, f32 scale, f32 rotation, s32 point count, 4 x {u32 x, u32 y}}.
// Recognizer (as the system's): finger down -> Touch (attribute IsNewTouch, new context); held -> Touch, or Pan once
// it moved more than a few pixels; lifted -> Tap if it never panned, else Complete; then Idle.
#define GESTURE_BASE 0x3BA00
#define GESTURE_ENTRY 0x68
enum { G_IDLE, G_COMPLETE, G_CANCEL, G_TOUCH, G_PRESS, G_TAP, G_PAN, G_SWIPE };
typedef struct {
    uint64_t context;
    uint32_t type, x, y, attrs;
    int32_t dx, dy, points;
} GestureSample;
static GestureSample g_gest_hist[17];
static uint64_t g_gest_sampling, g_gest_context;
static int g_gest_active, g_gest_panned;
static uint32_t g_gest_x0, g_gest_y0, g_gest_lx, g_gest_ly;

static uint32_t g_gest_count;   // entries in the ring (0 until the first touch, at most 16)
static int g_gest_idle_pending;   // one Idle entry after a gesture ended
static void write_gesture_lifo(void) {
    int down = g_touch_down || g_touch_tap;
    uint32_t x = g_touch_x, y = g_touch_y;
    GestureSample gs = {g_gest_context, G_IDLE, 0, 0, 0, 0, 0, 0};
    // Like the system (and yuzu): a new entry only when something happens, not an Idle entry every frame (with idle
    // entries from boot on the game spun forever right after its first frames).
    if (down && !g_gest_active) {                      // finger down: a new gesture
        g_gest_active = 1, g_gest_panned = 0;
        g_gest_x0 = g_gest_lx = x, g_gest_y0 = g_gest_ly = y;
        gs.context = ++g_gest_context;
        gs.type = G_TOUCH, gs.attrs = 1u << 4;           // IsNewTouch
        gs.x = x, gs.y = y, gs.points = 1;
    } else if (down) {                                 // held: Touch until it moves, then Pan
        int32_t mx = (int32_t)x - (int32_t)g_gest_x0, my = (int32_t)y - (int32_t)g_gest_y0;
        if (!g_gest_panned && mx * mx + my * my > 8 * 8) g_gest_panned = 1;
        gs.type = g_gest_panned ? G_PAN : G_TOUCH;
        gs.x = x, gs.y = y, gs.points = 1;
        gs.dx = (int32_t)x - (int32_t)g_gest_lx, gs.dy = (int32_t)y - (int32_t)g_gest_ly;
        g_gest_lx = x, g_gest_ly = y;
    } else if (g_gest_active) {                        // lifted
        g_gest_active = 0, g_gest_idle_pending = 1;
        gs.type = g_gest_panned ? G_COMPLETE : G_TAP;
        gs.x = g_gest_lx, gs.y = g_gest_ly;
    } else if (g_gest_idle_pending) {
        g_gest_idle_pending = 0;
    } else return;                                     // nothing new
    if (!g_gest_sampling) g_gest_sampling = 0;
    g_gest_sampling++;
    uint32_t tail = g_gest_sampling % 17;
    if (g_gest_count < 16) g_gest_count++;
    g_gest_hist[tail] = gs;
    uint8_t e[GESTURE_ENTRY] = {0};
    uint64_t m = g_gest_sampling;
    float scale = 1.0f;
    // storage sampling number: a seqlock for the SDK reader (sdk+0x505998 retries while it is odd), so 2x the state's
    uint64_t seq = m * 2;
    memcpy(e, &seq, 8);
    memcpy(e + 8, &m, 8);                              // state.sampling_number
    memcpy(e + 16, &gs.context, 8);
    memcpy(e + 24, &gs.type, 4);
    memcpy(e + 32, &gs.x, 4);                          // (+28 direction: 0)
    memcpy(e + 36, &gs.y, 4);
    memcpy(e + 40, &gs.dx, 4);
    memcpy(e + 44, &gs.dy, 4);                         // (+48, +52 velocity: 0)
    memcpy(e + 56, &gs.attrs, 4);
    memcpy(e + 60, &scale, 4);                         // (+64 rotation angle: 0)
    memcpy(e + 68, &gs.points, 4);
    if (gs.points) {
        memcpy(e + 72, &gs.x, 4);
        memcpy(e + 76, &gs.y, 4);
    }
    KShmem *shm = nx_hid_shared_memory();
    nx_shmem_write(shm, GESTURE_BASE + 0x20 + tail * GESTURE_ENTRY, e, sizeof e);
    uint64_t hdr[4] = {0, 17, tail, g_gest_count};
    nx_shmem_write(shm, GESTURE_BASE, hdr, sizeof hdr);
}

static void connect_handheld(void) {
    KShmem *shm = nx_hid_shared_memory();
    uint32_t style = 2;                                    // NpadStyleTag Handheld
    uint32_t assign = 0;                                   // dual
    uint32_t color[3] = {0, 0x2D2D2D, 0xE6E6E6};
    nx_shmem_write(shm, NPAD_HANDHELD_BLOCK + 0x0, &style, 4);
    nx_shmem_write(shm, NPAD_HANDHELD_BLOCK + 0x4, &assign, 4);
    nx_shmem_write(shm, NPAD_HANDHELD_BLOCK + 0x8, color, sizeof color);
    nx_shmem_write(shm, NPAD_HANDHELD_BLOCK + 0x14, color, sizeof color);   // joy colors (left / right)
    uint32_t device = 4 | 8;                               // DeviceType HandheldLeft | HandheldRight
    nx_shmem_write(shm, NPAD_HANDHELD_BLOCK + NPAD_DEVICE_TYPE, &device, 4);
    write_fullkey_lifo(0);
    nx_log("hid: Handheld = console with Joy-Cons attached (NXRT_HANDHELD)");
}

static void connect_pro_controller(void) {
    if (handheld()) { connect_handheld(); return; }
    KShmem *shm = nx_hid_shared_memory();
    uint32_t style = 1;                                    // NpadStyleTag FullKey
    uint32_t assign = 0;                                   // dual
    uint32_t color[3] = {0, 0x2D2D2D, 0xE6E6E6};           // attribute ok, main, sub
    nx_shmem_write(shm, NPAD_BASE + 0x0, &style, 4);
    nx_shmem_write(shm, NPAD_BASE + 0x4, &assign, 4);
    nx_shmem_write(shm, NPAD_BASE + 0x8, color, sizeof color);
    uint32_t device = 1;                                   // DeviceType FullKey
    nx_shmem_write(shm, NPAD_BASE + NPAD_DEVICE_TYPE, &device, 4);
    write_fullkey_lifo(0);
    nx_log("hid: Player 1 = connected Pro Controller (idle)");
}

static void ok(SvcObj *o, IpcReq *rq, IpcResp *rs) {}
static void obj(IpcResp *rs, const char *iface) { ipc_push_object(rs, nx_obj_new(&svc_hid, iface, NULL)); }
static void event(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    uint32_t h;
    nx_event_new_readable(&h);
    ipc_push_copy(rs, h);
}
static void u32_0(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)0); }
static void u64_0(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint64_t)0); }

static void create_applet_resource(SvcObj *o, IpcReq *rq, IpcResp *rs) { obj(rs, "IAppletResource"); }
static void get_shared_memory(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    nx_hid_shared_memory();
    ipc_push_copy(rs, g_hid_shm_handle);
}
static uint32_t g_style_set = 0x1F;
static uint64_t g_hold_type;
static void set_style_set(SvcObj *o, IpcReq *rq, IpcResp *rs) { g_style_set = IN(uint32_t, 0); }
static void supported_style_set(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, g_style_set); }
// NpadCondition lives in shared memory at +0x3E200 (from the SDK's own
// NpadSharedMemoryAccessor::Attach): +0x8 hold type, +0xC initialized.
#define NPAD_CONDITION 0x3E200
static void write_npad_condition(void) {
    uint32_t hold = (uint32_t)g_hold_type;
    uint8_t init = 1;
    nx_shmem_write(nx_hid_shared_memory(), NPAD_CONDITION + 0x8, &hold, 4);
    nx_shmem_write(nx_hid_shared_memory(), NPAD_CONDITION + 0xC, &init, 1);
}
static void set_hold_type(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    g_hold_type = IN(uint64_t, 8);                         // (aruid, hold type)
    write_npad_condition();
}
static void activate_npad(SvcObj *o, IpcReq *rq, IpcResp *rs) { write_npad_condition(); connect_pro_controller(); }
static void joy_hold_type(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, g_hold_type); }
static void vibration_device_info(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)1); OUT(rs, (uint32_t)0); }
static void create_vibration_list(SvcObj *o, IpcReq *rq, IpcResp *rs) { obj(rs, "IActiveVibrationDeviceList"); }
// Vibration (HD rumble): nn::hid::VibrationValue = {amp low, freq low, amp high, freq high} per device handle. Handheld
// mode has two (left/right): the strongest of the latest values is kept for the host (iOS: Core Haptics, app_ios.m
// polls nx_vibration_get). NXRT_VIBLOG=1 logs value changes.
static float g_vib[8][4];      // latest value per handle slot (handle & 7)
static uint32_t g_vib_serial;  // bumped on every send
static float g_vib_peak[2];    // strongest band since the last nx_vibration_get (amp, freq): the game's pulses are often
                               // on and off again within a few ms, between the host's 10 ms polls. NXRT_VIB_NOLATCH=1: off
static pthread_mutex_t g_vib_lock = PTHREAD_MUTEX_INITIALIZER;
static void vib_set(uint32_t handle, const float v[4]) {
    pthread_mutex_lock(&g_vib_lock);
    memcpy(g_vib[handle & 7], v, 16);
    g_vib_serial++;
    for (int b = 0; b < 4; b += 2)
        if (v[b] > g_vib_peak[0]) g_vib_peak[0] = v[b], g_vib_peak[1] = v[b + 1];
    pthread_mutex_unlock(&g_vib_lock);
    static int log = -1;
    static float last[2];
    if (log < 0) log = getenv("NXRT_VIBLOG") != NULL;
    float amp = v[0] > v[2] ? v[0] : v[2];
    if (log && (amp > 0) != (last[0] > 0)) nx_log("hid: vibration handle %#x amp %.2f@%.0fHz / %.2f@%.0fHz", handle, v[0], v[1], v[2], v[3]);
    last[0] = amp;
}
// The combined value: amplitude = the strongest band of all handles, frequency = that band's frequency.
void nx_vibration_get(float *amp, float *freq) {
    float a = 0, f = 160;
    pthread_mutex_lock(&g_vib_lock);
    for (int i = 0; i < 8; i++) {
        if (g_vib[i][0] > a) a = g_vib[i][0], f = g_vib[i][1];
        if (g_vib[i][2] > a) a = g_vib[i][2], f = g_vib[i][3];
    }
    static int nolatch = -1;
    if (nolatch < 0) nolatch = getenv("NXRT_VIB_NOLATCH") != NULL;
    if (!nolatch && g_vib_peak[0] > a) a = g_vib_peak[0], f = g_vib_peak[1];
    g_vib_peak[0] = 0;
    pthread_mutex_unlock(&g_vib_lock);
    *amp = a, *freq = f;
}
static void send_vibration_value(SvcObj *o, IpcReq *rq, IpcResp *rs) {   // (handle u32, VibrationValue at +4, aruid)
    float v[4];
    memcpy(v, rq->data + 4, 16);
    vib_set(IN(uint32_t, 0), v);
}
static void send_vibration_values(SvcObj *o, IpcReq *rq, IpcResp *rs) {   // X buffers: handles[], values[]
    IpcBuf *hb = rq->num_x >= 2 ? &rq->x[0] : rq->num_a >= 2 ? &rq->a[0] : NULL, *vb = hb ? hb + 1 : NULL;
    if (!hb || !hb->addr || !vb->addr) return;
    size_t n = hb->size / 4;
    if (vb->size / 16 < n) n = vb->size / 16;
    for (size_t i = 0; i < n && i < 8; i++) vib_set(((const uint32_t *)hb->addr)[i], (const float *)vb->addr + 4 * i);
}
static void u32_1(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)1); }
static void player_led(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint64_t)1); }
static void sixaxis_handles(SvcObj *o, IpcReq *rq, IpcResp *rs) {}

static const IpcCmd cmds[] = {
    {NULL, 0, create_applet_resource},
    {NULL, 1, ok},                                        // ActivateDebugPad
    {NULL, 11, ok},                                       // ActivateTouchScreen
    {NULL, 21, ok},                                       // ActivateMouse
    {NULL, 31, ok},                                       // ActivateKeyboard
    {NULL, 32, ok},                                       // SendKeyboardLockKeyEvent
    {NULL, 40, event},                                    // AcquireXpadIdEventHandle
    {NULL, 51, ok},                                       // ActivateXpad
    {NULL, 66, ok},                                       // StartSixAxisSensor
    {NULL, 67, ok},                                       // StopSixAxisSensor
    {NULL, 68, u32_0},                                    // IsSixAxisSensorFusionEnabled
    {NULL, 69, ok},                                       // EnableSixAxisSensorFusion
    {NULL, 70, ok},                                       // SetSixAxisSensorFusionParameters
    {NULL, 79, ok},                                       // SetGyroscopeZeroDriftMode
    {NULL, 82, u32_0},                                    // IsSixAxisSensorAtRest
    {NULL, 87, ok},                                       // LoadSixAxisSensorCalibrationParameter (stub)
    {NULL, 91, ok},                                       // ActivateGesture
    {NULL, 100, set_style_set},                           // SetSupportedNpadStyleSet
    {NULL, 101, supported_style_set},                     // GetSupportedNpadStyleSet
    {NULL, 102, ok},                                      // SetSupportedNpadIdType
    {NULL, 103, activate_npad},                           // ActivateNpad
    {NULL, 104, ok},                                      // DeactivateNpad
    {NULL, 106, event},                                   // AcquireNpadStyleSetUpdateEventHandle
    {NULL, 107, ok},                                      // DisconnectNpad
    {NULL, 108, player_led},                              // GetPlayerLedPattern
    {NULL, 109, activate_npad},                           // ActivateNpadWithRevision
    {NULL, 120, set_hold_type},                           // SetNpadJoyHoldType(aruid, type)
    {NULL, 121, joy_hold_type},                           // GetNpadJoyHoldType
    {NULL, 122, ok},                                      // SetNpadJoyAssignmentModeSingleByDefault
    {NULL, 123, ok},                                      // SetNpadJoyAssignmentModeSingle
    {NULL, 124, ok},                                      // SetNpadJoyAssignmentModeDual
    {NULL, 125, ok},                                      // MergeSingleJoyAsDualJoy
    {NULL, 128, ok},                                      // SetNpadHandheldActivationMode
    {NULL, 130, ok},                                      // SwapNpadAssignment
    {NULL, 133, ok},                                      // SetNpadJoyAssignmentModeSingleWithDestination
    {NULL, 134, ok},                                      // SetNpadAnalogStickUseCenterClamp
    {NULL, 136, ok},                                      // ClearNpadCaptureButtonAssignment
    {NULL, 200, vibration_device_info},                   // GetVibrationDeviceInfo
    {NULL, 201, send_vibration_value},                    // SendVibrationValue
    {NULL, 202, u64_0},                                   // GetActualVibrationValue
    {NULL, 203, create_vibration_list},                   // CreateActiveVibrationDeviceList
    {NULL, 204, ok},                                      // PermitVibration
    {NULL, 205, u32_1},                                   // IsVibrationPermitted
    {NULL, 206, send_vibration_values},                   // SendVibrationValues
    {NULL, 207, ok},                                      // SendVibrationGcErmCommand
    {NULL, 209, ok},                                      // BeginPermitVibrationSession
    {NULL, 210, ok},                                      // EndPermitVibrationSession
    {NULL, 211, u32_0},                                   // IsVibrationDeviceMounted
    {NULL, 300, ok},                                      // ActivateConsoleSixAxisSensor
    {NULL, 301, ok},                                      // StartConsoleSixAxisSensor
    {NULL, 303, ok},                                      // ActivateSevenSixAxisSensor
    {NULL, 304, ok},                                      // StartSevenSixAxisSensor
    {NULL, 400, u32_0},                                   // IsUsbFullKeyControllerEnabled
    {NULL, 1000, ok},                                     // SetNpadCommunicationMode
    {NULL, 1001, u64_0},                                  // GetNpadCommunicationMode
    {NULL, 1002, ok},                                     // SetTouchScreenConfiguration
    {NULL, 1003, u32_0},                                  // IsFirmwareUpdateNeededForNotification
    {NULL, 1004, ok},                                     // SetTouchScreenResolution
    {"IAppletResource", 0, get_shared_memory},
    {"IActiveVibrationDeviceList", 0, ok},                // ActivateVibrationDevice
    {0},
};
const ServiceDef svc_hid = {.name = "hid", .cmds = cmds};
void hid_unused(void) { (void)sixaxis_handles; }
