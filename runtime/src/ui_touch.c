// Native touch: the game's own UI driven by iOS touches (gesture engine below), and its A/B/X/Y symbols hidden.
// What is on screen comes from walking the pane trees of the layouts drawn this frame (nn::ui2d::Layout slot 0x70,
// wrapped): button prompts are TextBox panes holding a button glyph of the extended font (U+E0E0 A .. E0E3 Y),
// buttons are their "B_Bounding_00" hit boxes, the menu cursor's corners "N_LT_00" / "N_RD_00" give the focused item.
// Pane fields (main's ui2d): +0x18 parent, +0x20 child list head, +0x08 sibling node, +0x50/+0x54 size, +0x58 flags
// (bit 0 visible), +0x59 alpha, +0x70 global 3x4 matrix (rows at +0x70/+0x80/+0x90, translation in column 3),
// +0xb0 name[24], TextBox +0xd8 string (char16_t *), +0x112 length, +0xf0 font. Layout +0x18 root pane. Layout space
// is 1920x1080 around the screen centre, y up; the game renders it at 1280x720.
// Tests: NXRT_TOUCH_SCRIPT (fingers), NXRT_TAP_AT, NXRT_TAPLOG=1; recon: NXRT_UIDUMP=<frame>, NXRT_UIPROBE=<frame>
// (+_LAYOUT=1), NXRT_FONTLOG=1, NXRT_GLYPHSCAN=1 (+_DIR).
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include "nxrt.h"

// TextBox (main+0x30660c8) and the game's six subclasses (all objects use those).
static const uint32_t g_vts[] = {0x30660c8, 0x3274d78, 0x3274f68, 0x3275158, 0x3294930, 0x3295aa8, 0x3295dd0};
// NXRT_UIPROBE_LAYOUT=1: probe nn::ui2d::Layout (main+0x30654a0, 26 slots) and the game's three subclasses instead.
static const uint32_t g_lvts[] = {0x30654a0, 0x3066ef8, 0x3274810, 0x3294ed0};
enum { NVT = sizeof g_vts / sizeof *g_vts };
static const uint16_t g_slots[] = {0x8, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38, 0x40, 0x48, 0x50, 0x58, 0x60, 0x68, 0x70, 0x78, 0x80, 0x88, 0x90, 0x98, 0xa0, 0xa8, 0xb0, 0xb8, 0xc0, 0xc8, 0xd0, 0xd8, 0xe0, 0xe8, 0xf0, 0xf8, 0x100, 0x108, 0x110, 0x118, 0x120, 0x128, 0x130, 0x138, 0x140, 0x148, 0x150, 0x158, 0x160, 0x168, 0x170, 0x178, 0x180, 0x188, 0x190, 0x198};
enum { NSLOT = sizeof g_slots / sizeof *g_slots, NW = NVT * NSLOT };
typedef uint64_t (*Fn8)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
static Fn8 g_orig[NW];
static uint64_t g_cnt[NW];
static const void *g_last_this[NW];
static const void *g_this_ring[NW][8];   // distinct callers (recon)

// Counting wrappers: no floating-point work before the tail call, so v0-v7 (float arguments) pass through.
#define W(k)                                                                                                             \
    static uint64_t w##k(uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e, uint64_t f, uint64_t g, uint64_t h) { \
        __atomic_fetch_add(&g_cnt[k], 1, __ATOMIC_RELAXED);                                                              \
        g_last_this[k] = (const void *)a;                                                                                \
        g_this_ring[k][(g_cnt[k]) & 7] = (const void *)a;                                                                \
        return g_orig[k](a, b, c, d, e, f, g, h);                                                                        \
    }
W(0) W(1) W(2) W(3) W(4) W(5) W(6) W(7) W(8) W(9) W(10) W(11)
W(12) W(13) W(14) W(15) W(16) W(17) W(18) W(19) W(20) W(21) W(22) W(23)
W(24) W(25) W(26) W(27) W(28) W(29) W(30) W(31) W(32) W(33) W(34) W(35)
W(36) W(37) W(38) W(39) W(40) W(41) W(42) W(43) W(44) W(45) W(46) W(47)
W(48) W(49) W(50) W(51) W(52) W(53) W(54) W(55) W(56) W(57) W(58) W(59)
W(60) W(61) W(62) W(63) W(64) W(65) W(66) W(67) W(68) W(69) W(70) W(71)
W(72) W(73) W(74) W(75) W(76) W(77) W(78) W(79) W(80) W(81) W(82) W(83)
W(84) W(85) W(86) W(87) W(88) W(89) W(90) W(91) W(92) W(93) W(94) W(95)
W(96) W(97) W(98) W(99) W(100) W(101) W(102) W(103) W(104) W(105) W(106) W(107)
W(108) W(109) W(110) W(111) W(112) W(113) W(114) W(115) W(116) W(117) W(118) W(119)
W(120) W(121) W(122) W(123) W(124) W(125) W(126) W(127) W(128) W(129) W(130) W(131)
W(132) W(133) W(134) W(135) W(136) W(137) W(138) W(139) W(140) W(141) W(142) W(143)
W(144) W(145) W(146) W(147) W(148) W(149) W(150) W(151) W(152) W(153) W(154) W(155)
W(156) W(157) W(158) W(159) W(160) W(161) W(162) W(163) W(164) W(165) W(166) W(167)
W(168) W(169) W(170) W(171) W(172) W(173) W(174) W(175) W(176) W(177) W(178) W(179)
W(180) W(181) W(182) W(183) W(184) W(185) W(186) W(187) W(188) W(189) W(190) W(191)
W(192) W(193) W(194) W(195) W(196) W(197) W(198) W(199) W(200) W(201) W(202) W(203)
W(204) W(205) W(206) W(207) W(208) W(209) W(210) W(211) W(212) W(213) W(214) W(215)
W(216) W(217) W(218) W(219) W(220) W(221) W(222) W(223) W(224) W(225) W(226) W(227)
W(228) W(229) W(230) W(231) W(232) W(233) W(234) W(235) W(236) W(237) W(238) W(239)
W(240) W(241) W(242) W(243) W(244) W(245) W(246) W(247) W(248) W(249) W(250) W(251)
W(252) W(253) W(254) W(255) W(256) W(257) W(258) W(259) W(260) W(261) W(262) W(263)
W(264) W(265) W(266) W(267) W(268) W(269) W(270) W(271) W(272) W(273) W(274) W(275)
W(276) W(277) W(278) W(279) W(280) W(281) W(282) W(283) W(284) W(285) W(286) W(287)
W(288) W(289) W(290) W(291) W(292) W(293) W(294) W(295) W(296) W(297) W(298) W(299)
W(300) W(301) W(302) W(303) W(304) W(305) W(306) W(307) W(308) W(309) W(310) W(311)
W(312) W(313) W(314) W(315) W(316) W(317) W(318) W(319) W(320) W(321) W(322) W(323)
W(324) W(325) W(326) W(327) W(328) W(329) W(330) W(331) W(332) W(333) W(334) W(335)
W(336) W(337) W(338) W(339) W(340) W(341) W(342) W(343) W(344) W(345) W(346) W(347)
W(348) W(349) W(350) W(351) W(352) W(353) W(354) W(355) W(356)
static const Fn8 g_wrap[NW] = {w0, w1, w2, w3, w4, w5, w6, w7, w8, w9, w10, w11, w12, w13, w14, w15, w16, w17, w18, w19, w20, w21, w22, w23, w24, w25, w26, w27, w28, w29, w30, w31, w32, w33, w34, w35, w36, w37, w38, w39, w40, w41, w42, w43, w44, w45, w46, w47, w48, w49, w50, w51, w52, w53, w54, w55, w56, w57, w58, w59, w60, w61, w62, w63, w64, w65, w66, w67, w68, w69, w70, w71, w72, w73, w74, w75, w76, w77, w78, w79, w80, w81, w82, w83, w84, w85, w86, w87, w88, w89, w90, w91, w92, w93, w94, w95, w96, w97, w98, w99, w100, w101, w102, w103, w104, w105, w106, w107, w108, w109, w110, w111, w112, w113, w114, w115, w116, w117, w118, w119, w120, w121, w122, w123, w124, w125, w126, w127, w128, w129, w130, w131, w132, w133, w134, w135, w136, w137, w138, w139, w140, w141, w142, w143, w144, w145, w146, w147, w148, w149, w150, w151, w152, w153, w154, w155, w156, w157, w158, w159, w160, w161, w162, w163, w164, w165, w166, w167, w168, w169, w170, w171, w172, w173, w174, w175, w176, w177, w178, w179, w180, w181, w182, w183, w184, w185, w186, w187, w188, w189, w190, w191, w192, w193, w194, w195, w196, w197, w198, w199, w200, w201, w202, w203, w204, w205, w206, w207, w208, w209, w210, w211, w212, w213, w214, w215, w216, w217, w218, w219, w220, w221, w222, w223, w224, w225, w226, w227, w228, w229, w230, w231, w232, w233, w234, w235, w236, w237, w238, w239, w240, w241, w242, w243, w244, w245, w246, w247, w248, w249, w250, w251, w252, w253, w254, w255, w256, w257, w258, w259, w260, w261, w262, w263, w264, w265, w266, w267, w268, w269, w270, w271, w272, w273, w274, w275, w276, w277, w278, w279, w280, w281, w282, w283, w284, w285, w286, w287, w288, w289, w290, w291, w292, w293, w294, w295, w296, w297, w298, w299, w300, w301, w302, w303, w304, w305, w306, w307, w308, w309, w310, w311, w312, w313, w314, w315, w316, w317, w318, w319, w320, w321, w322, w323, w324, w325, w326, w327, w328, w329, w330, w331, w332, w333, w334, w335, w336, w337, w338, w339, w340, w341, w342, w343, w344, w345, w346, w347, w348, w349, w350, w351, w352, w353, w354, w355, w356};

static void probe_frame(int frame);
void nx_ui_tick(int frame);
void nx_ui_frame(int frame) {
    nx_ui_tick(frame);
    probe_frame(frame);
}
static void probe_frame(int frame) {
    static int probe = -2, installed;
    if (probe == -2) probe = getenv("NXRT_UIPROBE") ? atoi(getenv("NXRT_UIPROBE")) : -1;
    if (probe < 0) return;
    Module *m = nx_module("main");
    if (!m) return;
    static int layout = -1, nvt = NVT, nslot = NSLOT - 1;   // TextBox: slots 0x8..0x190 (0x198 is past the table)
    static const uint32_t *vts = g_vts;
    if (layout < 0 && (layout = getenv("NXRT_UIPROBE_LAYOUT") != NULL)) vts = g_lvts, nvt = 4, nslot = 25;
    if (!installed) {
        installed = 1;
        for (int v = 0; v < nvt; v++) {
            uint64_t *vt = (uint64_t *)(m->base + vts[v]);
            uintptr_t pg = (uintptr_t)vt & ~(uintptr_t)0x3fff;
            mprotect((void *)pg, 0x8000, PROT_READ | PROT_WRITE);
            for (int k = 0; k < nslot; k++) {
                g_orig[v * NSLOT + k] = (Fn8)vt[g_slots[k] / 8];
                vt[g_slots[k] / 8] = (uint64_t)g_wrap[v * NSLOT + k];
            }
        }
        nx_log("uiprobe: %d vtables wrapped (%d slots each)", nvt, nslot);
    }
    static uint64_t base[NW];
    if (frame == probe || frame == probe + 1) {
        for (int k = 0; k < NW; k++) {
            uint64_t n = __atomic_load_n(&g_cnt[k], __ATOMIC_RELAXED);
            if (frame == probe + 1 && n != base[k])
                nx_log("uiprobe: frame %d vtable main+%#x slot %#x (main+%#llx): %llu calls, last this %p", probe, vts[k / NSLOT],
                       g_slots[k % NSLOT], (unsigned long long)((uint8_t *)g_orig[k] - m->base), (unsigned long long)(n - base[k]),
                       g_last_this[k]);
            base[k] = n;
        }
        if (frame == probe + 1 && layout)   // the layouts seen: first 0x100 bytes
            for (int k = 0; k < NW; k++)
                for (int j = 0; j < 8; j++) {
                    const uint8_t *p = g_this_ring[k][j];
                    if (!p || g_cnt[k] < 1 || (k % NSLOT) != 13) continue;   // slot 0x70
                    char hex[0x100 * 3 + 1];
                    for (int i = 0; i < 0x100; i++) snprintf(hex + i * 3, 4, "%02x ", p[i]);
                    for (int i = 0; i < 0x100; i += 0x40) nx_log("uiprobe: layout %p +%#05x %.192s", p, i, hex + i * 3);
                }
        if (frame == probe + 1 && !layout)   // the text boxes seen: raw fields, name and string
            for (int k = 0; k < NW; k++) {
                const uint8_t *p = g_last_this[k];
                if (!p || (k % NSLOT) != 9) continue;   // slot 0x50
                char hex[0x200 * 3 + 1];
                for (int i = 0; i < 0x200; i++) snprintf(hex + i * 3, 4, "%02x ", p[i]);
                for (int i = 0; i < 0x200; i += 0x40) nx_log("uiprobe: %p +%#05x %.192s", p, i, hex + i * 3);
                const uint16_t *str = *(const uint16_t *const *)(p + 0xd8);
                unsigned len = *(const uint16_t *)(p + 0x112);
                char out[512];
                int o = 0;
                for (unsigned i = 0; str && i < len && o < 480; i++)
                    o += str[i] >= 0x20 && str[i] < 0x7f ? snprintf(out + o, 512 - o, "%c", str[i]) : snprintf(out + o, 512 - o, "\\u%04x", str[i]);
                out[o] = 0;
                nx_log("uiprobe: %p string (%u): %s", p, len, out);
            }
    }
}

static uint8_t *g_main;   // main's load address
int nx_game_width(void), nx_game_height(void);
void nx_wide_base(void);
static uint8_t *res_obj(void);
// Called by the loader once the image is in place (the vtables are wrapped later, at the first frame).
void nx_ui_install(Module *m, int patch) {
    (void)patch;
    g_main = m->base;
}

// Layouts drawn lately: nn::ui2d::Layout slot 0x70 (main+0x10bfe74, Calculate(DrawInfo &, bool): the pane matrices
// from the positions the animation step set before) runs once per frame for each layout on screen
// (6 on the island); screens built ahead of time keep their panes "visible" but never get it. Wrapped in the base
// class and the game's three subclasses once the vtables are relocated. Integer-only before the tail call (float
// arguments pass through in v0-v7).
static const uint32_t g_lay_vts[] = {0x30654a0, 0x3066ef8, 0x3274810, 0x3294ed0};
static Fn8 g_lay_orig[4];
static const uint8_t *volatile g_drawn_p[64];
static volatile int g_drawn_f[64];
static volatile int g_cur_frame;
static unsigned g_drawn_n, g_drawn_seq[64];
static void wide_layout(uint8_t *layout), wide_layout_pre(uint8_t *layout), hand_pre(uint8_t *layout);
#define LW(k)                                                                                                             \
    static uint64_t lw##k(uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e, uint64_t f, uint64_t g, uint64_t h) { \
        unsigned q = __atomic_fetch_add(&g_drawn_n, 1, __ATOMIC_RELAXED), i = q & 63;                                     \
        g_drawn_p[i] = (const uint8_t *)a;                                                                               \
        g_drawn_seq[i] = q;                                                                                              \
        g_drawn_f[i] = g_cur_frame;                                                                                      \
        wide_layout_pre((uint8_t *)a);   /* Calculate(DrawInfo &, bool): integer arguments only */                   \
        hand_pre((uint8_t *)a);                                                                                          \
        uint64_t r = g_lay_orig[k](a, b, c, d, e, f, g, h);                                                              \
        wide_layout((uint8_t *)a);   /* first sight: needs this frame's matrices */                                     \
        return r;                                                                                                        \
    }
LW(0) LW(1) LW(2) LW(3)
static const Fn8 g_lay_wrap[4] = {lw0, lw1, lw2, lw3};
static void layouts_hook(void) {
    for (int v = 0; v < 4; v++) {
        uint64_t *slot = (uint64_t *)(g_main + g_lay_vts[v] + 0x70);
        uintptr_t pg = (uintptr_t)slot & ~(uintptr_t)0x3fff;
        mprotect((void *)pg, 0x4000, PROT_READ | PROT_WRITE);
        g_lay_orig[v] = (Fn8)*slot;
        *slot = (uint64_t)g_lay_wrap[v];
    }
}

// Widescreen layouts (nx_game_width() > 1280): a full-screen layout (root pane 1920x1080) gets a root as wide as the
// screen in layout units (width * 1.5), and every pane spanning the full 1920 (backgrounds, full-width groups) grows
// by the same amount. Children positioned against those panes' edges (pane +0x5b anchors) follow the real screen
// edges. Pane: +0x30 translate x, +0x50 size, +0x58 flags (0x10 = recompute the matrix), +0x5b base position.
// Runs on the game thread after each layout's per-frame call; applied again when an animation resets a size.
static void pane_name(const uint8_t *p, char out[25]);
static int g_wide_layouts = -1;
const uint8_t *g_wide_seen[256];   // roots of the layouts set up (wide_layout)
// Per-screen overrides by pane name (checked before the general rules): 2 = move to the right edge (keep the width),
// 3 = left edge, 1 = leave as is. Main menu: its yellow panel (full-screen pictures, transparent on the left) and its
// rows keep their width against the right edge instead of the panel stretching.
static const struct { const char *name; int act; } g_wide_names[] = {
    {"P_Fluid_01", 2}, {"P_FluidBack_01", 2}, {"P_FluidIn_00", 2}, {"P_FluidInBack_00", 2}, {"N_Menu_00", 2},
};
static int wide_name_act(const uint8_t *p) {
    char nm[25];
    pane_name(p, nm);
    for (unsigned i = 0; i < sizeof g_wide_names / sizeof *g_wide_names; i++)
        if (!strcmp(nm, g_wide_names[i].name)) return g_wide_names[i].act;
    return 0;
}
// Named overrides are applied every frame (their panes are often animated: the menu slides in, and the animation
// writes the position each frame): x += shift whenever x is not the value written last (animation rewrote it).
static struct { const uint8_t *root, *owner; uint8_t *pane; float shift, last; } g_named[64];
static unsigned g_nnamed;
static const uint8_t *g_named_root;   // the layout being set up (edge_shift -> named_add)
static void named_add1(uint8_t *p, const uint8_t *owner, float shift) {
    for (unsigned i = 0; i < 64; i++) if (g_named[i].pane == p && g_named[i].root == g_named_root) return;
    unsigned k = g_nnamed++ & 63;
    g_named[k].root = g_named_root, g_named[k].owner = owner, g_named[k].pane = p, g_named[k].shift = shift, g_named[k].last = 1e30f;
}
// A named pane with children: the shift goes on its children instead. The menu's N_Menu_00 slides in by animation,
// and the game computes its matrix right after the animation writes x, before the shift could land: it was drawn at
// the 16:9 position for the whole slide (~20 frames), then snapped out to the edge when the animation stopped. Its
// children are not animated, so their shift is in place whenever the matrices are computed.
// NXRT_WIDE_NAMEDSELF=1: the named pane itself (old).
static void named_add(uint8_t *p, float shift) {
    static int self = -1;
    if (self < 0) self = getenv("NXRT_WIDE_NAMEDSELF") != NULL;
    const uint8_t *head = p + 0x20, *n = *(const uint8_t *const *)head;
    if (self || !n || n == head) { named_add1(p, p, shift); return; }
    for (int i = 0; n && n != head && i < 64; i++, n = *(const uint8_t *const *)n) named_add1((uint8_t *)n - 8, p, shift);
}
// Named panes: translate x += shift whenever it is not the value written last (an animation rewrote it: the menu
// sliding in). Applied before Calculate (static panes, and positions an animation set since the last frame) and after
// it (positions animations write during the layout's update), so the panes are placed right throughout a slide.
static void named_tick(const uint8_t *root) {
    static int log = -1;
    if (log < 0) log = getenv("NXRT_NAMEDLOG") != NULL;
    for (unsigned i = 0; i < 64; i++) {
        uint8_t *p = g_named[i].pane;
        if (!p || g_named[i].root != root) continue;
        if (!wide_name_act(g_named[i].owner)) { g_named[i].pane = NULL; continue; }
        float *x = (float *)(p + 0x30);
        if (log) {
            char nm[25]; pane_name(p, nm);
            const uint8_t *c = *(const uint8_t *const *)(p + 0x20);
            c = c && c != p + 0x20 ? c - 8 : NULL;
            char cn[25] = ""; if (c) pane_name(c, cn);
            nx_log("named: frame %d %s x %g m3 %g | child %s x %g m3 %g flags %02x", g_cur_frame, nm, *x, ((float *)(p + 0x70))[3],
                   cn, c ? ((const float *)(c + 0x30))[0] : 0, c ? ((const float *)(c + 0x70))[3] : 0, c ? c[0x58] : 0);
        }
        if (*x != g_named[i].last) *x += g_named[i].shift, g_named[i].last = *x, p[0x58] |= 0x10;
    }
}
static void wide_pane(uint8_t *p, int depth, float delta) {
    if (!p || depth > 40) return;
    float *sz = (float *)(p + 0x50);
    if (sz[0] >= 1900 && sz[0] < 1920 + delta / 2 && !wide_name_act(p)) sz[0] += delta, p[0x58] |= 0x10;
    const uint8_t *head = p + 0x20, *n = *(const uint8_t *const *)head;
    for (int i = 0; n && n != head && i < 4096; i++, n = *(const uint8_t *const *)n) wide_pane((uint8_t *)n - 8, depth + 1, delta);
}
// Extent of a pane and its descendants in layout units (global matrix +0x70: x m[3], y m[7], scales m[0], m[5]):
// b = {x0, x1, y0, y1}.
static void sub_box(const uint8_t *p, int depth, float b[4]) {
    if (!p || depth > 40) return;
    const float *m = (const float *)(p + 0x70), *sz = (const float *)(p + 0x50);
    float hw = fabsf(m[0] * sz[0]) / 2, hh = fabsf(m[5] * sz[1]) / 2;
    if (sz[0] > 0 && sz[1] > 0)
        b[0] = fminf(b[0], m[3] - hw), b[1] = fmaxf(b[1], m[3] + hw), b[2] = fminf(b[2], m[7] - hh), b[3] = fmaxf(b[3], m[7] + hh);
    const uint8_t *head = p + 0x20, *n = *(const uint8_t *const *)head;
    for (int i = 0; n && n != head && i < 4096; i++, n = *(const uint8_t *const *)n) sub_box(n - 8, depth + 1, b);
}
// HUD-style elements placed by fixed offsets at the 16:9 edges move out to the real edges: the topmost pane whose
// subtree lies on one side of the centre and reaches within 200 units of that 16:9 edge (but not past it: scrolled
// pages) shifts by half the extra width. Not moved: groups anchored to a widened parent's edge (+0x5b bits 4-5, they
// move already, with everything inside), grid/list cells (3+ same-size siblings), centre content.
static int grid_cell(const uint8_t *p, const uint8_t *parent) {
    const float *sz = (const float *)(p + 0x50);
    if (!parent || sz[0] < 40) return 0;
    int same = 0;
    const uint8_t *head = parent + 0x20, *n = *(const uint8_t *const *)head;
    for (int i = 0; n && n != head && i < 4096; i++, n = *(const uint8_t *const *)n) {
        const float *o = (const float *)(n - 8 + 0x50);
        if (n - 8 != p && fabsf(o[0] - sz[0]) < 1 && fabsf(o[1] - sz[1]) < 1) same++;
    }
    return same >= 3;
}
// Children of p: each is shifted (out to its edge), left as is, or descended into. A shifted child pulls along
// neighbours on its side that overlap it vertically and sit within 80 units (a toolbar made of separate groups).
static void edge_shift(uint8_t *p, int depth, float delta, int p_wide) {
    if (!p || depth > 40) return;
    static int onesided = -1;
    if (onesided < 0) onesided = getenv("NXRT_WIDE_ONESIDED") != NULL;
    enum { MAXC = 128 };
    uint8_t *c[MAXC];
    float bx[MAXC][4];
    int act[MAXC], nc = 0;   // act: 0 descend, 1 keep, 2 shift right, 3 shift left
    const uint8_t *head = p + 0x20, *n = *(const uint8_t *const *)head;
    for (int i = 0; n && n != head && i < 4096 && nc < MAXC; i++, n = *(const uint8_t *const *)n) {
        uint8_t *q = (uint8_t *)n - 8;
        const float *sz = (const float *)(q + 0x50);
        float *b = bx[nc];
        b[0] = b[2] = 1e9f, b[1] = b[3] = -1e9f;
        sub_box(q, 0, b);
        int a = wide_name_act(q);
        if (a) ;                                                      // per-screen override
        else if (sz[0] >= 1900) a = 0;                                // full width: widened, look inside
        else if (p_wide && (q[0x5b] >> 4 & 3)) a = 1;                 // anchored to a widened edge: moves already
        else if (grid_cell(q, p)) a = 1;                              // grid / list cell
        else if (b[0] > b[1]) a = 0;                                  // empty
        // Past the 16:9 edge: a full-screen container (both sides) is looked into; a group on one side that runs off
        // its edge (a scrolled page, or a panel that bleeds off the screen like the Mii info panel) stays whole. Looking
        // into the panel moved its rows, name and hints out to the edge without its background. NXRT_WIDE_ONESIDED=1:
        // old (looked into).
        else if (b[1] > 970 || b[0] < -970) a = (b[0] < -60 && b[1] > 60) || onesided ? 0 : 1;
        else if (b[0] > 60 && b[1] >= 760) a = 2;
        else if (b[1] < -60 && b[0] <= -760) a = 3;
        c[nc] = q, act[nc++] = a;
    }
    for (int changed = 1; changed;) {   // pull neighbours along
        changed = 0;
        for (int i = 0; i < nc; i++) {
            if (act[i] != 2 && act[i] != 3) continue;
            for (int k = 0; k < nc; k++) {
                if (act[k] != 0 || bx[k][0] > bx[k][1]) continue;
                int side = act[i] == 2 ? bx[k][0] > 60 : bx[k][1] < -60;
                float gap = fmaxf(bx[k][0] - bx[i][1], bx[i][0] - bx[k][1]);
                int vover = bx[k][2] < bx[i][3] && bx[i][2] < bx[k][3];
                if (side && vover && gap < 80 && bx[k][1] <= 970 && bx[k][0] >= -970) act[k] = act[i], changed = 1;
            }
        }
    }
    // Inside a widget (parent not full width, depth 2+: depth 0-1 are the screen's own groups, e.g. the shop's Buy button over
    // the clerk picture), a part moves only if no sibling overlapping it stays: else the widget
    // came apart (phone: the shop clerk's speech bubble moved right without its text, whose reserved box reaches past
    // the 16:9 edge; the button hint bar's icon moved left without its label). Cascades: what stays holds the rest.
    // NXRT_WIDE_SPLIT=1: old.
    static int split = -1;
    if (split < 0) split = getenv("NXRT_WIDE_SPLIT") != NULL;
    for (int changed = !p_wide && depth >= 2 && !split; changed;) {
        changed = 0;
        for (int i = 0; i < nc; i++) {
            if ((act[i] != 2 && act[i] != 3) || wide_name_act(c[i])) continue;
            for (int k = 0; k < nc; k++) {
                if (k == i || act[k] == act[i] || bx[k][0] > bx[k][1] || ((const float *)(c[k] + 0x50))[0] >= 1900) continue;
                float ox = fminf(bx[i][1], bx[k][1]) - fmaxf(bx[i][0], bx[k][0]), oy = fminf(bx[i][3], bx[k][3]) - fmaxf(bx[i][2], bx[k][2]);
                if (ox > 4 && oy > 4) { act[i] = 1, changed = 1; break; }
            }
        }
    }
    static int wlog = -1;   // NXRT_WIDELOG=1: every decision (pane, depth, subtree box, local x, action)
    if (wlog < 0) wlog = getenv("NXRT_WIDELOG") != NULL;
    for (int i = 0; i < nc && wlog; i++) {
        char nm[25];
        pane_name(c[i], nm);
        nx_log("widelog: frame %d d%d %-24s box x %.0f..%.0f y %.0f..%.0f x %.0f size %.0fx%.0f anchor %d -> %s", g_cur_frame, depth, nm,
               bx[i][0], bx[i][1], bx[i][2], bx[i][3], ((const float *)(c[i] + 0x30))[0], ((const float *)(c[i] + 0x50))[0],
               ((const float *)(c[i] + 0x50))[1], c[i][0x5b] >> 4 & 3, (const char *[]){"descend", "keep", "right", "left"}[act[i]]);
    }
    for (int i = 0; i < nc; i++) {
        if (act[i] >= 2 && wide_name_act(c[i])) named_add(c[i], act[i] == 2 ? delta / 2 : -delta / 2);
        else if (act[i] >= 2) *(float *)(c[i] + 0x30) += act[i] == 2 ? delta / 2 : -delta / 2, c[i][0x58] |= 0x10;
        else if (act[i] == 0) edge_shift(c[i], depth + 1, delta, ((const float *)(c[i] + 0x50))[0] >= 1900);
    }
}
// ---- tall layouts (NXRT_TALL): the vertical twin of the above -------------------------------------------------
// A full-screen layout (root 1920x1080) gets a root as tall as the picture in layout units (height * 1.5) and every
// pane spanning the full 1080 grows by the same amount; HUD-style elements placed against the 16:9 top or bottom
// edge move out to the real edges by half the extra height. Pane +0x34 = translate y (layout units, y up), +0x5b bits
// 6-7 = anchored to the parent's top / bottom (those move with a heightened parent already).
static void tall_pane(uint8_t *p, int depth, float delta) {
    if (!p || depth > 40) return;
    float *sz = (float *)(p + 0x50);
    if (sz[1] >= 1060 && sz[1] < 1080 + delta / 2) sz[1] += delta, p[0x58] |= 0x10;
    const uint8_t *head = p + 0x20, *n = *(const uint8_t *const *)head;
    for (int i = 0; n && n != head && i < 4096; i++, n = *(const uint8_t *const *)n) tall_pane((uint8_t *)n - 8, depth + 1, delta);
}
static void tall_edge_shift(uint8_t *p, int depth, float delta, int p_tall) {
    if (!p || depth > 40) return;
    enum { MAXC = 128 };
    uint8_t *c[MAXC];
    float bx[MAXC][4];
    int act[MAXC], nc = 0;   // act: 0 descend, 1 keep, 2 shift up, 3 shift down
    const uint8_t *head = p + 0x20, *n = *(const uint8_t *const *)head;
    for (int i = 0; n && n != head && i < 4096 && nc < MAXC; i++, n = *(const uint8_t *const *)n) {
        uint8_t *q = (uint8_t *)n - 8;
        const float *sz = (const float *)(q + 0x50);
        float *b = bx[nc];
        b[0] = b[2] = 1e9f, b[1] = b[3] = -1e9f;
        sub_box(q, 0, b);
        int a;
        if (sz[1] >= 1060) a = 0;                                     // full height: heightened, look inside
        else if (p_tall && (q[0x5b] >> 6 & 3)) a = 1;                 // anchored to a heightened edge: moves already
        else if (grid_cell(q, p)) a = 1;                              // grid / list cell
        else if (b[2] > b[3] || b[3] > 550 || b[2] < -550) a = 0;     // empty, or past the 16:9 edge (scrolled)
        else if (b[2] > 40 && b[3] >= 380) a = 2;
        else if (b[3] < -40 && b[2] <= -380) a = 3;
        else a = 0;
        c[nc] = q, act[nc++] = a;
    }
    for (int changed = 1; changed;) {   // pull neighbours along (a toolbar made of separate groups)
        changed = 0;
        for (int i = 0; i < nc; i++) {
            if (act[i] != 2 && act[i] != 3) continue;
            for (int k = 0; k < nc; k++) {
                if (act[k] != 0 || bx[k][2] > bx[k][3]) continue;
                int side = act[i] == 2 ? bx[k][2] > 40 : bx[k][3] < -40;
                float gap = fmaxf(bx[k][2] - bx[i][3], bx[i][2] - bx[k][3]);
                int hover = bx[k][0] < bx[i][1] && bx[i][0] < bx[k][1];
                if (side && hover && gap < 80 && bx[k][3] <= 550 && bx[k][2] >= -550) act[k] = act[i], changed = 1;
            }
        }
    }
    for (int i = 0; i < nc; i++) {
        if (act[i] >= 2) *(float *)(c[i] + 0x34) += act[i] == 2 ? delta / 2 : -delta / 2, c[i][0x58] |= 0x10;
        else if (act[i] == 0) tall_edge_shift(c[i], depth + 1, delta, ((const float *)(c[i] + 0x50))[1] >= 1060);
    }
}
static const uint8_t *g_tall_seen[256];
static void tall_layout(uint8_t *layout, int pre) {
    uint8_t *root = *(uint8_t **)(layout + 0x18);
    if (!root) return;
    const float *rs = (const float *)(root + 0x50);
    float delta = nx_game_height() * 1.5f - 1080;
    if (rs[0] < 1900 || rs[0] > 1940 || rs[1] < 1060) return;   // not a full-screen layout
    int k = 0;
    while (k < 256 && g_tall_seen[k] != root) k++;
    if (pre) {   // before Calculate: sizes the animation step reset
        if (k < 256) tall_pane(root, 0, delta);
        return;
    }
    if (rs[1] >= 1080 + delta / 2 && k < 256) return;   // heightened already
    static unsigned nseen;
    if (k == 256) g_tall_seen[nseen++ & 255] = root, tall_edge_shift(root, 0, delta, 1);   // first sight: edge elements out
    tall_pane(root, 0, delta);
}

// Before Calculate, every frame (after the animation step wrote this frame's positions and sizes): named shifts and
// full-width sizes, so the matrices of this frame already have them (a menu sliding in is placed right throughout).
static void wide_layout_pre(uint8_t *layout) {
    if (g_wide_layouts < 0) g_wide_layouts = (nx_game_width() > 1280 || nx_game_height() > 720) && !getenv("NXRT_WIDE_KEEPUI");
    if (g_wide_layouts > 0 && nx_game_height() > 720) { tall_layout(layout, 1); return; }
    if (g_wide_layouts <= 0) return;
    uint8_t *root = *(uint8_t **)(layout + 0x18);
    if (!root) return;
    const float *rs = (const float *)(root + 0x50);
    float delta = nx_game_width() * 1.5f - 1920;
    if (rs[1] != 1080 || rs[0] < 1900) return;
    int k = 0;
    extern const uint8_t *g_wide_seen[256];
    while (k < 256 && g_wide_seen[k] != root) k++;
    if (k == 256) return;   // not set up yet (wide_layout after this frame's Calculate)
    wide_pane(root, 0, delta);
    named_tick(root);
}
// NXRT_PANEDUMP=<frame>: every layout's pane tree (names, depth <= 3) at that frame (recon: screen detection).
static void pane_dump(const uint8_t *p, int depth, const uint8_t *root) {
    if (!p || depth > 3) return;
    char nm[25];
    pane_name(p, nm);
    nx_log("panedump: frame %d root %p d%d %s", g_cur_frame, root, depth, nm);
    const uint8_t *head = p + 0x20, *n = *(const uint8_t *const *)head;
    for (int i = 0; n && n != head && i < 64; i++, n = *(const uint8_t *const *)n) pane_dump(n - 8, depth + 1, root);
}
static void title_check(const uint8_t *layout);
static void wide_layout(uint8_t *layout) {
    title_check(layout);
    static int dumpf = -2;
    if (dumpf == -2) dumpf = getenv("NXRT_PANEDUMP") ? atoi(getenv("NXRT_PANEDUMP")) : -1;
    if (dumpf >= 0 && g_cur_frame == dumpf && *(uint8_t **)(layout + 0x18)) pane_dump(*(uint8_t **)(layout + 0x18), 0, *(uint8_t **)(layout + 0x18));
    if (g_wide_layouts < 0) g_wide_layouts = (nx_game_width() > 1280 || nx_game_height() > 720) && !getenv("NXRT_WIDE_KEEPUI");
    if (!g_wide_layouts) return;
    if (nx_game_height() > 720) { tall_layout(layout, 0); return; }
    uint8_t *root = *(uint8_t **)(layout + 0x18);
    if (!root) return;
    const float *rs = (const float *)(root + 0x50);
    float delta = nx_game_width() * 1.5f - 1920;
    if (rs[1] == 1080 && rs[0] >= 1920 + delta / 2) { named_tick(root); return; }   // widened already
    if (!(rs[1] == 1080 && rs[0] >= 1900 && rs[0] < 1920 + delta / 2)) return;          // not full screen
    // First sight of this layout (or its root was reset): edge elements out, then full-width panes wider.
    static unsigned nseen;
    int k = 0;
    while (k < 256 && g_wide_seen[k] != root) k++;
    if (k == 256) {
        g_wide_seen[nseen++ & 255] = root;
        for (unsigned i = 0; i < 64; i++) if (g_named[i].root == root) g_named[i].pane = NULL;   // a new layout here
        g_named_root = root, edge_shift(root, 0, delta, 1);
    }
    wide_pane(root, 0, delta);
}

// The island's centre hand (N_Pointer_00, a direct child of its own layout's root) is faded out (pane alpha +0x59)
// while a swipe pans the camera and 0.5 s after the glide ends (engine_tick sets g_hand_hide_until); the game's alpha
// is put back afterwards. Runs before each layout's Calculate on the game thread.
static double now_s(void);
static double now_s(void);
static double now_s(void);
static volatile double g_hand_hide_until;
static void hand_pre(uint8_t *layout) {
    static uint8_t *hand, saved;
    static int hidden;
    uint8_t *root = *(uint8_t **)(layout + 0x18);
    if (!root) return;
    const uint8_t *head = root + 0x20, *n = *(const uint8_t *const *)head;
    uint8_t *found = NULL;
    for (int i = 0; n && n != head && i < 64 && !found; i++, n = *(const uint8_t *const *)n) {
        char nm[25];
        pane_name(n - 8, nm);
        if (!strcmp(nm, "N_Pointer_00")) found = (uint8_t *)n - 8;
    }
    if (!found) return;
    if (hand != found) hand = found, hidden = 0;
    {   // recon: NXRT_POINTER_AT=<x>:<y> (layout units from the centre): the hand pane pinned there every frame
        static float px = 1e30f, py;
        if (px == 1e30f) {
            const char *e = getenv("NXRT_POINTER_AT");
            px = e ? strtof(e, NULL) : 1e31f, py = e && strchr(e, ':') ? strtof(strchr(e, ':') + 1, NULL) : 0;
        }
        if (px < 1e30f) {
            float *t = (float *)(hand + 0x30);
            static int logged;
            if (!logged++) nx_log("pointer: pane x %g y %g z %g -> %g %g", t[0], t[1], t[2], px, py);
            t[0] = px, t[1] = py, hand[0x58] |= 0x10;
        }
    }
    int want = now_s() < g_hand_hide_until;
    if (want && !hidden) saved = hand[0x59], hidden = 1;
    if (want) hand[0x59] = 0, hand[0x58] |= 0x10;
    else if (hidden) hand[0x59] = saved, hand[0x58] |= 0x10, hidden = 0;
}

// Button glyphs of the system extended font (also the game's NinDev-TCExt) -> HID button bit (A 0, B 1, X 2, Y 3,
// L 6, R 7, ZL 8, ZR 9, + 10, - 11, left/right stick press 4/5). A/B/X/Y and L/R/ZL/ZR confirmed in game (session 23,
// Island Builder toolbar); E104/E105 = the stick presses there.
static int glyph_button(unsigned c) {
    switch (c) {
    case 0xE0A0: case 0xE0E0: return 0;
    case 0xE0A1: case 0xE0E1: return 1;
    case 0xE0A2: case 0xE0E2: return 2;
    case 0xE0A3: case 0xE0E3: return 3;
    case 0xE0A4: case 0xE0E4: return 6;
    case 0xE0A5: case 0xE0E5: return 7;
    case 0xE0A6: case 0xE0E6: return 8;
    case 0xE0A7: case 0xE0E7: return 9;
    case 0xE0B5: case 0xE0B3: case 0xE0EF: return 10;
    case 0xE0B6: case 0xE0B4: case 0xE0F0: return 11;
    case 0xE104: return 4;   // stick presses (Island Builder toolbar)
    case 0xE105: return 5;
    default: return -1;
    }
}
// nn::ui2d::TextBox or one of the game's subclasses (their vtables, g_vts).
static int is_textbox(const uint8_t *p) {
    uint64_t vt = *(const uint64_t *)p;
    for (int v = 0; v < NVT; v++)
        if (vt == (uint64_t)(g_main + g_vts[v])) return 1;
    return 0;
}

// Screen rectangle (1280x720) of a pane: its size around the global translation, scaled by the matrix diagonal.
static void pane_rect(const uint8_t *p, float r[4]) {
    const float *m = (const float *)(p + 0x70), *sz = (const float *)(p + 0x50);
    float cx = (m[3] + nx_game_width() * 0.75f) * (2.0f / 3), cy = (nx_game_height() * 0.75f - m[7]) * (2.0f / 3);   // layout half size
    float hw = fabsf(m[0] * sz[0]) / 3, hh = fabsf(m[5] * sz[1]) / 3;   // half extents: size/2 * scale * 2/3
    r[0] = cx - hw, r[1] = cy - hh, r[2] = cx + hw, r[3] = cy + hh;
}
static void pane_name(const uint8_t *p, char out[25]) {
    static int off = -1;   // NXRT_PANENAME_OFF=<hex>: try another name offset (recon)
    if (off < 0) off = getenv("NXRT_PANENAME_OFF") ? (int)strtol(getenv("NXRT_PANENAME_OFF"), NULL, 16) : 0xb0;
    if (off >= 0x1000) {   // pointer at off - 0x1000
        const char *q = *(const char *const *)(p + off - 0x1000);
        memset(out, 0, 25);
        if (q) memcpy(out, q, 24);
    } else memcpy(out, p + off, 24);
    out[24] = 0;
    for (int i = 0; i < 24 && out[i]; i++)
        if (out[i] < 0x20 || out[i] > 0x7e) out[i] = '?';
}

// ---- pane trees of the drawn layouts -------------------------------------------------------------
// Children: list head at pane+0x20 {next, prev}; a child's node is child+0x08. Type by vtable (ui2d classes and the
// game's subclasses of TextBox; anything else "pane").
typedef void (*PaneFn)(const uint8_t *pane, int depth, void *ctx);
static void walk(const uint8_t *p, int depth, PaneFn fn, void *ctx) {
    if (!p || depth > 40) return;
    fn(p, depth, ctx);
    const uint8_t *head = p + 0x20, *n = *(const uint8_t *const *)head;
    for (int i = 0; n && n != head && i < 4096; i++, n = *(const uint8_t *const *)n) walk(n - 8, depth + 1, fn, ctx);
}
// Distinct drawn layouts (processed in the last 3 frames), back to front: a layout processed later in the frame is
// drawn over the earlier ones (the main menu after the island's).
static int drawn_layouts(const uint8_t **out, int max) {
    int n = 0;
    unsigned seq[64];
    for (int i = 0; i < 64; i++) {
        const uint8_t *l = g_drawn_p[i];
        if (!l || g_cur_frame - g_drawn_f[i] > 3) continue;
        int k = 0;
        while (k < n && out[k] != l) k++;
        if (k < n) {
            if ((int)(g_drawn_seq[i] - seq[k]) > 0) seq[k] = g_drawn_seq[i];
        } else if (n < max) out[n] = l, seq[n++] = g_drawn_seq[i];
    }
    for (int a = 1; a < n; a++)   // insertion sort by sequence
        for (int b = a; b > 0 && (int)(seq[b] - seq[b - 1]) < 0; b--) {
            unsigned t = seq[b]; seq[b] = seq[b - 1], seq[b - 1] = t;
            const uint8_t *u = out[b]; out[b] = out[b - 1], out[b - 1] = u;
        }
    return n;
}
static const char *pane_type(const uint8_t *p) {
    if (is_textbox(p)) return "text";
    return "pane";
}
static void dump_one(const uint8_t *p, int depth, void *ctx) {
    char nm[25];
    pane_name(p, nm);
    float r[4];
    pane_rect(p, r);
    uint64_t vt = *(const uint64_t *)p;
    char extra[64] = "";
    if (is_textbox(p)) {
        const uint16_t *str = *(const uint16_t *const *)(p + 0xd8);
        unsigned len = *(const uint16_t *)(p + 0x112);
        int o = 0;
        for (unsigned i = 0; str && i < len && i < 12 && o < 56; i++)
            o += str[i] >= 0x20 && str[i] < 0x7f ? snprintf(extra + o, 64 - o, "%c", str[i]) : snprintf(extra + o, 64 - o, "<%04x>", str[i]);
    }
    if (getenv("NXRT_UIDUMP_FINDNAME"))   // recon: where an inline ui2d name ("N_..", "P_..") sits in the object
        for (int o = 0; o < 0x140; o++)
            if (strchr("NPTLWB", p[o]) && p[o + 1] == '_' && p[o + 2] >= 'A' && p[o + 2] <= 'z') {
                nx_log("uidump: name at +%#x: %.24s", o, (const char *)p + o);
                break;
            }
    nx_log("uidump: %*s%s %s vt main+%#llx %s a%d g%d f%02x%02x rect %.0f,%.0f-%.0f,%.0f %s", depth * 2, "", nm, pane_type(p),
           (unsigned long long)(vt - (uint64_t)g_main), (p[0x58] & 1) ? "vis" : "HID", p[0x59], p[0x5a], p[0x5b], p[0x58], r[0], r[1], r[2],
           r[3], extra);
}
static void ui_dump(void) {
    const uint8_t *ls[64];
    int n = drawn_layouts(ls, 64);
    for (int i = 0; i < n; i++) {
        nx_log("uidump: layout %p vt main+%#llx root %p", ls[i], (unsigned long long)(*(const uint64_t *)ls[i] - (uint64_t)g_main),
               *(const uint8_t *const *)(ls[i] + 0x18));
        walk(*(const uint8_t *const *)(ls[i] + 0x18), 1, dump_one, NULL);
    }
}

// A scripted tap (NXRT_TAP_AT): finger down and up through the gesture engine.
void nx_ui_touch(int type, float x, float y);
static void scripted_tap(int x, int y) {
    nx_ui_touch(0, (float)x, (float)y);
    nx_ui_touch(2, (float)x, (float)y);
}


// ---- gesture engine ---------------------------------------------------------------------------------------------
// Touches from the platform (iOS view, or NXRT_TOUCH_SCRIPT on the Mac) are queued and handled here on the render
// thread, once per frame before the HID sample, together with the pane walks (no race with the game's UI).
//   tap        -> a prompt's button; else a button (B_Bounding_00) of the top layout: focus moved there with the D-pad
//                 (closed loop on the menu cursor's corner panes N_LT_00/N_RD_00), then A; else A
//   swipe      -> island (centre pointer N_Pointer_00 shown): the world follows the finger (stick against the finger's
//                 velocity) and glides on after release; menus with a focus cursor: D-pad steps against the finger
//                 (content follows the finger); anywhere else: a real touch-screen drag
//   long press -> on a prompt: that button held; island: A held (grab) and moving carries; else a real touch held
//   Back       -> nx_ui_flags() bit 0 on a menu without its own B prompt (the app shows a floating Back button)
#include <time.h>
enum { EV_DOWN, EV_MOVE, EV_UP, EV_CANCEL, EV_BACK };
typedef struct { int type, id; float x, y; double t; } TouchEv;
static TouchEv g_evq[256];
static unsigned g_evq_w, g_evq_r;
static pthread_mutex_t g_evq_lock = PTHREAD_MUTEX_INITIALIZER;
static double now_s(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }
// type EV_*, id = finger 0 or 1 (the platform numbers fingers in landing order), game px.
void nx_ui_touch2(int type, int id, float x, float y) {
    pthread_mutex_lock(&g_evq_lock);
    if (g_evq_w - g_evq_r < 256) g_evq[g_evq_w++ % 256] = (TouchEv){type, id, x, y, now_s()};
    pthread_mutex_unlock(&g_evq_lock);
}
void nx_ui_touch(int type, float x, float y) { nx_ui_touch2(type, 0, x, y); }

// What is on screen (one walk over the drawn layouts' visible panes).
typedef struct { float r[4]; int z; } Box;
typedef struct {
    int island, focus, back;   // island: a world view (centre hand shown, or the HUD's X + Y prompts), no menu cursor
    float f[4];                 // focused item: centres of N_LT_00 .. N_RD_00
    Box btn[256]; int nbtn;     // B_Bounding_00
    Box pr[64]; int pbtn[64]; int npr;   // prompts (glyph text boxes) and their HID buttons
    uint16_t pstr[64][24];               // their text (glyph + label, e.g. "<A> Drop")
} Scene;
static Scene g_sc;
static int g_scan_z;
static void scan_one(const uint8_t *p, Scene *sc) {
    // Pane flag 0x80 (+0x58): set on every prompt, button box and cursor corner actually shown; the game's hidden
    // alternatives (other control layouts, pre-built parts) keep only bit 0 ("visible") and would steal taps.
    if (!(p[0x58] & 0x80)) return;
    char nm[25];
    pane_name(p, nm);
    float r[4];
    if (nm[0] == 'B' && !strcmp(nm, "B_Bounding_00")) {
        if (sc->nbtn < 256) pane_rect(p, sc->btn[sc->nbtn].r), sc->btn[sc->nbtn++].z = g_scan_z;
    } else if (nm[0] == 'N') {
        if (!strcmp(nm, "N_LT_00")) pane_rect(p, r), sc->f[0] = (r[0] + r[2]) / 2, sc->f[1] = (r[1] + r[3]) / 2, sc->focus |= 1;
        else if (!strcmp(nm, "N_RD_00")) pane_rect(p, r), sc->f[2] = (r[0] + r[2]) / 2, sc->f[3] = (r[1] + r[3]) / 2, sc->focus |= 2;
    } else if (!strncmp(nm, "P_Finger_", 9)) {   // a hand at the screen centre: a world view (island, Island Builder)
        pane_rect(p, r);
        if (fabsf((r[0] + r[2]) / 2 - nx_game_width() / 2) < 100 && fabsf((r[1] + r[3]) / 2 - 370) < 100) sc->island |= 4;
    } else if (is_textbox(p)) {
        const uint16_t *str = *(const uint16_t *const *)(p + 0xd8);
        unsigned len = *(const uint16_t *)(p + 0x112);
        int b = -1;
        for (unsigned k = 0; str && k < len && k < 8 && b < 0; k++) b = glyph_button(str[k]);
        if (b >= 0 && getenv("NXRT_FONTLOG")) {   // recon: which font class draws the button glyphs
            static const void *seen[16];
            const uint8_t *font = *(const uint8_t *const *)(p + 0xf0);
            int k = 0;
            while (k < 16 && seen[k] && seen[k] != font) k++;
            if (font && k < 16 && !seen[k]) {
                seen[k] = font;
                const uint8_t *vt = *(const uint8_t *const *)font;
                const uint8_t *ti = *(const uint8_t *const *)(vt - 8);
                const char *nm = ti ? *(const char *const *)(ti + 8) : NULL;
                nx_log("ui: glyph font %p vt main+%#llx class %s", font, (unsigned long long)(vt - g_main), nm ? nm : "(no RTTI)");
                // TrueType data reachable from it (two pointer hops): header 00 01 00 00 / "OTTO" / "true" + table count
                for (int a = 0; a < 0x400; a += 8) {
                    const uint8_t *q = *(const uint8_t *const *)(font + a);
                    if ((uintptr_t)q < 0x7000000000 || (uintptr_t)q > 0x7fffffffff) continue;
                    for (int b2 = -1; b2 < 0x200; b2 += 8) {
                        const uint8_t *r = b2 < 0 ? q : *(const uint8_t *const *)(q + b2);
                        if ((uintptr_t)r < 0x7000000000 || (uintptr_t)r > 0x7fffffffff) continue;
                        uint32_t m = (uint32_t)r[0] << 24 | r[1] << 16 | r[2] << 8 | r[3];
                        if ((m == 0x00010000 || m == 0x4f54544f || m == 0x74727565) && r[4] == 0 && r[5] > 4 && r[5] < 40)
                            nx_log("ui: font %p +%#x%s -> %p: TrueType header, %d tables", font, a, b2 < 0 ? "" : " ->", r, r[5]);
                    }
                }
            }
        }
        if (b >= 0 && sc->npr < 64) {
            memset(sc->pstr[sc->npr], 0, sizeof sc->pstr[0]);
            for (unsigned k = 0; k < len && k < 23; k++) sc->pstr[sc->npr][k] = str[k];
            pane_rect(p, sc->pr[sc->npr].r), sc->pr[sc->npr].z = g_scan_z, sc->pbtn[sc->npr++] = b;
            if (b == 1) sc->back = 1;
            // The island HUD: X (menu) and Y (Miis) prompts in the bottom-right corner.
            const float *r = sc->pr[sc->npr - 1].r;
            if ((b == 2 || b == 3) && r[0] > 900 && r[1] > 550) sc->island |= b == 2 ? 1 : 2;
        }
    }
}
static void scan_walk(const uint8_t *p, int depth, Scene *sc) {
    if (!p || depth > 40 || !(p[0x58] & 1) || !p[0x59]) return;   // hidden subtrees are skipped whole
    scan_one(p, sc);
    const uint8_t *head = p + 0x20, *n = *(const uint8_t *const *)head;
    for (int i = 0; n && n != head && i < 4096; i++, n = *(const uint8_t *const *)n) scan_walk(n - 8, depth + 1, sc);
}
static void scan(Scene *sc) {
    memset(sc, 0, sizeof *sc);
    const uint8_t *ls[64];
    int n = drawn_layouts(ls, 64);
    for (int i = 0; i < n; i++) g_scan_z = i, scan_walk(*(const uint8_t *const *)(ls[i] + 0x18), 0, sc);
    if (sc->focus != 3) sc->focus = 0;
    sc->island = ((sc->island & 3) == 3 || (sc->island & 4)) && !sc->focus;   // world view, no menu cursor
}
static int in_box(const float r[4], float x, float y, float m) { return x >= r[0] - m && x <= r[2] + m && y >= r[1] - m && y <= r[3] + m; }
// The prompt under (x, y) (glyph box + margin, nearest centre wins), or -1.
static int prompt_at(const Scene *sc, float x, float y) {
    int best = -1;
    float bd = 1e9f;
    for (int i = 0; i < sc->npr; i++) {
        const float *r = sc->pr[i].r;
        if (!in_box(r, x, y, 36)) continue;
        float d = hypotf(x - (r[0] + r[2]) / 2, y - (r[1] + r[3]) / 2);
        if (d < bd) bd = d, best = sc->pbtn[i];
    }
    return best;
}
// The button box under (x, y) in the topmost layout that has one there, or -1.
static int button_at(const Scene *sc, float x, float y) {
    int best = -1;
    for (int i = 0; i < sc->nbtn; i++)
        if (in_box(sc->btn[i].r, x, y, 0) && (best < 0 || sc->btn[i].z >= sc->btn[best].z)) {
            // the smallest box among those of the same layout (a row inside a panel)
            if (best >= 0 && sc->btn[i].z == sc->btn[best].z) {
                const float *a = sc->btn[i].r, *b = sc->btn[best].r;
                if ((a[2] - a[0]) * (a[3] - a[1]) > (b[2] - b[0]) * (b[3] - b[1])) continue;
            }
            best = i;
        }
    return best;
}

// The game's menu focus manager (no RTTI): vtable main+0x322da30, slot +0x20 (main+0x20591e0) is its per-frame
// update (D-pad input -> neighbour -> SetFocus main+0x702510(mgr, control, 0, 0, 0)). mgr+0x58 = focused control;
// control+0x48 + dir*8 = its neighbours (4 directions); mgr+0x28..+0x40 = the cursor's corner panes.
static Fn8 g_fm_orig;
static void fm_log(const uint8_t *mgr) {
    const uint8_t *cur = *(const uint8_t *const *)(mgr + 0x58);
    nx_log("ui: focus mgr %p current %p", mgr, cur);
    const uint8_t *seen[64];
    int n = 0;
    if (cur) seen[n++] = cur;
    for (int i = 0; i < n; i++) {
        const uint8_t *c = seen[i], *a = *(const uint8_t *const *)(c + 0x18), *b = a ? *(const uint8_t *const *)(a + 0x60) : NULL;
        char na[25] = "", nb[25] = "";
        if ((uintptr_t)a >= 0x7000000000 && (uintptr_t)a < 0x8000000000) pane_name(a, na);
        if ((uintptr_t)b >= 0x7000000000 && (uintptr_t)b < 0x8000000000) pane_name(b, nb);
        float r[4] = {0};
        if (nb[0]) pane_rect(b, r);
        nx_log("ui:   control %p: +0x18 %p '%s', ->+0x60 %p '%s' rect %.0f,%.0f-%.0f,%.0f  nb %p %p %p %p", c, a, na, b, nb,
               r[0], r[1], r[2], r[3], *(void *const *)(c + 0x48), *(void *const *)(c + 0x50), *(void *const *)(c + 0x58),
               *(void *const *)(c + 0x60));
        for (int d = 0; d < 4 && n < 64; d++) {
            const uint8_t *q = *(const uint8_t *const *)(c + 0x48 + 8 * d);
            int k = 0;
            while (q && k < n && seen[k] != q) k++;
            if (q && k == n) seen[n++] = q;
        }
    }
}
static int guest_ptr(const void *p) { return (uintptr_t)p >= 0x7000000000 && (uintptr_t)p < 0x8000000000 && !((uintptr_t)p & 7); }
// A tap on a menu row: the manager that owns a control under (x, y) focuses it directly (on the game thread, before
// its update), like its own D-pad path does. The controls of a menu are on an intrusive list at control+0x8 (head in
// the menu object); control+0x18 -> button, button+0x60 = its B_Bounding_00 pane.
static struct { float x, y; volatile int frame, done; } g_freq;
static void fm_jump(uint8_t *mgr) {
    uint8_t *cur = *(uint8_t *const *)(mgr + 0x58);
    if (!guest_ptr(cur)) return;
    uint8_t *start = cur + 8, *node = *(uint8_t *const *)(start + 8);   // node: {prev, next}
    for (int i = 0; i < 256 && guest_ptr(node) && node != start; i++, node = *(uint8_t *const *)(node + 8)) {
        uint8_t *c = node - 8, *btn = *(uint8_t *const *)(c + 0x18);
        if (!guest_ptr(btn)) continue;   // the list head (inside the menu object)
        const uint8_t *pane = *(const uint8_t *const *)(btn + 0x60);
        if (!guest_ptr(pane) || !(pane[0x58] & 0x80)) continue;
        float r[4];
        pane_rect(pane, r);
        if (!in_box(r, g_freq.x, g_freq.y, 0)) continue;
        uint8_t *sub = *(uint8_t *const *)(c + 0x20);
        if (guest_ptr(sub)) sub[0x123] = 1;   // as the game's own neighbour moves do before SetFocus
        ((Fn8)(g_main + 0x702510))((uint64_t)mgr, (uint64_t)c, 0, 0, 0, 0, 0, 0);
        g_freq.done = 1;
        nx_log("ui: tap focus: control %p (box %.0f,%.0f-%.0f,%.0f) focused directly", c, r[0], r[1], r[2], r[3]);
        return;
    }
}
static uint64_t fm_wrap(uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e, uint64_t f, uint64_t g, uint64_t h) {
    static int logf = -1;
    if (logf < 0) logf = getenv("NXRT_FOCUSLOG") ? atoi(getenv("NXRT_FOCUSLOG")) : 0;
    if (logf && g_cur_frame == logf) fm_log((const uint8_t *)a);
    if (g_freq.frame && !g_freq.done && g_cur_frame - g_freq.frame <= 3) fm_jump((uint8_t *)a);
    return g_fm_orig(a, b, c, d, e, f, g, h);
}
static void focus_hook(void) {
    uint64_t *slot = (uint64_t *)(g_main + 0x322da50);
    if (*slot != (uint64_t)(g_main + 0x20591e0)) { nx_log("ui: focus hook: unexpected slot %#llx", (unsigned long long)*slot); return; }
    uintptr_t pg = (uintptr_t)slot & ~(uintptr_t)0x3fff;
    mprotect((void *)pg, 0x4000, PROT_READ | PROT_WRITE);
    g_fm_orig = (Fn8)*slot;
    *slot = (uint64_t)fm_wrap;
}

// Output: button presses scheduled by frame, held buttons, stick.
enum { BA = 1 << 0, BB = 1 << 1, DL = 1 << 12, DU = 1 << 13, DR = 1 << 14, DD = 1 << 15 };
static struct { uint64_t bits; int from, to; } g_out[32];
static uint64_t g_held;
static int g_stick_on;
static float g_stick[2];
static int g_frame;
static void press(uint64_t bits, int after, int frames) {   // after = frames from now
    for (int i = 0; i < 32; i++)
        if (g_out[i].to <= g_frame) {
            g_out[i].bits = bits, g_out[i].from = g_frame + after, g_out[i].to = g_frame + after + frames;
            return;
        }
}
static int queue_busy(void) {   // frames until the last scheduled press ends
    int m = 0;
    for (int i = 0; i < 32; i++) if (g_out[i].to > g_frame && g_out[i].to - g_frame > m) m = g_out[i].to - g_frame;
    return m;
}

// Finger state.
enum { G_IDLE, G_PENDING, G_PAN, G_DPAD, G_HOLD, G_TOUCH, G_TWO, G_WAITUP };
static struct {
    int st, prompt, island, focus;   // context at touch-down
    float x0, y0, x, y, vx, vy;      // game px; velocity px/s
    double t0, tl;
    float travel;                    // G_DPAD: px along the axis since the last step
    int axis;                        // 0 x, 1 y
    uint64_t hold;                   // G_HOLD: the held button
    int down[2];                     // fingers down
    float p[2][2];                   // G_TWO: both fingers
    float cvx, cvy, svel, wvel;      // G_TWO: centroid velocity (px/s), spread rate (d ln spread / s), twist (rad/s)
    double t2;                       // G_TWO: last update
    Scene *hold_sc;                  // G_HOLD on the island: the prompts when the hold began
} F;
static Scene g_hold_sc;
// A prompt for button b on screen now that was not there in `before` (by text): e.g. "Drop" once a Mii is grabbed.
static int new_prompt(const Scene *before, const Scene *now, int b) {
    for (int i = 0; i < now->npr; i++) {
        if (now->pbtn[i] != b) continue;
        int seen = 0;
        for (int k = 0; k < before->npr && !seen; k++) seen = !memcmp(before->pstr[k], now->pstr[i], sizeof now->pstr[i]);
        if (!seen) return 1;
    }
    return 0;
}
static const double HOLD_S = 0.4;   // long press
// Island pan as distance owed: finger movement (and a fling's run-out) adds screen px the world still has to move;
// each frame the stick moves the camera by up to what the game can do (measured: ~20 px/frame horizontally, linear
// in tilt; ~7 px/frame vertically, reached at half tilt) and that much is paid off. Total travel matches the finger
// even where the game's camera is slower than the finger (vertical), and the run-out is the glide.
static float g_debt[2];
enum { PAN_VX = 20, PAN_VY = 7 };
// Tap anywhere on the island: the game picks only under its centre hand (the pointer is fixed at the screen centre;
// the island ignores the game's touch screen), so a tap away from the centre owes the camera the distance from the tap
// to the centre (the tapped spot glides under the hand, as a drag from there to the centre would), then presses A once
// the camera has settled. NXRT_TAPCENTRE=0: old (A at once, on whatever is under the hand).
// Miis are steered closed loop: the runtime knows where each one is on screen (gfx_cmd.m gfx_pick_objects, from the
// game's visibility queries), so after each glide the remaining error is measured and glided again (the camera's
// vertical response lags ~0.5 s and its speed depends on the zoom: one open-loop glide missed by ~40% vertically),
// learning the camera's px-per-px scale per axis as it goes. Anything else (houses, ground): one glide with that scale.
static struct { int on, settle, frame, mii, iter, lost; float start[2], asked[2], pos[2]; } TC;
static float g_tc_scale[2] = {1.12f, 0.59f};   // camera displacement per owed px (measured: 570/509, 100/170)
int gfx_pick_objects(float out[][2], float box[][4], unsigned char *valid, int max);
// The Mii nearest (x, y) within r px: its block, and its position in p. Blocks are repacked as Miis come and go, so a
// Mii is followed by position from frame to frame (it and the camera move at most ~20 px a frame), not by block.
static float g_mii_box[4];   // the body box (game px) of the Mii mii_near found last
static int mii_near(float x, float y, float r, float p[2]) {
    float o[128][2], bx[128][4];
    unsigned char v[128];
    if (gfx_pick_objects(o, bx, v, 128) < 0) return -1;
    int best = -1;
    float bd = r;
    for (int k = 0; k < 128; k++) {
        float d = v[k] ? hypotf(o[k][0] * nx_game_width() - x, o[k][1] * nx_game_height() - y) : 1e9f;
        if (d < bd) bd = d, best = k;
    }
    if (best >= 0 && p) p[0] = o[best][0] * nx_game_width(), p[1] = o[best][1] * nx_game_height();
    if (best >= 0)
        for (int a = 0; a < 4; a++) g_mii_box[a] = bx[best][a] * (a & 1 ? nx_game_height() : nx_game_width());
    return best;
}
static int hand_on_mii(float margin) {   // the centre hand inside the found Mii's body box (+ margin px)
    float cx = nx_game_width() / 2.0f, cy = nx_game_height() / 2.0f;
    return cx >= g_mii_box[0] - margin && cx <= g_mii_box[2] + margin && cy >= g_mii_box[1] - margin && cy <= g_mii_box[3] + margin;
}
static void tc_glide(float ex, float ey) {   // owe the camera what moves the content by (ex, ey)
    TC.asked[0] = g_debt[0] = ex / g_tc_scale[0], TC.asked[1] = g_debt[1] = ey / g_tc_scale[1], TC.settle = 0;
}
// Closed-loop focus move to a button, then A.
static struct { int on, steps, wait, tries; float t[4], last[2]; uint64_t dir, alt; } N;

static void nav_start(const float r[4]) {
    memset(&N, 0, sizeof N);
    N.on = 1, N.wait = 3;   // the direct focus (fm_jump) gets its chance first; D-pad steps are the fallback
    memcpy(N.t, r, sizeof N.t);
    N.last[0] = N.last[1] = -1e9f;
}
static void nav_tick(void) {
    if (!N.on || queue_busy()) return;
    if (N.wait > 0) { N.wait--; return; }
    Scene sc;
    scan(&sc);
    if (!sc.focus) { N.on = 0; press(BA, 0, 3); return; }   // the cursor went away: just confirm
    float fx = (sc.f[0] + sc.f[2]) / 2, fy = (sc.f[1] + sc.f[3]) / 2;
    if (in_box(N.t, fx, fy, 0)) { N.on = 0; press(BA, 1, 3); return; }
    int moved = fabsf(fx - N.last[0]) > 2 || fabsf(fy - N.last[1]) > 2;
    if (N.steps && !moved) {   // that direction did nothing: try the other axis once, then give up
        if (N.tries++ >= 2) { N.on = 0; return; }
    }
    if (++N.steps > 24) { N.on = 0; return; }
    float dx = (N.t[0] + N.t[2]) / 2 - fx, dy = (N.t[1] + N.t[3]) / 2 - fy;
    float w = fmaxf(N.t[2] - N.t[0], 1), h = fmaxf(N.t[3] - N.t[1], 1);
    int horiz = fabsf(dx) / w > fabsf(dy) / h;
    if (N.tries == 1) horiz = !horiz;   // retry along the other axis
    uint64_t d = horiz ? (dx > 0 ? DR : DL) : (dy > 0 ? DD : DU);
    N.last[0] = fx, N.last[1] = fy;
    // All the steps the geometry suggests at once (buttons the size of the target apart), as fast as the game reads
    // them (1 frame pressed, 1 released): the cursor jumps instead of walking. The loop then checks and corrects.
    int n = N.steps == 1 ? (int)lroundf(horiz ? fabsf(dx) / w : fabsf(dy) / h) : 1;
    if (n < 1) n = 1;
    if (n > 12) n = 12;
    for (int i = 0; i < n; i++) press(d, 2 * i, 1);
    N.wait = 2;   // let the cursor settle before looking again
}

// This frame's stick for the owed distance (content follows the finger), as one 2D motion: the payment is a fraction
// of what is owed (ease-out: a fling glides and slows down smoothly instead of running at full speed and stopping),
// scaled as a whole so neither axis exceeds what the game's camera can do in a frame: the direction is kept exactly
// (per-axis caps bent diagonals toward the axes). Vertical full speed is reached at ~half tilt (PAN_VY).
static void pan_pay(float out[2]) {
    float px = g_debt[0] * 0.3f, py = g_debt[1] * 0.3f;
    if (fabsf(g_debt[0]) < 2 && fabsf(g_debt[1]) < 2) px = g_debt[0], py = g_debt[1];   // the last bit at once
    float k = 1;
    if (fabsf(px) > PAN_VX) k = fminf(k, PAN_VX / fabsf(px));
    if (fabsf(py) > PAN_VY) k = fminf(k, PAN_VY / fabsf(py));
    px *= k, py *= k;
    g_debt[0] -= px, g_debt[1] -= py;
    out[0] = -px / PAN_VX * 32767;
    out[1] = fminf(32767, fmaxf(-32767, py / PAN_VY * 16384 * 1.15f));   // a little over half tilt: the vertical cap
}
static void touch_real(int down, float x, float y) {
    void nx_hid_set_touch(int down, int x, int y);
    nx_hid_set_touch(down, (int)(x - (nx_game_width() - 1280) / 2), (int)(y - (nx_game_height() - 720) / 2));   // the centre 16:9
}
// A tap on a button of a menu without a focus cursor (e.g. Menu_SelectHand: six hands picked with the L stick, none
// selected at first, so A alone does nothing): its focus manager focuses the tapped button directly (fm_jump), then A;
// if no manager took it within a few frames, a real tap on the game's touch screen (the buttons have TouchSelect /
// TouchDecide states). NXRT_TAPDIRECT=0 = old (A).
static struct { int on, frame, up; float x, y; } T;
static void tapbtn_tick(void) {
    if (!T.on) return;
    if (T.up) {   // real touch in progress: lift after 4 frames
        if (g_frame >= T.up) touch_real(0, T.x, T.y), T.on = 0;
        return;
    }
    if (g_freq.done) { T.on = 0; press(BA, 1, 3); nx_log("ui: tap button: focused directly -> A"); return; }
    if (g_frame - T.frame > 4) {
        touch_real(1, T.x, T.y), T.up = g_frame + 4;
        nx_log("ui: tap button: no focus manager took it -> touch %.0f,%.0f", T.x, T.y);
    }
}
static void on_tap(float x, float y) {
    Scene sc;
    scan(&sc);
    int after = queue_busy() ? queue_busy() + 1 : 0;   // a quick second tap is a second press, not merged into the first
    int b = prompt_at(&sc, x, y);
    if (b >= 0) { press(1ull << b, after, 3); nx_log("ui: tap %.0f,%.0f -> prompt button %d", x, y, b); return; }
    int k = button_at(&sc, x, y);
    if (k >= 0 && sc.focus) { g_freq.x = x, g_freq.y = y, g_freq.done = 0, g_freq.frame = g_frame;   // direct focus (game thread)
                              nav_start(sc.btn[k].r); nx_log("ui: tap %.0f,%.0f -> button box %.0f,%.0f-%.0f,%.0f", x, y,
                                                         sc.btn[k].r[0], sc.btn[k].r[1], sc.btn[k].r[2], sc.btn[k].r[3]); return; }
    if (sc.focus) {   // a menu, but not on any of its buttons: close it (B) where it can be closed, else nothing
        if (sc.back) press(BB, after, 3);
        nx_log("ui: tap %.0f,%.0f -> outside the menu's buttons: %s", x, y, sc.back ? "B" : "ignored");
        return;
    }
    static int direct = -1;
    if (direct < 0) direct = !getenv("NXRT_TAPDIRECT") || atoi(getenv("NXRT_TAPDIRECT"));
    if (k >= 0 && !sc.island && direct && !T.on && !after) {
        g_freq.x = x, g_freq.y = y, g_freq.done = 0, g_freq.frame = g_frame;
        T = (typeof(T)){1, g_frame, 0, x, y};
        nx_log("ui: tap %.0f,%.0f -> button box %.0f,%.0f-%.0f,%.0f (no cursor)", x, y, sc.btn[k].r[0], sc.btn[k].r[1],
               sc.btn[k].r[2], sc.btn[k].r[3]);
        return;
    }
    static int tapcentre = -1;
    if (tapcentre < 0) tapcentre = !getenv("NXRT_TAPCENTRE") || atoi(getenv("NXRT_TAPCENTRE"));
    float dx = nx_game_width() / 2.0f - x, dy = nx_game_height() / 2.0f - y;
    if (sc.island && tapcentre && !after) {
        float p[2] = {x, y};
        int k = mii_near(x, y, 70, p);
        if (k >= 0) dx = nx_game_width() / 2.0f - p[0], dy = nx_game_height() / 2.0f - p[1];
        // Already under the hand (its body covers the hand's point), or a spot near it: A at once, as before.
        if (k >= 0 ? !hand_on_mii(16) : hypotf(dx, dy) > 60) {
            TC.on = 1, TC.frame = g_frame, TC.mii = k, TC.iter = 0, TC.lost = 0, TC.start[0] = TC.pos[0] = p[0], TC.start[1] = TC.pos[1] = p[1];
            tc_glide(dx, dy);
            nx_log("ui: tap %.0f,%.0f on the island -> %s at %.0f,%.0f: glide %.0f,%.0f under the hand", x, y, k >= 0 ? "Mii" : "spot",
                   p[0], p[1], dx, dy);
            return;
        }
    }
    press(BA, after, 3);   // dialogs, the island, "Press A": a tap is A
    nx_log("ui: tap %.0f,%.0f -> A", x, y);
}
static void handle(const TouchEv *e) {
    static const float SLOP = 20, STEP = 70;   // game px (12 pt on the phone is ~20 px)
    static int raw = -1;   // NXRT_RAWTOUCH=1 (recon): finger 0 straight to the game's touch screen
    if (raw < 0) raw = getenv("NXRT_RAWTOUCH") != NULL;
    if (raw) {
        if (e->id == 0 && e->type != EV_BACK) touch_real(e->type == EV_DOWN || e->type == EV_MOVE, e->x, e->y);
        return;
    }
    if (e->type != EV_BACK && (e->id == 1 || F.st == G_TWO || F.st == G_WAITUP)) {   // two fingers
        int id = e->id & 1;
        if (e->type == EV_DOWN) {
            F.down[id] = 1, F.p[id][0] = e->x, F.p[id][1] = e->y;
            if (F.down[0] && F.down[1] && F.st != G_TWO) {   // second finger: the first one's gesture ends unfinished
                if (F.st == G_TOUCH) touch_real(0, F.x, F.y);
                g_held = 0, g_debt[0] = g_debt[1] = 0, N.on = 0;
                F.st = F.island ? G_TWO : G_WAITUP, F.t2 = e->t, F.cvx = F.cvy = F.svel = F.wvel = 0;
                if (id == 1) F.p[0][0] = F.x, F.p[0][1] = F.y;
                nx_log("ui: two fingers -> %s", F.st == G_TWO ? "camera" : "ignored");
            }
        } else if (e->type == EV_MOVE && F.st == G_TWO) {
            float ocx = (F.p[0][0] + F.p[1][0]) / 2, ocy = (F.p[0][1] + F.p[1][1]) / 2;
            float osp = hypotf(F.p[0][0] - F.p[1][0], F.p[0][1] - F.p[1][1]);
            float oang = atan2f(F.p[1][1] - F.p[0][1], F.p[1][0] - F.p[0][0]);
            F.p[id][0] = e->x, F.p[id][1] = e->y;
            float ncx = (F.p[0][0] + F.p[1][0]) / 2, ncy = (F.p[0][1] + F.p[1][1]) / 2;
            float nsp = hypotf(F.p[0][0] - F.p[1][0], F.p[0][1] - F.p[1][1]);
            float dang = atan2f(F.p[1][1] - F.p[0][1], F.p[1][0] - F.p[0][0]) - oang;
            if (dang > 3.14159f) dang -= 6.28318f;
            if (dang < -3.14159f) dang += 6.28318f;
            double dt = e->t - F.t2;
            if (dt > 0.004 && osp > 10 && nsp > 10) {
                F.cvx = 0.5f * F.cvx + 0.5f * (ncx - ocx) / dt, F.cvy = 0.5f * F.cvy + 0.5f * (ncy - ocy) / dt;
                F.svel = 0.5f * F.svel + 0.5f * logf(nsp / osp) / dt;
                F.wvel = 0.5f * F.wvel + 0.5f * dang / dt;
                F.t2 = e->t;
            }
        } else if (e->type == EV_MOVE) F.p[id][0] = e->x, F.p[id][1] = e->y;
        else if (e->type == EV_UP || e->type == EV_CANCEL) {
            F.down[id] = 0;
            if (F.st == G_TWO) F.st = G_WAITUP;   // the other finger does nothing until it lifts too
            if (!F.down[0] && !F.down[1]) F.st = G_IDLE;
        }
        return;
    }
    switch (e->type) {
    case EV_BACK: press(BB, 0, 3); break;
    case EV_DOWN: {
        if (F.st != G_IDLE) break;   // one finger
        N.on = 0, TC.on = 0, g_debt[0] = g_debt[1] = 0;   // a new touch stops a glide, a pending focus move or tap
        Scene sc;
        scan(&sc);
        F.st = G_PENDING, F.x0 = F.x = e->x, F.y0 = F.y = e->y, F.t0 = F.tl = e->t, F.vx = F.vy = 0, F.travel = 0;
        F.down[0] = 1, F.down[1] = 0, F.p[0][0] = e->x, F.p[0][1] = e->y;
        F.prompt = prompt_at(&sc, e->x, e->y), F.island = sc.island, F.focus = sc.focus;
        if (getenv("NXRT_TAPLOG")) nx_log("ui: down %.0f,%.0f island %d focus %d prompts %d buttons %d back %d", e->x, e->y, sc.island, sc.focus,
                                          sc.npr, sc.nbtn, sc.back);
        break;
    }
    case EV_MOVE: {
        if (F.st == G_IDLE) break;
        double dt = e->t - F.tl;
        if (dt > 0.004) {
            float ivx = (e->x - F.x) / dt, ivy = (e->y - F.y) / dt;
            F.vx = 0.5f * F.vx + 0.5f * ivx, F.vy = 0.5f * F.vy + 0.5f * ivy;
        }
        float px = F.x, py = F.y;
        F.x = e->x, F.y = e->y, F.tl = e->t;
        if (F.st == G_PAN) g_debt[0] += F.x - px, g_debt[1] += F.y - py;
        if (F.st == G_PENDING && hypotf(F.x - F.x0, F.y - F.y0) >= SLOP) {
            if (F.island) F.st = G_PAN, g_debt[0] += F.x - F.x0, g_debt[1] += F.y - F.y0;
            else if (F.focus) F.st = G_DPAD, F.axis = fabsf(F.x - F.x0) < fabsf(F.y - F.y0);
            else F.st = G_TOUCH, touch_real(1, F.x0, F.y0);
            nx_log("ui: swipe from %.0f,%.0f -> %s", F.x0, F.y0, F.st == G_PAN ? "island pan" : F.st == G_DPAD ? "d-pad" : "touch drag");
        }
        if (F.st == G_TOUCH) touch_real(1, F.x, F.y);
        if (F.st == G_DPAD) {
            float d = F.axis ? F.y - py : F.x - px;
            F.travel += d;
            while (fabsf(F.travel) >= STEP) {   // content follows the finger: the selection moves against it
                uint64_t dir = F.axis ? (F.travel < 0 ? DD : DU) : (F.travel < 0 ? DR : DL);
                press(dir, queue_busy() + 1, 2);
                F.travel -= F.travel > 0 ? STEP : -STEP;
            }
        }
        break;
    }
    case EV_UP:
    case EV_CANCEL:
        if (F.st == G_PENDING && e->type == EV_UP) on_tap(F.x0, F.y0);
        else if (F.st == G_PAN && e->type == EV_UP) {   // fling: the run-out a scroll view would glide (~0.3 s of speed)
            float gx = g_debt[0] + F.vx * 0.3f, gy = g_debt[1] + F.vy * 0.3f, gl = hypotf(gx, gy);
            float k = gl > 900 ? 900 / gl : 1;   // capped as a vector (keeps the fling's direction)
            g_debt[0] = gx * k, g_debt[1] = gy * k;
        } else if (F.st == G_PAN) g_debt[0] = g_debt[1] = 0;
        else if (F.st == G_DPAD && e->type == EV_UP) {   // fling: a few more steps
            float v = F.axis ? F.vy : F.vx;
            int extra = (int)fminf(4, fabsf(v) / 1200);
            uint64_t dir = F.axis ? (v < 0 ? DD : DU) : (v < 0 ? DR : DL);
            for (int i = 0; i < extra; i++) press(dir, queue_busy() + 1, 2);
        } else if (F.st == G_TOUCH) touch_real(0, F.x, F.y);
        else if (F.st == G_HOLD && F.island && F.prompt < 0) {   // grabbed something: lifting the finger drops it
            Scene now;
            scan(&now);
            if (new_prompt(&g_hold_sc, &now, 0)) press(BA, 2, 3), nx_log("ui: release after grab -> A (drop)");
        }
        g_held = 0;
        F.st = G_IDLE, F.down[0] = 0;
        break;
    }
}
static void engine_tick(int frame) {
    g_frame = frame;
    for (;;) {
        TouchEv e;
        pthread_mutex_lock(&g_evq_lock);
        int have = g_evq_r != g_evq_w;
        if (have) e = g_evq[g_evq_r++ % 256];
        pthread_mutex_unlock(&g_evq_lock);
        if (!have) break;
        handle(&e);
    }
    double t = now_s();
    if (F.st == G_PENDING && t - F.t0 >= HOLD_S) {   // long press
        if (F.prompt >= 0) F.st = G_HOLD, F.hold = 1ull << F.prompt;
        else if (F.island) F.st = G_HOLD, F.hold = BA, scan(&g_hold_sc);
        else F.st = G_TOUCH, touch_real(1, F.x0, F.y0);
        if (F.st == G_HOLD) g_held = F.hold, nx_log("ui: long press -> hold %#llx", (unsigned long long)F.hold);
    }
    if ((F.st == G_PAN || F.st == G_HOLD) && t - F.tl > 0.06) F.vx *= 0.6f, F.vy *= 0.6f;   // finger resting
    nav_tick();
    tapbtn_tick();
    if (TC.on && TC.mii >= 0) {   // follow the tapped Mii
        float q[2];
        if (mii_near(TC.pos[0], TC.pos[1], 40, q) >= 0) TC.pos[0] = q[0], TC.pos[1] = q[1], TC.lost = 0;
        else if (++TC.lost > 10) TC.mii = -1, nx_log("ui: tap glide: lost the Mii");
    }
    if (TC.on && fabsf(g_debt[0]) < 1 && fabsf(g_debt[1]) < 1 && ++TC.settle >= 10) {   // tap-centre: the camera has stopped
        float p[2] = {TC.pos[0], TC.pos[1]}, cx = nx_game_width() / 2.0f, cy = nx_game_height() / 2.0f;
        if (TC.mii >= 0 && !TC.lost) {
            for (int a = 0; a < 2; a++)   // learn the camera's scale from this glide (the Mii's own walk is small)
                if (fabsf(TC.asked[a]) > 40) g_tc_scale[a] = fminf(3, fmaxf(0.3f, 0.5f * g_tc_scale[a] + 0.5f * (p[a] - TC.start[a]) / TC.asked[a]));
            float ex = cx - p[0], ey = cy - p[1];
            nx_log("ui: tap glide %d: Mii at %.0f,%.0f (off %.0f,%.0f), scale now %.2f,%.2f", TC.iter, p[0], p[1], ex, ey, g_tc_scale[0], g_tc_scale[1]);
            if (!hand_on_mii(0) && ++TC.iter < 4) {
                TC.start[0] = p[0], TC.start[1] = p[1];
                tc_glide(ex, ey);
                goto tc_done;
            }
        }
        TC.on = 0, press(BA, 0, 3);
        nx_log("ui: tap glide done after %d frames -> A", g_frame - TC.frame);
    }
tc_done:
    // right stick (island camera): pinch = zoom (spread up = in = stick up), two fingers sideways = rotate (content
    // follows the fingers), up/down = the zoom/tilt axis (fingers up = in). Full tilt at a spread rate of 1.4/s
    // (doubling in half a second) or 400 px/s.
    {
        float rx = 0, ry = 0;
        if (F.st == G_TWO) {
            if (t - F.t2 > 0.06) F.cvx *= 0.6f, F.cvy *= 0.6f, F.svel *= 0.6f, F.wvel *= 0.6f;   // fingers resting
            // Twist (screen y down: positive = clockwise) turns the world the same way, about 1:1: stick right turns it
            // counter-clockwise, ~1 rad/s at full tilt (Mac test). A sideways two-finger swipe drags the near ground
            // along (stick right moves it right).
            rx = -F.wvel / 1.0f * 32767 + F.cvx / 300 * 32767;
            ry = F.svel / 1.4f * 32767 - F.cvy / 400 * 32767;
        }
        void nx_hid_rstick(int x, int y);
        nx_hid_rstick((int)fmaxf(-32767, fminf(32767, rx)), (int)fmaxf(-32767, fminf(32767, ry)));
    }
    // stick
    g_stick_on = 0;
    if (F.st == G_PAN || F.st == G_TWO || fabsf(g_debt[0]) > 1 || fabsf(g_debt[1]) > 1) g_hand_hide_until = t + 0.5;   // hide the hand
    if (F.st == G_PAN || fabsf(g_debt[0]) > 1 || fabsf(g_debt[1]) > 1) {
        if (F.st == G_PAN || F.st == G_IDLE) g_stick_on = 1, pan_pay(g_stick);
        else g_debt[0] = g_debt[1] = 0;
    }
    else if (F.st == G_HOLD && F.island && hypotf(F.x - F.x0, F.y - F.y0) >= 20) {   // carrying: towards the finger
        float dx = F.x - F.x0, dy = F.y - F.y0, len = hypotf(dx, dy), k = fminf(1, len / 120) / len;
        g_stick_on = 1, g_stick[0] = dx * k * 32767, g_stick[1] = -dy * k * 32767;
    }
    uint64_t b = g_held;
    for (int i = 0; i < 32; i++)
        if (g_out[i].from <= frame && frame < g_out[i].to) b |= g_out[i].bits;
    void nx_hid_ui(uint64_t buttons, int stick_on, int x, int y);
    nx_hid_ui(b, g_stick_on, (int)g_stick[0], (int)g_stick[1]);
    static int sc_frame;   // the Back flag, refreshed every 10 frames
    static double sc_t, sc_max;   // its cost on the render thread, logged every 300 frames
    static int sc_n;
    if (frame - sc_frame >= 10) {
        sc_frame = frame;
        double t0 = now_s();
        scan(&g_sc);
        double dt = now_s() - t0;
        sc_t += dt, sc_n++;
        if (dt > sc_max) sc_max = dt;
        if (sc_n == 30) {
            nx_log("ui: back scan %.3f ms avg, %.3f ms max (%d scans)", sc_t / sc_n * 1000, sc_max * 1000, sc_n);
            sc_t = sc_max = 0, sc_n = 0;
        }
    }
}
// Bit 0: show the app's floating Back. Screens with a B prompt have their own tappable Back (bottom left, glyph hidden),
// so only a menu (cursor shown) without one gets the floating button.
// The title screen ("press start"): its layout has N_All > N_Base > P_TitleBase_WW. Found among the layouts drawn each
// frame (title_check, from the layout wrapper); "on title" while it was drawn within the last 3 frames.
static const uint8_t *g_title_root;
static volatile int g_title_frame = -100;
static const uint8_t *pane_child(const uint8_t *p, const char *name) {
    char nm[25];
    const uint8_t *head = p + 0x20, *n = *(const uint8_t *const *)head;
    for (int i = 0; n && n != head && i < 256; i++, n = *(const uint8_t *const *)n) {
        pane_name(n - 8, nm);
        if (!strcmp(nm, name)) return n - 8;
    }
    return NULL;
}
static void title_check(const uint8_t *layout) {
    const uint8_t *root = *(const uint8_t *const *)(layout + 0x18);
    if (!root) return;
    if (root == g_title_root) { g_title_frame = g_cur_frame; return; }
    static const uint8_t *checked[64];
    static unsigned nchecked;
    for (unsigned i = 0; i < 64; i++) if (checked[i] == root) return;
    checked[nchecked++ & 63] = root;
    const uint8_t *all = pane_child(root, "N_All"), *base = all ? pane_child(all, "N_Base") : NULL;
    if (base && pane_child(base, "P_TitleBase_WW")) {
        g_title_root = root, g_title_frame = g_cur_frame;
        nx_log("ui: title screen layout %p (frame %d)", (const void *)root, g_cur_frame);
    }
}
// bit 0: the game shows a B prompt (show Back); bit 1: the title screen is up (iOS: the island-select button).
int nx_ui_flags(void) { return (g_sc.focus && !g_sc.back ? 1 : 0) | (g_cur_frame - g_title_frame <= 3 ? 2 : 0); }

// NXRT_FOCUSPROBE=<f1>:<f2> (recon): who holds the menu's buttons. At f1, every heap word pointing at a shown
// B_Bounding_00 pane, its two ancestors or the cursor corners is logged and the 1 KB around it saved; at f2 (press a
// D-pad direction in between) the words that changed there are logged: the focus index / current-button pointer.
void nx_guest_heap_each(void (*fn)(uint8_t *p, size_t n, void *ctx), void *ctx);
#define FP_T 512
#define FP_H 4096
static const uint8_t *fp_t[FP_T]; static int fp_kind[FP_T], fp_nt;   // kind: 0 bounding, 1 parent, 2 grandparent, 3 cursor
static uint8_t *fp_h[FP_H]; static int fp_nh;
static uint8_t (*fp_snap)[1024];
static void fp_collect(const uint8_t *p, int depth, const uint8_t **anc) {
    if (!p || depth > 40 || !(p[0x58] & 1) || !p[0x59]) return;
    anc[depth] = p;
    char nm[25];
    pane_name(p, nm);
    if ((p[0x58] & 0x80) && fp_nt < FP_T - 3) {
        if (!strcmp(nm, "B_Bounding_00"))
            for (int k = 0; k < 3 && depth - k >= 0; k++) fp_t[fp_nt] = anc[depth - k], fp_kind[fp_nt++] = k;
        else if (!strcmp(nm, "N_LT_00") || !strcmp(nm, "N_RD_00")) fp_t[fp_nt] = p, fp_kind[fp_nt++] = 3;
    }
    const uint8_t *head = p + 0x20, *n = *(const uint8_t *const *)head;
    for (int i = 0; n && n != head && i < 4096; i++, n = *(const uint8_t *const *)n) fp_collect(n - 8, depth + 1, anc);
}
static void fp_run(uint8_t *p, size_t n, void *ctx) {
    for (size_t i = 0; i + 8 <= n; i += 8) {
        uint64_t v = *(const uint64_t *)(p + i);
        if (v < 0x7000000000 || v > 0x7fffffffff) continue;
        int lo = 0, hi = fp_nt - 1;   // fp_t is sorted
        while (lo < hi) { int m = (lo + hi) / 2; if ((uint64_t)fp_t[m] < v) lo = m + 1; else hi = m; }
        if (fp_nt && v == (uint64_t)fp_t[lo]) {
            if (fp_nh < FP_H) fp_h[fp_nh++] = p + i;
            if (fp_nh <= 400) nx_log("ui: focusprobe: %p holds %s %p", p + i,
                                     (const char *[]){"bounding", "parent", "grandparent", "cursor", "layout"}[fp_kind[lo]], fp_t[lo]);
        }
    }
}
// The class of the object whose vtable pointer is at p (Itanium RTTI: vtable[-1] = typeinfo, typeinfo+8 = name).
static const char *rtti_at(const uint8_t *p) {
    const uint8_t *vt = *(const uint8_t *const *)p;
    if (vt < g_main || vt > g_main + 0x4000000) return NULL;
    const uint8_t *ti = *(const uint8_t *const *)(vt - 8);
    if (ti < g_main || ti > g_main + 0x4000000) return NULL;
    const char *nm = *(const char *const *)(ti + 8);
    if ((const uint8_t *)nm < g_main || (const uint8_t *)nm > g_main + 0x4000000) return NULL;
    for (int i = 0; i < 4; i++) if (nm[i] < '0' || nm[i] > 'z') return NULL;
    return nm;
}
static void fp_classes(const uint8_t *h) {   // vtables in the 0x600 bytes before h: its likely owner objects
    int found = 0;
    for (int o = 0; o <= 0x600 && found < 2; o += 8) {
        const char *nm = rtti_at(h - o);
        if (nm) nx_log("ui: focusprobe:   %p -%#x: %p vt main+%#llx %s", h, o, h - o,
                       (unsigned long long)(*(const uint8_t *const *)(h - o) - g_main), nm), found++;
    }
}
static void focus_probe(int frame) {
    static int f1 = -1, f2;
    if (f1 < 0) {
        const char *e = getenv("NXRT_FOCUSPROBE");
        f1 = 0;
        if (e) sscanf(e, "%d:%d", &f1, &f2);
    }
    if (!f1 || (frame != f1 && frame != f2)) return;
    Scene sc;
    scan(&sc);
    nx_log("ui: focusprobe frame %d: focus %d at %.0f,%.0f  %d buttons, %d prompts", frame, sc.focus,
           (sc.f[0] + sc.f[2]) / 2, (sc.f[1] + sc.f[3]) / 2, sc.nbtn, sc.npr);
    if (frame == f1) {
        const uint8_t *ls[64], *anc[48];
        int n = drawn_layouts(ls, 64);
        for (int i = 0; i < n; i++) fp_collect(*(const uint8_t *const *)(ls[i] + 0x18), 0, anc);
        for (int i = 0; i < n && fp_nt < FP_T; i++) fp_t[fp_nt] = ls[i], fp_kind[fp_nt++] = 4;   // the layouts
        for (int a = 1; a < fp_nt; a++)   // sort targets (with kinds) for the lookup
            for (int b = a; b > 0 && fp_t[b] < fp_t[b - 1]; b--) {
                const uint8_t *t = fp_t[b]; fp_t[b] = fp_t[b - 1], fp_t[b - 1] = t;
                int k = fp_kind[b]; fp_kind[b] = fp_kind[b - 1], fp_kind[b - 1] = k;
            }
        double t0 = now_s();
        nx_guest_heap_each(fp_run, NULL);
        nx_log("ui: focusprobe: %d targets, %d holders, %.0f ms", fp_nt, fp_nh, (now_s() - t0) * 1000);
        for (int i = 0; i < fp_nh; i++) fp_classes(fp_h[i]);
        fp_snap = malloc((size_t)fp_nh * 1024);
        for (int i = 0; i < fp_nh; i++) memcpy(fp_snap[i], fp_h[i] - 512, 1024);
        void nx_watch_set(uint64_t addr);
        const char *w = getenv("NXRT_FOCUSPROBE_WATCH");   // <hex addr>: write-watch it until f2
        if (w) nx_watch_set(strtoull(w, NULL, 16));
    } else if (fp_snap) {
        const char *fe = getenv("NXRT_FOCUSPROBE_FIND");   // <hex>[,<hex>]: who holds these now, and their classes
        char fb[256];
        snprintf(fb, sizeof fb, "%s", fe ? fe : "");
        for (char *t = strtok(fb, ","); t; t = strtok(NULL, ",")) {
            uint64_t v = strtoull(t, NULL, 16);
            fp_t[0] = (const uint8_t *)v, fp_kind[0] = 4, fp_nt = 1, fp_nh = 0;
            const char *c = rtti_at((const uint8_t *)v);
            nx_log("ui: focusprobe find %#llx: class %s", (unsigned long long)v, c ? c : "-");
            nx_guest_heap_each(fp_run, NULL);
            for (int i = 0; i < fp_nh && i < 40; i++) fp_classes(fp_h[i]);
        }
        fp_nh = 0;
        const char *fd = getenv("NXRT_FOCUSPROBE_DUMP");   // <hex>:<len>[,...]: hex dump (8-byte words, classes)
        snprintf(fb, sizeof fb, "%s", fd ? fd : "");
        for (char *t = strtok(fb, ","); t; t = strtok(NULL, ",")) {
            uint64_t a = strtoull(t, NULL, 16) & ~7ull, len = strchr(t, ':') ? strtoull(strchr(t, ':') + 1, NULL, 16) : 0x80;
            for (uint64_t o = 0; o < len; o += 8) {
                uint64_t v = *(const uint64_t *)(a + o);
                const char *c = v >= 0x7000000000 && v < 0x8000000000 ? rtti_at((const uint8_t *)v) : NULL;
                const char *self = rtti_at((const uint8_t *)(a + o));
                nx_log("ui: dump %#llx +%#03llx: %016llx%s%s%s%s", (unsigned long long)a, (unsigned long long)o,
                       (unsigned long long)v, c ? " -> " : "", c ? c : "", self ? " vt " : "", self ? self : "");
            }
        }
        void nx_watch_set(uint64_t addr);
        if (getenv("NXRT_FOCUSPROBE_WATCH")) nx_watch_set(0);
        int logged = 0;
        for (int i = 0; i < fp_nh && logged < 300; i++)
            for (int o = 0; o < 1024; o += 4) {
                uint32_t a = *(const uint32_t *)(fp_snap[i] + o), b = *(const uint32_t *)(fp_h[i] - 512 + o);
                if (a == b) continue;
                if (getenv("NXRT_FOCUSPROBE_SMALL") && (a > 64 || b > 64)) continue;
                nx_log("ui: focusprobe: holder %p %+d: %#x -> %#x", fp_h[i], o - 512, a, b);
                if (++logged >= 300) break;
            }
    }
}

// ---- widescreen (NXRT_WIDE=<width>: render width at 720 high, e.g. 1560 for 19.5:9; the iOS app sets it) ----------
// The engine renders scale * base with scale 2/3 (handheld) and base 1920x1080: base entry 0 is widened to width * 1.5
// at run time (nx_wide_base), the cameras' shared 16/9 constant (main+0x29eb450,
// read-only data: writable in both builds at load) becomes width / 720, and the UI cameras (main+0x46c080 ortho,
// main+0x6ec3c0 perspective; hooked in memory here, at build time by embed.py on iOS) get width * 1.5 for 1920x1080
// layouts. The engine's crop (main+0x46e974, mid-function hook nx_wide_crop) sizes the final picture. The UI then keeps its proportions inside the centre 16:9 area; the 3D view fills the width.
// src/probe_hooks.S: the UI camera stubs' settings and counters
extern struct { float mw, mh, nw, nh; uint64_t ret, calls; float lw, lh; uint64_t ret2, calls2; float lw2, lh2; uint64_t ret3; uint32_t crop_w; float scale;
                uint32_t crop_h; float proj_k; uint64_t persp_vt; float aspect; uint32_t proj_calls, proj_hits; } nx_ui_ortho_cfg;
// The tall picture's projection hook (probe_hooks.S nx_proj_dev) at main+0x2082fc, the tail of
// sead::PerspectiveProjection::doUpdateMatrix: k = the y row factor for projections with the screen aspect.
static void proj_hook(Module *m, float k, float aspect) {
    static const uint32_t o[4] = {0x1e230822, 0x1e220800, 0xbd002c20, 0xd65f03c0};
    if (memcmp(m->base + 0x2082fc, o, 16)) nx_fatal("tall: unexpected projection code at main+0x2082fc");
    nx_ui_ortho_cfg.persp_vt = (uint64_t)(m->base + 0x3279278), nx_ui_ortho_cfg.aspect = aspect, nx_ui_ortho_cfg.proj_k = k;
    extern void nx_proj_dev(void);
    uint32_t code[4] = {0x58000050, 0xD61F0200, 0, 0};   // ldr x16, #8 ; br x16
    uint64_t t = (uint64_t)nx_proj_dev;
    memcpy(&code[2], &t, 8), memcpy(m->base + 0x2082fc, code, 16);
}
// NXRT_MODE=quality | performance (the prelauncher's choice later; env.txt for now): defaults for the settings
// below, each still overridable on its own.
//   quality:     the game's 720p (widescreen width), MetalFX upscale to 1080, 30 fps
//   performance: 540p, MetalFX upscale to 1080, 30 fps (less GPU work per frame: fewer frames over 33 ms)
//   performance60: as performance, up to 60 fps (the game's controller falls back to 30 / 20 when slow). The iPhone 14
//                  encodes 25-40 ms per frame, so it swung between 60, 30 and 20 (128 switches in a session, felt as
//                  drops): not offered until encode is well under 16 ms.
void nx_apply_mode(void) {
    const char *m = getenv("NXRT_MODE");
    if (!m) return;
    if (!strcmp(m, "quality")) setenv("NXRT_UPSCALE", "1080", 0);
    else if (!strcmp(m, "performance")) setenv("NXRT_RENDER_H", "540", 0), setenv("NXRT_UPSCALE", "1080", 0);
    else if (!strcmp(m, "performance60")) setenv("NXRT_RENDER_H", "540", 0), setenv("NXRT_UPSCALE", "1080", 0), setenv("NXRT_FPS", "60", 0);
    else { nx_log("mode: unknown NXRT_MODE=%s (quality, performance, performance60)", m); return; }
    nx_log("mode: %s (render height %s, upscale %s, fps %s)", m, getenv("NXRT_RENDER_H") ? getenv("NXRT_RENDER_H") : "game's",
           getenv("NXRT_UPSCALE") ? getenv("NXRT_UPSCALE") : "off", getenv("NXRT_FPS") ? getenv("NXRT_FPS") : "30");
}
// NXRT_RENDER_H=<height>: the game renders (3D, UI, crop) at that height instead of 720 (handheld) / 1080 (docked);
// the presenter scales the crop to the screen. 0 / unset = the game's own. 360..1080.
int nx_render_h(void) {
    static int h = -1;
    if (h < 0) {
        h = getenv("NXRT_RENDER_H") ? atoi(getenv("NXRT_RENDER_H")) & ~1 : 0;
        if (h && (h < 360 || h > 1080)) h = 0;
        // The crop (scale * 1.5 * picture size) must fit the game's 1920x1080 window textures, or the presenter shows
        // the whole texture: a wider or taller picture caps the scale (1280x800 at 1080: 972, a 1728x1080 crop).
        int cap = 1080 * 1280 / nx_game_width() < 1080 * 720 / nx_game_height() ? 1080 * 1280 / nx_game_width() : 1080 * 720 / nx_game_height();
        if (h > cap) nx_log("render scale: %d high capped to %d (the %dx%d picture must fit 1920x1080 window textures)", h, cap & ~1,
                            nx_game_width(), nx_game_height()), h = cap & ~1;
    }
    return h;
}
// NXRT_TALL=<height>: the picture is taller than 16:9 at 1280 wide (e.g. 800 for a 16:10 Mac screen, 960 for 4:3;
// 720..1080; not together with widescreen). The vertical twin of NXRT_WIDE (see nx_wide_setup).
int nx_game_height(void) {
    static int h = -1;
    if (h < 0) {
        h = getenv("NXRT_TALL") ? atoi(getenv("NXRT_TALL")) & ~1 : 720;
        if (h < 720 || h > 1080 || nx_game_width() != 1280) h = 720;
    }
    return h;
}
int nx_game_width(void) {
    static int w = -1;
    if (w < 0) {
        w = getenv("NXRT_WIDE") ? atoi(getenv("NXRT_WIDE")) & ~1 : 1280;
        if (w < 1280 || w > 2048) w = 1280;
    }
    return w;
}
// The UI camera hooks and the crop hook, in memory (Mac; the iPhone image has them from embed.py).
static void ui_hooks(Module *m) {
    extern void nx_ui_ortho(void), nx_ui_persp(void);
    static const uint32_t o1[4] = {0xd10783ff, 0xfd00c3ec, 0x6d192beb, 0x6d1a23e9}, o2[4] = {0xd107c3ff, 0xfd00cbec, 0xf900e7fc, 0x6d19abeb};
    if (memcmp(m->base + 0x46c080, o1, 16) || memcmp(m->base + 0x6ec3c0, o2, 16)) nx_fatal("widescreen: unexpected UI camera code");
    uint32_t code[4] = {0x58000050, 0xD61F0200, 0, 0};   // ldr x16, #8 ; br x16
    uint64_t t = (uint64_t)nx_ui_ortho;
    memcpy(&code[2], &t, 8), memcpy(m->base + 0x46c080, code, 16);
    t = (uint64_t)nx_ui_persp;
    memcpy(&code[2], &t, 8), memcpy(m->base + 0x6ec3c0, code, 16);
    extern void nx_wide_crop(void);
    static const uint32_t o3[4] = {0x1e380049, 0x1e38002a, 0xf9400108, 0xf9404108};
    if (memcmp(m->base + 0x46e974, o3, 16)) nx_fatal("widescreen: unexpected crop code at main+0x46e974");
    t = (uint64_t)nx_wide_crop;
    memcpy(&code[2], &t, 8), memcpy(m->base + 0x46e974, code, 16);
}
void nx_wide_setup(Module *m, int patch_code) {
    nx_ui_ortho_cfg.ret = (uint64_t)(m->base + 0x46c090);   // always (iOS: the hooks are in the image)
    nx_ui_ortho_cfg.ret2 = (uint64_t)(m->base + 0x6ec3d0);
    nx_ui_ortho_cfg.ret3 = (uint64_t)(m->base + 0x46e984);
    int w = nx_game_width(), rh = nx_render_h();
    if (patch_code && getenv("NXRT_PROJTEST"))   // recon: the y row of screen-aspect projections times <k>
        proj_hook(m, (float)atof(getenv("NXRT_PROJTEST")), (float)w / 720.f), nx_log("tall: projection test, y x %s", getenv("NXRT_PROJTEST"));
    int h = nx_game_height();
    if (rh) {
        nx_ui_ortho_cfg.scale = (float)rh / 1080.f;
        if (w != 1280) nx_ui_ortho_cfg.crop_w = (uint32_t)((w * rh / 720) & ~1);
        if (h != 720) nx_ui_ortho_cfg.crop_h = (uint32_t)((h * rh / 720) & ~1);
        nx_log("render scale: %d high (scale %.4f, crop width %d)", rh, nx_ui_ortho_cfg.scale, w != 1280 ? w * rh / 720 : rh * 16 / 9);
    }
    if (w == 1280 && h == 720 && !rh) return;
    if (h != 720) {   // tall
        // The cameras keep the 16/9 constant (the same horizontal view) and the screen-aspect projection's y row is
        // scaled by 720/h (more world above and below: probe_hooks.S nx_proj_dev); the UI cameras get 1920 x h*1.5 for
        // full-screen layouts; base entries 1920x1080 -> 1920 x h*1.5 (nx_wide_base); the crop height is h.
        nx_ui_ortho_cfg.nh = (float)(h * 3 / 2);
        if (!rh) nx_ui_ortho_cfg.crop_h = (uint32_t)h;
        if (patch_code) proj_hook(m, 720.f / h, 16.f / 9.f), ui_hooks(m);
        nx_log("tall: 1280x%d (projection y x %.4f, UI camera height %d)", h, 720.f / h, h * 3 / 2);
        return;
    }
    if (w == 1280) {   // render scale alone: just the crop hook (the UI camera hooks only matter for widescreen)
        if (patch_code) {
            static const uint32_t o3[4] = {0x1e380049, 0x1e38002a, 0xf9400108, 0xf9404108};
            if (memcmp(m->base + 0x46e974, o3, 16)) nx_fatal("render scale: unexpected crop code at main+0x46e974");
            extern void nx_wide_crop(void);
            uint32_t code[4] = {0x58000050, 0xD61F0200, 0, 0};
            uint64_t t = (uint64_t)nx_wide_crop;
            memcpy(&code[2], &t, 8), memcpy(m->base + 0x46e974, code, 16);
        }
        return;
    }
    float aspect = (float)w / 720.f, old;
    memcpy(&old, m->base + 0x29eb450, 4);
    if (old != 16.f / 9.f) nx_fatal("widescreen: unexpected aspect constant at main+0x29eb450 (%f)", old);
    memcpy(m->base + 0x29eb450, &aspect, 4);
    nx_ui_ortho_cfg.nw = (float)(w * 3 / 2);
    if (!rh) nx_ui_ortho_cfg.crop_w = (uint32_t)w;
    if (patch_code) ui_hooks(m);
    nx_log("widescreen: %dx720 (camera aspect %.4f, UI camera width %d)", w, aspect, w * 3 / 2);
}

// Widescreen recon: the engine's resolution object = *(*(*(main+0x32cf8a8)) + 0xd8) (main+0x46e8dc sets it up:
// handheld scale 720/1080 for both axes). +0x10/+0x14 base size, +0x510/+0x514 render size, +0x518/+0x51c x/y scale.
// NXRT_RESLOG=1 logs it every 300 frames.
static uint8_t *res_obj(void) {
    uint8_t **got = *(uint8_t ***)(g_main + 0x32cf8a8);   // -> a global in main's data (not the guest heap)
    if (!got || ((uintptr_t)got & 7) || !*got || ((uintptr_t)*got & 7)) return NULL;
    uint8_t *o = *(uint8_t **)(*got + 0xd8);
    return o && !((uintptr_t)o & 7) ? o : NULL;
}
// The 8 base entries (+0x10, stride 12; the ctor main+0x86ba4c fills them with 1920x1080) -> width * 1.5. Called as
// early as possible (texture creation, window crop: during boot, before the renderer sizes its targets and viewports)
// and every frame (entry 0 is set to 1920 again during boot).
void nx_wide_base(void) {
    int w = nx_game_width();
    int h = nx_game_height();
    if ((w == 1280 && h == 720) || !g_main) return;
    uint8_t *o = res_obj();
    if (!o) return;
    for (int k = 0x10; k < 0x70; k += 12)
        if (*(int32_t *)(o + k) == 1920 && *(int32_t *)(o + k + 4) == 1080)
            *(int32_t *)(o + k) = w * 3 / 2, *(int32_t *)(o + k + 4) = h * 3 / 2,
            nx_log("widescreen: frame %d: base +%#x %dx%d", g_cur_frame, k, w * 3 / 2, h * 3 / 2);
}
// NXRT_FPS=60 at run time (both builds; the code patches of loader.c / embed.py --fps60 are only needed for the
// first frames): the game's frame-rate controller = *(main+0x39687f0) (reset main+0x16ba640, script setter via the
// GOT slot main+0x32cb138): +0 min present interval, +4 max, +0x44 copy of min. Min 1 every frame: the controller
// picks 60 when a frame fits 16.7 ms and falls back to 30/20 by itself (game step dt = interval / 60 s).
// NXRT_VRR: pace() (gfx_metal.m) chooses each frame's step and writes it here as min = max, so the controller
// (hysteresis patched out, loader.c) sets interval = step for the next frame; fps_tick leaves the controller alone.
void nx_fps_step(int n) {
    uint32_t *ctl = g_main ? *(uint32_t **)(g_main + 0x39687f0) : NULL;
    if (ctl && !((uintptr_t)ctl & 3)) ctl[0] = ctl[1] = ctl[0x44 / 4] = (uint32_t)n;
}
static void fps_tick(int frame) {
    static int on = -1;
    extern int g_vrr;
    if (on < 0) on = getenv("NXRT_FPS") && atoi(getenv("NXRT_FPS")) >= 60 && !g_vrr;
    if (!on || !g_main) return;
    uint32_t *ctl = *(uint32_t **)(g_main + 0x39687f0);
    if (!ctl || ((uintptr_t)ctl & 3)) return;
    if (frame % 600 == 1) nx_log("frame rate: controller %p min %u max %u copy %u (-> min 1)", ctl, ctl[0], ctl[1], ctl[0x44 / 4]);
    if (ctl[0] != 1 || ctl[0x44 / 4] != 1) ctl[0] = 1, ctl[0x44 / 4] = 1;
}
static void res_tick(int frame) {
    static int log = -1, wide = -1;
    fps_tick(frame);
    if (nx_ui_ortho_cfg.proj_k && frame % 300 == 0)
        nx_log("tall: frame %d: device matrices %u, screen-aspect perspective %u (y row x %.3f)", frame, nx_ui_ortho_cfg.proj_calls,
               nx_ui_ortho_cfg.proj_hits, nx_ui_ortho_cfg.proj_k);
    void nx_applet_tick(int frame);
    nx_applet_tick(frame);
    void nx_save_tick(int frame);
    nx_save_tick(frame);
    static int on_title;
    if (!!(nx_ui_flags() & 2) != on_title) on_title = !on_title, nx_log("ui: frame %d: title screen %s", frame, on_title ? "up" : "gone");
    if (log < 0) log = getenv("NXRT_RESLOG") != NULL;
    // NXRT_WIDE=<width>: base entry 0 (+0x10) is set to 1920 during boot (not by the constructor patched in loader.c,
    // which fills the other entries); the renderer sizes its targets as scale * base, so widen it to width * 1.5 (the
    // targets are re-created at the new size on the next frames).
    if (wide < 0) wide = nx_game_width() == 1280 ? 0 : nx_game_width() * 3 / 2;
    uint8_t *o = res_obj();
    if (!o) return;
    nx_wide_base();
    if (getenv("NXRT_NAMEDLOG") && frame >= 1895 && frame <= 1935)
        nx_log("res: frame %d ortho %llu last %gx%g persp %llu last %gx%g", frame, (unsigned long long)nx_ui_ortho_cfg.calls,
               nx_ui_ortho_cfg.lw, nx_ui_ortho_cfg.lh, (unsigned long long)nx_ui_ortho_cfg.calls2, nx_ui_ortho_cfg.lw2, nx_ui_ortho_cfg.lh2);
    if (log && frame % 300 == 0)
        nx_log("res: ui camera hooks: ortho %llu calls (last %gx%g), perspective %llu (last %gx%g)", (unsigned long long)nx_ui_ortho_cfg.calls,
               nx_ui_ortho_cfg.lw, nx_ui_ortho_cfg.lh, (unsigned long long)nx_ui_ortho_cfg.calls2, nx_ui_ortho_cfg.lw2, nx_ui_ortho_cfg.lh2);
    if (log && frame % 300 == 0)
        nx_log("res: obj %p base %dx%d (entry 1 %dx%d) scale %.4f %.4f", o, *(int32_t *)(o + 0x10), *(int32_t *)(o + 0x14),
               *(int32_t *)(o + 0x1c), *(int32_t *)(o + 0x20), *(float *)(o + 0x518), *(float *)(o + 0x51c));
}

// NXRT_FLOATSCAN=<frame>:<hex bits>[:<hex bits 2>] (recon): guest heap words equal to a float (and, if given, a second
// float within 0x40 bytes after it), logged with their neighbourhood.
static uint32_t fs_a, fs_b;
static int fs_n;
static void fs_run(uint8_t *p, size_t n, void *ctx) {
    for (size_t i = 0; i + 4 <= n && fs_n < 64; i += 4) {
        if (*(const uint32_t *)(p + i) != fs_a) continue;
        int k = -1;
        if (fs_b) for (int o = 4; o <= 0x40 && i + o + 4 <= n && k < 0; o += 4) if (*(const uint32_t *)(p + i + o) == fs_b) k = o;
        if (fs_b && k < 0) continue;
        static uintptr_t last;   // one line per 1 MB region (per-draw constant-buffer copies cluster)
        uintptr_t a = (uintptr_t)(p + i);
        if (last && a - last < 0x100000) continue;
        last = a;
        fs_n++;
        const float *f = (const float *)(p + i);
        nx_log("floatscan: %p (+%#x to 2nd): %g %g %g %g | %g %g %g %g | %g %g %g %g | %g %g %g %g", p + i, k, f[0], f[1], f[2],
               f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11], f[12], f[13], f[14], f[15]);
    }
}
// NXRT_VTSCAN=<frame>:<vtable main offset> (recon): heap objects with that vtable; offsets of 1/960 inside the first 0x400.
static uint64_t vs_vt;
static void vs_run(uint8_t *p, size_t n, void *ctx) {
    for (size_t i = 0; i + 8 <= n; i += 8) {
        if (*(const uint64_t *)(p + i) != vs_vt) continue;
        char offs[256] = "";
        int o = 0;
        for (size_t k = 0; k < 0x400 && i + k + 4 <= n; k += 4)
            if (*(const uint32_t *)(p + i + k) == 0x3a888889) o += snprintf(offs + o, sizeof offs - o, " +%#zx", k);
        nx_log("vtscan: %p (main+%#lx)%s", p + i, (long)(p + i - g_main), offs);
    }
}
static void float_scan(int frame) {
    static int vsat = -1;
    if (vsat < 0) {
        vsat = 0;
        unsigned off = 0;
        const char *e = getenv("NXRT_VTSCAN");
        if (e && sscanf(e, "%d:%x", &vsat, &off) == 2) vs_vt = (uint64_t)(g_main + off);
    }
    if (vsat && frame == vsat) {
        nx_guest_heap_each(vs_run, NULL);
        vs_run(g_main + 0x301b000, 0x6925c4 + 0x1beba3c & ~7ul, NULL);   // main's data + bss
        nx_log("vtscan: done (main base %p)", g_main);
    }
    static int at = -1;
    if (at < 0) {
        at = 0;
        const char *e = getenv("NXRT_FLOATSCAN");
        if (e) sscanf(e, "%d:%x:%x", &at, &fs_a, &fs_b);
    }
    if (!at || frame != at) return;
    nx_guest_heap_each(fs_run, NULL);
    nx_log("floatscan: frame %d, %d hits", frame, fs_n);
}

// ---- the game's own button glyphs ------------------------------------------------------------------------------
// The prompts' A/B/X/Y symbols come from a font the game loads itself (nn::font::ScalableFont over its own TrueType
// data), not the system's extended font. NXRT_GLYPHSCAN=1 (recon): scan the guest heap for TrueType data whose cmap
// maps U+E0E1 and log where and when it appears.
static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static void ttf_scan_run(uint8_t *p, size_t n, void *ctx) {
    int *found = ctx;
    for (size_t i = 0; i + 12 + 16 * 40 < n; i += 4) {
        uint32_t m = rd32(p + i);
        if (m != 0x00010000 && m != 0x4f54544f) continue;
        unsigned nt = rd16(p + i + 4);
        if (nt < 6 || nt > 40 || rd16(p + i + 6) == 0) continue;   // searchRange
        // a cmap table record with a sane offset
        for (unsigned k = 0; k < nt; k++) {
            const uint8_t *r = p + i + 12 + 16 * k;
            if (memcmp(r, "cmap", 4)) continue;
            uint32_t off = rd32(r + 8);
            if (off > 64 << 20 || i + off + 4 > n) break;
            nx_log("ui: glyphscan: TrueType at %p (%u tables, %s), cmap at +%#x", p + i, nt, m == 0x00010000 ? "glyf" : "CFF", off);
            if (getenv("NXRT_GLYPHSCAN_DIR")) {   // dump: size = end of the furthest table
                size_t end = 0;
                for (unsigned t = 0; t < nt; t++) {
                    const uint8_t *tr = p + i + 12 + 16 * t;
                    size_t e = (size_t)rd32(tr + 8) + rd32(tr + 12);
                    if (e > end) end = e;
                }
                if (end && i + end <= n) {
                    char path[1024];
                    snprintf(path, sizeof path, "%s/font_%p.otf", getenv("NXRT_GLYPHSCAN_DIR"), p + i);
                    FILE *fo = fopen(path, "wb");
                    if (fo) fwrite(p + i, 1, end, fo), fclose(fo);
                }
            }
            (*found)++;
            break;
        }
    }
}
// The game's own button-symbol font ("NinDev-TCExt", loaded at boot, before any prompt is drawn): its A/B/X/Y glyphs
// are blanked in place like the system's (pl.c), once, as soon as it is in memory. The text keeps the characters
// (prompts are still found by them).
static int g_glyphs_done;
static void ttf_blank_run(uint8_t *p, size_t n, void *ctx) {
    int nx_blank_button_glyphs(uint8_t *f, size_t n);
    for (size_t i = 0; i + 12 + 16 * 40 < n; i += 4) {
        if (rd32(p + i) != 0x00010000) continue;
        unsigned nt = rd16(p + i + 4);
        if (nt < 6 || nt > 40 || !rd16(p + i + 6)) continue;
        size_t end = 0;
        for (unsigned t = 0; t < nt; t++) {
            const uint8_t *tr = p + i + 12 + 16 * t;
            size_t e = (size_t)rd32(tr + 8) + rd32(tr + 12);
            if (e > end) end = e;
        }
        if (!end || end > (8u << 20) || i + end > n) continue;
        int k = nx_blank_button_glyphs(p + i, end);
        if (k > 0) {
            nx_log("ui: button glyphs: %d blanked in the game's font at %p", k, p + i);
            g_glyphs_done = 1;
        }
    }
}
static void glyph_scan(int frame) {
    int found = 0;
    double t0 = now_s();
    void nx_guest_heap_each(void (*fn)(uint8_t *p, size_t n, void *ctx), void *ctx);
    nx_guest_heap_each(ttf_scan_run, &found);
    nx_log("ui: glyphscan: frame %d, %d TrueType candidates, %.0f ms", frame, found, (now_s() - t0) * 1000);
}

// Per frame: NXRT_TAP_AT / NXRT_TOUCH_SCRIPT, the gesture engine, the glyph patch.
void nx_ui_tick(int frame) {
    if (!g_main) return;
    g_cur_frame = frame;
    static int hooked;
    if (!hooked) hooked = 1, layouts_hook(), focus_hook();   // first frame: the game's rtld has relocated the vtables
    static int dumpf = -2;   // NXRT_UIDUMP=<frame>[,<frame>...]: the pane trees of the drawn layouts
    static int dumps[16], ndump;
    if (dumpf == -2) {
        dumpf = 0;
        const char *e = getenv("NXRT_UIDUMP");
        for (char *q = (char *)e; q && *q && ndump < 16; q = strchr(q, ',') ? strchr(q, ',') + 1 : NULL) dumps[ndump++] = atoi(q);
    }
    for (int i = 0; i < ndump; i++)
        if (dumps[i] == frame) ui_dump();
    static int n = -1, at[32][3];
    if (n < 0) {
        n = 0;
        const char *e = getenv("NXRT_TAP_AT");
        char buf[1024];
        snprintf(buf, sizeof buf, "%s", e ? e : "");
        for (char *t = strtok(buf, ","); t && n < 32; t = strtok(NULL, ","))
            if (sscanf(t, "%d:%d:%d", &at[n][0], &at[n][1], &at[n][2]) == 3) n++;
    }
    for (int i = 0; i < n; i++)
        if (at[i][0] == frame) scripted_tap(at[i][1], at[i][2]);
    {   // NXRT_TAP_MII=<frame>: tap the first Mii on screen at least 150 px from the centre (tap-to-centre test)
        static int tm = -2, skip;   // NXRT_TAP_MII=<frame>[:<skip that many Miis first>]
        if (tm == -2) tm = getenv("NXRT_TAP_MII") ? atoi(getenv("NXRT_TAP_MII")) : -1, skip = getenv("NXRT_TAP_MII") && strchr(getenv("NXRT_TAP_MII"), ':') ? atoi(strchr(getenv("NXRT_TAP_MII"), ':') + 1) : 0;
        if (tm == frame) {
            float o[128][2];
            unsigned char v[128];
            int pf = gfx_pick_objects(o, NULL, v, 128), ok = pf >= 0, nv = 0;
            for (int k = 0; ok && k < 128; k++) nv += v[k];
            nx_log("ui: NXRT_TAP_MII: frame %d, positions from frame %d, %d Miis", frame, pf, nv);
            for (int k = 0; ok && k < 128; k++) {
                float x = o[k][0] * nx_game_width(), y = o[k][1] * nx_game_height();
                if (v[k] && x > 40 && x < nx_game_width() - 40 && y > 40 && y < nx_game_height() - 40 &&
                    hypotf(x - nx_game_width() / 2.0f, y - nx_game_height() / 2.0f) > 150 && skip-- <= 0) {
                    nx_log("ui: NXRT_TAP_MII: Mii %d at %.0f,%.0f", k, x, y);
                    scripted_tap((int)x, (int)y);
                    break;
                }
            }
        }
    }
    // NXRT_TOUCH_SCRIPT=<frame>:<d|m|u|b>:<x>:<y>[,...]: finger down / move / up (game px) and the Back button, fed
    // to the gesture engine at those frames (moves between two script points are interpolated per frame).
    static int ns = -1, sf[256], st[256];
    static float sx[256], sy[256];
    if (ns < 0) {
        ns = 0;
        const char *e = getenv("NXRT_TOUCH_SCRIPT");
        char buf[8192], c;
        snprintf(buf, sizeof buf, "%s", e ? e : "");
        for (char *t = strtok(buf, ","); t && ns < 256; t = strtok(NULL, ","))
            if (sscanf(t, "%d:%c:%f:%f", &sf[ns], &c, &sx[ns], &sy[ns]) == 4)
                st[ns++] = c == 'd' ? EV_DOWN : c == 'm' ? EV_MOVE : c == 'u' ? EV_UP : c == 'b' ? EV_BACK
                         : c == 'D' ? 0x10 | EV_DOWN : c == 'M' ? 0x10 | EV_MOVE : c == 'U' ? 0x10 | EV_UP : EV_CANCEL;   // upper case: finger 1
    }
    for (int i = 0; i < ns; i++) {
        int id = st[i] >> 4, ty = st[i] & 15;
        if (sf[i] == frame) nx_ui_touch2(ty, id, sx[i], sy[i]);
        else if (ty == EV_MOVE) {   // in between: interpolate from this finger's previous script point
            int j = i - 1;
            while (j >= 0 && (st[j] >> 4) != id) j--;
            if (j >= 0 && sf[j] < frame && frame < sf[i]) {
                float k = (float)(frame - sf[j]) / (sf[i] - sf[j]);
                nx_ui_touch2(EV_MOVE, id, sx[j] + (sx[i] - sx[j]) * k, sy[j] + (sy[i] - sy[j]) * k);
            }
        }
    }
    engine_tick(frame);
    focus_probe(frame);
    res_tick(frame);
    float_scan(frame);
    {
        int nx_hide_button_glyphs(void);
        void nx_guest_heap_each(void (*fn)(uint8_t *p, size_t n, void *ctx), void *ctx);
        if (!g_glyphs_done && nx_hide_button_glyphs() && frame >= 10 && frame % 60 == 10 && frame < 3000) nx_guest_heap_each(ttf_blank_run, NULL);
    }
    static int gs = -1;
    if (gs < 0) gs = getenv("NXRT_GLYPHSCAN") != NULL;
    if (gs && (frame == 30 || frame == 120 || frame == 300 || frame == 600 || frame == 900)) glyph_scan(frame);
}
