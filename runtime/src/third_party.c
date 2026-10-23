// Vendored decoders (runtime/third_party): zstd 1.5.6 decompressor (single file, BSD) for the game's .zs archives, and
// bcdec 0.985 (BC1-BC7 block decoding, MIT/Unlicense) for BNTX textures read on the CPU (the iOS prelauncher's assets).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#define ZSTD_DISABLE_ASM 1
#include "../third_party/zstddeclib.c"
#define BCDEC_IMPLEMENTATION 1
#include "../third_party/bcdec.h"
#pragma clang diagnostic pop
