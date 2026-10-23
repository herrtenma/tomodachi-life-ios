// ldn:u (local wireless, nn::ldn): research stub for the online exchange. A faithful state machine for a player who
// is alone: Initialize, OpenAccessPoint / OpenStation, CreateNetwork (a network with only us in it), Scan (finds
// nobody), Connect (fails: no such network). Every call is logged with its inputs (configs, advertise data) so the
// relay can be designed from what the game really sends. Command ids, structs and result codes per Ryujinx
// (Services/Ldn). NXRT_LDN=0: not registered (the old unimplemented stub session).
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "ipc.h"

extern const ServiceDef svc_ldn;

#define LDN_RES(desc) (((desc) << 9) | 203)
#define RES_LDN_INVALID_STATE LDN_RES(32)
#define RES_LDN_CONNECT_NOT_FOUND LDN_RES(65)

enum { ST_NONE, ST_INITIALIZED, ST_AP, ST_AP_CREATED, ST_STATION, ST_STATION_CONNECTED, ST_ERROR };
static const char *st_name[] = {"None", "Initialized", "AccessPoint", "AccessPointCreated", "Station",
                                "StationConnected", "Error"};

// NetworkInfo (0x480): NetworkId 0x00 (IntentId: local communication id u64 +0, scene id u16 +8; session id +0x10),
// Common 0x20 (mac, ssid +0x26, channel +0x48, link level +0x4a, network type +0x4b), Ldn 0x50 (security mode +0x60,
// accept policy +0x62, node count max +0x66, node count +0x67, nodes +0x68 (8 x 0x40: ipv4 +0, mac +4, node id +0xa,
// connected +0xb, user name +0xc, version +0x2e), advertise data size +0x26a, advertise data +0x26c (384)).
typedef struct {
    int state;
    uint32_t event_h;
    KEvent *event;
    uint8_t info[0x480];
    uint8_t advertise[384];
    uint16_t advertise_size;
} Ldn;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static const uint32_t k_ip = 0x0A0D2501, k_mask = 0xFFFFFF00;   // 10.13.37.1/24: our address in the fake network

static void hex(char *out, size_t n, const uint8_t *p, size_t len) {
    size_t o = 0;
    for (size_t i = 0; i < len && o + 3 < n; i++) o += snprintf(out + o, n - o, "%02x", p[i]);
    if (!len && n) out[0] = 0;
}
static void set_state(Ldn *l, int s) {
    if (l->state == s) return;
    static int n;                                        // the lobby cycles Initialized <-> Station for every scan
    if (n++ < 8 || (s != ST_STATION && l->state != ST_STATION)) nx_log("ldn: state %s -> %s", st_name[l->state], st_name[s]);
    l->state = s;
    if (l->event) nx_event_signal_obj(l->event);
}
// The game's buffers: pointer (C, 0x1a) or mapped (B, 0x6) out buffers depending on the command's descriptor type.
static IpcBuf *out_buf(IpcReq *rq) { return rq->num_c ? &rq->c[0] : rq->num_b ? &rq->b[0] : NULL; }
static IpcBuf *in_buf(IpcReq *rq) { return rq->num_x ? &rq->x[0] : rq->num_a ? &rq->a[0] : NULL; }

static void create_service(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    nx_log("ldn: CreateUserLocalCommunicationService");
    ipc_push_object(rs, nx_obj_new(&svc_ldn, "IUserLocalCommunicationService", calloc(1, sizeof(Ldn))));
}
static void create_monitor(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    ipc_push_object(rs, nx_obj_new(&svc_ldn, "IClientProcessMonitor", NULL));
}
static void ok(SvcObj *o, IpcReq *rq, IpcResp *rs) {}

static void get_state(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    Ldn *l = o->state;
    static int n;
    if (n++ < 4) nx_log("ldn: GetState -> %s", st_name[l->state]);
    OUT(rs, (uint32_t)l->state);
}
static void get_network_info(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    Ldn *l = o->state;
    IpcBuf *b = out_buf(rq);
    static int n;
    if (n++ < 4) nx_log("ldn: GetNetworkInfo (state %s, buffer %#llx)", st_name[l->state], b ? (unsigned long long)b->size : 0ull);
    if (b && b->addr) memset((void *)b->addr, 0, b->size < 0x480 ? b->size : 0x480);
    if (l->state != ST_AP_CREATED && l->state != ST_STATION_CONNECTED) { rs->result = RES_LDN_INVALID_STATE; return; }
    if (b && b->addr) memcpy((void *)b->addr, l->info, b->size < 0x480 ? b->size : 0x480);
}
static void get_ipv4(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    Ldn *l = o->state;
    nx_log("ldn: GetIpv4Address (state %s) -> 10.13.37.1/24", st_name[l->state]);
    OUT(rs, k_ip);
    OUT(rs, k_mask);
}
static void get_disconnect_reason(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint16_t)0); }
static void get_security_parameter(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    Ldn *l = o->state;
    uint8_t p[0x20] = {0};
    memcpy(p + 0x10, l->info + 0x10, 16);                // session id
    ipc_push_raw(rs, p, sizeof p);
}
static void get_network_config(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    Ldn *l = o->state;
    uint8_t c[0x20] = {0};
    memcpy(c, l->info, 0x10);                            // intent id
    memcpy(c + 0x10, l->info + 0x48, 2);                 // channel
    c[0x12] = l->info[0x66];                             // node count max
    memcpy(c + 0x14, l->info + 0x68 + 0x2e, 2);          // our local communication version
    ipc_push_raw(rs, c, sizeof c);
}
static void attach_state_change_event(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    Ldn *l = o->state;
    if (!l->event) l->event = nx_event_new_readable(&l->event_h);
    nx_log("ldn: AttachStateChangeEvent");
    ipc_push_copy(rs, l->event_h);
}
static void get_network_info_latest_update(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    get_network_info(o, rq, rs);
    if (rq->num_c > 1 && rq->c[1].addr) memset((void *)rq->c[1].addr, 0, rq->c[1].size);   // no node changes
}
// Scan(u16 channel, ScanFilter 0x60 at +8) -> (u16 count, buffer<NetworkInfo>). Nobody is nearby. A console's scan
// takes about a second (it listens on each channel); answering at once made the lobby rescan ~37 times a second.
// NXRT_LDN_SCAN_MS=<ms> (default 1000).
static void scan(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    Ldn *l = o->state;
    IpcBuf *b = out_buf(rq);
    static int n;
    uint64_t lcid;
    memcpy(&lcid, rq->data + 8, 8);
    if (n++ < 6)
        nx_log("ldn: Scan%s channel %u, filter: local communication id %016llx scene %u, flags %#x (state %s, room for %llu "
               "networks) -> 0 found", rq->cmd == 103 ? "Private" : "", IN(uint16_t, 0), (unsigned long long)lcid,
               IN(uint16_t, 8 + 8), IN(uint32_t, 8 + 0x5c), st_name[l->state], b ? (unsigned long long)(b->size / 0x480) : 0ull);
    if (b && b->addr) memset((void *)b->addr, 0, b->size);
    static int ms = -1;
    if (ms < 0) ms = getenv("NXRT_LDN_SCAN_MS") ? atoi(getenv("NXRT_LDN_SCAN_MS")) : 1000;
    pthread_mutex_unlock(&g_lock);                       // don't block GetState etc. while "listening"
    usleep(ms * 1000);
    pthread_mutex_lock(&g_lock);
    if (l->state != ST_AP && l->state != ST_STATION && l->state != ST_INITIALIZED) { rs->result = RES_LDN_INVALID_STATE; return; }
    OUT(rs, (uint16_t)0);
}
static void open_ap(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    Ldn *l = o->state;
    nx_log("ldn: OpenAccessPoint");
    if (l->state != ST_INITIALIZED) { rs->result = RES_LDN_INVALID_STATE; return; }
    set_state(l, ST_AP);
}
static void close_ap(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    Ldn *l = o->state;
    nx_log("ldn: CloseAccessPoint");
    set_state(l, ST_INITIALIZED);
}
// CreateNetwork(SecurityConfig 0x44, UserConfig 0x30 at +0x44, NetworkConfig 0x20 at +0x78); Private adds a
// SecurityParameter (0x20) after the SecurityConfig and an address list buffer.
static void create_network(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    Ldn *l = o->state;
    int priv = rq->cmd == 203;
    const uint8_t *sec = rq->data, *user = rq->data + 0x44 + (priv ? 0x20 : 0), *net = user + 0x30 + 4;
    char name[34] = {0}, pass[140];
    memcpy(name, user, 33);
    hex(pass, sizeof pass, sec + 4, sec[2] < 64 ? sec[2] : 64);
    uint64_t lcid;
    memcpy(&lcid, net, 8);
    uint16_t scene, channel, version;
    memcpy(&scene, net + 8, 2);
    memcpy(&channel, net + 0x10, 2);
    memcpy(&version, net + 0x14, 2);
    nx_log("ldn: CreateNetwork%s: security mode %u passphrase (%u bytes) %s, user \"%s\", local communication id %016llx "
           "scene %u, channel %u, max nodes %u, version %u", priv ? "Private" : "", sec[0] | sec[1] << 8, sec[2] | sec[3] << 8,
           pass, name, (unsigned long long)lcid, scene, channel, net[0x12], version);
    if (l->state != ST_AP) { rs->result = RES_LDN_INVALID_STATE; return; }
    uint8_t *i = l->info;
    memset(i, 0, sizeof l->info);
    memcpy(i, net, 0x10);                                // intent id
    arc4random_buf(i + 0x10, 16);                        // session id
    static const uint8_t mac[6] = {0x02, 0x00, 0x0a, 0x0d, 0x25, 0x01};
    memcpy(i + 0x20, mac, 6);
    uint16_t ch = channel ? channel : 6;
    memcpy(i + 0x48, &ch, 2);
    i[0x4a] = 3;                                         // link level
    i[0x4b] = 2;                                         // network type: ldn
    memcpy(i + 0x60, sec, 2);                            // security mode
    i[0x66] = net[0x12];                                 // node count max
    i[0x67] = 1;                                         // node count: us
    uint8_t *node = i + 0x68;
    memcpy(node, &k_ip, 4);
    memcpy(node + 4, mac, 6);
    node[0xa] = 0;
    node[0xb] = 1;
    memcpy(node + 0xc, name, 33);
    memcpy(node + 0x2e, &version, 2);
    memcpy(i + 0x26a, &l->advertise_size, 2);
    memcpy(i + 0x26c, l->advertise, l->advertise_size);
    set_state(l, ST_AP_CREATED);
}
static void destroy_network(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    Ldn *l = o->state;
    nx_log("ldn: DestroyNetwork");
    if (l->state == ST_AP_CREATED) set_state(l, ST_AP);
}
static void set_advertise_data(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    Ldn *l = o->state;
    IpcBuf *b = in_buf(rq);
    size_t n = b ? (b->size < 384 ? b->size : 384) : 0;
    if (b && b->addr) memcpy(l->advertise, (void *)b->addr, n);
    l->advertise_size = (uint16_t)n;
    memcpy(l->info + 0x26a, &l->advertise_size, 2);
    memcpy(l->info + 0x26c, l->advertise, n);
    char h[2 * 384 + 1];
    hex(h, sizeof h, l->advertise, n);
    nx_log("ldn: SetAdvertiseData %zu bytes: %s", n, h);
}
static void set_accept_policy(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    nx_log("ldn: SetStationAcceptPolicy %u", IN(uint8_t, 0));
    ((Ldn *)o->state)->info[0x62] = IN(uint8_t, 0);
}
static void open_station(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    Ldn *l = o->state;
    static int n;
    if (n++ < 4) nx_log("ldn: OpenStation");
    if (l->state != ST_INITIALIZED) { rs->result = RES_LDN_INVALID_STATE; return; }
    set_state(l, ST_STATION);
}
static void close_station(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    static int n;
    if (n++ < 4) nx_log("ldn: CloseStation");
    set_state(o->state, ST_INITIALIZED);
}
static void connect(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    nx_log("ldn: Connect%s (nobody to connect to)", rq->cmd == 303 ? "Private" : "");
    rs->result = RES_LDN_CONNECT_NOT_FOUND;
}
static void disconnect(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    Ldn *l = o->state;
    nx_log("ldn: Disconnect");
    if (l->state == ST_STATION_CONNECTED) set_state(l, ST_STATION);
}
static void initialize(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    Ldn *l = o->state;
    nx_log("ldn: Initialize (cmd %u)", rq->cmd);
    if (l->state == ST_NONE) set_state(l, ST_INITIALIZED);
}
static void finalize(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    nx_log("ldn: Finalize");
    set_state(o->state, ST_NONE);
}
static void unknown(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    char h[2 * 64 + 1];
    hex(h, sizeof h, rq->data, 64);
    nx_log("ldn: %s command %u NOT IMPLEMENTED (accepted, empty reply); x %d a %d b %d c %d; data %s",
           o->iface ? o->iface : "root", rq->cmd, rq->num_x, rq->num_a, rq->num_b, rq->num_c, h);
}

static void locked(SvcObj *o, IpcReq *rq, IpcResp *rs, IpcFn fn) {
    pthread_mutex_lock(&g_lock);
    fn(o, rq, rs);
    pthread_mutex_unlock(&g_lock);
}
#define WRAP(fn) static void w_##fn(SvcObj *o, IpcReq *rq, IpcResp *rs) { locked(o, rq, rs, fn); }
WRAP(get_state) WRAP(get_network_info) WRAP(get_ipv4) WRAP(get_disconnect_reason) WRAP(get_security_parameter)
WRAP(get_network_config) WRAP(attach_state_change_event) WRAP(get_network_info_latest_update) WRAP(scan) WRAP(open_ap)
WRAP(close_ap) WRAP(create_network) WRAP(destroy_network) WRAP(set_advertise_data) WRAP(set_accept_policy)
WRAP(open_station) WRAP(close_station) WRAP(connect) WRAP(disconnect) WRAP(initialize) WRAP(finalize)

#define U "IUserLocalCommunicationService"
static const IpcCmd cmds[] = {
    {NULL, 0, create_service},                            // CreateUserLocalCommunicationService
    {NULL, 1, create_monitor},                            // CreateClientProcessMonitor (18.0.0+)
    {"IClientProcessMonitor", 0, ok},                     // RegisterClient
    {U, 0, w_get_state},
    {U, 1, w_get_network_info},
    {U, 2, w_get_ipv4},
    {U, 3, w_get_disconnect_reason},
    {U, 4, w_get_security_parameter},
    {U, 5, w_get_network_config},
    {U, 100, w_attach_state_change_event},
    {U, 101, w_get_network_info_latest_update},
    {U, 102, w_scan},
    {U, 103, w_scan},                                     // ScanPrivate
    {U, 104, ok},                                         // SetWirelessControllerRestriction
    {U, 106, ok},                                         // SetProtocol (20.0.0+)
    {U, 200, w_open_ap},
    {U, 201, w_close_ap},
    {U, 202, w_create_network},
    {U, 203, w_create_network},                           // CreateNetworkPrivate
    {U, 204, w_destroy_network},
    {U, 205, ok},                                         // Reject
    {U, 206, w_set_advertise_data},
    {U, 207, w_set_accept_policy},
    {U, 208, ok},                                         // AddAcceptFilterEntry
    {U, 209, ok},                                         // ClearAcceptFilter
    {U, 300, w_open_station},
    {U, 301, w_close_station},
    {U, 302, w_connect},
    {U, 303, w_connect},                                  // ConnectPrivate
    {U, 304, w_disconnect},
    {U, 400, w_initialize},                               // InitializeOld
    {U, 401, w_finalize},
    {U, 402, w_initialize},                               // Initialize (7.0.0+)
    {0},
};
const ServiceDef svc_ldn = {.name = "ldn:u", .cmds = cmds, .fallback = unknown};
