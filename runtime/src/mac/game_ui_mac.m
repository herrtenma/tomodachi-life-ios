// Game-style pieces for the Mac launcher, the AppKit twin of ios/game_ui.m: pill buttons with the RoughLine waves and
// the cloud dialog (Return / Escape answer it), from the game's textures cached by launcher_mac.m, in the launcher's
// logical points (NxCanvas). Same visual spec as game_ui.m.
#import "ui_mac.h"
#include "nxrt.h"

NSImage *nx_ui_texture(NSString *name);
NSFont *nx_ui_font(CGFloat size, BOOL bold);
NSImage *nx_ui_cloud(void);

#define rgb nx_rgb
#define navy NX_NAVY
static NSImage *tex(NSString *name) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    if (!cache[name]) { NSImage *i = nx_ui_texture(name); if (i) cache[name] = i; }
    return cache[name];
}
static CGImageRef cg_of(NSImage *i) { return [i CGImageForProposedRect:NULL context:nil hints:nil]; }

// The shape textures' edges hold near-transparent texels (block compression): stretched, they showed as a thin line
// past the button's end. Alpha below ~16% -> 0; the shape's own outline is untouched.
static NSImage *clean_alpha(NSImage *img) {
    CGImageRef src = cg_of(img);
    if (!src) return img;
    size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef g = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!g) return img;
    CGContextDrawImage(g, CGRectMake(0, 0, w, h), src);
    uint8_t *px = CGBitmapContextGetData(g);
    for (size_t i = 0; i < w * h; i++)
        if (px[i * 4 + 3] < 40) px[i * 4] = px[i * 4 + 1] = px[i * 4 + 2] = px[i * 4 + 3] = 0;
    CGImageRef out = CGBitmapContextCreateImage(g);
    CGContextRelease(g);
    NSImage *r = [[NSImage alloc] initWithCGImage:out size:img.size];
    CGImageRelease(out);
    return r;
}
static NSImage *shape_tex(NSString *name) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    if (!cache[name]) { NSImage *i = tex(name); if (i) cache[name] = clean_alpha(i); }
    return cache[name];
}
// A shape texture tinted `base`, with the RoughLine waves in `wave` inside it (the game's button look).
static NSImage *shape_with_waves(NSImage *shape, CGSize size, NSColor *base, NSColor *wave) {
    if (!shape || size.width < 1 || size.height < 1) return nil;
    NSImage *tb = nx_tinted(shape, base), *line = tex(@"roughline"), *tw_ = wave && line ? nx_tinted(line, wave) : nil;
    return [NSImage imageWithSize:size flipped:YES drawingHandler:^BOOL(NSRect b) {
        [tb drawInRect:b fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];   // respectFlipped: these images are y-up, the context is flipped
        if (!tw_) return YES;
        CGContextRef g = NSGraphicsContext.currentContext.CGContext;
        CGContextBeginTransparencyLayer(g, NULL);
        // The waves stay 1 pt inside the edge (the shape is clear there): on the scaled canvas the edge pixels are only
        // partly covered by the shape's DestinationIn, which left a faint dashed line of waves along the border.
        CGContextClipToRect(g, CGRectInset(b, 1, 1));
        CGFloat px = 0.5;   // tiles on whole pixels, overlapping by one: soft edges at fractional positions left seams
        CGFloat th = round(size.height * 0.55 / px) * px, tw = round(th * line.size.width / line.size.height / px) * px;
        for (CGFloat y = round(-th * 0.3 / px) * px; y < size.height; y += round(th * 1.15 / px) * px)
            for (CGFloat x = round(-tw * 0.5 / px) * px; x < size.width; x += tw - px) [tw_ drawInRect:NSMakeRect(x, y, tw, th) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
        [shape drawInRect:b fromRect:NSZeroRect operation:NSCompositingOperationDestinationIn fraction:1 respectFlipped:YES hints:nil];
        CGContextEndTransparencyLayer(g);
        return YES;
    }];
}
static NxLabel *label(NSString *text, CGFloat size, BOOL bold, NSColor *color) {
    NxLabel *l = [NxLabel text:text font:nx_ui_font(size, bold) color:color];
    l.minScale = 0.6;
    return l;
}
static void drop_shadow(NSView *v, float opacity, CGFloat radius, CGFloat dy) {
    v.layer.shadowColor = NSColor.blackColor.CGColor, v.layer.shadowOpacity = opacity, v.layer.shadowRadius = radius;
    v.layer.shadowOffset = CGSizeMake(0, v.layer.contentsAreFlipped ? dy : -dy);
}

// ---- buttons --------------------------------------------------------------------------------------------------------
typedef NS_ENUM(int, NxBtnStyle) { NxBtnMain, NxBtnSecond, NxBtnList };
@interface NxGameButton : NxPressable
@property(nonatomic, readonly) NxLabel *title;
+ (instancetype)style:(NxBtnStyle)style title:(NSString *)title icon:(NSImage *)icon;
@end
@implementation NxGameButton {
    NxBtnStyle _style;
    NxImageView *_bg, *_icon;
    CGSize _drawn;
}
+ (instancetype)style:(NxBtnStyle)style title:(NSString *)title icon:(NSImage *)icon {
    NxGameButton *b = [self new];
    b->_style = style;
    b->_bg = [NxImageView new];
    [b addSubview:b->_bg];
    b->_title = label(title, 22, YES, style == NxBtnList ? navy(1) : NSColor.whiteColor);
    [b addSubview:b->_title];
    if (icon) b->_icon = [NxImageView new], b->_icon.image = nx_tinted(icon, navy(1)), b->_icon.fit = YES, [b addSubview:b->_icon];
    b.accessibilityLabel = title, b.accessibilityRole = NSAccessibilityButtonRole;
    return b;
}
- (void)layout {
    [super layout];
    CGRect b = self.bounds;
    if (!CGSizeEqualToSize(_drawn, b.size)) {
        _drawn = b.size;
        NSImage *shape = shape_tex(_style == NxBtnList ? @"btn_long" : @"btn_dialog");
        NSColor *base = rgb(_style == NxBtnMain ? 0xFF2E00 : _style == NxBtnSecond ? 0xFF8000 : 0xFFF0A8, 1);
        NSColor *wave = _style == NxBtnMain ? rgb(0xFF6900, 1) : _style == NxBtnList ? rgb(0xFFE353, 1) : nil;
        _bg.image = shape_with_waves(shape, b.size, base, wave);
        if (!_bg.image) _bg.layer.backgroundColor = base.CGColor, _bg.layer.cornerRadius = b.size.height / 2;
    }
    _bg.frame = b;
    CGFloat ih = _icon ? b.size.height * 0.5 : 0;
    _icon.frame = CGRectMake(b.size.height * 0.45, (b.size.height - ih) / 2, ih * 1.1, ih);
    _title.frame = CGRectInset(b, _icon ? b.size.height * 0.45 + ih * 1.2 : 20, 0);
}
@end

// ---- cloud dialog -----------------------------------------------------------------------------------------------------
@interface NxCloudDialog : NxView
+ (instancetype)title:(NSString *)title body:(NSString *)body main:(NSString *)main second:(NSString *)second
                  done:(void (^)(BOOL main))done;
- (void)showIn:(NSView *)host;
- (void)dismiss;
- (void)setBusy:(NSString *)text;   // replace the buttons with a waiting line
@end
@implementation NxCloudDialog {
    NxImageView *_cloud;
    NxLabel *_title, *_body, *_busy;
    NxGameButton *_main, *_second;
    void (^_done)(BOOL);
}
+ (instancetype)title:(NSString *)title body:(NSString *)body main:(NSString *)main second:(NSString *)second done:(void (^)(BOOL))done {
    NxCloudDialog *d = [self new];
    d.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.3].CGColor;
    d->_done = done;
    d->_cloud = [NxImageView new];
    d->_cloud.image = nx_tinted(nx_ui_cloud(), rgb(0xFFF2CA, 1));
    if (!nx_ui_cloud()) d->_cloud.layer.backgroundColor = rgb(0xFFF2CA, 1).CGColor, d->_cloud.layer.cornerRadius = 40;
    drop_shadow(d->_cloud, 0.16f, 10, 5);
    [d addSubview:d->_cloud];
    d->_title = label(title, 24, YES, navy(1));
    d->_body = label(body, 17, NO, navy(0.85)), d->_body.lines = 0, d->_body.minScale = 1;
    d->_body.lineHeightMultiple = 1.2;   // the game font's lines sit tight
    d->_busy = label(@"", 18, YES, rgb(0xF2660D, 1));
    for (NSView *v in @[d->_title, d->_body, d->_busy]) [d addSubview:v];
    __weak NxCloudDialog *wd = d;
    if (main) {
        d->_main = [NxGameButton style:NxBtnMain title:main icon:nil];
        d->_main.onTap = ^{ [wd tapMain]; };
        [d addSubview:d->_main];
    }
    if (second) {
        d->_second = [NxGameButton style:NxBtnSecond title:second icon:nil];
        d->_second.onTap = ^{ [wd tapSecond]; };
        [d addSubview:d->_second];
    }
    return d;
}
- (void)mouseDown:(NSEvent *)e {}   // the dim takes clicks (modal)
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)e {   // Return = the main button, Escape = the second
    if (_busy.text.length) return;
    if ([e.characters isEqualToString:@"\r"] && _main) [self tapMain];
    else if (e.keyCode == 53 && (_second || (_main && !_second))) _second ? [self tapSecond] : [self tapMain];
}
- (void)tapMain { [self dismiss]; if (_done) _done(YES); }
- (void)tapSecond { [self dismiss]; if (_done) _done(NO); }
- (void)setBusy:(NSString *)text {
    _busy.text = text;
    _main.hidden = _second.hidden = text.length > 0;
    self.needsLayout = YES;
}
- (void)showIn:(NSView *)host {
    self.frame = host.bounds;
    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [host addSubview:self];
    [self layoutSubtreeIfNeeded];
    [self.window makeFirstResponder:self];
    self.alphaValue = 0;
    nx_fade(self, 1, 0.2, nil);
    nx_animate_scale(_cloud, @"in", 0.96, 1, 0.2, kCAMediaTimingFunctionEaseOut, NO, NO);
}
- (void)dismiss {
    nx_fade(self, 0, 0.2, ^{ [self removeFromSuperview]; });
}
- (void)layout {
    [super layout];
    CGRect b = self.bounds;
    // The cloud is sized around its content: its wavy outline dips well into its rectangle, so everything (text and
    // buttons) keeps 60 pt from the sides and 48 pt from the top and bottom.
    const CGFloat side = 60, top = 48;
    CGFloat cw = MIN(440, b.size.width - 32 - 2 * side), w = cw + 2 * side, y = top;
    CGRect title = CGRectMake(side, y, cw, 30), body = CGRectZero, busy = CGRectZero, main = CGRectZero, second = CGRectZero;
    y += 40;
    CGSize bs = [_body sizeThatFits:CGSizeMake(cw, 400)];
    if (_body.text.length) body = CGRectMake(side, y, cw, bs.height), y += bs.height + 20;
    if (_busy.text.length) {
        busy = CGRectMake(side, y, cw, 44), y += 44;
    } else if (_main || _second) {
        CGFloat bw = _main && _second ? MIN(200, (cw - 14) / 2) : 220, bh = 50, x = (w - (_main && _second ? bw * 2 + 14 : bw)) / 2;
        if (_second) second = CGRectMake(x, y, bw, bh), x += bw + 14;   // second on the left, like the game
        if (_main) main = CGRectMake(x, y, bw, bh);
        y += bh;
    }
    y += top;
    y = MIN(y, b.size.height - 16);
    CGPoint o = CGPointMake((b.size.width - w) / 2, (b.size.height - y) / 2);   // the content sits on the cloud (siblings)
    _cloud.frame = CGRectMake(o.x, o.y, w, y);
    _title.frame = CGRectOffset(title, o.x, o.y);
    _body.frame = CGRectOffset(body, o.x, o.y);
    _busy.frame = CGRectOffset(busy, o.x, o.y);
    _main.frame = CGRectOffset(main, o.x, o.y);
    _second.frame = CGRectOffset(second, o.x, o.y);
}
@end

NSView *nx_game_dialog(NSString *title, NSString *body, NSString *main, NSString *second, NSView *host, void (^done)(BOOL main)) {
    NxCloudDialog *d = [NxCloudDialog title:title body:body main:main second:second done:done];
    [d showIn:host];
    return d;
}
// A game-style button for the launcher (style 0 main, 1 second, 2 list).
NxPressable *nx_game_button(int style, NSString *title, NSImage *icon) { return [NxGameButton style:(NxBtnStyle)style title:title icon:icon]; }
