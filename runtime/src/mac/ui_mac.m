// Shared AppKit pieces of the Mac launcher (see ui_mac.h).
#import "ui_mac.h"

NSColor *nx_rgb(uint32_t c, CGFloat a) {
    return [NSColor colorWithSRGBRed:(c >> 16 & 255) / 255.0 green:(c >> 8 & 255) / 255.0 blue:(c & 255) / 255.0 alpha:a];
}

@implementation NxView
- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)setFrameSize:(NSSize)s {
    BOOL changed = !NSEqualSizes(s, self.frame.size);
    [super setFrameSize:s];
    if (changed) self.needsLayout = YES, self.needsDisplay = YES;
}
@end

// ---- canvas: the phone's logical size, scaled to the window -----------------------------------------------------
// The iOS launcher is laid out for a landscape phone (~390 pt high). Here the canvas is 430 logical points high (a
// little more room than the phone: the window has no notch or home bar), never smaller than the window's own points
// and at least 700 wide.
@implementation NxCanvas
- (void)setFrameSize:(NSSize)s {
    [super setFrameSize:s];
    CGFloat k = MAX(1, MIN(s.height / 430, s.width / 700));
    _scale = k;
    [self setBoundsSize:NSMakeSize(s.width / k, s.height / k)];
    for (NSView *v in self.subviews) v.frame = self.bounds;
}
- (void)didAddSubview:(NSView *)v {
    [super didAddSubview:v];
    v.frame = self.bounds;
}
- (NSView *)hitTest:(NSPoint)p {
    NSView *v = [super hitTest:p];
    return _passThrough && v == self ? nil : v;
}
@end

// ---- label ---------------------------------------------------------------------------------------------------------
@implementation NxLabel
@synthesize text = _text;
+ (instancetype)text:(NSString *)text font:(NSFont *)font color:(NSColor *)color {
    NxLabel *l = [self new];
    l.text = text, l.font = font, l.textColor = color;
    return l;
}
- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    _alignment = NSTextAlignmentCenter, _lines = 1, _minScale = 1, _lineHeightMultiple = 0;
    _font = [NSFont systemFontOfSize:17], _textColor = NSColor.blackColor;
    return self;
}
- (NSView *)hitTest:(NSPoint)p { return nil; }   // labels never take clicks (as UILabel)
- (void)setText:(NSString *)t { _text = [t copy], _attributedText = nil, self.needsDisplay = YES; }
- (NSString *)text { return _attributedText ? _attributedText.string : _text; }
- (void)setAttributedText:(NSAttributedString *)a { _attributedText = [a copy], _text = nil, self.needsDisplay = YES; }
- (void)setFont:(NSFont *)f { _font = f, self.needsDisplay = YES; }
- (void)setTextColor:(NSColor *)c { _textColor = c, self.needsDisplay = YES; }
- (void)setAlignment:(NSTextAlignment)a { _alignment = a, self.needsDisplay = YES; }
- (void)setTextShadow:(NSShadow *)s { _textShadow = s, self.needsDisplay = YES; }
- (NSAttributedString *)stringScaled:(CGFloat)k {
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = _alignment;
    ps.lineBreakMode = _lines == 1 ? NSLineBreakByTruncatingTail : NSLineBreakByWordWrapping;
    if (_lineHeightMultiple > 0) ps.lineHeightMultiple = _lineHeightMultiple;
    NSMutableAttributedString *s;
    if (_attributedText) {
        s = [_attributedText mutableCopy];
        [s enumerateAttribute:NSParagraphStyleAttributeName inRange:NSMakeRange(0, s.length) options:0 usingBlock:^(id v, NSRange r, BOOL *stop) {
            NSMutableParagraphStyle *p = v ? [v mutableCopy] : [ps mutableCopy];
            if (!v) p.alignment = self->_alignment;
            p.lineBreakMode = ps.lineBreakMode;
            [s addAttribute:NSParagraphStyleAttributeName value:p range:r];
        }];
        [s enumerateAttribute:NSForegroundColorAttributeName inRange:NSMakeRange(0, s.length) options:0 usingBlock:^(id v, NSRange r, BOOL *stop) {
            if (!v && self->_textColor) [s addAttribute:NSForegroundColorAttributeName value:self->_textColor range:r];
        }];
        [s enumerateAttribute:NSFontAttributeName inRange:NSMakeRange(0, s.length) options:0 usingBlock:^(id v, NSRange r, BOOL *stop) {
            NSFont *f = v ?: self->_font;
            if (k != 1 || !v) [s addAttribute:NSFontAttributeName value:[NSFont fontWithDescriptor:f.fontDescriptor size:f.pointSize * k] range:r];
        }];
    } else {
        NSFont *f = k == 1 ? _font : [NSFont fontWithDescriptor:_font.fontDescriptor size:_font.pointSize * k];
        s = [[NSMutableAttributedString alloc] initWithString:_text ?: @""
            attributes:@{NSFontAttributeName : f, NSForegroundColorAttributeName : _textColor ?: NSColor.blackColor, NSParagraphStyleAttributeName : ps}];
    }
    if (_textShadow) [s addAttribute:NSShadowAttributeName value:_textShadow range:NSMakeRange(0, s.length)];
    return s;
}
static const NSStringDrawingOptions kDraw = NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading;
- (CGSize)sizeThatFits:(CGSize)size {
    NSAttributedString *s = [self stringScaled:1];
    if (_lines == 1) {
        NSSize n = s.size;
        return CGSizeMake(ceil(n.width), ceil(n.height));
    }
    NSRect r = [s boundingRectWithSize:NSMakeSize(size.width, CGFLOAT_MAX) options:kDraw];
    return CGSizeMake(ceil(r.size.width), ceil(r.size.height));
}
- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    NSAttributedString *s = [self stringScaled:1];
    if (_lines == 1 && _minScale < 1) {
        CGFloat w = s.size.width;
        if (w > b.size.width && w > 0) s = [self stringScaled:MAX(_minScale, b.size.width / w * 0.995)];
    }
    NSRect r = [s boundingRectWithSize:NSMakeSize(b.size.width, _lines == 1 ? CGFLOAT_MAX : b.size.height + 1000) options:kDraw];
    CGFloat h = MIN(ceil(r.size.height), _lines == 1 ? CGFLOAT_MAX : b.size.height);
    [s drawWithRect:NSMakeRect(0, (b.size.height - h) / 2, b.size.width, h)
            options:kDraw | (_lines == 1 ? NSStringDrawingTruncatesLastVisibleLine : 0)];
}
@end

// ---- pressable -----------------------------------------------------------------------------------------------------
@implementation NxPressable {
    BOOL _pressed, _inside;
}
- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    _pressScale = 0.95, _enabled = YES, _dimWhenDisabled = YES;
    return self;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    if (_dimWhenDisabled) self.alphaValue = enabled ? 1 : 0.5;
    [self.window invalidateCursorRectsForView:self];
}
- (void)resetCursorRects {
    if (_enabled && !self.hidden) [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}
- (void)press:(BOOL)down {
    if (down == _pressed) return;
    _pressed = down;
    if (_pressScale != 1)
        nx_animate_scale(self, @"press", down ? 1 : _pressScale, down ? _pressScale : 1, 0.1, kCAMediaTimingFunctionEaseOut, down, NO);
    if (down && _onDown) _onDown();
    if (!down && _onUp) _onUp();
}
- (void)mouseDown:(NSEvent *)e {
    if (!_enabled) return;
    _inside = YES;
    [self press:YES];
}
- (void)mouseDragged:(NSEvent *)e {
    if (!_enabled) return;
    _inside = NSPointInRect([self convertPoint:e.locationInWindow fromView:nil], self.bounds);
    [self press:_inside];
}
- (void)mouseUp:(NSEvent *)e {
    if (!_enabled) return;
    BOOL tap = _pressed && NSPointInRect([self convertPoint:e.locationInWindow fromView:nil], self.bounds);
    [self press:NO];
    if (tap && _onTap) _onTap();
}
- (void)rightMouseDown:(NSEvent *)e {
    if (_onRightClick) _onRightClick(e);
    else [super rightMouseDown:e];
}
@end

// ---- image view ----------------------------------------------------------------------------------------------------
@implementation NxImageView
- (void)setImage:(NSImage *)i { _image = i, self.needsDisplay = YES; }
- (void)setMask:(NSImage *)m { _mask = m, self.needsDisplay = YES; }
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (void)drawRect:(NSRect)dirty {
    NSImage *img = _image;
    if (!img || img.size.width <= 0 || img.size.height <= 0) return;
    NSRect b = self.bounds, r = b;
    if (_fit || _fill) {
        CGFloat sx = b.size.width / img.size.width, sy = b.size.height / img.size.height, k = _fit ? MIN(sx, sy) : MAX(sx, sy);
        CGSize s = CGSizeMake(img.size.width * k, img.size.height * k);
        r = NSMakeRect((b.size.width - s.width) / 2, (b.size.height - s.height) / 2, s.width, s.height);
    }
    CGContextRef g = NSGraphicsContext.currentContext.CGContext;
    if (_mask || _fill) {
        CGContextSaveGState(g);
        NSRectClip(b);
        CGContextBeginTransparencyLayer(g, NULL);
    }
    [img drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    if (_mask) [_mask drawInRect:b fromRect:NSZeroRect operation:NSCompositingOperationDestinationIn fraction:1 respectFlipped:YES hints:nil];
    if (_mask || _fill) {
        CGContextEndTransparencyLayer(g);
        CGContextRestoreGState(g);
    }
}
@end

// ---- images --------------------------------------------------------------------------------------------------------
NSImage *nx_png(NSString *path, CGFloat scale) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    NSBitmapImageRep *rep = d ? [NSBitmapImageRep imageRepWithData:d] : nil;
    if (!rep) return nil;
    NSSize s = NSMakeSize(rep.pixelsWide / scale, rep.pixelsHigh / scale);
    rep.size = s;
    NSImage *img = [[NSImage alloc] initWithSize:s];
    [img addRepresentation:rep];
    return img;
}
NSImage *nx_tinted(NSImage *mask, NSColor *c) {
    if (!mask) return nil;
    NSImage *t = [NSImage imageWithSize:mask.size flipped:NO drawingHandler:^BOOL(NSRect r) {
        [mask drawInRect:r];
        [c set];
        NSRectFillUsingOperation(r, NSCompositingOperationSourceAtop);
        return YES;
    }];
    return t;
}
NSImage *nx_symbol(NSString *name, CGFloat points, NSFontWeight weight) {
    NSImage *i = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    return [i imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:points weight:weight]];
}
CGImageRef nx_cgimage(NSImage *img, CGSize points, CGFloat k) {
    size_t w = (size_t)ceil(points.width * k), h = (size_t)ceil(points.height * k);
    if (!img || !w || !h) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef g = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!g) return NULL;
    CGContextScaleCTM(g, k, k);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:g flipped:NO];
    [img drawInRect:NSMakeRect(0, 0, points.width, points.height)];
    [NSGraphicsContext restoreGraphicsState];
    CGImageRef out = CGBitmapContextCreateImage(g);
    CGContextRelease(g);
    return out;
}

// ---- animation -----------------------------------------------------------------------------------------------------
CATransform3D nx_center_scale(NSView *v, CGFloat sx, CGFloat sy) {
    CALayer *l = v.layer;
    CGFloat dx = l.bounds.size.width * (0.5 - l.anchorPoint.x), dy = l.bounds.size.height * (0.5 - l.anchorPoint.y);
    CATransform3D t = CATransform3DMakeTranslation(dx, dy, 0);
    t = CATransform3DScale(t, sx, sy, 1);
    return CATransform3DTranslate(t, -dx, -dy, 0);
}
void nx_animate_scale(NSView *v, NSString *key, CGFloat from, CGFloat to, CFTimeInterval d, CAMediaTimingFunctionName timing, BOOL hold,
                      BOOL repeatReverse) {
    if (!v.layer) return;
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform"];
    a.fromValue = [NSValue valueWithCATransform3D:nx_center_scale(v, from, from)];
    a.toValue = [NSValue valueWithCATransform3D:nx_center_scale(v, to, to)];
    a.duration = d, a.additive = YES;
    a.timingFunction = [CAMediaTimingFunction functionWithName:timing];
    if (hold) a.fillMode = kCAFillModeForwards, a.removedOnCompletion = NO;
    if (repeatReverse) a.autoreverses = YES, a.repeatCount = HUGE_VALF, a.removedOnCompletion = NO;
    [v.layer addAnimation:a forKey:key];
}
void nx_spring_scale(NSView *v, NSString *key, CGFloat from, CGFloat to, CGFloat damping, CFTimeInterval delay) {
    if (!v.layer) return;
    CASpringAnimation *a = [CASpringAnimation animationWithKeyPath:@"transform"];
    a.fromValue = [NSValue valueWithCATransform3D:nx_center_scale(v, from, from)];
    a.toValue = [NSValue valueWithCATransform3D:nx_center_scale(v, to, to)];
    a.additive = YES;
    a.damping = damping, a.stiffness = 220, a.mass = 1;
    a.duration = a.settlingDuration;
    a.beginTime = delay > 0 ? CACurrentMediaTime() + delay : 0;
    a.fillMode = kCAFillModeBackwards;
    [v.layer addAnimation:a forKey:key];
}
void nx_fade(NSView *v, CGFloat to, NSTimeInterval d, void (^done)(void)) {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) {
        c.duration = d;
        c.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        v.animator.alphaValue = to;
    } completionHandler:done];
}

// ---- dialogs -------------------------------------------------------------------------------------------------------
static NSAlert *make_alert(NSString *title, NSString *msg, NSArray<NSString *> *buttons, NSInteger destructive) {
    NSAlert *a = [NSAlert new];
    a.messageText = title ?: @"";
    a.informativeText = msg ?: @"";
    for (NSUInteger i = 0; i < buttons.count; i++) {
        NSButton *b = [a addButtonWithTitle:buttons[i]];
        if ((NSInteger)i == destructive) b.hasDestructiveAction = YES;
        if ([buttons[i] isEqualToString:@"Cancel"]) b.keyEquivalent = @"\e";
    }
    return a;
}
void nx_alert(NSWindow *w, NSString *title, NSString *msg, NSArray<NSString *> *buttons, NSInteger destructive, void (^done)(NSInteger)) {
    NSAlert *a = make_alert(title, msg, buttons.count ? buttons : @[@"OK"], destructive);
    void (^end)(NSModalResponse) = ^(NSModalResponse r) { if (done) done(r - NSAlertFirstButtonReturn); };
    if (w) [a beginSheetModalForWindow:w completionHandler:end];
    else end([a runModal]);
}
void nx_alert_ok(NSWindow *w, NSString *title, NSString *msg) { nx_alert(w, title, msg, @[@"OK"], -1, nil); }
void nx_prompt(NSWindow *w, NSString *title, NSString *msg, NSString *value, NSString *placeholder, NSArray<NSString *> *buttons,
               void (^done)(NSInteger, NSString *)) {
    NSAlert *a = make_alert(title, msg, buttons, -1);
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    f.stringValue = value ?: @"";
    f.placeholderString = placeholder;
    a.accessoryView = f;
    a.window.initialFirstResponder = f;
    void (^end)(NSModalResponse) = ^(NSModalResponse r) { if (done) done(r - NSAlertFirstButtonReturn, f.stringValue); };
    if (w) [a beginSheetModalForWindow:w completionHandler:end];
    else end([a runModal]);
}
void nx_busy(NSWindow *w, NSString *text, id (^work)(void), void (^then)(id)) {
    NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 300, 84) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NSProgressIndicator *spin = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(24, 26, 32, 32)];
    spin.style = NSProgressIndicatorStyleSpinning;
    [spin startAnimation:nil];
    NSTextField *t = [NSTextField labelWithString:text];
    t.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    t.frame = NSMakeRect(68, 32, 216, 20);
    [p.contentView addSubview:spin], [p.contentView addSubview:t];
    void (^run)(void) = ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            id r = work();
            dispatch_async(dispatch_get_main_queue(), ^{
                if (w) [w endSheet:p];
                else [p orderOut:nil];
                then(r);
            });
        });
    };
    if (w) [w beginSheet:p completionHandler:nil];
    else [p makeKeyAndOrderFront:nil];
    run();
}
