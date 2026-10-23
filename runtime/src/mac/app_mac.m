// Mac app shell (the AppKit twin of ios/app_ios.m): one window holding the game's CAMetalLayer and, over it, the
// launcher (launcher_mac.m) before the game starts or over the paused title screen. In game: the mouse is the touch
// screen, the keyboard / a game controller are Player 1, an "Islands" pill shows while the title screen is up, plus the
// FPS counter (Settings).
// NXRT_LAUNCHER=0 (or NXRT_HEADLESS): the old start, straight into the game with the shell's settings.
#import <Cocoa/Cocoa.h>
#import <GameController/GameController.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <crt_externs.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <unistd.h>

#include "../gfx_internal.h"
#include "nxrt.h"
#import "ui_mac.h"

void gfx_attach_layer(CAMetalLayer *layer);
void nx_hid_set_buttons(uint64_t buttons);
void nx_hid_set_stick(int x, int y);
int nx_game_width(void), nx_game_height(void);
int nx_ui_flags(void);   // ui_touch.c: bit 1 = the title screen is up
void nx_apply_mode(void);
int nx_launcher_enabled(void), nx_launcher_fps_counter(void), nx_launcher_wide(void), nx_launcher_take_autostart(void), nx_launcher_fullscreen(void);
void nx_launcher_paths(void);
void nx_launcher_show(BOOL running, void (^start)(void), void (^resume)(void), void (^removeRom)(void), void (^shown)(NSView *v));
NSView *nx_rom_view(void (^done)(NSString *xci));
void nx_rom_forget(void);
extern volatile int g_gfx_frame;

static void (*g_guest_main)(void);
static NSWindow *g_win;
static NSView *g_root, *g_game;          // the game: a layer-hosting view with the CAMetalLayer, aspect-fit in the window
static CAMetalLayer *g_layer;
static NxCanvas *g_canvas;               // the launcher / ROM screen (whole window)
static NxCanvas *g_overlay;              // in-game pills and banner (over the game's picture, clicks pass through)
static NSView *g_launcher, *g_rom, *g_islands, *g_back, *g_fps;
static NSProgressIndicator *g_spin;
static int g_started;                    // 0 not yet, 2 running
static BOOL g_paused;                    // the game is paused under the launcher
static char **g_env0;                    // the environment at launch (a relaunch starts from it, not the launcher's choices)
static uint64_t g_key_buttons, g_pad_buttons;
static int g_key_stick[2], g_pad_stick[2];

// Settings > Full screen, applied at once.
void nx_mac_set_fullscreen(int on) {
    if (getenv("NXRT_UITEST_QUIET")) return;
    if (!!(g_win.styleMask & NSWindowStyleMaskFullScreen) != !!on) [g_win toggleFullScreen:nil];
}
// The app bundle (make app) knows the game's folder (Info.plist NxrtHome = runtime/, set at build time): opened from
// the Finder (no arguments, cwd /), the game runs from there with ../work, and its log goes to runtime/nxrt.log.
const char *nx_mac_bundle_home(void) {
    @autoreleasepool {
        NSString *h = NSBundle.mainBundle.infoDictionary[@"NxrtHome"];
        return [h isKindOfClass:NSString.class] && h.length ? strdup(h.fileSystemRepresentation) : NULL;
    }
}

// ---- relaunch ------------------------------------------------------------------------------------------------------
// An island picked over the paused title screen that needs a fresh start: the process replaces itself (same arguments,
// the launch environment); the launcher then starts the island straight away (nx.autostart).
void nx_mac_relaunch(void) {
    char path[4096];
    uint32_t n = sizeof path;
    if (_NSGetExecutablePath(path, &n)) { nx_log("mac: relaunch: no executable path"); exit(0); }
    fflush(stderr);
    execve(path, *_NSGetArgv(), g_env0);
    nx_log("mac: relaunch failed: %s", strerror(errno));
    exit(0);
}

// ---- input -----------------------------------------------------------------------------------------------------------
// Keyboard + controller -> Player 1 (both at once). The stick's direction bits (16-19, as a real stick sets them)
// follow whichever stick is pushed.
static void send_pad(void) {
    int x = g_pad_stick[0] ? g_pad_stick[0] : g_key_stick[0], y = g_pad_stick[1] ? g_pad_stick[1] : g_key_stick[1];
    uint64_t dir = (x < -16384 ? 1ull << 16 : 0) | (y > 16384 ? 1ull << 17 : 0) | (x > 16384 ? 1ull << 18 : 0) | (y < -16384 ? 1ull << 19 : 0);
    nx_hid_set_buttons(g_key_buttons | g_pad_buttons | dir);
    nx_hid_set_stick(x, y);
}
// Game controller -> Player 1 (Nintendo layout: A is the right face button).
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
    send_pad();
}
static BOOL game_has_input(void) { return g_started == 2 && !g_paused && !g_win.attachedSheet; }

// Keyboard -> Player 1: arrows D-pad, WASD left stick, K/J/I/U = A/B/X/Y (Escape = B too), Q/E = L/R, 1/3 = ZL/ZR,
// Return = Plus, Tab = Minus. Only while the game has the window (the launcher and dialogs type normally); key ups
// always release.
static NSEvent *key_event(NSEvent *ev) {
    int down = ev.type == NSEventTypeKeyDown;
    if (ev.window != g_win || (down && (!game_has_input() || (ev.modifierFlags & NSEventModifierFlagCommand)))) return ev;
    static int sx[4];   // A, D, S, W held
    uint64_t bit = 0;
    int stick = -1;
    switch (ev.keyCode) {
    case 40: bit = 1 << 0; break;  case 38: case 53: bit = 1 << 1; break;   // K A, J / Escape B
    case 34: bit = 1 << 2; break;  case 32: bit = 1 << 3; break;           // I X, U Y
    case 12: bit = 1 << 6; break;  case 14: bit = 1 << 7; break;           // Q L, E R
    case 18: bit = 1 << 8; break;  case 20: bit = 1 << 9; break;           // 1 ZL, 3 ZR
    case 36: bit = 1 << 10; break; case 48: bit = 1 << 11; break;          // Return Plus, Tab Minus
    case 123: bit = 1 << 12; break; case 126: bit = 1 << 13; break;        // arrows: D-pad
    case 124: bit = 1 << 14; break; case 125: bit = 1 << 15; break;
    case 0: stick = 0; break; case 2: stick = 1; break; case 1: stick = 2; break; case 13: stick = 3; break;
    default: return ev;
    }
    if (bit) g_key_buttons = down ? g_key_buttons | bit : g_key_buttons & ~bit;
    if (stick >= 0) sx[stick] = down;
    g_key_stick[0] = (sx[1] - sx[0]) * 32767, g_key_stick[1] = (sx[3] - sx[2]) * 32767;
    send_pad();
    return game_has_input() ? nil : ev;   // swallowed while playing (no system beep)
}
// Mouse and trackpad -> the gesture engine (ui_touch.c, the iPhone's touch handling), in game pixels (the picture is
// nx_game_width() x 720):
//   click        a tap: a prompt's button, a menu item (focus moved there), else A; anything on screen can be clicked
//   click + drag the island follows the pointer (glides on after release); menus step through their items
//   long press   hold (grab and carry on the island)
//   right-click  Back (B)
//   pinch / wheel     zoom (two synthesized fingers spreading), two-finger rotate turns the camera
//   two-finger scroll pans like a drag (starts after 24 px, so a small nudge never clicks)
// Clicks on the pills / banner / launcher stay theirs.
void nx_ui_touch2(int type, int id, float x, float y);   // 0 down, 1 move, 2 up, 3 cancel, 4 Back
static BOOL game_xy(NSEvent *ev, float *x, float *y) {
    NSPoint p = [g_game convertPoint:ev.locationInWindow fromView:nil];
    NSSize sz = g_game.bounds.size;
    if (sz.width <= 0 || sz.height <= 0) return NO;
    *x = (float)(p.x / sz.width * nx_game_width()), *y = (float)((sz.height - p.y) / sz.height * nx_game_height());
    return NSPointInRect(p, g_game.bounds);
}
static BOOL on_game(NSEvent *ev) {   // the click lands on the picture itself (not a pill, the launcher or a sheet)
    NSView *hit = [g_root hitTest:[g_root.superview convertPoint:ev.locationInWindow fromView:nil]];
    return hit == g_game && game_has_input();
}
static BOOL g_mouse_down;            // finger 0 is the mouse
static struct { BOOL on; float cx, cy, d, a; double last; } g_pair;      // two synthesized fingers (pinch / wheel / rotate)
static struct { BOOL pending, down; float x0, y0, dx, dy; } g_scroll;    // two-finger scroll as a drag of finger 0
static void pair_send(int type) {
    float ox = g_pair.d * cosf(g_pair.a), oy = g_pair.d * sinf(g_pair.a);
    if (type == 2) { nx_ui_touch2(2, 1, g_pair.cx + ox, g_pair.cy + oy), nx_ui_touch2(2, 0, g_pair.cx - ox, g_pair.cy - oy); return; }
    nx_ui_touch2(type, 0, g_pair.cx - ox, g_pair.cy - oy);
    nx_ui_touch2(type, 1, g_pair.cx + ox, g_pair.cy + oy);
}
static BOOL pair_begin(NSEvent *ev) {
    if (g_pair.on) { g_pair.last = CACurrentMediaTime(); return YES; }
    float x, y;
    if (g_mouse_down || g_scroll.down || !game_xy(ev, &x, &y) || !on_game(ev)) return NO;
    g_pair.on = YES, g_pair.cx = x, g_pair.cy = y, g_pair.d = 110, g_pair.a = 0, g_pair.last = CACurrentMediaTime();
    pair_send(0);
    return YES;
}
static void pair_tick(void) {   // the gesture went quiet: lift both fingers
    if (g_pair.on && CACurrentMediaTime() - g_pair.last > 0.2) g_pair.on = NO, pair_send(2);
}
static NSEvent *mouse_event(NSEvent *ev) {
    if (ev.window != g_win || g_started != 2) return ev;
    float x, y;
    switch (ev.type) {
    case NSEventTypeLeftMouseDown:
        if (!on_game(ev) || g_pair.on || g_scroll.down || !game_xy(ev, &x, &y)) return ev;
        g_mouse_down = YES;
        nx_ui_touch2(0, 0, x, y);
        return ev;
    case NSEventTypeLeftMouseDragged:
        if (g_mouse_down) game_xy(ev, &x, &y), nx_ui_touch2(1, 0, x, y);
        return ev;
    case NSEventTypeLeftMouseUp:
        if (g_mouse_down) game_xy(ev, &x, &y), nx_ui_touch2(g_paused ? 3 : 2, 0, x, y), g_mouse_down = NO;
        return ev;
    case NSEventTypeRightMouseDown:
        if (!on_game(ev)) return ev;
        nx_ui_touch2(4, 0, 0, 0);   // Back
        return nil;
    case NSEventTypeMagnify:
        if (!pair_begin(ev)) return ev;
        g_pair.d = fminf(400, fmaxf(30, g_pair.d * (1 + (float)ev.magnification)));
        pair_send(1);
        return nil;
    case NSEventTypeRotate:
        if (!pair_begin(ev)) return ev;
        g_pair.a -= (float)(ev.rotation * M_PI / 180);   // counter-clockwise positive; the game's y points down
        pair_send(1);
        return nil;
    case NSEventTypeScrollWheel:
        if (!ev.hasPreciseScrollingDeltas) {   // a mouse wheel: zoom
            if (!ev.scrollingDeltaY || !pair_begin(ev)) return ev;
            g_pair.d = fminf(400, fmaxf(30, g_pair.d * (1 + (float)ev.scrollingDeltaY * 0.08f)));
            pair_send(1);
            return nil;
        }
        if (ev.momentumPhase != NSEventPhaseNone) return nil;   // the engine glides on by itself
        if (ev.phase == NSEventPhaseBegan) {
            if (g_mouse_down || g_pair.on || !game_xy(ev, &x, &y) || !on_game(ev)) return ev;
            g_scroll.pending = YES, g_scroll.down = NO, g_scroll.x0 = x, g_scroll.y0 = y, g_scroll.dx = g_scroll.dy = 0;
            return nil;
        }
        if (!g_scroll.pending) return ev;
        if (ev.phase == NSEventPhaseChanged) {
            // content follows the fingers (natural scrolling) whichever way the Mac is set
            float k = 720 / (float)g_game.bounds.size.height, sgn = ev.isDirectionInvertedFromDevice ? 1 : -1;
            g_scroll.dx += sgn * (float)ev.scrollingDeltaX * k, g_scroll.dy += sgn * (float)ev.scrollingDeltaY * k;
            if (!g_scroll.down && hypotf(g_scroll.dx, g_scroll.dy) >= 24) g_scroll.down = YES, nx_ui_touch2(0, 0, g_scroll.x0, g_scroll.y0);
            if (g_scroll.down) nx_ui_touch2(1, 0, g_scroll.x0 + g_scroll.dx, g_scroll.y0 + g_scroll.dy);
        } else if (ev.phase == NSEventPhaseEnded || ev.phase == NSEventPhaseCancelled) {
            if (g_scroll.down) nx_ui_touch2(ev.phase == NSEventPhaseEnded ? 2 : 3, 0, g_scroll.x0 + g_scroll.dx, g_scroll.y0 + g_scroll.dy);
            g_scroll.pending = g_scroll.down = NO;
        }
        return nil;
    default:
        return ev;
    }
}

// NXRT_UITEST_MOUSE=<frame>:<what>[;...] (tests, with NXRT_UITEST_QUIET: nothing touches the real pointer): real
// NSEvents posted to the app at a game frame, through the same monitors as the mouse. Points in game pixels.
//   click:x,y   drag:x0,y0,x1,y1   right   wheel:x,y,n (n clicks, + = in)   pinch:x,y,m (magnification, + = in)
static void uitest_post(NSEventType t, float gx, float gy) {
    NSSize sz = g_game.bounds.size;
    NSPoint w = [g_game convertPoint:NSMakePoint(gx / nx_game_width() * sz.width, sz.height - gy / nx_game_height() * sz.height) toView:nil];
    NSEvent *e = [NSEvent mouseEventWithType:t location:w modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                                windowNumber:g_win.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
    [NSApp postEvent:e atStart:NO];
}
static void uitest_mouse(void) {
    const char *spec = getenv("NXRT_UITEST_MOUSE");
    if (!spec) return;
    for (NSString *item in [@(spec) componentsSeparatedByString:@";"]) {
        NSArray *p = [item componentsSeparatedByString:@":"];
        if (p.count < 2) continue;
        int frame = [p[0] intValue];
        NSString *what = p[1];
        NSArray<NSString *> *a = p.count > 2 ? [p[2] componentsSeparatedByString:@","] : @[];
        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) {
            if (g_gfx_frame < frame) return;
            [t invalidate];
            nx_log("mac: uitest: %s at frame %d", item.UTF8String, g_gfx_frame);
            if ([what isEqual:@"click"]) {
                uitest_post(NSEventTypeLeftMouseDown, a[0].floatValue, a[1].floatValue);
                uitest_post(NSEventTypeLeftMouseUp, a[0].floatValue, a[1].floatValue);
            } else if ([what isEqual:@"right"]) {
                uitest_post(NSEventTypeRightMouseDown, 640, 360);
            } else if ([what isEqual:@"drag"]) {   // 0.5 s, 20 steps, held still at the end (no fling)
                float x0 = a[0].floatValue, y0 = a[1].floatValue, x1 = a[2].floatValue, y1 = a[3].floatValue;
                uitest_post(NSEventTypeLeftMouseDown, x0, y0);
                for (int i = 1; i <= 22; i++)
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 25 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                        float k = fminf(1, i / 20.f);
                        uitest_post(i == 22 ? NSEventTypeLeftMouseUp : NSEventTypeLeftMouseDragged, x0 + (x1 - x0) * k, y0 + (y1 - y0) * k);
                    });
            } else if ([what isEqual:@"wheel"] || [what isEqual:@"pinch"]) {
                BOOL wheel = [what isEqual:@"wheel"];
                float v = a[2].floatValue;
                for (int i = 0; i < 10; i++)
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 30 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                        NSSize sz = g_game.bounds.size;
                        NSPoint w = [g_game convertPoint:NSMakePoint(a[0].floatValue / nx_game_width() * sz.width, sz.height - a[1].floatValue / 720 * sz.height) toView:nil];
                        NSPoint sp = [g_win convertPointToScreen:w];
                        CGEventRef ce = wheel ? CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 1, (int32_t)(v > 0 ? 1 : -1))
                                              : CGEventCreate(NULL);
                        CGEventSetLocation(ce, CGPointMake(sp.x, NSScreen.screens.firstObject.frame.size.height - sp.y));
                        if (!wheel) {   // a magnify gesture event (type 29, subtype 8 = magnify, value at field 113)
                            CGEventSetType(ce, 29);
                            CGEventSetIntegerValueField(ce, 110, 8);
                            CGEventSetDoubleValueField(ce, 113, v / 10);
                        }
                        CGEventSetIntegerValueField(ce, kCGMouseEventWindowUnderMousePointer, g_win.windowNumber);
                        CGEventSetIntegerValueField(ce, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, g_win.windowNumber);
                        NSEvent *e = [NSEvent eventWithCGEvent:ce];
                        CFRelease(ce);
                        if (i == 0) nx_log("mac: uitest: %s event %s window", what.UTF8String, e.window == g_win ? "has the" : "has NO");
                        if (e) mouse_event(e);
                    });
            }
        }];
    }
}

// ---- window --------------------------------------------------------------------------------------------------------
@interface NxRootView : NSView
@end
@implementation NxRootView
- (BOOL)isFlipped { return YES; }
- (void)resizeSubviewsWithOldSize:(NSSize)old { [self place]; }
- (void)place {
    NSRect b = self.bounds;
    g_canvas.frame = b;
    if (g_started < 2) { g_game.frame = b; return; }
    CGFloat aspect = (CGFloat)nx_game_width() / nx_game_height(), w = MIN(b.size.width, b.size.height * aspect), h = w / aspect;
    g_game.frame = NSMakeRect((b.size.width - w) / 2, (b.size.height - h) / 2, w, h);
    g_overlay.frame = g_game.frame;
}
@end

@interface NxOverlay : NxView   // in-game pills, positioned in the overlay canvas's logical points
@end
@implementation NxOverlay
- (NSView *)hitTest:(NSPoint)p {
    NSView *v = [super hitTest:p];
    return v == self ? nil : v;
}
- (void)layout {
    [super layout];
    CGFloat top = 12, left = 12;
    if (g_islands) g_islands.frame = NSMakeRect(left, top, 112, 36);
    BOOL isl = g_islands && !g_islands.hidden;
    if (g_fps) g_fps.frame = NSMakeRect(left, top + (isl ? 44 : 0), 66, 26);
    if (g_back) g_back.frame = NSMakeRect(self.bounds.size.width - 12 - 88, top, 88, 36);
}
@end
static NxOverlay *g_over;

// The floating glass pill (the iOS spec: 36 pt high, radius 18, translucent material + white 0.65 overlay, 0.5 pt white
// 0.5 border, shadow #000 0.18 r8 y2, symbol + title 15 pt semibold, fade 0.2 s).
static NxPressable *glass_pill(NSString *title, NSString *symbol, CGFloat width) {
    NxPressable *b = [[NxPressable alloc] initWithFrame:NSMakeRect(0, 0, width, 36)];
    b.pressScale = 0.94;
    b.alphaValue = 0, b.hidden = YES;
    b.layer.shadowColor = NSColor.blackColor.CGColor, b.layer.shadowOpacity = 0.18f, b.layer.shadowRadius = 8, b.layer.shadowOffset = CGSizeMake(0, -2);
    NSVisualEffectView *glass = [[NSVisualEffectView alloc] initWithFrame:b.bounds];
    glass.material = NSVisualEffectMaterialHUDWindow, glass.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    glass.state = NSVisualEffectStateActive;
    glass.wantsLayer = YES, glass.layer.cornerRadius = 18, glass.layer.masksToBounds = YES;
    glass.layer.borderWidth = 0.5, glass.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.5].CGColor;
    glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NxView *tint = [[NxView alloc] initWithFrame:b.bounds];
    tint.layer.backgroundColor = [NSColor colorWithWhite:1 alpha:0.65].CGColor;
    tint.autoresizingMask = glass.autoresizingMask;
    [glass addSubview:tint];
    NSColor *ink = nx_rgb(0x1C1C1E, 1);
    NxImageView *icon = [NxImageView new];
    icon.image = nx_tinted(nx_symbol(symbol, 13, NSFontWeightSemibold), ink), icon.fit = YES;
    NxLabel *txt = [NxLabel text:title font:[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold] color:ink];
    CGSize ts = [txt sizeThatFits:CGSizeMake(200, 36)];
    CGFloat iw = 16, cw = iw + 5 + ts.width, x0 = (width - cw) / 2;
    icon.frame = NSMakeRect(x0, 10, iw, 16);
    txt.frame = NSMakeRect(x0 + iw + 5, 0, ts.width + 2, 36);
    [glass addSubview:icon], [glass addSubview:txt];
    [b addSubview:glass];
    return b;
}
static void show_pill(NSView *b, BOOL want) {
    if (!b || want == !b.hidden) return;
    if (want) b.hidden = NO;
    g_over.needsLayout = YES;
    nx_fade(b, want ? 1 : 0, 0.2, ^{ if (!want && b.alphaValue == 0) b.hidden = YES; });
}
// FPS counter (Settings): presents per second over the last 0.5 s, in a glass pill (26 pt high, 13 pt monospaced digits).
static NxLabel *g_fps_label;
static NSTimer *g_fps_timer;
static void fps_counter(BOOL on) {
    if (!on) {
        [g_fps removeFromSuperview], g_fps = nil;
        [g_fps_timer invalidate], g_fps_timer = nil;
        return;
    }
    if (g_fps) return;
    NxView *v = [[NxView alloc] initWithFrame:NSMakeRect(0, 0, 66, 26)];
    NSVisualEffectView *glass = [[NSVisualEffectView alloc] initWithFrame:v.bounds];
    glass.material = NSVisualEffectMaterialHUDWindow, glass.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    glass.state = NSVisualEffectStateActive;
    glass.wantsLayer = YES, glass.layer.cornerRadius = 13, glass.layer.masksToBounds = YES;
    glass.layer.borderWidth = 0.5, glass.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.5].CGColor;
    glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NxView *tint = [[NxView alloc] initWithFrame:v.bounds];
    tint.layer.backgroundColor = [NSColor colorWithWhite:1 alpha:0.65].CGColor;
    tint.autoresizingMask = glass.autoresizingMask;
    g_fps_label = [NxLabel text:@"-- fps" font:[NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold] color:nx_rgb(0x1C1C1E, 1)];
    g_fps_label.frame = v.bounds, g_fps_label.autoresizingMask = glass.autoresizingMask;
    [v addSubview:glass], [v addSubview:tint], [v addSubview:g_fps_label];
    g_fps = v;
    [g_over addSubview:v];
    __block int last = g_gfx_frame;
    __block uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    g_fps_timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        int f = g_gfx_frame;
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        g_fps_label.text = [NSString stringWithFormat:@"%.0f fps", (f - last) * 1e9 / (double)(now - t0)];
        last = f, t0 = now;
    }];
    g_over.needsLayout = YES;
}

// ---- the launcher over the game --------------------------------------------------------------------------------------
static void show_launcher_view(NSView *v, BOOL fade) {
    g_launcher = v;
    [g_canvas addSubview:v];
    if (fade) v.alphaValue = 0, nx_fade(v, 1, 0.3, nil);
    [g_spin removeFromSuperview], g_spin = nil;
}
static void resume_game(void) {
    g_paused = NO;
    g_gfx_background = 0;
    fps_counter(nx_launcher_fps_counter());
    [g_win makeFirstResponder:g_root];
    nx_log("mac: game resumed");
}
// The title screen's Islands: the game pauses (the render thread waits) under the island select.
static void islands_tap(void) {
    if (g_paused) return;
    g_paused = YES;
    g_gfx_background = 1;
    if (g_mouse_down) nx_ui_touch2(3, 0, 0, 0), g_mouse_down = NO;   // nothing stays held under the launcher
    if (g_pair.on) g_pair.on = NO, pair_send(2);
    show_pill(g_islands, NO);
    nx_log("mac: island select over the title screen (game paused)");
    nx_launcher_show(YES, nil, ^{ resume_game(); }, nil, ^(NSView *v) { show_launcher_view(v, YES); });
}
// ---- starting the game -------------------------------------------------------------------------------------------------
static void *guest_thread(void *arg) {
    g_guest_main();
    return NULL;
}
// Display settings, after the launcher's choices. Resolution: the game renders at 1080p (Quality) or its own 720p
// (Performance) and MetalFX sharpens the picture to the window's real pixel height (up to 2160: full screen on a
// Retina display). Widescreen: the width = the window's shape at 720 high (16:9 at the least). The window then keeps
// the game's shape. The shell's NXRT_* values win.
static void display_defaults(void) {
    if (!nx_launcher_enabled()) return;
    NSSize s = g_root.bounds.size;
    CGFloat px = s.height * g_win.backingScaleFactor;
    const char *mode = getenv("NXRT_MODE") ? getenv("NXRT_MODE") : "quality";
    char v[16];
    if (!strcmp(mode, "quality")) setenv("NXRT_RENDER_H", "1080", 0);
    int render = getenv("NXRT_RENDER_H") ? atoi(getenv("NXRT_RENDER_H")) : 720, up = (int)MIN(2160, px) & ~1;
    if (up > render) snprintf(v, sizeof v, "%d", up), setenv("NXRT_UPSCALE", v, 0);
    // Fill the window (Settings > Widescreen): wider than 16:9 -> a wider picture at 720 high (NXRT_WIDE), narrower ->
    // a taller one at 1280 wide (NXRT_TALL, ui_touch.c: more world above and below, the UI to the real edges).
    if (nx_launcher_wide() && s.width > 0 && s.height > 0) {
        if (s.width * 9 >= s.height * 16) snprintf(v, sizeof v, "%d", (int)lround(720 * s.width / s.height) & ~1), setenv("NXRT_WIDE", v, 0);
        else snprintf(v, sizeof v, "%d", MIN(1080, (int)lround(1280 * s.height / s.width) & ~1)), setenv("NXRT_TALL", v, 0);
    }
    nx_log("mac: %s: render %d high, sharpened to %s, %s fps, picture %dx%d", mode, render, getenv("NXRT_UPSCALE") ?: "-",
           getenv("NXRT_FPS") ?: "30", nx_game_width(), nx_game_height());
}
static void start_game(void) {
    if (g_started) return;
    display_defaults();
    g_started = 2;
    int gw = nx_game_width(), gh = nx_game_height();
    g_win.contentAspectRatio = NSMakeSize(gw, gh);
    if (!(g_win.styleMask & NSWindowStyleMaskFullScreen)) {
        NSRect f = g_win.frame;
        NSSize c = [g_win contentRectForFrameRect:f].size;
        [g_win setContentSize:NSMakeSize(c.width, round(c.width * gh / gw))];
        [g_win setFrameTopLeftPoint:NSMakePoint(f.origin.x, NSMaxY(f))];
    }
    g_layer.drawableSize = CGSizeMake(gw, gh);
    gfx_attach_layer(g_layer);
    [(NxRootView *)g_root place];
    if (nx_launcher_enabled()) {
        g_islands = glass_pill(@"Islands", @"house.fill", 112);
        ((NxPressable *)g_islands).onTap = ^{ islands_tap(); };
        [g_over addSubview:g_islands];
        // Back (the iPhone's floating pill): while the game shows a menu without its own Back prompt
        g_back = glass_pill(@"Back", @"chevron.left", 88);
        ((NxPressable *)g_back).onTap = ^{ nx_ui_touch2(4, 0, 0, 0); };
        [g_over addSubview:g_back];
        fps_counter(nx_launcher_fps_counter());
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
            int f = nx_ui_flags();
            show_pill(g_islands, (f & 2) && !g_paused);
            show_pill(g_back, (f & 1) && !g_paused);
            pair_tick();
        }];
    }
    [g_win makeFirstResponder:g_root];
    uitest_mouse();
    nx_log("mac: game starting (%dx%d)", gw, gh);
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 8 << 20);
    pthread_t t;
    if (pthread_create(&t, &attr, guest_thread, NULL)) nx_fatal("mac: guest thread");
}
// Asks for whatever is still missing (the ROM screen), then the launcher, then the game.
static void next(void) {
    if (!nx_launcher_enabled() || g_started) { start_game(); return; }
    if (!getenv("NXRT_XCI") || !getenv("NXRT_KEYS")) {   // first launch / Remove ROM: the ROM screen
        if (g_rom) return;
        g_rom = nx_rom_view(^(NSString *xci) {
            nx_fade(g_rom, 0, 0.25, ^{ [g_rom removeFromSuperview], g_rom = nil; next(); });
        });
        [g_canvas addSubview:g_rom];
        return;
    }
    if (nx_launcher_take_autostart()) { start_game(); return; }
    g_spin = [NSProgressIndicator new];   // first launch: the game's UI assets are decoded from the .xci (~1-2 s), then cached
    g_spin.style = NSProgressIndicatorStyleSpinning, g_spin.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    g_spin.frame = NSMakeRect(NSMidX(g_root.bounds) - 16, NSMidY(g_root.bounds) - 16, 32, 32);
    [g_spin startAnimation:nil];
    [g_root addSubview:g_spin];
    nx_launcher_show(NO, ^{ start_game(); }, nil, ^{
        nx_rom_forget();
        g_launcher = nil;
        next();
    }, ^(NSView *v) { show_launcher_view(v, NO); });
}

// ---- menu bar ----------------------------------------------------------------------------------------------------------
static NSMenu *main_menu(void) {
    NSMenu *bar = [NSMenu new], *app = [[NSMenu alloc] initWithTitle:@"Tomodachi Life"], *edit = [[NSMenu alloc] initWithTitle:@"Edit"],
           *win = [[NSMenu alloc] initWithTitle:@"Window"];
    [app addItemWithTitle:@"Hide Tomodachi Life" action:@selector(hide:) keyEquivalent:@"h"];
    [app addItem:NSMenuItem.separatorItem];
    [app addItemWithTitle:@"Quit Tomodachi Life" action:@selector(terminate:) keyEquivalent:@"q"];
    [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [win addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    NSMenuItem *fs = [win addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
    fs.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    for (NSMenu *m in @[app, edit, win]) [bar addItemWithTitle:m.title action:nil keyEquivalent:@""].submenu = m;
    NSApp.windowsMenu = win;
    return bar;
}

@interface NxAppDelegate : NSObject <NSApplicationDelegate>
@end
@implementation NxAppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }
// Full screen (Settings, on by default) once the app has finished launching: asked for before that, macOS ignores it.
// It is also what turns on macOS Game Mode for the app bundle (make app: games category, LSSupportsGameMode).
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    if (nx_launcher_enabled() && nx_launcher_fullscreen() && !getenv("NXRT_UITEST_QUIET") && !(g_win.styleMask & NSWindowStyleMaskFullScreen))
        [g_win toggleFullScreen:nil];
}
@end

void gfx_run_app(void (*guest_main)(void)) {
    @autoreleasepool {
        g_guest_main = guest_main;
        // The launch environment, kept for a relaunch (before the launcher adds its choices).
        int n = 0;
        char **environ = *_NSGetEnviron();
        while (environ[n]) n++;
        g_env0 = calloc(n + 1, sizeof *g_env0);
        for (int i = 0; i < n; i++) g_env0[i] = strdup(environ[i]);
        if (nx_launcher_enabled()) {
            nx_launcher_paths();
            // What the game needs to run as an app (the Mac test recipe; the iPhone app sets the same), unless the shell
            // says otherwise: unknown IPC commands answered, guest memory use reported, draws and compute on, handheld
            // (the game takes the mouse as its touch screen only in handheld mode).
            setenv("NXRT_LENIENT", "1", 0), setenv("NXRT_MEMUSED", "1", 0), setenv("NXRT_DRAW", "1", 0);
            setenv("NXRT_COMPUTE", "1", 0), setenv("NXRT_HANDHELD", "1", 0);
            setenv("NXRT_HIDEBUTTONGLYPHS", "1", 0);   // no A/B/X/Y symbols: everything is clicked (pl.c, as on the iPhone)
            // Fewer first-visit hitches: pipelines kept across launches (runtime/pipecache, gfx_cmd.m pc_*), and shaders
            // missing from the metallib saved for its next build (build_metallib.py ... work/shaders/variants).
            setenv("NXRT_PIPECACHE", "1", 0), setenv("NXRT_SHADER_MISSDIR", "../work/shaders/variants", 0);
        }
        gfx_init();
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        static NxAppDelegate *delegate;
        delegate = [NxAppDelegate new];
        NSApp.delegate = delegate;
        NSApp.mainMenu = main_menu();
        BOOL launcher = nx_launcher_enabled();
        // Without the launcher the window has the game's shape from the start (the old window).
        NSSize size = launcher ? NSMakeSize(1280, 720) : NSMakeSize(nx_game_width(), 720);
        g_win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                      NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                              backing:NSBackingStoreBuffered defer:NO];
        g_win.title = launcher ? @"Tomodachi Life" : @"nxrt";
        g_win.releasedWhenClosed = NO;
        g_win.contentMinSize = NSMakeSize(800, 450);
        g_win.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
        g_win.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];   // the launcher's alerts in the game's light look
        g_win.backgroundColor = NSColor.blackColor;
        [g_win center];
        g_root = [[NxRootView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
        g_root.wantsLayer = YES;
        g_root.layer.backgroundColor = NSColor.blackColor.CGColor;
        g_win.contentView = g_root;
        g_layer = [CAMetalLayer layer];
        g_layer.device = g_dev;
        g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_layer.framebufferOnly = YES;
        g_layer.displaySyncEnabled = YES;   // flip on vblank (NO tore); pace() still sets the game's rate
        g_layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        g_game = [[NSView alloc] initWithFrame:g_root.bounds];
        g_game.layer = g_layer;             // layer-hosting view
        g_game.wantsLayer = YES;
        g_overlay = [[NxCanvas alloc] initWithFrame:g_root.bounds];
        g_overlay.passThrough = YES;
        g_over = [NxOverlay new];
        [g_overlay addSubview:g_over];
        g_canvas = [[NxCanvas alloc] initWithFrame:g_root.bounds];
        g_canvas.passThrough = YES;
        [g_root addSubview:g_game], [g_root addSubview:g_overlay], [g_root addSubview:g_canvas];
        [(NxRootView *)g_root place];
        // NXRT_UITEST_QUIET=1 (tests): the window opens behind everything, never takes focus or the screen, no sound.
        BOOL quiet = getenv("NXRT_UITEST_QUIET") != NULL;
        if (quiet) {
            setenv("NXRT_AUDIO", "0", 1), setenv("NXRT_LAUNCHER_MUSIC", "0", 1);
            [g_win orderBack:nil];
        } else {
            [g_win makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
        }

        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp handler:^NSEvent *(NSEvent *ev) { return key_event(ev); }];
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp |
                                                      NSEventMaskRightMouseDown | NSEventMaskMagnify | NSEventMaskRotate | NSEventMaskScrollWheel
                                              handler:^NSEvent *(NSEvent *ev) { return mouse_event(ev); }];
        // Controllers: read the current one on every change (connect, buttons, sticks).
        [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            GCController *c = note.object;
            c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *e) { poll_controller(g); };
            nx_log("mac: controller connected: %s", c.vendorName.UTF8String ?: "?");
        }];
        for (GCController *c in GCController.controllers)
            c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *e) { poll_controller(g); };

        if (launcher) next();
        else start_game();
        [NSApp run];
    }
}
