// make check DUMP=<dir>: translate every <dir>/bin/<hash>.<kind>.bin (+ .c1 / .ctl) with the on-device pipeline and
// compare with the offline pipeline's <dir>/msl/<name>.metal and <dir>/spv/<name>.json, byte for byte.
#import <Foundation/Foundation.h>

int nxsh_translate(const uint8_t *code, int code_len, const uint8_t *c1, int c1_len, const uint8_t *ctl, int ctl_len,
                   uint8_t **spv, int *spv_len, char **json, char **err);
int nxsh_fix_msl(const char *msl, int vertex, char **out, char **err);
void nxsh_free(void *p);
int nx_spirv_to_msl(const char *spv_path, const char *msl_path);

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: xlatcheck <dump dir>\n"); return 2; }
        NSString *dir = @(argv[1]), *tmp = NSTemporaryDirectory();
        NSArray *files = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:[dir stringByAppendingPathComponent:@"bin"] error:nil]
                          sortedArrayUsingSelector:@selector(compare:)];
        int same = 0, msl_diff = 0, json_diff = 0, failed = 0, no_ref = 0;
        double t = 0;
        for (NSString *f in files) {
            if (![f hasSuffix:@".bin"]) continue;
            NSString *name = f.stringByDeletingPathExtension, *base = [[dir stringByAppendingPathComponent:@"bin"] stringByAppendingPathComponent:name];
            NSData *code = [NSData dataWithContentsOfFile:[base stringByAppendingString:@".bin"]];
            NSData *c1 = [NSData dataWithContentsOfFile:[base stringByAppendingString:@".c1"]];
            NSData *ctl = [NSData dataWithContentsOfFile:[base stringByAppendingString:@".ctl"]];
            NSString *ref_msl = [NSString stringWithContentsOfFile:[NSString stringWithFormat:@"%@/msl/%@.metal", dir, name] encoding:NSUTF8StringEncoding error:nil];
            NSData *ref_json = [NSData dataWithContentsOfFile:[NSString stringWithFormat:@"%@/spv/%@.json", dir, name]];
            CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
            uint8_t *spv = NULL;
            int spv_len = 0;
            char *json = NULL, *out = NULL, *err = NULL;
            int ok = nxsh_translate(code.bytes, (int)code.length, c1.bytes, (int)c1.length, ctl.bytes, (int)ctl.length, &spv, &spv_len, &json, &err) == 0;
            NSString *sp = [tmp stringByAppendingPathComponent:@"x.spv"], *mp = [tmp stringByAppendingPathComponent:@"x.metal"];
            if (ok) ok = [[NSData dataWithBytes:spv length:spv_len] writeToFile:sp atomically:NO] && nx_spirv_to_msl(sp.UTF8String, mp.UTF8String) == 0;
            NSString *msl = ok ? [NSString stringWithContentsOfFile:mp encoding:NSUTF8StringEncoding error:nil] : nil;
            if (msl) ok = nxsh_fix_msl(msl.UTF8String, [name hasSuffix:@".vs"], &out, &err) == 0;
            else ok = 0;
            t += CFAbsoluteTimeGetCurrent() - t0;
            if (!ref_msl || !ref_json) no_ref++;
            else if (!ok) { failed++; if (failed <= 10) printf("FAILED %s: %s\n", name.UTF8String, err ? err : "-"); }
            else {
                BOOL m = [@(out) isEqualToString:ref_msl], j = [[NSData dataWithBytes:json length:strlen(json)] isEqualToData:ref_json];
                if (m && j) same++;
                if (!m && ++msl_diff <= 10) printf("MSL differs: %s\n", name.UTF8String);
                if (!j && ++json_diff <= 10) printf("JSON differs: %s\n", name.UTF8String);
            }
            nxsh_free(spv), nxsh_free(json), nxsh_free(out), nxsh_free(err);
        }
        printf("%d identical, %d MSL differ, %d JSON differ, %d failed, %d without reference; %.1f ms per shader\n", same,
               msl_diff, json_diff, failed, no_ref, t * 1000 / MAX(1, same + msl_diff + failed));
        return msl_diff || json_diff || failed;
    }
}
