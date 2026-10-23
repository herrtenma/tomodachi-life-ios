// SPIR-V -> MSL with SPIRV-Cross's own command-line front end (third_party/spirv-cross/main.cpp, built in with its
// main renamed), so the options are exactly those of `spirv-cross <in> --msl --msl-version 30000
// --msl-decoration-binding`, the translation the runtime's binding rules were written against.
#define main nx_spirv_cross_main
#include "../../third_party/spirv-cross/main.cpp"
#undef main

extern "C" int nx_spirv_to_msl(const char *spv_path, const char *msl_path) {
    const char *argv[] = {"spirv-cross", spv_path, "--msl", "--msl-version", "30000", "--msl-decoration-binding",
                          "--output", msl_path};
    return nx_spirv_cross_main(sizeof argv / sizeof *argv, const_cast<char **>(argv));
}
