// Save import (see save_import.h). Saves are plain files on every emulator (Mii.sav, Player.sav, Map.sav, Ugc/), so
// importing is finding that folder and copying it; a .zip is unpacked to a temporary folder first.
#import "save_import.h"
#include <zlib.h>

static const char *kGameId = "010051F0207B2000";

static uint32_t le32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t le16(const uint8_t *p) { return p[0] | p[1] << 8; }

// Unpacks a zip (stored / deflate, no zip64) into `dest`. Entries with .. or an absolute path are refused.
static NSString *unzip(NSString *zip, NSString *dest) {
    NSData *d = [NSData dataWithContentsOfFile:zip options:NSDataReadingMappedIfSafe error:nil];
    const uint8_t *b = d.bytes;
    size_t n = d.length;
    if (n < 22) return @"That zip file is empty or damaged.";
    size_t e = n - 22;
    for (size_t lim = MIN(n - 22, 65557); lim && le32(b + e) != 0x06054b50; lim--) e--;
    if (le32(b + e) != 0x06054b50) return @"That zip file is damaged.";
    unsigned count = le16(b + e + 10);
    size_t p = le32(b + e + 16);
    NSFileManager *fm = NSFileManager.defaultManager;
    unsigned long long total = 0;
    for (unsigned i = 0; i < count; i++) {
        if (p + 46 > n || le32(b + p) != 0x02014b50) return @"That zip file is damaged.";
        unsigned method = le16(b + p + 10);
        size_t csz = le32(b + p + 20), usz = le32(b + p + 24), nl = le16(b + p + 28), el = le16(b + p + 30), cl = le16(b + p + 32), lo = le32(b + p + 42);
        if (p + 46 + nl > n) return @"That zip file is damaged.";
        NSString *name = [[NSString alloc] initWithBytes:b + p + 46 length:nl encoding:NSUTF8StringEncoding];
        p += 46 + nl + el + cl;
        if (!name || [name hasSuffix:@"/"] || [name hasPrefix:@"__MACOSX/"] || [name.lastPathComponent isEqual:@".DS_Store"]) continue;
        if ([name hasPrefix:@"/"] || [name.pathComponents containsObject:@".."]) return @"That zip file has unsafe paths in it.";
        if (csz == 0xFFFFFFFF || usz == 0xFFFFFFFF) return @"That zip file is too large (zip64).";
        if ((total += usz) > (1ull << 30)) return @"That zip file is far larger than a save.";
        if (lo + 30 > n || le32(b + lo) != 0x04034b50) return @"That zip file is damaged.";
        size_t ds = lo + 30 + le16(b + lo + 26) + le16(b + lo + 28);
        if (ds + csz > n) return @"That zip file is damaged.";
        NSMutableData *out = [NSMutableData dataWithLength:usz];
        if (method == 0 && csz == usz) memcpy(out.mutableBytes, b + ds, usz);
        else if (method == 8) {
            z_stream z = {0};
            if (inflateInit2(&z, -15) != Z_OK) return @"Couldn't unpack the zip file.";
            z.next_in = (Bytef *)(b + ds), z.avail_in = (uInt)csz, z.next_out = out.mutableBytes, z.avail_out = (uInt)usz;
            int r = inflate(&z, Z_FINISH);
            inflateEnd(&z);
            if (r != Z_STREAM_END || z.total_out != usz) return @"Couldn't unpack the zip file (damaged?).";
        } else return @"That zip file uses a compression this app can't read.";
        NSString *to = [dest stringByAppendingPathComponent:name];
        [fm createDirectoryAtPath:to.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if (![out writeToFile:to atomically:NO]) return @"Couldn't write the unpacked save.";
    }
    return nil;
}

// The folder with Mii.sav in it (newest wins: Ryujinx keeps a working copy "0" and a committed one "1").
static NSString *find_save(NSString *root, NSString **wrongGame) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *best = nil;
    NSDate *bestDate = nil;
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
    for (NSString *rel in en) {
        if (![rel.lastPathComponent isEqual:@"Mii.sav"]) continue;
        NSDictionary *a = [fm attributesOfItemAtPath:[root stringByAppendingPathComponent:rel] error:nil];
        if ([a.fileType isEqual:NSFileTypeDirectory]) continue;
        NSString *dir = [root stringByAppendingPathComponent:rel.stringByDeletingLastPathComponent];
        // A save of another title (a 16 hex digit folder name other than this game's) isn't ours.
        BOOL other = NO;
        for (NSString *c in [root stringByAppendingPathComponent:rel].pathComponents) {
            if (c.length == 16 && [c hasPrefix:@"0100"] && [c rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEFabcdef"] invertedSet]].location == NSNotFound
                && strcasecmp(c.UTF8String, kGameId)) other = YES;
        }
        if (other) { *wrongGame = dir; continue; }
        NSDate *m = a.fileModificationDate ?: NSDate.distantPast;
        if (!best || [m compare:bestDate] == NSOrderedDescending) best = dir, bestDate = m;
    }
    return best;
}

NSString *nx_save_import(NSString *source, NSString *slotDir, int *files) {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:source isDirectory:&isDir]) return @"That file or folder isn't there any more.";
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"nx-import-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [fm createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *(^finish)(NSString *) = ^NSString *(NSString *msg) { [fm removeItemAtPath:tmp error:nil]; return msg; };
    NSString *root = source;
    if (!isDir) {
        if (![source.pathExtension.lowercaseString isEqual:@"zip"]) return finish(@"Choose a save folder, or a .zip of one.");
        NSString *why = unzip(source, tmp);
        if (why) return finish(why);
        root = tmp;
    }
    NSString *wrong = nil;
    NSString *dir = find_save(root, &wrong);
    if (!dir) return finish(wrong ? @"That is another game's save, not Tomodachi Life: Living the Dream's."
                                  : @"No Tomodachi Life save found there (a folder with Mii.sav, Player.sav and Map.sav).");
    for (NSString *f in @[@"Mii.sav", @"Player.sav"])
        if ([[fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:f] error:nil] fileSize] == 0)
            return finish([NSString stringWithFormat:@"%@ is missing or empty in that save.", f]);

    [fm createDirectoryAtPath:slotDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *neu = [slotDir stringByAppendingPathComponent:@"save.importing"];
    [fm removeItemAtPath:neu error:nil];
    [fm createDirectoryAtPath:neu withIntermediateDirectories:YES attributes:nil error:nil];
    int n = 0;
    NSError *err = nil;
    for (NSString *rel in [fm enumeratorAtPath:dir]) {
        if ([rel.pathComponents.firstObject hasPrefix:@"."] || [rel.lastPathComponent hasPrefix:@"."]) continue;   // .DS_Store, emulator metadata
        NSString *from = [dir stringByAppendingPathComponent:rel], *to = [neu stringByAppendingPathComponent:rel];
        BOOL d = NO;
        [fm fileExistsAtPath:from isDirectory:&d];
        if (d) { [fm createDirectoryAtPath:to withIntermediateDirectories:YES attributes:nil error:nil]; continue; }
        if (![fm copyItemAtPath:from toPath:to error:&err]) {
            [fm removeItemAtPath:neu error:nil];
            return finish([NSString stringWithFormat:@"Couldn't copy the save: %@", err.localizedDescription]);
        }
        n++;
    }
    NSString *save = [slotDir stringByAppendingPathComponent:@"save"];
    if ([fm fileExistsAtPath:save]) {
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"yyyyMMdd-HHmmss";
        NSString *old = [slotDir stringByAppendingPathComponent:[@"save-before-import-" stringByAppendingString:[df stringFromDate:NSDate.date]]];
        if (![fm moveItemAtPath:save toPath:old error:&err]) {
            [fm removeItemAtPath:neu error:nil];
            return finish([NSString stringWithFormat:@"Couldn't set the old save aside: %@", err.localizedDescription]);
        }
    }
    if (![fm moveItemAtPath:neu toPath:save error:&err]) return finish([NSString stringWithFormat:@"Couldn't finish the import: %@", err.localizedDescription]);
    [fm removeItemAtPath:[slotDir stringByAppendingPathComponent:@"snapshot.jpg"] error:nil];   // the card's picture of the old island
    if (files) *files = n;
    return finish(nil);
}
