// Host UI for library applets: a text dialog stands in for the software keyboard.
// The dialog runs on the main thread; the guest keeps running and waits on the applet's events.
#import <Cocoa/Cocoa.h>
#include <stdint.h>
#include <stdlib.h>

typedef void (*NxTextDone)(void *ctx, const uint16_t *text, int len, int accepted);

int nx_host_ui_available(void) { return !getenv("NXRT_HEADLESS"); }

static NSString *str16(const uint16_t *s, int max) {
    int n = 0;
    while (s && n < max && s[n]) n++;
    return n ? [NSString stringWithCharacters:s length:n] : @"";
}

void nx_host_text_prompt(const uint16_t *header, const uint16_t *guide, const uint16_t *message,
                         const uint16_t *initial, int initial_len, int max_len, NxTextDone done, void *ctx) {
    NSString *h = str16(header, 65), *g = str16(guide, 257), *m = str16(message, 511);
    NSString *init = initial_len > 0 ? [NSString stringWithCharacters:initial length:initial_len] : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [NSAlert new];
        alert.messageText = h.length ? h : @"Enter text";
        alert.informativeText = m.length ? m : (max_len > 0 ? [NSString stringWithFormat:@"Up to %d characters.", max_len] : @"");
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Cancel"];
        NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
        field.stringValue = init;
        field.placeholderString = g;
        alert.accessoryView = field;
        alert.window.initialFirstResponder = field;
        int ok = [alert runModal] == NSAlertFirstButtonReturn;
        NSString *t = field.stringValue;
        int n = (int)t.length;
        uint16_t *buf = calloc(n ? n : 1, 2);
        [t getCharacters:buf range:NSMakeRange(0, n)];
        done(ctx, buf, n, ok);
        free(buf);
    });
}
