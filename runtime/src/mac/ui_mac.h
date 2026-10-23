// Shared AppKit pieces of the Mac launcher (launcher_mac.m, game_ui_mac.m, app_mac.m): the iOS launcher's UIKit
// idioms rebuilt natively so its layout code carries over with the same numbers.
//   - NxView: flipped (y down, as UIKit), layer-backed, `layout` runs on every size change (= layoutSubviews).
//   - NxCanvas: the launcher's coordinate space. Its bounds are the window scaled down to a phone-like logical size
//     (about 430 pt high), so the iOS points apply unchanged; AppKit draws text and images at the real resolution.
//   - NxLabel: UILabel's behaviour (vertically centred, shrink to fit, lines, attributed text).
//   - NxPressable: a tappable view (press scale, drag out cancels, pointing-hand cursor).
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

NSColor *nx_rgb(uint32_t c, CGFloat a);
#define NX_NAVY(a) nx_rgb(0x002240, (a))
#define NX_ORANGE nx_rgb(0xF2660D, 1)

@interface NxView : NSView
@end

@interface NxCanvas : NxView
@property(nonatomic) BOOL passThrough;   // clicks on its empty area go to the views below (in-game overlay)
@property(nonatomic, readonly) CGFloat scale;
@end

@interface NxLabel : NxView
@property(nonatomic, copy) NSString *text;
@property(nonatomic, copy) NSAttributedString *attributedText;
@property(nonatomic, strong) NSFont *font;
@property(nonatomic, strong) NSColor *textColor;
@property(nonatomic) NSTextAlignment alignment;   // centre by default
@property(nonatomic) NSInteger lines;             // 1 by default, 0 = as many as needed
@property(nonatomic) CGFloat minScale;            // < 1: one line shrinks to fit down to this
@property(nonatomic) CGFloat lineHeightMultiple;
@property(nonatomic, strong) NSShadow *textShadow;
+ (instancetype)text:(NSString *)text font:(NSFont *)font color:(NSColor *)color;
- (CGSize)sizeThatFits:(CGSize)size;
@end

@interface NxPressable : NxView
@property(nonatomic, copy) void (^onTap)(void);
@property(nonatomic, copy) void (^onDown)(void);
@property(nonatomic, copy) void (^onUp)(void);
@property(nonatomic, copy) void (^onRightClick)(NSEvent *e);
@property(nonatomic) CGFloat pressScale;   // 0.95 by default, 1 = none
@property(nonatomic) BOOL enabled;         // YES by default; NO = alpha 0.5, no taps
@property(nonatomic) BOOL dimWhenDisabled; // YES by default
@end

@interface NxImageView : NxView
@property(nonatomic, strong) NSImage *image;
@property(nonatomic) BOOL fit;             // aspect fit (YES) or stretch (NO, the default; resizable images keep caps)
@property(nonatomic) BOOL fill;            // aspect fill, clipped
@property(nonatomic, strong) NSImage *mask;   // drawn through this image's alpha (aspect stretch to the bounds)
@end

// Images: PNG at a pixel density (3 = the iOS @3x assets), tinting, symbols, CGImage at a size.
NSImage *nx_png(NSString *path, CGFloat scale);
NSImage *nx_tinted(NSImage *mask, NSColor *c);
NSImage *nx_symbol(NSString *name, CGFloat points, NSFontWeight weight);
CGImageRef nx_cgimage(NSImage *img, CGSize points, CGFloat pxPerPoint);   // caller releases

// Animations on a view's layer, about its centre (AppKit anchors layers at a corner). Additive: they stack.
CATransform3D nx_center_scale(NSView *v, CGFloat sx, CGFloat sy);
void nx_animate_scale(NSView *v, NSString *key, CGFloat from, CGFloat to, CFTimeInterval d, CAMediaTimingFunctionName timing,
                      BOOL hold, BOOL repeatReverse);
void nx_spring_scale(NSView *v, NSString *key, CGFloat from, CGFloat to, CGFloat damping, CFTimeInterval delay);
void nx_fade(NSView *v, CGFloat to, NSTimeInterval d, void (^done)(void));

// Native dialogs as sheets on `w`.
void nx_alert(NSWindow *w, NSString *title, NSString *msg, NSArray<NSString *> *buttons, NSInteger destructive,
              void (^done)(NSInteger button));   // buttons[0] is the default (Return); done may be nil
void nx_alert_ok(NSWindow *w, NSString *title, NSString *msg);
void nx_prompt(NSWindow *w, NSString *title, NSString *msg, NSString *value, NSString *placeholder, NSArray<NSString *> *buttons,
               void (^done)(NSInteger button, NSString *text));   // buttons[0] default; the last one cancels
void nx_busy(NSWindow *w, NSString *text, id (^work)(void), void (^then)(id result));   // work() on a background queue
