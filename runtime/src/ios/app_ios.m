// iOS app shell: a full-screen view with a 16:9 CAMetalLayer the game presents into, touches -> the
// Switch touch screen (1280x720 space, handheld mode), an on-screen B (back) button beside the picture,
// game controllers -> Player 1. The .xci and prod.keys come from the app's
// Documents folder (Files app: "On My iPhone > nxrt") or, if not there, from files picked once in the Files app
// (read in place, remembered as bookmarks). Documents also holds data/save (the save) and nxrt.log.
// The game code itself is linked into the binary (make embed / embed.py), so no JIT is needed.
#import <CoreHaptics/CoreHaptics.h>
#import <GameController/GameController.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <os/proc.h>
#include <sys/mman.h>
#include <pthread.h>
#include <sys/sysctl.h>

#include "gfx_internal.h"
#include "nxrt.h"
#import "../app_online.h"

void gfx_attach_layer(CAMetalLayer *layer);
void nx_hid_set_touch(int down, int x, int y);
void nx_ui_touch2(int type, int id, float x, float y);   // ui_touch.c: 0 down, 1 move, 2 up, 3 cancel, 4 Back
int nx_ui_flags(void);                                   // bit 0: the game shows a B prompt (show Back)
int nx_game_width(void);                                 // ui_touch.c: 1280, or the widescreen width (720 high)
void nx_hid_set_buttons(uint64_t buttons);
void nx_hid_set_stick(int x, int y);

static void (*g_guest_main)(void);
static uint64_t g_pad_buttons;   // controller buttons
static int g_pad_stick[2];       // controller left stick

// Buttons + left stick to hid: the stick's direction bits (16-19, as a real stick sets them) follow the stick in use.
static void send_stick(void) {
    int x = g_pad_stick[0], y = g_pad_stick[1];
    uint64_t dir = (x < -16384 ? 1ull << 16 : 0) | (y > 16384 ? 1ull << 17 : 0) | (x > 16384 ? 1ull << 18 : 0) | (y < -16384 ? 1ull << 19 : 0);
    nx_hid_set_buttons(g_pad_buttons | dir);
    nx_hid_set_stick(x, y);
}

static void *guest_thread(void *arg) {
    g_guest_main();
    return NULL;
}

// A file picked in the Files app (outside our folder): kept as a bookmark and read in place. The access
// started here lasts for the app's lifetime.
static NSString *bookmarked(NSString *key) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSData *d = [ud dataForKey:key];
    if (!d) return nil;
    BOOL stale = NO;
    NSURL *u = [NSURL URLByResolvingBookmarkData:d options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:nil];
    if (!u || ![u startAccessingSecurityScopedResource]) return nil;
    if (stale) {
        NSData *n = [u bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
        if (n) [ud setObject:n forKey:key];
    }
    return [NSFileManager.defaultManager fileExistsAtPath:u.path] ? u.path : nil;
}

// Paths: NXRT_XCI = the first .xci in Documents, else (under LiveContainer) the Packager's folder's, else the picked
// one; NXRT_KEYS = the same order for prod.keys; NXRT_SHADERS = Documents/shaders, the shaders translated on this device
// (shader_xlat.m); cwd = Documents (fs.c keeps the save in data/save, relative).
// A dump that is this game: it opens with these keys and has the game's title screen layout (the ROM screen's test).
static BOOL is_this_game(NSString *xci, NSString *keys) {
    int nx_content_try(const char *xci_path, const char *keys_path);
    uint8_t *nx_romfs_file(const char *fname, uint64_t *size);
    if (nx_content_try(xci.fileSystemRepresentation, keys.fileSystemRepresentation)) return NO;
    uint64_t sz;
    uint8_t *t = nx_romfs_file("Common_Title_00.Nin_NX_NVN.blarc.zs", &sz);
    free(t);
    return t != NULL;
}
static void setup_paths(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    // Under LiveContainer our Documents is .../Documents/Data/Application/<uuid>/Documents, which a re-import of the
    // app deletes (an 8 GB .xci was lost that way). Use LiveContainer's own Documents/Tomodachi instead: same process
    // sandbox, survives updates, visible in the Files app under LiveContainer > Tomodachi. The Packager's folder
    // (LiveContainer > Packager) is next to it: the .xci and prod.keys it built the app from are used from there.
    NSRange lc = [docs rangeOfString:@"/Documents/Data/Application/"];
    NSString *packager = nil;
    if (lc.location != NSNotFound) {
        NSString *lcdocs = [[docs substringToIndex:lc.location] stringByAppendingPathComponent:@"Documents"];
        docs = [lcdocs stringByAppendingPathComponent:@"Tomodachi"];
        packager = [lcdocs stringByAppendingPathComponent:@"Packager"];
        [fm createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
    }
    [fm createDirectoryAtPath:[docs stringByAppendingPathComponent:@"data/save"] withIntermediateDirectories:YES attributes:nil error:nil];
    chdir(docs.fileSystemRepresentation);
    nx_session_begin();                 // keeps the last log as nxrt-prev.log and notes whether that session ended in a crash
    freopen("nxrt.log", "w", stderr);   // the log (nx_log writes stderr), readable in the Files app
    setvbuf(stderr, NULL, _IOLBF, 0);
    // Documents/nxrt/env.txt: NAME=value lines set before the defaults below (pushed over Wi-Fi to A/B a setting
    // without a re-import; relaunch the app to apply).
    for (NSString *line in [[NSString stringWithContentsOfFile:@"env.txt" encoding:NSUTF8StringEncoding error:nil]
                               componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound || [line hasPrefix:@"#"]) continue;
        NSString *k = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *v = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        setenv(k.UTF8String, v.UTF8String, 1);
        nx_log("ios: env.txt %s=%s", k.UTF8String, v.UTF8String);
    }
    NSString *xci = nil;
    int nx_launcher_enabled(void), nx_rom_unmounted(void);
    BOOL unmounted = nx_launcher_enabled() && nx_rom_unmounted();   // Settings > Remove ROM: ask again (ROM screen)
    for (NSString *dir in unmounted ? @[] : packager ? @[docs, packager] : @[docs]) {
        NSString *k = [dir stringByAppendingPathComponent:@"prod.keys"];
        for (NSString *f in [[fm contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
            if (![f.pathExtension.lowercaseString isEqualToString:@"xci"]) continue;
            NSString *p = [dir stringByAppendingPathComponent:f];
            // in the Packager's folder, the .xci that is this game (other ports' dumps may be there too)
            if (dir == docs || ([fm fileExistsAtPath:k] && is_this_game(p, k))) { xci = p; break; }
        }
        if (xci) break;
    }
    if (!xci && !unmounted) xci = bookmarked(@"xci");
    NSString *keys = [docs stringByAppendingPathComponent:@"prod.keys"];
    if (![fm fileExistsAtPath:keys] && packager && [fm fileExistsAtPath:[packager stringByAppendingPathComponent:@"prod.keys"]])
        keys = [packager stringByAppendingPathComponent:@"prod.keys"];
    if (![fm fileExistsAtPath:keys]) keys = bookmarked(@"keys");
    if (xci) setenv("NXRT_XCI", xci.fileSystemRepresentation, 1);
    if (keys) setenv("NXRT_KEYS", keys.fileSystemRepresentation, 1);
    // romfs.bin (tools/texconv: the RomFS with its BC textures as ASTC, so the A15 samples them without decoding):
    // used when present; the .xci still serves the program and system data.
    NSString *romfs = [docs stringByAppendingPathComponent:@"romfs.bin"];
    if ([fm fileExistsAtPath:romfs]) setenv("NXRT_ROMFS", romfs.fileSystemRepresentation, 0);
    nx_log("ios: xci %s, keys %s, romfs %s", xci ? xci.UTF8String : "(not chosen)", keys ? keys.UTF8String : "(not chosen)",
           getenv("NXRT_ROMFS") ? getenv("NXRT_ROMFS") : "(the .xci's)");
    setenv("NXRT_SHADERS", [docs stringByAppendingPathComponent:@"shaders"].fileSystemRepresentation, 0);
    setenv("NXRT_HDSHADERS", "0", 0);   // no hand-written shader replacements ship with the app
    // Defaults of the Mac test recipe that the phone needs too (unknown IPC commands answered, engine draw order).
    setenv("NXRT_LENIENT", "1", 0);
    setenv("NXRT_MEMUSED", "1", 0);
    setenv("NXRT_DRAW", "1", 0);
    setenv("NXRT_COMPUTE", "1", 0);
    setenv("NXRT_PERF", "1", 0);
    setenv("NXRT_STATS_EVERY", "300", 0);   // fps / encode / GPU numbers in the log every 300 frames
    setenv("NXRT_HANDHELD", "1", 0);   // handheld: the game takes touch input (docked ignores the touch screen), 720p
    setenv("NXRT_VIBLOG", "1", 0);   // the game's vibration on/off in the log (haptics check)
#if TARGET_OS_SIMULATOR
    setenv("NXRT_BCDECODE", "1", 0);   // the Mac GPU has BC, the A15 doesn't: take the iPhone's decode path
    // shaders missing from the metallib (variants), collected for the next build (make -C ios sim-misses)
    setenv("NXRT_SHADER_MISSDIR", [docs stringByAppendingPathComponent:@"shader_misses"].fileSystemRepresentation, 0);
#endif
}

// Display defaults, after the prelauncher's choices (launcher_ios.m) and env.txt: graphics mode, widescreen.
static void display_defaults(void) {
    void nx_apply_mode(void);
    nx_apply_mode();   // NXRT_MODE=quality | performance (ui_touch.c)
    // widescreen: render as wide as the screen at 720 high (19.5:9 -> 1558); NXRT_WIDE=1280 turns it off
    CGSize sz = UIScreen.mainScreen.bounds.size;
    CGFloat lo = MIN(sz.width, sz.height), hi = MAX(sz.width, sz.height);
    char wide[16];
    snprintf(wide, sizeof wide, "%d", lo > 0 ? ((int)lround(720 * hi / lo) & ~1) : 1280);
    setenv("NXRT_WIDE", wide, 0);
}
int nx_launcher_enabled(void), nx_launcher_fps_counter(void), nx_launcher_take_autostart(void);
void nx_launcher_show(UIViewController *host, BOOL running, void (^start)(void), void (^resume)(void), void (^removeRom)(void),
                      void (^shown)(UIView *v));
UIView *nx_rom_view(UIViewController *host, void (^done)(NSString *xci));
void nx_rom_forget(void);

// Device facts the port depends on (first launch on a new device: check the log).
static void log_device(id<MTLDevice> dev) {
    char model[64] = "";
    size_t n = sizeof model;
    sysctlbyname("hw.machine", model, &n, NULL, 0);
    nx_log("ios: %s, iOS %s, GPU %s, BC textures %s, memory limit %.2f GB available now", model,
           UIDevice.currentDevice.systemVersion.UTF8String, dev.name.UTF8String,
           dev.supportsBCTextureCompression ? "yes" : "NO", os_proc_available_memory() / 1e9);
    // Address space: the guest reservation (mem.c) needs the extended-virtual-addressing entitlement.
    void *a = mmap(NULL, 64ull << 30, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    nx_log("ios: 64 GB address-space reservation %s", a != MAP_FAILED ? "ok" : "FAILED (extended-virtual-addressing missing?)");
    if (a != MAP_FAILED) munmap(a, 64ull << 30);
}

// ---- Haptics: the game's vibration (hid.c nx_vibration_get: strongest band, 0..1, and its frequency) on the Taptic
// Engine. One long continuous event; ~100 times a second its intensity follows the amplitude and its sharpness the
// frequency (Switch HD rumble bands ~40-320 Hz -> sharpness 0..1). Stops when the game is silent.
void nx_vibration_get(float *amp, float *freq);
static CHHapticEngine *g_hap;
static id<CHHapticAdvancedPatternPlayer> g_hap_player;
static BOOL g_hap_on;
static void haptics_player(void) {
    NSError *err = nil;
    CHHapticEvent *ev = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
        parameters:@[[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
                     [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5]]
        relativeTime:0 duration:30];
    CHHapticPattern *pat = [[CHHapticPattern alloc] initWithEvents:@[ev] parameters:@[] error:&err];
    g_hap_player = pat ? [g_hap createAdvancedPlayerWithPattern:pat error:&err] : nil;
    g_hap_player.loopEnabled = YES;
    g_hap_on = NO;
    if (err) nx_log("ios: haptics: %s", err.localizedDescription.UTF8String);
}
static void haptics_start(void) {
    if (!CHHapticEngine.capabilitiesForHardware.supportsHaptics || getenv("NXRT_NOHAPTICS")) return;
    NSError *err = nil;
    g_hap = [[CHHapticEngine alloc] initAndReturnError:&err];
    if (!g_hap) { nx_log("ios: haptics: no engine (%s)", err.localizedDescription.UTF8String); return; }
    g_hap.playsHapticsOnly = YES;
    g_hap.autoShutdownEnabled = NO;
    g_hap.resetHandler = ^{ [g_hap startAndReturnError:nil]; haptics_player(); };   // after a media-services reset
    g_hap.stoppedHandler = ^(CHHapticEngineStoppedReason r) { g_hap_on = NO; };
    [g_hap startAndReturnError:&err];
    haptics_player();
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_queue_create("nx.haptics", DISPATCH_QUEUE_SERIAL));
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        float amp, freq;
        nx_vibration_get(&amp, &freq);
        float in = fminf(1, sqrtf(amp) * 1.4f);   // Switch amplitudes are low (0.1-0.6 typical): 0.1 -> 0.44
        if (!g_hap_player) return;
        // The game's pulses are short and weak (~0.1 for a few ms; hid.c latches them between polls): a vibration
        // starting plays one crisp tap at its strength (at least 0.6) first, and the continuous event stays on for at
        // least 60 ms. NXRT_HAPTIC_NOTAP=1: continuous only (old).
        static uint64_t hold_until;
        static int notap = -1;
        if (notap < 0) notap = getenv("NXRT_HAPTIC_NOTAP") != NULL;
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (in < 0.02f) {
            if (g_hap_on && (notap || now >= hold_until)) [g_hap_player stopAtTime:CHHapticTimeImmediate error:nil], g_hap_on = NO;
            return;
        }
        float sharp = fminf(1, fmaxf(0, (freq - 40) / 280));
        if (!g_hap_on && !notap) {
            CHHapticEvent *tap = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                parameters:@[[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:fmaxf(in, 0.6f)],
                             [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:sharp]]
                relativeTime:0];
            CHHapticPattern *tp = [[CHHapticPattern alloc] initWithEvents:@[tap] parameters:@[] error:nil];
            [tp ? [g_hap createPlayerWithPattern:tp error:nil] : nil startAtTime:CHHapticTimeImmediate error:nil];
        }
        hold_until = now + 60 * NSEC_PER_MSEC;
        NSArray *ps = @[[[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:in relativeTime:0],
                        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:sharp - 0.5f relativeTime:0]];
        if (!g_hap_on) {
            [g_hap startAndReturnError:nil];
            [g_hap_player startAtTime:CHHapticTimeImmediate error:nil];
            g_hap_on = YES;
        }
        [g_hap_player sendParameters:ps atTime:CHHapticTimeImmediate error:nil];
    });
    dispatch_resume(timer);
    // One short tap at launch: confirms the Taptic Engine works independently of the game's vibration.
    CHHapticEvent *tap = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
        parameters:@[[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:0.8],
                     [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5]]
        relativeTime:0];
    CHHapticPattern *tp = [[CHHapticPattern alloc] initWithEvents:@[tap] parameters:@[] error:&err];
    id<CHHapticPatternPlayer> tpl = tp ? [g_hap createPlayerWithPattern:tp error:&err] : nil;
    BOOL ok = [tpl startAtTime:CHHapticTimeImmediate error:&err];
    nx_log("ios: haptics on (Core Haptics), launch tap %s%s", ok ? "played" : "failed: ", ok ? "" : err.localizedDescription.UTF8String);
}

@interface NxView : UIView
@end
@implementation NxView
+ (Class)layerClass {
    return CAMetalLayer.class;
}
@end

// The floating glass pill (approved spec: 36 pt high, radius 18, ultra-thin material + white 0.65 / dark #1C1C1E 0.6
// overlay, 0.5 pt white 0.5 border, shadow #000 0.18 r8 y2, symbol + title 15 pt semibold, fade 0.2 s).
static UIButton *glass_pill(NSString *title, NSString *symbol, CGFloat width) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, width, 36);   // final size before the glass is added (it resizes with the button)
    b.alpha = 0, b.hidden = YES;
    b.layer.shadowColor = UIColor.blackColor.CGColor, b.layer.shadowOpacity = 0.18f;
    b.layer.shadowRadius = 8, b.layer.shadowOffset = CGSizeMake(0, 2);
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    glass.userInteractionEnabled = NO, glass.layer.cornerRadius = 18, glass.clipsToBounds = YES;
    glass.layer.borderWidth = 0.5, glass.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor;
    glass.frame = CGRectMake(0, 0, width, 36), glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIView *tint = [[UIView alloc] initWithFrame:glass.bounds];
    tint.autoresizingMask = glass.autoresizingMask;
    tint.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x1C / 255.0 green:0x1C / 255.0 blue:0x1E / 255.0 alpha:0.6]
                                                                 : [UIColor colorWithWhite:1 alpha:0.65];
    }];
    [glass.contentView addSubview:tint];
    UIColor *ink = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithWhite:1 alpha:0.9]
                                                                 : [UIColor colorWithRed:0x1C / 255.0 green:0x1C / 255.0 blue:0x1E / 255.0 alpha:1];
    }];
    UIImageView *chev = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol
                                                                   withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]]];
    chev.tintColor = ink;
    UILabel *txt = [UILabel new];
    txt.text = title, txt.textColor = ink, txt.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [txt sizeToFit];
    CGFloat cw = chev.bounds.size.width + 5 + txt.bounds.size.width, x0 = (width - cw) / 2;
    chev.center = CGPointMake(x0 + chev.bounds.size.width / 2, 18), txt.center = CGPointMake(x0 + chev.bounds.size.width + 5 + txt.bounds.size.width / 2, 18);
    [glass.contentView addSubview:chev];
    [glass.contentView addSubview:txt];
    [b addSubview:glass];
    return b;
}

@interface NxViewController : UIViewController <UIDocumentPickerDelegate>
- (void)cancelFingers;
@property(nonatomic, readonly) BOOL paused;
@end
@implementation NxViewController {
    NxView *_game;
    UIButton *_back;      // floating Back (glass pill), shown while the game shows a B prompt
    UILabel *_label;
    NSString *_picking;   // "xci" or "keys" while the Files picker is open
    int _started;
    UITouch *_t[2];       // fingers 0 and 1 (landing order); gestures are recognised in ui_touch.c
    UIView *_launcher;    // the prelauncher (launcher_ios.m): before the game, or over the paused title screen
    UIView *_rom;         // the ROM screen (launcher_ios.m), first launch or after Remove ROM
    UIButton *_islands;   // "Islands" pill, top left while the game's title screen is up
    BOOL _paused;         // the game is paused under the launcher
    UIView *_fps;         // FPS counter pill (Settings), top left of the game
    UILabel *_fpsLabel;
}
- (void)loadView {
    UIView *root = [UIView new];
    root.backgroundColor = UIColor.blackColor;
    _game = [NxView new];
    _game.multipleTouchEnabled = YES;   // pinch / two-finger camera (ui_touch.c)
    root.multipleTouchEnabled = YES;
    [root addSubview:_game];
    // No on-screen controller buttons: taps, swipes and pinches go through the game's own prompts and menus
    // (ui_touch.c). Back: a glass pill (approved spec: 88x36 pt, radius 18, ultra-thin material + white 0.65 / dark
    // #1C1C1E 0.6 overlay, 0.5 pt white 0.5 border, shadow #000 0.18 r8 y2, chevron + "Back" 15 pt semibold, fade 0.2 s,
    // pressed scale 0.94 in 0.1 s), visible only while the game shows a B prompt.
    _back = glass_pill(@"Back", @"chevron.left", 88);
    [_back addTarget:self action:@selector(backDown) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [_back addTarget:self action:@selector(backUp) forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
    [_back addTarget:self action:@selector(backTap) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:_back];
    // Islands: the same pill (112 pt, house symbol), top left while the title screen is up: the island select over the
    // paused game.
    _islands = glass_pill(@"Islands", @"house.fill", 112);
    [_islands addTarget:self action:@selector(islandsTap) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:_islands];
    self.view = root;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _launcher.frame = self.view.bounds;
    _rom.frame = self.view.bounds;
    if (_started < 2) return;   // the game's shape is known once it starts (nx_game_width is fixed on first use)
    // The game's shape (widescreen: nx_game_width() x 720, else 16:9), as large as fits
    CGRect b = self.view.bounds;
    CGFloat aspect = nx_game_width() / 720.0;
    CGFloat w = MIN(b.size.width, b.size.height * aspect), h = w / aspect;
    _game.frame = CGRectMake((b.size.width - w) / 2, (b.size.height - h) / 2, w, h);
    // Back: top right of the game view, 12 pt inside the safe area
    UIEdgeInsets sa = self.view.safeAreaInsets;
    CGFloat right = MIN(CGRectGetMaxX(_game.frame), b.size.width - sa.right), top = MAX(CGRectGetMinY(_game.frame), sa.top);
    _back.frame = CGRectMake(right - 12 - 88, top + 12, 88, 36);
    [self.view bringSubviewToFront:_back];
    CGFloat left = MAX(CGRectGetMinX(_game.frame), sa.left);
    _islands.frame = CGRectMake(left + 12, top + 12, 112, 36);
    _fps.frame = CGRectMake(left + 12, top + 12 + (_islands.hidden ? 0 : 44), _fps.bounds.size.width, 26);
    if (_fps) [self.view bringSubviewToFront:_fps];
}
- (void)backDown {
    [UIView animateWithDuration:0.1 animations:^{ self->_back.transform = CGAffineTransformMakeScale(0.94, 0.94); }];
}
- (void)backUp {
    [UIView animateWithDuration:0.1 animations:^{ self->_back.transform = CGAffineTransformIdentity; }];
}
- (void)backTap {
    [self backUp];
    nx_ui_touch2(4, 0, 0, 0);   // B
}
// Shows / hides Back as the game's B prompt comes and goes (polled 10 times a second).
- (void)pollBack {
    int f = nx_ui_flags();
    [self show:_back want:(f & 1) != 0];
    [self show:_islands want:(f & 2) && !_paused && nx_launcher_enabled()];
}
- (void)show:(UIButton *)b want:(BOOL)want {
    if (want == !b.hidden) return;
    if (want) b.hidden = NO;
    [self.view setNeedsLayout];
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ b.alpha = want ? 1 : 0; }
                     completion:^(BOOL done) { if (!want && done) b.hidden = YES; }];
}
// The title screen's Islands: the game pauses (the render thread waits as in the background) under the island select.
- (void)islandsTap {
    if (_paused) return;
    _paused = YES;
    g_gfx_background = 1;
    [self cancelFingers];
    [self show:_islands want:NO];
    nx_log("ios: island select over the title screen (game paused)");
    __weak NxViewController *ws = self;
    nx_launcher_show(self, YES, nil, ^{ [ws resumeGame]; }, nil, ^(UIView *v) {
        NxViewController *s = ws;
        if (!s) return;
        s->_launcher = v;
        v.frame = s.view.bounds, v.alpha = 0;
        [s.view addSubview:v];
        [UIView animateWithDuration:0.3 animations:^{ v.alpha = 1; }];
    });
}
- (void)resumeGame {
    _paused = NO;
    g_gfx_background = 0;
    if (nx_launcher_fps_counter() && !_fps) [self fpsCounter];
    if (!nx_launcher_fps_counter() && _fps) [_fps removeFromSuperview], _fps = nil;
    [self.view setNeedsLayout];
    nx_log("ios: game resumed");
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!_started) [self next];
}
// Asks for whatever is still missing (Files picker), then starts the game.
- (void)next {
    NSString *want = !getenv("NXRT_XCI") ? @"xci" : !getenv("NXRT_KEYS") ? @"keys" : nil;
    if ([want isEqualToString:@"xci"] && nx_launcher_enabled()) {   // first launch / Remove ROM: the ROM screen
        if (_rom) return;
        __weak NxViewController *ws = self;
        _rom = nx_rom_view(self, ^(NSString *xci) {
            NxViewController *s = ws;
            [s->_rom removeFromSuperview];
            s->_rom = nil;
            [s next];
        });
        _rom.frame = self.view.bounds;
        [self.view addSubview:_rom];
        return;
    }
    if (want) {
        [self say:[want isEqualToString:@"xci"] ? @"Choose the game's .xci file (tap to open the Files picker)."
                                                 : @"Choose prod.keys (tap to open the Files picker)."];
        _picking = want;
        UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:NO];
        p.delegate = self;
        p.allowsMultipleSelection = NO;
        [self presentViewController:p animated:YES completion:nil];
        return;
    }
    [_label removeFromSuperview];
    _label = nil;
    _started = 1;
    if (!nx_launcher_enabled() || nx_launcher_take_autostart()) { [self startGame]; return; }
    __weak NxViewController *ws = self;
    UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spin.color = UIColor.whiteColor, spin.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
    [spin startAnimating];
    [self.view addSubview:spin];   // first launch: the game's UI assets are decoded from the .xci (~1-2 s), then cached
    nx_launcher_show(self, NO, ^{ [ws startGame]; }, nil, ^{
        NxViewController *s = ws;
        nx_rom_forget();
        s->_launcher = nil, s->_started = 0;
        [s next];
    }, ^(UIView *v) {
        [spin removeFromSuperview];
        NxViewController *s = ws;
        if (!s) return;
        s->_launcher = v;
        v.frame = s.view.bounds;
        [s.view addSubview:v];
    });
}
- (void)say:(NSString *)text {
    if (!_label) {
        _label = [UILabel new];
        _label.textColor = UIColor.whiteColor;
        _label.numberOfLines = 0;
        _label.textAlignment = NSTextAlignmentCenter;
        _label.userInteractionEnabled = YES;
        [_label addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(next)]];
        [self.view addSubview:_label];
    }
    _label.frame = CGRectInset(self.view.bounds, 40, 40);
    _label.text = text;
}
- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject;
    if (u && [u startAccessingSecurityScopedResource]) {
        NSData *b = [u bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
        if (b) [NSUserDefaults.standardUserDefaults setObject:b forKey:_picking];
        setenv([_picking isEqualToString:@"xci"] ? "NXRT_XCI" : "NXRT_KEYS", u.path.fileSystemRepresentation, 1);
        nx_log("ios: picked %s: %s", _picking.UTF8String, u.path.UTF8String);
    }
    [self next];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)picker {
    // stays on the message; tapping it opens the picker again
}
// FPS counter (Settings): presents per second over the last 0.5 s, in a glass pill (26 pt high, radius 13, 13 pt
// semibold monospaced digits, 10 pt side padding).
- (void)fpsCounter {
    _fps = [UIView new];
    _fps.userInteractionEnabled = NO;
    UIVisualEffectView *g = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    g.layer.cornerRadius = 13, g.clipsToBounds = YES;
    g.layer.borderWidth = 0.5, g.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor;
    g.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIView *tint = [UIView new];
    tint.autoresizingMask = g.autoresizingMask;
    tint.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x1C / 255.0 green:0x1C / 255.0 blue:0x1E / 255.0 alpha:0.6]
                                                                 : [UIColor colorWithWhite:1 alpha:0.65];
    }];
    [g.contentView addSubview:tint];
    _fpsLabel = [UILabel new];
    _fpsLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
    _fpsLabel.textColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithWhite:1 alpha:0.9]
                                                                 : [UIColor colorWithRed:0x1C / 255.0 green:0x1C / 255.0 blue:0x1E / 255.0 alpha:1];
    }];
    _fpsLabel.text = @"-- fps";
    _fpsLabel.textAlignment = NSTextAlignmentCenter;
    _fps.bounds = CGRectMake(0, 0, 66, 26);
    g.frame = _fps.bounds, _fpsLabel.frame = _fps.bounds;
    _fpsLabel.autoresizingMask = g.autoresizingMask;
    [_fps addSubview:g], [_fps addSubview:_fpsLabel];
    [self.view addSubview:_fps];
    extern volatile int g_gfx_frame;
    __block int last = g_gfx_frame;
    __block uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        int f = g_gfx_frame;
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        double fps = (f - last) * 1e9 / (double)(now - t0);
        last = f, t0 = now;
        self->_fpsLabel.text = [NSString stringWithFormat:@"%.0f fps", fps];
    }];
}
// NXRT_UITEST_PRESS=Back@<frame>[,...]: tap the floating Back button once the game reaches the frame (the simulator
// has no touch injection; this runs the button's own UIKit actions).
- (void)uitestPresses {
    const char *e = getenv("NXRT_UITEST_PRESS");
    if (!e) return;
    extern volatile int g_gfx_frame;
    for (NSString *item in [@(e) componentsSeparatedByString:@","]) {
        NSArray *p = [item componentsSeparatedByString:@"@"];
        if (p.count != 2 || !([p[0] isEqualToString:@"Back"] || [p[0] isEqualToString:@"Islands"])) continue;
        BOOL islands = [p[0] isEqualToString:@"Islands"];
        int frame = [p[1] intValue];
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
            if (g_gfx_frame < frame) return;
            [t invalidate];
            nx_log("ios: uitest: %s at frame %d", islands ? "Islands" : "Back", g_gfx_frame);
            [islands ? self->_islands : self->_back sendActionsForControlEvents:UIControlEventTouchUpInside];
        }];
    }
}
- (void)startGame {
    display_defaults();
    _started = 2;
    [self.view setNeedsLayout];
    if (_launcher) [self.view bringSubviewToFront:_launcher];   // fades out over the booting game
    if (nx_launcher_enabled() && nx_launcher_fps_counter()) [self fpsCounter];
    [self uitestPresses];
    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) { [self pollBack]; }];
    gfx_init();
    CAMetalLayer *layer = (CAMetalLayer *)_game.layer;
    layer.device = g_dev;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.drawableSize = CGSizeMake(1920, 1080);   // the game's size; present resizes it to the window texture
    gfx_attach_layer(layer);
    log_device(g_dev);
    haptics_start();   // the game's vibration on the Taptic Engine
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 8 << 20);
    pthread_t t;
    if (pthread_create(&t, &attr, guest_thread, NULL)) nx_fatal("ios: guest thread");
}
- (BOOL)prefersStatusBarHidden {
    return YES;
}
- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeAll;
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

// Touch: raw fingers (up to two, numbered in landing order) in game coordinates (nx_game_width() x 720) to the gesture engine
// (ui_touch.c). Touches outside the game view (the black bars) are ignored.
- (void)send:(int)type touch:(UITouch *)t id:(int)i {
    CGSize s = _game.bounds.size;
    if (s.width <= 0 || s.height <= 0) return;
    CGPoint p = [t locationInView:_game];
    nx_ui_touch2(type, i, (float)(p.x / s.width * nx_game_width()), (float)(p.y / s.height * 720));
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:_game];
        if (!CGRectContainsPoint(_game.bounds, p)) continue;
        int i = !_t[0] ? 0 : !_t[1] ? 1 : -1;
        if (i < 0) continue;   // a third finger: ignored
        _t[i] = t;
        [self send:0 touch:t id:i];
    }
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (int i = 0; i < 2; i++)
        if (_t[i] && [touches containsObject:_t[i]]) [self send:1 touch:_t[i] id:i];
}
- (void)fingers:(NSSet<UITouch *> *)touches type:(int)type {
    for (int i = 0; i < 2; i++)
        if (_t[i] && [touches containsObject:_t[i]]) [self send:type touch:_t[i] id:i], _t[i] = nil;
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self fingers:touches type:2];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self fingers:touches type:3];
}
// The app leaving the foreground: every finger is cancelled (no button left held, no glide).
- (void)cancelFingers {
    for (int i = 0; i < 2; i++)
        if (_t[i]) nx_ui_touch2(3, i, 0, 0), _t[i] = nil;
}
@end

// Game controller -> Player 1 (bits as in nn::hid::NpadButton; Nintendo layout: A is the right face button).
static void poll_controller(GCExtendedGamepad *g) {
    if (!g) return;
    uint64_t b = 0;
    b |= g.buttonB.pressed ? 1ull << 0 : 0;   // east -> A
    b |= g.buttonA.pressed ? 1ull << 1 : 0;   // south -> B
    b |= g.buttonY.pressed ? 1ull << 2 : 0;   // north -> X
    b |= g.buttonX.pressed ? 1ull << 3 : 0;   // west -> Y
    b |= g.leftShoulder.pressed ? 1ull << 6 : 0;
    b |= g.rightShoulder.pressed ? 1ull << 7 : 0;
    b |= g.leftTrigger.pressed ? 1ull << 8 : 0;
    b |= g.rightTrigger.pressed ? 1ull << 9 : 0;
    b |= g.buttonMenu.pressed ? 1ull << 10 : 0;
    b |= g.buttonOptions.pressed ? 1ull << 11 : 0;
    b |= g.dpad.left.pressed ? 1ull << 12 : 0;
    b |= g.dpad.up.pressed ? 1ull << 13 : 0;
    b |= g.dpad.right.pressed ? 1ull << 14 : 0;
    b |= g.dpad.down.pressed ? 1ull << 15 : 0;
    g_pad_stick[0] = (int)(g.leftThumbstick.xAxis.value * 32767), g_pad_stick[1] = (int)(g.leftThumbstick.yAxis.value * 32767);
    g_pad_buttons = b;
    send_stick();
}

// The window lives in a scene (Info.plist UIApplicationSceneManifest): apps built with the iOS 27 SDK trap at launch
// without the scene life cycle (UIApplicationEvaluateRuntimeIssueForNoSceneLife).
@interface NxSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(strong, nonatomic) UIWindow *window;
@end
@implementation NxSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)opts {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [NxViewController new];
    [self.window makeKeyAndVisible];
}
// iOS rejects command buffers from the background (that ended the run with a GPU error): the render thread waits
// in commit/present while the scene is inactive (also covers Control Center / the app switcher, before backgrounding).
- (void)sceneWillResignActive:(UIScene *)scene {
    g_gfx_background = 1;
    [(NxViewController *)self.window.rootViewController cancelFingers];
}
- (void)sceneDidEnterBackground:(UIScene *)scene { nx_session_end(); }   // backgrounded: whatever happens next isn't a crash of ours
- (void)sceneWillEnterForeground:(UIScene *)scene { nx_session_resume(); }
- (void)sceneDidBecomeActive:(UIScene *)scene { g_gfx_background = ((NxViewController *)self.window.rootViewController).paused; }
@end

@interface NxAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation NxAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    setup_paths();
    // Controllers: read the current one on every change (connect, buttons, sticks).
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *n) {
        GCController *c = n.object;
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *e) { poll_controller(g); };
        nx_log("ios: controller connected: %s", c.vendorName.UTF8String ?: "?");
    }];
    for (GCController *c in GCController.controllers)
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *e) { poll_controller(g); };
    return YES;
}
@end

void nx_ios_main(int argc, char **argv, void (*guest_main)(void)) {
    g_guest_main = guest_main;
    @autoreleasepool {
        UIApplicationMain(argc, argv, nil, NSStringFromClass(NxAppDelegate.class));
    }
}
