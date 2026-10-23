// nvdrv: the NVIDIA driver interface. NVN itself is replaced at the API level (host
// functions behind nvnBootstrapLoader), so this only needs to satisfy the SDK's own
// graphics init. Every device open and ioctl is logged; outputs default to zero.
#include <stdio.h>
#include <string.h>

#include "ipc.h"

static char g_fd_path[64][64];
static int g_nfd = 1;

static void ok(SvcObj *o, IpcReq *rq, IpcResp *rs) {}
static void nv_ok(IpcResp *rs) { OUT(rs, (uint32_t)0); }   // NvResult Success

static IpcBuf *in_buf(IpcReq *rq) { return rq->num_a ? &rq->a[0] : rq->num_x ? &rq->x[0] : NULL; }
static IpcBuf *out_buf(IpcReq *rq) { return rq->num_b ? &rq->b[0] : rq->num_c ? &rq->c[0] : NULL; }

static void nv_open(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    IpcBuf *b = in_buf(rq);
    char path[64] = {0};
    if (b) memcpy(path, (void *)b->addr, b->size < 63 ? b->size : 63);
    int fd = g_nfd < 64 ? g_nfd++ : 63;
    strcpy(g_fd_path[fd], path);
    nx_log("nvdrv: Open(\"%s\") -> fd %d", path, fd);
    OUT(rs, (uint32_t)fd);
    OUT(rs, (uint32_t)0);
}

// Ioctl number layout (Linux style): dir[31:30] size[29:16] magic[15:8] nr[7:0]
static void nv_ioctl(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    uint32_t fd = IN(uint32_t, 0), cmd = IN(uint32_t, 4);
    IpcBuf *in = in_buf(rq), *out = out_buf(rq);
    uint32_t size = (cmd >> 16) & 0x3FFF;
    nx_log("nvdrv: Ioctl(%s, %#x: magic %#x nr %#x size %#x)", fd < 64 ? g_fd_path[fd] : "?", cmd, (cmd >> 8) & 0xFF,
           cmd & 0xFF, size);
    if (out && out->addr) {
        if (in && in->addr && in->addr != out->addr) memcpy((void *)out->addr, (void *)in->addr, in->size < out->size ? in->size : out->size);
    }
    nv_ok(rs);
}

static void nv_query_event(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    uint32_t h;
    nx_event_new_readable(&h);
    ipc_push_copy(rs, h);
    nv_ok(rs);
}

static void nv_initialize(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    nx_log("nvdrv: Initialize(transfer memory size %#x)", IN(uint32_t, 0));
    nv_ok(rs);
}
static void nv_close(SvcObj *o, IpcReq *rq, IpcResp *rs) { nv_ok(rs); }
static void nv_set_aruid(SvcObj *o, IpcReq *rq, IpcResp *rs) { nv_ok(rs); }

static const IpcCmd cmds[] = {
    {NULL, 0, nv_open},
    {NULL, 1, nv_ioctl},
    {NULL, 2, nv_close},
    {NULL, 3, nv_initialize},
    {NULL, 4, nv_query_event},
    {NULL, 8, nv_set_aruid},                              // SetAruid / SetClientPid
    {NULL, 11, nv_ioctl},                                 // Ioctl2
    {NULL, 12, nv_ioctl},                                 // Ioctl3
    {NULL, 13, ok},                                       // SetGraphicsFirmwareMemoryMarginEnabled
    {0},
};
const ServiceDef svc_nvdrv = {.name = "nvdrv", .cmds = cmds};
