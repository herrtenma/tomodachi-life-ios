// On-device shader translation. The game's shaders are never shipped: each stage is translated the first time the game
// hands it to nvnProgramSetShaders (shaders.c), in the background, into the shader cache (NXRT_SHADERS:
// msl/<hash>.<kind>.metal + spv/<hash>.<kind>.json, the layout gfx_cmd.m reads). Later runs find them there.
//   Maxwell code -> SPIR-V + JSON   Ryujinx's translator (runtime/xlat/Translate.cs, NativeAOT static library)
//   SPIR-V -> MSL                    SPIRV-Cross (runtime/xlat/xlat_msl.cpp)
//   MSL -> MSL for Metal's limits    runtime/xlat/MslFix.cs
// gfx_cmd.m shader_load waits for a stage still being translated (nx_xlat_wait). NXRT_XLAT=0: off.
#import <Foundation/Foundation.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "nxrt.h"

int nxsh_translate(const uint8_t *code, int code_len, const uint8_t *c1, int c1_len, const uint8_t *ctl, int ctl_len,
                   uint8_t **spv, int *spv_len, char **json, char **err);
int nxsh_fix_msl(const char *msl, int vertex, char **out, char **err);
void nxsh_free(void *p);
int nx_spirv_to_msl(const char *spv_path, const char *msl_path);

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_done = PTHREAD_COND_INITIALIZER;
static NSMutableSet<NSString *> *g_seen;      // every stage noted (translated, cached or queued)
static NSMutableSet<NSString *> *g_pending;   // queued or being translated
static uint64_t g_ok, g_failed, g_ns;

static int xlat_on(void) {
    static int on = -1;
    if (on < 0) on = !(getenv("NXRT_XLAT") && !atoi(getenv("NXRT_XLAT")));
    return on;
}
static NSString *cache_root(void) { return @(getenv("NXRT_SHADERS") ? getenv("NXRT_SHADERS") : "shaders"); }

static int write_file(NSString *path, const void *p, size_t n) {
    return [[NSData dataWithBytesNoCopy:(void *)p length:n freeWhenDone:NO] writeToFile:path atomically:YES];
}

// One stage (copies of what the game set: the game's memory may change before this runs).
static void translate(NSString *name, NSData *code, NSData *c1, NSData *ctl) {
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    NSString *root = cache_root(), *tmp = NSTemporaryDirectory();
    uint8_t *spv = NULL;
    int spv_len = 0;
    char *json = NULL, *msl_fixed = NULL, *err = NULL;
    const char *stage = "translate";
    NSString *spv_path = [tmp stringByAppendingPathComponent:[name stringByAppendingString:@".spv"]];
    NSString *msl_path = [tmp stringByAppendingPathComponent:[name stringByAppendingString:@".metal"]];
    int ok = nxsh_translate(code.bytes, (int)code.length, c1.bytes, (int)c1.length, ctl.bytes, (int)ctl.length, &spv, &spv_len, &json, &err) == 0;
    if (ok) {
        stage = "spirv-cross";
        static pthread_mutex_t sc_lock = PTHREAD_MUTEX_INITIALIZER;   // SPIRV-Cross's CLI code runs one at a time
        pthread_mutex_lock(&sc_lock);
        ok = write_file(spv_path, spv, spv_len) && nx_spirv_to_msl(spv_path.fileSystemRepresentation, msl_path.fileSystemRepresentation) == 0;
        pthread_mutex_unlock(&sc_lock);
    }
    NSString *msl = ok ? [NSString stringWithContentsOfFile:msl_path encoding:NSUTF8StringEncoding error:nil] : nil;
    if (ok && msl) {
        stage = "mslfix";
        ok = nxsh_fix_msl(msl.UTF8String, [name hasSuffix:@".vs"], &msl_fixed, &err) == 0;
    } else ok = 0;
    if (ok) {   // json first: gfx_cmd.m treats the .metal as the sign that both are there
        stage = "write";
        ok = write_file([NSString stringWithFormat:@"%@/spv/%@.json", root, name], json, strlen(json)) &&
             write_file([NSString stringWithFormat:@"%@/msl/%@.metal", root, name], msl_fixed, strlen(msl_fixed));
    }
    [NSFileManager.defaultManager removeItemAtPath:spv_path error:nil];
    [NSFileManager.defaultManager removeItemAtPath:msl_path error:nil];
    uint64_t ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;
    if (!ok) nx_log("xlat: %s failed at %s: %s", name.UTF8String, stage, err ? err : "-");
    nxsh_free(spv), nxsh_free(json), nxsh_free(msl_fixed), nxsh_free(err);
    pthread_mutex_lock(&g_lock);
    ok ? g_ok++ : g_failed++;
    g_ns += ns;
    if ((g_ok + g_failed) % 100 == 0)
        nx_log("xlat: %llu shaders translated on this device, %llu failed (%.1f ms each)", (unsigned long long)g_ok,
               (unsigned long long)g_failed, g_ns / 1e6 / (g_ok + g_failed));
    [g_pending removeObject:name];
    pthread_cond_broadcast(&g_done);
    pthread_mutex_unlock(&g_lock);
}

// A stage the game set (shaders.c): queued unless its translation is already in the cache.
void nx_xlat_note(uint64_t hash, const char *kind, const uint8_t *code, size_t n, const uint8_t *c1, size_t c1n,
                  const uint8_t *ctl, size_t ctln) {
    if (!xlat_on()) return;
    NSString *name = [NSString stringWithFormat:@"%016llx.%s", (unsigned long long)hash, kind];
    pthread_mutex_lock(&g_lock);
    if (!g_seen) {
        g_seen = [NSMutableSet set], g_pending = [NSMutableSet set];
        for (NSString *d in @[@"msl", @"spv"])
            [NSFileManager.defaultManager createDirectoryAtPath:[cache_root() stringByAppendingPathComponent:d]
                                    withIntermediateDirectories:YES attributes:nil error:nil];
    }
    BOOL fresh = ![g_seen containsObject:name];
    [g_seen addObject:name];
    pthread_mutex_unlock(&g_lock);
    if (!fresh) return;
    struct stat st;
    if (!stat([NSString stringWithFormat:@"%@/msl/%@.metal", cache_root(), name].fileSystemRepresentation, &st)) return;
    NSData *code_d = [NSData dataWithBytes:code length:n], *c1_d = c1 ? [NSData dataWithBytes:c1 length:c1n] : nil;
    NSData *ctl_d = ctl ? [NSData dataWithBytes:ctl length:ctln] : nil;
    pthread_mutex_lock(&g_lock);
    [g_pending addObject:name];
    pthread_mutex_unlock(&g_lock);
    // Two at a time, below the game's threads.
    static dispatch_queue_t q;
    static dispatch_semaphore_t slots;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("nx.xlat", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_UTILITY, 0));
        slots = dispatch_semaphore_create(2);
    });
    dispatch_async(q, ^{
        dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
        @autoreleasepool { translate(name, code_d, c1_d, ctl_d); }
        dispatch_semaphore_signal(slots);
    });
}

// gfx_cmd.m: the stage <name> ("<hash>.<kind>") has no translation on disk. Waits while it is being translated;
// returns 1 if it may be there now.
int nx_xlat_wait(const char *name) {
    if (!xlat_on()) return 0;
    NSString *n = @(name);
    pthread_mutex_lock(&g_lock);
    int was = [g_pending containsObject:n];
    while ([g_pending containsObject:n]) pthread_cond_wait(&g_done, &g_lock);
    pthread_mutex_unlock(&g_lock);
    return was;
}
