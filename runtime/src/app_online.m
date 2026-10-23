// See app_online.h.
#import "app_online.h"
#include <fcntl.h>
#include <unistd.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif
#include <sys/sysctl.h>

static NSString *const kRunning = @".running", *const kCrashed = @".crashed", *const kPrevLog = @"nxrt-prev.log", *const kLog = @"nxrt.log";
static BOOL g_last_crashed;

static NSString *news_url(void) {
    const char *e = getenv("NXRT_NEWS_URL");
    return e ? @(e) : @"https://raw.githubusercontent.com/herrtenma/tomodachi-life-ios/main/news.json";
}
static NSString *feedback_url(void) {
    const char *e = getenv("NXRT_FEEDBACK_URL");
    if (e) return @(e);
    NSString *p = [NSBundle.mainBundle objectForInfoDictionaryKey:@"NxFeedbackURL"];
    return p.length ? p : @"https://tomodachi-feedback.tomodachi-island-backend.workers.dev/feedback";
}
static NSUserDefaults *ud(void) { return NSUserDefaults.standardUserDefaults; }

NSString *nx_app_version(void) { return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0"; }

static NSString *device_id(void) {
    NSString *d = [ud() stringForKey:@"nx.deviceId"];
    if (!d) [ud() setObject:d = NSUUID.UUID.UUIDString forKey:@"nx.deviceId"];   // random, not tied to the phone or the Apple ID
    return d;
}

// ---- News ----
static NSString *news_cache(void) {
    NSString *c = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [c stringByAppendingPathComponent:@"nx-news.json"];
}
void nx_news_fetch(void (^done)(NSDictionary *)) {
    NSURLRequest *rq = [NSURLRequest requestWithURL:[NSURL URLWithString:news_url()] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
    [[NSURLSession.sharedSession dataTaskWithRequest:rq completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSDictionary *j = nil;
        if (data && [(NSHTTPURLResponse *)resp statusCode] == 200) {
            id o = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([o isKindOfClass:NSDictionary.class] && [o[@"entries"] isKindOfClass:NSArray.class]) {
                j = o;
                [data writeToFile:news_cache() atomically:YES];
            }
        }
        if (!j) {
            NSData *c = [NSData dataWithContentsOfFile:news_cache()];
            id o = c ? [NSJSONSerialization JSONObjectWithData:c options:0 error:nil] : nil;
            if ([o isKindOfClass:NSDictionary.class]) j = o;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(j); });
    }] resume];
}
BOOL nx_news_update_available(NSDictionary *news) {
    NSString *latest = [news[@"latest"] isKindOfClass:NSString.class] ? news[@"latest"] : nil;
    return latest && [latest compare:nx_app_version() options:NSNumericSearch] == NSOrderedDescending;
}

// ---- Log ----
static NSString *log_tail(NSString *path, size_t max) {
    NSFileHandle *f = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!f) return @"";
    unsigned long long size = [f seekToEndOfFile];
    [f seekToFileOffset:size > max ? size - max : 0];
    NSData *d = [f readDataToEndOfFile];
    [f closeFile];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    return [s stringByReplacingOccurrencesOfString:NSHomeDirectory() withString:@"~"];
}

// ---- Feedback ----
static NSString *model_id(void) {
    size_t n = 0;
    sysctlbyname("hw.machine", NULL, &n, NULL, 0);
    char *m = calloc(1, n + 1);
    sysctlbyname("hw.machine", m, &n, NULL, 0);
    NSString *s = @(m);
    free(m);
    return s;
}
void nx_feedback_send(NSString *kind, NSString *message, NSString *contact, BOOL withLog, void (^done)(NSString *)) {
    NSMutableArray<NSNumber *> *sent = [NSMutableArray array];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    for (NSNumber *t in [ud() arrayForKey:@"nx.feedbackTimes"]) if (now - t.doubleValue < 3600) [sent addObject:t];
    if (sent.count >= 3) { done(@"You've sent a few reports already. Please try again in an hour."); return; }

    NSMutableString *log = [NSMutableString string];
    if (withLog) {
        if (nx_last_session_crashed() || [kind isEqual:@"crash"]) [log appendFormat:@"=== previous session ===\n%@\n", log_tail(kPrevLog, 120000)];
        [log appendFormat:@"=== this session ===\n%@", log_tail(kLog, 120000)];
    }
    NSString *os =
#if TARGET_OS_IPHONE
        [UIDevice.currentDevice.systemName stringByAppendingFormat:@" %@", UIDevice.currentDevice.systemVersion];
#else
        NSProcessInfo.processInfo.operatingSystemVersionString;
#endif
    NSDictionary *body = @{@"device" : device_id(), @"kind" : kind, @"message" : message ?: @"", @"contact" : contact ?: @"", @"app" : nx_app_version(),
                           @"os" : os, @"model" : model_id(), @"slot" : [ud() objectForKey:@"nx.slot"] ? [NSString stringWithFormat:@"%@", [ud() objectForKey:@"nx.slot"]] : @"",
                           @"log" : log};
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:feedback_url()] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    rq.HTTPMethod = @"POST";
    rq.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [rq setValue:@"application/json" forHTTPHeaderField:@"content-type"];
    [[NSURLSession.sharedSession dataTaskWithRequest:rq completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSString *why = nil;
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        if (err || !resp) why = @"Couldn't reach the server. Check your connection and try again.";
        else if (code == 429) {
            id j = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            why = [j isKindOfClass:NSDictionary.class] && [j[@"reason"] isKindOfClass:NSString.class] ? [j[@"reason"] stringByAppendingString:@". Please try again tomorrow."] : @"Too many reports today. Please try again tomorrow.";
        } else if (code != 200) why = [NSString stringWithFormat:@"The server didn't accept it (%ld).", (long)code];
        if (!why) {
            [sent addObject:@(now)];
            [ud() setObject:sent forKey:@"nx.feedbackTimes"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(why); });
    }] resume];
}

// ---- Crash markers ----
void nx_session_begin(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    g_last_crashed = [fm fileExistsAtPath:kRunning] || [fm fileExistsAtPath:kCrashed];
    if ([fm fileExistsAtPath:kLog]) {   // the log is reopened for writing right after this: keep the last session's
        [fm removeItemAtPath:kPrevLog error:nil];
        [fm moveItemAtPath:kLog toPath:kPrevLog error:nil];
    }
    [fm removeItemAtPath:kCrashed error:nil];
    close(open(kRunning.fileSystemRepresentation, O_CREAT | O_WRONLY, 0644));
}
void nx_session_resume(void) { close(open(kRunning.fileSystemRepresentation, O_CREAT | O_WRONLY, 0644)); }
void nx_session_end(void) { unlink(kRunning.fileSystemRepresentation); }
BOOL nx_last_session_crashed(void) { return g_last_crashed; }
void nx_crash_marker_write(void) { close(open(".crashed", O_CREAT | O_WRONLY, 0644)); }
