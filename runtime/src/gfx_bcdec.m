// BC1-5 / BC7 decode on the GPU, for devices without BC texture sampling (the iPhone 14's A15). The game's
// BC textures become RGBA8 (BC1/2/3/7, sRGB kept), R8 (BC4) or RG8 (BC5) textures, and uploads run a
// compute kernel over the (deswizzled) blocks instead of a buffer-to-texture copy. NXRT_BCDECODE=1 forces it
// on (Mac testing), =0 off. BC7 tables: Ryujinx BC67Tables.cs (partitions packed 2 bits per texel).
// BC6H is not decoded (logged; the texture stays empty).
#import <Metal/Metal.h>
#include <stdlib.h>

#include "gfx_internal.h"
#include "nxrt.h"

static NSString *const kBcSource = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "// p: mode (1 BC1, 2 BC2, 3 BC3, 4 BC4U, 5 BC4S, 6 BC5U, 7 BC5S, 8 BC7), row bytes, texels w/h, origin x/y\n"
    "struct P { uint mode, row, w, h, ox, oy; };\n"
    "constant uint bc7_part2[64] = {\n"
    "0x50505050u, 0x40404040u, 0x54545454u, 0x54505040u, 0x50404000u, 0x55545450u, 0x55545040u, 0x54504000u,\n"
    "0x50400000u, 0x55555450u, 0x55544000u, 0x54400000u, 0x55555440u, 0x55550000u, 0x55555500u, 0x55000000u,\n"
    "0x55150100u, 0x00004054u, 0x15010000u, 0x00405054u, 0x00004050u, 0x15050100u, 0x05010000u, 0x40505054u,\n"
    "0x00404050u, 0x05010100u, 0x14141414u, 0x05141450u, 0x01155440u, 0x00555500u, 0x15014054u, 0x05414150u,\n"
    "0x44444444u, 0x55005500u, 0x11441144u, 0x05055050u, 0x05500550u, 0x11114444u, 0x41144114u, 0x44111144u,\n"
    "0x15055054u, 0x01055040u, 0x05041050u, 0x05455150u, 0x14414114u, 0x50050550u, 0x41411414u, 0x00141400u,\n"
    "0x00041504u, 0x00105410u, 0x10541000u, 0x04150400u, 0x50410514u, 0x41051450u, 0x05415014u, 0x14054150u,\n"
    "0x41050514u, 0x41505014u, 0x40011554u, 0x54150140u, 0x50505500u, 0x00555050u, 0x15151010u, 0x54540404u};\n"
    "constant uint bc7_part3[64] = {\n"
    "0xaa685050u, 0x6a5a5040u, 0x5a5a4200u, 0x5450a0a8u, 0xa5a50000u, 0xa0a05050u, 0x5555a0a0u, 0x5a5a5050u,\n"
    "0xaa550000u, 0xaa555500u, 0xaaaa5500u, 0x90909090u, 0x94949494u, 0xa4a4a4a4u, 0xa9a59450u, 0x2a0a4250u,\n"
    "0xa5945040u, 0x0a425054u, 0xa5a5a500u, 0x55a0a0a0u, 0xa8a85454u, 0x6a6a4040u, 0xa4a45000u, 0x1a1a0500u,\n"
    "0x0050a4a4u, 0xaaa59090u, 0x14696914u, 0x69691400u, 0xa08585a0u, 0xaa821414u, 0x50a4a450u, 0x6a5a0200u,\n"
    "0xa9a58000u, 0x5090a0a8u, 0xa8a09050u, 0x24242424u, 0x00aa5500u, 0x24924924u, 0x24499224u, 0x50a50a50u,\n"
    "0x500aa550u, 0xaaaa4444u, 0x66660000u, 0xa5a0a5a0u, 0x50a050a0u, 0x69286928u, 0x44aaaa44u, 0x66666600u,\n"
    "0xaa444444u, 0x54a854a8u, 0x95809580u, 0x96969600u, 0xa85454a8u, 0x80959580u, 0xaa141414u, 0x96960000u,\n"
    "0xaaaa1414u, 0xa05050a0u, 0xa0a5a5a0u, 0x96000000u, 0x40804080u, 0xa9a8a9a8u, 0xaaaaaa44u, 0x2a4a5254u};\n"
    "// anchors: bits 0-3 subset 1 of 2; bits 4-7 / 8-11 subsets 1 / 2 of 3\n"
    "constant uint bc7_anchor[64] = {\n"
    "0x00000f3fu, 0x0000083fu, 0x000008ffu, 0x000003ffu, 0x00000f8fu, 0x00000f3fu, 0x000003ffu, 0x000008ffu,\n"
    "0x00000f8fu, 0x00000f8fu, 0x00000f6fu, 0x00000f6fu, 0x00000f6fu, 0x00000f5fu, 0x00000f3fu, 0x0000083fu,\n"
    "0x00000f3fu, 0x00000832u, 0x00000f88u, 0x000003f2u, 0x00000f32u, 0x00000838u, 0x00000f68u, 0x000008afu,\n"
    "0x00000352u, 0x00000f88u, 0x00000682u, 0x00000a62u, 0x00000f88u, 0x00000f58u, 0x00000af2u, 0x000008f2u,\n"
    "0x00000f8fu, 0x000003ffu, 0x00000f36u, 0x00000a58u, 0x00000a62u, 0x000008a8u, 0x0000098fu, 0x00000affu,\n"
    "0x000006f2u, 0x00000f38u, 0x000008f2u, 0x00000f52u, 0x000003f2u, 0x000006ffu, 0x000006ffu, 0x000008f6u,\n"
    "0x00000f36u, 0x000003f2u, 0x00000f56u, 0x00000f58u, 0x00000f5fu, 0x00000f8fu, 0x00000f52u, 0x00000fa2u,\n"
    "0x00000f5fu, 0x00000fafu, 0x00000f8fu, 0x00000fdfu, 0x000003ffu, 0x00000fc2u, 0x00000f32u, 0x0000083fu};\n"
    "constant uchar bc7_w2[4] = {0, 21, 43, 64};\n"
    "constant uchar bc7_w3[8] = {0, 9, 18, 27, 37, 46, 55, 64};\n"
    "constant uchar bc7_w4[16] = {0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64};\n"
    "// BC7 modes 0-7 (Ryujinx BC67Tables): subsets, partition bits, p-bits, rotation bits, index-mode bits,\n"
    "// color index bits, alpha index bits, color depth, alpha depth\n"
    "constant uchar bc7_ns[8] = {3, 2, 3, 2, 1, 1, 1, 2}, bc7_pb[8] = {4, 6, 6, 6, 0, 0, 0, 6}, bc7_pv[8] = {6, 2, 0, 4, 0, 0, 2, 4},\n"
    "               bc7_rb[8] = {0, 0, 0, 0, 2, 2, 0, 0}, bc7_ib[8] = {0, 0, 0, 0, 1, 0, 0, 0}, bc7_ci[8] = {3, 3, 2, 2, 2, 2, 4, 2},\n"
    "               bc7_ai[8] = {0, 0, 0, 0, 3, 2, 0, 0}, bc7_cd[8] = {4, 6, 5, 7, 5, 7, 7, 5}, bc7_ad[8] = {0, 0, 0, 0, 6, 8, 7, 5};\n"
    "\n"
    "static uint bits(uint4 b, thread uint &pos, uint n) {\n"
    "    if (n == 0) return 0;\n"
    "    uint w = pos >> 5, s = pos & 31;\n"
    "    uint v = b[w] >> s;\n"
    "    if (s + n > 32 && w < 3) v |= b[w + 1] << (32 - s);\n"
    "    pos += n;\n"
    "    return v & ((1u << n) - 1);\n"
    "}\n"
    "static uint bc7_weight(uint nbits, uint i) { return nbits == 2 ? bc7_w2[i] : nbits == 3 ? bc7_w3[i] : bc7_w4[i]; }\n"
    "static uint unq(uint c, uint nbits, int pbit) {\n"
    "    uint shift = 8 - nbits, v = c << shift;\n"
    "    if (pbit >= 0) { v |= v >> (nbits + 1); v |= uint(pbit) << (shift - 1); }\n"
    "    else v |= v >> nbits;\n"
    "    return v;\n"
    "}\n"
    "static void bc7(uint4 b, thread uint4 *out) {\n"
    "    uint mode = ctz((b.x & 0xffu) | 0x100u);\n"
    "    if (mode == 8) { for (uint i = 0; i < 16; i++) out[i] = uint4(0); return; }\n"
    "    uint pos = mode + 1;\n"
    "    uint part = bits(b, pos, bc7_pb[mode]), rot = bits(b, pos, bc7_rb[mode]), idxm = bits(b, pos, bc7_ib[mode]);\n"
    "    uint ns = bc7_ns[mode], ne = ns * 2, cd = bc7_cd[mode], ad = bc7_ad[mode], npv = bc7_pv[mode];\n"
    "    uint4 ep[6];\n"
    "    for (uint c = 0; c < 3; c++)\n"
    "        for (uint i = 0; i < ne; i++) ep[i][c] = bits(b, pos, cd);\n"
    "    for (uint i = 0; i < ne; i++) ep[i].a = ad ? bits(b, pos, ad) : 255;\n"
    "    uint pv[6];\n"
    "    for (uint i = 0; i < npv; i++) pv[i] = bits(b, pos, 1);\n"
    "    for (uint i = 0; i < ne; i++) {\n"
    "        int pbit = npv ? int(pv[i * npv / ne]) : -1;\n"
    "        ep[i].rgb = uint3(unq(ep[i].r, cd, pbit), unq(ep[i].g, cd, pbit), unq(ep[i].b, cd, pbit));\n"
    "        ep[i].a = ad ? unq(ep[i].a, ad, pbit) : 255;\n"
    "    }\n"
    "    uint pt = ns == 2 ? bc7_part2[part] : ns == 3 ? bc7_part3[part] : 0u;\n"
    "    uint an = bc7_anchor[part];\n"
    "    uint a1 = ns == 2 ? (an & 15) : ((an >> 4) & 15), a2 = (an >> 8) & 15;\n"
    "    uint ci[16], ai[16];\n"
    "    uint cib = bc7_ci[mode], aib = bc7_ai[mode];\n"
    "    for (uint i = 0; i < 16; i++) {\n"
    "        uint sub = (pt >> (2 * i)) & 3;\n"
    "        bool anchor = i == 0 || (sub == 1 && i == a1) || (sub == 2 && i == a2);\n"
    "        ci[i] = bits(b, pos, anchor ? cib - 1 : cib);\n"
    "    }\n"
    "    for (uint i = 0; i < 16 && aib; i++) ai[i] = bits(b, pos, i == 0 ? aib - 1 : aib);\n"
    "    for (uint i = 0; i < 16; i++) {\n"
    "        uint sub = (pt >> (2 * i)) & 3;\n"
    "        uint cw, aw;\n"
    "        if (aib) {\n"
    "            if (idxm == 0) cw = bc7_weight(cib, ci[i]), aw = bc7_weight(aib, ai[i]);\n"
    "            else cw = bc7_weight(aib, ai[i]), aw = bc7_weight(cib, ci[i]);\n"
    "        } else cw = aw = bc7_weight(cib, ci[i]);\n"
    "        uint4 w = uint4(cw, cw, cw, aw);\n"
    "        uint4 c = (ep[sub * 2] * (64 - w) + ep[sub * 2 + 1] * w + 32) >> 6;\n"
    "        if (rot == 1) c = uint4(c.a, c.g, c.b, c.r);   // rotation: swap A with R / G / B\n"
    "        else if (rot == 2) c = uint4(c.r, c.a, c.b, c.g);\n"
    "        else if (rot == 3) c = uint4(c.r, c.g, c.a, c.b);\n"
    "        out[i] = min(c, uint4(255));\n"
    "    }\n"
    "}\n"
    "static uint3 e565(uint c) {\n"
    "    uint r = (c >> 11) & 31, g = (c >> 5) & 63, b = c & 31;\n"
    "    return uint3((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2));\n"
    "}\n"
    "static uint4 bc1(uint w0, uint w1, uint i, bool punch) {\n"
    "    uint c0 = w0 & 0xffffu, c1 = w0 >> 16;\n"
    "    uint3 a = e565(c0), b = e565(c1);\n"
    "    uint s = (w1 >> (2 * i)) & 3;\n"
    "    if (s == 0) return uint4(a, 255);\n"
    "    if (s == 1) return uint4(b, 255);\n"
    "    if (c0 > c1 || !punch) return uint4(s == 2 ? (2 * a + b) / 3 : (a + 2 * b) / 3, 255);\n"
    "    return s == 2 ? uint4((a + b) / 2, 255) : uint4(0);\n"
    "}\n"
    "static uint bc4u(uint lo, uint hi, uint i) {\n"
    "    uint a0 = lo & 255, a1 = (lo >> 8) & 255;\n"
    "    ulong idx = (ulong(hi) << 16) | ulong(lo >> 16);\n"
    "    uint s = uint(idx >> (3 * i)) & 7;\n"
    "    if (s == 0) return a0;\n"
    "    if (s == 1) return a1;\n"
    "    if (a0 > a1) return ((8 - s) * a0 + (s - 1) * a1) / 7;\n"
    "    if (s == 6) return 0;\n"
    "    if (s == 7) return 255;\n"
    "    return ((6 - s) * a0 + (s - 1) * a1) / 5;\n"
    "}\n"
    "static float bc4s(uint lo, uint hi, uint i) {\n"
    "    int a0 = max(int(lo << 24) >> 24, -127), a1 = max(int(lo << 16) >> 24, -127);   // signed endpoints\n"
    "    ulong idx = (ulong(hi) << 16) | ulong(lo >> 16);\n"
    "    int s = int(uint(idx >> (3 * i)) & 7);\n"
    "    int v;\n"
    "    if (s == 0) v = a0;\n"
    "    else if (s == 1) v = a1;\n"
    "    else if (a0 > a1) v = ((8 - s) * a0 + (s - 1) * a1) / 7;\n"
    "    else if (s == 6) v = -127;\n"
    "    else if (s == 7) v = 127;\n"
    "    else v = ((6 - s) * a0 + (s - 1) * a1) / 5;\n"
    "    return float(v) / 127.0;\n"
    "}\n"
    "kernel void bc_decode(device const uint *src [[buffer(0)]], constant P &p [[buffer(1)]],\n"
    "                      texture2d<float, access::write> dst [[texture(0)]], uint2 g [[thread_position_in_grid]]) {\n"
    "    uint bw = (p.w + 3) / 4, bh = (p.h + 3) / 4;\n"
    "    if (g.x >= bw || g.y >= bh) return;\n"
    "    uint bpb = p.mode == 1 || p.mode == 4 || p.mode == 5 ? 8 : 16;\n"
    "    device const uint *q = src + (g.y * p.row + g.x * bpb) / 4;\n"
    "    uint4 blk = bpb == 8 ? uint4(q[0], q[1], 0, 0) : uint4(q[0], q[1], q[2], q[3]);\n"
    "    uint4 c7[16];\n"
    "    if (p.mode == 8) bc7(blk, c7);\n"
    "    for (uint i = 0; i < 16; i++) {\n"
    "        uint x = g.x * 4 + (i & 3), y = g.y * 4 + (i >> 2);\n"
    "        if (x >= p.w || y >= p.h) continue;\n"
    "        float4 c;\n"
    "        switch (p.mode) {\n"
    "        case 1: c = float4(bc1(blk.x, blk.y, i, true)) / 255.0; break;\n"
    "        case 2: c = float4(float3(bc1(blk.z, blk.w, i, false).rgb) / 255.0,\n"
    "                           float((i < 8 ? blk.x >> (4 * i) : blk.y >> (4 * (i - 8))) & 15) / 15.0); break;\n"
    "        case 3: c = float4(float3(bc1(blk.z, blk.w, i, false).rgb) / 255.0, float(bc4u(blk.x, blk.y, i)) / 255.0); break;\n"
    "        case 4: c = float4(float(bc4u(blk.x, blk.y, i)) / 255.0, 0, 0, 1); break;\n"
    "        case 5: c = float4(bc4s(blk.x, blk.y, i), 0, 0, 1); break;\n"
    "        case 6: c = float4(float(bc4u(blk.x, blk.y, i)) / 255.0, float(bc4u(blk.z, blk.w, i)) / 255.0, 0, 1); break;\n"
    "        case 7: c = float4(bc4s(blk.x, blk.y, i), bc4s(blk.z, blk.w, i), 0, 1); break;\n"
    "        default: c = float4(c7[i]) / 255.0; break;\n"
    "        }\n"
    "        dst.write(c, uint2(p.ox + x, p.oy + y));\n"
    "    }\n"
    "}\n"
    "\n"
    ;

int gfx_bc_emulated(void) {
    static int e = -1;
    if (e < 0) {
        gfx_init();
        e = getenv("NXRT_BCDECODE") ? atoi(getenv("NXRT_BCDECODE")) != 0 : !g_dev.supportsBCTextureCompression;
        if (e) nx_log("gfx: BC textures decoded on the GPU (BC1-5, BC7 -> RGBA8/R8/RG8)");
    }
    return e;
}

// Kernel mode for a BC format (0 = not decoded here)
int gfx_bc_mode(MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatBC1_RGBA: case MTLPixelFormatBC1_RGBA_sRGB: return 1;
    case MTLPixelFormatBC2_RGBA: case MTLPixelFormatBC2_RGBA_sRGB: return 2;
    case MTLPixelFormatBC3_RGBA: case MTLPixelFormatBC3_RGBA_sRGB: return 3;
    case MTLPixelFormatBC4_RUnorm: return 4;
    case MTLPixelFormatBC4_RSnorm: return 5;
    case MTLPixelFormatBC5_RGUnorm: return 6;
    case MTLPixelFormatBC5_RGSnorm: return 7;
    case MTLPixelFormatBC7_RGBAUnorm: case MTLPixelFormatBC7_RGBAUnorm_sRGB: return 8;
    default: return 0;
    }
}

// The format a BC texture is created with when decoded (unchanged otherwise)
MTLPixelFormat gfx_bc_host_format(MTLPixelFormat f) {
    if (!gfx_bc_emulated()) return f;
    switch (f) {
    case MTLPixelFormatBC1_RGBA: case MTLPixelFormatBC2_RGBA: case MTLPixelFormatBC3_RGBA: case MTLPixelFormatBC7_RGBAUnorm:
        return MTLPixelFormatRGBA8Unorm;
    case MTLPixelFormatBC1_RGBA_sRGB: case MTLPixelFormatBC2_RGBA_sRGB: case MTLPixelFormatBC3_RGBA_sRGB:
    case MTLPixelFormatBC7_RGBAUnorm_sRGB:
        return MTLPixelFormatRGBA8Unorm_sRGB;
    case MTLPixelFormatBC4_RUnorm: return MTLPixelFormatR8Unorm;
    case MTLPixelFormatBC4_RSnorm: return MTLPixelFormatR8Snorm;
    case MTLPixelFormatBC5_RGUnorm: return MTLPixelFormatRG8Unorm;
    case MTLPixelFormatBC5_RGSnorm: return MTLPixelFormatRG8Snorm;
    case MTLPixelFormatBC6H_RGBFloat: case MTLPixelFormatBC6H_RGBUfloat: return MTLPixelFormatRGBA16Float;
    default: return f;
    }
}

static id<MTLComputePipelineState> bc_pso(void) {
    static id<MTLComputePipelineState> pso;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSError *err = nil;
        id<MTLLibrary> lib = [g_dev newLibraryWithSource:kBcSource options:nil error:&err];
        id<MTLFunction> fn = [lib newFunctionWithName:@"bc_decode"];
        pso = fn ? [g_dev newComputePipelineStateWithFunction:fn error:&err] : nil;
        if (!pso) nx_fatal("gfx: BC decode kernel: %s", err.localizedDescription.UTF8String);
    });
    return pso;
}

// Decodes w x h texels of BC blocks (src + off, `row` bytes per block row) into dst at (x, y) of one level and
// slice. Encodes into `e` (a compute encoder of the upload's command buffer). dst needs ShaderWrite usage.
void gfx_bc_decode(id<MTLComputeCommandEncoder> e, id<MTLBuffer> src, NSUInteger off, NSUInteger row, MTLPixelFormat bc,
                   id<MTLTexture> dst, NSUInteger slice, NSUInteger level, NSUInteger x, NSUInteger y, NSUInteger w, NSUInteger h) {
    int mode = gfx_bc_mode(bc);
    if (!mode) {
        static int n;
        if (n++ < 4) nx_log("gfx: BC format %lu not decoded (texture %lux%lu left empty)", (unsigned long)bc, (unsigned long)dst.width,
                            (unsigned long)dst.height);
        return;
    }
    // The write view: plain (non-sRGB) RGBA8 for the sRGB formats, so the decoded bytes go in unchanged.
    MTLPixelFormat vf = dst.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB ? MTLPixelFormatRGBA8Unorm : dst.pixelFormat;
    id<MTLTexture> v = [dst newTextureViewWithPixelFormat:vf textureType:MTLTextureType2D levels:NSMakeRange(level, 1)
                                                   slices:NSMakeRange(slice, 1)];
    if (!v) return;
    struct { uint32_t mode, row, w, h, ox, oy; } p = {(uint32_t)mode, (uint32_t)row, (uint32_t)w, (uint32_t)h, (uint32_t)x, (uint32_t)y};
    [e setComputePipelineState:bc_pso()];
    [e setBuffer:src offset:off atIndex:0];
    [e setBytes:&p length:sizeof p atIndex:1];
    [e setTexture:v atIndex:0];
    [e dispatchThreads:MTLSizeMake((w + 3) / 4, (h + 3) / 4, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
}
