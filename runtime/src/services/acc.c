// acc:u0 / acc:u1 — one local user, picked without any UI.
#include <string.h>
#include <time.h>

#include "ipc.h"

extern const ServiceDef svc_acc;

static const uint8_t g_uid[16] = {0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                                  0x7a, 0x6f, 0x6d, 0x6f, 0x64, 0x61, 0x63, 0x68};

static void ok(SvcObj *o, IpcReq *rq, IpcResp *rs) {}
static void user_count(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)1); }
static void user_exists(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint8_t)!memcmp(rq->data, g_uid, 16)); }
static void push_uid(IpcResp *rs) { ipc_push_raw(rs, g_uid, 16); }
static void last_user(SvcObj *o, IpcReq *rq, IpcResp *rs) { push_uid(rs); }
static void list_users(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    IpcBuf *b = rq->num_c ? &rq->c[0] : rq->num_b ? &rq->b[0] : &rq->x[0];
    if (b->addr && b->size >= 16) {
        memset((void *)b->addr, 0, b->size);
        memcpy((void *)b->addr, g_uid, 16);
    }
}
static void u8_0(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint8_t)0); }
static void u8_1(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint8_t)1); }
static void get_profile(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    ipc_push_object(rs, nx_obj_new(&svc_acc, "IProfile", NULL));
}
static void get_baas(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    ipc_push_object(rs, nx_obj_new(&svc_acc, "IManagerForApplication", NULL));
}

// ProfileBase: uid[16], last edit timestamp u64, nickname[0x21], pad
static void profile_base(uint8_t *p) {
    memset(p, 0, 0x38);
    memcpy(p, g_uid, 16);
    uint64_t ts = (uint64_t)time(NULL);
    memcpy(p + 0x10, &ts, 8);
    strcpy((char *)p + 0x18, "Player");
}
static void profile_get_base(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    uint8_t p[0x38];
    profile_base(p);
    ipc_push_raw(rs, p, sizeof p);
}
static void profile_get(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    IpcBuf *b = rq->num_c ? &rq->c[0] : &rq->b[0];
    if (b->addr) memset((void *)b->addr, 0, b->size);      // UserData (0x80): all zero
    profile_get_base(o, rq, rs);
}
static void image_size(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)0); }
static void baas_check_availability(SvcObj *o, IpcReq *rq, IpcResp *rs) { rs->result = 0x1BC7C; }  // network unavailable
static void baas_get_account_id(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint64_t)0x51); }

static const IpcCmd cmds[] = {
    {NULL, 0, user_count},                                // GetUserCount
    {NULL, 1, user_exists},                               // GetUserExistence
    {NULL, 2, list_users},                                // ListAllUsers
    {NULL, 3, list_users},                                // ListOpenUsers
    {NULL, 4, last_user},                                 // GetLastOpenedUser
    {NULL, 5, get_profile},                               // GetProfile
    {NULL, 50, u8_0},                                     // IsUserRegistrationRequestPermitted
    {NULL, 51, last_user},                                // TrySelectUserWithoutInteraction
    {NULL, 60, list_users},                               // ListOpenContextStoredUsers
    {NULL, 100, ok},                                      // InitializeApplicationInfoV0
    {NULL, 101, get_baas},                                // GetBaasAccountManagerForApplication
    {NULL, 110, ok},                                      // StoreSaveDataThumbnail
    {NULL, 111, ok},                                      // ClearSaveDataThumbnail
    {NULL, 130, ok},                                      // LoadOpenContext? (stub)
    {NULL, 131, list_users},                              // ListOpenContextStoredUsers
    {NULL, 140, ok},                                      // InitializeApplicationInfo
    {NULL, 141, list_users},                              // ListQualifiedUsers
    {NULL, 150, u8_0},                                    // IsUserAccountSwitchLocked
    {NULL, 160, ok},                                      // InitializeApplicationInfoV2
    {"IProfile", 0, profile_get},
    {"IProfile", 1, profile_get_base},
    {"IProfile", 10, image_size},
    {"IProfile", 11, image_size},                         // LoadImage: no image
    {"IManagerForApplication", 0, baas_check_availability},
    {"IManagerForApplication", 1, baas_get_account_id},
    {"IManagerForApplication", 130, u8_1},
    {0},
};
const ServiceDef svc_acc = {.name = "acc:u0", .cmds = cmds};
