// lm — log manager. ILogger::Log carries the SDK's binary log packets; print the
// readable text so the guest's own diagnostics show up in our log.
#include <ctype.h>
#include <stdio.h>
#include <string.h>

#include "ipc.h"

extern const ServiceDef svc_lm;

static void open_logger(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    ipc_push_object(rs, nx_obj_new(&svc_lm, "ILogger", NULL));
}

// Log packet: 0x18-byte header, then chunks {u8 key, uleb len, data}. Print text-ish chunks.
static void logger_log(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    IpcBuf *b = rq->num_a ? &rq->a[0] : rq->num_x ? &rq->x[0] : NULL;
    if (!b || !b->addr || b->size < 0x18) return;
    const uint8_t *p = (const uint8_t *)b->addr + 0x18, *end = (const uint8_t *)b->addr + b->size;
    char line[1024];
    size_t n = 0;
    while (p < end) {
        uint8_t key = *p++;
        uint32_t len = 0, shift = 0;
        while (p < end) { uint8_t c = *p++; len |= (uint32_t)(c & 0x7F) << shift; shift += 7; if (!(c & 0x80)) break; }
        if (p + len > end) break;
        int text = len > 1;
        for (uint32_t i = 0; i < len && text; i++) text = isprint(p[i]) || p[i] == '\n' || p[i] == '\t';
        if (text && n + len + 3 < sizeof line) {
            if (n) line[n++] = ' ';
            if (key == 2) { memcpy(line + n, p, len); n += len; }        // 2 = TextLog
            else n += snprintf(line + n, sizeof line - n, "[%u:%.*s]", key, (int)len, p);
        }
        p += len;
    }
    while (n && (line[n - 1] == '\n' || line[n - 1] == ' ')) n--;
    if (n) fprintf(stderr, "[guest lm] %.*s\n", (int)n, line);
}

static void logger_nop(SvcObj *o, IpcReq *rq, IpcResp *rs) {}

static const IpcCmd cmds[] = {
    {NULL, 0, open_logger},
    {"ILogger", 0, logger_log},
    {"ILogger", 1, logger_nop},      // SetDestination
    {0},
};
const ServiceDef svc_lm = {.name = "lm", .cmds = cmds};
