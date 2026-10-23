// Prelauncher (Mac), the native AppKit twin of ios/launcher_ios.m: the same screens, game assets (logo, clouds, pill
// buttons, squiggle pattern, Seurat font and menu sounds read from the user's .xci by nx_assets.m and cached in
// ~/Library/Caches/nx-ui), time-of-day colours and music, save slots and settings, with the same layout
// numbers in the launcher's logical points (NxCanvas scales them to the window). See launcher_ios.m for the visual spec.
//   - ROM screen: choose the .xci (Open panel, or drop it on the window), or use the one found next to the game; prod.keys
//     from NXRT_KEYS / ~/.switch/prod.keys, else chosen here too. The choice is remembered (nx.xciPath / nx.keysPath).
//   - Island select: three save slots in the working folder (data, data-slot2, data-slot3), right-click = Rename /
//     Delete; arrows pick a slot, Return starts, Cmd+, opens Settings.
//   - Settings: a sheet (graphics mode, widescreen, FPS counter, sound, islands, keyboard, Remove ROM).
//   - Over the paused title screen (app_mac.m "Islands"): the same island with the same settings resumes; anything else
//     restarts the game process straight into that island (the iPhone has to be reopened by hand).
// The choices go into the environment before the game starts (the shell's own NXRT_* values still win: setenv without
// overwrite). NXRT_LAUNCHER=0: no launcher (the old straight start; also the case with NXRT_HEADLESS). Test hooks as on
// iOS: NXRT_LAUNCHER_SHOW=settings, NXRT_LAUNCHER_AUTOSTART=<s>, NXRT_LAUNCHER_HOUR=<h>, NXRT_LAUNCHER_MUSIC=0.
#import <AVFoundation/AVFoundation.h>
#import <CoreText/CoreText.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdlib.h>
#import "ui_mac.h"
#include "nxrt.h"
#import "../save_import.h"

uint8_t *nx_asset_file(const char *name, size_t *n);
const uint8_t *nx_sarc_file(const uint8_t *b, size_t n, const char *name, size_t *size);
CGImageRef nx_bntx_image(const uint8_t *b, size_t n, const char *name);
uint8_t *nx_font_decrypt(const uint8_t *f, size_t n, size_t *out_n);
int nx_content_try(const char *xci_path, const char *keys_path);
uint8_t *nx_romfs_file(const char *fname, uint64_t *size);
NSData *nx_bars_wav(const uint8_t *b, size_t n, const char *name);
NSView *nx_game_dialog(NSString *title, NSString *body, NSString *main, NSString *second, NSView *host, void (^done)(BOOL main));
NxPressable *nx_game_button(int style, NSString *title, NSImage *icon);
void nx_mac_relaunch(void);   // app_mac.m

#define rgb nx_rgb
#define navy NX_NAVY
#define orange() NX_ORANGE

static NSString *const kSlot = @"nx.slot", *const kMode = @"nx.mode", *const kWide = @"nx.wide", *const kFps = @"nx.fps",
                      *const kSound = @"nx.sound", *const kUnmounted = @"nx.romUnmounted", *const kAutostart = @"nx.autostart",
                      *const kXci = @"nx.xciPath", *const kKeys = @"nx.keysPath", *const kFps60 = @"nx.fps60", *const kFull = @"nx.fullscreen";
void nx_mac_set_fullscreen(int on);   // app_mac.m

int nx_launcher_enabled(void) {
    const char *e = getenv("NXRT_LAUNCHER");
    return (!e || atoi(e) != 0) && !getenv("NXRT_HEADLESS");
}
static NSUserDefaults *ud(void) {
    NSUserDefaults *u = NSUserDefaults.standardUserDefaults;
    [u registerDefaults:@{kSlot : @1, kMode : @"quality", kWide : @YES, kFps : @NO, kSound : @YES, kUnmounted : @NO, kAutostart : @0,
                          kFps60 : @NO, kFull : @YES}];
    return u;
}
int nx_launcher_fps_counter(void) { return [ud() boolForKey:kFps]; }
int nx_launcher_wide(void) { return [ud() boolForKey:kWide]; }
int nx_launcher_fullscreen(void) { return [ud() boolForKey:kFull]; }
static NSString *slot_dir(int slot) { return slot == 1 ? @"data" : [NSString stringWithFormat:@"data-slot%d", slot]; }
static NSString *slot_title(int slot) {
    NSString *n = [ud() stringForKey:[NSString stringWithFormat:@"nx.slotname.%d", slot]];
    return n.length ? n : [NSString stringWithFormat:@"Island %d", slot];
}
// What needs a fresh start when it changes (the FPS counter doesn't).
static NSString *settings_key(int slot) {
    NSUserDefaults *u = ud();
    return [NSString stringWithFormat:@"%d|%@|%d|%d|%d", slot, [u stringForKey:kMode], [u boolForKey:kWide], [u boolForKey:kSound],
            [u boolForKey:kFps60]];
}

// The saved choices -> environment (cwd = the game's working folder). Doesn't overwrite what the shell set.
static void apply_settings(int slot) {
    NSUserDefaults *u = ud();
    NSString *dir = slot_dir(slot);
    [NSFileManager.defaultManager createDirectoryAtPath:[dir stringByAppendingPathComponent:@"save"] withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("NXRT_DATA", dir.fileSystemRepresentation, 0);
    setenv("NXRT_MODE", [u stringForKey:kMode].UTF8String, 0);
    if (![u boolForKey:kWide]) setenv("NXRT_WIDE", "1280", 0);
    if (![u boolForKey:kSound]) setenv("NXRT_AUDIO", "0", 0);
    if ([u boolForKey:kFps60]) setenv("NXRT_FPS", "60", 0);   // the game drops to 30 by itself when a frame doesn't fit
    nx_log("launcher: slot %d (%s), mode %s, widescreen %s, fps counter %s, sound %s", slot, getenv("NXRT_DATA"), getenv("NXRT_MODE"),
           [u boolForKey:kWide] ? "on" : "off", [u boolForKey:kFps] ? "on" : "off", [u boolForKey:kSound] ? "on" : "off");
}
// An island chosen from the title screen that needed a fresh start: start it straight away (slot, or 0).
int nx_launcher_take_autostart(void) {
    int slot = (int)[ud() integerForKey:kAutostart];
    if (slot < 1 || slot > 3) return 0;
    [ud() setInteger:0 forKey:kAutostart];
    apply_settings(slot);
    return slot;
}

// ---- paths -------------------------------------------------------------------------------------------------------
static BOOL is_file(NSString *p) {
    BOOL dir = NO;
    return p.length && [NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&dir] && !dir;
}
static NSString *absolute(NSString *p) {
    return p.isAbsolutePath ? p.stringByStandardizingPath
                            : [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:p].stringByStandardizingPath;
}
// An .xci next to the game: the repo's own (the old default path), then the working folder and its parent.
static NSString *nearby_xci(void) {
    if (is_file(@"../Tomodachi Life Living the Dream.xci")) return absolute(@"../Tomodachi Life Living the Dream.xci");
    for (NSString *dir in @[@".", @".."])
        for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil])
            if ([f.pathExtension.lowercaseString isEqualToString:@"xci"]) return absolute([dir stringByAppendingPathComponent:f]);
    return nil;
}
static NSString *default_keys(void) {
    NSString *k = [NSHomeDirectory() stringByAppendingPathComponent:@".switch/prod.keys"];
    return is_file(k) ? k : nil;
}
// NXRT_XCI / NXRT_KEYS from the shell, else the remembered choices, else the defaults (before the window shows).
void nx_launcher_paths(void) {
    NSUserDefaults *u = ud();
    if (!getenv("NXRT_KEYS")) {
        NSString *k = is_file([u stringForKey:kKeys]) ? [u stringForKey:kKeys] : default_keys();
        if (k) setenv("NXRT_KEYS", k.fileSystemRepresentation, 1);
    }
    if (getenv("NXRT_XCI") || [u boolForKey:kUnmounted]) return;   // Remove ROM: ask again (ROM screen)
    NSString *x = is_file([u stringForKey:kXci]) ? [u stringForKey:kXci] : nil;
    if (x) setenv("NXRT_XCI", x.fileSystemRepresentation, 1);
}

// ---- time of day -----------------------------------------------------------------------------------------------
// The launcher follows the local time: background colour (keyframes below, blended) and music (the parts of the day).
static double day_hour(void) {
    const char *e = getenv("NXRT_LAUNCHER_HOUR");
    if (e) return fmod(atof(e), 24);
    NSDateComponents *c = [NSCalendar.currentCalendar components:NSCalendarUnitHour | NSCalendarUnitMinute fromDate:NSDate.date];
    return c.hour + c.minute / 60.0;
}
static NSString *day_period(void) {
    double h = day_hour();
    return h < 5 ? @"latenight" : h < 10 ? @"morning" : h < 12 ? @"latemorning" : h < 16 ? @"afternoon" : h < 18 ? @"lateafternoon"
         : h < 21 ? @"evening" : @"night";
}
// Dawn peach, the game's yellow (morning, to 11:00), sky blue (13:00-16:30), sunset, dusk violet, night indigo.
static NSColor *day_color(void) {
    static const struct { double h; uint32_t c; } k[] = {{4.5, 0x2B3570}, {5.5, 0xFFB98A}, {8, 0xFFC100}, {11, 0xFFC100}, {13, 0x6EC6F0},
                                                       {16.5, 0x6EC6F0}, {18.5, 0xFF8A3D}, {20, 0x6E5BC4}, {22, 0x2B3570}, {28.5, 0x2B3570}};
    const int nk = sizeof k / sizeof *k;
    double h = day_hour();
    if (h < 4.5) h += 24;
    int i = 0;
    while (i < nk - 2 && h >= k[i + 1].h) i++;
    double t = (h - k[i].h) / (k[i + 1].h - k[i].h);
    uint32_t a = k[i].c, b = k[i + 1].c;
    CGFloat ch[3];
    for (int j = 0; j < 3; j++) ch[j] = (((a >> (16 - 8 * j)) & 255) * (1 - t) + ((b >> (16 - 8 * j)) & 255) * t) / 255;
    return [NSColor colorWithSRGBRed:ch[0] green:ch[1] blue:ch[2] alpha:1];
}
static void components(NSColor *c, CGFloat *r, CGFloat *g, CGFloat *b) {
    NSColor *s = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    *r = s.redComponent, *g = s.greenComponent, *b = s.blueComponent;
}
static BOOL is_dark(NSColor *c) {
    CGFloat r, g, b;
    components(c, &r, &g, &b);
    return 0.299 * r + 0.587 * g + 0.114 * b < 0.55;
}
// The squiggles: the base 18% of the way to white (#FFC100 -> #FFCC2E, the game's own pair); 9% on dark colours.
static NSColor *pattern_color(NSColor *base) {
    CGFloat r, g, b, k = is_dark(base) ? 0.09 : 0.18;
    components(base, &r, &g, &b);
    return [NSColor colorWithSRGBRed:r + (1 - r) * k green:g + (1 - g) * k blue:b + (1 - b) * k alpha:1];
}

// ---- launcher music ------------------------------------------------------------------------------------------------
// As on iOS: music/launcher_<period>_*.m4a shuffled (2 s fade in, 0.8 s out on Start, 3 s cross-fade when the part of
// the day changes). Folder: NXRT_MUSIC, else ./music, else the repo's ../ios/music. Settings > Sound off or
// NXRT_LAUNCHER_MUSIC=0: silent.
@interface NxMusic : NSObject <AVAudioPlayerDelegate>
@end
static AVAudioPlayer *g_music;
static NSString *g_music_mode;
static NSArray<NSString *> *g_playlist;
static NSUInteger g_track;
static NxMusic *g_music_delegate;
static const float kMusicVolume = 0.7f;
static NSString *music_dir(void) {
    if (getenv("NXRT_MUSIC")) return @(getenv("NXRT_MUSIC"));
    BOOL d = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:@"music" isDirectory:&d] && d) return @"music";
    return @"../ios/music";
}
static BOOL audio_off(void) {   // NXRT_AUDIO=0: the game, the music and the menu sounds are all silent
    const char *a = getenv("NXRT_AUDIO");
    return a && atoi(a) == 0;
}
static BOOL music_on(void) {
    const char *e = getenv("NXRT_LAUNCHER_MUSIC");
    return (!e || atoi(e) != 0) && [ud() boolForKey:kSound] && !audio_off();
}
static void music_fade_out(AVAudioPlayer *p, NSTimeInterval t) {
    if (!p) return;
    [p setVolume:0 fadeDuration:t];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((t + 0.05) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [p stop]; });
}
static void music_play(NSString *file, BOOL loop, NSTimeInterval fade) {
    NSURL *u = [NSURL fileURLWithPath:[music_dir() stringByAppendingPathComponent:file]];
    AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithContentsOfURL:u error:nil];
    if (!p) { nx_log("launcher: music %s missing", file.UTF8String); return; }
    if (!g_music_delegate) g_music_delegate = [NxMusic new];
    p.delegate = g_music_delegate;
    p.numberOfLoops = loop ? -1 : 0;
    p.volume = 0;
    [p play];
    [p setVolume:kMusicVolume fadeDuration:fade];
    nx_log("launcher: music %s (%.0f s, fade in %.1f s)", file.UTF8String, p.duration, fade);
    music_fade_out(g_music, fade);
    g_music = p;
}
static NSArray<NSString *> *music_tracks(NSString *period) {
    NSArray *all = [NSFileManager.defaultManager contentsOfDirectoryAtPath:music_dir() error:nil];
    NSMutableArray *mine = [NSMutableArray array], *any = [NSMutableArray array];
    NSString *old = @{@"latenight" : @"launcher_1.m4a", @"night" : @"launcher_1.m4a", @"evening" : @"launcher_3.m4a"}[period] ?: @"launcher_2.m4a";
    for (NSString *f in all) {
        if (![f hasPrefix:@"launcher_"] || ![f.pathExtension.lowercaseString isEqualToString:@"m4a"]) continue;
        [any addObject:f];
        if ([f hasPrefix:[NSString stringWithFormat:@"launcher_%@_", period]]) [mine addObject:f];
    }
    if (!mine.count && [any containsObject:old]) [mine addObject:old];
    if (!mine.count) mine = any;
    for (NSUInteger i = mine.count; i > 1; i--) [mine exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
    return mine;
}
static void music_launcher(NSTimeInterval fade) {
    NSString *mode = [@"launcher-" stringByAppendingString:day_period()];
    if (!music_on() || [g_music_mode isEqual:mode]) return;
    g_playlist = music_tracks(day_period()), g_track = 0;
    if (!g_playlist.count) return;
    g_music_mode = mode;
    music_play(g_playlist[g_track % g_playlist.count], g_playlist.count == 1, fade);
}
static void music_follow_time(void) {
    if ([g_music_mode hasPrefix:@"launcher"]) music_launcher(3.0);
}
static void music_stop(NSTimeInterval fade) {
    music_fade_out(g_music, fade);
    g_music = nil, g_music_mode = nil;
}
@implementation NxMusic
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)p successfully:(BOOL)ok {
    if (p != g_music || ![g_music_mode hasPrefix:@"launcher"] || !g_playlist.count) return;
    g_track++;
    music_play(g_playlist[g_track % g_playlist.count], NO, 0.5);
}
@end

// ---- menu sounds -------------------------------------------------------------------------------------------------
static NSString *cache_dir(void);
static void sfx(NSString *name) {
    static NSMutableDictionary<NSString *, AVAudioPlayer *> *players;
    if (![ud() boolForKey:kSound] || audio_off()) return;
    if (!players) players = [NSMutableDictionary dictionary];
    AVAudioPlayer *p = players[name];
    if (!p) {
        p = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:[cache_dir() stringByAppendingFormat:@"/sfx_%@.wav", name]] error:nil];
        if (!p) return;
        [p prepareToPlay];
        players[name] = p;
    }
    p.currentTime = 0;
    [p play];
}

typedef struct { int files; NSDate *newest; unsigned long long bytes; } SlotInfo;
static SlotInfo slot_info(int slot) {
    SlotInfo si = {0, nil, 0};
    NSDirectoryEnumerator *en = [NSFileManager.defaultManager enumeratorAtPath:[slot_dir(slot) stringByAppendingPathComponent:@"save"]];
    for (NSString *f in en) {
        NSDictionary *a = en.fileAttributes;
        if (![a.fileType isEqualToString:NSFileTypeRegular]) continue;
        si.files++, si.bytes += a.fileSize;
        if (!si.newest || [a.fileModificationDate compare:si.newest] == NSOrderedDescending) si.newest = a.fileModificationDate;
        (void)f;
    }
    return si;
}
// Residents: Mii.sav key 0x2499BFDA = the 70 Mii names (u32 count, then 0x40-byte UTF-16 names; empty = free).
static int slot_residents(int slot) {
    NSFileHandle *f = [NSFileHandle fileHandleForReadingAtPath:[slot_dir(slot) stringByAppendingPathComponent:@"save/Mii.sav"]];
    NSData *hd = [f readDataUpToLength:0x4000 error:nil];
    const uint8_t *h = hd.bytes;
    if (hd.length < 0x20) return -1;
    uint32_t end = MIN(*(const uint32_t *)(h + 8), (uint32_t)hd.length), off = 0;
    for (uint32_t k = 0x20; k + 8 <= end && !off; k += 8)
        if (*(const uint32_t *)(h + k) == 0x2499BFDA) off = *(const uint32_t *)(h + k + 4);
    if (!off || ![f seekToOffset:off error:nil]) return -1;
    NSData *d = [f readDataUpToLength:4 + 100 * 0x40 error:nil];
    const uint8_t *p = d.bytes;
    if (d.length < 4) return -1;
    uint32_t n = MIN(*(const uint32_t *)p, (uint32_t)((d.length - 4) / 0x40)), count = 0;
    for (uint32_t i = 0; i < n; i++) count += p[4 + i * 0x40] || p[5 + i * 0x40];
    return (int)count;
}
// The island's last picture (gfx_metal.m writes it every 15 s of play).
static NSImage *slot_snapshot(int slot) {
    NSString *p = [slot_dir(slot) stringByAppendingPathComponent:@"snapshot.jpg"];
    return is_file(p) ? [[NSImage alloc] initWithContentsOfFile:p] : nil;
}

// ---- the game's assets -----------------------------------------------------------------------------------------
@interface NxUI : NSObject
@property(nonatomic, readonly) NSImage *logo, *pattern, *cloud, *pill, *circle;
@property(nonatomic, readonly) BOOL ready;
+ (instancetype)shared;
- (BOOL)loadForXci:(NSString *)xci keys:(NSString *)keys;   // background thread
- (void)forget;
- (NSFont *)font:(CGFloat)size bold:(BOOL)bold;
@end
@implementation NxUI {
    NSString *_eb, *_b;
}
+ (instancetype)shared {
    static NxUI *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NxUI new]; });
    return s;
}
static NSString *cache_dir(void) {
    NSString *c = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [c stringByAppendingPathComponent:@"nx-ui"];
}
static BOOL cache_texture(NSString *dir, const char *archive, const char *tex, NSString *out) {
    size_t n, bn;
    uint8_t *a = nx_asset_file(archive, &n);
    const uint8_t *bntx = a ? nx_sarc_file(a, n, "timg/__Combined.bntx", &bn) : NULL;
    CGImageRef img = bntx ? nx_bntx_image(bntx, bn, tex) : NULL;
    free(a);
    if (!img) { nx_log("launcher: asset %s / %s missing", archive, tex); return NO; }
    NSData *png = [[[NSBitmapImageRep alloc] initWithCGImage:img] representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    CGImageRelease(img);
    return [png writeToFile:[dir stringByAppendingPathComponent:out] atomically:YES];
}
static NSString *register_font(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return nil;
    CTFontDescriptorRef fd = CTFontManagerCreateFontDescriptorFromData((__bridge CFDataRef)d);
    if (!fd) return nil;
    CTFontRef f = CTFontCreateWithFontDescriptor(fd, 12, NULL);
    NSString *name = CFBridgingRelease(CTFontCopyPostScriptName(f));
    CTFontManagerRegisterFontsForURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], kCTFontManagerScopeProcess, NULL);   // fails harmlessly when already registered
    CFRelease(f), CFRelease(fd);
    return name;
}
- (BOOL)loadForXci:(NSString *)xci keys:(NSString *)keys {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = cache_dir(), *stampf = [dir stringByAppendingPathComponent:@"stamp"];
    unsigned long long size = [[fm attributesOfItemAtPath:xci error:nil] fileSize];
    NSString *stamp = [NSString stringWithFormat:@"v3 %@ %llu", xci.lastPathComponent, size];
    if (![[NSString stringWithContentsOfFile:stampf encoding:NSUTF8StringEncoding error:nil] isEqualToString:stamp]) {
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        [fm removeItemAtPath:dir error:nil];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        if (nx_content_try(xci.fileSystemRepresentation, keys.fileSystemRepresentation)) return NO;
        BOOL ok = cache_texture(dir, "Common_Title_00.Nin_NX_NVN.blarc.zs", "Title_WW_LogoS^w", @"logo.png") &&
                  cache_texture(dir, "Common_MenuBGPa_00.Nin_NX_NVN.blarc.zs", "CmnFacePartsBG_00^r", @"pattern.png") &&
                  cache_texture(dir, "Common_DialogBase_00.Nin_NX_NVN.blarc.zs", "DialogCloud_00^s", @"cloud.png") &&
                  cache_texture(dir, "Button_Main_00.Nin_NX_NVN.blarc.zs", "BtnMain_00^s", @"pill.png") &&
                  cache_texture(dir, "Button_Toggle_00.Nin_NX_NVN.blarc.zs", "ToggleBtn_00^s", @"circle.png");
        // game_ui_mac.m's buttons and dialog. Missing ones fall back to plain shapes.
        static const char *ui_tex[][3] = {
            {"Button_Dialog_00", "BtnDialog_00^s", "btn_dialog"},  {"Button_Dialog_00", "RoughLine_00^r", "roughline"},
            {"Button_LclNwkRoom_00", "BtnMainL_00^s", "btn_long"}, {"Button_LclNwkRoom_00", "LclNwk_IconRoom^s", "icon_room"},
        };
        for (size_t i = 0; i < sizeof ui_tex / sizeof *ui_tex; i++)
            cache_texture(dir, [NSString stringWithFormat:@"%s.Nin_NX_NVN.blarc.zs", ui_tex[i][0]].UTF8String, ui_tex[i][1],
                          [@(ui_tex[i][2]) stringByAppendingString:@".png"]);
        size_t n, fn, fsz;
        uint8_t *arc = nx_asset_file("Font.Nin_NX_NVN.bfarc.zs", &n);
        const char *fonts[2][2] = {{"scft/ninP_SeuratCapie-EB_003.bfotf", "SeuratEB.otf"}, {"scft/ninP_SeuratCapie-B_003.bfotf", "SeuratB.otf"}};
        for (int i = 0; i < 2 && arc; i++) {
            const uint8_t *f = nx_sarc_file(arc, n, fonts[i][0], &fsz);
            uint8_t *otf = f ? nx_font_decrypt(f, fsz, &fn) : NULL;
            ok = ok && otf && [[NSData dataWithBytesNoCopy:otf length:fn freeWhenDone:YES]
                                   writeToFile:[dir stringByAppendingPathComponent:@(fonts[i][1])] atomically:YES];
        }
        free(arc);
        uint8_t *bars = nx_asset_file("System_Static.Product.100.bars.zs", &n);
        const char *sfx[][2] = {{"SE_UI_Cursor", "sfx_tap"}, {"SE_UI_Decide2", "sfx_start"}, {"SE_UI_Open_", "sfx_open"}, {"SE_UI_CloseSoft", "sfx_close"}};
        for (int i = 0; i < 4 && bars; i++)
            [nx_bars_wav(bars, n, sfx[i][0]) writeToFile:[dir stringByAppendingFormat:@"/%s.wav", sfx[i][1]] atomically:YES];
        free(bars);
        if (!ok) return NO;
        [stamp writeToFile:stampf atomically:YES encoding:NSUTF8StringEncoding error:nil];
        nx_log("launcher: game UI assets cached in %.2f s", CFAbsoluteTimeGetCurrent() - t0);
    }
    _logo = nx_png([dir stringByAppendingPathComponent:@"logo.png"], 3);
    _pattern = nx_png([dir stringByAppendingPathComponent:@"pattern.png"], 768 / 240.0);
    _cloud = nx_png([dir stringByAppendingPathComponent:@"cloud.png"], 3);
    _pill = nx_png([dir stringByAppendingPathComponent:@"pill.png"], 3);
    _circle = nx_png([dir stringByAppendingPathComponent:@"circle.png"], 3);
    _eb = register_font([dir stringByAppendingPathComponent:@"SeuratEB.otf"]);
    _b = register_font([dir stringByAppendingPathComponent:@"SeuratB.otf"]);
    _ready = _logo && _pattern && _cloud && _pill && _circle && _eb && _b;
    nx_log("launcher: game UI assets %s (fonts %s, %s)", _ready ? "ready" : "INCOMPLETE", _eb.UTF8String ?: "-", _b.UTF8String ?: "-");
    return _ready;
}
- (void)forget {
    [NSFileManager.defaultManager removeItemAtPath:cache_dir() error:nil];
    _ready = NO, _logo = _pattern = _cloud = _pill = _circle = nil;
}
- (NSFont *)font:(CGFloat)size bold:(BOOL)bold {
    NSFont *f = _ready ? [NSFont fontWithName:bold ? _eb : _b size:size] : nil;
    if (f) return f;
    NSFont *sys = [NSFont systemFontOfSize:size weight:bold ? NSFontWeightHeavy : NSFontWeightSemibold];
    NSFontDescriptor *rd = [sys.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded];
    return rd ? [NSFont fontWithDescriptor:rd size:size] : sys;
}
@end
// For game_ui_mac.m and app_mac.m: the cached game textures (3 px per point), the game's font, the background.
NSImage *nx_ui_texture(NSString *name) { return nx_png([[cache_dir() stringByAppendingPathComponent:name] stringByAppendingString:@".png"], 3); }
NSFont *nx_ui_font(CGFloat size, BOOL bold) { return [NxUI.shared font:size bold:bold]; }
NSImage *nx_ui_cloud(void) { return NxUI.shared.cloud; }
BOOL nx_ui_background_dark(void) { return is_dark(day_color()); }
// The time of day's colour with the squiggle pattern, tiled from the top left (240 pt tiles).
void nx_ui_draw_background(NSRect r) {
    NSColor *base = day_color();
    [base setFill];
    NSRectFill(r);
    NSImage *p = NxUI.shared.pattern;
    if (!p) return;
    NSImage *t = nx_tinted(p, pattern_color(base));
    for (CGFloat y = 0; y < NSMaxY(r); y += p.size.height)
        for (CGFloat x = 0; x < NSMaxX(r); x += p.size.width) [t drawInRect:NSMakeRect(x, y, p.size.width, p.size.height) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
}

// ---- Deleting / leaving an island ------------------------------------------------------------------------------
// Settings > Islands and the card's right-click: empty a slot, confirmed twice. The folder is moved aside
// (data-deleted-<time>-slotN), never removed.
static void slot_empty(int slot) {
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *to = [NSString stringWithFormat:@"data-deleted-%@-slot%d", [df stringFromDate:NSDate.date], slot];
    NSError *err = nil;
    BOOL ok = [NSFileManager.defaultManager moveItemAtPath:slot_dir(slot) toPath:to error:&err];
    if (ok) [ud() removeObjectForKey:[NSString stringWithFormat:@"nx.slotname.%d", slot]];
    nx_log("launcher: slot %d moved to %s: %s", slot, to.UTF8String, ok ? "ok" : err.localizedDescription.UTF8String);
}
static void island_remove_flow(NSWindow *host, int slot, void (^done)(void)) {
    NSString *name = slot_title(slot);
    void (^confirm)(NSString *, NSString *, NSString *, void (^)(void)) = ^(NSString *t, NSString *m, NSString *btn, void (^yes)(void)) {
        nx_alert(host, t, m, @[btn, @"Cancel"], 0, ^(NSInteger b) { if (b == 0) yes(); });
    };
    void (^empty)(void) = ^{ slot_empty(slot); done(); };
    confirm([NSString stringWithFormat:@"Delete %@?", name],
            @"Its save leaves this slot. A backup copy stays in the game's folder.", @"Delete", ^{
        confirm(@"Are you sure?", [NSString stringWithFormat:@"%@ and all its residents will be gone from the island select.", name],
                @"Delete Island", empty);
    });
}

// ---- Settings (a sheet) -----------------------------------------------------------------------------------------
// The iOS inset-grouped table in the game's palette: #FFF2CA, white rounded groups, Seurat B 17 labels, #F2660D toggles
// and segments. Plain Mac points (it is its own window).
@interface NxToggle : NxPressable
@property(nonatomic) BOOL on;
@property(nonatomic, copy) void (^changed)(BOOL on);
@end
@implementation NxToggle {
    NxView *_knob;
}
- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:NSMakeRect(0, 0, 44, 26)];
    self.pressScale = 1;
    self.layer.cornerRadius = 13;
    _knob = [NxView new];
    _knob.layer.backgroundColor = NSColor.whiteColor.CGColor, _knob.layer.cornerRadius = 11;
    _knob.layer.shadowColor = NSColor.blackColor.CGColor, _knob.layer.shadowOpacity = 0.2f, _knob.layer.shadowRadius = 2;
    _knob.layer.shadowOffset = CGSizeMake(0, -1);
    [self addSubview:_knob];
    __weak NxToggle *ws = self;
    self.onTap = ^{ NxToggle *s = ws; s.on = !s.on; if (s.changed) s.changed(s.on); };
    [self show:NO];
    return self;
}
- (void)setOn:(BOOL)on { _on = on; [self show:YES]; }
- (void)show:(BOOL)animated {
    NSRect k = NSMakeRect(_on ? 20 : 2, 2, 22, 22);
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) {
        c.duration = animated ? 0.15 : 0;
        c.allowsImplicitAnimation = YES;
        self->_knob.animator.frame = k;
        self.layer.backgroundColor = (self->_on ? NX_ORANGE : [NSColor colorWithWhite:0.82 alpha:1]).CGColor;
    }];
}
@end

@interface NxSettingsSheet : NSWindow
@property(nonatomic, copy) void (^removeRom)(void);
@property(nonatomic, copy) void (^islandsChanged)(void);
@property(nonatomic) int runningSlot;   // the paused game's slot (can't be removed), 0 = none
- (void)reload;
@end
@interface NxSettingsRow : NxPressable   // a row: label (+ detail) on the left, an accessory on the right
@end
@implementation NxSettingsRow
- (void)resetCursorRects { if (self.onTap) [super resetCursorRects]; }
@end
@implementation NxSettingsSheet {
    NSScrollView *_scroll;
    NxView *_doc;
}
- (instancetype)init {
    self = [super initWithContentRect:NSMakeRect(0, 0, 540, 620) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView
                              backing:NSBackingStoreBuffered defer:NO];
    self.titlebarAppearsTransparent = YES, self.titleVisibility = NSWindowTitleHidden;
    self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];   // the game's palette, also in dark mode
    NxView *root = [NxView new];
    root.layer.backgroundColor = rgb(0xFFF2CA, 1).CGColor;
    self.contentView = root;
    NxLabel *title = [NxLabel text:@"Settings" font:[NxUI.shared font:19 bold:YES] color:navy(1)];
    title.frame = NSMakeRect(0, 12, 540, 30);
    NSButton *done = [NSButton buttonWithTitle:@"Done" target:self action:@selector(done)];
    done.bordered = NO, done.keyEquivalent = @"\r";
    done.focusRingType = NSFocusRingTypeNone, done.refusesFirstResponder = YES;
    done.attributedTitle = [[NSAttributedString alloc] initWithString:@"Done"
        attributes:@{NSFontAttributeName : [NxUI.shared font:17 bold:YES], NSForegroundColorAttributeName : orange()}];
    done.frame = NSMakeRect(540 - 20 - 70, 12, 70, 30);
    _scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 52, 540, 620 - 52)];
    _scroll.drawsBackground = NO, _scroll.hasVerticalScroller = YES, _scroll.autohidesScrollers = YES;
    _doc = [NxView new];
    _scroll.documentView = _doc;
    [root addSubview:title], [root addSubview:done], [root addSubview:_scroll];
    return self;
}
- (void)cancelOperation:(id)sender { [self done]; }
- (void)done {
    sfx(@"close");
    [self.sheetParent endSheet:self];
}
- (NSArray<NSNumber *> *)islandSlots {
    NSMutableArray *a = [NSMutableArray array];
    for (int slot = 1; slot <= 3; slot++)
        if (slot_info(slot).files) [a addObject:@(slot)];
    return a;
}
static NxLabel *value_label(NSString *text, NSColor *color) {
    NxLabel *v = [NxLabel text:text font:[NxUI.shared font:17 bold:YES] color:color];
    v.alignment = NSTextAlignmentRight;
    return v;
}
- (NxSettingsRow *)row:(NSString *)text detail:(NSString *)detail color:(NSColor *)color accessory:(NSView *)acc tap:(void (^)(void))tap {
    NxSettingsRow *r = [NxSettingsRow new];
    r.pressScale = 1;
    r.onTap = tap;
    NxLabel *l = [NxLabel text:text font:[NxUI.shared font:17 bold:NO] color:color ?: navy(1)];
    l.alignment = NSTextAlignmentLeft, l.minScale = 0.7;
    l.identifier = @"label";
    [r addSubview:l];
    if (detail) {
        NxLabel *d = [NxLabel text:detail font:[NxUI.shared font:13 bold:NO] color:navy(0.55)];
        d.alignment = NSTextAlignmentLeft, d.identifier = @"detail";
        [r addSubview:d];
    }
    if (acc) acc.identifier = @"acc", [r addSubview:acc];
    return r;
}
// Sections: rows + header + footer, stacked top to bottom.
- (void)reload {
    for (NSView *v in [_doc.subviews copy]) [v removeFromSuperview];
    NSUserDefaults *u = ud();
    __weak NxSettingsSheet *ws = self;
    NSMutableArray *sections = [NSMutableArray array];   // @[header, rows, footer]

    NSView *(^toggle)(NSString *) = ^NSView *(NSString *key) {
        NxToggle *t = [NxToggle new];
        t.on = [u boolForKey:key];
        t.changed = ^(BOOL on) { [ws toggle:key on:on]; };
        return t;
    };
    NSSegmentedControl *seg = [NSSegmentedControl segmentedControlWithLabels:@[@"Quality", @"Performance"] trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                      target:self action:@selector(mode:)];
    seg.selectedSegment = [[u stringForKey:kMode] isEqualToString:@"performance"] ? 1 : 0;
    seg.selectedSegmentBezelColor = orange();
    [seg sizeToFit];
    [sections addObject:@[@"Graphics", @[[self row:@"Mode" detail:nil color:nil accessory:seg tap:nil],
                                          [self row:@"60 fps" detail:nil color:nil accessory:toggle(kFps60) tap:nil]],
                          (@"Quality: rendered at 1080p, sharpened to your screen's resolution. Performance: the game's own 720p, "
                          @"sharpened the same way; less work per frame. 60 fps falls back to 30 by itself when a scene is too heavy.")]];
    [sections addObject:@[@"Display", @[[self row:@"Full screen" detail:nil color:nil accessory:toggle(kFull) tap:nil],
                                         [self row:@"Fill the screen" detail:nil color:nil accessory:toggle(kWide) tap:nil],
                                         [self row:@"FPS counter" detail:nil color:nil accessory:toggle(kFps) tap:nil]],
                          (@"Full screen also turns on macOS Game Mode. Fill the screen gives the picture the window's shape when an "
                          @"island starts: wider or taller than 16:9, showing more of the island instead of black bars.")]];
    [sections addObject:@[@"Sound", @[[self row:@"Sound" detail:nil color:nil accessory:toggle(kSound) tap:nil]],
                          @"Settings apply when an island starts."]];
    [sections addObject:@[@"Online", @[[self row:@"Shared islands, Local Play" detail:nil color:nil
                                               accessory:value_label(@"Coming soon", navy(0.45)) tap:nil]],
                          @"Sharing an island with a friend and online Local Play will come in a later update."]];
    NSMutableArray *islands = [NSMutableArray array];
    for (NSNumber *s in self.islandSlots) {
        int slot = s.intValue;
        BOOL running = slot == _runningSlot;
        NSString *detail = [NSString stringWithFormat:@"Slot %d%@", slot, running ? @" · Playing now" : @""];
        [islands addObject:[self row:slot_title(slot) detail:detail color:nil
                           accessory:value_label(@"Delete", running ? navy(0.3) : rgb(0xFF2E00, 1))
                                 tap:^{ [ws removeSlot:slot]; }]];
    }
    if (!islands.count) [islands addObject:[self row:@"No saved islands" detail:nil color:navy(0.45) accessory:nil tap:nil]];
    [islands addObject:[self row:@"Import a save…" detail:nil color:orange() accessory:nil tap:^{ [ws importSave]; }]];
    [sections addObject:@[@"Islands", islands, (@"Import takes a save from an emulator (Ryujinx, yuzu and forks, Checkpoint, JKSV): its folder "
                                                @"or a .zip. The island it replaces is kept in the game's folder. Deleting asks twice.")]];
    [sections addObject:@[@"Controls", @[[self row:@"Click anything · drag to move around · right-click = Back" detail:
                                                   @"Pinch or scroll wheel = zoom · two-finger scroll = move · rotate = turn" color:navy(0.75) accessory:nil tap:nil],
                                          [self row:@"Keys: K J I U = A B X Y · arrows · WASD = stick" detail:
                                                   @"Q E = L R · 1 3 = ZL ZR · Return = + · Tab = − · Esc = Back" color:navy(0.75) accessory:nil tap:nil]],
                          @"A game controller works too."]];
    if (_removeRom) {
        NSString *xci = getenv("NXRT_XCI") ? @(getenv("NXRT_XCI")).lastPathComponent : @"";
        [sections addObject:@[@"Game", @[[self row:[NSString stringWithFormat:@"Remove ROM (%@)", xci] detail:nil color:rgb(0xFF2E00, 1)
                                          accessory:nil tap:^{ [ws askRemoveRom]; }]],
                              @"Removing the ROM only forgets it here; the file itself stays where it is."]];
    }
    // layout
    CGFloat W = 540, side = 20, y = 4;
    for (NSArray *sec in sections) {
        NxLabel *h = [NxLabel text:sec[0] font:[NxUI.shared font:14 bold:YES] color:navy(0.55)];
        h.alignment = NSTextAlignmentLeft;
        h.frame = NSMakeRect(side + 16, y + 10, W - 2 * side - 32, 20), y += 34;
        [_doc addSubview:h];
        NxView *group = [NxView new];
        group.layer.backgroundColor = NSColor.whiteColor.CGColor, group.layer.cornerRadius = 10;
        NSArray<NxSettingsRow *> *rows = sec[1];
        CGFloat gy = 0;
        for (NSUInteger i = 0; i < rows.count; i++) {
            NxSettingsRow *r = rows[i];
            BOOL two = [r.subviews indexOfObjectPassingTest:^BOOL(NSView *v, NSUInteger k, BOOL *s) { return [v.identifier isEqual:@"detail"]; }] != NSNotFound;
            CGFloat rh = two ? 58 : 46, rw = W - 2 * side;
            r.frame = NSMakeRect(0, gy, rw, rh);
            CGFloat accw = 0;
            for (NSView *v in r.subviews) {
                if ([v.identifier isEqual:@"acc"]) {
                    NSSize s = [v isKindOfClass:NxLabel.class] ? [(NxLabel *)v sizeThatFits:NSMakeSize(300, 30)] : v.frame.size;
                    accw = s.width;
                    v.frame = NSMakeRect(rw - 16 - s.width, (rh - s.height) / 2, s.width, s.height);
                }
            }
            for (NSView *v in r.subviews) {
                if ([v.identifier isEqual:@"label"]) v.frame = NSMakeRect(16, two ? 8 : 0, rw - 32 - accw - (accw ? 12 : 0), two ? 24 : rh);
                if ([v.identifier isEqual:@"detail"]) v.frame = NSMakeRect(16, 32, rw - 32 - accw - (accw ? 12 : 0), 18);
            }
            [group addSubview:r];
            if (i + 1 < rows.count) {
                NxView *line = [NxView new];
                line.layer.backgroundColor = navy(0.12).CGColor;
                line.frame = NSMakeRect(16, gy + rh - 0.5, rw - 16, 0.5);
                [group addSubview:line];
            }
            gy += rh;
        }
        group.frame = NSMakeRect(side, y, W - 2 * side, gy), y += gy;
        [_doc addSubview:group];
        NxLabel *f = [NxLabel text:sec[2] font:[NSFont systemFontOfSize:12] color:navy(0.55)];
        f.alignment = NSTextAlignmentLeft, f.lines = 0;
        CGFloat fh = [f sizeThatFits:CGSizeMake(W - 2 * side - 32, 200)].height;
        f.frame = NSMakeRect(side + 16, y + 6, W - 2 * side - 32, fh), y += fh + 14;
        [_doc addSubview:f];
    }
    _doc.frame = NSMakeRect(0, 0, W, y + 16);
}
- (void)mode:(NSSegmentedControl *)seg {
    [ud() setObject:seg.selectedSegment == 1 ? @"performance" : @"quality" forKey:kMode];
}
- (void)toggle:(NSString *)key on:(BOOL)on {
    [ud() setBool:on forKey:key];
    if ([key isEqual:kFull]) nx_mac_set_fullscreen(on);
    if ([key isEqual:kSound]) {   // the launcher's music follows Sound at once
        if (on) music_launcher(1.0);
        else music_stop(0.5);
    }
}
- (void)removeSlot:(int)slot {
    if (slot == _runningSlot) {
        nx_alert_ok(self, @"This island is open", @"Pick another island and Start it first, then delete this one.");
        return;
    }
    __weak NxSettingsSheet *ws = self;
    island_remove_flow(self, slot, ^{
        [ws reload];
        if (ws.islandsChanged) ws.islandsChanged();
    });
}
// Settings > Islands > Import a save: a folder or .zip from an emulator, into an island (the old save is kept aside).
- (void)importSave {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.message = @"Choose the save folder (or a .zip of it) from your emulator or a Checkpoint / JKSV backup";
    p.canChooseDirectories = YES;
    p.canChooseFiles = YES;
    p.allowedContentTypes = @[UTTypeFolder, UTTypeZIP];
    p.allowsMultipleSelection = NO;
    [p beginSheetModalForWindow:self completionHandler:^(NSModalResponse r) {
        if (r == NSModalResponseOK && p.URL) [self importSaveFrom:p.URL.path];
    }];
}
- (void)importSaveFrom:(NSString *)src {
    NSMutableArray *buttons = [NSMutableArray array];
    for (int slot = 1; slot <= 3; slot++)
        [buttons addObject:[NSString stringWithFormat:@"%@%@", slot_title(slot), slot_info(slot).files ? @" (replaces it)" : @" (empty)"]];
    [buttons addObject:@"Cancel"];
    nx_alert(self, @"Import into which island?", @"The save currently in that island is kept in the game's folder.", buttons, -1, ^(NSInteger b) {
        if (b < 0 || b > 2) return;
        int slot = (int)b + 1;
        if (slot == self->_runningSlot) {
            nx_alert_ok(self, @"This island is open", @"Pick another island and Start it first, then import into this one.");
            return;
        }
        int n = 0;
        NSString *why = nx_save_import(src, slot_dir(slot), &n);
        nx_log("launcher: import save %s -> slot %d: %s", src.lastPathComponent.UTF8String, slot, why ? why.UTF8String : "ok");
        if (why) { nx_alert_ok(self, @"Couldn't import", why); return; }
        [self reload];
        if (self.islandsChanged) self.islandsChanged();
        nx_alert_ok(self, @"Save imported", [NSString stringWithFormat:@"%@ now has your save (%d files).", slot_title(slot), n]);
    });
}
- (void)askRemoveRom {
    void (^rm)(void) = _removeRom;
    nx_alert(self, @"Remove the ROM?", @"The game forgets this .xci and asks for one again. Your islands stay.", @[@"Remove", @"Cancel"], 0,
             ^(NSInteger b) {
        if (b != 0) return;
        [self.sheetParent endSheet:self];
        rm();
    });
}
@end

// ---- ROM screen ------------------------------------------------------------------------------------------------
// Forgets the ROM (the path, the cached UI assets); the next launch asks again.
void nx_rom_forget(void) {
    [ud() removeObjectForKey:kXci];
    [ud() setBool:YES forKey:kUnmounted];
    unsetenv("NXRT_XCI");
    [NxUI.shared forget];
    nx_log("launcher: ROM removed");
}
static NSFont *rounded(CGFloat size, NSFontWeight w) {
    NSFont *sys = [NSFont systemFontOfSize:size weight:w];
    NSFontDescriptor *rd = [sys.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded];
    return rd ? [NSFont fontWithDescriptor:rd size:size] : sys;
}
// The iOS ROM screen (#FFC100, white card, "Choose .xci file"), plus: drop an .xci (or prod.keys) anywhere on it, the
// .xci found next to the game as a one-click choice, and prod.keys chosen here when it isn't in ~/.switch.
@interface NxRomView : NxView
- (instancetype)initWithDone:(void (^)(NSString *xci))done;
@end
@implementation NxRomView {
    void (^_done)(NSString *);
    NxView *_card;
    NxLabel *_title, *_body, *_error;
    NxPressable *_choose, *_local, *_keys;
    NxLabel *_chooseLabel, *_localLabel, *_keysLabel;
    NSProgressIndicator *_spin;
    NSString *_localXci;
    BOOL _busy;
}
- (instancetype)initWithDone:(void (^)(NSString *))done {
    self = [super initWithFrame:NSZeroRect];
    _done = done;
    self.layer.backgroundColor = rgb(0xFFC100, 1).CGColor;
    [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    _card = [NxView new];
    _card.layer.backgroundColor = [NSColor colorWithWhite:1 alpha:0.92].CGColor;
    _card.layer.cornerRadius = 30, _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.layer.borderColor = orange().CGColor;
    _card.layer.shadowColor = NSColor.blackColor.CGColor, _card.layer.shadowOpacity = 0.12f, _card.layer.shadowRadius = 20;
    _card.layer.shadowOffset = CGSizeMake(0, -8);
    [self addSubview:_card];
    _title = [NxLabel text:@"Add your Tomodachi Life ROM" font:rounded(26, NSFontWeightHeavy) color:navy(1)];
    _title.minScale = 0.6;
    _body = [NxLabel text:@"Choose your Tomodachi Life: Living the Dream .xci file, or drop it here. It stays where it is on this Mac."
                     font:[NSFont systemFontOfSize:16] color:navy(0.7)];
    _body.lines = 0;
    _error = [NxLabel text:@"" font:[NSFont systemFontOfSize:14 weight:NSFontWeightMedium] color:rgb(0xFF2E00, 1)];
    _error.lines = 0;
    __weak NxRomView *ws = self;
    _choose = [NxPressable new];
    _choose.layer.backgroundColor = navy(1).CGColor, _choose.layer.cornerRadius = 26, _choose.layer.cornerCurve = kCACornerCurveContinuous;
    _chooseLabel = [NxLabel text:@"Choose .xci file" font:[NSFont systemFontOfSize:18 weight:NSFontWeightSemibold] color:NSColor.whiteColor];
    [_choose addSubview:_chooseLabel];
    _choose.onTap = ^{ [ws pick]; };
    _localXci = nearby_xci();
    _local = [NxPressable new], _local.pressScale = 0.97;
    _localLabel = [NxLabel text:_localXci ? [NSString stringWithFormat:@"Use %@ from %@", _localXci.lastPathComponent,
                                             [_localXci.stringByDeletingLastPathComponent.lastPathComponent isEqual:@""] ? @"/" : _localXci.stringByDeletingLastPathComponent.lastPathComponent] : @""
                           font:[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold] color:orange()];
    _localLabel.minScale = 0.7;
    [_local addSubview:_localLabel];
    _local.onTap = ^{ NxRomView *s = ws; if (s) [s check:s->_localXci]; };
    _local.hidden = !_localXci;
    _keys = [NxPressable new], _keys.pressScale = 0.97;
    _keysLabel = [NxLabel text:@"Choose prod.keys…" font:[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold] color:orange()];
    [_keys addSubview:_keysLabel];
    _keys.onTap = ^{ [ws pickKeys]; };
    _keys.hidden = getenv("NXRT_KEYS") != NULL;
    _spin = [NSProgressIndicator new];
    _spin.style = NSProgressIndicatorStyleSpinning, _spin.controlSize = NSControlSizeSmall, _spin.displayedWhenStopped = NO;
    for (NSView *v in @[_title, _body, _error, _choose, _local, _keys, _spin]) [_card addSubview:v];
    if (getenv("NXRT_LAUNCHER_ROMAUTO") && _localXci)   // test hook: use the .xci next to the game after 2 s
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ NxRomView *s = ws; [s check:s ? s->_localXci : nil]; });
    return self;
}
- (void)layout {
    [super layout];
    CGRect b = self.bounds;
    CGFloat w = MIN(460, b.size.width - 48), inner = w - 60, y = 30;
    _title.frame = CGRectMake(30, y, inner, 32), y += 42;
    CGSize bs = [_body sizeThatFits:CGSizeMake(inner, 200)];
    _body.frame = CGRectMake(30, y, inner, bs.height), y += bs.height + 22;
    _choose.frame = CGRectMake((w - 280) / 2, y, 280, 52), y += 52;
    _chooseLabel.frame = _choose.bounds;
    _spin.frame = CGRectMake(w - 30 - 24, CGRectGetMidY(_choose.frame) - 8, 16, 16);
    if (!_local.hidden) _local.frame = CGRectMake(30, y + 10, inner, 30), _localLabel.frame = _local.bounds, y += 40;
    if (!_keys.hidden) _keys.frame = CGRectMake(30, y + (_local.hidden ? 10 : 0), inner, 30), _keysLabel.frame = _keys.bounds, y += _local.hidden ? 40 : 30;
    if (_error.text.length) {
        CGSize es = [_error sizeThatFits:CGSizeMake(inner, 200)];
        _error.frame = CGRectMake(30, y + 12, inner, es.height), y += es.height + 12;
    }
    y += 30;
    _card.frame = CGRectMake((b.size.width - w) / 2, (b.size.height - y) / 2, w, y);
}
- (void)pick {
    if (_busy) return;
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.message = @"Choose your Tomodachi Life: Living the Dream .xci file";
    p.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"xci"] ?: UTTypeData];
    p.allowsMultipleSelection = NO;
    [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r == NSModalResponseOK && p.URL) [self check:p.URL.path];
    }];
}
- (void)pickKeys {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.message = @"Choose prod.keys (the keys dumped from your Switch)";
    p.allowsMultipleSelection = NO;
    [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r == NSModalResponseOK && p.URL) [self useKeys:p.URL.path];
    }];
}
- (void)useKeys:(NSString *)path {
    [ud() setObject:path forKey:kKeys];
    setenv("NXRT_KEYS", path.fileSystemRepresentation, 1);
    nx_log("launcher: keys %s", path.UTF8String);
    _keys.hidden = YES;
    _error.text = @"";
    self.needsLayout = YES;
}
- (void)fail:(NSString *)msg {
    _busy = NO;
    _error.text = msg;
    [_spin stopAnimation:nil];
    _choose.enabled = YES;
    self.needsLayout = YES;
}
// The file must be an .xci the runtime can open, holding the game's title layout.
- (void)check:(NSString *)path {
    if (!path || _busy) return;
    if (![path.pathExtension.lowercaseString isEqualToString:@"xci"]) { [self fail:@"That isn't an .xci file."]; return; }
    _busy = YES;
    _error.text = @"";
    _choose.enabled = NO;
    [_spin startAnimation:nil];
    self.needsLayout = YES;
    const char *keys = getenv("NXRT_KEYS");
    NSString *k = keys ? @(keys) : nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ok = NO;
        if (k && !nx_content_try(path.fileSystemRepresentation, k.fileSystemRepresentation)) {
            uint64_t sz;
            uint8_t *t = nx_romfs_file("Common_Title_00.Nin_NX_NVN.blarc.zs", &sz);
            ok = t != NULL;
            free(t);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) {
                [self fail:k ? @"That file isn't Tomodachi Life: Living the Dream (or it couldn't be read)."
                             : @"prod.keys is missing: put it in ~/.switch, or choose it below."];
                self->_keys.hidden = k != nil;
                return;
            }
            [ud() setObject:path forKey:kXci];
            [ud() setBool:NO forKey:kUnmounted];
            setenv("NXRT_XCI", path.fileSystemRepresentation, 1);
            nx_log("launcher: ROM added: %s", path.UTF8String);
            self->_busy = NO;
            [self->_spin stopAnimation:nil];
            self->_done(path);
        });
    });
}
// Drag and drop: an .xci is checked, prod.keys (any .keys) is taken.
static NSString *dropped(id<NSDraggingInfo> info) {
    NSURL *u = [NSURL URLFromPasteboard:info.draggingPasteboard];
    NSString *e = u.pathExtension.lowercaseString;
    return u.isFileURL && ([e isEqual:@"xci"] || [e isEqual:@"keys"]) ? u.path : nil;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
    if (!dropped(info) || _busy) return NSDragOperationNone;
    _card.layer.borderWidth = 4;
    return NSDragOperationCopy;
}
- (void)draggingExited:(id<NSDraggingInfo>)info { _card.layer.borderWidth = 0; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    _card.layer.borderWidth = 0;
    NSString *p = dropped(info);
    if (!p) return NO;
    if ([p.pathExtension.lowercaseString isEqual:@"keys"]) [self useKeys:p];
    else [self check:p];
    return YES;
}
@end
NSView *nx_rom_view(void (^done)(NSString *xci)) { return [[NxRomView alloc] initWithDone:done]; }

// ---- Slot card --------------------------------------------------------------------------------------------------
// A cream cloud. With a snapshot: the picture fills the cloud (cloud-shaped, 6 pt in) and a cream tag on the lower edge
// carries the name and residents. Without one: name, last played, residents in text.
// A new slot: an orange plus and "New island".
@interface NxSlotCard : NxPressable
@property(nonatomic) int slot;
@property(nonatomic) BOOL chosen;
- (void)refresh;
- (void)squash;
@end
@implementation NxSlotCard {
    NxView *_body;
    NxImageView *_ring, *_cloud, *_photo;
    NxLabel *_name, *_status, *_size, *_plus;
    NxView *_tag;
    NxLabel *_tagText;
}
- (instancetype)initWithSlot:(int)slot {
    self = [super initWithFrame:NSZeroRect];
    _slot = slot;
    self.pressScale = 1;
    NxUI *ui = NxUI.shared;
    _body = [NxView new];
    [self addSubview:_body];
    _ring = [NxImageView new], _cloud = [NxImageView new], _photo = [NxImageView new];
    _ring.image = nx_tinted(ui.cloud, orange());
    _cloud.image = nx_tinted(ui.cloud, rgb(0xFFF2CA, 1));
    if (!ui.cloud) _cloud.layer.backgroundColor = rgb(0xFFF2CA, 1).CGColor, _cloud.layer.cornerRadius = 40,
                   _ring.layer.backgroundColor = orange().CGColor, _ring.layer.cornerRadius = 46;
    _ring.alphaValue = 0;
    _cloud.layer.shadowColor = NSColor.blackColor.CGColor, _cloud.layer.shadowOpacity = 0.16f, _cloud.layer.shadowRadius = 10;
    _cloud.layer.shadowOffset = CGSizeMake(0, -5);
    _photo.fill = YES, _photo.mask = ui.cloud;
    [_body addSubview:_ring], [_body addSubview:_cloud], [_body addSubview:_photo];
    _name = [NxLabel text:@"" font:[ui font:17 bold:YES] color:navy(1)];
    _status = [NxLabel text:@"" font:[ui font:12 bold:NO] color:navy(0.75)];
    _size = [NxLabel text:@"" font:[ui font:11 bold:NO] color:navy(0.5)];
    _plus = [NxLabel text:@"+" font:[ui font:28 bold:YES] color:orange()];
    for (NxLabel *l in @[_name, _status, _size, _plus]) l.minScale = 0.5, [_body addSubview:l];
    _tag = [NxView new];
    _tag.layer.backgroundColor = rgb(0xFFF2CA, 0.95).CGColor, _tag.layer.cornerRadius = 12;
    _tag.layer.shadowColor = NSColor.blackColor.CGColor, _tag.layer.shadowOpacity = 0.12f, _tag.layer.shadowRadius = 4;
    _tag.layer.shadowOffset = CGSizeMake(0, -2);
    _tagText = [NxLabel new];
    _tagText.minScale = 0.7;
    [_tag addSubview:_tagText];
    [_body addSubview:_tag];
    self.accessibilityRole = NSAccessibilityButtonRole;
    [self refresh];
    return self;
}
- (void)refresh {
    SlotInfo si = slot_info(_slot);
    int residents = si.files ? slot_residents(_slot) : -1;
    NSString *res = residents == 0 ? @"No residents yet" : residents == 1 ? @"1 resident"
                  : residents > 1 ? [NSString stringWithFormat:@"%d residents", residents] : nil;
    NSImage *snap = si.files ? slot_snapshot(_slot) : nil;
    _name.text = slot_title(_slot);
    if (si.files) {
        NSDateFormatter *df = [NSDateFormatter new];
        df.doesRelativeDateFormatting = YES, df.dateStyle = NSDateFormatterMediumStyle, df.timeStyle = NSDateFormatterShortStyle;
        _status.text = [@"Played " stringByAppendingString:[df stringFromDate:si.newest]];
        _status.textColor = navy(0.75);
        _size.text = res ?: [NSByteCountFormatter stringFromByteCount:(long long)si.bytes countStyle:NSByteCountFormatterCountStyleFile];
    } else {
        _status.text = @"New island", _status.textColor = orange(), _size.text = @"";
    }
    [_status.layer removeAnimationForKey:@"pulse"];
    _photo.image = snap;
    _photo.hidden = !snap, _tag.hidden = !snap;
    _plus.hidden = si.files != 0;
    _status.hidden = _size.hidden = snap != nil;
    _name.hidden = snap || !_plus.hidden;
    if (snap) {
        NSMutableAttributedString *t = [[NSMutableAttributedString alloc] initWithString:_name.text
            attributes:@{NSFontAttributeName : [NxUI.shared font:15 bold:YES], NSForegroundColorAttributeName : navy(1)}];
        if (res) [t appendAttributedString:[[NSAttributedString alloc] initWithString:[@" · " stringByAppendingString:res]
            attributes:@{NSFontAttributeName : [NxUI.shared font:12 bold:NO], NSForegroundColorAttributeName : navy(0.6)}]];
        _tagText.attributedText = t;
    }
    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@%@", _name.text, _status.text, res ? [@", " stringByAppendingString:res] : @""];
    self.needsLayout = YES;
}
- (void)setChosen:(BOOL)chosen {
    BOOL was = _chosen;
    _chosen = chosen;
    nx_fade(_ring, chosen ? 1 : 0, 0.2, nil);
    self.accessibilitySelected = chosen;
    if (chosen && !was) {   // the chosen cloud floats: 0 -> 4 pt up, 1.6 s each way
        CABasicAnimation *bob = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
        bob.fromValue = @0, bob.toValue = @(_body.layer.contentsAreFlipped ? -4 : 4), bob.duration = 1.6, bob.autoreverses = YES;
        bob.repeatCount = HUGE_VALF, bob.additive = YES, bob.removedOnCompletion = NO;
        bob.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_body.layer addAnimation:bob forKey:@"bob"];
    } else if (!chosen && was) {
        [_body.layer removeAnimationForKey:@"bob"];
    }
}
// A click: squash to (1.06, 0.94) in 0.08 s, spring back.
- (void)squash {
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform"];
    a.fromValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    a.toValue = [NSValue valueWithCATransform3D:nx_center_scale(self, 1.06, 0.94)];
    a.duration = 0.08, a.additive = YES;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    CASpringAnimation *s = [CASpringAnimation animationWithKeyPath:@"transform"];
    s.fromValue = a.toValue, s.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    s.additive = YES, s.damping = 9, s.stiffness = 300, s.mass = 1, s.duration = s.settlingDuration;
    s.beginTime = CACurrentMediaTime() + 0.08;
    [self.layer addAnimation:a forKey:@"squash"];
    [self.layer addAnimation:s forKey:@"squash2"];
}
- (void)layout {
    [super layout];
    CGRect b = self.bounds;
    _body.frame = b;
    _cloud.frame = b;
    _ring.frame = CGRectInset(b, -6, -6);
    _photo.frame = CGRectInset(b, 6, 6);
    CGFloat w = b.size.width - 40, cy = b.size.height / 2;
    _name.frame = CGRectMake(20, cy - 30, w, 22);
    _status.frame = CGRectMake(20, cy - 5, w, 16);
    _size.frame = CGRectMake(20, cy + 12, w, 14);
    if (!_plus.hidden) _plus.frame = CGRectMake(20, cy - 40, w, 30), _status.frame = CGRectMake(20, cy - 6, w, 16);
    CGFloat tw = MIN(b.size.width + 10, [_tagText sizeThatFits:CGSizeMake(400, 24)].width + 24);
    _tag.frame = CGRectMake((b.size.width - tw) / 2, b.size.height - 14, tw, 24);
    _tagText.frame = CGRectInset(_tag.bounds, 10, 0);
}
@end

// ---- Launcher ---------------------------------------------------------------------------------------------------
@interface NxLauncherView : NxView
@end
@implementation NxLauncherView {
    void (^_start)(void), (^_resume)(void), (^_removeRom)(void);
    NSString *_running;   // resume mode: settings_key of the running game
    NxImageView *_logo;
    NxPressable *_gear, *_go;
    NxLabel *_goLabel, *_time, *_date;
    NSView *_bg;                          // layer-hosting: colour, drifting squiggle tiles, night sparkles
    CALayer *_drift, *_tile, *_stars;
    NSColor *_shown;
    CGSize _starSize;
    CGFloat _tilePx;                      // pixels per point the tile was drawn at
    BOOL _appeared;
    NxPressable *_join, *_share;          // online play: "Coming soon" for now
    NSArray<NxSlotCard *> *_cards;
    int _slot;
    NSTimer *_timer;
}
- (instancetype)initRunning:(NSString *)running start:(void (^)(void))start resume:(void (^)(void))resume removeRom:(void (^)(void))removeRom {
    self = [super initWithFrame:NSZeroRect];
    _start = start, _resume = resume, _removeRom = removeRom, _running = running;
    self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    NxUI *ui = NxUI.shared;
    _slot = (int)[ud() integerForKey:kSlot];
    if (_slot < 1 || _slot > 3) _slot = 1;
    [self setupBackground];
    _logo = [NxImageView new];
    _logo.image = ui.logo, _logo.fit = YES;
    [self addSubview:_logo];
    __weak NxLauncherView *ws = self;
    _gear = [NxPressable new];
    // The circle texture is 70x78 px with the circle in its top 52x52 (the rest is shadow room): scale that part to the button.
    NxImageView *ring = [NxImageView new];
    ring.image = nx_tinted(ui.circle, NSColor.whiteColor);
    if (!ui.circle) ring.layer.backgroundColor = NSColor.whiteColor.CGColor, ring.layer.cornerRadius = 24;
    ring.frame = ui.circle ? CGRectMake(-9 * 48 / 52.0, -9 * 48 / 52.0, 70 * 48 / 52.0, 78 * 48 / 52.0) : CGRectMake(0, 0, 48, 48);
    NxImageView *gear = [NxImageView new];
    gear.image = nx_tinted(nx_symbol(@"gearshape.fill", 20, NSFontWeightBold), navy(1)), gear.fit = YES;
    gear.frame = CGRectMake(13, 13, 22, 22);
    [_gear addSubview:ring], [_gear addSubview:gear];
    _gear.accessibilityLabel = @"Settings";
    _gear.onTap = ^{ [ws settings]; };
    [self addSubview:_gear];
    _time = [NxLabel new], _date = [NxLabel new];
    _time.alignment = _date.alignment = NSTextAlignmentRight;
    _date.font = [ui font:15 bold:NO];
    [self addSubview:_time], [self addSubview:_date];
    [self updateClock];
    NSMutableArray *cards = [NSMutableArray array];
    for (int s = 1; s <= 3; s++) {
        NxSlotCard *c = [[NxSlotCard alloc] initWithSlot:s];
        __weak NxSlotCard *wc = c;
        c.onTap = ^{ [ws cardTap:wc]; };
        if (!running) c.onRightClick = ^(NSEvent *e) { [ws menuFor:wc event:e]; };   // not under a running game
        [self addSubview:c];
        [cards addObject:c];
    }
    _cards = cards;
    _go = [NxPressable new];
    NxImageView *pill = [NxImageView new];
    pill.image = nx_tinted(ui.pill, rgb(0xFF2E00, 1));
    if (!ui.pill) _go.layer.backgroundColor = rgb(0xFF2E00, 1).CGColor, _go.layer.cornerRadius = 29;
    pill.identifier = @"pill";
    _go.layer.shadowColor = rgb(0xA31D00, 1).CGColor, _go.layer.shadowOpacity = 0.35f, _go.layer.shadowRadius = 0, _go.layer.shadowOffset = CGSizeMake(0, -4);
    _goLabel = [NxLabel text:@"" font:[ui font:21 bold:YES] color:NSColor.whiteColor];
    _goLabel.minScale = 0.6;
    [_go addSubview:pill], [_go addSubview:_goLabel];
    _go.onDown = ^{ [ws breathe:NO]; };
    _go.onUp = ^{ [ws breathe:YES]; };
    _go.onTap = ^{ [ws go]; };
    [self addSubview:_go];
    if (!running) {
        _join = nx_game_button(2, @"Join a shared island", nx_ui_texture(@"icon_room"));
        _share = nx_game_button(1, @"Share island", nil);
        _join.onTap = _share.onTap = ^{ [ws comingSoon]; };
        [self addSubview:_join], [self addSubview:_share];
    }
    [self choose:_slot];
    const char *show = getenv("NXRT_LAUNCHER_SHOW");
    if (show && !strcmp(show, "settings"))
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ [ws settings]; });
    const char *auto_s = getenv("NXRT_LAUNCHER_AUTOSTART");
    if (auto_s) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(atof(auto_s) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws go]; });
    return self;
}
- (void)layout {
    [super layout];
    CGRect b = self.bounds;
    CGFloat l = 18, r = b.size.width - 18, top = 6, bottom = b.size.height - 8;
    CGFloat lh = 160, lw = lh * 420 / 360;
    _logo.frame = CGRectMake(l, top, lw, lh);
    // Clock top right (time over date), the gear 14 pt to its left
    CGFloat tw = [_time sizeThatFits:CGSizeMake(400, 60)].width, dw = [_date sizeThatFits:CGSizeMake(400, 30)].width, cw0 = MAX(tw, dw);
    _time.frame = CGRectMake(r - cw0, top + 4, cw0, 50);
    _date.frame = CGRectMake(r - cw0, top + 52, cw0, 20);
    _gear.frame = CGRectMake(r - cw0 - 14 - 48, top + 8, 48, 48);
    // Join: centred between the logo and the gear
    CGFloat jx0 = CGRectGetMaxX(_logo.frame) + 12, jx1 = CGRectGetMinX(_gear.frame) - 12, jw = MIN(280, jx1 - jx0);
    _join.frame = CGRectMake((jx0 + jx1 - jw) / 2, top + 14, jw, 44);
    CGFloat goy = bottom - 14 - 58;
    _go.frame = CGRectMake((b.size.width - 250) / 2, goy, 250, 58);
    for (NSView *v in _go.subviews) v.frame = [v.identifier isEqual:@"pill"] ? _go.bounds : CGRectInset(_go.bounds, 24, 0);
    _share.frame = CGRectMake(CGRectGetMaxX(_go.frame) + 14, goy + 4, 170, 50);
    // The saves: a row of small clouds just above the buttons
    CGFloat cw = MIN(170, (r - l - 24) / 3), ch = 112, x0 = (b.size.width - (cw * 3 + 24)) / 2, cy = goy - 18 - ch;
    for (int i = 0; i < 3; i++) _cards[i].frame = CGRectMake(x0 + i * (cw + 12), cy, cw, ch);
    [self layoutBackground];
    if (_go.layer && ![_go.layer animationForKey:@"breathe"]) [self breathe:YES];   // its centre moved: start again
}
// ---- background, clock -----------------------------------------------------------------------------------------
// The time of day's colour; the squiggles (one 240 pt tile, repeated) drift down-right at 12 pt/s (a tile per 20 s);
// from 20:00 to 5:00, 12 sparkles twinkle in the empty areas.
- (CGFloat)pixelsPerPoint {
    CGFloat k = [self.superview isKindOfClass:NxCanvas.class] ? ((NxCanvas *)self.superview).scale : 1;
    return (self.window ? self.window.backingScaleFactor : 2) * k;
}
- (CGImageRef)tileImage:(NSColor *)c CF_RETURNS_RETAINED {
    NSImage *p = NxUI.shared.pattern;
    _tilePx = [self pixelsPerPoint];
    return nx_cgimage(nx_tinted(p, pattern_color(c)), p.size, _tilePx);
}
- (void)setupBackground {
    _shown = day_color();
    _bg = [NSView new];
    CALayer *root = [CALayer new];
    root.geometryFlipped = YES;
    root.backgroundColor = _shown.CGColor;
    _bg.layer = root;   // layer-hosting: these layers are ours
    _bg.wantsLayer = YES;
    _drift = [CALayer new];
    NSImage *p = NxUI.shared.pattern;
    if (p) {
        _tile = [CALayer new];
        _tile.frame = CGRectMake(0, 0, p.size.width, p.size.height);
        CGImageRef t = [self tileImage:_shown];
        _tile.contents = (__bridge id)t;
        CGImageRelease(t);
        CAReplicatorLayer *rx = [CAReplicatorLayer new], *ry = [CAReplicatorLayer new];
        rx.instanceCount = 9, rx.instanceTransform = CATransform3DMakeTranslation(p.size.width, 0, 0);
        ry.instanceCount = 7, ry.instanceTransform = CATransform3DMakeTranslation(0, p.size.height, 0);
        [rx addSublayer:_tile], [ry addSublayer:rx], [_drift addSublayer:ry];
    }
    _stars = [CALayer new];
    [root addSublayer:_drift];
    [root addSublayer:_stars];
    [self addSubview:_bg];
}
- (void)layoutBackground {
    _bg.frame = self.bounds;
    CGSize t = _tile ? _tile.bounds.size : CGSizeMake(240, 240);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _drift.frame = CGRectMake(-t.width, -t.height, t.width * 9, t.height * 7);
    _stars.frame = self.bounds;
    if (_tile && fabs([self pixelsPerPoint] - _tilePx) > 0.25) {   // the window grew: a sharper tile
        CGImageRef img = [self tileImage:_shown];
        _tile.contents = (__bridge id)img;
        CGImageRelease(img);
    }
    [CATransaction commit];
    if (![_drift animationForKey:@"drift"]) {
        CABasicAnimation *d = [CABasicAnimation animationWithKeyPath:@"transform.translation"];
        d.fromValue = [NSValue valueWithSize:CGSizeZero], d.toValue = [NSValue valueWithSize:t];
        d.duration = t.width / 12, d.repeatCount = HUGE_VALF, d.removedOnCompletion = NO;
        d.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [_drift addAnimation:d forKey:@"drift"];
    }
    if (!CGSizeEqualToSize(_starSize, self.bounds.size)) _starSize = self.bounds.size, [self placeStars];
}
// Sparkles at fixed pseudo-random spots that stay clear of the logo, clock, buttons and clouds.
- (void)placeStars {
    for (CALayer *s in [_stars.sublayers copy]) [s removeFromSuperlayer];
    NSMutableArray<NSValue *> *busy = [NSMutableArray array];
    for (NSView *v in @[_logo, _time, _date, _gear, _go]) [busy addObject:[NSValue valueWithRect:CGRectInset(v.frame, -10, -10)]];
    if (_join) [busy addObject:[NSValue valueWithRect:CGRectInset(_join.frame, -10, -10)]];
    if (_share) [busy addObject:[NSValue valueWithRect:CGRectInset(_share.frame, -10, -10)]];
    for (NSView *v in _cards) [busy addObject:[NSValue valueWithRect:CGRectInset(v.frame, -14, -14)]];
    unsigned short seed[3] = {7, 13, 21};
    CGSize sz = self.bounds.size;
    for (int n = 0, tries = 0; n < 12 && tries < 400; tries++) {
        CGPoint c = CGPointMake(erand48(seed) * sz.width, erand48(seed) * sz.height);
        CGFloat rr = 2.5 + 1.5 * erand48(seed);   // 5-8 pt across
        BOOL hit = NO;
        for (NSValue *v in busy) hit |= CGRectContainsPoint(v.rectValue, c);
        if (hit) continue;
        CGMutablePathRef p = CGPathCreateMutable();   // four-point sparkle
        CGPathMoveToPoint(p, NULL, 0, -rr);
        CGPathAddQuadCurveToPoint(p, NULL, 0, 0, rr, 0);
        CGPathAddQuadCurveToPoint(p, NULL, 0, 0, 0, rr);
        CGPathAddQuadCurveToPoint(p, NULL, 0, 0, -rr, 0);
        CGPathAddQuadCurveToPoint(p, NULL, 0, 0, 0, -rr);
        CAShapeLayer *s = [CAShapeLayer new];
        s.path = p, s.fillColor = NSColor.whiteColor.CGColor, s.position = c, s.opacity = 0.15f;
        CGPathRelease(p);
        CABasicAnimation *tw = [CABasicAnimation animationWithKeyPath:@"opacity"];
        tw.fromValue = @0.15, tw.toValue = @0.6, tw.duration = 2 + 2 * erand48(seed), tw.autoreverses = YES, tw.repeatCount = HUGE_VALF;
        tw.timeOffset = erand48(seed) * 4, tw.removedOnCompletion = NO;
        tw.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [s addAnimation:tw forKey:@"twinkle"];
        [_stars addSublayer:s];
        n++;
    }
    double h = day_hour();
    _stars.opacity = h >= 20 || h < 5 ? 1 : 0;
}
static NSDate *launcher_now(void) {
    if (!getenv("NXRT_LAUNCHER_HOUR")) return NSDate.date;
    return [[NSCalendar.currentCalendar startOfDayForDate:NSDate.date] dateByAddingTimeInterval:day_hour() * 3600];
}
- (void)updateClock {
    NSDate *now = launcher_now();
    NSDateFormatter *tf = [NSDateFormatter new], *df = [NSDateFormatter new];
    [tf setLocalizedDateFormatFromTemplate:@"jmm"];
    [df setLocalizedDateFormatFromTemplate:@"EEEEMMMd"];
    BOOL dark = is_dark(_shown);
    NSColor *ink = dark ? NSColor.whiteColor : navy(1);
    NSString *ts = [tf stringFromDate:now];
    NSMutableAttributedString *t = [[NSMutableAttributedString alloc] initWithString:ts
        attributes:@{NSFontAttributeName : [NxUI.shared font:44 bold:YES], NSForegroundColorAttributeName : ink}];
    for (NSString *sym in @[tf.AMSymbol, tf.PMSymbol]) {   // AM / PM smaller
        NSRange rg = [ts rangeOfString:sym];
        if (sym.length && rg.location != NSNotFound) [t addAttribute:NSFontAttributeName value:[NxUI.shared font:20 bold:YES] range:rg];
    }
    _time.attributedText = t;
    _date.text = [df stringFromDate:now];
    _date.textColor = [ink colorWithAlphaComponent:0.75];
    NSShadow *sh = nil;
    if (dark) sh = [NSShadow new], sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.25], sh.shadowBlurRadius = 6, sh.shadowOffset = NSMakeSize(0, -2);
    _time.textShadow = _date.textShadow = sh;
    self.needsLayout = YES;
}
// Every 5 s: the clock; the background colour when it moved (2 s fade), the sparkles, the music's part of the day.
- (void)tick {
    NSColor *c = day_color();
    CGFloat r0, g0, b0, r1, g1, b1;
    components(_shown, &r0, &g0, &b0), components(c, &r1, &g1, &b1);
    if (fabs(r0 - r1) + fabs(g0 - g1) + fabs(b0 - b1) > 1.5 / 255) {
        _shown = c;
        [CATransaction begin];
        [CATransaction setAnimationDuration:2];
        _bg.layer.backgroundColor = c.CGColor;
        if (_tile) {
            CGImageRef img = [self tileImage:c];
            _tile.contents = (__bridge id)img;
            CGImageRelease(img);
        }
        double h = day_hour();
        _stars.opacity = h >= 20 || h < 5 ? 1 : 0;
        [CATransaction commit];
    }
    [self updateClock];
    music_follow_time();
}
// Start breathes: scale 1.0 <-> 1.03, 1.4 s each way (off while pressed).
- (void)breathe:(BOOL)on {
    [_go.layer removeAnimationForKey:@"breathe"];
    if (on && self.window) nx_animate_scale(_go, @"breathe", 1.0, 1.03, 1.4, kCAMediaTimingFunctionEaseInEaseOut, NO, YES);
}
// While the launcher is on screen: the clock and colours every 5 s, shared cards follow the island every 10 s.
// The first time: the clouds pop in.
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [_timer invalidate], _timer = nil;
    if (!self.window) return;
    [self.window makeFirstResponder:self];
    [self layoutSubtreeIfNeeded];
    [self breathe:YES];
    if (!_appeared) {
        _appeared = YES;
        for (int i = 0; i < 3; i++) {   // scale 0.6 -> 1, fade in, spring, 0.07 s apart
            NxSlotCard *c = _cards[i];
            CFTimeInterval delay = 0.1 + 0.07 * i;
            nx_spring_scale(c, @"pop", 0.6, 1, 11, delay);
            CABasicAnimation *f = [CABasicAnimation animationWithKeyPath:@"opacity"];
            f.fromValue = @0, f.toValue = @1, f.duration = 0.3, f.beginTime = CACurrentMediaTime() + delay, f.fillMode = kCAFillModeBackwards;
            [c.layer addAnimation:f forKey:@"popfade"];
        }
    }
    __weak NxLauncherView *ws = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *t) {
        NxLauncherView *s = ws;
        if (!s || !s.window) { [t invalidate]; return; }
        [s tick];
    }];
}
// Keyboard: left / right pick a slot, Return starts, Cmd+, opens Settings.
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)e {
    switch (e.keyCode) {
    case 123: if (_slot > 1) sfx(@"tap"), [_cards[_slot - 2] squash], [self choose:_slot - 1]; return;
    case 124: if (_slot < 3) sfx(@"tap"), [_cards[_slot] squash], [self choose:_slot + 1]; return;
    case 36: case 76: [self go]; return;
    }
    [super keyDown:e];
}
- (BOOL)performKeyEquivalent:(NSEvent *)e {
    if ((e.modifierFlags & NSEventModifierFlagCommand) && [e.charactersIgnoringModifiers isEqualToString:@","] && !self.window.attachedSheet) {
        [self settings];
        return YES;
    }
    return [super performKeyEquivalent:e];
}
- (void)choose:(int)slot {
    _slot = slot;
    for (NxSlotCard *c in _cards) c.chosen = c.slot == slot;
    [ud() setInteger:slot forKey:kSlot];
    BOOL fresh = slot_info(slot).files == 0;
    _goLabel.text = fresh ? @"Start new island" : [@"Start " stringByAppendingString:slot_title(slot)];
    _share.hidden = fresh;
    [self.window invalidateCursorRectsForView:_share];
}
// Join / Share: online play isn't in this version yet.
- (void)comingSoon {
    sfx(@"open");
    nx_game_dialog(@"Coming soon", @"Sharing an island with a friend and playing Local Play online will come in a later update.",
                   @"OK", nil, self, ^(BOOL m) { sfx(@"close"); [self.window makeFirstResponder:self]; });
}
- (void)cardTap:(NxSlotCard *)c {
    sfx(@"tap");
    [c squash];
    [self choose:c.slot];
}
// Into the game: a bank of cream clouds crosses the screen left to right (0.45 s ease-in), the launcher goes under it,
// then the bank slides off to the right (0.45 s ease-out).
- (void)fadeOut {
    NSView *host = self.superview;
    if (!host) return;
    CGFloat W = host.bounds.size.width, H = host.bounds.size.height, R = H / 4;
    NSColor *cream = rgb(0xFFF2CA, 1);
    NxView *bank = [[NxView alloc] initWithFrame:CGRectMake(-(W + 2 * R), 0, W + 2 * R, H)];
    NxView *fill = [[NxView alloc] initWithFrame:CGRectMake(R, 0, W, H)];
    fill.layer.backgroundColor = cream.CGColor;
    [bank addSubview:fill];
    NSImage *puff = NxUI.shared.cloud ? nx_tinted(NxUI.shared.cloud, cream) : nil;
    for (int edge = 0; edge < 2; edge++)
        for (int i = 0; i <= 4; i++) {
            CGFloat d = 2 * R * (1.25 + 0.15 * (i % 2)), x = edge ? W + R - (i % 2) * R * 0.25 : R + (i % 2) * R * 0.25;
            NxImageView *p = [[NxImageView alloc] initWithFrame:CGRectMake(x - d / 2, i * H / 4 - d / 2, d, d)];
            p.image = puff;
            if (!puff) p.layer.backgroundColor = cream.CGColor, p.layer.cornerRadius = d / 2;
            [bank addSubview:p];
        }
    bank.autoresizingMask = NSViewNotSizable;
    [host addSubview:bank positioned:NSWindowAbove relativeTo:nil];
    bank.frame = CGRectMake(-(W + 2 * R), 0, W + 2 * R, H);   // the canvas sized it to itself
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) {
        c.duration = 0.45;
        c.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
        bank.animator.frame = CGRectMake(-R, 0, W + 2 * R, H);
    } completionHandler:^{
        [self removeFromSuperview];
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) {
            c.duration = 0.45;
            c.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            bank.animator.frame = CGRectMake(W + R, 0, W + 2 * R, H);
        } completionHandler:^{ [bank removeFromSuperview]; }];
    }];
}
- (void)go {
    if (!self.window || self.window.attachedSheet) return;
    sfx(@"start");
    if (_running) {   // over the paused game (from its title screen)
        if ([settings_key(_slot) isEqualToString:_running]) {
            void (^resume)(void) = _resume;
            _resume = nil;
            music_stop(0.8);
            if (resume) resume();
            [self fadeOut];
            return;
        }
        int slot = _slot;
        nx_alert(self.window, @"Restart needed",
                 [NSString stringWithFormat:@"%@ needs a fresh start of the game. Restart it now?", slot_title(slot)], @[@"Restart", @"Cancel"], 0,
                 ^(NSInteger b) {
            if (b != 0) return;
            [ud() setInteger:slot forKey:kAutostart];
            [ud() synchronize];
            nx_log("launcher: island %d chosen from the title screen: restarting for a fresh start", slot);
            nx_mac_relaunch();
        });
        return;
    }
    [self startNow];
}
- (void)startNow {
    if (!_start) return;
    music_stop(0.8);
    apply_settings(_slot);
    void (^start)(void) = _start;
    _start = nil;
    start();
    [self fadeOut];
}
- (void)settings {
    if (self.window.attachedSheet) return;
    sfx(@"open");
    NxSettingsSheet *s = [NxSettingsSheet new];
    s.runningSlot = _running ? (int)[ud() integerForKey:kSlot] : 0;
    __weak NxLauncherView *ws = self;
    s.islandsChanged = ^{ [ws islandsChanged]; };
    if (_removeRom) {
        void (^rm)(void) = _removeRom;
        s.removeRom = ^{
            [ws removeFromSuperview];
            rm();
        };
    }
    [s reload];
    [self.window beginSheet:s completionHandler:^(NSModalResponse r) { [ws.window makeFirstResponder:ws]; }];
}
- (void)menuFor:(NxSlotCard *)card event:(NSEvent *)e {
    int slot = card.slot;
    NSMenu *m = [NSMenu new];
    m.autoenablesItems = NO;
    __weak NxLauncherView *ws = self;
    NSMenuItem *ren = [m addItemWithTitle:@"Rename…" action:@selector(menuRename:) keyEquivalent:@""];
    ren.target = self, ren.representedObject = card, ren.image = nx_symbol(@"pencil", 13, NSFontWeightRegular);
    NSMenuItem *del = [m addItemWithTitle:@"Delete Island…" action:@selector(menuRemove:) keyEquivalent:@""];
    del.target = self, del.representedObject = card;
    del.image = nx_symbol(@"trash", 13, NSFontWeightRegular);
    del.enabled = slot_info(slot).files != 0;
    (void)ws;
    [NSMenu popUpContextMenu:m withEvent:e forView:card];
}
- (void)menuRename:(NSMenuItem *)i { [self rename:i.representedObject]; }
- (void)menuRemove:(NSMenuItem *)i { [self remove:i.representedObject]; }
- (void)rename:(NxSlotCard *)card {
    nx_prompt(self.window, @"Rename", nil, slot_title(card.slot), nil, @[@"Save", @"Cancel"], ^(NSInteger b, NSString *text) {
        if (b != 0) return;
        NSString *n = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        [ud() setObject:n forKey:[NSString stringWithFormat:@"nx.slotname.%d", card.slot]];
        [card refresh];
        [self choose:self->_slot];
    });
}
- (void)remove:(NxSlotCard *)card {
    __weak NxLauncherView *ws = self;
    island_remove_flow(self.window, card.slot, ^{ [ws islandsChanged]; });
}
- (void)islandsChanged {
    for (NxSlotCard *c in _cards) [c refresh];
    [self choose:_slot];
}
@end

// The game's assets (decoded once, then cached) on a background thread, then the island select (main thread).
void nx_launcher_show(BOOL running, void (^start)(void), void (^resume)(void), void (^removeRom)(void), void (^shown)(NSView *v)) {
    NSString *xci = @(getenv("NXRT_XCI") ?: ""), *keys = @(getenv("NXRT_KEYS") ?: "");
    NSString *run = running ? settings_key((int)[ud() integerForKey:kSlot]) : nil;
    void (^make)(void) = ^{
        NxLauncherView *v = [[NxLauncherView alloc] initRunning:run start:start resume:resume removeRom:running ? nil : removeRom];
        shown(v);
        music_launcher(2.0);
    };
    if (NxUI.shared.ready) { make(); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [NxUI.shared loadForXci:xci keys:keys];   // falls back to system fonts / plain colours when incomplete
        dispatch_async(dispatch_get_main_queue(), make);
    });
}
