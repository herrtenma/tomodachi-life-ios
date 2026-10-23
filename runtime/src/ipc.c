// Horizon IPC: HIPC message framing + CMIF (SFCI/SFCO, domains) on top of host-side
// service objects. Reference: Ryujinx IpcMessage/ServiceCtx, Atmosphère sf/hipc.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ipc.h"

#define SFCI 0x49434653u
#define SFCO 0x4F434653u

enum { MT_CLOSE = 2, MT_LEGACY_REQUEST = 1, MT_LEGACY_CONTROL = 3, MT_REQUEST = 4,
       MT_CONTROL = 5, MT_REQUEST_CTX = 6, MT_CONTROL_CTX = 7 };

// ---- service registry --------------------------------------------------------------

static struct { const char *name; const ServiceDef *def; } g_services[256];
static int g_nservices;

void nx_service_register(const ServiceDef *def) { nx_service_alias(def->name, def); }

void nx_service_alias(const char *name, const ServiceDef *def) {
    g_services[g_nservices].name = name;
    g_services[g_nservices++].def = def;
}

static const ServiceDef *find_service(const char *name) {
    for (int i = 0; i < g_nservices; i++)
        if (!strcmp(g_services[i].name, name)) return g_services[i].def;
    return NULL;
}

// Services nobody has written yet: the first request stops the run and names the call.
static void unknown_cmd(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    static int lenient = -1;
    if (lenient < 0) lenient = getenv("NXRT_LENIENT") != NULL;
    if (lenient) {                      // exploration mode: accept with an empty reply
        nx_log("LENIENT: %s (%s) command %u accepted with empty reply", o->def->name,
               o->iface ? o->iface : "root", rq->cmd);
        return;
    }
    nx_fatal("service '%s' (%s): command %u not implemented", o->def->name,
             o->iface ? o->iface : "root", rq->cmd);
}
static const ServiceDef g_stub = {.name = "<stub>", .fallback = unknown_cmd};

SvcObj *nx_obj_new(const ServiceDef *def, const char *iface, void *state) {
    SvcObj *o = calloc(1, sizeof *o);
    o->def = def;
    o->iface = iface;
    o->state = state;
    return o;
}

// ---- sessions ----------------------------------------------------------------------

typedef struct Session {
    SvcObj *root;
    int is_domain;
    int refs;            // session handles (clones share the session)
    SvcObj *objs[512];   // domain object table, id = index + 1
} Session;

// Last handle closed: free the session and its objects. Object state belongs to the service.
// Called from CloseHandle with g_klock held.
static void session_handle_destroy(KObject *k) {
    Session *s = k->ptr;
    free(k);
    if (--s->refs) return;
    for (int i = 0; i < 512; i++)
        if (s->objs[i] && s->objs[i] != s->root) free(s->objs[i]);
    free(s->root);
    free(s);
}

static KObject *session_kobj(Session *s) {
    KObject *k = calloc(1, sizeof *k);
    k->type = KO_SESSION;
    k->ptr = s;
    k->destroy = session_handle_destroy;
    s->refs++;
    return k;
}

static uint32_t new_session_handle(SvcObj *root) {
    Session *s = calloc(1, sizeof *s);
    s->root = root;
    pthread_mutex_lock(&g_klock);
    KObject *k = session_kobj(s);
    uint32_t h = nx_handle_new(k);
    pthread_mutex_unlock(&g_klock);
    return h;
}

uint32_t nx_session_for(const char *service_name, uint32_t *out_handle) {
    const ServiceDef *def = find_service(service_name);
    SvcObj *o;
    if (def) {
        o = nx_obj_new(def, NULL, NULL);
        if (def->open) def->open(o);
    } else {
        nx_log("ipc: service '%s' has no implementation (stub session)", service_name);
        ServiceDef *stub = calloc(1, sizeof *stub);
        *stub = g_stub;
        stub->name = strdup(service_name);
        o = nx_obj_new(stub, NULL, NULL);
    }
    *out_handle = new_session_handle(o);
    return 0;
}

uint32_t nx_ipc_connect_named_port(const char *name, uint32_t *out_handle) {
    char n[9] = {0};
    memcpy(n, name, 8);
    if (strcmp(n, "sm:")) nx_fatal("ConnectToNamedPort(%s): only sm: is supported", n);
    return nx_session_for("sm:", out_handle);
}

// ---- message parsing ---------------------------------------------------------------

static void parse(uint8_t *msg, IpcReq *rq) {
    uint32_t *w = (uint32_t *)msg;
    memset(rq, 0, sizeof *rq);
    rq->msg = msg;
    rq->type = w[0] & 0xFFFF;
    rq->num_x = (w[0] >> 16) & 0xF;
    rq->num_a = (w[0] >> 20) & 0xF;
    rq->num_b = (w[0] >> 24) & 0xF;
    rq->num_w = (w[0] >> 28) & 0xF;
    uint32_t data_words = w[1] & 0x3FF;
    rq->recv_flags = (w[1] >> 10) & 0xF;
    int pos = 2;
    if (w[1] >> 31) {
        uint32_t sh = w[pos++];
        int send_pid = sh & 1;
        rq->num_copy = (sh >> 1) & 0xF;
        rq->num_move = (sh >> 5) & 0xF;
        if (send_pid) {
            rq->pid = w[pos] | (uint64_t)w[pos + 1] << 32;
            pos += 2;
        }
        for (int i = 0; i < rq->num_copy; i++) rq->copy[i] = w[pos++];
        for (int i = 0; i < rq->num_move; i++) rq->move[i] = w[pos++];
    }
    for (int i = 0; i < rq->num_x; i++, pos += 2) {        // X: send statics (pointers)
        uint32_t a = w[pos], b = w[pos + 1];
        rq->x[i].size = a >> 16;
        rq->x[i].addr = b | ((uint64_t)(a >> 12 & 0xF) << 32) | ((uint64_t)(a >> 6 & 0x3F) << 36);
        rq->x[i].index = (a & 0x3F) | ((a >> 9 & 0x7) << 6);
    }
    IpcBuf *bufs[3] = {rq->a, rq->b, rq->w};
    int counts[3] = {rq->num_a, rq->num_b, rq->num_w};
    for (int k = 0; k < 3; k++)                             // A/B/W: send/recv/exchange buffers
        for (int i = 0; i < counts[k]; i++, pos += 3) {
            uint32_t sz = w[pos], lo = w[pos + 1], pk = w[pos + 2];
            bufs[k][i].size = sz | ((uint64_t)(pk >> 24 & 0xF) << 32);
            bufs[k][i].addr = lo | ((uint64_t)(pk >> 28 & 0xF) << 32) | ((uint64_t)(pk >> 2 & 0x7) << 36);
            bufs[k][i].index = pk & 3;                      // flags
        }
    rq->hipc_data = msg + pos * 4;                          // HIPC data words (TIPC uses these)
    int raw_start = (pos * 4 + 15) & ~15;                   // CMIF data is 16-byte aligned
    rq->raw = msg + raw_start;
    rq->raw_size = data_words * 4 - (raw_start - pos * 4);
    rq->c_pos = pos + data_words;                           // C descriptors follow the data
    if (rq->recv_flags >= 2) {                              // receive list (C buffers)
        int n = rq->recv_flags == 2 ? 1 : rq->recv_flags - 2;
        for (int i = 0; i < n && i < 8; i++) {
            uint32_t lo = w[rq->c_pos + 2 * i], hi = w[rq->c_pos + 2 * i + 1];
            rq->c[i].addr = lo | ((uint64_t)(hi & 0xFFFF) << 32);
            rq->c[i].size = hi >> 16;
        }
        rq->num_c = n;
    }
}

// ---- responses ---------------------------------------------------------------------

void ipc_push_raw(IpcResp *rs, const void *p, size_t n) {
    if (rs->out_size + n > sizeof rs->out) nx_fatal("ipc: response too large");
    memcpy(rs->out + rs->out_size, p, n);
    rs->out_size += n;
}

void ipc_push_copy(IpcResp *rs, uint32_t h) {          // the receiver gets its own handle
    pthread_mutex_lock(&g_klock);
    KObject *o = nx_handle_get(h);
    uint32_t dup = o ? nx_handle_new(o) : h;
    pthread_mutex_unlock(&g_klock);
    rs->copy[rs->num_copy++] = dup;
}
void ipc_push_move(IpcResp *rs, uint32_t h) { rs->move[rs->num_move++] = h; }
void ipc_push_object(IpcResp *rs, SvcObj *o) { rs->objs[rs->num_objs++] = o; }

static void write_response(uint8_t *msg, IpcResp *rs, Session *s) {
    uint32_t out_objs[8];
    int nobj_ids = 0;
    // Objects become domain ids on domain sessions, else new session handles (move).
    for (int i = 0; i < rs->num_objs; i++) {
        if (s->is_domain) {
            int id = 0;
            for (int k = 0; k < 512; k++)
                if (!s->objs[k]) { s->objs[k] = rs->objs[i]; id = k + 1; break; }
            if (!id) nx_fatal("ipc: domain table full");
            out_objs[nobj_ids++] = id;
        } else {
            rs->move[rs->num_move++] = new_session_handle(rs->objs[i]);
        }
    }
    uint32_t *w = (uint32_t *)msg;
    memset(msg, 0, 0x100);
    int pos = 2;
    int special = rs->num_copy || rs->num_move;
    if (special) {
        w[pos++] = (rs->num_copy << 1) | (rs->num_move << 5);
        for (int i = 0; i < rs->num_copy; i++) w[pos++] = rs->copy[i];
        for (int i = 0; i < rs->num_move; i++) w[pos++] = rs->move[i];
    }
    int raw_start = (pos * 4 + 15) & ~15;
    uint8_t *raw = msg + raw_start;
    size_t n = 0;
    if (s->is_domain) {                                     // domain response header
        uint32_t dh[4] = {(uint32_t)nobj_ids, 0, 0, 0};
        memcpy(raw, dh, 16);
        n += 16;
    }
    uint32_t hdr[4] = {SFCO, 0, rs->result, 0};
    memcpy(raw + n, hdr, 16);
    n += 16;
    memcpy(raw + n, rs->out, rs->out_size);
    n += rs->out_size;
    if (s->is_domain) {
        memcpy(raw + n, out_objs, nobj_ids * 4);
        n += nobj_ids * 4;
    }
    uint32_t data_words = (uint32_t)(raw_start - pos * 4 + n + 3) / 4;
    w[0] = 0;
    w[1] = data_words | (special ? 1u << 31 : 0);
}

// TIPC response: header, special header with handles, then result + outputs (no CMIF).
static void write_tipc_response(uint8_t *msg, IpcResp *rs) {
    for (int i = 0; i < rs->num_objs; i++) rs->move[rs->num_move++] = new_session_handle(rs->objs[i]);
    uint32_t *w = (uint32_t *)msg;
    memset(msg, 0, 0x100);
    int pos = 2;
    int special = rs->num_copy || rs->num_move;
    if (special) {
        w[pos++] = (rs->num_copy << 1) | (rs->num_move << 5);
        for (int i = 0; i < rs->num_copy; i++) w[pos++] = rs->copy[i];
        for (int i = 0; i < rs->num_move; i++) w[pos++] = rs->move[i];
    }
    w[pos] = rs->result;
    memcpy(&w[pos + 1], rs->out, rs->out_size);
    w[0] = 0;
    w[1] = (uint32_t)(4 + rs->out_size + 3) / 4 | (special ? 1u << 31 : 0);
}

// ---- dispatch ----------------------------------------------------------------------

static void call(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    const ServiceDef *d = o->def;
    static int trace = -1;
    if (trace < 0) trace = getenv("NXRT_TRACE") != NULL;
    if (trace) nx_log("  ipc %s%s%s #%u", d->name, o->iface ? "::" : "", o->iface ? o->iface : "", rq->cmd);
    for (const IpcCmd *c = d->cmds; c && c->fn; c++)
        if (c->id == rq->cmd && (c->iface ? o->iface && !strcmp(c->iface, o->iface) : !o->iface)) {
            c->fn(o, rq, rs);
            return;
        }
    if (d->fallback) d->fallback(o, rq, rs);
    else unknown_cmd(o, rq, rs);
}

uint32_t nx_ipc_send_sync_request(uint32_t handle, uint8_t *msg, size_t size) {
    KObject *k = nx_handle_get(handle);
    if (!k || k->type != KO_SESSION) return RES_INVALID_HANDLE;
    Session *s = k->ptr;
    IpcReq rq;
    parse(msg, &rq);
    IpcResp *rs = calloc(1, sizeof *rs);

    if (rq.type == MT_CLOSE) {
        free(rs);
        return 0;
    }
    if (rq.type == MT_CONTROL || rq.type == MT_CONTROL_CTX) {
        uint32_t *c = (uint32_t *)rq.raw;
        rq.cmd = c[2];
        if (getenv("NXRT_TRACE")) nx_log("  ipc control #%u on %s", rq.cmd, s->root->def->name);
        switch (rq.cmd) {
        case 0:                                             // ConvertCurrentObjectToDomain
            s->is_domain = 1;
            s->objs[0] = s->root;
            {
                uint32_t id = 1;
                s->is_domain = 0;                           // reply itself is not domain-framed
                ipc_push_raw(rs, &id, 4);
                write_response(msg, rs, s);
                s->is_domain = 1;
            }
            free(rs);
            return 0;
        case 2: case 4: {                                   // CloneCurrentObject(Ex)
            pthread_mutex_lock(&g_klock);
            KObject *k2 = session_kobj(s);                 // same session (and domain table)
            uint32_t h2 = nx_handle_new(k2);
            pthread_mutex_unlock(&g_klock);
            ipc_push_move(rs, h2);
            break;
        }
        case 3: {                                           // QueryPointerBufferSize
            uint16_t sz = 0x8000;
            ipc_push_raw(rs, &sz, 2);
            break;
        }
        default:
            nx_fatal("ipc: control command %u", rq.cmd);
        }
        int dom = s->is_domain;
        s->is_domain = 0;
        write_response(msg, rs, s);
        s->is_domain = dom;
        free(rs);
        return 0;
    }
    if (rq.type >= 16) {                                    // TIPC: type = 16 + command
        rq.cmd = rq.type - 16;
        rq.data = rq.hipc_data;
        rq.session = s;
        call(s->root, &rq, rs);
        write_tipc_response(msg, rs);
        free(rs);
        return 0;
    }
    if (rq.type != MT_REQUEST && rq.type != MT_REQUEST_CTX)
        nx_fatal("ipc: message type %u", rq.type);

    SvcObj *target = s->root;
    uint8_t *cmif = rq.raw;
    if (s->is_domain) {                                     // domain header (16 bytes)
        uint8_t dcmd = cmif[0], nin = cmif[1];
        uint16_t dsize;
        uint32_t oid;
        memcpy(&dsize, cmif + 2, 2);
        memcpy(&oid, cmif + 4, 4);
        if (oid == 0 || oid > 512 || !s->objs[oid - 1]) nx_fatal("ipc: bad domain object %u", oid);
        if (dcmd == 2) {                                    // close object
            if (s->objs[oid - 1] != s->root) free(s->objs[oid - 1]);
            s->objs[oid - 1] = NULL;
            ipc_push_raw(rs, NULL, 0);
            write_response(msg, rs, s);
            free(rs);
            return 0;
        }
        target = s->objs[oid - 1];
        if (getenv("NXRT_TRACE")) nx_log("  ipc domain object %u (cmd %u, %u in-objects)", oid, dcmd, nin);
        memcpy(rq.in_objs, cmif + 16 + dsize, nin * 4);
        rq.num_in_objs = nin;
        cmif += 16;
    }
    uint32_t *c = (uint32_t *)cmif;
    if (c[0] != SFCI) nx_fatal("ipc: missing SFCI magic (%#x)", c[0]);
    rq.cmd = c[2];
    rq.data = cmif + 16;
    rq.session = s;
    call(target, &rq, rs);
    if (getenv("NXRT_TRACE") && (rs->num_copy || rs->num_move))
        nx_log("    -> copy %#x move %#x (%s%s%s #%u)", rs->num_copy ? rs->copy[0] : 0, rs->num_move ? rs->move[0] : 0,
               target->def->name, target->iface ? "::" : "", target->iface ? target->iface : "", rq.cmd);
    write_response(msg, rs, s);
    free(rs);
    return 0;
}

SvcObj *ipc_in_object(IpcReq *rq, int i) {
    Session *s = rq->session;
    uint32_t id = rq->in_objs[i];
    return id && id <= 512 ? s->objs[id - 1] : NULL;
}
