#include <time.h>
// fsp-srv: RomFS as an IStorage (decrypted from the XCI on demand), save data and SD
// card as IFileSystems over host folders (runtime/data/save, runtime/data/sdmc).
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <pthread.h>
#include <unistd.h>

#include "ipc.h"

extern const ServiceDef svc_fs;

// fs result codes (module 2)
#define RES_FS_PATH_NOT_FOUND 0x202
#define RES_FS_PATH_EXISTS 0x402
#define RES_FS_TARGET_NOT_FOUND 0x7D402   // e.g. no patch storage / no save
#define RES_FS_OUT_OF_RANGE 0x2EE602

static char g_root[1024] = "data";

// The folder holding save/ and sdmc/: NXRT_DATA (the iOS prelauncher's save slots: data, data-slot2, data-slot3), else
// "data". Read once, at the first file system open. The one place that decides where the island's save lives, so a
// shared island's downloaded copy or an offline copy can be pointed at later.
const char *nx_data_root(void) {
    static int init;
    if (!init++ && getenv("NXRT_DATA") && *getenv("NXRT_DATA")) snprintf(g_root, sizeof g_root, "%s", getenv("NXRT_DATA"));
    return g_root;
}

typedef struct { char base[1024]; } FsState;           // IFileSystem: host directory
typedef struct { int fd; char path[1100]; } FileState;
typedef struct { char path[1024]; DIR *d; } DirState;

static void ok(SvcObj *o, IpcReq *rq, IpcResp *rs) {}

// NXRT_SAVELOG=1: log every change to the save / SD folders (create, delete, rename, opens, bytes written per
// file) and each Commit with what changed since the previous one, frame number and seconds since boot; the first 4
// Commits also print the guest backtrace (=bt: every Commit and every .sav open). Research for save sync (shared island).
static int savelog(void) {
    static int on = -1;
    if (on < 0) on = getenv("NXRT_SAVELOG") ? (strcmp(getenv("NXRT_SAVELOG"), "bt") ? 1 : 2) : 0;
    return on;
}
static struct { char path[256]; uint64_t bytes, writes; } g_dirty[64];
static int g_ndirty;
static pthread_mutex_t g_dirty_lock = PTHREAD_MUTEX_INITIALIZER;
static const char *rel(const char *p) { size_t n = strlen(g_root); return strncmp(p, g_root, n) ? p : p + n + (p[n] == '/'); }
static double since_boot(void) {
    static uint64_t t0;
    uint64_t t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (!t0) t0 = t;
    return (t - t0) / 1e9;
}
static void dirty(const char *path, uint64_t bytes) {
    pthread_mutex_lock(&g_dirty_lock);
    int i;
    for (i = 0; i < g_ndirty && strcmp(g_dirty[i].path, rel(path)); i++) {}
    if (i == g_ndirty && g_ndirty < 64) {
        snprintf(g_dirty[i].path, 256, "%s", rel(path));
        g_dirty[i].bytes = g_dirty[i].writes = 0;
        g_ndirty++;
    }
    if (i < 64) { g_dirty[i].bytes += bytes; g_dirty[i].writes++; }
    pthread_mutex_unlock(&g_dirty_lock);
}
static void slog(const char *what, const char *path, const char *extra) {
    extern volatile int g_gfx_frame;
    nx_log("save: frame %d t %.1f s: %s %s%s", g_gfx_frame, since_boot(), what, rel(path), extra ? extra : "");
}

static SvcObj *fs_new(const char *sub) {
    nx_data_root();
    since_boot();                                        // NXRT_SAVELOG times count from the first open
    FsState *st = calloc(1, sizeof *st);
    snprintf(st->base, sizeof st->base, "%s/%s", g_root, sub);
    mkdir(g_root, 0755);
    mkdir(st->base, 0755);
    return nx_obj_new(&svc_fs, "IFileSystem", st);
}

// Paths arrive in the first X descriptor (fs path, up to 0x301 bytes).
static void host_path(SvcObj *o, IpcReq *rq, int xi, char *out, size_t n) {
    FsState *st = o->state;
    char p[0x302] = {0};
    if (rq->num_x > xi) memcpy(p, (void *)rq->x[xi].addr, rq->x[xi].size < 0x301 ? rq->x[xi].size : 0x301);
    snprintf(out, n, "%s%s%s", st->base, p[0] == '/' ? "" : "/", p);
}

static uint32_t errno_result(void) { return errno == ENOENT ? RES_FS_PATH_NOT_FOUND : errno == EEXIST ? RES_FS_PATH_EXISTS : 0x2602; }

// ---- IFileSystemProxy --------------------------------------------------------------
static void open_sdcard(SvcObj *o, IpcReq *rq, IpcResp *rs) { ipc_push_object(rs, fs_new("sdmc")); }
// OpenSaveDataFileSystem (space id, SaveDataAttribute at +8: program id, user id, system save id, type...). Program id
// 0 = the game itself. The game also asks for its demo's save (0100ca502552a000, to carry demo progress over); every
// request used to get our one save folder, so a fresh island found "save data from the demo version". Another title's
// save now doesn't exist, as on a console without the demo. NXRT_SAVE_ANYTITLE=1: every request gets the save (old).
static void open_save(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    uint64_t program;
    memcpy(&program, rq->data + 8, 8);
    if (rq->cmd == 51 && program && !getenv("NXRT_SAVE_ANYTITLE")) {
        nx_log("fs: save data of program %016llx requested: not found", (unsigned long long)program);
        rs->result = RES_FS_TARGET_NOT_FOUND;
        return;
    }
    ipc_push_object(rs, fs_new("save"));
}
static void open_data_storage(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    ipc_push_object(rs, nx_obj_new(&svc_fs, "IStorage", NULL));
}
static void no_patch(SvcObj *o, IpcReq *rq, IpcResp *rs) { rs->result = RES_FS_TARGET_NOT_FOUND; }
static void u32_0(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)0); }
static void program_index(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)0); OUT(rs, (uint32_t)1); }

// ---- IStorage (RomFS) ---------------------------------------------------------------
static void st_read(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    uint64_t off = IN(uint64_t, 0), size = IN(uint64_t, 8);
    IpcBuf *b = &rq->b[0];
    if (size > b->size) size = b->size;
    const char *w = getenv("NXRT_WATCH");
    uint64_t watch = w ? strtoull(w, NULL, 16) : 0;
    if (watch && watch >= b->addr && watch < b->addr + size)
        nx_log("fs: RomFS read off %#llx size %#llx -> buffer %#llx covers the watch", (unsigned long long)off,
               (unsigned long long)size, (unsigned long long)b->addr);
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (nx_romfs_read(off, (void *)b->addr, size)) rs->result = RES_FS_OUT_OF_RANGE;
    static int fslog = -1;                         // NXRT_FSLOG=1: every RomFS read
    if (fslog < 0) fslog = getenv("NXRT_FSLOG") != NULL;
    if (fslog) {
        extern volatile int g_gfx_frame;
        nx_log("fs: frame %d RomFS read off %#llx size %#llx%s", g_gfx_frame, (unsigned long long)off,
               (unsigned long long)size, rs->result ? " FAILED (out of range)" : "");
    }
    extern uint64_t g_fs_stat[3];   // reads, bytes, ns (NXRT_FRAMEDRAWS)
    __atomic_fetch_add(&g_fs_stat[0], 1, __ATOMIC_RELAXED);
    __atomic_fetch_add(&g_fs_stat[1], size, __ATOMIC_RELAXED);
    __atomic_fetch_add(&g_fs_stat[2], clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0, __ATOMIC_RELAXED);
}
uint64_t g_fs_stat[3];
static void st_get_size(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, nx_romfs_size()); }

// ---- IFileSystem -------------------------------------------------------------------
static void fs_create_file(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    char p[1100];
    host_path(o, rq, 0, p, sizeof p);
    uint64_t size = IN(uint64_t, 8);
    int fd = open(p, O_CREAT | O_EXCL | O_RDWR, 0644);
    if (fd < 0) { rs->result = errno_result(); return; }
    if (ftruncate(fd, (off_t)size)) rs->result = 0x2602;
    close(fd);
    if (savelog()) { char x[48]; snprintf(x, sizeof x, " (size %llu)", (unsigned long long)size); slog("create", p, x); dirty(p, 0); }
}
static void fs_delete_file(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    char p[1100];
    host_path(o, rq, 0, p, sizeof p);
    if (unlink(p)) rs->result = errno_result();
    if (savelog()) { slog("delete", p, rs->result ? " (failed)" : NULL); dirty(p, 0); }
}
static void fs_create_dir(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    char p[1100];
    host_path(o, rq, 0, p, sizeof p);
    if (mkdir(p, 0755)) rs->result = errno_result();
    if (savelog()) slog("mkdir", p, rs->result ? " (failed)" : NULL);
}
static void fs_delete_dir(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    char p[1100];
    host_path(o, rq, 0, p, sizeof p);
    if (rmdir(p)) rs->result = errno_result();
    if (savelog()) slog("rmdir", p, rs->result ? " (failed)" : NULL);
}
static void fs_rename(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    char a[1100], b[1100];
    host_path(o, rq, 0, a, sizeof a);
    host_path(o, rq, 1, b, sizeof b);
    if (rename(a, b)) rs->result = errno_result();
    if (savelog()) { char x[1200]; snprintf(x, sizeof x, " -> %s%s", rel(b), rs->result ? " (failed)" : ""); slog("rename", a, x); dirty(b, 0); }
}
static void fs_get_entry_type(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    char p[1100];
    host_path(o, rq, 0, p, sizeof p);
    struct stat st;
    if (stat(p, &st)) { rs->result = RES_FS_PATH_NOT_FOUND; return; }
    OUT(rs, (uint32_t)(S_ISDIR(st.st_mode) ? 0 : 1));
}
static void fs_open_file(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    char p[1100];
    host_path(o, rq, 0, p, sizeof p);
    uint32_t mode = IN(uint32_t, 0);
    int fd = open(p, (mode & 2) ? O_RDWR : O_RDONLY);
    if (fd < 0) { rs->result = errno_result(); return; }
    FileState *f = calloc(1, sizeof *f);
    f->fd = fd;
    strcpy(f->path, p);
    if (savelog()) { char x[32]; snprintf(x, sizeof x, " (mode %#x)", mode); slog(mode & 2 ? "open for write" : "open for read", p, x);
        if (savelog() == 2 && strstr(p, ".sav")) { void nx_backtrace_from(uint64_t fp); nx_backtrace_from((uint64_t)__builtin_frame_address(0)); } }
    ipc_push_object(rs, nx_obj_new(&svc_fs, "IFile", f));
}
static void fs_open_dir(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    char p[1100];
    host_path(o, rq, 0, p, sizeof p);
    DIR *d = opendir(p);
    if (!d) { rs->result = errno_result(); return; }
    DirState *ds = calloc(1, sizeof *ds);
    ds->d = d;
    strcpy(ds->path, p);
    ipc_push_object(rs, nx_obj_new(&svc_fs, "IDirectory", ds));
}
static void fs_free_space(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint64_t)0x40000000); }
// Local save snapshots (on unless NXRT_SNAPSHOTS=0): each Commit of the save keeps a copy in <root>/snapshots/<n>/
// (save/ as an APFS clone: instant, no data copied, later writes don't touch it) with manifest.txt (number, island
// posix time, frame, then "size path" per file). Built in .tmp then renamed, so a snapshot is never half written. The
// 8 newest are kept. The game truncates and rewrites the files before committing, so these are the consistent copies
// to go back to (copy one's save/ over the island's save/ while the game is closed).
static void rm_tree(const char *path) {
    DIR *d = opendir(path);
    struct dirent *e;
    while (d && (e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char p[2100];
        snprintf(p, sizeof p, "%s/%s", path, e->d_name);
        if (e->d_type == DT_DIR) rm_tree(p);
        else unlink(p);
    }
    if (d) closedir(d);
    rmdir(path);
}
static void manifest_walk(FILE *f, const char *base, const char *rel_dir) {
    char dir[2100];
    snprintf(dir, sizeof dir, "%s%s%s", base, *rel_dir ? "/" : "", rel_dir);
    DIR *d = opendir(dir);
    struct dirent *e;
    while (d && (e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char rp[1100], p[3300];
        snprintf(rp, sizeof rp, "%s%s%s", rel_dir, *rel_dir ? "/" : "", e->d_name);
        snprintf(p, sizeof p, "%s/%s", base, rp);
        struct stat st;
        if (stat(p, &st)) continue;
        if (S_ISDIR(st.st_mode)) manifest_walk(f, base, rp);
        else fprintf(f, "%lld %s\n", (long long)st.st_size, rp);
    }
    if (d) closedir(d);
}
static void snapshot_commit(const char *save_dir) {
    static int on = -1, version = -1;
    if (on < 0) on = !(getenv("NXRT_SNAPSHOTS") && !strcmp(getenv("NXRT_SNAPSHOTS"), "0"));
    if (!on) return;
    char box[1100], tmp[1200], dst[1200], files[1300];
    snprintf(box, sizeof box, "%s/snapshots", nx_data_root());
    mkdir(box, 0755);
    DIR *d = opendir(box);
    struct dirent *e;
    int oldest = 1 << 30, count = 0;
    if (version < 0) version = 0;
    while (d && (e = readdir(d)))                        // numbered snapshots: continue after the newest
        if (e->d_name[0] >= '0' && e->d_name[0] <= '9') {
            int v = atoi(e->d_name);
            if (v > version) version = v;
            if (v < oldest) oldest = v;
            count++;
        }
    if (d) closedir(d);
    int v = ++version;
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    snprintf(tmp, sizeof tmp, "%s/.tmp-%d", box, v);
    snprintf(dst, sizeof dst, "%s/%08d", box, v);
    snprintf(files, sizeof files, "%s/save", tmp);
    rm_tree(tmp);
    mkdir(tmp, 0755);
    if (clonefile(save_dir, files, 0)) {
        nx_log("save: snapshot: clonefile %s -> %s failed (errno %d): snapshot %d skipped", save_dir, files, errno, v);
        rm_tree(tmp);
        return;
    }
    char mpath[1300];
    snprintf(mpath, sizeof mpath, "%s/manifest.txt", tmp);
    FILE *f = fopen(mpath, "w");
    if (f) {
        extern volatile int g_gfx_frame;
        int64_t nx_time_posix_now(void);
        fprintf(f, "version %d\nisland_time %lld\nframe %d\n", v, (long long)nx_time_posix_now(), g_gfx_frame);
        manifest_walk(f, tmp, "save");
        fclose(f);
    }
    if (rename(tmp, dst)) { nx_log("save: snapshot: rename to %s failed (errno %d)", dst, errno); rm_tree(tmp); return; }
    while (count >= 8 && oldest < v) {                   // keep the 8 newest (count includes the old ones only)
        char old[1200];
        snprintf(old, sizeof old, "%s/%08d", box, oldest++);
        struct stat st;
        if (!stat(old, &st)) rm_tree(old), count--;
    }
    nx_log("save: snapshot: snapshot %d in %.1f ms", v, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6);
}
// Save on demand (shared island handoff), the way the game's own X menu > Save does it. The save manager is the
// singleton *(main+0x396d0f0); its per-frame update (main+0x5e1dfc, game thread) saves when byte +0x55 is set:
// unless +0x53 is set (then the request is dropped), it calls the save request main+0x1d7bf60, which proceeds only
// with +0x50 and +0x51 set (save data loaded / saving allowed), sets +0x94c (1 requested, 2 writing, 0 idle) and
// counts saves in +0x950; the job (main+0x1d7d2b8) writes Mii/Player/Map.sav and commits. The update waits while a
// save runs or global flag 0x800 (*(main+0x3a87ae0)+0xf0) is set. +0x52 enables the game's timed autosave (timer
// +0x948, 10801). Returns 1 = requested (a Commit follows; nx_save_count() goes up), 0 = saving not possible now.
static uint8_t *save_mgr(void) {
    Module *m = nx_module("main");
    uint8_t *mgr = m ? *(uint8_t **)(m->base + 0x396d0f0) : NULL;
    return (uintptr_t)mgr >= 0x7000000000 && (uintptr_t)mgr < 0x8000000000 ? mgr : NULL;
}
int nx_save_count(void) { uint8_t *m = save_mgr(); return m ? *(int32_t *)(m + 0x950) : -1; }
int nx_request_save(const char *why) {
    uint8_t *m = save_mgr();
    extern volatile int g_gfx_frame;
    if (!m || !m[0x50] || !m[0x51] || m[0x53]) {
        nx_log("save: frame %d: save on demand (%s) not possible now: %s", g_gfx_frame, why, !m ? "no save manager" :
               !m[0x50] || !m[0x51] ? "save data not ready (+0x50/+0x51)" : "saving blocked by the game (+0x53)");
        return 0;
    }
    nx_log("save: frame %d: save on demand (%s): state %u, saves so far %d", g_gfx_frame, why, *(uint32_t *)(m + 0x94c),
           *(int32_t *)(m + 0x950) + 1);
    __atomic_store_n(&m[0x55], 1, __ATOMIC_RELEASE);
    return 1;
}
// NXRT_AUTOSAVE_AT=<frame>[,<frame>...]: request a save at those frames (test of nx_request_save). Called per frame.
void nx_save_tick(int frame) {
    static const char *spec;
    static int init;
    if (!init++) spec = getenv("NXRT_AUTOSAVE_AT");
    for (const char *p = spec; p && *p; p = strchr(p, ',') ? strchr(p, ',') + 1 : NULL)
        if (atoi(p) == frame) nx_request_save("NXRT_AUTOSAVE_AT");
}

static void fs_commit(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    FsState *st = o->state;
    size_t bl = strlen(st->base);
    if (bl >= 5 && !strcmp(st->base + bl - 5, "/save")) snapshot_commit(st->base);
    if (!savelog()) return;
    static int n;
    pthread_mutex_lock(&g_dirty_lock);
    char list[2048] = "";
    uint64_t total = 0;
    for (int i = 0; i < g_ndirty; i++) {
        size_t l = strlen(list);
        snprintf(list + l, sizeof list - l, "%s%s %llu B/%llu", i ? ", " : "", g_dirty[i].path,
                 (unsigned long long)g_dirty[i].bytes, (unsigned long long)g_dirty[i].writes);
        total += g_dirty[i].bytes;
    }
    char x[2200];
    snprintf(x, sizeof x, " #%d: %llu bytes since the last: %s", ++n, (unsigned long long)total, g_ndirty ? list : "nothing");
    g_ndirty = 0;
    pthread_mutex_unlock(&g_dirty_lock);
    slog("COMMIT", st->base, x);
    if (n <= 4 || savelog() == 2) {
        void nx_backtrace_from(uint64_t fp);
        nx_backtrace_from((uint64_t)__builtin_frame_address(0));
    }
}

// ---- IFile -------------------------------------------------------------------------
static void f_read(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    FileState *f = o->state;
    uint64_t off = IN(uint64_t, 8), size = IN(uint64_t, 16);
    IpcBuf *b = &rq->b[0];
    if (size > b->size) size = b->size;
    ssize_t n = pread(f->fd, (void *)b->addr, size, (off_t)off);
    static uint64_t watch;
    static int init;
    if (!init++) { const char *w = getenv("NXRT_WATCH"); watch = w ? strtoull(w, NULL, 16) : 0; }
    if (getenv("NXRT_TRACE") || (watch && watch >= b->addr && watch < b->addr + size))
        nx_log("fs: IFile read fd %d off %#llx size %#llx -> buffer %#llx (desc size %#llx) got %zd", f->fd,
               (unsigned long long)off, (unsigned long long)IN(uint64_t, 16), (unsigned long long)b->addr,
               (unsigned long long)b->size, n);
    OUT(rs, (uint64_t)(n < 0 ? 0 : n));
}
static void f_write(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    FileState *f = o->state;
    uint64_t off = IN(uint64_t, 8), size = IN(uint64_t, 16);
    if (pwrite(f->fd, (void *)rq->a[0].addr, size, (off_t)off) != (ssize_t)size) rs->result = 0x2602;
    if (savelog()) dirty(f->path, size);
}
static void f_set_size(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    FileState *f = o->state;
    if (ftruncate(f->fd, (off_t)IN(uint64_t, 0))) rs->result = 0x2602;
    if (savelog()) { char x[48]; snprintf(x, sizeof x, " to %llu", (unsigned long long)IN(uint64_t, 0)); slog("set size", f->path, x); }
}
static void f_get_size(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    FileState *f = o->state;
    struct stat st;
    fstat(f->fd, &st);
    OUT(rs, (uint64_t)st.st_size);
}

// ---- IDirectory --------------------------------------------------------------------
static void d_read(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    DirState *ds = o->state;
    IpcBuf *b = &rq->b[0];
    uint64_t n = 0, max = b->size / 0x310;
    struct dirent *e;
    while (n < max && (e = readdir(ds->d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        uint8_t *ent = (uint8_t *)b->addr + n * 0x310;
        memset(ent, 0, 0x310);
        strncpy((char *)ent, e->d_name, 0x300);
        char p[2100];
        snprintf(p, sizeof p, "%s/%s", ds->path, e->d_name);
        struct stat st;
        stat(p, &st);
        ent[0x304] = S_ISDIR(st.st_mode) ? 0 : 1;
        uint64_t size = S_ISDIR(st.st_mode) ? 0 : (uint64_t)st.st_size;
        memcpy(ent + 0x308, &size, 8);
        n++;
    }
    OUT(rs, n);
}
static void d_count(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    DirState *ds = o->state;
    DIR *d = opendir(ds->path);
    uint64_t n = 0;
    struct dirent *e;
    while (d && (e = readdir(d)))
        if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) n++;
    if (d) closedir(d);
    OUT(rs, n);
}

static const IpcCmd cmds[] = {
    {NULL, 1, ok},                                        // SetCurrentProcess
    {NULL, 18, open_sdcard},                              // OpenSdCardFileSystem
    {NULL, 51, open_save},                                // OpenSaveDataFileSystem
    {NULL, 52, open_save},                                // OpenSaveDataFileSystemBySystemSaveDataId
    {NULL, 200, open_data_storage},                       // OpenDataStorageByCurrentProcess
    {NULL, 203, no_patch},                                // OpenPatchDataStorageByCurrentProcess
    {NULL, 1003, ok},                                     // DisableAutoSaveDataCreation
    {NULL, 1004, ok},                                     // SetGlobalAccessLogMode
    {NULL, 1005, u32_0},                                  // GetGlobalAccessLogMode
    {NULL, 1006, ok},                                     // OutputAccessLogToSdCard
    {NULL, 1011, program_index},                          // GetProgramIndexForAccessLog
    {NULL, 1016, ok},                                     // FlushAccessLogOnSdCard
    {"IStorage", 0, st_read},
    {"IStorage", 2, ok},                                  // Flush
    {"IStorage", 4, st_get_size},
    {"IFileSystem", 0, fs_create_file},
    {"IFileSystem", 1, fs_delete_file},
    {"IFileSystem", 2, fs_create_dir},
    {"IFileSystem", 3, fs_delete_dir},
    {"IFileSystem", 5, fs_rename},
    {"IFileSystem", 6, fs_rename},
    {"IFileSystem", 7, fs_get_entry_type},
    {"IFileSystem", 8, fs_open_file},
    {"IFileSystem", 9, fs_open_dir},
    {"IFileSystem", 10, fs_commit},                       // Commit (no-op; NXRT_SAVELOG logs it)
    {"IFileSystem", 11, fs_free_space},                   // GetFreeSpaceSize
    {"IFileSystem", 12, fs_free_space},                   // GetTotalSpaceSize
    {"IFile", 0, f_read},
    {"IFile", 1, f_write},
    {"IFile", 2, ok},                                     // Flush
    {"IFile", 3, f_set_size},
    {"IFile", 4, f_get_size},
    {"IDirectory", 0, d_read},
    {"IDirectory", 1, d_count},
    {0},
};
const ServiceDef svc_fs = {.name = "fsp-srv", .cmds = cmds};
