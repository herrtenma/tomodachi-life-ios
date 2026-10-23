// time:u / time:a / time:s — clocks from the host. Newer SDKs read the clock contexts
// from shared memory (GetSharedMemoryNativeHandle), so that is kept current too.
#include <stdio.h>
#include <stdlib.h>
#include <mach/mach_time.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

#include "ipc.h"

extern const ServiceDef svc_time;

typedef struct { int64_t time_point; uint8_t source_id[16]; } SteadyClockTimePoint;   // 0x18
typedef struct { int64_t offset; SteadyClockTimePoint steady; } SystemClockContext;   // 0x20

static const uint8_t g_source_id[16] = {0x6E, 0x78, 0x72, 0x74, 0x2D, 0x73, 0x74, 0x65,
                                        0x61, 0x64, 0x79, 0x2D, 0x63, 0x6C, 0x6B, 0x31};

static int64_t steady_ns(void) {   // the same clock as svc.c's system tick (sleep included)
    uint64_t nx_host_time_units(void);
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (int64_t)((__uint128_t)nx_host_time_units() * tb.numer / tb.denom);
}
static int64_t steady_s(void) { return steady_ns() / 1000000000; }
// NXRT_TZ=<IANA zone, e.g. Europe/Berlin>: the island's calendar (time of day, date) follows that zone instead of the
// device's. Unset = the host's local zone. Sets the
// process TZ once, before the first clock use.
static void tz_init(void) {
    static int done;
    if (done++) return;
    const char *z = getenv("NXRT_TZ");
    if (!z || !*z) return;
    setenv("TZ", z, 1);
    tzset();
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    nx_log("time: island time zone %s (%s, UTC%+.2g h)%s", z, tm.tm_zone ? tm.tm_zone : "?", tm.tm_gmtoff / 3600.0,
           tm.tm_zone && !strcmp(tm.tm_zone, "UTC") && strcmp(z, "UTC") ? " - unknown zone? fell back to UTC" : "");
}
// NXRT_CLOCK="YYYY-MM-DD HH:MM" (host local time): the clock starts there and runs normally, so runs
// see the same time of day (the island's lighting and events follow it).
static int64_t posix_now(void) {
    static int64_t shift = -1;
    if (shift == -1) {
        tz_init();
        shift = 0;
        const char *e = getenv("NXRT_CLOCK");
        struct tm tm = {0};
        if (e && sscanf(e, "%d-%d-%d %d:%d", &tm.tm_year, &tm.tm_mon, &tm.tm_mday, &tm.tm_hour, &tm.tm_min) == 5) {
            tm.tm_year -= 1900, tm.tm_mon -= 1, tm.tm_isdst = -1;
            shift = (int64_t)mktime(&tm) - (int64_t)time(NULL);
        }
    }
    return (int64_t)time(NULL) + shift;
}
int64_t nx_time_posix_now(void) { return posix_now(); }

static SystemClockContext context_now(void) {
    SystemClockContext c = {.offset = posix_now() - steady_s()};
    c.steady.time_point = steady_s();
    memcpy(c.steady.source_id, g_source_id, 16);
    return c;
}

// ---- shared memory -----------------------------------------------------------------
static KShmem *g_shm;
static uint32_t g_shm_handle;

static void shm_put(size_t off, const void *v, size_t n) {   // LockFreeAtomicType<T>
    uint32_t counter;
    memcpy(&counter, g_shm->backing + off, 4);
    counter++;
    nx_shmem_write(g_shm, off + 8 + (counter & 1) * n, v, n);
    nx_shmem_write(g_shm, off, &counter, 4);
}

static void shm_init(void) {
    if (g_shm) return;
    g_shm = nx_shmem_new(0x1000, &g_shm_handle);
    struct { int64_t base_time_ns; uint8_t source_id[16]; } steady = {0};   // base + tick time = steady ns
    memcpy(steady.source_id, g_source_id, 16);
    // SDK: steady time = base_time + ConvertToTimeSpan(GetSystemTick()); our tick counts
    // from the same monotonic clock, so base_time is 0.
    shm_put(0x00, &steady, sizeof steady);
    SystemClockContext c = context_now();
    shm_put(0x38, &c, sizeof c);                              // standard local system clock
    shm_put(0x80, &c, sizeof c);                              // standard network system clock
    uint8_t automatic = 0;
    shm_put(0xC8, &automatic, 1);
    // Newer SDKs (SharedMemoryClient::GetStandardSteadyClockCurrentTimePoint, sdk+0x442350) take the
    // steady clock from here instead of 0x00: entries of 0x38 bytes at 0xD8 + (counter & 1) * 0x38,
    //   steady ns = now_ns + clamp(((now_ns - base) * rate >> shift) + add, limit), source id at +0x28.
    // Left zero, the source id (0) never matched the system clock contexts' steady source, so every
    // CalculateSystemClockCurrentTime failed (0xcc74) and the game's clock fell back to posix ~0
    // (1970-01-01 00:00 UTC = 19:00 EST: the island was always in the evening).
    // rate 0: steady time = tick time since boot, like steady_s() and the contexts above.
    struct { int64_t base, rate, shift, add, limit; uint8_t source_id[16]; } cont = {0};
    memcpy(cont.source_id, g_source_id, 16);
    shm_put(0xD0, &cont, sizeof cont);
}

static void ok(SvcObj *o, IpcReq *rq, IpcResp *rs) {}
static void obj(IpcResp *rs, const char *iface) { ipc_push_object(rs, nx_obj_new(&svc_time, iface, NULL)); }

// IStaticService
static void get_user_clock(SvcObj *o, IpcReq *rq, IpcResp *rs) { obj(rs, "ISystemClock"); }
static void get_steady_clock(SvcObj *o, IpcReq *rq, IpcResp *rs) { obj(rs, "ISteadyClock"); }
static void get_timezone(SvcObj *o, IpcReq *rq, IpcResp *rs) { obj(rs, "ITimeZoneService"); }
static void get_shared_memory(SvcObj *o, IpcReq *rq, IpcResp *rs) { shm_init(); ipc_push_copy(rs, g_shm_handle); }
static void u8_0(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint8_t)0); }
static void u8_1(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint8_t)1); }
static void initial_year(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)2026); }
// Host local time as a CalendarTime + CalendarAdditionalInfo.
typedef struct { uint16_t year; uint8_t month, day, hour, minute, second, pad; } CalendarTime;
typedef struct { uint32_t day_of_week, day_of_year; char tz_name[8]; uint32_t is_dst; int32_t gmt_offset; } CalendarAdditionalInfo;
static void calendar_of(int64_t posix, CalendarTime *ct, CalendarAdditionalInfo *ai) {
    tz_init();
    time_t t = (time_t)posix;
    struct tm tm;
    localtime_r(&t, &tm);
    *ct = (CalendarTime){(uint16_t)(tm.tm_year + 1900), (uint8_t)(tm.tm_mon + 1), (uint8_t)tm.tm_mday,
                         (uint8_t)tm.tm_hour, (uint8_t)tm.tm_min, (uint8_t)tm.tm_sec, 0};
    *ai = (CalendarAdditionalInfo){(uint32_t)tm.tm_wday, (uint32_t)tm.tm_yday, {0}, (uint32_t)(tm.tm_isdst > 0),
                                   (int32_t)tm.tm_gmtoff};
    strncpy(ai->tz_name, tm.tm_zone ? tm.tm_zone : "UTC", 7);
}
static void clock_snapshot(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    // ClockSnapshot (0xD0): user ctx, network ctx, user time, network time, calendar times,
    // additional infos, steady time point, location name, auto correction, type, version
    uint8_t snap[0xD0] = {0};
    SystemClockContext c = context_now();
    memcpy(snap + 0x00, &c, 0x20);
    memcpy(snap + 0x20, &c, 0x20);
    int64_t now = posix_now();
    memcpy(snap + 0x40, &now, 8);
    memcpy(snap + 0x48, &now, 8);
    // User/network calendar time (+0x50/+0x58) and additional info (+0x60/+0x78). These were left zero
    // (hour 0): the game took its time of day from them, and the island was always at midnight.
    CalendarTime ct;
    CalendarAdditionalInfo ai;
    calendar_of(now, &ct, &ai);
    memcpy(snap + 0x50, &ct, 8);
    memcpy(snap + 0x58, &ct, 8);
    memcpy(snap + 0x60, &ai, 0x18);
    memcpy(snap + 0x78, &ai, 0x18);
    memcpy(snap + 0x90, &c.steady, 0x18);
    memcpy(snap + 0xA8, "UTC", 3);
    snap[0xCC] = 0;                 // automatic correction
    snap[0xCD] = rq->data[0];       // type: echoes the request (the SDK checks it)
    IpcBuf *b = rq->num_c ? &rq->c[0] : &rq->b[0];
    static int logged;
    if (logged++ < 4) {
        const int64_t *d = (const int64_t *)rq->data;
        nx_log("time: ClockSnapshot req: num_b %d num_c %d buf %#llx size %#llx; data %llx %llx %llx %llx %llx", rq->num_b, rq->num_c,
               (unsigned long long)b->addr, (unsigned long long)b->size, d[0], d[1], d[2], d[3], d[4]);
    }
    if (b->addr) memcpy((void *)b->addr, snap, b->size < sizeof snap ? b->size : sizeof snap);
}
static void calc_span(SvcObj *o, IpcReq *rq, IpcResp *rs) {   // CalculateSpanBetween(a, b) -> ns
    SteadyClockTimePoint a, b;
    memcpy(&a, rq->data, 0x18);
    memcpy(&b, rq->data + 0x18, 0x18);
    OUT(rs, (int64_t)(b.time_point - a.time_point) * 1000000000);
}

// ISystemClock
static void sc_get_current_time(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, posix_now()); }
static void sc_get_context(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    SystemClockContext c = context_now();
    ipc_push_raw(rs, &c, sizeof c);
}
static void sc_event(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    uint32_t h;
    nx_event_new_readable(&h);
    ipc_push_copy(rs, h);
}

// ISteadyClock
static void st_get_current_time_point(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    SteadyClockTimePoint t = {.time_point = steady_s()};
    memcpy(t.source_id, g_source_id, 16);
    ipc_push_raw(rs, &t, sizeof t);
}
static void st_i64_0(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (int64_t)0); }
static void st_rtc(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, posix_now()); }

// ITimeZoneService: local time of the host
static void to_calendar(int64_t posix, IpcResp *rs) {
    CalendarTime ct;
    CalendarAdditionalInfo ai;
    calendar_of(posix, &ct, &ai);
    static int logged;
    static int64_t last = -1;
    extern __thread uint64_t *nx_svc_regs;
    void nx_backtrace_from(uint64_t fp);
    if (posix != last && logged < 12 && getenv("NXRT_TIMEBT") && nx_svc_regs) nx_backtrace_from(nx_svc_regs[19]);
    if (posix != last && logged++ < 12) last = posix, nx_log("time: ToCalendarTime(%lld) -> %04d-%02d-%02d %02d:%02d:%02d (host now %lld)", (long long)posix, ct.year,
                             ct.month, ct.day, ct.hour, ct.minute, ct.second, (long long)posix_now());
    ipc_push_raw(rs, &ct, sizeof ct);
    ipc_push_raw(rs, &ai, sizeof ai);
}
static void tz_get_location_name(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    char name[0x24] = "UTC";
    ipc_push_raw(rs, name, sizeof name);
}
static void tz_load_rule(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    IpcBuf *b = rq->num_b ? &rq->b[0] : &rq->c[0];
    if (b->addr) memset((void *)b->addr, 0, b->size);       // rules are ignored: host localtime is used
}
static void tz_to_calendar(SvcObj *o, IpcReq *rq, IpcResp *rs) { to_calendar(IN(int64_t, 0), rs); }
static void tz_to_posix(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    CalendarTime ct;
    tz_init();
    memcpy(&ct, rq->data, sizeof ct);
    struct tm tm = {.tm_year = ct.year - 1900, .tm_mon = ct.month - 1, .tm_mday = ct.day,
                    .tm_hour = ct.hour, .tm_min = ct.minute, .tm_sec = ct.second, .tm_isdst = -1};
    int64_t t = (int64_t)mktime(&tm);
    IpcBuf *b = rq->num_c ? &rq->c[0] : &rq->b[0];
    if (b->addr && b->size >= 8) memcpy((void *)b->addr, &t, 8);
    OUT(rs, (uint32_t)1);
}
static void tz_u32_1(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)1); }

static const IpcCmd cmds[] = {
    {NULL, 0, get_user_clock},                            // GetStandardUserSystemClock
    {NULL, 1, get_user_clock},                            // GetStandardNetworkSystemClock
    {NULL, 2, get_steady_clock},                          // GetStandardSteadyClock
    {NULL, 3, get_timezone},                              // GetTimeZoneService
    {NULL, 4, get_user_clock},                            // GetStandardLocalSystemClock
    {NULL, 5, get_user_clock},                            // GetEphemeralNetworkSystemClock
    {NULL, 20, get_shared_memory},                        // GetSharedMemoryNativeHandle
    {NULL, 100, u8_0},                                    // IsStandardUserSystemClockAutomaticCorrectionEnabled
    {NULL, 102, initial_year},                            // GetStandardUserSystemClockInitialYear
    {NULL, 200, u8_1},                                    // IsStandardNetworkSystemClockAccuracySufficient
    {NULL, 400, clock_snapshot},                          // GetClockSnapshot
    {NULL, 401, clock_snapshot},                          // GetClockSnapshotFromSystemClockContext
    {NULL, 500, st_i64_0},                                // CalculateStandardUserSystemClockDifferenceByUser
    {NULL, 501, calc_span},                               // CalculateSpanBetween
    {"ISystemClock", 0, sc_get_current_time},
    {"ISystemClock", 1, ok},                              // SetCurrentTime
    {"ISystemClock", 2, sc_get_context},
    {"ISystemClock", 3, ok},                              // SetSystemClockContext
    {"ISystemClock", 4, sc_event},                        // GetOperationEventReadableHandle
    {"ISteadyClock", 0, st_get_current_time_point},
    {"ISteadyClock", 2, st_i64_0},                        // GetTestOffset
    {"ISteadyClock", 3, ok},                              // SetTestOffset
    {"ISteadyClock", 100, st_rtc},                        // GetRtcValue
    {"ISteadyClock", 101, u8_0},                          // IsRtcResetDetected
    {"ISteadyClock", 102, st_i64_0},                      // GetSetupResultValue
    {"ISteadyClock", 200, st_i64_0},                      // GetInternalOffset
    {"ITimeZoneService", 0, tz_get_location_name},
    {"ITimeZoneService", 1, ok},                          // SetDeviceLocationName
    {"ITimeZoneService", 2, tz_u32_1},                    // GetTotalLocationNameCount
    {"ITimeZoneService", 4, tz_load_rule},                // LoadTimeZoneRule
    {"ITimeZoneService", 100, tz_to_calendar},            // ToCalendarTime
    {"ITimeZoneService", 101, tz_to_calendar},            // ToCalendarTimeWithMyRule
    {"ITimeZoneService", 201, tz_to_posix},               // ToPosixTime
    {"ITimeZoneService", 202, tz_to_posix},               // ToPosixTimeWithMyRule
    {0},
};
const ServiceDef svc_time = {.name = "time:u", .cmds = cmds};
