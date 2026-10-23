// Small services touched early in boot. Answers are the "plain offline console" ones:
// no parental restrictions, no DLC, no network, English, firmware 20.5.
#include <stdlib.h>
#include <string.h>

#include "ipc.h"

static void ok(SvcObj *o, IpcReq *rq, IpcResp *rs) {}
static void u8_0(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint8_t)0); }
static void u8_1(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint8_t)1); }
static void u32_0(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)0); }
static void u64_0(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint64_t)0); }
static void new_event(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    uint32_t h;
    nx_event_new_readable(&h);
    ipc_push_copy(rs, h);
}

// ---- pctl --------------------------------------------------------------------------
extern const ServiceDef svc_pctl;
static void pctl_create(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    ipc_push_object(rs, nx_obj_new(&svc_pctl, "IParentalControlService", NULL));
}
static const IpcCmd pctl_cmds[] = {
    {NULL, 0, pctl_create},                               // CreateService
    {NULL, 1, pctl_create},                               // CreateServiceWithoutInitialize
    {"IParentalControlService", 1, ok},                   // Initialize
    {"IParentalControlService", 1001, ok},                // CheckFreeCommunicationPermission
    {"IParentalControlService", 1002, ok},                // ConfirmLaunchApplicationPermission
    {"IParentalControlService", 1006, u8_0},              // IsRestrictedSystemSettingsEntered
    {"IParentalControlService", 1013, ok},                // ConfirmStereoVisionPermission
    {"IParentalControlService", 1017, ok},                // EndFreeCommunication
    {"IParentalControlService", 1018, u8_0},              // IsFreeCommunicationAvailable
    {"IParentalControlService", 1031, u8_0},              // IsRestrictionEnabled
    {"IParentalControlService", 1032, u32_0},             // GetSafetyLevel
    {"IParentalControlService", 1034, ok},                // GetFreeCommunicationApplicationListCount? (stub)
    {"IParentalControlService", 1035, ok},                // GetCurrentSettings
    {"IParentalControlService", 1039, u32_0},             // GetFreeCommunicationApplicationListCount
    {"IParentalControlService", 1061, ok},                // ConfirmStereoVisionRestrictionConfigurable
    {"IParentalControlService", 1064, ok},                // ResetConfirmedStereoVisionPermission
    {"IParentalControlService", 1065, u8_0},              // IsStereoVisionPermitted
    {"IParentalControlService", 1403, u8_0},              // IsPairingActive
    {"IParentalControlService", 1432, new_event},         // GetSynchronizationEvent
    {"IParentalControlService", 1451, ok},                // StartPlayTimer
    {"IParentalControlService", 1452, ok},                // StopPlayTimer
    {"IParentalControlService", 1453, u8_0},              // IsPlayTimerEnabled
    {"IParentalControlService", 1454, u64_0},             // GetPlayTimerRemainingTime
    {"IParentalControlService", 1455, u8_0},              // IsRestrictedByPlayTimer
    {"IParentalControlService", 1456, ok},                // GetPlayTimerSettings
    {"IParentalControlService", 1457, new_event},         // GetPlayTimerEventToRequestSuspension
    {"IParentalControlService", 1458, u8_0},              // IsPlayTimerAlarmDisabled
    {"IParentalControlService", 1471, ok},                // NotifyWrongPinCodeInputManyTimes
    {"IParentalControlService", 1473, new_event},         // GetUnlinkedEvent
    {"IParentalControlService", 1474, ok},                // ClearUnlinkedEvent
    {0},
};
const ServiceDef svc_pctl = {.name = "pctl", .cmds = pctl_cmds};

// ---- aoc:u (add-on content): nothing installed --------------------------------------
static const IpcCmd aoc_cmds[] = {
    {NULL, 2, u32_0},                                     // CountAddOnContent
    {NULL, 3, u32_0},                                     // ListAddOnContent
    {NULL, 5, u64_0},                                     // GetAddOnContentBaseId
    {NULL, 7, ok},                                        // PrepareAddOnContent
    {NULL, 8, new_event},                                 // GetAddOnContentListChangedEvent
    {NULL, 10, new_event},                                // GetAddOnContentListChangedEventWithProcessId
    {NULL, 11, ok},                                       // NotifyMountAddOnContent
    {NULL, 12, ok},                                       // NotifyUnmountAddOnContent
    {NULL, 50, ok},                                       // CheckAddOnContentMountStatus
    {NULL, 100, ok},                                      // CreateEcPurchasedEventManager (stub)
    {0},
};
const ServiceDef svc_aoc = {.name = "aoc:u", .cmds = aoc_cmds};

// ---- ectx:aw (error context) ------------------------------------------------------
extern const ServiceDef svc_ectx;
static void ectx_create(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    ipc_push_object(rs, nx_obj_new(&svc_ectx, "IContextRegistrar", NULL));
}
static const IpcCmd ectx_cmds[] = {
    {NULL, 0, ectx_create},                               // CreateContextRegistrar
    {"IContextRegistrar", 0, ok},                         // Complete
    {0},
};
const ServiceDef svc_ectx = {.name = "ectx:aw", .cmds = ectx_cmds};

// ---- set / set:sys -----------------------------------------------------------------
static uint64_t lang_code(const char *s) {
    char b[8] = {0};
    strncpy(b, s, 8);
    uint64_t v;
    memcpy(&v, b, 8);
    return v;
}
static void set_get_language_code(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, lang_code("en-US")); }
static void set_make_language_code(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    static const char *langs[] = {"ja", "en-US", "fr", "de", "it", "es", "zh-CN", "ko", "nl", "pt",
                                  "ru", "zh-TW", "en-GB", "fr-CA", "es-419", "zh-Hans", "zh-Hant", "pt-BR"};
    uint32_t i = IN(uint32_t, 0);
    OUT(rs, lang_code(i < 18 ? langs[i] : "en-US"));
}
static void set_get_available_language_codes(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    static const char *langs[] = {"ja", "en-US", "fr", "de", "it", "es", "zh-CN", "ko", "nl", "pt",
                                  "ru", "zh-TW", "en-GB", "fr-CA", "es-419", "zh-Hans", "zh-Hant", "pt-BR"};
    IpcBuf *b = rq->num_c ? &rq->c[0] : &rq->b[0];
    uint32_t n = 0;
    for (; n < 18 && (n + 1) * 8 <= b->size; n++) ((uint64_t *)b->addr)[n] = lang_code(langs[n]);
    OUT(rs, n);
}
static void set_get_region_code(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)1); }   // USA
static void set_get_key_code_map(SvcObj *o, IpcReq *rq, IpcResp *rs) {}
static const IpcCmd set_cmds[] = {
    {NULL, 0, set_get_language_code},
    {NULL, 1, set_get_available_language_codes},
    {NULL, 2, set_make_language_code},
    {NULL, 3, u32_0},                                     // GetAvailableLanguageCodeCount (filled below?)
    {NULL, 4, set_get_region_code},
    {NULL, 5, set_get_available_language_codes},          // GetAvailableLanguageCodes2
    {NULL, 6, u32_0},                                     // GetAvailableLanguageCodeCount2
    {NULL, 7, set_get_key_code_map},
    {0},
};
const ServiceDef svc_set = {.name = "set", .cmds = set_cmds};

static void setsys_get_firmware_version(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    // FirmwareVersion: major, minor, micro, pad, revision major/minor, pad, platform[0x20],
    // version hash[0x40], display version[0x18], display title[0x80]
    uint8_t fw[0x100] = {20, 5, 0, 0, 0, 0, 0, 0};
    strcpy((char *)fw + 0x8, "NX");
    strcpy((char *)fw + 0x68, "20.5.0");
    strcpy((char *)fw + 0x80, "NintendoSDK Firmware for NX 20.5.0");
    IpcBuf *b = rq->num_c ? &rq->c[0] : &rq->x[0];
    if (rq->num_b) b = &rq->b[0];
    memcpy((void *)b->addr, fw, b->size < sizeof fw ? b->size : sizeof fw);
}
static const IpcCmd setsys_cmds[] = {
    {NULL, 3, setsys_get_firmware_version},               // GetFirmwareVersion
    {NULL, 4, setsys_get_firmware_version},               // GetFirmwareVersion2
    {NULL, 23, u32_0},                                    // GetColorSetId
    {NULL, 37, u64_0},                                    // GetSettingsItemValueSize
    {NULL, 38, u64_0},                                    // GetSettingsItemValue
    {0},
};
const ServiceDef svc_setsys = {.name = "set:sys", .cmds = setsys_cmds};

// ---- prepo:u (play reports): accepted and dropped ----------------------------------
static const IpcCmd prepo_cmds[] = {
    {NULL, 10100, ok}, {NULL, 10101, ok}, {NULL, 10102, ok}, {NULL, 10103, ok},
    {NULL, 10104, ok}, {NULL, 10105, ok}, {NULL, 10106, ok}, {NULL, 10107, ok},
    {NULL, 10300, ok},                                    // GetTransmissionStatus
    {NULL, 20100, ok}, {NULL, 20101, ok},
    {0},
};
const ServiceDef svc_prepo = {.name = "prepo:u", .cmds = prepo_cmds};

// ---- nifm:u (network): no connection -----------------------------------------------
extern const ServiceDef svc_nifm;
static void nifm_create_general(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    ipc_push_object(rs, nx_obj_new(&svc_nifm, "IGeneralService", NULL));
}
static void nifm_create_request(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    ipc_push_object(rs, nx_obj_new(&svc_nifm, "IRequest", NULL));
}
static void nifm_two_events(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    uint32_t a, b;
    nx_event_new_readable(&a);
    nx_event_new_readable(&b);
    ipc_push_copy(rs, a);
    ipc_push_copy(rs, b);
}
static void nifm_request_state(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)1); }   // Error/none
static void nifm_request_result(SvcObj *o, IpcReq *rq, IpcResp *rs) { rs->result = 0x3016E; }  // not connected
static void nifm_internet_status(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)0); }
static const IpcCmd nifm_cmds[] = {
    {NULL, 4, nifm_create_general},                       // CreateGeneralServiceOld
    {NULL, 5, nifm_create_general},                       // CreateGeneralService
    {"IGeneralService", 1, ok},                           // GetClientId
    {"IGeneralService", 4, nifm_create_request},          // CreateRequest
    {"IGeneralService", 5, ok},                           // GetCurrentNetworkProfile
    {"IGeneralService", 12, ok},                          // GetCurrentIpAddress
    {"IGeneralService", 18, nifm_internet_status},        // GetInternetConnectionStatus
    {"IGeneralService", 21, u8_0},                        // IsAnyInternetRequestAccepted
    {"IGeneralService", 22, u8_0},                        // IsAnyForegroundRequestAccepted
    {"IRequest", 0, nifm_request_state},                  // GetRequestState
    {"IRequest", 1, nifm_request_result},                 // GetResult
    {"IRequest", 2, nifm_two_events},                     // GetSystemEventReadableHandles
    {"IRequest", 3, ok},                                  // Cancel
    {"IRequest", 4, ok},                                  // Submit
    {"IRequest", 6, ok},                                  // SetRequirementPreset
    {"IRequest", 11, ok},                                 // SetConnectionConfirmationOption
    {"IRequest", 21, ok},                                 // GetAppletInfo
    {"IRequest", 22, ok},                                 // GetAdditionalInfo
    {0},
};
const ServiceDef svc_nifm = {.name = "nifm:u", .cmds = nifm_cmds};

// unused helpers kept for later services
void misc_unused(void) { (void)u8_1; }

// ---- mii:e / mii:u — the console's Mii database: empty -----------------------------
extern const ServiceDef svc_mii;
static void mii_get_db(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    ipc_push_object(rs, nx_obj_new(&svc_mii, "IDatabaseService", NULL));
}
// NXRT_MIILOG=1: log the game's Mii database requests (first 20 of each).
static void mii_log(IpcReq *rq, const char *what) {
    static int on = -1, n[64];
    if (on < 0) on = getenv("NXRT_MIILOG") != NULL;
    if (on && rq->cmd < 64 && n[rq->cmd]++ < 20)
        nx_log("mii: IDatabaseService #%u %s (source flag/arg %#x)", rq->cmd, what, rq->data ? *(uint32_t *)rq->data : 0);
}
static void mii_get_list(SvcObj *o, IpcReq *rq, IpcResp *rs) { mii_log(rq, "Get -> 0 Miis"); OUT(rs, (uint32_t)0); }   // 0 elements
static void mii_find_index(SvcObj *o, IpcReq *rq, IpcResp *rs) { mii_log(rq, "FindIndex/GetIndex -> -1"); OUT(rs, (int32_t)-1); }
static void mii_count(SvcObj *o, IpcReq *rq, IpcResp *rs) { mii_log(rq, "GetCount -> 0"); OUT(rs, (uint32_t)0); }

// CharInfo (0x58): create id[16], name u16[11], then one byte per field in this order:
// font_region favorite_color gender height build type region_move faceline_type
// faceline_color faceline_wrinkle faceline_make hair_type hair_color hair_flip eye_type
// eye_color eye_scale eye_aspect eye_rotate eye_x eye_y eyebrow_type eyebrow_color
// eyebrow_scale eyebrow_aspect eyebrow_rotate eyebrow_x eyebrow_y nose_type nose_scale
// nose_y mouth_type mouth_color mouth_scale mouth_aspect mouth_y beard_color beard_type
// mustache_type mustache_scale mustache_y glass_type glass_color glass_scale glass_y
// mole_type mole_scale mole_x mole_y reserved
static void mii_char_info(uint8_t *ci, int female, uint32_t seed) {
    memset(ci, 0, 0x58);
    for (int i = 0; i < 16; i++) ci[i] = (uint8_t)(seed * 2654435761u >> (i % 4 * 8)) ^ (uint8_t)i;
    ci[6] = (ci[6] & 0x0F) | 0x40;                         // a well-formed v4-style create id
    ci[8] = (ci[8] & 0x3F) | 0x80;
    const char *nm = female ? "Mii" : "Mii";
    for (int i = 0; nm[i]; i++) ci[0x10 + 2 * i] = (uint8_t)nm[i];
    static const uint8_t male[] = {0, 0, 0, 64, 64, 0, 0,  0, 0, 0, 0, 33, 1, 0,  2, 0, 4, 3, 4, 2, 12,
                                   6, 1, 4, 3, 6, 2, 10,   1, 4, 9,   23, 0, 4, 3, 13,  0, 0, 0, 4, 10,
                                   0, 0, 4, 10,   0, 4, 2, 20, 0};
    static const uint8_t fem[] = {0, 0, 1, 64, 64, 0, 0,  0, 0, 0, 0, 12, 1, 0,  4, 0, 4, 3, 3, 2, 12,
                                  0, 1, 4, 3, 6, 2, 10,   1, 4, 9,   23, 0, 4, 3, 13,  0, 0, 0, 4, 10,
                                  0, 0, 4, 10,   0, 4, 2, 20, 0};
    memcpy(ci + 0x26, female ? fem : male, sizeof male);
}
// The six system default Miis (nn::mii BuildDefault), CharInfo bytes 0x26..0x57 in CharInfo field order;
// generated from Ryujinx DefaultMii.cs (table rows 2..7) with the Ver3 colour conversions applied.
static const uint8_t g_default_mii[6][50] = {
    {0, 4, 0, 64, 64, 0, 0, 0, 4, 0, 0, 68, 8, 0, 2, 8, 4, 3, 4, 2, 12, 6, 8, 4, 3, 6, 2, 10, 1, 4, 9, 23, 19, 4, 3, 13, 8, 0, 0, 4, 10, 0, 8, 4, 10, 0, 4, 2, 20, 0},   // 'no name'
    {0, 5, 0, 64, 64, 0, 0, 0, 0, 0, 0, 55, 6, 0, 2, 12, 4, 3, 4, 2, 12, 6, 6, 4, 3, 6, 2, 10, 1, 4, 9, 23, 19, 4, 3, 13, 8, 0, 0, 4, 10, 0, 8, 4, 10, 0, 4, 2, 20, 0},   // 'no name'
    {0, 0, 0, 64, 64, 0, 0, 0, 1, 0, 0, 33, 1, 0, 2, 8, 4, 3, 4, 2, 12, 6, 1, 4, 3, 6, 2, 10, 1, 4, 9, 23, 19, 4, 3, 13, 8, 0, 0, 4, 10, 0, 8, 4, 10, 0, 4, 2, 20, 0},   // 'no name'
    {0, 2, 1, 64, 64, 0, 0, 0, 2, 0, 0, 24, 8, 0, 4, 8, 4, 3, 3, 2, 12, 0, 8, 4, 3, 6, 2, 10, 1, 4, 9, 23, 19, 4, 3, 13, 8, 0, 0, 4, 10, 0, 8, 4, 10, 0, 4, 2, 20, 0},   // 'no name'
    {0, 6, 1, 64, 64, 0, 0, 0, 0, 0, 0, 14, 7, 0, 4, 13, 4, 3, 3, 2, 12, 0, 7, 4, 3, 6, 2, 10, 1, 4, 9, 23, 19, 4, 3, 13, 8, 0, 0, 4, 10, 0, 8, 4, 10, 0, 4, 2, 20, 0},   // 'no name'
    {0, 7, 1, 64, 64, 0, 0, 0, 0, 0, 0, 12, 1, 0, 4, 8, 4, 3, 3, 2, 12, 0, 1, 4, 3, 6, 2, 10, 1, 4, 9, 23, 19, 4, 3, 13, 8, 0, 0, 4, 10, 0, 8, 4, 10, 0, 4, 2, 20, 0},   // 'no name'
};

static void mii_build_default(SvcObj *o, IpcReq *rq, IpcResp *rs) {   // BuildDefault(index 0..5)
    uint32_t idx = IN(uint32_t, 0);
    uint8_t ci[0x58];
    mii_log(rq, "BuildDefault");
    mii_char_info(ci, idx >= 3, idx + 1);                  // create id
    if (idx < 6) {
        static const char nm[] = "no name";
        memset(ci + 0x10, 0, 0x16);
        for (int i = 0; nm[i]; i++) ci[0x10 + 2 * i] = (uint8_t)nm[i];
        memcpy(ci + 0x26, g_default_mii[idx], sizeof g_default_mii[idx]);
    }
    ipc_push_raw(rs, ci, sizeof ci);
}
static void mii_build_random(SvcObj *o, IpcReq *rq, IpcResp *rs) {    // BuildRandom(age, gender, race)
    uint32_t gender = IN(uint32_t, 4);
    uint8_t ci[0x58];
    mii_log(rq, "BuildRandom");
    mii_char_info(ci, gender == 1, arc4random());
    ipc_push_raw(rs, ci, sizeof ci);
}
static const IpcCmd mii_cmds[] = {
    {NULL, 0, mii_get_db},                                // GetDatabaseService
    {"IDatabaseService", 0, u8_0},                        // IsUpdated
    {"IDatabaseService", 1, u8_0},                        // IsFullDatabase
    {"IDatabaseService", 2, mii_count},                   // GetCount
    {"IDatabaseService", 3, mii_get_list},                // Get
    {"IDatabaseService", 4, mii_get_list},                // Get1
    {"IDatabaseService", 5, ok},                          // UpdateLatest
    {"IDatabaseService", 6, mii_build_random},            // BuildRandom
    {"IDatabaseService", 7, mii_build_default},           // BuildDefault
    {"IDatabaseService", 8, mii_get_list},                // Get2
    {"IDatabaseService", 9, mii_get_list},                // Get3
    {"IDatabaseService", 11, mii_find_index},             // FindIndex
    {"IDatabaseService", 20, u8_0},                       // IsBrokenDatabaseWithClearFlag
    {"IDatabaseService", 21, mii_find_index},             // GetIndex
    {"IDatabaseService", 22, ok},                         // SetInterfaceVersion
    {0},
};
const ServiceDef svc_mii = {.name = "mii:e", .cmds = mii_cmds};

// ---- ngc:u — profanity filter: everything is clean ---------------------------------
static void ngc_version(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)1); }
static void ngc_mask(SvcObj *o, IpcReq *rq, IpcResp *rs) {      // copy input text to output unchanged
    IpcBuf *in = rq->num_a ? &rq->a[0] : &rq->x[0];
    IpcBuf *out = rq->num_b ? &rq->b[0] : &rq->c[0];
    if (in->addr && out->addr) memcpy((void *)out->addr, (void *)in->addr, in->size < out->size ? in->size : out->size);
    OUT(rs, (uint32_t)0);
}
static const IpcCmd ngc_cmds[] = {
    {NULL, 0, ngc_version},                               // GetContentVersion
    {NULL, 1, u32_0},                                     // Check -> no flags
    {NULL, 2, ngc_mask},                                  // Mask
    {NULL, 3, ok},                                        // Reload
    {0},
};
const ServiceDef svc_ngc = {.name = "ngc:u", .cmds = ngc_cmds};
