// Host-side Horizon services: IPC request/response and service definitions.
#pragma once
#include "nxrt.h"

typedef struct IpcBuf { uint64_t addr, size; uint32_t index; } IpcBuf;

typedef struct IpcReq {
    uint8_t *msg;
    uint32_t type, cmd;
    int num_x, num_a, num_b, num_w, num_c, recv_flags;
    uint64_t pid;
    int num_copy, num_move;
    uint32_t copy[8], move[8];
    IpcBuf x[8], a[8], b[8], w[8], c[8];
    uint8_t *hipc_data;      // HIPC data words, right after the descriptors (TIPC payload)
    uint8_t *raw;            // 16-aligned raw data (domain header / SFCI header)
    size_t raw_size;
    uint8_t *data;           // command arguments (after the SFCI header)
    int c_pos;
    uint32_t in_objs[8];
    int num_in_objs;
    void *session;
} IpcReq;

typedef struct SvcObj SvcObj;

typedef struct IpcResp {
    uint32_t result;
    uint8_t out[0x100];
    size_t out_size;
    int num_copy, num_move, num_objs;
    uint32_t copy[8], move[8];
    SvcObj *objs[8];
} IpcResp;

typedef void (*IpcFn)(SvcObj *o, IpcReq *rq, IpcResp *rs);
typedef struct IpcCmd { const char *iface; uint32_t id; IpcFn fn; } IpcCmd;

typedef struct ServiceDef {
    const char *name;
    const IpcCmd *cmds;      // terminated by {0}; iface NULL = the root interface
    IpcFn fallback;
    void (*open)(SvcObj *o);
} ServiceDef;

struct SvcObj {
    const ServiceDef *def;
    const char *iface;       // sub-interface name (NULL for the service root)
    void *state;
};

void nx_service_register(const ServiceDef *def);
void nx_service_alias(const char *name, const ServiceDef *def);
SvcObj *nx_obj_new(const ServiceDef *def, const char *iface, void *state);
uint32_t nx_session_for(const char *service_name, uint32_t *out_handle);
void ipc_push_raw(IpcResp *rs, const void *p, size_t n);
void ipc_push_copy(IpcResp *rs, uint32_t h);
void ipc_push_move(IpcResp *rs, uint32_t h);
void ipc_push_object(IpcResp *rs, SvcObj *o);
SvcObj *ipc_in_object(IpcReq *rq, int i);

#define IN(T, off) (*(T *)(rq->data + (off)))
#define OUT(rs, v) do { __typeof__(v) _v = (v); ipc_push_raw((rs), &_v, sizeof _v); } while (0)

void nx_services_init(void);
