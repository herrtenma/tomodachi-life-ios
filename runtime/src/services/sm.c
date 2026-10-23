// sm: — the service manager. GetServiceHandle opens a session to a host service
// (or a logging stub when the service is not written yet).
#include <string.h>

#include "ipc.h"

static void register_client(SvcObj *o, IpcReq *rq, IpcResp *rs) {}

static void get_service_handle(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    char name[9] = {0};
    memcpy(name, rq->data, 8);
    uint32_t h;
    nx_session_for(name, &h);
    nx_log("sm: GetServiceHandle(\"%s\") -> %#x", name, h);
    ipc_push_move(rs, h);
}

static const IpcCmd cmds[] = {
    {NULL, 0, register_client},
    {NULL, 1, get_service_handle},
    {0},
};
const ServiceDef svc_sm = {.name = "sm:", .cmds = cmds};
