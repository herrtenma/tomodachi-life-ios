// Host UI for library applets (iOS): an alert with a text field stands in for the software keyboard.
// Same contract as src/host_ui.m: the dialog runs on the main thread, the guest waits on the applet's events.
#import <UIKit/UIKit.h>
#include <stdint.h>
#include <stdlib.h>

typedef void (*NxTextDone)(void *ctx, const uint16_t *text, int len, int accepted);

int nx_host_ui_available(void) { return 1; }

static NSString *str16(const uint16_t *s, int max) {
    int n = 0;
    while (s && n < max && s[n]) n++;
    return n ? [NSString stringWithCharacters:s length:n] : @"";
}

static UIViewController *top_controller(void) {
    UIViewController *vc = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
        if ([sc isKindOfClass:UIWindowScene.class])
            for (UIWindow *w in ((UIWindowScene *)sc).windows)
                if (w.isKeyWindow) vc = w.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

void nx_host_text_prompt(const uint16_t *header, const uint16_t *guide, const uint16_t *message,
                         const uint16_t *initial, int initial_len, int max_len, NxTextDone done, void *ctx) {
    NSString *h = str16(header, 65), *g = str16(guide, 257), *m = str16(message, 511);
    NSString *init = initial_len > 0 ? [NSString stringWithCharacters:initial length:initial_len] : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:h.length ? h : @"Enter text"
                             message:m.length ? m : (max_len > 0 ? [NSString stringWithFormat:@"Up to %d characters.", max_len] : nil)
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
            f.text = init;
            f.placeholder = g;
        }];
        void (^finish)(int) = ^(int ok) {
            NSString *t = a.textFields.firstObject.text ?: @"";
            if (max_len > 0 && (int)t.length > max_len) t = [t substringToIndex:max_len];
            int n = (int)t.length;
            uint16_t *buf = calloc(n ? n : 1, 2);
            [t getCharacters:buf range:NSMakeRange(0, n)];
            done(ctx, buf, n, ok);
            free(buf);
        };
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { finish(1); }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { finish(0); }]];
        [top_controller() presentViewController:a animated:YES completion:nil];
    });
}
