// appletOE (application proxy) and apm. Command ids per switchbrew / Ryujinx.
// Boot behavior: one pending FocusStateChanged message, focus = InFocus, docked.
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include "ipc.h"

extern const ServiceDef svc_appletoe, svc_apm;

#define RES_AM_NO_MESSAGES 0x680     // am: no messages in the queue
#define RES_AM_NO_DATA 0x2680        // am: no launch parameter
#define RES_AM_NOT_AVAILABLE 0x480   // am: applet out data queue empty (Ryujinx NotAvailable; the SDK polls on it)

static struct {
    uint32_t msg_event;              // readable handle given to the guest
    KEvent *msg_ev;
    int pending[8], npending;
    int focus;                       // 0 = InFocus (reported as 1); NXRT_APPLETMSG can change it
    pthread_mutex_t lock;            // pending[]: the game's ReceiveMessage vs nx_applet_post
    int docked;
} g_am = {.docked = 1, .lock = PTHREAD_MUTEX_INITIALIZER};

static int applet_log(void) {
    static int on = -1;
    if (on < 0) on = getenv("NXRT_APPLETLOG") != NULL;
    return on;
}
// Queue an applet message for the game (4 ExitRequest, 15 FocusStateChanged, 16 Resume, 30 OperationModeChanged, ...).
void nx_applet_post(uint32_t msg) {
    if (!g_am.msg_ev) return;
    pthread_mutex_lock(&g_am.lock);
    if (g_am.npending < 8) g_am.pending[g_am.npending++] = msg;
    pthread_mutex_unlock(&g_am.lock);
    nx_event_signal_obj(g_am.msg_ev);
}
// NXRT_APPLETMSG=<frame>:<msg>[:<focus>],...: post msg at that frame (focus: 1 in focus, 2 out of focus, 3 background,
// reported by GetCurrentFocusState from then on). Research: which message makes the game save (shared island handoff).
void nx_applet_tick(int frame) {
    static const char *spec;
    static int init;
    if (!init++) spec = getenv("NXRT_APPLETMSG");
    if (!spec) return;
    for (const char *p = spec; *p;) {
        char *e;
        long f = strtol(p, &e, 10), m = 0, focus = 0;
        if (*e == ':') m = strtol(e + 1, &e, 10);
        if (*e == ':') focus = strtol(e + 1, &e, 10);
        if (f == frame) {
            if (focus) g_am.focus = (int)focus - 1;
            nx_log("am: frame %d: posting applet message %ld%s", frame, m, focus ? " (focus changed)" : "");
            nx_applet_post((uint32_t)m);
        }
        while (*e && *e != ',') e++;
        p = *e ? e + 1 : e;
    }
}

// Applet storage objects (IStorage -> IStorageAccessor) carry launch parameters and
// library applet in/out data.
typedef struct { uint8_t *data; uint64_t size; } AmStorage;

static void ok(SvcObj *o, IpcReq *rq, IpcResp *rs) {}

// NXRT_HANDHELD=1: report handheld mode (720p, touch screen allowed) instead of docked.
static int is_docked(void) {
    static int d = -1;
    if (d < 0) d = getenv("NXRT_HANDHELD") ? 0 : g_am.docked;
    return d;
}

static void sub(IpcResp *rs, const char *iface) { ipc_push_object(rs, nx_obj_new(&svc_appletoe, iface, NULL)); }

// IApplicationProxyService
static void open_application_proxy(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    if (!g_am.msg_ev) {
        g_am.msg_ev = nx_event_new_readable(&g_am.msg_event);
        g_am.pending[g_am.npending++] = 15;               // FocusStateChanged
        nx_event_signal_obj(g_am.msg_ev);
    }
    sub(rs, "IApplicationProxy");
}

// IApplicationProxy getters
static void get_common_state_getter(SvcObj *o, IpcReq *rq, IpcResp *rs) { sub(rs, "ICommonStateGetter"); }
static void get_self_controller(SvcObj *o, IpcReq *rq, IpcResp *rs) { sub(rs, "ISelfController"); }
static void get_window_controller(SvcObj *o, IpcReq *rq, IpcResp *rs) { sub(rs, "IWindowController"); }
static void get_audio_controller(SvcObj *o, IpcReq *rq, IpcResp *rs) { sub(rs, "IAudioController"); }
static void get_display_controller(SvcObj *o, IpcReq *rq, IpcResp *rs) { sub(rs, "IDisplayController"); }
static void get_library_applet_creator(SvcObj *o, IpcReq *rq, IpcResp *rs) { sub(rs, "ILibraryAppletCreator"); }
static void get_application_functions(SvcObj *o, IpcReq *rq, IpcResp *rs) { sub(rs, "IApplicationFunctions"); }
static void get_debug_functions(SvcObj *o, IpcReq *rq, IpcResp *rs) { sub(rs, "IDebugFunctions"); }
static void get_process_winding_controller(SvcObj *o, IpcReq *rq, IpcResp *rs) { sub(rs, "IProcessWindingController"); }

// ICommonStateGetter
static void csg_get_event_handle(SvcObj *o, IpcReq *rq, IpcResp *rs) { ipc_push_copy(rs, g_am.msg_event); }
static void csg_receive_message(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    pthread_mutex_lock(&g_am.lock);
    if (!g_am.npending) { pthread_mutex_unlock(&g_am.lock); rs->result = RES_AM_NO_MESSAGES; return; }
    uint32_t m = g_am.pending[0];
    memmove(g_am.pending, g_am.pending + 1, --g_am.npending * sizeof(int));
    if (!g_am.npending) g_am.msg_ev->signaled = 0;
    pthread_mutex_unlock(&g_am.lock);
    if (applet_log()) { extern volatile int g_gfx_frame; nx_log("am: frame %d: game received message %u", g_gfx_frame, m); }
    OUT(rs, m);
}
static void csg_get_operation_mode(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    static int n;
    if (n++ < 3) nx_log("am: GetOperationMode -> %s", is_docked() ? "console (docked)" : "handheld");
    OUT(rs, (uint8_t)is_docked());
}
static void csg_get_performance_mode(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)is_docked()); }
static void csg_get_boot_mode(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint8_t)0); }
static void csg_get_current_focus_state(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint8_t)(1 + g_am.focus)); }
static void sc_logged(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    static const char *names[] = {"Exit", "LockExit", "UnlockExit"};
    if (applet_log()) { extern volatile int g_gfx_frame; nx_log("am: frame %d: game called %s", g_gfx_frame, names[rq->cmd]); }
}
static void csg_get_default_display_resolution(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    OUT(rs, (uint32_t)(is_docked() ? 1920 : 1280));
    OUT(rs, (uint32_t)(is_docked() ? 1080 : 720));
}
static void csg_get_default_display_resolution_event(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    uint32_t h;
    nx_event_new_readable(&h);
    ipc_push_copy(rs, h);
}
static void csg_event(SvcObj *o, IpcReq *rq, IpcResp *rs) {   // generic "get an event" commands
    uint32_t h;
    nx_event_new_readable(&h);
    ipc_push_copy(rs, h);
}
static void csg_u8_zero(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint8_t)0); }
static void csg_u32_zero(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)0); }

static void sc_u64_0(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint64_t)0); }
static void sc_launchable_event(SvcObj *o, IpcReq *rq, IpcResp *rs) {   // in foreground: launchable now
    uint32_t h;
    KEvent *e = nx_event_new_readable(&h);
    e->signaled = 1;
    ipc_push_copy(rs, h);
}
static void sc_create_managed_layer(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint64_t)1); }
static void sc_create_separable_layer(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint64_t)1); OUT(rs, (uint64_t)2); }

// ---- library applets: we act as the system applet ---------------------------------
// Most complete immediately with a fixed reply. The software keyboard (0x11) asks the host for text
// (a dialog in the window, NXRT_SWKBD_TEXT headless) and answers like the real applet.
#define LA_QMAX 8
typedef struct {
    uint32_t applet_id, mode;
    KEvent *state_ev, *out_ev, *iout_ev;
    uint32_t state_h, out_h, iout_h;
    int started, completed, popped;
    AmStorage *in[LA_QMAX], *out[LA_QMAX], *iout[LA_QMAX];
    int nin, nout, niout;
    // swkbd
    uint8_t cfg[0x3D4];
    int check_pending;                                    // text sent for the game's check, awaiting its verdict
    uint16_t text[512];
    int text_len, accepted;
    int inl, inl_state, inl_utf8, inl_max;                // inline keyboard (config = 8-byte Initialize)
} LibApplet;
enum { INL_UNINIT = 0, INL_INIT = 1, INL_SHOWN = 3, INL_DISAPPEARING = 4 };   // inline keyboard states
static void inl_done(LibApplet *a, int accepted);

static pthread_mutex_t g_la_lock = PTHREAD_MUTEX_INITIALIZER;   // the host dialog finishes on the main thread

static void q_push(AmStorage **q, int *n, AmStorage *st) {
    if (*n < LA_QMAX) q[(*n)++] = st;
    else nx_log("am: applet storage queue full, dropped %llu bytes", (unsigned long long)st->size);
}
static AmStorage *q_pop(AmStorage **q, int *n) {
    if (!*n) return NULL;
    AmStorage *st = q[0];
    memmove(q, q + 1, --*n * sizeof *q);
    return st;
}
static AmStorage *storage_new(uint64_t size) {
    AmStorage *st = calloc(1, sizeof *st);
    st->size = size;
    st->data = calloc(1, size ? size : 1);
    return st;
}

static void lac_create(SvcObj *o, IpcReq *rq, IpcResp *rs) {   // CreateLibraryApplet(id, mode)
    LibApplet *a = calloc(1, sizeof *a);
    a->applet_id = IN(uint32_t, 0);
    a->mode = IN(uint32_t, 4);
    a->state_ev = nx_event_new_readable(&a->state_h);
    a->out_ev = nx_event_new_readable(&a->out_h);
    a->iout_ev = nx_event_new_readable(&a->iout_h);
    nx_log("am: CreateLibraryApplet(applet %#x, mode %u)", a->applet_id, a->mode);
    ipc_push_object(rs, nx_obj_new(&svc_appletoe, "ILibraryAppletAccessor", a));
}
static void lac_create_storage(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    ipc_push_object(rs, nx_obj_new(&svc_appletoe, "IStorage", storage_new(IN(uint64_t, 0))));
}
static void lac_u8_0(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint8_t)0); }
static LibApplet *LA(SvcObj *o) { return o->state; }
static void la_state_event(SvcObj *o, IpcReq *rq, IpcResp *rs) { ipc_push_copy(rs, LA(o)->state_h); }
static void la_is_completed(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint8_t)LA(o)->completed); }

// ---- software keyboard (applet 0x11), normal (non-inline) mode -------------------------
// In: CommonArguments, SoftwareKeyboardConfig (0x3D4+ bytes), work buffer (initial text, UTF-16).
// Out: 0x7D8 bytes = u32 result (0 OK, 1 cancel) + text (UTF-16, or UTF-8 if cfg+0x3BD).
// With CheckText (cfg+0x3D0) the text first goes out as interactive data (0x7D4: u64 length+8, text);
// the game replies with PushInteractiveInData (u32 0 = OK, else an error message) before the final reply.
// Layout per Ryujinx SoftwareKeyboardConfig / libnx SwkbdConfigCommon.
#define SWKBD_HEADER 0x24
#define SWKBD_SUBTITLE 0xA6
#define SWKBD_GUIDE 0x1A8
#define SWKBD_MAX 0x3AC
#define SWKBD_MIN 0x3B0
#define SWKBD_UTF8 0x3BD
#define SWKBD_INIT_OFF 0x3C0
#define SWKBD_INIT_LEN 0x3C4
#define SWKBD_CHECK 0x3D0

typedef void (*NxTextDone)(void *ctx, const uint16_t *text, int len, int accepted);
void nx_host_text_prompt(const uint16_t *header, const uint16_t *guide, const uint16_t *message,
                         const uint16_t *initial, int initial_len, int max_len, NxTextDone done, void *ctx);
int nx_host_ui_available(void);

static uint32_t cfg32(LibApplet *a, int off) { uint32_t v; memcpy(&v, a->cfg + off, 4); return v; }
static const uint16_t *cfg16(LibApplet *a, int off) { return (const uint16_t *)(a->cfg + off); }

// UTF-16 <-> UTF-8 for the log, NXRT_SWKBD_TEXT and UTF-8 replies.
static int utf16_to_utf8(const uint16_t *s, int n, char *out, int cap) {
    int o = 0;
    for (int i = 0; i < n && s[i]; i++) {
        uint32_t c = s[i];
        if (c >= 0xD800 && c < 0xDC00 && i + 1 < n && s[i + 1] >= 0xDC00 && s[i + 1] < 0xE000)
            c = 0x10000 + ((c - 0xD800) << 10) + (s[++i] - 0xDC00);
        uint8_t b[4]; int k;
        if (c < 0x80) { b[0] = c; k = 1; }
        else if (c < 0x800) { b[0] = 0xC0 | c >> 6; b[1] = 0x80 | (c & 63); k = 2; }
        else if (c < 0x10000) { b[0] = 0xE0 | c >> 12; b[1] = 0x80 | (c >> 6 & 63); b[2] = 0x80 | (c & 63); k = 3; }
        else { b[0] = 0xF0 | c >> 18; b[1] = 0x80 | (c >> 12 & 63); b[2] = 0x80 | (c >> 6 & 63); b[3] = 0x80 | (c & 63); k = 4; }
        if (o + k >= cap) break;
        memcpy(out + o, b, k);
        o += k;
    }
    if (cap) out[o] = 0;
    return o;
}
static int utf8_to_utf16(const char *s, uint16_t *out, int cap) {
    int n = 0;
    const uint8_t *p = (const uint8_t *)s;
    while (*p && n < cap) {
        uint32_t c = *p++;
        int more = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : c >= 0xC0 ? 1 : 0;
        if (more) c &= 0x3F >> more;
        while (more-- && (*p & 0xC0) == 0x80) c = c << 6 | (*p++ & 63);
        if (c >= 0x10000) {
            if (n + 2 > cap) break;
            c -= 0x10000;
            out[n++] = 0xD800 + (c >> 10);
            out[n++] = 0xDC00 + (c & 0x3FF);
        } else out[n++] = c;
    }
    return n;
}

// Builds a reply: interactive = u64 (length + 8) + text, else u32 result + text.
static AmStorage *swkbd_reply(LibApplet *a, int interactive) {
    AmStorage *st = storage_new(interactive ? 0x7D4 : 0x7D8);
    int hdr = interactive ? 8 : 4, n;
    if (a->cfg[SWKBD_UTF8]) n = utf16_to_utf8(a->text, a->text_len, (char *)st->data + hdr, (int)st->size - hdr);
    else {
        n = a->text_len * 2;
        if (n > (int)st->size - hdr - 2) n = ((int)st->size - hdr - 2) & ~1;
        memcpy(st->data + hdr, a->text, n);
    }
    if (interactive) { uint64_t len = n + 8; memcpy(st->data, &len, 8); }
    else { uint32_t res = a->accepted ? 0 : 1; memcpy(st->data, &res, 4); }
    return st;
}

static void swkbd_prompt(LibApplet *a, const uint16_t *message);

// Text is in (any thread): apply the length limits, then reply (or send it for the game's check).
static void swkbd_done(void *ctx, const uint16_t *text, int len, int accepted) {
    LibApplet *a = ctx;
    pthread_mutex_lock(&g_la_lock);
    int max = a->inl ? a->inl_max : (int)cfg32(a, SWKBD_MAX), min = a->inl ? 0 : (int)cfg32(a, SWKBD_MIN);
    if (max <= 0 || max > 500) max = max <= 0 ? 100 : 500;
    if (len > max) len = max;
    memcpy(a->text, text, len * 2);
    a->text_len = len;
    if (accepted && len > 0)                               // too short: repeat it, like Ryujinx
        while (a->text_len < min && a->text_len < max) { a->text[a->text_len] = a->text[a->text_len % len]; a->text_len++; }
    a->accepted = accepted;
    if (a->inl) {
        inl_done(a, accepted);
        pthread_mutex_unlock(&g_la_lock);
        nx_event_signal_obj(a->iout_ev);
        return;
    }
    char u8[1024];
    utf16_to_utf8(a->text, a->text_len, u8, sizeof u8);
    nx_log("am: swkbd -> %s \"%s\"%s", accepted ? "OK" : "cancel", u8,
           accepted && a->cfg[SWKBD_CHECK] ? " (sent for the game's text check)" : "");
    if (accepted && a->cfg[SWKBD_CHECK]) {
        a->check_pending = 1;
        q_push(a->iout, &a->niout, swkbd_reply(a, 1));
        pthread_mutex_unlock(&g_la_lock);
        nx_event_signal_obj(a->iout_ev);
        return;
    }
    q_push(a->out, &a->nout, swkbd_reply(a, 0));
    a->completed = 1;
    pthread_mutex_unlock(&g_la_lock);
    nx_event_signal_obj(a->out_ev);
    nx_event_signal_obj(a->state_ev);
}

static void swkbd_prompt(LibApplet *a, const uint16_t *message) {
    static const uint16_t def[] = {'M', 'i', 'i'};
    const char *env = getenv("NXRT_SWKBD_TEXT");
    if (env || !nx_host_ui_available()) {
        uint16_t t[512];
        int n;
        if (env) n = utf8_to_utf16(env, t, 512);
        else if (a->text_len) { n = a->text_len; memcpy(t, a->text, n * 2); }   // initial text
        else { n = 3; memcpy(t, def, sizeof def); }
        swkbd_done(a, t, n, 1);
        return;
    }
    if (a->inl) nx_host_text_prompt(NULL, NULL, message, a->text, a->text_len, a->inl_max, swkbd_done, a);
    else nx_host_text_prompt(cfg16(a, SWKBD_HEADER), cfg16(a, SWKBD_GUIDE), message, a->text, a->text_len,
                             (int)cfg32(a, SWKBD_MAX), swkbd_done, a);
}

static void swkbd_start(LibApplet *a) {
    AmStorage *cfg = a->nin > 1 ? a->in[1] : NULL, *work = a->nin > 2 ? a->in[2] : NULL;
    if (cfg && cfg->size == 8) {                          // SoftwareKeyboardInitialize: inline keyboard
        a->inl = 1;
        a->inl_state = INL_UNINIT;
        nx_log("am: swkbd start: inline keyboard (mode %u)", a->mode);
        return;
    }
    if (!cfg || cfg->size < sizeof a->cfg)
        nx_log("am: swkbd config storage %#llx bytes (want >= %#zx), using defaults",
               cfg ? (unsigned long long)cfg->size : 0ull, sizeof a->cfg);
    else memcpy(a->cfg, cfg->data, sizeof a->cfg);
    uint32_t off = cfg32(a, SWKBD_INIT_OFF), n = cfg32(a, SWKBD_INIT_LEN);
    if (work && n && n < 512 && off + 2ull * n <= work->size) {
        memcpy(a->text, work->data + off, 2 * n);
        a->text_len = (int)n;
    }
    char h[256], g[512], init[512];
    utf16_to_utf8(cfg16(a, SWKBD_HEADER), 65, h, sizeof h);
    utf16_to_utf8(cfg16(a, SWKBD_GUIDE), 257, g, sizeof g);
    utf16_to_utf8(a->text, a->text_len, init, sizeof init);
    nx_log("am: swkbd start: %d storages, header \"%s\", guide \"%s\", initial \"%s\", length %u..%u, %s%s",
           a->nin, h, g, init, cfg32(a, SWKBD_MIN), cfg32(a, SWKBD_MAX), a->cfg[SWKBD_UTF8] ? "UTF-8" : "UTF-16",
           a->cfg[SWKBD_CHECK] ? ", text check" : "");
    swkbd_prompt(a, NULL);
}

// PushInteractiveInData: the game's verdict on checked text (u32 0 = OK, then an error message).
static void swkbd_check_result(LibApplet *a, AmStorage *st) {
    uint32_t verdict = 0;
    if (st->size >= 4) memcpy(&verdict, st->data, 4);
    pthread_mutex_lock(&g_la_lock);
    int pending = a->check_pending;
    a->check_pending = 0;
    pthread_mutex_unlock(&g_la_lock);
    if (!pending) { nx_log("am: swkbd interactive data with no text check pending (%#x)", verdict); return; }
    if (verdict) {
        uint16_t msg[512] = {0};
        int n = st->size > 4 ? (int)((st->size - 4) / 2) : 0;
        if (n > 511) n = 511;
        memcpy(msg, st->data + 4, n * 2);
        char u8[1024];
        utf16_to_utf8(msg, n, u8, sizeof u8);
        nx_log("am: swkbd text rejected by the game (%#x): \"%s\"", verdict, u8);
        if (nx_host_ui_available() && !getenv("NXRT_SWKBD_TEXT")) { swkbd_prompt(a, msg); return; }
        // Headless: nothing else to offer; accept like Ryujinx does.
    }
    pthread_mutex_lock(&g_la_lock);
    q_push(a->out, &a->nout, swkbd_reply(a, 0));
    a->completed = 1;
    pthread_mutex_unlock(&g_la_lock);
    nx_event_signal_obj(a->out_ev);
    nx_event_signal_obj(a->state_ev);
}

// ---- inline software keyboard ------------------------------------------------------------
// The game drives it with interactive data: u32 request + payload (Ryujinx InlineKeyboardRequest);
// every reply is u32 state + u32 response code + payload (InlineResponses). Calc (0xA) carries flags
// (u64 at +8): Initialize 0x1, Appear 0x4, SetInputText 0x8, SetUtf8Mode 0x20, AppearTrigger 0x10000.
// Calc body: Appear at +0x20 (0x48 bytes, 0x70 in CalcEx), then InputText (506 UTF-16), then UseUtf8.

static void inl_push(LibApplet *a, uint32_t code, const void *payload, uint64_t n) {   // g_la_lock held
    AmStorage *st = storage_new(8 + n);
    uint32_t hdr[2] = {(uint32_t)a->inl_state, code};
    memcpy(st->data, hdr, 8);
    if (n) memcpy(st->data + 8, payload, n);
    q_push(a->iout, &a->niout, st);
}
// String field: text in a fixed area (0x3EC UTF-16 / 0x7D4 UTF-8), then u32 length in characters.
static int inl_string(LibApplet *a, uint8_t *p) {
    int area = a->inl_utf8 ? 0x7D4 : 0x3EC;
    if (a->inl_utf8) utf16_to_utf8(a->text, a->text_len, (char *)p, area);
    else memcpy(p, a->text, (a->text_len * 2 < area ? a->text_len * 2 : area));
    uint32_t len = a->text_len;
    memcpy(p + area, &len, 4);
    return area + 4;
}
static void inl_changed_string(LibApplet *a) {          // ChangedString(Utf8): string, -1, -1, cursor
    uint8_t buf[0x7D4 + 16] = {0};
    int n = inl_string(a, buf);
    int32_t tail[3] = {-1, -1, a->text_len};
    memcpy(buf + n, tail, 12);
    inl_push(a, a->inl_utf8 ? 7 : 2, buf, n + 12);
}
static void inl_default(LibApplet *a) { inl_push(a, 1, NULL, 0); }

static void inl_done(LibApplet *a, int accepted) {      // g_la_lock held; the dialog closed
    char u8[1024];
    utf16_to_utf8(a->text, a->text_len, u8, sizeof u8);
    nx_log("am: swkbd inline -> %s \"%s\"", accepted ? "OK" : "cancel", u8);
    a->inl_state = INL_DISAPPEARING;
    if (accepted) {
        uint8_t buf[0x7D4 + 8] = {0};
        inl_changed_string(a);
        inl_push(a, a->inl_utf8 ? 9 : 5, buf, inl_string(a, buf));   // DecidedEnter(Utf8)
    } else inl_push(a, 6, NULL, 0);                      // DecidedCancel
    inl_default(a);
    a->inl_state = INL_INIT;
    inl_default(a);
}

static void inl_request(LibApplet *a, AmStorage *st) {
    uint32_t req = 0;
    if (st->size >= 4) memcpy(&req, st->data, 4);
    const uint8_t *body = st->data + 4;
    uint64_t bn = st->size >= 4 ? st->size - 4 : 0;
    int show = 0;
    pthread_mutex_lock(&g_la_lock);
    switch (req) {
    case 0x6: inl_push(a, 0xB, NULL, 0); break;          // SetUserWordInfo -> ReleasedUserWordInfo
    case 0x7: case 0xB: case 0xD: case 0xE: break;       // dictionaries, V2 flags: no reply (Ryujinx)
    case 0x4:                                            // Finalize
        a->inl_state = INL_UNINIT;
        a->completed = 1;
        pthread_mutex_unlock(&g_la_lock);
        nx_log("am: swkbd inline finalize");
        nx_event_signal_obj(a->state_ev);
        return;
    case 0xA: {                                          // Calc
        uint64_t flags = 0;
        if (bn >= 16) memcpy(&flags, body + 8, 8);
        int ex = bn >= 0x90 + 0x3F4 + 1;                 // CalcEx (0x70-byte Appear) vs Calc (0x48)
        int text_off = ex ? 0x90 : 0x68;
        if (bn >= 0x24 + 0x20) { int32_t m; memcpy(&m, body + 0x20 + 0x20, 4); if (m > 0) a->inl_max = m; }
        if (flags & 0x1) { inl_push(a, 0, "\1", 1); a->inl_state = INL_INIT; }   // FinishedInitialize
        if ((flags & 0x8) && bn >= text_off + 0x3F4u) {
            const uint16_t *t = (const uint16_t *)(body + text_off);
            int n = 0;
            while (n < 505 && t[n]) n++;
            memcpy(a->text, t, n * 2);
            a->text_len = n;
        }
        if ((flags & 0x20) && bn > text_off + 0x3F4u) a->inl_utf8 = body[text_off + 0x3F4];
        static int nlog;
        if (nlog++ < 40) nx_log("am: swkbd inline Calc flags %#llx (%llu bytes), state %d, text %d chars",
                                (unsigned long long)flags, (unsigned long long)bn, a->inl_state, a->text_len);
        if ((flags & 0x10004) && a->inl_state != INL_SHOWN) {   // Appear / AppearTrigger
            a->inl_state = INL_SHOWN;
            inl_changed_string(a);
            show = 1;
        }
        inl_default(a);
        break;
    }
    default:
        nx_log("am: swkbd inline request %#x (%llu bytes) -> default reply", req, (unsigned long long)bn);
        inl_default(a);
        break;
    }
    int any = a->niout > 0;
    pthread_mutex_unlock(&g_la_lock);
    if (any) nx_event_signal_obj(a->iout_ev);   // a signal with nothing queued makes the game pop and abort
    if (show) swkbd_prompt(a, NULL);
}

static void la_start(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    LibApplet *a = LA(o);
    a->started = 1;
    if (a->applet_id == 0x11) { swkbd_start(a); return; }
    a->completed = 1;
    nx_log("am: library applet %#x started -> completes immediately", a->applet_id);
    nx_event_signal_obj(a->out_ev);
    nx_event_signal_obj(a->state_ev);
}
static void la_get_result(SvcObj *o, IpcReq *rq, IpcResp *rs) {}
static void la_push_in(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    SvcObj *so = ipc_in_object(rq, 0);
    if (!so || !so->state) return;
    pthread_mutex_lock(&g_la_lock);
    q_push(LA(o)->in, &LA(o)->nin, so->state);
    pthread_mutex_unlock(&g_la_lock);
}
static void la_push_interactive_in(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    SvcObj *so = ipc_in_object(rq, 0);
    if (!so || !so->state || LA(o)->applet_id != 0x11) return;
    if (LA(o)->inl) inl_request(LA(o), so->state);
    else swkbd_check_result(LA(o), so->state);
}
static void la_pop_out(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    LibApplet *a = LA(o);
    pthread_mutex_lock(&g_la_lock);
    AmStorage *st = q_pop(a->out, &a->nout);
    if (!a->nout) a->out_ev->signaled = 0;
    pthread_mutex_unlock(&g_la_lock);
    if (!st && a->applet_id != 0x11 && !a->popped++) {     // fixed replies of the other applets
        if (a->applet_id == 0x0C) {                        // controller applet: 1 player, Player 1
            st = storage_new(0xC);
            st->data[0] = 1;                               // player count
        } else st = storage_new(0x10);
    }
    if (a->applet_id == 0x11 && getenv("NXRT_SWKBDLOG"))
        nx_log("am: swkbd PopOutData -> %s", st ? "storage" : "none");
    if (!st) { rs->result = RES_AM_NOT_AVAILABLE; return; }
    ipc_push_object(rs, nx_obj_new(&svc_appletoe, "IStorage", st));
}
static void la_pop_interactive_out(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    LibApplet *a = LA(o);
    pthread_mutex_lock(&g_la_lock);
    AmStorage *st = q_pop(a->iout, &a->niout);
    if (!a->niout) a->iout_ev->signaled = 0;
    pthread_mutex_unlock(&g_la_lock);
    if (a->applet_id == 0x11 && getenv("NXRT_SWKBDLOG"))
        nx_log("am: swkbd PopInteractiveOutData -> %s (%d left)", st ? "storage" : "none", a->niout);
    if (!st) { rs->result = RES_AM_NOT_AVAILABLE; return; }
    ipc_push_object(rs, nx_obj_new(&svc_appletoe, "IStorage", st));
}
static void la_out_event(SvcObj *o, IpcReq *rq, IpcResp *rs) { ipc_push_copy(rs, LA(o)->out_h); }
static void la_iout_event(SvcObj *o, IpcReq *rq, IpcResp *rs) { ipc_push_copy(rs, LA(o)->iout_h); }
static void la_indirect_layer(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint64_t)1); }

// IWindowController
static void wc_get_aruid(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint64_t)0x51); }

// IApplicationFunctions
// (AmStorage is declared at the top of the file.)

static void af_pop_launch_parameter(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    uint32_t kind = IN(uint32_t, 0);
    nx_log("am: PopLaunchParameter(kind %u)", kind);
    static int popped;
    if (kind != 2 || popped++) { rs->result = RES_AM_NO_DATA; return; }
    // PreselectedUser: magic, is_account_selected, uid (same as acc), padding to 0x88
    static const uint8_t uid[16] = {0x01, 0, 0, 0, 0, 0, 0, 0, 0x7a, 0x6f, 0x6d, 0x6f, 0x64, 0x61, 0x63, 0x68};
    AmStorage *st = calloc(1, sizeof *st);
    st->size = 0x88;
    st->data = calloc(1, st->size);
    uint32_t magic = 0xC79497CA, selected = 1;
    memcpy(st->data, &magic, 4);
    memcpy(st->data + 4, &selected, 4);
    memcpy(st->data + 8, uid, 16);
    ipc_push_object(rs, nx_obj_new(&svc_appletoe, "IStorage", st));
}
static void storage_open(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    ipc_push_object(rs, nx_obj_new(&svc_appletoe, "IStorageAccessor", o->state));
}
static void accessor_size(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, ((AmStorage *)o->state)->size); }
static void accessor_read(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    AmStorage *st = o->state;
    uint64_t off = IN(uint64_t, 0);
    IpcBuf *b = rq->num_c ? &rq->c[0] : &rq->b[0];
    uint64_t n = off < st->size ? st->size - off : 0;
    if (n > b->size) n = b->size;
    memcpy((void *)b->addr, st->data + off, n);
}
static void accessor_write(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    AmStorage *st = o->state;
    uint64_t off = IN(uint64_t, 0);
    IpcBuf *b = rq->num_x ? &rq->x[0] : &rq->a[0];
    if (off + b->size <= st->size) memcpy(st->data + off, (void *)b->addr, b->size);
}
static void af_get_desired_language(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    char lang[8] = "en-US";
    uint64_t v;
    memcpy(&v, lang, 8);
    OUT(rs, v);
}
static void af_get_display_version(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    char ver[0x10] = "1.0.0";
    ipc_push_raw(rs, ver, sizeof ver);
}
static void af_ensure_save_data(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint64_t)0); }
static void af_get_pseudo_device_id(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    uint8_t id[16] = {0x51, 0x51};
    ipc_push_raw(rs, id, 16);
}
static void af_notify_running(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint8_t)0); }
static void af_get_save_data_size(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    OUT(rs, (uint64_t)0x10000000);
    OUT(rs, (uint64_t)0x10000000);
}
static void af_query_application_play_statistics(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)0); }

static const IpcCmd am_cmds[] = {
    {NULL, 0, open_application_proxy},
    {"IApplicationProxy", 0, get_common_state_getter},
    {"IApplicationProxy", 1, get_self_controller},
    {"IApplicationProxy", 2, get_window_controller},
    {"IApplicationProxy", 3, get_audio_controller},
    {"IApplicationProxy", 4, get_display_controller},
    {"IApplicationProxy", 10, get_process_winding_controller},
    {"IApplicationProxy", 11, get_library_applet_creator},
    {"IApplicationProxy", 20, get_application_functions},
    {"IApplicationProxy", 1000, get_debug_functions},

    {"ICommonStateGetter", 0, csg_get_event_handle},
    {"ICommonStateGetter", 1, csg_receive_message},
    {"ICommonStateGetter", 5, csg_get_operation_mode},
    {"ICommonStateGetter", 6, csg_get_performance_mode},
    {"ICommonStateGetter", 8, csg_get_boot_mode},
    {"ICommonStateGetter", 9, csg_get_current_focus_state},
    {"ICommonStateGetter", 50, csg_u8_zero},              // IsVrModeEnabled
    {"ICommonStateGetter", 60, csg_get_default_display_resolution},
    {"ICommonStateGetter", 61, csg_get_default_display_resolution_event},
    {"ICommonStateGetter", 66, ok},                       // SetCpuBoostMode
    {"ICommonStateGetter", 90, csg_event},                // GetAcquiredSleepLockEvent
    {"ICommonStateGetter", 300, csg_u32_zero},            // GetSettingsPlatformRegion
    {"ICommonStateGetter", 400, csg_u8_zero},             // ...
    {"ICommonStateGetter", 900, ok},                      // SetRequestExitToLibraryAppletAtExecuteNextProgramEnabled

    {"ISelfController", 0, sc_logged},                    // Exit
    {"ISelfController", 1, sc_logged},                    // LockExit
    {"ISelfController", 2, sc_logged},                    // UnlockExit
    {"ISelfController", 9, sc_launchable_event},          // GetLibraryAppletLaunchableEvent
    {"ISelfController", 10, ok},                          // SetScreenShotPermission
    {"ISelfController", 11, ok},                          // SetOperationModeChangedNotification
    {"ISelfController", 12, ok},                          // SetPerformanceModeChangedNotification
    {"ISelfController", 13, ok},                          // SetFocusHandlingMode
    {"ISelfController", 14, ok},                          // SetRestartMessageEnabled
    {"ISelfController", 16, ok},                          // SetOutOfFocusSuspendingEnabled
    {"ISelfController", 19, ok},                          // SetAlbumImageOrientation
    {"ISelfController", 40, sc_create_managed_layer},     // CreateManagedDisplayLayer
    {"ISelfController", 41, csg_u8_zero},                 // IsSystemBufferSharingEnabled
    {"ISelfController", 44, sc_create_separable_layer},   // CreateManagedDisplaySeparableLayer
    {"ISelfController", 50, ok},                          // SetHandlesRequestToDisplay
    {"ISelfController", 62, ok},                          // SetIdleTimeDetectionExtension
    {"ISelfController", 68, ok},                          // SetAutoSleepDisabled
    {"ISelfController", 90, sc_u64_0},                    // GetAccumulatedSuspendedTickValue
    {"ISelfController", 91, csg_event},                   // GetAccumulatedSuspendedTickChangedEvent
    {"ISelfController", 100, ok},                         // SetAlbumImageTakenNotificationEnabled

    {"ILibraryAppletCreator", 0, lac_create},
    {"ILibraryAppletCreator", 2, lac_u8_0},               // AreAnyLibraryAppletsLeft
    {"ILibraryAppletCreator", 3, lac_create},             // newer FW create variant
    {"ILibraryAppletCreator", 10, lac_create_storage},
    {"ILibraryAppletAccessor", 0, la_state_event},
    {"ILibraryAppletAccessor", 1, la_is_completed},
    {"ILibraryAppletAccessor", 10, la_start},
    {"ILibraryAppletAccessor", 20, ok},                   // RequestExit
    {"ILibraryAppletAccessor", 25, ok},                   // Terminate
    {"ILibraryAppletAccessor", 30, la_get_result},
    {"ILibraryAppletAccessor", 50, ok},                   // SetOutOfFocusApplicationSuspendingEnabled
    {"ILibraryAppletAccessor", 60, ok},                   // PresetLibraryAppletGpuTimeSliceZero
    {"ILibraryAppletAccessor", 100, la_push_in},
    {"ILibraryAppletAccessor", 101, la_pop_out},
    {"ILibraryAppletAccessor", 102, la_push_in},          // PushExtraStorage
    {"ILibraryAppletAccessor", 90, ok},                   // RequestForAppletToGetForeground
    {"ILibraryAppletAccessor", 103, la_push_interactive_in},
    {"ILibraryAppletAccessor", 104, la_pop_interactive_out},
    {"ILibraryAppletAccessor", 105, la_out_event},        // GetPopOutDataEvent
    {"ILibraryAppletAccessor", 106, la_iout_event},       // GetPopInteractiveOutDataEvent
    {"ILibraryAppletAccessor", 160, la_indirect_layer},   // GetIndirectLayerConsumerHandle
    {"IWindowController", 1, wc_get_aruid},
    {"IWindowController", 10, ok},                        // AcquireForegroundRights

    {"IAudioController", 0, ok},                          // SetExpectedMasterVolume
    {"IDisplayController", 0, ok},

    {"IApplicationFunctions", 1, af_pop_launch_parameter},
    {"IStorage", 0, storage_open},
    {"IStorageAccessor", 0, accessor_size},
    {"IStorageAccessor", 10, accessor_write},
    {"IStorageAccessor", 11, accessor_read},
    {"IApplicationFunctions", 20, af_ensure_save_data},
    {"IApplicationFunctions", 21, af_get_desired_language},
    {"IApplicationFunctions", 22, ok},                    // SetTerminateResult
    {"IApplicationFunctions", 23, af_get_display_version},
    {"IApplicationFunctions", 25, af_ensure_save_data},   // ExtendSaveData
    {"IApplicationFunctions", 26, af_get_save_data_size},
    {"IApplicationFunctions", 40, af_notify_running},
    {"IApplicationFunctions", 50, af_get_pseudo_device_id},
    {"IApplicationFunctions", 65, ok},                    // InitializeGamePlayRecording
    {"IApplicationFunctions", 66, ok},                    // SetGamePlayRecordingState
    {"IApplicationFunctions", 90, ok},                    // EnableApplicationCrashReport
    {"IApplicationFunctions", 100, ok},                   // InitializeApplicationCopyrightFrameBuffer
    {"IApplicationFunctions", 110, af_query_application_play_statistics},
    {"IApplicationFunctions", 130, csg_event},            // GetGpuErrorDetectedSystemEvent
    {"IApplicationFunctions", 140, csg_event},            // GetFriendInvitationStorageChannelEvent
    {"IApplicationFunctions", 210, csg_event},            // newer FW: returns an event (polled right after)
    {0},
};
const ServiceDef svc_appletoe = {.name = "appletOE", .cmds = am_cmds};

// apm: performance mode / configuration
static void apm_open_session(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    ipc_push_object(rs, nx_obj_new(&svc_apm, "ISession", NULL));
}
static void apm_get_performance_mode(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)is_docked()); }
static void apm_get_config(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)0x00020003); }

static const IpcCmd apm_cmds[] = {
    {NULL, 0, apm_open_session},
    {NULL, 1, apm_get_performance_mode},
    {NULL, 6, csg_u8_zero},                               // IsCpuOverclockEnabled
    {"ISession", 0, ok},                                  // SetPerformanceConfiguration
    {"ISession", 1, apm_get_config},                      // GetPerformanceConfiguration
    {"ISession", 2, ok},                                  // SetCpuOverclockEnabled
    {0},
};
const ServiceDef svc_apm = {.name = "apm", .cmds = apm_cmds};
