// vi:u / vi:s / vi:m — display and layers. The window contents come from our NVN
// layer, so the binder (IGraphicBufferProducer) side only needs to look alive.
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "ipc.h"

extern const ServiceDef svc_vi;

static uint32_t g_vsync_event;
static KEvent *g_vsync;
static uint64_t g_next_layer = 1;

static void ok(SvcObj *o, IpcReq *rq, IpcResp *rs) {}
static void obj(IpcResp *rs, const char *iface) { ipc_push_object(rs, nx_obj_new(&svc_vi, iface, NULL)); }

static void get_display_service(SvcObj *o, IpcReq *rq, IpcResp *rs) { obj(rs, "IApplicationDisplayService"); }
static void get_relay(SvcObj *o, IpcReq *rq, IpcResp *rs) { obj(rs, "IHOSBinderDriver"); }
static void get_system(SvcObj *o, IpcReq *rq, IpcResp *rs) { obj(rs, "ISystemDisplayService"); }
static void get_manager(SvcObj *o, IpcReq *rq, IpcResp *rs) { obj(rs, "IManagerDisplayService"); }

static void open_display(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint64_t)1); }
static void display_resolution(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (int64_t)1920); OUT(rs, (int64_t)1080); }
static void list_displays(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    // DisplayInfo: name[0x40], has_layer_limit u8, pad[7], layer count max i64, width i64, height i64
    uint8_t info[0x60] = {0};
    strcpy((char *)info, "Default");
    info[0x40] = 1;
    int64_t v[3] = {1, 1920, 1080};
    memcpy(info + 0x48, v, sizeof v);
    IpcBuf *b = rq->num_b ? &rq->b[0] : &rq->c[0];
    if (b->addr) memcpy((void *)b->addr, info, b->size < sizeof info ? b->size : sizeof info);
    OUT(rs, (uint64_t)1);
}

// Native window parcel: header {data size, data offset, objects size, objects offset},
// then a flat binder object {type 2, flags, binder id, cookie, "dispdrv"} and one
// object offset.
static void write_native_window(IpcReq *rq, IpcResp *rs, int32_t binder_id) {
    uint8_t parcel[0x100] = {0};
    uint32_t hdr[4] = {0x28, 0x10, 0x4, 0x10 + 0x28};
    memcpy(parcel, hdr, 16);
    int32_t fbo[2] = {2, 0};
    memcpy(parcel + 0x10, fbo, 8);
    int64_t id = binder_id;
    memcpy(parcel + 0x18, &id, 8);
    memcpy(parcel + 0x28, "dispdrv", 8);
    IpcBuf *b = rq->num_b ? &rq->b[0] : &rq->c[0];
    if (b->addr) memcpy((void *)b->addr, parcel, b->size < sizeof parcel ? b->size : sizeof parcel);
    OUT(rs, (uint64_t)(0x10 + 0x28 + 4));
}
static void open_layer(SvcObj *o, IpcReq *rq, IpcResp *rs) { write_native_window(rq, rs, 1); }
static void create_stray_layer(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    OUT(rs, g_next_layer++);
    write_native_window(rq, rs, 1);
}
static void create_managed_layer(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, g_next_layer++); }
static void *vsync_ticker(void *arg) {           // 60 Hz display vsync
    for (;;) {
        usleep(16667);
        nx_event_signal_obj(g_vsync);
    }
    return NULL;
}
static void vsync_event(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    if (!g_vsync) {
        g_vsync = nx_event_new_readable(&g_vsync_event);
        pthread_t t;
        pthread_create(&t, NULL, vsync_ticker, NULL);
        pthread_detach(t);
        nx_log("vi: vsync event %#x (60 Hz)", g_vsync_event);
    }
    ipc_push_copy(rs, g_vsync_event);
}
static void u64_0(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint64_t)0); }
static void zorder_max(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint64_t)255); }
static void logical_resolution(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (int32_t)1920); OUT(rs, (int32_t)1080); }
static void convert_scaling_mode(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint64_t)IN(uint32_t, 0)); }
// GetIndirectLayerImageRequiredMemoryInfo(width, height) -> (size, alignment): an RGBA8 linear image,
// pitch aligned to 64 bytes, height to 64 rows, size rounded up to 0x20000 (as Ryujinx computes it).
// An empty reply (size 0, alignment 0) was followed by intermittent load-time crashes in sdk.
static void indirect_layer_mem_info(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    if (getenv("NXRT_VI2460_EMPTY")) return;   // A/B test: the old empty reply
    int64_t w = IN(int64_t, 0), h = IN(int64_t, 8);
    if (w < 0) w = 0;
    if (h < 0) h = 0;
    uint64_t pitch = ((uint64_t)w * 4 + 63) & ~63ull, size = pitch * (((uint64_t)h + 63) & ~63ull);
    size = (size + 0xfff) & ~0xfffull;
    size = (size + 0x1ffff) / 0x20000 * 0x20000;
    if (!size) size = 0x20000;
    nx_log("vi: GetIndirectLayerImageRequiredMemoryInfo(%lld x %lld) -> %#llx", (long long)w, (long long)h, (unsigned long long)size);
    OUT(rs, size);
    OUT(rs, (uint64_t)0x1000);
}

// IHOSBinderDriver: log IGraphicBufferProducer transactions and answer status OK.
static void transact(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    int32_t id = IN(int32_t, 0);
    uint32_t code = IN(uint32_t, 4);
    nx_log("vi binder: TransactParcel(id %d, code %u)", id, code);
    IpcBuf *out = rq->num_b ? &rq->b[0] : rq->num_c ? &rq->c[0] : NULL;
    if (out && out->addr) {
        uint8_t parcel[0x40] = {0};
        uint32_t hdr[4] = {0x4, 0x10, 0, 0x14};           // data: one i32 status = 0
        memcpy(parcel, hdr, 16);
        memcpy((void *)out->addr, parcel, out->size < sizeof parcel ? out->size : sizeof parcel);
    }
}
static void binder_native_handle(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    uint32_t h;
    nx_event_new_readable(&h);
    ipc_push_copy(rs, h);
}

static const IpcCmd cmds[] = {
    {NULL, 0, get_display_service},                       // vi:u GetDisplayService
    {NULL, 1, get_display_service},                       // vi:s GetDisplayService
    {NULL, 2, get_display_service},                       // vi:m GetDisplayService
    {NULL, 3, get_display_service},                       // GetDisplayServiceWithProxyNameExchange
    {"IApplicationDisplayService", 100, get_relay},
    {"IApplicationDisplayService", 101, get_system},
    {"IApplicationDisplayService", 102, get_manager},
    {"IApplicationDisplayService", 103, get_relay},       // GetIndirectDisplayTransactionService
    {"IApplicationDisplayService", 1000, list_displays},
    {"IApplicationDisplayService", 1010, open_display},
    {"IApplicationDisplayService", 1011, open_display},   // OpenDefaultDisplay
    {"IApplicationDisplayService", 1020, ok},             // CloseDisplay
    {"IApplicationDisplayService", 1101, ok},             // SetDisplayEnabled
    {"IApplicationDisplayService", 1102, display_resolution},
    {"IApplicationDisplayService", 2020, open_layer},
    {"IApplicationDisplayService", 2021, ok},             // CloseLayer
    {"IApplicationDisplayService", 2030, create_stray_layer},
    {"IApplicationDisplayService", 2031, ok},             // DestroyStrayLayer
    {"IApplicationDisplayService", 2101, ok},             // SetLayerScalingMode
    {"IApplicationDisplayService", 2102, convert_scaling_mode},
    {"IApplicationDisplayService", 2460, indirect_layer_mem_info},
    {"IApplicationDisplayService", 5202, vsync_event},    // GetDisplayVsyncEvent
    {"IApplicationDisplayService", 5203, vsync_event},
    {"ISystemDisplayService", 1200, u64_0},               // GetZOrderCountMin
    {"ISystemDisplayService", 1202, zorder_max},          // GetZOrderCountMax
    {"ISystemDisplayService", 1203, logical_resolution},  // GetDisplayLogicalResolution
    {"ISystemDisplayService", 2201, ok},                  // SetLayerPosition
    {"ISystemDisplayService", 2203, ok},                  // SetLayerSize
    {"ISystemDisplayService", 2205, ok},                  // SetLayerZ
    {"ISystemDisplayService", 2207, ok},                  // SetLayerVisibility
    {"IManagerDisplayService", 2010, create_managed_layer},
    {"IManagerDisplayService", 2011, ok},                 // DestroyManagedLayer
    {"IManagerDisplayService", 6000, ok},                 // AddToLayerStack
    {"IManagerDisplayService", 6002, ok},                 // SetLayerVisibility
    {"IHOSBinderDriver", 0, transact},
    {"IHOSBinderDriver", 1, ok},                          // AdjustRefcount
    {"IHOSBinderDriver", 2, binder_native_handle},        // GetNativeHandle
    {"IHOSBinderDriver", 3, transact},                    // TransactParcelAuto
    {0},
};
const ServiceDef svc_vi = {.name = "vi:u", .cmds = cmds};
