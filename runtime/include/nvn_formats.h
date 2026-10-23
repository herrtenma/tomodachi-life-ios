// NVN texture formats (enum values as recalled from public NVN headers, checked against the
// game: window textures are 37 = RGBA8, an HDR target is 63 = R11G11B10F, the ASTC range
// starts at 121) and the Tegra X1 block-linear layout rules used for storage sizes.
#pragma once
#include <stdint.h>

typedef struct { int nvn, bpb, bw, bh; const char *name; } NvnFmt;   // bytes per block, block size

static const NvnFmt g_nvn_fmts[] = {
    {1, 1, 1, 1, "R8"},          {2, 1, 1, 1, "R8SN"},        {3, 1, 1, 1, "R8UI"},        {4, 1, 1, 1, "R8I"},
    {5, 2, 1, 1, "R16F"},        {6, 2, 1, 1, "R16"},         {7, 2, 1, 1, "R16SN"},       {8, 2, 1, 1, "R16UI"},
    {9, 2, 1, 1, "R16I"},        {10, 4, 1, 1, "R32F"},       {11, 4, 1, 1, "R32UI"},      {12, 4, 1, 1, "R32I"},
    {13, 2, 1, 1, "RG8"},        {14, 2, 1, 1, "RG8SN"},      {15, 2, 1, 1, "RG8UI"},      {16, 2, 1, 1, "RG8I"},
    {17, 4, 1, 1, "RG16F"},      {18, 4, 1, 1, "RG16"},       {19, 4, 1, 1, "RG16SN"},     {20, 4, 1, 1, "RG16UI"},
    {21, 4, 1, 1, "RG16I"},      {22, 8, 1, 1, "RG32F"},      {23, 8, 1, 1, "RG32UI"},     {24, 8, 1, 1, "RG32I"},
    {37, 4, 1, 1, "RGBA8"},      {38, 4, 1, 1, "RGBA8SN"},    {39, 4, 1, 1, "RGBA8UI"},    {40, 4, 1, 1, "RGBA8I"},
    {41, 8, 1, 1, "RGBA16F"},    {42, 8, 1, 1, "RGBA16"},     {43, 8, 1, 1, "RGBA16SN"},   {44, 8, 1, 1, "RGBA16UI"},
    {45, 8, 1, 1, "RGBA16I"},    {46, 16, 1, 1, "RGBA32F"},   {47, 16, 1, 1, "RGBA32UI"},  {48, 16, 1, 1, "RGBA32I"},
    {49, 1, 1, 1, "STENCIL8"},   {50, 2, 1, 1, "DEPTH16"},    {51, 4, 1, 1, "DEPTH24"},    {52, 4, 1, 1, "DEPTH32F"},
    {53, 4, 1, 1, "DEPTH24_STENCIL8"}, {54, 8, 1, 1, "DEPTH32F_STENCIL8"},
    {55, 4, 1, 1, "RGBX8_SRGB"}, {56, 4, 1, 1, "RGBA8_SRGB"}, {57, 2, 1, 1, "RGBA4"},      {58, 2, 1, 1, "RGB5"},
    {59, 2, 1, 1, "RGB5A1"},     {60, 2, 1, 1, "RGB565"},     {61, 4, 1, 1, "RGB10A2"},    {62, 4, 1, 1, "RGB10A2UI"},
    {63, 4, 1, 1, "R11G11B10F"}, {64, 4, 1, 1, "RGB9E5F"},
    {65, 8, 4, 4, "RGB_DXT1"},   {66, 8, 4, 4, "RGBA_DXT1"},  {67, 16, 4, 4, "RGBA_DXT3"}, {68, 16, 4, 4, "RGBA_DXT5"},
    {69, 8, 4, 4, "RGB_DXT1_SRGB"}, {70, 8, 4, 4, "RGBA_DXT1_SRGB"}, {71, 16, 4, 4, "RGBA_DXT3_SRGB"},
    {72, 16, 4, 4, "RGBA_DXT5_SRGB"}, {73, 8, 4, 4, "RGTC1_UNORM"}, {74, 8, 4, 4, "RGTC1_SNORM"},
    {75, 16, 4, 4, "RGTC2_UNORM"}, {76, 16, 4, 4, "RGTC2_SNORM"}, {77, 16, 4, 4, "BPTC_UNORM"},
    {78, 16, 4, 4, "BPTC_UNORM_SRGB"}, {79, 16, 4, 4, "BPTC_SFLOAT"}, {80, 16, 4, 4, "BPTC_UFLOAT"},
    {121, 16, 4, 4, "ASTC_4x4"},  {122, 16, 5, 4, "ASTC_5x4"},  {123, 16, 5, 5, "ASTC_5x5"},  {124, 16, 6, 5, "ASTC_6x5"},
    {125, 16, 6, 6, "ASTC_6x6"},  {126, 16, 8, 5, "ASTC_8x5"},  {127, 16, 8, 6, "ASTC_8x6"},  {128, 16, 8, 8, "ASTC_8x8"},
    {129, 16, 10, 5, "ASTC_10x5"}, {130, 16, 10, 6, "ASTC_10x6"}, {131, 16, 10, 8, "ASTC_10x8"},
    {132, 16, 10, 10, "ASTC_10x10"}, {133, 16, 12, 10, "ASTC_12x10"}, {134, 16, 12, 12, "ASTC_12x12"},
    {135, 16, 4, 4, "ASTC_4x4_SRGB"}, {136, 16, 5, 4, "ASTC_5x4_SRGB"}, {137, 16, 5, 5, "ASTC_5x5_SRGB"},
    {138, 16, 6, 5, "ASTC_6x5_SRGB"}, {139, 16, 6, 6, "ASTC_6x6_SRGB"}, {140, 16, 8, 5, "ASTC_8x5_SRGB"},
    {141, 16, 8, 6, "ASTC_8x6_SRGB"}, {142, 16, 8, 8, "ASTC_8x8_SRGB"}, {143, 16, 10, 5, "ASTC_10x5_SRGB"},
    {144, 16, 10, 6, "ASTC_10x6_SRGB"}, {145, 16, 10, 8, "ASTC_10x8_SRGB"}, {146, 16, 10, 10, "ASTC_10x10_SRGB"},
    {147, 16, 12, 10, "ASTC_12x10_SRGB"}, {148, 16, 12, 12, "ASTC_12x12_SRGB"},
};

static inline const NvnFmt *nvn_fmt(int nvn) {
    for (unsigned i = 0; i < sizeof g_nvn_fmts / sizeof *g_nvn_fmts; i++)
        if (g_nvn_fmts[i].nvn == nvn) return &g_nvn_fmts[i];
    return 0;
}

// Block height (in 8-row GOBs) the driver picks for a surface `height_blocks` tall.
static inline int nvn_gob_height(uint32_t height_blocks) {
    int gh = 1;
    while (gh < 16 && gh * 8 < (int)height_blocks) gh <<= 1;
    return gh;
}

// Block height for a mip level: halves while the level fits in half a block (Tegra rule).
static inline int nvn_mip_gob_height(int gh, uint32_t height_blocks) {
    while (gh > 1 && height_blocks <= (uint32_t)(gh >> 1) * 8) gh >>= 1;
    return gh;
}

// Bytes of one block-linear surface (one level of one layer): 64-byte-wide GOB columns,
// rows padded to whole blocks of `gh` GOBs.
static inline uint64_t nvn_surface_size(uint32_t wb, uint32_t hb, int bpb, int gh) {
    uint64_t width_gobs = ((uint64_t)wb * bpb + 63) / 64;
    uint64_t rows = (hb + 8 * gh - 1) / (8 * gh);
    return rows * width_gobs * 512 * gh;
}
