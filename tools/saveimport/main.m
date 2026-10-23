// Command line for the save importer: saveimport <save folder or .zip> <island folder (data, data-slot2...)>
#import "save_import.h"
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) { fprintf(stderr, "usage: saveimport <save folder|.zip> <island folder>\n"); return 2; }
        int n = 0;
        NSString *why = nx_save_import(@(argv[1]), @(argv[2]), &n);
        if (why) { fprintf(stderr, "failed: %s\n", why.UTF8String); return 1; }
        printf("imported %d files into %s/save\n", n, argv[2]);
    }
    return 0;
}
