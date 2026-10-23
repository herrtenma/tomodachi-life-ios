// Prelauncher (iOS), in the game's own look: the logo, cloud panels, pill buttons, squiggle pattern and Seurat font are
// read from the user's .xci (nx_assets.m) and cached in Library/Caches/nx-ui; nothing of the game is bundled.
//   - ROM screen (first launch, or after "Remove ROM"): pick the .xci (checked: it must hold Tomodachi Life's title
//     layout). Plain look: the game's assets aren't there yet.
//   - Island select: three save slots (slot 1 = data, the save from before slots existed; 2 = data-slot2; 3 =
//     data-slot3), long press = Rename / Delete (island_remove_flow), Start.
//   - Settings: graphics mode, widescreen, FPS counter, haptics, sound, Islands (delete; asked twice; folders moved aside
//     to data-deleted-<time>-slotN, never removed); Remove ROM.
//   - From the game's title screen ("Islands" button, app_ios.m) the same screen opens over the paused game: the same
//     island with the same settings resumes; anything else needs a fresh start, which iOS apps can't do in-process:
//     the choice is kept (nx.autostart) and the app closes; opening it again starts that island directly.
// The choices go into the environment before the game starts (env.txt still wins: setenv without overwrite).
// NXRT_LAUNCHER=0: no launcher (old: straight into the game with slot 1 and the defaults).
// Test hooks (simulator, no touch injection): NXRT_LAUNCHER_SHOW=settings, NXRT_LAUNCHER_AUTOSTART=<s> (Start, also over
// the paused game), NXRT_LAUNCHER_ROMAUTO=1 (ROM screen: use the app folder's .xci); app_ios.m NXRT_UITEST_PRESS=Islands@<f>.
//
// Visual spec (the game's menus; colours sampled from its screens):
//   background  #FFC100, squiggle pattern (CmnFacePartsBG_00, 768 px tile shown at 240 pt) in #FFCC2E
//   logo        Title_WW_LogoS (420x360), 118 pt high, top left, 18 pt in from the safe area, 10 pt from its top
//   cards       DialogCloud_00 cloud in #FFF2CA, 3 in a row, 150 pt high, width min(230, (available - 28) / 3), 14 pt
//               gaps, shadow #000 a0.16 r10 y5; selected: the same cloud 8 pt larger behind it in #F2660D; text
//               centred: name Seurat EB 21 #002240, status Seurat B 14 (#F2660D "New island", else #002240 a0.75),
//               size Seurat B 12 #002240 a0.5
//   start       BtnMain_00 pill in #FF2E00, 250x58, "Start <name>" Seurat EB 21 white, shadow #A31D00 a0.35 r0 y4;
//               pressed scale 0.95 in 0.1 s
//   settings    48 pt ToggleBtn_00 circle in #FFFFFF (the texture's visible 52x52 of 70x78 px scaled to the 48 pt button, so
//               the gear is centred), gear 20 pt bold #002240, top right
//   light       the launcher, Settings and alerts stay in light mode (the game's palette; dark mode broke Settings)
//   ROM screen  #FFC100; centre card 460 pt wide, radius 30, #FFFFFF a0.92, 30 pt padding, shadow #000 a0.12 r20 y8;
//               "Add your Tomodachi Life ROM" SF Rounded 26 heavy #002240, body 16 regular #002240 a0.7, button 280x52
//               radius 26 #002240 "Choose .xci file" 18 semibold white, link 15 semibold #F2660D, error 14 #FF2E00
//   motion      selection 0.2 s ease-in-out; the launcher fades out in 0.3 s ease-in-out on Start
//   settings    inset-grouped table on #FFF2CA, Seurat B 17 labels, #F2660D switches and segments
#import <CoreText/CoreText.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdlib.h>
#include "nxrt.h"
#import "../save_import.h"
#import "../app_online.h"

uint8_t *nx_asset_file(const char *name, size_t *n);
const uint8_t *nx_sarc_file(const uint8_t *b, size_t n, const char *name, size_t *size);
CGImageRef nx_bntx_image(const uint8_t *b, size_t n, const char *name);
uint8_t *nx_font_decrypt(const uint8_t *f, size_t n, size_t *out_n);
int nx_content_try(const char *xci_path, const char *keys_path);
uint8_t *nx_romfs_file(const char *fname, uint64_t *size);
NSData *nx_bars_wav(const uint8_t *b, size_t n, const char *name);
UIView *nx_game_dialog(NSString *title, NSString *body, NSString *main, NSString *second, UIView *host, void (^done)(BOOL main));
UIControl *nx_game_button(int style, NSString *title, UIImage *icon);
UIImage *nx_ui_texture(NSString *name);

static NSString *const kSlot = @"nx.slot", *const kMode = @"nx.mode", *const kWide = @"nx.wide", *const kFps = @"nx.fps",
                      *const kHaptics = @"nx.haptics", *const kSound = @"nx.sound", *const kUnmounted = @"nx.romUnmounted",
                      *const kAutostart = @"nx.autostart", *const kSilent = @"nx.respectSilent";
static UIColor *rgb(uint32_t c, CGFloat a) {
    return [UIColor colorWithRed:(c >> 16 & 255) / 255.0 green:(c >> 8 & 255) / 255.0 blue:(c & 255) / 255.0 alpha:a];
}
static UIColor *navy(CGFloat a) { return rgb(0x002240, a); }
static UIColor *orange(void) { return rgb(0xF2660D, 1); }

int nx_launcher_enabled(void) {
    const char *e = getenv("NXRT_LAUNCHER");
    return !e || atoi(e) != 0;
}
static NSUserDefaults *ud(void) {
    NSUserDefaults *u = NSUserDefaults.standardUserDefaults;
    [u registerDefaults:@{kSlot : @1, kMode : @"quality", kWide : @YES, kFps : @NO, kHaptics : @YES, kSound : @YES, kSilent : @NO, kUnmounted : @NO, kAutostart : @0}];
    return u;
}
int nx_launcher_fps_counter(void) { return [ud() boolForKey:kFps]; }
int nx_rom_unmounted(void) { return [ud() boolForKey:kUnmounted]; }
static NSString *slot_dir(int slot) { return slot == 1 ? @"data" : [NSString stringWithFormat:@"data-slot%d", slot]; }
static NSString *slot_title(int slot) {
    NSString *n = [ud() stringForKey:[NSString stringWithFormat:@"nx.slotname.%d", slot]];
    return n.length ? n : [NSString stringWithFormat:@"Island %d", slot];
}
// What needs a fresh start when it changes (the FPS counter doesn't).
static NSString *settings_key(int slot) {
    NSUserDefaults *u = ud();
    return [NSString stringWithFormat:@"%d|%@|%d|%d|%d", slot, [u stringForKey:kMode], [u boolForKey:kWide], [u boolForKey:kHaptics], [u boolForKey:kSound]];
}

// Settings > Respect silent mode. Off (default): the audio session is Playback, which ignores the ring/silent switch, so the
// game and the launcher music play with the phone on silent. On: Ambient, which the switch mutes.
static void apply_audio_session(void) {
    AVAudioSession *as = AVAudioSession.sharedInstance;
    NSError *err = nil;
    BOOL respect = [ud() boolForKey:kSilent];
    [as setCategory:respect ? AVAudioSessionCategoryAmbient : AVAudioSessionCategoryPlayback error:&err];
    if (!err) [as setActive:YES error:&err];
    nx_log("launcher: audio session %s%s%s", respect ? "ambient (respects silent mode)" : "playback (ignores silent mode)", err ? ": " : "",
           err ? err.localizedDescription.UTF8String : "");
}

// The saved choices -> environment (cwd = Documents). Doesn't overwrite what env.txt set.
static void apply_settings(int slot) {
    NSUserDefaults *u = ud();
    NSString *dir = slot_dir(slot);
    apply_audio_session();
    [NSFileManager.defaultManager createDirectoryAtPath:[dir stringByAppendingPathComponent:@"save"] withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("NXRT_DATA", dir.fileSystemRepresentation, 0);
    setenv("NXRT_MODE", [u stringForKey:kMode].UTF8String, 0);
    if (![u boolForKey:kWide]) setenv("NXRT_WIDE", "1280", 0);
    if (![u boolForKey:kHaptics]) setenv("NXRT_NOHAPTICS", "1", 0);
    if (![u boolForKey:kSound]) setenv("NXRT_AUDIO", "0", 0);
    nx_log("launcher: slot %d (%s), mode %s, widescreen %s, fps counter %s, haptics %s, sound %s", slot, getenv("NXRT_DATA"),
           getenv("NXRT_MODE"), [u boolForKey:kWide] ? "on" : "off", [u boolForKey:kFps] ? "on" : "off",
           [u boolForKey:kHaptics] ? "on" : "off", [u boolForKey:kSound] ? "on" : "off");
}
// An island chosen from the title screen that needed a fresh start: start it straight away (slot, or 0).
int nx_launcher_take_autostart(void) {
    int slot = (int)[ud() integerForKey:kAutostart];
    if (slot < 1 || slot > 3) return 0;
    [ud() setInteger:0 forKey:kAutostart];
    apply_settings(slot);
    return slot;
}

// ---- time of day -----------------------------------------------------------------------------------------------
// The launcher follows the local time: background colour (keyframes below, blended) and music (four parts of the day).
// NXRT_LAUNCHER_HOUR=<hours, e.g. 20.5>: pretend it's that time (screenshots).
static double day_hour(void) {
    const char *e = getenv("NXRT_LAUNCHER_HOUR");
    if (e) return fmod(atof(e), 24);
    NSDateComponents *c = [NSCalendar.currentCalendar components:NSCalendarUnitHour | NSCalendarUnitMinute fromDate:NSDate.date];
    return c.hour + c.minute / 60.0;
}
// latenight 0-5, morning 5-10, latemorning 10-12, afternoon 12-16, lateafternoon 16-18, evening 18-21, night 21-24
static NSString *day_period(void) {
    double h = day_hour();
    return h < 5 ? @"latenight" : h < 10 ? @"morning" : h < 12 ? @"latemorning" : h < 16 ? @"afternoon" : h < 18 ? @"lateafternoon"
         : h < 21 ? @"evening" : @"night";
}
// Base colour: dawn peach, the game's yellow (morning, to 11:00), sky blue (afternoon, 13:00-16:30), sunset, dusk
// violet, night indigo (22:00 to 4:30).
static UIColor *day_color(void) {
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
    return [UIColor colorWithRed:ch[0] green:ch[1] blue:ch[2] alpha:1];
}
static BOOL is_dark(UIColor *c) {
    CGFloat r, g, b, a;
    [c getRed:&r green:&g blue:&b alpha:&a];
    return 0.299 * r + 0.587 * g + 0.114 * b < 0.55;
}
// The squiggles: the base 18% of the way to white (#FFC100 -> #FFCC2E, the game's own pair); 9% on dark colours.
static UIColor *pattern_color(UIColor *base) {
    CGFloat r, g, b, a, k = is_dark(base) ? 0.09 : 0.18;
    [base getRed:&r green:&g blue:&b alpha:&a];
    return [UIColor colorWithRed:r + (1 - r) * k green:g + (1 - g) * k blue:b + (1 - b) * k alpha:1];
}

// ---- launcher music ------------------------------------------------------------------------------------------------
// The island select plays the part of the day's music (music/launcher_<period>_*.m4a, day_period's names, shuffled; the
// older launcher_1..3 stand for night + latenight / morning to lateafternoon / evening), fading in over 2 s when the launcher appears, out over
// 0.8 s when an island is picked, cross-fading over 3 s when the part of the day changes. The files are in the app's
// music folder (ios/music). Off with Settings > Sound off or NXRT_LAUNCHER_MUSIC=0; missing files = silence.
@interface NxMusic : NSObject <AVAudioPlayerDelegate>
@end
static AVAudioPlayer *g_music;            // what's playing now
static NSString *g_music_mode;            // @"launcher-<period>" / nil
static NSArray<NSString *> *g_playlist;   // the period's tracks, shuffled
static NSUInteger g_track;
static NxMusic *g_music_delegate;
static const float kMusicVolume = 0.7f;
static NSString *music_dir(void) { return [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"music"]; }
static BOOL music_on(void) {
    const char *e = getenv("NXRT_LAUNCHER_MUSIC");
    return (!e || atoi(e) != 0) && [ud() boolForKey:kSound];
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
    music_fade_out(g_music, fade);   // cross-fade from whatever played before
    g_music = p;
}
// The period's tracks: launcher_<period>_*, else the old numbered ones, else any launcher_*.
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
// The island select's music for the part of the day (no-op while it's already playing).
static void music_launcher(NSTimeInterval fade) {
    NSString *mode = [@"launcher-" stringByAppendingString:day_period()];
    if (!music_on() || [g_music_mode isEqual:mode]) return;
    g_playlist = music_tracks(day_period()), g_track = 0;
    if (!g_playlist.count) return;
    g_music_mode = mode;
    apply_audio_session();
    music_play(g_playlist[g_track % g_playlist.count], g_playlist.count == 1, fade);
}
// The part of the day changed while the island select plays: cross-fade to its music.
static void music_follow_time(void) {
    if ([g_music_mode hasPrefix:@"launcher"]) music_launcher(3.0);
}
static void music_stop(NSTimeInterval fade) {
    music_fade_out(g_music, fade);
    g_music = nil, g_music_mode = nil;
}
@implementation NxMusic
// A launcher track ended: the next one in the period's shuffle.
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)p successfully:(BOOL)ok {
    if (p != g_music || ![g_music_mode hasPrefix:@"launcher"] || !g_playlist.count) return;
    g_track++;
    music_play(g_playlist[g_track % g_playlist.count], NO, 0.5);
}
@end

// ---- menu sounds -------------------------------------------------------------------------------------------------
// The game's own UI sounds (decoded from its sound archive into the asset cache): tap (a cloud), start, open (a screen
// or Settings), close. Follow Settings > Sound.
static NSString *cache_dir(void);
static void sfx(NSString *name) {
    static NSMutableDictionary<NSString *, AVAudioPlayer *> *players;
    if (![ud() boolForKey:kSound]) return;
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

// Residents: Mii.sav is a table of (key hash, offset) pairs (from 0x20 up to the u32 at 8); key 0x2499BFDA = the 70 Mii
// names (u32 count, then 0x40-byte UTF-16 names; empty = free). -1: no save or not readable.
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
static UIImage *slot_snapshot(int slot) {
    return [UIImage imageWithContentsOfFile:[slot_dir(slot) stringByAppendingPathComponent:@"snapshot.jpg"]];
}

// ---- the game's assets -----------------------------------------------------------------------------------------
@interface NxUI : NSObject
@property(nonatomic, readonly) UIImage *logo, *pattern, *cloud, *pill, *circle;
@property(nonatomic, readonly) BOOL ready;
+ (instancetype)shared;
- (BOOL)loadForXci:(NSString *)xci keys:(NSString *)keys;   // background thread
- (void)forget;
- (UIFont *)font:(CGFloat)size bold:(BOOL)bold;
@end
@implementation NxUI {
    NSString *_eb, *_b;   // PostScript names of the registered fonts
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
static UIImage *png_image(NSString *path, CGFloat scale) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    return d ? [UIImage imageWithData:d scale:scale] : nil;
}
// One texture of one layout archive to a PNG in the cache.
static BOOL cache_texture(NSString *dir, const char *archive, const char *tex, NSString *out) {
    size_t n, bn;
    uint8_t *a = nx_asset_file(archive, &n);
    const uint8_t *bntx = a ? nx_sarc_file(a, n, "timg/__Combined.bntx", &bn) : NULL;
    CGImageRef img = bntx ? nx_bntx_image(bntx, bn, tex) : NULL;
    free(a);
    if (!img) { nx_log("launcher: asset %s / %s missing", archive, tex); return NO; }
    NSData *png = UIImagePNGRepresentation([UIImage imageWithCGImage:img]);
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
    CGFontRef cg = CTFontCopyGraphicsFont(f, NULL);
    CTFontManagerRegisterGraphicsFont(cg, NULL);   // fails harmlessly when already registered
    CGFontRelease(cg), CFRelease(f), CFRelease(fd);
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
        // game_ui.m's buttons and dialog. Missing ones fall back to plain shapes.
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
        // The game's menu sounds (optional): tap, start, open, close
        uint8_t *bars = nx_asset_file("System_Static.Product.100.bars.zs", &n);
        const char *sfx[][2] = {{"SE_UI_Cursor", "sfx_tap"}, {"SE_UI_Decide2", "sfx_start"}, {"SE_UI_Open_", "sfx_open"}, {"SE_UI_CloseSoft", "sfx_close"}};
        for (int i = 0; i < 4 && bars; i++)
            [nx_bars_wav(bars, n, sfx[i][0]) writeToFile:[dir stringByAppendingFormat:@"/%s.wav", sfx[i][1]] atomically:YES];
        free(bars);
        if (!ok) return NO;
        [stamp writeToFile:stampf atomically:YES encoding:NSUTF8StringEncoding error:nil];
        nx_log("launcher: game UI assets cached in %.2f s", CFAbsoluteTimeGetCurrent() - t0);
    }
    _logo = png_image([dir stringByAppendingPathComponent:@"logo.png"], 3);
    _pattern = png_image([dir stringByAppendingPathComponent:@"pattern.png"], 768 / 240.0);
    _cloud = png_image([dir stringByAppendingPathComponent:@"cloud.png"], 3);
    _pill = png_image([dir stringByAppendingPathComponent:@"pill.png"], 3);
    _circle = png_image([dir stringByAppendingPathComponent:@"circle.png"], 3);
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
- (UIFont *)font:(CGFloat)size bold:(BOOL)bold {
    UIFont *f = _ready ? [UIFont fontWithName:bold ? _eb : _b size:size] : nil;
    if (f) return f;
    UIFont *sys = [UIFont systemFontOfSize:size weight:bold ? UIFontWeightHeavy : UIFontWeightSemibold];
    UIFontDescriptor *rd = [sys.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    return rd ? [UIFont fontWithDescriptor:rd size:size] : sys;
}
@end
// For game_ui.m: the cached game textures (3 px per point), the game's font, the cloud.
UIImage *nx_ui_texture(NSString *name) { return png_image([[cache_dir() stringByAppendingPathComponent:name] stringByAppendingString:@".png"], 3); }
UIFont *nx_ui_font(CGFloat size, BOOL bold) { return [NxUI.shared font:size bold:bold]; }
UIImage *nx_ui_cloud(void) { return NxUI.shared.cloud; }
static UIImage *tinted(UIImage *mask, UIColor *c) { return [mask imageWithTintColor:c renderingMode:UIImageRenderingModeAlwaysOriginal]; }

// ---- Deleting an island ------------------------------------------------------------------------------------
// Settings > Islands and the card's long press: empty a slot, confirmed twice. The folder is moved aside
// (data-deleted-<time>-slotN, still in the Files app), never removed.
static void slot_empty(int slot) {
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *to = [NSString stringWithFormat:@"data-deleted-%@-slot%d", [df stringFromDate:NSDate.date], slot];
    NSError *err = nil;
    BOOL ok = [NSFileManager.defaultManager moveItemAtPath:slot_dir(slot) toPath:to error:&err];
    if (ok) [ud() removeObjectForKey:[NSString stringWithFormat:@"nx.slotname.%d", slot]];
    nx_log("launcher: slot %d moved to %s: %s", slot, to.UTF8String, ok ? "ok" : err.localizedDescription.UTF8String);
}
static void alert_ok(UIViewController *host, NSString *title, NSString *msg) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [host presentViewController:a animated:YES completion:nil];
}
static void island_remove_flow(UIViewController *host, int slot, void (^done)(void)) {
    NSString *name = slot_title(slot);
    void (^confirm)(NSString *, NSString *, NSString *, void (^)(void)) = ^(NSString *t, NSString *m, NSString *btn, void (^yes)(void)) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:t message:m preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:btn style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { yes(); }]];
        [host presentViewController:a animated:YES completion:nil];
    };
    void (^empty)(void) = ^{ slot_empty(slot); done(); };
    confirm([NSString stringWithFormat:@"Delete %@?", name],
            @"Its save leaves this slot. A backup copy stays in the app's folder (Files app).", @"Delete", ^{
        confirm(@"Are you sure?", [NSString stringWithFormat:@"%@ and all its residents will be gone from the island select.", name],
                @"Delete Island", empty);
    });
}

// ---- Settings --------------------------------------------------------------------------------------------------
@interface NxSettingsController : UITableViewController <UIDocumentPickerDelegate>
@property(nonatomic, copy) void (^removeRom)(void);
@property(nonatomic, copy) void (^islandsChanged)(void);   // a slot was emptied (the launcher refreshes its cards)
@property(nonatomic) int runningSlot;                       // the paused game's slot (can't be removed), 0 = none
@end
@implementation NxSettingsController
- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    self.title = @"Settings";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = rgb(0xFFF2CA, 1);
    self.navigationController.navigationBar.titleTextAttributes = @{NSFontAttributeName : [NxUI.shared font:19 bold:YES], NSForegroundColorAttributeName : navy(1)};
    self.navigationController.navigationBar.tintColor = orange();
}
- (void)done {
    sfx(@"close");
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return self.removeRom ? 6 : 5;
}
// Settings > Islands: the slots with a save.
- (NSArray<NSNumber *> *)islandSlots {
    NSMutableArray *a = [NSMutableArray array];
    for (int slot = 1; slot <= 3; slot++)
        if (slot_info(slot).files) [a addObject:@(slot)];
    return a;
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 4) return MAX(1, (NSInteger)self.islandSlots.count) + 1;   // the islands (or "No saved islands"), then Import
    if (s == 2) return 3;
    return s == 0 || s == 3 || s >= 5 ? 1 : 2;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return @[@"Graphics", @"Display", @"Feedback", @"Online", @"Islands", @"Game"][s];
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0) return @"Quality: the game's 720p, sharpened to 1080p. Performance: 540p, sharpened to 1080p; less work per frame, a "
                       @"little softer. Both run at 30 fps.";
    if (s == 1) return @"Widescreen fills the whole screen instead of 16:9.";
    if (s == 2) return @"Respect silent mode: off, the game plays even when the phone is on silent; on, the silent switch mutes it. "
                       @"Settings apply when an island starts.";
    if (s == 3) return @"Sharing an island with a friend and online Local Play will come in a later update.";
    if (s == 4) return @"Import takes a save from an emulator (Ryujinx, yuzu and forks, Checkpoint, JKSV): its folder or a .zip. "
                       @"The island it replaces is kept in the app's folder. Deleting asks twice.";
    return @"Removing the ROM only forgets it here; the file itself stays where it is.";
}
- (void)tableView:(UITableView *)tv willDisplayHeaderView:(UIView *)v forSection:(NSInteger)s {
    if ([v isKindOfClass:UITableViewHeaderFooterView.class]) ((UITableViewHeaderFooterView *)v).textLabel.font = [NxUI.shared font:14 bold:YES];
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.textLabel.font = [NxUI.shared font:17 bold:NO];
    c.textLabel.textColor = navy(1);
    NSUserDefaults *u = ud();
    if (ip.section == 0) {
        c.textLabel.text = @"Mode";
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"Quality", @"Performance"]];
        seg.selectedSegmentIndex = [[u stringForKey:kMode] isEqualToString:@"performance"] ? 1 : 0;
        seg.selectedSegmentTintColor = orange();
        [seg setTitleTextAttributes:@{NSFontAttributeName : [NxUI.shared font:14 bold:NO], NSForegroundColorAttributeName : navy(1)} forState:UIControlStateNormal];
        [seg setTitleTextAttributes:@{NSFontAttributeName : [NxUI.shared font:14 bold:YES], NSForegroundColorAttributeName : UIColor.whiteColor}
                           forState:UIControlStateSelected];
        [seg addTarget:self action:@selector(mode:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = seg;
        return c;
    }
    if (ip.section == 3) {
        c.textLabel.text = @"Shared islands, Local Play";
        UILabel *v = [UILabel new];
        v.text = @"Coming soon";
        v.font = [NxUI.shared font:17 bold:YES], v.textColor = navy(0.45);
        [v sizeToFit];
        c.accessoryView = v;
        return c;
    }
    if (ip.section == 4 && ip.row == MAX(1, (NSInteger)self.islandSlots.count)) {
        c.textLabel.text = @"Import a save…";
        c.textLabel.textColor = orange();
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        return c;
    }
    if (ip.section == 4) {
        NSArray<NSNumber *> *slots = self.islandSlots;
        if (!slots.count) {
            c.textLabel.text = @"No saved islands";
            c.textLabel.textColor = navy(0.45);
            return c;
        }
        int slot = slots[ip.row].intValue;
        BOOL running = slot == self.runningSlot;
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        c.textLabel.font = [NxUI.shared font:17 bold:NO], c.textLabel.textColor = navy(1);
        c.textLabel.text = slot_title(slot);
        c.detailTextLabel.font = [NxUI.shared font:13 bold:NO], c.detailTextLabel.textColor = navy(0.55);
        c.detailTextLabel.text = [NSString stringWithFormat:@"Slot %d%@", slot, running ? @" · Playing now" : @""];
        UILabel *v = [UILabel new];
        v.text = @"Delete";
        v.font = [NxUI.shared font:17 bold:YES], v.textColor = running ? navy(0.3) : rgb(0xFF2E00, 1);
        [v sizeToFit];
        c.accessoryView = v;
        c.selectionStyle = running ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
        return c;
    }
    if (ip.section == 5) {
        NSString *xci = getenv("NXRT_XCI") ? @(getenv("NXRT_XCI")).lastPathComponent : @"";
        c.textLabel.text = [NSString stringWithFormat:@"Remove ROM (%@)", xci];
        c.textLabel.textColor = rgb(0xFF2E00, 1);
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        return c;
    }
    NSString *key = ip.section == 1 ? (ip.row == 0 ? kWide : kFps) : (ip.row == 0 ? kHaptics : ip.row == 1 ? kSound : kSilent);
    c.textLabel.text = @{kWide : @"Widescreen", kFps : @"FPS counter", kHaptics : @"Haptics", kSound : @"Sound", kSilent : @"Respect silent mode"}[key];
    UISwitch *sw = [UISwitch new];
    sw.on = [u boolForKey:key];
    sw.onTintColor = orange();
    sw.accessibilityIdentifier = key;
    [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
    c.accessoryView = sw;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 4 && ip.row == MAX(1, (NSInteger)self.islandSlots.count)) { [self importFlow:[tv cellForRowAtIndexPath:ip]]; return; }
    if (ip.section == 4) {
        NSArray<NSNumber *> *slots = self.islandSlots;
        if (ip.row >= (NSInteger)slots.count) return;
        int slot = slots[ip.row].intValue;
        if (slot == self.runningSlot) {
            alert_ok(self, @"This island is open", @"Pick another island and Start it first, then delete this one.");
            return;
        }
        __weak NxSettingsController *ws = self;
        island_remove_flow(self, slot, ^{
            [ws.tableView reloadData];
            if (ws.islandsChanged) ws.islandsChanged();
        });
        return;
    }
    if (ip.section != 5 || !self.removeRom) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Remove the ROM?"
                                                               message:@"The app forgets this .xci and asks for one again. Your islands stay."
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    void (^rm)(void) = self.removeRom;
    [a addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [self dismissViewControllerAnimated:YES completion:^{ rm(); }];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
// ---- Import a save ---------------------------------------------------------------------------------------------
// Where the save comes from: the Files app, or the app's Import folder (pickers don't hand files over inside
// LiveContainer; Files > Tomodachi > Import always works). Then which island it goes into.
- (void)importFlow:(UIView *)from {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Import a save" message:@"A folder or .zip from your emulator or a Checkpoint / JKSV backup."
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"Choose from Files…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder, UTTypeZIP] asCopy:NO];
        p.delegate = self;
        p.allowsMultipleSelection = NO;
        [self presentViewController:p animated:YES completion:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Use the Import folder" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *dir = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:@"Import"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        if (![NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil].count) {
            alert_ok(self, @"The Import folder is empty", @"Put the save folder or its .zip in Files > Tomodachi > Import, then try again.");
            return;
        }
        [self chooseIslandFor:dir scoped:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = from;
    a.popoverPresentationController.sourceRect = from.bounds;
    [self presentViewController:a animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject;
    if (!u) return;
    BOOL scoped = [u startAccessingSecurityScopedResource];
    [self chooseIslandFor:u.path scoped:scoped ? u : nil];
}
- (void)chooseIslandFor:(NSString *)src scoped:(NSURL *)scoped {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Import into which island?" message:nil preferredStyle:UIAlertControllerStyleAlert];
    for (int slot = 1; slot <= 3; slot++) {
        BOOL used = slot_info(slot).files > 0;
        NSString *t = used ? [NSString stringWithFormat:@"%@ (replaces it)", slot_title(slot)] : [NSString stringWithFormat:@"%@ (empty)", slot_title(slot)];
        UIAlertAction *act = [UIAlertAction actionWithTitle:t style:used ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            int n = 0;
            NSString *why = nx_save_import(src, slot_dir(slot), &n);
            if (scoped) [scoped stopAccessingSecurityScopedResource];
            nx_log("launcher: import save %s -> slot %d: %s", src.lastPathComponent.UTF8String, slot, why ? why.UTF8String : "ok");
            if (why) { alert_ok(self, @"Couldn't import", why); return; }
            [self.tableView reloadData];
            if (self.islandsChanged) self.islandsChanged();
            alert_ok(self, @"Save imported", [NSString stringWithFormat:@"%@ now has your save (%d files).%@", slot_title(slot), n,
                                              used ? @" The old save was kept in the app's folder." : @""]);
        }];
        if (slot == self.runningSlot) act.enabled = NO;
        [a addAction:act];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) {
        if (scoped) [scoped stopAccessingSecurityScopedResource];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)mode:(UISegmentedControl *)seg {
    [ud() setObject:seg.selectedSegmentIndex == 1 ? @"performance" : @"quality" forKey:kMode];
}
- (void)toggle:(UISwitch *)sw {
    [ud() setBool:sw.on forKey:sw.accessibilityIdentifier];
    if ([sw.accessibilityIdentifier isEqual:kSilent]) apply_audio_session();
    if ([sw.accessibilityIdentifier isEqual:kSound]) {   // the launcher's music follows Sound at once
        if (sw.on) music_launcher(1.0);
        else music_stop(0.5);
    }
}
@end

// ---- News and feedback -----------------------------------------------------------------------------------------
// News: the entries of news.json (GitHub main), newest first; an orange row on top when a newer version is out.
@interface NxNewsController : UITableViewController
@end
@implementation NxNewsController {
    NSDictionary *_news;
    BOOL _loaded;
}
- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    self.title = @"News";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = rgb(0xFFF2CA, 1);
    self.navigationController.navigationBar.titleTextAttributes = @{NSFontAttributeName : [NxUI.shared font:19 bold:YES], NSForegroundColorAttributeName : navy(1)};
    self.navigationController.navigationBar.tintColor = orange();
    __weak NxNewsController *ws = self;
    nx_news_fetch(^(NSDictionary *news) {
        NxNewsController *s = ws;
        if (!s) return;
        s->_news = news, s->_loaded = YES;
        [s.tableView reloadData];
    });
}
- (void)done {
    sfx(@"close");
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (BOOL)hasUpdate { return _news && nx_news_update_available(_news); }
- (NSArray *)entries { return [_news[@"entries"] isKindOfClass:NSArray.class] ? _news[@"entries"] : @[]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return (self.hasUpdate ? 1 : 0) + MAX(1, (NSInteger)self.entries.count);
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (self.hasUpdate && s == 0) return 1;
    if (!self.entries.count) return 1;
    NSArray *notes = self.entries[s - (self.hasUpdate ? 1 : 0)][@"notes"];
    return [notes isKindOfClass:NSArray.class] ? MAX(1, (NSInteger)notes.count) : 1;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (self.hasUpdate && s == 0) return @"Update";
    if (!self.entries.count) return nil;
    NSDictionary *e = self.entries[s - (self.hasUpdate ? 1 : 0)];
    NSString *date = [e[@"date"] isKindOfClass:NSString.class] ? e[@"date"] : @"";
    return [NSString stringWithFormat:@"%@ · %@%@%@", e[@"version"] ?: @"", e[@"title"] ?: @"", date.length ? @" · " : @"", date];
}
- (void)tableView:(UITableView *)tv willDisplayHeaderView:(UIView *)v forSection:(NSInteger)sec {
    if ([v isKindOfClass:UITableViewHeaderFooterView.class]) {
        UILabel *l = ((UITableViewHeaderFooterView *)v).textLabel;
        l.font = [NxUI.shared font:14 bold:YES], l.textColor = orange();
    }
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.textLabel.numberOfLines = 0;
    c.textLabel.font = [NxUI.shared font:16 bold:NO];
    c.textLabel.textColor = navy(0.85);
    if (self.hasUpdate && ip.section == 0) {
        c.textLabel.text = [NSString stringWithFormat:@"Version %@ is out. Tap to download it.", _news[@"latest"]];
        c.textLabel.font = [NxUI.shared font:16 bold:YES], c.textLabel.textColor = orange();
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        return c;
    }
    if (!self.entries.count) {
        c.textLabel.text = _loaded ? @"Couldn't load the news. Check your connection." : @"Loading…";
        c.textLabel.textColor = navy(0.45);
        return c;
    }
    NSArray *notes = self.entries[ip.section - (self.hasUpdate ? 1 : 0)][@"notes"];
    c.textLabel.text = [notes isKindOfClass:NSArray.class] && notes.count ? [@"• " stringByAppendingString:[NSString stringWithFormat:@"%@", notes[ip.row]]] : @"";
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (!(self.hasUpdate && ip.section == 0)) return;
    NSString *u = [_news[@"url"] isKindOfClass:NSString.class] ? _news[@"url"] : nil;
    NSURL *url = u ? [NSURL URLWithString:u] : nil;
    if ([url.scheme isEqual:@"https"]) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}
@end

// Feedback: bug / crash / idea, a message, an optional contact, the game log on by default. Sent to the feedback worker.
@interface NxFeedbackController : UIViewController
@property(nonatomic, copy) NSString *kind;   // preselects "crash" after a crash
@end
@implementation NxFeedbackController {
    UISegmentedControl *_seg;
    UITextView *_text;
    UITextField *_contact;
    UISwitch *_log;
    UIButton *_send;
    UILabel *_status;
    UIScrollView *_scroll;
    UIActivityIndicatorView *_spin;
}
static NSArray *kFeedbackKinds(void) { return @[@"bug", @"crash", @"idea"]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    NxUI *ui = NxUI.shared;
    self.title = @"Feedback";
    self.view.backgroundColor = rgb(0xFFF2CA, 1);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    self.navigationController.navigationBar.titleTextAttributes = @{NSFontAttributeName : [ui font:19 bold:YES], NSForegroundColorAttributeName : navy(1)};
    self.navigationController.navigationBar.tintColor = orange();

    _seg = [[UISegmentedControl alloc] initWithItems:@[@"Bug", @"Crash", @"Idea"]];
    _seg.selectedSegmentIndex = MAX(0, (NSInteger)[kFeedbackKinds() indexOfObject:self.kind ?: @"bug"]);
    _seg.selectedSegmentTintColor = orange();
    [_seg setTitleTextAttributes:@{NSFontAttributeName : [ui font:14 bold:NO], NSForegroundColorAttributeName : navy(1)} forState:UIControlStateNormal];
    [_seg setTitleTextAttributes:@{NSFontAttributeName : [ui font:14 bold:YES], NSForegroundColorAttributeName : UIColor.whiteColor} forState:UIControlStateSelected];

    _text = [UITextView new];
    _text.font = [ui font:16 bold:NO], _text.textColor = navy(1);
    _text.backgroundColor = UIColor.whiteColor;
    _text.layer.cornerRadius = 12, _text.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
    _text.accessibilityLabel = @"What happened, or your idea";
    _contact = [UITextField new];
    _contact.placeholder = @"Email or Discord, if you'd like a reply (optional)";
    _contact.font = [ui font:15 bold:NO], _contact.textColor = navy(1);
    _contact.backgroundColor = UIColor.whiteColor, _contact.layer.cornerRadius = 12;
    _contact.autocapitalizationType = UITextAutocapitalizationTypeNone, _contact.autocorrectionType = UITextAutocorrectionTypeNo;
    _contact.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)], _contact.leftViewMode = UITextFieldViewModeAlways;

    UILabel *logLabel = [UILabel new];
    logLabel.text = @"Include game log", logLabel.font = [ui font:16 bold:NO], logLabel.textColor = navy(1);
    _log = [UISwitch new];
    _log.on = YES, _log.onTintColor = orange();
    UIStackView *logRow = [[UIStackView alloc] initWithArrangedSubviews:@[logLabel, _log]];
    UILabel *foot = [UILabel new];
    foot.text = @"Sends the game log and your device model, never your saves. A few reports an hour at most.";
    foot.font = [ui font:13 bold:NO], foot.textColor = navy(0.55), foot.numberOfLines = 0;

    _send = [UIButton buttonWithType:UIButtonTypeCustom];
    [_send setBackgroundImage:tinted(ui.pill, rgb(0xFF2E00, 1)) forState:UIControlStateNormal];
    if (!ui.pill) _send.backgroundColor = rgb(0xFF2E00, 1), _send.layer.cornerRadius = 26;
    _send.layer.shadowColor = rgb(0xA31D00, 1).CGColor, _send.layer.shadowOpacity = 0.35f, _send.layer.shadowRadius = 0, _send.layer.shadowOffset = CGSizeMake(0, 4);
    [_send setTitle:@"Send" forState:UIControlStateNormal];
    _send.titleLabel.font = [ui font:19 bold:YES];
    [_send addTarget:self action:@selector(send) forControlEvents:UIControlEventTouchUpInside];
    _spin = [UIActivityIndicatorView new];
    _spin.color = UIColor.whiteColor, _spin.hidesWhenStopped = YES;
    [_send addSubview:_spin];
    _status = [UILabel new];
    _status.font = [ui font:14 bold:YES], _status.textColor = rgb(0xFF2E00, 1), _status.numberOfLines = 0, _status.textAlignment = NSTextAlignmentCenter;

    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[_seg, _text, _contact, logRow, foot, _send, _status]];
    st.axis = UILayoutConstraintAxisVertical, st.spacing = 14;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll = [UIScrollView new];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [_scroll addSubview:st];
    [self.view addSubview:_scroll];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_scroll.topAnchor constraintEqualToAnchor:g.topAnchor], [_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [st.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:16], [st.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [st.leadingAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.leadingAnchor constant:20], [st.trailingAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.trailingAnchor constant:-20],
        [_text.heightAnchor constraintEqualToConstant:140], [_contact.heightAnchor constraintEqualToConstant:44], [_send.heightAnchor constraintEqualToConstant:52],
        [_send.widthAnchor constraintLessThanOrEqualToConstant:250],
    ]];
    st.alignment = UIStackViewAlignmentFill;
    [_send.centerXAnchor constraintEqualToAnchor:st.centerXAnchor].active = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboard:) name:UIKeyboardWillChangeFrameNotification object:nil];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _spin.center = CGPointMake(28, _send.bounds.size.height / 2);
}
- (void)keyboard:(NSNotification *)n {
    CGRect f = [self.view convertRect:[n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil];
    CGFloat h = MAX(0, CGRectGetMaxY(self.view.bounds) - f.origin.y);
    _scroll.contentInset = _scroll.verticalScrollIndicatorInsets = UIEdgeInsetsMake(0, 0, h, 0);
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)send {
    NSString *kind = kFeedbackKinds()[_seg.selectedSegmentIndex];
    NSString *msg = [_text.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!msg.length && ![kind isEqual:@"crash"]) { _status.text = @"Write a few words first."; return; }
    [self.view endEditing:YES];
    _status.text = @"";
    _send.enabled = NO, _send.alpha = 0.7;
    [_spin startAnimating];
    __weak NxFeedbackController *ws = self;
    nx_feedback_send(kind, msg, _contact.text, _log.on, ^(NSString *err) {
        NxFeedbackController *s = ws;
        if (!s) return;
        [s->_spin stopAnimating];
        s->_send.enabled = YES, s->_send.alpha = 1;
        if (err) { s->_status.text = err; return; }
        nx_log("launcher: feedback (%s) sent", kind.UTF8String);
        UIViewController *host = s.presentingViewController;
        [s dismissViewControllerAnimated:YES completion:^{ alert_ok(host, @"Thank you!", @"Your report was sent."); }];
    });
}
@end

// ---- ROM screen ------------------------------------------------------------------------------------------------
// Forgets the ROM: the bookmark, the Documents .xci (ignored until a ROM is added again), the cached UI assets.
void nx_rom_forget(void) {
    [ud() removeObjectForKey:@"xci"];
    [ud() setBool:YES forKey:kUnmounted];
    unsetenv("NXRT_XCI");
    [NxUI.shared forget];
    nx_log("launcher: ROM removed");
}
@interface NxRomView : UIView <UIDocumentPickerDelegate>
@end
@implementation NxRomView {
    __weak UIViewController *_host;
    void (^_done)(NSString *);
    UIView *_card;
    UILabel *_title, *_body, *_error;
    UIButton *_choose, *_local;
    UIActivityIndicatorView *_spin;
    NSString *_localXci;
}
- (instancetype)initWithHost:(UIViewController *)host done:(void (^)(NSString *))done {
    self = [super initWithFrame:CGRectZero];
    _host = host, _done = done;
    self.backgroundColor = rgb(0xFFC100, 1);
    _card = [UIView new];
    _card.backgroundColor = [UIColor colorWithWhite:1 alpha:0.92];
    _card.layer.cornerRadius = 30, _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.layer.shadowColor = UIColor.blackColor.CGColor, _card.layer.shadowOpacity = 0.12f, _card.layer.shadowRadius = 20, _card.layer.shadowOffset = CGSizeMake(0, 8);
    [self addSubview:_card];
    _title = [UILabel new], _body = [UILabel new], _error = [UILabel new];
    _title.text = @"Add your Tomodachi Life ROM";
    _title.font = [NxUI.shared font:26 bold:YES], _title.textColor = navy(1), _title.textAlignment = NSTextAlignmentCenter;
    _title.adjustsFontSizeToFitWidth = YES;
    _body.text = @"Choose your Tomodachi Life: Living the Dream .xci file. It stays on this device.";
    _body.font = [UIFont systemFontOfSize:16], _body.textColor = navy(0.7), _body.numberOfLines = 0, _body.textAlignment = NSTextAlignmentCenter;
    _error.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium], _error.textColor = rgb(0xFF2E00, 1), _error.numberOfLines = 0;
    _error.textAlignment = NSTextAlignmentCenter;
    _choose = [UIButton buttonWithType:UIButtonTypeCustom];
    _choose.backgroundColor = navy(1), _choose.layer.cornerRadius = 26, _choose.layer.cornerCurve = kCACornerCurveContinuous;
    [_choose setTitle:@"Choose .xci file" forState:UIControlStateNormal];
    _choose.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [_choose addTarget:self action:@selector(pick) forControlEvents:UIControlEventTouchUpInside];
    _local = [UIButton buttonWithType:UIButtonTypeSystem];
    _local.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [_local setTitleColor:orange() forState:UIControlStateNormal];
    [_local addTarget:self action:@selector(useLocal) forControlEvents:UIControlEventTouchUpInside];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:@"." error:nil])
        if ([f.pathExtension.lowercaseString isEqualToString:@"xci"]) { _localXci = f; break; }
    if (_localXci) [_local setTitle:[NSString stringWithFormat:@"Use %@ from the app's folder", _localXci] forState:UIControlStateNormal];
    _local.hidden = !_localXci;
    _spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spin.color = navy(1), _spin.hidesWhenStopped = YES;
    for (UIView *v in @[_title, _body, _error, _choose, _local, _spin]) [_card addSubview:v];
    if (getenv("NXRT_LAUNCHER_ROMAUTO") && _localXci)   // test hook: use the app folder's .xci after 2 s
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self useLocal]; });
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat w = MIN(460, b.size.width - 48), inner = w - 60, y = 30;
    _title.frame = CGRectMake(30, y, inner, 32), y += 42;
    CGSize bs = [_body sizeThatFits:CGSizeMake(inner, 200)];
    _body.frame = CGRectMake(30, y, inner, bs.height), y += bs.height + 22;
    _choose.frame = CGRectMake((w - 280) / 2, y, 280, 52), y += 52;
    _spin.center = CGPointMake(w - 30 - 12, CGRectGetMidY(_choose.frame));
    if (!_local.hidden) _local.frame = CGRectMake(30, y + 10, inner, 30), y += 40;
    if (_error.text.length) {
        CGSize es = [_error sizeThatFits:CGSizeMake(inner, 200)];
        _error.frame = CGRectMake(30, y + 12, inner, es.height), y += es.height + 12;
    }
    y += 30;
    _card.frame = CGRectMake((b.size.width - w) / 2, (b.size.height - y) / 2, w, y);
}
- (void)pick {
    UTType *xci = [UTType typeWithFilenameExtension:@"xci"] ?: UTTypeData;
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[xci, UTTypeData] asCopy:NO];
    p.delegate = self;
    p.allowsMultipleSelection = NO;
    [_host presentViewController:p animated:YES completion:nil];
}
- (void)useLocal {
    [self check:[[NSFileManager.defaultManager currentDirectoryPath] stringByAppendingPathComponent:_localXci] bookmark:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject;
    if (!u) return;
    if (![u.pathExtension.lowercaseString isEqualToString:@"xci"]) { [self fail:@"That isn't an .xci file."]; return; }
    if (![u startAccessingSecurityScopedResource]) { [self fail:@"The file couldn't be opened."]; return; }
    [self check:u.path bookmark:[u bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil]];
}
- (void)fail:(NSString *)msg {
    _error.text = msg;
    [_spin stopAnimating];
    _choose.enabled = YES, _choose.alpha = 1;
    [self setNeedsLayout];
}
// The file must be an .xci the runtime can open, holding the game's title layout.
- (void)check:(NSString *)path bookmark:(NSData *)bm {
    _error.text = @"";
    _choose.enabled = NO, _choose.alpha = 0.6;
    [_spin startAnimating];
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
            if (!ok) { [self fail:k ? @"That file isn't Tomodachi Life: Living the Dream (or it couldn't be read)." : @"prod.keys is missing."]; return; }
            if (bm) [ud() setObject:bm forKey:@"xci"];
            [ud() setBool:NO forKey:kUnmounted];
            setenv("NXRT_XCI", path.fileSystemRepresentation, 1);
            nx_log("launcher: ROM added: %s", path.UTF8String);
            [self->_spin stopAnimating];
            self->_done(path);
        });
    });
}
@end
UIView *nx_rom_view(UIViewController *host, void (^done)(NSString *xci)) {
    return [[NxRomView alloc] initWithHost:host done:done];
}

// ---- Slot card --------------------------------------------------------------------------------------------------
// A cream cloud. With a snapshot: the picture fills the cloud (cloud-shaped, 6 pt in) and a cream tag on the lower edge
// carries the name and residents. Without one: name, last played, residents in text.
// A new slot: an orange plus and "New island".
@interface NxSlotCard : UIView
@property(nonatomic) int slot;
@property(nonatomic) BOOL chosen;
- (void)refresh;
- (void)squash;
@end
@implementation NxSlotCard {
    UIView *_body;                       // everything but the ring's shadow room; bobs when chosen
    UIImageView *_ring, *_cloud, *_photo;
    UILabel *_name, *_status, *_size, *_plus;
    UIView *_tag;                        // with a snapshot: name · residents
    UILabel *_tagText;
}
- (instancetype)initWithSlot:(int)slot {
    self = [super initWithFrame:CGRectZero];
    _slot = slot;
    NxUI *ui = NxUI.shared;
    _body = [UIView new];
    [self addSubview:_body];
    _ring = [[UIImageView alloc] initWithImage:tinted(ui.cloud, orange())];
    _cloud = [[UIImageView alloc] initWithImage:tinted(ui.cloud, rgb(0xFFF2CA, 1))];
    _ring.alpha = 0;
    _cloud.layer.shadowColor = UIColor.blackColor.CGColor, _cloud.layer.shadowOpacity = 0.16f, _cloud.layer.shadowRadius = 10;
    _cloud.layer.shadowOffset = CGSizeMake(0, 5);
    _photo = [UIImageView new];
    _photo.contentMode = UIViewContentModeScaleAspectFill;
    _photo.maskView = [[UIImageView alloc] initWithImage:ui.cloud];
    [_body addSubview:_ring], [_body addSubview:_cloud], [_body addSubview:_photo];
    _name = [UILabel new], _status = [UILabel new], _size = [UILabel new], _plus = [UILabel new];
    _name.font = [ui font:17 bold:YES], _name.textColor = navy(1);
    _status.font = [ui font:12 bold:NO];
    _size.font = [ui font:11 bold:NO], _size.textColor = navy(0.5);
    _plus.font = [ui font:28 bold:YES], _plus.textColor = orange(), _plus.text = @"+";
    for (UILabel *l in @[_name, _status, _size, _plus]) l.textAlignment = NSTextAlignmentCenter, l.adjustsFontSizeToFitWidth = YES, [_body addSubview:l];
    _tag = [UIView new];
    _tag.backgroundColor = rgb(0xFFF2CA, 0.95), _tag.layer.cornerRadius = 12;
    _tag.layer.shadowColor = UIColor.blackColor.CGColor, _tag.layer.shadowOpacity = 0.12f, _tag.layer.shadowRadius = 4, _tag.layer.shadowOffset = CGSizeMake(0, 2);
    _tagText = [UILabel new];
    _tagText.textAlignment = NSTextAlignmentCenter, _tagText.adjustsFontSizeToFitWidth = YES, _tagText.minimumScaleFactor = 0.7;
    [_tag addSubview:_tagText];
    [_body addSubview:_tag];
    self.isAccessibilityElement = YES, self.accessibilityTraits = UIAccessibilityTraitButton;
    [self refresh];
    return self;
}
- (void)refresh {
    SlotInfo si = slot_info(_slot);
    int residents = si.files ? slot_residents(_slot) : -1;
    NSString *res = residents == 0 ? @"No residents yet" : residents == 1 ? @"1 resident"
                  : residents > 1 ? [NSString stringWithFormat:@"%d residents", residents] : nil;
    UIImage *snap = si.files ? slot_snapshot(_slot) : nil;
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
    [_status.layer removeAllAnimations];
    _status.alpha = 1;
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
    [self setNeedsLayout];   // the tag's width follows its text
}
- (void)setChosen:(BOOL)chosen {
    BOOL was = _chosen;
    _chosen = chosen;
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{ self->_ring.alpha = chosen ? 1 : 0; } completion:nil];
    self.accessibilityTraits = UIAccessibilityTraitButton | (chosen ? UIAccessibilityTraitSelected : 0);
    if (chosen && !was) {   // the chosen cloud floats: 0 -> -4 pt, 1.6 s each way
        CABasicAnimation *bob = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
        bob.fromValue = @0, bob.toValue = @-4, bob.duration = 1.6, bob.autoreverses = YES, bob.repeatCount = HUGE_VALF;
        bob.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        bob.additive = YES, bob.removedOnCompletion = NO;
        [_body.layer addAnimation:bob forKey:@"bob"];
    } else if (!chosen && was) {
        [_body.layer removeAnimationForKey:@"bob"];
    }
}
// A tap: squash to (1.06, 0.94) in 0.08 s, spring back.
- (void)squash {
    [UIView animateWithDuration:0.08 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.transform = CGAffineTransformMakeScale(1.06, 0.94);
    } completion:^(BOOL done) {
        [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ self.transform = CGAffineTransformIdentity; } completion:nil];
    }];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    _body.frame = b;
    _cloud.frame = b;
    _ring.frame = CGRectInset(b, -6, -6);
    _photo.frame = CGRectInset(b, 6, 6);
    _photo.maskView.frame = _photo.bounds;
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
@interface NxLauncherView : UIView <UIContextMenuInteractionDelegate>
@end
@implementation NxLauncherView {
    __weak UIViewController *_host;
    void (^_start)(void), (^_resume)(void), (^_removeRom)(void);
    NSString *_running;   // resume mode: settings_key of the running game
    UIImageView *_logo;
    UIButton *_gear, *_go, *_news, *_feedback;
    UIView *_badge;                       // the news button's dot: a newer version is out
    UILabel *_goLabel, *_time, *_date;
    CALayer *_drift, *_tile, *_stars;     // background: drifting squiggle tiles, night sparkles
    UIColor *_shown;                      // the background colour on screen
    CGSize _starSize;                     // the size the sparkles were placed for
    BOOL _appeared;
    UIControl *_join, *_share;            // online play: "Coming soon" for now
    NSArray<NxSlotCard *> *_cards;
    int _slot;
}
- (instancetype)initWithHost:(UIViewController *)host running:(NSString *)running start:(void (^)(void))start resume:(void (^)(void))resume
                   removeRom:(void (^)(void))removeRom {
    self = [super initWithFrame:CGRectZero];
    _host = host, _start = start, _resume = resume, _removeRom = removeRom, _running = running;
    host.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;   // the game's palette in Settings / alerts too
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    NxUI *ui = NxUI.shared;
    _slot = (int)[ud() integerForKey:kSlot];
    if (_slot < 1 || _slot > 3) _slot = 1;
    [self setupBackground];
    _logo = [[UIImageView alloc] initWithImage:ui.logo];
    _logo.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:_logo];
    _gear = [UIButton buttonWithType:UIButtonTypeCustom];
    // The circle texture is 70x78 px with the circle in its top 52x52 (the rest is shadow room): scale that part to the button.
    UIImageView *ring = [[UIImageView alloc] initWithImage:tinted(ui.circle, UIColor.whiteColor)];
    ring.frame = CGRectMake(-9 * 48 / 52.0, -9 * 48 / 52.0, 70 * 48 / 52.0, 78 * 48 / 52.0);
    ring.userInteractionEnabled = NO;
    UIImageView *gear = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"gearshape.fill" withConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightBold]] imageWithTintColor:navy(1) renderingMode:UIImageRenderingModeAlwaysOriginal]];
    gear.frame = CGRectMake(0, 0, 48, 48), gear.contentMode = UIViewContentModeCenter, gear.userInteractionEnabled = NO;
    [_gear addSubview:ring], [_gear addSubview:gear];   // circle, then the gear on top, both centred in the 48 pt button
    _gear.accessibilityLabel = @"Settings";
    [_gear addTarget:self action:@selector(settings) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_gear];
    _news = [self circleButton:@"newspaper.fill" label:@"News" action:@selector(openNews)];
    _feedback = [self circleButton:@"bubble.left.fill" label:@"Feedback" action:@selector(openFeedback)];
    _badge = [[UIView alloc] initWithFrame:CGRectMake(34, 0, 12, 12)];
    _badge.backgroundColor = rgb(0xFF2E00, 1), _badge.layer.cornerRadius = 6, _badge.layer.borderWidth = 2, _badge.layer.borderColor = UIColor.whiteColor.CGColor;
    _badge.hidden = YES, _badge.userInteractionEnabled = NO;
    [_news addSubview:_badge];
    _time = [UILabel new], _date = [UILabel new];
    _time.textAlignment = _date.textAlignment = NSTextAlignmentRight;
    _date.font = [ui font:15 bold:NO];
    for (UILabel *c in @[_time, _date])
        c.layer.shadowColor = UIColor.blackColor.CGColor, c.layer.shadowRadius = 6, c.layer.shadowOffset = CGSizeMake(0, 2), [self addSubview:c];
    [self updateClock];
    NSMutableArray *cards = [NSMutableArray array];
    for (int s = 1; s <= 3; s++) {
        NxSlotCard *c = [[NxSlotCard alloc] initWithSlot:s];
        [c addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cardTap:)]];
        if (!running) [c addInteraction:[[UIContextMenuInteraction alloc] initWithDelegate:self]];   // not under a running game
        [self addSubview:c];
        [cards addObject:c];
    }
    _cards = cards;
    _go = [UIButton buttonWithType:UIButtonTypeCustom];
    [_go setBackgroundImage:tinted(ui.pill, rgb(0xFF2E00, 1)) forState:UIControlStateNormal];
    if (!ui.pill) _go.backgroundColor = rgb(0xFF2E00, 1), _go.layer.cornerRadius = 29;
    _go.layer.shadowColor = rgb(0xA31D00, 1).CGColor, _go.layer.shadowOpacity = 0.35f, _go.layer.shadowRadius = 0, _go.layer.shadowOffset = CGSizeMake(0, 4);
    _goLabel = [UILabel new];
    _goLabel.font = [ui font:21 bold:YES], _goLabel.textColor = UIColor.whiteColor, _goLabel.textAlignment = NSTextAlignmentCenter;
    _goLabel.adjustsFontSizeToFitWidth = YES;
    [_go addSubview:_goLabel];
    [_go addTarget:self action:@selector(goDown) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [_go addTarget:self action:@selector(goUp) forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
    [_go addTarget:self action:@selector(go) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_go];
    [self breathe:YES];
    if (!running) {
        _join = nx_game_button(2, @"Join a shared island", nx_ui_texture(@"icon_room"));
        _share = nx_game_button(1, @"Share island", nil);
        for (UIControl *b in @[_join, _share]) [b addTarget:self action:@selector(comingSoon) forControlEvents:UIControlEventTouchUpInside], [self addSubview:b];
    }
    [self choose:_slot];
    const char *auto_s = getenv("NXRT_LAUNCHER_AUTOSTART");
    if (auto_s) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(atof(auto_s) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self go]; });
    if (getenv("NXRT_LAUNCHER_SHOW") && !strcmp(getenv("NXRT_LAUNCHER_SHOW"), "settings"))
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ [self settings]; });
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    UIEdgeInsets sa = self.safeAreaInsets;
    CGFloat l = sa.left + 18, r = b.size.width - sa.right - 18, top = sa.top + 6, bottom = b.size.height - MAX(sa.bottom, 8);
    CGFloat lh = 160, lw = lh * 420 / 360;
    _logo.frame = CGRectMake(l, top, lw, lh);
    // Clock top right (time over date), the gear 14 pt to its left
    CGFloat tw = [_time sizeThatFits:CGSizeMake(400, 60)].width, dw = [_date sizeThatFits:CGSizeMake(400, 30)].width, cw0 = MAX(tw, dw);
    _time.frame = CGRectMake(r - cw0, top + 4, cw0, 50);
    _date.frame = CGRectMake(r - cw0, top + 52, cw0, 20);
    _gear.frame = CGRectMake(r - cw0 - 14 - 48, top + 8, 48, 48);
    _news.frame = CGRectOffset(_gear.frame, -14 - 48, 0);
    _feedback.frame = CGRectOffset(_news.frame, -14 - 48, 0);
    // Join: centred between the logo and the gear
    CGFloat jx0 = CGRectGetMaxX(_logo.frame) + 12, jx1 = CGRectGetMinX(_feedback.frame) - 12, jw = MIN(280, jx1 - jx0);
    _join.frame = CGRectMake((jx0 + jx1 - jw) / 2, top + 14, jw, 44);
    CGFloat goy = bottom - 14 - 58;
    _go.frame = CGRectMake((b.size.width - 250) / 2, goy, 250, 58);
    _goLabel.frame = CGRectInset(_go.bounds, 24, 0);
    _share.frame = CGRectMake(CGRectGetMaxX(_go.frame) + 14, goy + 4, 170, 50);
    // The saves: a row of small clouds just above the buttons
    CGFloat cw = MIN(170, (r - l - 24) / 3), ch = 112, x0 = (b.size.width - (cw * 3 + 24)) / 2, cy = goy - 18 - ch;
    for (int i = 0; i < 3; i++) {
        CGAffineTransform t = _cards[i].transform;   // frames are set untransformed (pop-in / squash scale them)
        _cards[i].transform = CGAffineTransformIdentity;
        _cards[i].frame = CGRectMake(x0 + i * (cw + 12), cy, cw, ch);
        _cards[i].transform = t;
    }
    [self layoutBackground];
}
// The squiggle tile in a colour, as a bitmap (a tinted UIImage's CGImage is still the untinted mask).
static UIImage *pattern_tile(UIImage *p, UIColor *c) {
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat preferredFormat];
    f.scale = p.scale, f.opaque = NO;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:p.size format:f] imageWithActions:^(UIGraphicsImageRendererContext *x) {
        [tinted(p, c) drawAtPoint:CGPointZero];
    }];
}
// ---- background, clock -----------------------------------------------------------------------------------------
// The time of day's colour; the squiggles (one 240 pt tile, repeated) drift down-right at 12 pt/s (a tile per 20 s);
// from 20:00 to 5:00, 12 sparkles twinkle in the empty areas.
- (void)setupBackground {
    _shown = day_color();
    self.backgroundColor = _shown;
    _drift = [CALayer new];
    UIImage *p = NxUI.shared.pattern;
    if (p) {
        _tile = [CALayer new];
        _tile.frame = CGRectMake(0, 0, p.size.width, p.size.height);
        _tile.contents = (__bridge id)pattern_tile(p, pattern_color(_shown)).CGImage;
        CAReplicatorLayer *rx = [CAReplicatorLayer new], *ry = [CAReplicatorLayer new];
        rx.instanceCount = 9, rx.instanceTransform = CATransform3DMakeTranslation(p.size.width, 0, 0);
        ry.instanceCount = 7, ry.instanceTransform = CATransform3DMakeTranslation(0, p.size.height, 0);
        [rx addSublayer:_tile], [ry addSublayer:rx], [_drift addSublayer:ry];
    }
    _stars = [CALayer new];
    [self.layer insertSublayer:_drift atIndex:0];
    [self.layer insertSublayer:_stars above:_drift];
}
- (void)layoutBackground {
    CGSize t = _tile ? _tile.bounds.size : CGSizeMake(240, 240);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _drift.frame = CGRectMake(-t.width, -t.height, t.width * 9, t.height * 7);
    _stars.frame = self.bounds;
    [CATransaction commit];
    if (![_drift animationForKey:@"drift"]) {
        CABasicAnimation *d = [CABasicAnimation animationWithKeyPath:@"transform.translation"];
        d.fromValue = [NSValue valueWithCGSize:CGSizeZero], d.toValue = [NSValue valueWithCGSize:t];
        d.duration = t.width / 12, d.repeatCount = HUGE_VALF, d.removedOnCompletion = NO;
        d.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [_drift addAnimation:d forKey:@"drift"];
    }
    if (!CGSizeEqualToSize(_starSize, self.bounds.size)) _starSize = self.bounds.size, [self placeStars];   // once per size
}
// Sparkles at fixed pseudo-random spots that stay clear of the logo, clock, buttons and clouds.
- (void)placeStars {
    for (CALayer *s in [_stars.sublayers copy]) [s removeFromSuperlayer];
    NSMutableArray<NSValue *> *busy = [NSMutableArray array];
    for (UIView *v in @[_logo, _time, _date, _gear, _news, _feedback, _go]) [busy addObject:[NSValue valueWithCGRect:CGRectInset(v.frame, -10, -10)]];
    if (_join) [busy addObject:[NSValue valueWithCGRect:CGRectInset(_join.frame, -10, -10)]];
    if (_share) [busy addObject:[NSValue valueWithCGRect:CGRectInset(_share.frame, -10, -10)]];
    for (UIView *v in _cards) [busy addObject:[NSValue valueWithCGRect:CGRectInset(v.frame, -14, -14)]];
    unsigned short seed[3] = {7, 13, 21};
    CGSize sz = self.bounds.size;
    for (int n = 0, tries = 0; n < 12 && tries < 400; tries++) {
        CGPoint c = CGPointMake(erand48(seed) * sz.width, erand48(seed) * sz.height);
        CGFloat rr = 2.5 + 1.5 * erand48(seed);   // 5-8 pt across
        BOOL hit = NO;
        for (NSValue *v in busy) hit |= CGRectContainsPoint(v.CGRectValue, c);
        if (hit) continue;
        UIBezierPath *p = [UIBezierPath bezierPath];   // four-point sparkle
        [p moveToPoint:CGPointMake(0, -rr)];
        [p addQuadCurveToPoint:CGPointMake(rr, 0) controlPoint:CGPointZero];
        [p addQuadCurveToPoint:CGPointMake(0, rr) controlPoint:CGPointZero];
        [p addQuadCurveToPoint:CGPointMake(-rr, 0) controlPoint:CGPointZero];
        [p addQuadCurveToPoint:CGPointMake(0, -rr) controlPoint:CGPointZero];
        CAShapeLayer *s = [CAShapeLayer new];
        s.path = p.CGPath, s.fillColor = UIColor.whiteColor.CGColor, s.position = c, s.opacity = 0.15f;
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
// Now (or NXRT_LAUNCHER_HOUR today).
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
    UIColor *ink = dark ? UIColor.whiteColor : navy(1);
    NSString *ts = [tf stringFromDate:now];
    NSMutableAttributedString *t = [[NSMutableAttributedString alloc] initWithString:ts
        attributes:@{NSFontAttributeName : [NxUI.shared font:44 bold:YES], NSForegroundColorAttributeName : ink}];
    for (NSString *sym in @[tf.AMSymbol, tf.PMSymbol]) {   // AM / PM smaller
        NSRange rg = [ts rangeOfString:sym];
        if (rg.location != NSNotFound) [t addAttribute:NSFontAttributeName value:[NxUI.shared font:20 bold:YES] range:rg];
    }
    _time.attributedText = t;
    _date.text = [df stringFromDate:now];
    _date.textColor = [ink colorWithAlphaComponent:0.75];
    for (UILabel *c in @[_time, _date]) c.layer.shadowOpacity = dark ? 0.25f : 0;
    [self setNeedsLayout];
}
// Every 5 s: the clock; the background colour when it moved (2 s fade), the sparkles, the music's part of the day.
- (void)tick {
    UIColor *c = day_color();
    CGFloat r0, g0, b0, a0, r1, g1, b1, a1;
    [_shown getRed:&r0 green:&g0 blue:&b0 alpha:&a0], [c getRed:&r1 green:&g1 blue:&b1 alpha:&a1];
    if (fabs(r0 - r1) + fabs(g0 - g1) + fabs(b0 - b1) > 1.5 / 255) {
        _shown = c;
        [UIView animateWithDuration:2 animations:^{ self.backgroundColor = c; }];
        [CATransaction begin];
        [CATransaction setAnimationDuration:2];
        if (_tile) _tile.contents = (__bridge id)pattern_tile(NxUI.shared.pattern, pattern_color(c)).CGImage;
        double h = day_hour();
        _stars.opacity = h >= 20 || h < 5 ? 1 : 0;
        [CATransaction commit];
    }
    [self updateClock];
    music_follow_time();
}
// Start breathes: scale 1.0 <-> 1.03, 1.4 s each way (off while pressed).
- (void)breathe:(BOOL)on {
    if (!on) { [_go.layer removeAnimationForKey:@"breathe"]; return; }
    CABasicAnimation *br = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    br.fromValue = @1.0, br.toValue = @1.03, br.duration = 1.4, br.autoreverses = YES, br.repeatCount = HUGE_VALF;
    br.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    br.removedOnCompletion = NO;
    [_go.layer addAnimation:br forKey:@"breathe"];
}
// While the launcher is on screen: the clock and colours every 5 s. The first time: the clouds pop in.
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) return;
    if (!_appeared) {
        _appeared = YES;
        [self checkNews];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self offerCrashReport]; });
        for (int i = 0; i < 3; i++) {   // scale 0.6 -> 1, fade in, spring 0.55 s, 0.07 s apart
            NxSlotCard *c = _cards[i];
            c.alpha = 0, c.transform = CGAffineTransformMakeScale(0.6, 0.6);
            [UIView animateWithDuration:0.55 delay:0.1 + 0.07 * i usingSpringWithDamping:0.6 initialSpringVelocity:0.8 options:0
                             animations:^{ c.alpha = 1, c.transform = CGAffineTransformIdentity; } completion:nil];
        }
    }
    __weak NxLauncherView *ws = self;
    [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *t) {
        NxLauncherView *s = ws;
        if (!s || !s.window) { [t invalidate]; return; }
        [s tick];
    }];
}
- (void)choose:(int)slot {
    _slot = slot;
    for (NxSlotCard *c in _cards) c.chosen = c.slot == slot;
    [ud() setInteger:slot forKey:kSlot];
    BOOL fresh = slot_info(slot).files == 0;
    _goLabel.text = fresh ? @"Start new island" : [@"Start " stringByAppendingString:slot_title(slot)];
    _share.hidden = fresh;
}
// Join / Share: online play isn't in this version yet.
- (void)comingSoon {
    sfx(@"open");
    nx_game_dialog(@"Coming soon", @"Sharing an island with a friend and playing Local Play online will come in a later update.",
                   @"OK", nil, self, ^(BOOL m) { sfx(@"close"); });
}
- (void)cardTap:(UITapGestureRecognizer *)g {
    sfx(@"tap");
    [(NxSlotCard *)g.view squash];
    [self choose:((NxSlotCard *)g.view).slot];
}
- (void)goDown {
    [self breathe:NO];
    [UIView animateWithDuration:0.1 animations:^{ self->_go.transform = CGAffineTransformMakeScale(0.95, 0.95); }];
}
- (void)goUp {
    [UIView animateWithDuration:0.1 animations:^{ self->_go.transform = CGAffineTransformIdentity; }
                     completion:^(BOOL done) { if (self.window) [self breathe:YES]; }];
}
// Into the game: a bank of cream clouds crosses the screen left to right (0.45 s ease-in), the launcher goes under it,
// then the bank slides off to the right (0.45 s ease-out).
- (void)fadeOut {
    UIView *host = self.superview;
    if (!host) return;
    CGFloat W = host.bounds.size.width, H = host.bounds.size.height, R = H / 4;   // R: a puff's radius
    UIColor *cream = rgb(0xFFF2CA, 1);
    UIView *bank = [[UIView alloc] initWithFrame:CGRectMake(-(W + 2 * R), 0, W + 2 * R, H)];
    UIView *fill = [[UIView alloc] initWithFrame:CGRectMake(R, 0, W, H)];
    fill.backgroundColor = cream;
    [bank addSubview:fill];
    UIImage *puff = NxUI.shared.cloud ? tinted(NxUI.shared.cloud, cream) : nil;
    for (int edge = 0; edge < 2; edge++)
        for (int i = 0; i <= 4; i++) {   // puffs along both edges, alternately a little in and out
            CGFloat d = 2 * R * (1.25 + 0.15 * (i % 2)), x = edge ? W + R - (i % 2) * R * 0.25 : R + (i % 2) * R * 0.25;
            UIView *p = puff ? [[UIImageView alloc] initWithImage:puff] : [UIView new];
            p.frame = CGRectMake(x - d / 2, i * H / 4 - d / 2, d, d);
            if (!puff) p.backgroundColor = cream, p.layer.cornerRadius = d / 2;
            [bank addSubview:p];
        }
    [host addSubview:bank];
    [UIView animateWithDuration:0.45 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        bank.frame = CGRectOffset(bank.bounds, -R, 0);
    } completion:^(BOOL done) {
        [self removeFromSuperview];
        [UIView animateWithDuration:0.45 delay:0.05 options:UIViewAnimationOptionCurveEaseOut animations:^{
            bank.frame = CGRectOffset(bank.bounds, W + R, 0);
        } completion:^(BOOL d2) { [bank removeFromSuperview]; }];
    }];
}
- (void)go {
    sfx(@"start");
    [self goUp];
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
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Restart needed"
            message:[NSString stringWithFormat:@"%@ starts the next time you open the app. Close the game now?", slot_title(slot)]
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"Close Game" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [ud() setInteger:slot forKey:kAutostart];
            [ud() synchronize];
            nx_log("launcher: island %d chosen from the title screen: closing for a fresh start", slot);
            exit(0);
        }]];
        [_host presentViewController:a animated:YES completion:nil];
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
// A 48 pt white circle with an SF Symbol, like the gear.
- (UIButton *)circleButton:(NSString *)symbol label:(NSString *)label action:(SEL)action {
    NxUI *ui = NxUI.shared;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    UIImageView *ring = [[UIImageView alloc] initWithImage:tinted(ui.circle, UIColor.whiteColor)];
    ring.frame = CGRectMake(-9 * 48 / 52.0, -9 * 48 / 52.0, 70 * 48 / 52.0, 78 * 48 / 52.0);
    ring.userInteractionEnabled = NO;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:symbol withConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightBold]] imageWithTintColor:navy(1) renderingMode:UIImageRenderingModeAlwaysOriginal]];
    icon.frame = CGRectMake(0, 0, 48, 48), icon.contentMode = UIViewContentModeCenter, icon.userInteractionEnabled = NO;
    [b addSubview:ring], [b addSubview:icon];
    b.accessibilityLabel = label;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b];
    return b;
}
// The launcher asks for the news once: the dot when a newer version is out. After a crash the next launch offers a report.
- (void)checkNews {
    __weak NxLauncherView *ws = self;
    nx_news_fetch(^(NSDictionary *news) {
        NxLauncherView *s = ws;
        if (s) s->_badge.hidden = !(news && nx_news_update_available(news));
    });
}
- (void)offerCrashReport {
    static BOOL asked;
    if (asked || !nx_last_session_crashed()) return;
    asked = YES;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"The game closed unexpectedly"
                                                               message:@"Send a crash report? It includes the game log, never your saves."
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Not now" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Send report" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self openFeedbackKind:@"crash"]; }]];
    [_host presentViewController:a animated:YES completion:nil];
}
- (void)openNews {
    sfx(@"open");
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[NxNewsController new]];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [_host presentViewController:nav animated:YES completion:nil];
}
- (void)openFeedback { [self openFeedbackKind:nil]; }
- (void)openFeedbackKind:(NSString *)kind {
    sfx(@"open");
    NxFeedbackController *f = [NxFeedbackController new];
    f.kind = kind;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:f];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [_host presentViewController:nav animated:YES completion:nil];
}
- (void)settings {
    sfx(@"open");
    NxSettingsController *s = [NxSettingsController new];
    s.runningSlot = _running ? (int)[ud() integerForKey:kSlot] : 0;
    __weak NxLauncherView *wl = self;
    s.islandsChanged = ^{ [wl islandsChanged]; };
    if (_removeRom) {
        void (^rm)(void) = _removeRom;
        __weak NxLauncherView *ws = self;
        s.removeRom = ^{
            [ws removeFromSuperview];
            rm();
        };
    }
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:s];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [_host presentViewController:nav animated:YES completion:nil];
}
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)cmi configurationForMenuAtLocation:(CGPoint)loc {
    NxSlotCard *card = (NxSlotCard *)cmi.view;
    int slot = card.slot;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested) {
        UIAction *ren = [UIAction actionWithTitle:@"Rename" image:[UIImage systemImageNamed:@"pencil"] identifier:nil
                                          handler:^(UIAction *a) { [self rename:card]; }];
        UIAction *del = [UIAction actionWithTitle:@"Delete Island" image:[UIImage systemImageNamed:@"trash"]
                                       identifier:nil handler:^(UIAction *a) { [self remove:card]; }];
        del.attributes = UIMenuElementAttributesDestructive;
        if (!slot_info(slot).files) del.attributes |= UIMenuElementAttributesDisabled;
        return [UIMenu menuWithTitle:@"" children:@[ren, del]];
    }];
}
// The lifted card: only the cloud (iOS's default preview puts it on a white rounded rectangle with its own shadow).
- (UITargetedPreview *)cardPreview:(UIContextMenuInteraction *)cmi {
    UIPreviewParameters *p = [UIPreviewParameters new];
    p.backgroundColor = UIColor.clearColor;
    p.shadowPath = [UIBezierPath bezierPath];   // the cloud keeps its own shadow
    p.visiblePath = [UIBezierPath bezierPathWithRect:CGRectInset(cmi.view.bounds, -24, -24)];   // room for that shadow
    return [[UITargetedPreview alloc] initWithView:cmi.view parameters:p];
}
- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)cmi configuration:(UIContextMenuConfiguration *)c
       highlightPreviewForItemWithIdentifier:(id<NSCopying>)ident {
    return [self cardPreview:cmi];
}
- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)cmi configuration:(UIContextMenuConfiguration *)c
         dismissalPreviewForItemWithIdentifier:(id<NSCopying>)ident {
    return [self cardPreview:cmi];
}
- (void)rename:(NxSlotCard *)card {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Rename" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = slot_title(card.slot), tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *n = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        [ud() setObject:n forKey:[NSString stringWithFormat:@"nx.slotname.%d", card.slot]];
        [card refresh];
        [self choose:self->_slot];
    }]];
    [_host presentViewController:a animated:YES completion:nil];
}
// Delete (island_remove_flow: asks twice).
- (void)remove:(NxSlotCard *)card {
    __weak NxLauncherView *ws = self;
    island_remove_flow(_host, card.slot, ^{ [ws islandsChanged]; });
}
- (void)islandsChanged {
    for (NxSlotCard *c in _cards) [c refresh];
    [self choose:_slot];
}
@end

// The game's assets (decoded once, then cached) on a background thread, then the island select (main thread).
void nx_launcher_show(UIViewController *host, BOOL running, void (^start)(void), void (^resume)(void), void (^removeRom)(void),
                      void (^shown)(UIView *v)) {
    NSString *xci = @(getenv("NXRT_XCI") ?: ""), *keys = @(getenv("NXRT_KEYS") ?: "");
    NSString *run = running ? settings_key((int)[ud() integerForKey:kSlot]) : nil;
    void (^make)(void) = ^{
        NxLauncherView *v = [[NxLauncherView alloc] initWithHost:host running:run start:start resume:resume removeRom:running ? nil : removeRom];
        shown(v);
        music_launcher(2.0);
    };
    if (NxUI.shared.ready) { make(); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [NxUI.shared loadForXci:xci keys:keys];   // falls back to system fonts / plain colours when incomplete
        dispatch_async(dispatch_get_main_queue(), make);
    });
}
