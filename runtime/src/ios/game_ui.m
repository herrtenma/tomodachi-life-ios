// Game-style pieces for the launcher (iOS), built from the game's own textures (decoded from the user's .xci by the
// launcher's asset cache, launcher_ios.m): pill buttons with the RoughLine waves and the cloud dialog.
//
// Visual spec (colours sampled from the game's menus):
//   dialog      DialogCloud_00 #FFF2CA sized around its content (max 440 wide): 60 pt in from the sides, 48 pt top/bottom,
//               body Seurat B 17 at 1.2x line spacing, buttons 50 high, shadow #000 a0.16 r10 y5, dim a0.3
//   main btn    BtnDialog_00 #FF2E00 + RoughLine_00 waves #FF6900, Seurat EB 22 white
//   second btn  BtnDialog_00 #FF8000, Seurat EB 22 white
//   list btn    BtnMainL_00 #FFF0A8 + waves #FFE353, Seurat EB 22 #002240, icon left
//   press       scale 0.95 in 0.1 s; dialogs fade + scale 0.96 -> 1 in 0.2 s ease-out
#import <UIKit/UIKit.h>
#include "nxrt.h"

UIImage *nx_ui_texture(NSString *name);
UIFont *nx_ui_font(CGFloat size, BOOL bold);
UIImage *nx_ui_cloud(void);

static UIColor *rgb(uint32_t c, CGFloat a) {
    return [UIColor colorWithRed:(c >> 16 & 255) / 255.0 green:(c >> 8 & 255) / 255.0 blue:(c & 255) / 255.0 alpha:a];
}
static UIColor *navy(CGFloat a) { return rgb(0x002240, a); }
static UIImage *tint(UIImage *mask, UIColor *c) { return [mask imageWithTintColor:c renderingMode:UIImageRenderingModeAlwaysOriginal]; }
static UIImage *tex(NSString *name) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    if (!cache[name]) { UIImage *i = nx_ui_texture(name); if (i) cache[name] = i; }
    return cache[name];
}
// The shape textures' edges hold near-transparent texels (block compression): stretched, they showed as a thin line
// past the button's end (the bright waves through them). Alpha below ~16% -> 0; the shape's own outline is untouched.
static UIImage *clean_alpha(UIImage *img) {
    CGImageRef src = img.CGImage;
    if (!src) return img;
    size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef g = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!g) return img;
    CGContextDrawImage(g, CGRectMake(0, 0, w, h), src);
    uint8_t *px = CGBitmapContextGetData(g);
    for (size_t i = 0; i < w * h; i++)
        if (px[i * 4 + 3] < 40) px[i * 4] = px[i * 4 + 1] = px[i * 4 + 2] = px[i * 4 + 3] = 0;
    CGImageRef out = CGBitmapContextCreateImage(g);
    CGContextRelease(g);
    UIImage *r = [UIImage imageWithCGImage:out scale:img.scale orientation:img.imageOrientation];
    CGImageRelease(out);
    return r;
}
static UIImage *shape_tex(NSString *name) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    if (!cache[name]) { UIImage *i = tex(name); if (i) cache[name] = clean_alpha(i); }
    return cache[name];
}
// A shape texture tinted `base`, with the RoughLine waves in `wave` inside it (the game's button look).
static UIImage *shape_with_waves(UIImage *shape, CGSize size, UIColor *base, UIColor *wave) {
    if (!shape || size.width < 1 || size.height < 1) return nil;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    CGFloat px = 1 / UIScreen.mainScreen.scale;
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect b = {CGPointZero, size};
        [tint(shape, base) drawInRect:b];
        UIImage *line = tex(@"roughline");
        if (!wave || !line) return;
        UIGraphicsImageRenderer *wr = [[UIGraphicsImageRenderer alloc] initWithSize:size];
        UIImage *waves = [wr imageWithActions:^(UIGraphicsImageRendererContext *w) {
            UIImage *t = tint(line, wave);
            // Tiles on whole pixels, overlapping by one: at fractional positions their soft edges left faint seams.
            CGFloat th = round(size.height * 0.55 / px) * px, tw = round(th * line.size.width / line.size.height / px) * px;
            for (CGFloat y = round(-th * 0.3 / px) * px; y < size.height; y += round(th * 1.15 / px) * px)
                for (CGFloat x = round(-tw * 0.5 / px) * px; x < size.width; x += tw - px) [t drawInRect:CGRectMake(x, y, tw, th)];
            [shape drawInRect:b blendMode:kCGBlendModeDestinationIn alpha:1];
        }];
        [waves drawInRect:b];
    }];
}
static UILabel *label(NSString *text, CGFloat size, BOOL bold, UIColor *color) {
    UILabel *l = [UILabel new];
    l.text = text, l.font = nx_ui_font(size, bold), l.textColor = color;
    l.textAlignment = NSTextAlignmentCenter, l.adjustsFontSizeToFitWidth = YES, l.minimumScaleFactor = 0.6;
    return l;
}

// ---- buttons --------------------------------------------------------------------------------------------------------
typedef NS_ENUM(int, NxBtnStyle) { NxBtnMain, NxBtnSecond, NxBtnList };
@interface NxGameButton : UIControl
@property(nonatomic, readonly) UILabel *title;
+ (instancetype)style:(NxBtnStyle)style title:(NSString *)title icon:(UIImage *)icon;
@end
@implementation NxGameButton {
    NxBtnStyle _style;
    UIImageView *_bg, *_icon;
    CGSize _drawn;
}
+ (instancetype)style:(NxBtnStyle)style title:(NSString *)title icon:(UIImage *)icon {
    NxGameButton *b = [self new];
    b->_style = style;
    b->_bg = [UIImageView new];
    [b addSubview:b->_bg];
    b->_title = label(title, 22, YES, style == NxBtnList ? navy(1) : UIColor.whiteColor);
    [b addSubview:b->_title];
    if (icon) b->_icon = [[UIImageView alloc] initWithImage:tint(icon, navy(1))], b->_icon.contentMode = UIViewContentModeScaleAspectFit, [b addSubview:b->_icon];
    b.isAccessibilityElement = YES, b.accessibilityTraits = UIAccessibilityTraitButton, b.accessibilityLabel = title;
    [b addTarget:b action:@selector(down) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [b addTarget:b action:@selector(up) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
                                                       UIControlEventTouchCancel | UIControlEventTouchDragExit];
    return b;
}
- (void)down { [UIView animateWithDuration:0.1 animations:^{ self.transform = CGAffineTransformMakeScale(0.95, 0.95); }]; }
- (void)up { [UIView animateWithDuration:0.1 animations:^{ self.transform = CGAffineTransformIdentity; }]; }
- (void)setEnabled:(BOOL)enabled { [super setEnabled:enabled]; self.alpha = enabled ? 1 : 0.5; }
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    if (!CGSizeEqualToSize(_drawn, b.size)) {
        _drawn = b.size;
        UIImage *shape = shape_tex(_style == NxBtnList ? @"btn_long" : @"btn_dialog");
        UIColor *base = rgb(_style == NxBtnMain ? 0xFF2E00 : _style == NxBtnSecond ? 0xFF8000 : 0xFFF0A8, 1);
        UIColor *wave = _style == NxBtnMain ? rgb(0xFF6900, 1) : _style == NxBtnList ? rgb(0xFFE353, 1) : nil;
        _bg.image = shape_with_waves(shape, b.size, base, wave);
        if (!_bg.image) _bg.backgroundColor = base, _bg.layer.cornerRadius = b.size.height / 2;
    }
    _bg.frame = b;
    CGFloat ih = _icon ? b.size.height * 0.5 : 0;
    _icon.frame = CGRectMake(b.size.height * 0.45, (b.size.height - ih) / 2, ih * 1.1, ih);
    _title.frame = CGRectInset(b, _icon ? b.size.height * 0.45 + ih * 1.2 : 20, 0);
}
@end

// ---- cloud dialog -----------------------------------------------------------------------------------------------------
@interface NxCloudDialog : UIView
+ (instancetype)title:(NSString *)title body:(NSString *)body main:(NSString *)main second:(NSString *)second
                  done:(void (^)(BOOL main))done;
- (void)showIn:(UIView *)host;
- (void)dismiss;
- (void)setBusy:(NSString *)text;   // replace the buttons with a waiting line
@end
@implementation NxCloudDialog {
    UIImageView *_cloud;
    UILabel *_title, *_body, *_busy;
    NxGameButton *_main, *_second;
    void (^_done)(BOOL);
}
+ (instancetype)title:(NSString *)title body:(NSString *)body main:(NSString *)main second:(NSString *)second done:(void (^)(BOOL))done {
    NxCloudDialog *d = [self new];
    d.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];
    d->_done = done;
    d->_cloud = [[UIImageView alloc] initWithImage:tint(nx_ui_cloud(), rgb(0xFFF2CA, 1))];
    if (!nx_ui_cloud()) d->_cloud.backgroundColor = rgb(0xFFF2CA, 1), d->_cloud.layer.cornerRadius = 40;
    d->_cloud.layer.shadowColor = UIColor.blackColor.CGColor, d->_cloud.layer.shadowOpacity = 0.16f, d->_cloud.layer.shadowRadius = 10;
    d->_cloud.layer.shadowOffset = CGSizeMake(0, 5);
    d->_cloud.userInteractionEnabled = YES;
    [d addSubview:d->_cloud];
    d->_title = label(title, 24, YES, navy(1));
    d->_body = label(body, 17, NO, navy(0.85)), d->_body.numberOfLines = 0, d->_body.adjustsFontSizeToFitWidth = NO;
    if (body) {   // the game font's lines sit tight: 1.2x line spacing
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.lineHeightMultiple = 1.2, ps.alignment = NSTextAlignmentCenter;
        d->_body.attributedText = [[NSAttributedString alloc] initWithString:body attributes:@{NSParagraphStyleAttributeName: ps,
                                       NSFontAttributeName: nx_ui_font(17, NO), NSForegroundColorAttributeName: navy(0.85)}];
    }
    d->_busy = label(@"", 18, YES, rgb(0xF2660D, 1));
    for (UIView *v in @[d->_title, d->_body, d->_busy]) [d->_cloud addSubview:v];
    if (main) {
        d->_main = [NxGameButton style:NxBtnMain title:main icon:nil];
        [d->_main addTarget:d action:@selector(tapMain) forControlEvents:UIControlEventTouchUpInside];
        [d->_cloud addSubview:d->_main];
    }
    if (second) {
        d->_second = [NxGameButton style:NxBtnSecond title:second icon:nil];
        [d->_second addTarget:d action:@selector(tapSecond) forControlEvents:UIControlEventTouchUpInside];
        [d->_cloud addSubview:d->_second];
    }
    return d;
}
- (void)tapMain { [self dismiss]; if (_done) _done(YES); }
- (void)tapSecond { [self dismiss]; if (_done) _done(NO); }
- (void)setBusy:(NSString *)text {
    _busy.text = text;
    _main.hidden = _second.hidden = text.length > 0;
    [self setNeedsLayout];
}
- (void)showIn:(UIView *)host {
    self.frame = host.bounds;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [host addSubview:self];
    self.alpha = 0;
    _cloud.transform = CGAffineTransformMakeScale(0.96, 0.96);
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.alpha = 1;
        self->_cloud.transform = CGAffineTransformIdentity;
    } completion:nil];
}
- (void)dismiss {
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{ self.alpha = 0; }
                     completion:^(BOOL f) { [self removeFromSuperview]; }];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    // The cloud is sized around its content: its wavy outline dips well into its rectangle, so everything (text and
    // buttons) keeps 60 pt from the sides and 48 pt from the top and bottom.
    const CGFloat side = 60, top = 48;
    CGFloat cw = MIN(440, b.size.width - 32 - 2 * side), w = cw + 2 * side, y = top;
    _title.frame = CGRectMake(side, y, cw, 30), y += 40;
    CGSize bs = [_body sizeThatFits:CGSizeMake(cw, 400)];
    if (_body.text.length) _body.frame = CGRectMake(side, y, cw, bs.height), y += bs.height + 20;
    if (_busy.text.length) {
        _busy.frame = CGRectMake(side, y, cw, 44), y += 44;
    } else if (_main || _second) {
        CGFloat bw = _main && _second ? MIN(200, (cw - 14) / 2) : 220, bh = 50, x = (w - (_main && _second ? bw * 2 + 14 : bw)) / 2;
        if (_second) _second.frame = CGRectMake(x, y, bw, bh), x += bw + 14;   // second on the left, like the game
        if (_main) _main.frame = CGRectMake(x, y, bw, bh);
        y += bh;
    }
    y += top;
    y = MIN(y, b.size.height - 16);
    _cloud.frame = CGRectMake((b.size.width - w) / 2, (b.size.height - y) / 2, w, y);
}
@end

UIView *nx_game_dialog(NSString *title, NSString *body, NSString *main, NSString *second, UIView *host, void (^done)(BOOL main)) {
    NxCloudDialog *d = [NxCloudDialog title:title body:body main:main second:second done:done];
    [d showIn:host];
    return d;
}
// A game-style button for the launcher (style 0 main, 1 second, 2 list).
UIControl *nx_game_button(int style, NSString *title, UIImage *icon) { return [NxGameButton style:(NxBtnStyle)style title:title icon:icon]; }
