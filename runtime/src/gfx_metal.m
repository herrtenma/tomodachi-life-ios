// Graphics on Metal, step 1: command buffers are recorded on the host (one op list per
// NVNcommandBuffer), EndRecording hands back a handle, SubmitCommands replays the ops on a
// Metal queue. Only render-target binding and clears exist so far; draws are still stubs.
// Every NVN color texture gets an RGBA8 Metal texture (format mapping comes later).
// Present draws the window texture into a CAMetalLayer, paced to 60 Hz like vsync.
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#import <Cocoa/Cocoa.h>
#else
#import <Foundation/Foundation.h>
#endif
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#if __has_include(<MetalFX/MetalFX.h>)   // not in the iOS Simulator SDK: plain scaling there
#import <MetalFX/MetalFX.h>
#define NX_METALFX 1
#endif
#import <QuartzCore/CAMetalLayer.h>
#include <pthread.h>
#include <time.h>

#include "gfx.h"
#include "gfx_internal.h"
#include "nxrt.h"
int nx_game_width(void);   // ui_touch.c: 1280, or the widescreen width (720 high)

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
id<MTLDevice> g_dev;
id<MTLCommandQueue> g_queue;
static id<MTLLibrary> g_lib;
static id<MTLRenderPipelineState> g_clear_pso, g_blit_pso;
static CAMetalLayer *g_layer;
static NSMapTable *g_win_textures;  // NVNwindow(Builder)* -> NSData of NVNtexture*

static NSString *const kShaders = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct V { float4 pos [[position]]; float2 uv; };\n"
    "vertex V fs_tri(uint vid [[vertex_id]]) {\n"
    "    float2 p = float2((vid << 1) & 2, vid & 2);\n"
    "    V o; o.pos = float4(p * 2 - 1, 0, 1); o.uv = float2(p.x, 1 - p.y); return o;\n"
    "}\n"
    "fragment float4 clear_frag(constant float4 &c [[buffer(0)]]) { return c; }\n"
    "fragment float4 blit_frag(V in [[stage_in]], texture2d<float> t [[texture(0)]]) {\n"
    "    constexpr sampler s(filter::linear); return t.sample(s, in.uv);\n"
    "}\n"
    "fragment float4 blit_rect_frag(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant float4 &r [[buffer(0)]]) {\n"
    "    constexpr sampler s(filter::linear); return t.sample(s, r.xy + in.uv * r.zw);\n"
    "}\n";

static NSMapTable *ptr_map(void) {
    return [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                                 valueOptions:NSPointerFunctionsStrongMemory];
}
#define KEY(p) ((__bridge id)(void *)(p))

static id<MTLRenderPipelineState> pso(id<MTLLibrary> lib, NSString *frag, MTLPixelFormat fmt) {
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"fs_tri"];
    d.fragmentFunction = [lib newFunctionWithName:frag];
    d.colorAttachments[0].pixelFormat = fmt;
    NSError *err = nil;
    id<MTLRenderPipelineState> p = [g_dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!p) nx_fatal("gfx: pipeline %s: %s", frag.UTF8String, err.localizedDescription.UTF8String);
    return p;
}

void gfx_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_dev = MTLCreateSystemDefaultDevice();
        if (!g_dev) nx_fatal("gfx: no Metal device");
        g_queue = [g_dev newCommandQueue];
        NSError *err = nil;
        g_lib = [g_dev newLibraryWithSource:kShaders options:nil error:&err];
        if (!g_lib) nx_fatal("gfx: shaders: %s", err.localizedDescription.UTF8String);
        g_clear_pso = pso(g_lib, @"clear_frag", MTLPixelFormatRGBA8Unorm);
        g_blit_pso = pso(g_lib, @"blit_frag", MTLPixelFormatBGRA8Unorm);
        g_win_textures = ptr_map();
        nx_log("gfx: Metal device %s", g_dev.name.UTF8String);
    });
}

// Like gfx_blit_pso, sampling the source rectangle given as float4 {u0, v0, du, dv} at fragment buffer 0.
id<MTLRenderPipelineState> gfx_blit_rect_pso(MTLPixelFormat target) {
    static NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *cache;
    @synchronized([NSNull null]) {
        if (!cache) cache = [NSMutableDictionary new];
        id<MTLRenderPipelineState> p = cache[@(target)];
        if (!p) cache[@(target)] = p = pso(g_lib, @"blit_rect_frag", target);
        return p;
    }
}
id<MTLRenderPipelineState> gfx_blit_pso(MTLPixelFormat target) {
    static NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *cache;
    @synchronized([NSNull null]) {
        if (!cache) cache = [NSMutableDictionary new];
        id<MTLRenderPipelineState> p = cache[@(target)];
        if (!p) cache[@(target)] = p = pso(g_lib, @"blit_frag", target);
        return p;
    }
}

int gfx_write_png(const char *path, const void *rgba, NSUInteger w, NSUInteger h) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, rgba, w * h * 4, NULL);
    CGImageRef img = CGImageCreate(w, h, 8, 32, w * 4, cs, (CGBitmapInfo)kCGImageAlphaNoneSkipLast, dp, NULL, false,
                                   kCGRenderingIntentDefault);
    NSURL *url = [NSURL fileURLWithPath:@(path)];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
    int ok = 0;
    if (dst) {
        CGImageDestinationAddImage(dst, img, NULL);
        ok = CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
    CGImageRelease(img);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);
    return ok;
}

// ---- windows and present -----------------------------------------------------------

void gfx_window_builder_textures(void *builder, int32_t n, void *const *textures) {
    @autoreleasepool {
        gfx_init();
        if (n < 0 || n > 16 || !textures) n = 0;
        pthread_mutex_lock(&g_lock);
        [g_win_textures setObject:[NSData dataWithBytes:textures length:n * sizeof(void *)] forKey:KEY(builder)];
        pthread_mutex_unlock(&g_lock);
        nx_log("gfx: window builder %p gets %d textures", builder, n);
    }
}

static volatile int32_t g_crop[4];   // nvnWindowSetCrop: x, y, w, h (w = 0: the whole texture)
void gfx_window_set_crop(void *window, int32_t x, int32_t y, int32_t w, int32_t h) {
    g_crop[0] = x, g_crop[1] = y, g_crop[2] = w, g_crop[3] = h;
}
void gfx_window_init(void *window, const void *builder) {
    @autoreleasepool {
        gfx_init();
        pthread_mutex_lock(&g_lock);
        NSData *d = [g_win_textures objectForKey:KEY(builder)];
        if (d) [g_win_textures setObject:d forKey:KEY(window)];
        pthread_mutex_unlock(&g_lock);
    }
}

// Vsync pacing: present returns after the game's present interval (nvnWindowSetPresentInterval, vsyncs
// of 60 Hz per present; late frames resynchronize). The game asks for 2 = 30 fps, and its logic advances
// a fixed step per frame (same camera position at the same frame number at 20 and 37 fps), so presenting
// faster than the interval speeds the whole game up.
// NXRT_PACE_HZ=<n>: pace to n Hz instead (testing only; above 30 the game runs fast).
uint64_t g_present_pace_ns;   // time slept in pace() (NXRT_HITCHLOG)

// NXRT_PACESTAT=1: every 300 frames, frames per step and how many were on screen for a different number of 60 Hz
// vsyncs than their step (the picture jumps by the difference: what reads as jitter)
static void pace_stat(int step, int shown) {
    static int ps = -1;
    static unsigned cnt[5], over, under, n;
    extern volatile int g_gfx_frame;
    if (ps < 0) ps = getenv("NXRT_PACESTAT") && atoi(getenv("NXRT_PACESTAT"));
    if (!ps) return;
    cnt[step < 5 ? step : 4]++, n++;
    if (shown > step) over++;
    else if (shown < step) under++;
    if (n == 300) {
        nx_log("pace: frame %d: step 1/2/3/4 %u/%u/%u/%u, on screen longer than the step %u, shorter %u (of 300)", g_gfx_frame,
               cnt[1], cnt[2], cnt[3], cnt[4], over, under);
        memset(cnt, 0, sizeof cnt), over = under = n = 0;
    }
}

// NXRT_VRR (loader.c: the controller's hysteresis patched out): the frame rate floats per frame (60 / 30 / 20) and the
// picture moves exactly as much as the time it was shown. Each frame gets a target of m vblanks after the previous
// present, m = the most vblanks any of the last 30 frames needed (one slow frame -> 30 at once, back to 60 after
// half a second of frames that fit); an early frame waits for its vblank (never shown early), a late one goes out on
// the next vblank and the vblanks lost are added to the next frame's step, so game time catches up in one frame
// instead of a slow-motion stretch. The step goes to the controller as min = max (ui_touch.c nx_fps_step) and is
// read back from the present interval it set, so a frame of delay there is corrected too.
static void pace_vrr(uint64_t now, int step) {
    const uint64_t vb = 1000000000ull / 60;
    static uint64_t slot;      // time of the last present's vblank
    static long shown, world;  // vblanks: last present's vblank count, game time of the frame on screen
    static int m = 1, need[30], ni, win;   // NXRT_VRR_WINDOW=<frames> (1-30, default 30): lookback for m
    if (!win) win = getenv("NXRT_VRR_WINDOW") ? MAX(1, MIN(30, atoi(getenv("NXRT_VRR_WINDOW")))) : 30;
    if (!slot || now > slot + 10 * vb) slot = now - vb, shown = world = 0;   // start or a long stall (loading)
    int nd = now <= slot + 2000000 ? 1 : (int)((now - slot - 2000000 + vb - 1) / vb);   // vblanks this frame needed
    need[ni++ % win] = nd;
    int wait = nd > m ? nd : m;
    uint64_t target = slot + (uint64_t)wait * vb;
    if (now < target) {
        uint64_t d = target - now;
        struct timespec ts = {(time_t)(d / 1000000000ull), (long)(d % 1000000000ull)};
        nx_core_leave();
        nanosleep(&ts, NULL);
        nx_core_enter();
        g_present_pace_ns += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - now;
    }
    slot = target, shown += wait, world += step;
    pace_stat(step, wait);
    m = 1;
    for (int i = 0; i < win; i++) m = need[i] > m ? need[i] : m;
    if (m > 3) m = 3;
    long debt = shown - world, next = m + debt;   // vblanks the game is behind the screen
    if (next > 4) world += next - 4, next = 4;    // more than 4 behind (hitch): drop the rest
    if (next < 1) next = 1;
    void nx_fps_step(int n);
    nx_fps_step((int)next);
}

static void pace(void) {
    static uint64_t next;
    extern int g_present_interval;
    static int hz = -1;
    if (hz < 0) hz = getenv("NXRT_PACE_HZ") && atoi(getenv("NXRT_PACE_HZ")) > 0 ? atoi(getenv("NXRT_PACE_HZ")) : 0;
    // NXRT_PACE_FROM=<n>: present at 60 Hz for the first n frames (was the load-crash workaround, default 300,
    // before cores.c fixed the cause: two same-core threads sharing the per-core font-engine state).
    extern volatile int g_gfx_frame;
    static int from = -1;
    if (from < 0) from = getenv("NXRT_PACE_FROM") ? atoi(getenv("NXRT_PACE_FROM")) : 0;
    int interval = g_present_interval > 0 && g_present_interval < 5 && g_gfx_frame > from ? g_present_interval : 1;
    uint64_t period = hz ? 1000000000ull / hz : 1000000000ull / 60 * (uint64_t)interval;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    extern int g_vrr;
    if (g_vrr && !hz && g_gfx_frame > from) {
        pace_vrr(now, g_present_interval > 0 && g_present_interval < 5 ? g_present_interval : 1);
        return;
    }
    if (!next || now > next + 3 * period) next = now;
    if (now < next) {
        uint64_t d = next - now;
        struct timespec ts = {(time_t)(d / 1000000000ull), (long)(d % 1000000000ull)};
        nx_core_leave();   // waiting for vsync: other threads on this emulated core run (cores.c)
        nanosleep(&ts, NULL);
        nx_core_enter();
        g_present_pace_ns += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - now;
    }
    next += period;
    static uint64_t last;   // NXRT_PACESTAT: on a 60 Hz display a frame stays up until the next vblank (2 ms slack)
    uint64_t t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), d = t - last;
    if (last) pace_stat(interval, d > 2000000 ? (int)((d - 2000000 + 16666666) / 16666667) : 1);
    last = t;
}

// NXRT_SHOT=<file.png>: write presented frame NXRT_SHOT_FRAME (default 120) to a PNG. A list
// (NXRT_SHOT_FRAME=1000,1100,1200) writes one PNG per frame, <file.png>_<frame>.png.
static void shot(id<MTLTexture> src, int frame) {
    const char *path = getenv("NXRT_SHOT");
    const char *fs = getenv("NXRT_SHOT_FRAME");
    int nx_sweep(int frame, long *limit);
    long lim = 0;
    char swpath[1024];
    if (path && nx_sweep(frame - 1, &lim)) {   // frame N's draws were recorded while g_gfx_frame was N - 1
        snprintf(swpath, sizeof swpath, "%s_%04ld.png", path, lim);
        path = swpath;
    } else if (path && fs && strchr(fs, ',')) {
        int hit = 0;
        for (const char *p = fs; p && !hit; p = strchr(p, ',') ? strchr(p, ',') + 1 : NULL) hit = atoi(p) == frame;
        if (!hit) return;
        snprintf(swpath, sizeof swpath, "%s_%05d.png", path, frame);
        path = swpath;
    } else if (!path || frame != (fs ? atoi(fs) : 120)) return;
    NSUInteger w = src.width, h = src.height;
    id<MTLBuffer> buf = [g_dev newBufferWithLength:w * h * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
    id<MTLBlitCommandEncoder> b = [cmd blitCommandEncoder];
    [b copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:(MTLOrigin){0, 0, 0} sourceSize:(MTLSize){w, h, 1}
              toBuffer:buf destinationOffset:0 destinationBytesPerRow:w * 4 destinationBytesPerImage:w * h * 4];
    [b endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];
    int ok = gfx_write_png(path, buf.contents, w, h);
    nx_log("gfx: frame %d (%lux%lu) %s %s", frame, (unsigned long)w, (unsigned long)h, ok ? "saved to" : "FAILED", path);
}

// The island's picture on the launcher's card (launcher_ios.m): every 15 s of play, a 480 px wide copy of the shown
// frame -> <NXRT_DATA>/snapshot.jpg (written off the render thread). Only from frames with the 3D world in them (500+
// draws: the island draws 1,200-5,400, loading screens and menus far fewer), not the title screen, not dark frames
// (fades). NXRT_SNAPSHOT=0: off.
static void snapshot(id<MTLCommandBuffer> cmd, id<MTLTexture> shown, const float r[4], int cw, int ch) {
    static int on = -1;
    static uint64_t last, last_draws;
    if (on < 0) on = !getenv("NXRT_SNAPSHOT") || atoi(getenv("NXRT_SNAPSHOT"));
    int nx_ui_flags(void);
    uint64_t gfx_draws_total(void), dt = gfx_draws_total(), draws = dt >= last_draws ? dt - last_draws : 0;
    last_draws = dt;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (!on || (last && now - last < 15000000000ull) || draws < 500 || (nx_ui_flags() & 2) || cw <= 0 || ch <= 0) return;
    last = now;
    NSUInteger w = 480, h = MAX(1, (NSUInteger)(480.0 * ch / cw));
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget, td.storageMode = MTLStorageModeShared;
    id<MTLTexture> small = [g_dev newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = small;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cmd renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:gfx_blit_rect_pso(MTLPixelFormatBGRA8Unorm)];
    [e setFragmentBytes:r length:16 atIndex:0];
    [e setFragmentTexture:shown atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    NSString *path = [@(getenv("NXRT_DATA") ?: "data") stringByAppendingPathComponent:@"snapshot.jpg"];
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> c) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSMutableData *px = [NSMutableData dataWithLength:w * h * 4];
            [small getBytes:px.mutableBytes bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
            const uint8_t *p = px.bytes;
            uint64_t sum = 0;
            for (NSUInteger i = 0; i < w * h; i++) sum += p[i * 4] + 2 * p[i * 4 + 1] + p[i * 4 + 2];
            if (sum / (w * h * 4) < 40) return;   // mostly dark: a fade
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGContextRef bc = CGBitmapContextCreate(px.mutableBytes, w, h, 8, w * 4, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
            CGImageRef img = bc ? CGBitmapContextCreateImage(bc) : NULL;
            NSString *tmp = [path stringByAppendingString:@".tmp"];
            CGImageDestinationRef dst = img ? CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:tmp], CFSTR("public.jpeg"), 1, NULL) : NULL;
            if (dst) {
                CGImageDestinationAddImage(dst, img, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @0.8});
                if (CGImageDestinationFinalize(dst)) rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation);
                CFRelease(dst);
            }
            if (img) CGImageRelease(img);
            if (bc) CGContextRelease(bc);
            CGColorSpaceRelease(cs);
        });
    }];
}

// NXRT_UPSCALE=<height>: MetalFX spatial upscaling of the window crop to that height (the game renders at
// NXRT_RENDER_H or its own 720/1080); the drawable gets the upscaled size. Unset/0 = the crop as is (the
// compositor scales it to the screen). The scaler reads the crop in place (top left of the window texture:
// inputContentWidth/Height) and writes an intermediate texture, which the blit copies to the drawable
// (drawables are framebuffer-only). No scaler for the format (nil): the plain path.
static int upscale_h(void) {
    static int h = -1;
    if (h < 0) {
        h = getenv("NXRT_UPSCALE") ? atoi(getenv("NXRT_UPSCALE")) & ~1 : 0;
        if (h && (h < 360 || h > 2160)) h = 0;
    }
    return h;
}
#ifdef NX_METALFX
static id<MTLFXSpatialScaler> g_fx;
static __strong id<MTLTexture> g_fx_out;
static NSUInteger g_fx_key[6];
static id<MTLTexture> upscale(id<MTLCommandBuffer> cmd, id<MTLTexture> src, int cw, int ch) {
    int oh = upscale_h();
    if (!oh || oh <= ch) return nil;
    int ow = (int)(((int64_t)cw * oh / ch) & ~1);
    NSUInteger key[6] = {src.width, src.height, (NSUInteger)src.pixelFormat, (NSUInteger)ow, (NSUInteger)oh, 0};
    if (memcmp(key, g_fx_key, sizeof key)) {
        memcpy(g_fx_key, key, sizeof key);
        g_fx = nil, g_fx_out = nil;
        MTLFXSpatialScalerDescriptor *d = [MTLFXSpatialScalerDescriptor new];
        d.inputWidth = src.width, d.inputHeight = src.height;
        d.outputWidth = ow, d.outputHeight = oh;
        d.colorTextureFormat = src.pixelFormat, d.outputTextureFormat = src.pixelFormat;
        d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        if ([MTLFXSpatialScalerDescriptor supportsDevice:g_dev]) g_fx = [d newSpatialScalerWithDevice:g_dev];
        if (g_fx) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat width:ow height:oh mipmapped:NO];
            td.usage = g_fx.outputTextureUsage | MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModePrivate;
            g_fx_out = [g_dev newTextureWithDescriptor:td];
        }
        nx_log("gfx: MetalFX spatial upscale %dx%d -> %dx%d (format %lu): %s", cw, ch, ow, oh, (unsigned long)src.pixelFormat,
               g_fx && g_fx_out ? "on" : "not available, plain scaling");
    }
    if (!g_fx || !g_fx_out) return nil;
    g_fx.colorTexture = src;
    g_fx.inputContentWidth = cw, g_fx.inputContentHeight = ch;
    g_fx.outputTexture = g_fx_out;
    [g_fx encodeToCommandBuffer:cmd];
    return g_fx_out;
}
#else
static id<MTLTexture> upscale(id<MTLCommandBuffer> cmd, id<MTLTexture> src, int cw, int ch) { return nil; }
#endif

volatile int g_gfx_frame;   // presents so far (read by probes)
volatile int g_gfx_background;
void gfx_wait_foreground(void) {
    while (g_gfx_background) usleep(20000);
}

void gfx_queue_present(void *queue, void *window, int32_t index) {
    static int frames;
    gfx_wait_foreground();
    g_gfx_frame = frames + 1;
    void nx_hitch_frame(int frame);
    nx_hitch_frame(frames + 1);   // NXRT_HITCHLOG
    if (getenv("NXRT_WATCHDOG_TEST") && frames + 1 == atoi(getenv("NXRT_WATCHDOG_TEST")))   // test the freeze watchdog (crash.c)
        for (;;) sleep(60);
    gfx_texture_trim();
    if (frames == 60) {
        void nx_nvn_findproc_env(void), nx_nvn_gotname_env(void), nx_findptr_env(void);
        nx_nvn_findproc_env();
        nx_findptr_env();
        nx_nvn_gotname_env();
    }
    {
        void nx_hid_frame(int frame), nx_ui_frame(int frame);
        nx_ui_frame(frames + 1);   // touch gestures first: they feed this HID sample
        nx_hid_frame(frames + 1);
    }
    {
        void nx_tickprobe_frame(int frame);
        nx_tickprobe_frame(frames + 1);
    }
    {
        // NXRT_FRAMEDRAWS=1: one line per frame with that frame's executed / skipped / compiling draws
        // (spots objects the game stops submitting vs objects that render wrong).
        static int on = -1;
        if (on < 0) on = getenv("NXRT_FRAMEDRAWS") != NULL;
        void gfx_frame_draws(uint64_t out[6]);
        if (on) {
            uint64_t d[6];
            gfx_frame_draws(d);
            nx_log("fd: frame %d draws %llu skipped %llu render-off %llu calls %llu submitted %llu ended %llu", frames, d[0], d[1], d[2],
                   d[3], d[4], d[5]);
        }
    }
    if (++frames == 1) nx_log("*** demo A milestone: the game reached its first nvnQueuePresentTexture ***");
    else {
        static int every;   // NXRT_STATS_EVERY=N frames (default 600)
        if (!every) every = getenv("NXRT_STATS_EVERY") ? MAX(1, atoi(getenv("NXRT_STATS_EVERY"))) : 600;
        if (frames % every == 0) {
            static uint64_t last;
            uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            nx_log("gfx: frame %d presented (%.1f fps)", frames, last ? every * 1e9 / (double)(now - last) : 0.0);
            last = now;
            void gfx_draw_stats(int frames);
            if (getenv("NXRT_GFXDBG") || getenv("NXRT_PERF") || getenv("NXRT_STAGETIME")) gfx_draw_stats(every);   // NXRT_PERF=1: stats without GFXDBG's per-draw cost
        }
    }
    if (getenv("NXRT_NVNSTATS") && (frames == 1200 || frames == 1500)) {
        void nx_nvn_dump_stats(int frames);
        nx_nvn_dump_stats(frames == 1200 ? 1200 : 300);   // first call resets the counters
    }
    @autoreleasepool {
        gfx_init();
        pthread_mutex_lock(&g_lock);
        NSData *d = [g_win_textures objectForKey:KEY(window)];
        const void *t = d && index >= 0 && (size_t)index < d.length / sizeof(void *) ? ((void *const *)d.bytes)[index] : NULL;
        id<MTLTexture> src = gfx_texture_mtl(t);
        static int wlog;
        if (t && wlog < 2 && frames > 600) {
            NxTexDesc wd;
            nx_nvn_texture_desc(t, &wd);
            nx_log("gfx: window texture %p (index %d): %dx%d fmt %d storage %p", t, index, wd.w, wd.h, wd.format, wd.pool_data);
            wlog++;
        }
        pthread_mutex_unlock(&g_lock);
        static int logged;
        if (logged++ < 2) nx_log("gfx: present window %p index %d -> texture %p (%s)", window, index, t, src ? "ok" : "none");
        CAMetalLayer *layer = g_layer;
        id<MTLTexture> up = nil;
        if (src && (layer || upscale_h())) {   // headless + NXRT_UPSCALE: upscale too (the shot shows it)
            // The shown part: the window crop (handheld renders 1280x720 into the top left of 1920x1080 textures)
            int32_t cx = g_crop[0], cy = g_crop[1], cw = g_crop[2], ch = g_crop[3];
            if (cw <= 0 || ch <= 0 || cx < 0 || cy < 0 || cx + cw > (int32_t)src.width || cy + ch > (int32_t)src.height)
                cx = cy = 0, cw = (int32_t)src.width, ch = (int32_t)src.height;
            id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
            if (cx == 0 && cy == 0) up = upscale(cmd, src, cw, ch);
            id<MTLTexture> shown = up ? up : src;
            if (up) cw = (int32_t)up.width, ch = (int32_t)up.height;
            if (layer && (layer.drawableSize.width != cw || layer.drawableSize.height != ch)) layer.drawableSize = CGSizeMake(cw, ch);
            id<CAMetalDrawable> dr = layer ? [layer nextDrawable] : nil;
            if (dr) {
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = dr.texture;
                rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> e = [cmd renderCommandEncoderWithDescriptor:rp];
                float r[4] = {(float)cx / src.width, (float)cy / src.height, (float)cw / src.width, (float)ch / src.height};
                if (up) r[0] = r[1] = 0, r[2] = r[3] = 1;
                [e setRenderPipelineState:gfx_blit_rect_pso(MTLPixelFormatBGRA8Unorm)];
                [e setFragmentBytes:r length:sizeof r atIndex:0];
                [e setFragmentTexture:shown atIndex:0];
                [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [e endEncoding];
                [cmd presentDrawable:dr];
                snapshot(cmd, shown, r, cw, ch);
            }
            [cmd commit];
        }
        if (up) shot(up, frames);
        else if (src) shot(src, frames);
        gfx_texdump_at_frame(frames);
    }
    pace();
}

// The window's layer (iOS: the app's view, src/ios/app_ios.m). Present draws into it; nil = headless.
void gfx_attach_layer(CAMetalLayer *layer) { g_layer = layer; }

// The Mac window, input and launcher: src/mac/app_mac.m (gfx_run_app).
