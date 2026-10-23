// Entry probes for guest functions (debugging). The loader replaces a function's first 16 bytes
// with a jump here (NXRT_EXECPROBE). The probe records the call and the executor's early-out inputs
// in a ring without touching
// the guest stack, runs the 4 displaced instructions, and jumps back to entry + 16.
// Probe: main+0x1850f0, the pass executor (displaced: stp x29,x30,[sp,#-0x60]! ; stp x28,x27,[sp,#0x10] ;
// mov x29,sp ; stp x26,x25,[sp,#0x20]).
    .text
    .p2align 2
    .globl _nx_probe_exec
_nx_probe_exec:
    adrp    x16, _nx_probe@PAGE
    add     x16, x16, _nx_probe@PAGEOFF
    mov     x17, #1
    ldadd   x17, x17, [x16]                 // x17 = old index
    and     x17, x17, #4095
    add     x17, x16, x17, lsl #6               // 64-byte entries after a 32-byte header
    stp     x30, x0, [x17, #32]                 // lr, renderer
    str     x2, [x17, #48]                      // request
    ldr     w16, [x2]
    str     w16, [x17, #56]                     // request mask
    ldr     x16, [x2, #0xc0]
    str     x16, [x17, #64]                     // pass
    cbz     x16, 1f
    ldr     w16, [x16, #0x14]
    str     w16, [x17, #72]                     // pass mask
    ldr     x16, [x2, #0xc0]
    ldr     w16, [x16, #0x2c]
    str     w16, [x17, #76]                     // pass +0x2c
1:  ldrb    w16, [x0, #0xb]
    str     w16, [x17, #80]                     // renderer +0xb
    stp     x29, x30, [sp, #-0x60]!
    stp     x28, x27, [sp, #0x10]
    mov     x29, sp
    stp     x26, x25, [sp, #0x20]
    adrp    x16, _nx_probe@PAGE
    add     x16, x16, _nx_probe@PAGEOFF
    ldr     x16, [x16, #8]                  // return address (entry + 16)
    br      x16

// Probe: main+0x177b3c, the parallel view-render job (x0 = render manager R; views at [R+0x380],
// count [R+0x378]). Displaced: stp x29,x30,[sp,#-0x30]! ; str x21,[sp,#0x10] ; stp x20,x19,[sp,#0x20] ; mov x29,sp.
    .p2align 2
    .globl _nx_probe_viewjob
_nx_probe_viewjob:
    adrp    x16, _nx_probe2@PAGE
    add     x16, x16, _nx_probe2@PAGEOFF
    str     x0, [x16, #16]                  // last R
    mov     x17, #1
    ldadd   x17, x17, [x16]                 // call count
    stp     x29, x30, [sp, #-0x30]!
    str     x21, [sp, #0x10]
    stp     x20, x19, [sp, #0x20]
    mov     x29, sp
    ldr     x16, [x16, #8]                  // return address (entry + 16)
    br      x16

// Probe: main+0x183688, a per-view stage function (x0 = graphics object G; [G+0x3b80] = scene renderer
// hook). Displaced: stp x29,x30,[sp,#-0x40]! ; stp x24,x23,[sp,#0x10] ; stp x22,x21,[sp,#0x20] ; stp x20,x19,[sp,#0x30].
    .p2align 2
    .globl _nx_probe_stage
_nx_probe_stage:
    adrp    x16, _nx_probe3@PAGE
    add     x16, x16, _nx_probe3@PAGEOFF
    str     x0, [x16, #16]
    mov     x17, #1
    ldadd   x17, x17, [x16]
    stp     x29, x30, [sp, #-0x40]!
    stp     x24, x23, [sp, #0x10]
    stp     x22, x21, [sp, #0x20]
    stp     x20, x19, [sp, #0x30]
    ldr     x16, [x16, #8]
    br      x16

// Probe: main+0x182ddc, render-stage delegate (x0 = delegate {?, obj +0x8, fn +0x10, adj +0x18},
// x1 = event {stage id, +4 flag}). Records into a 32-byte-entry ring. Displaced: stp x29,x30,[sp,#-0x40]! ;
// str x23,[sp,#0x10] ; stp x22,x21,[sp,#0x20] ; stp x20,x19,[sp,#0x30].
    .p2align 2
    .globl _nx_probe_stagecb
_nx_probe_stagecb:
    adrp    x16, _nx_probe4@PAGE
    add     x16, x16, _nx_probe4@PAGEOFF
    mov     x17, #1
    ldadd   x17, x17, [x16]
    and     x17, x17, #1023
    add     x17, x16, x17, lsl #5
    ldr     x16, [x1]                       // stage id | flag << 32
    str     x16, [x17, #32]
    ldr     x16, [x0, #8]
    str     x16, [x17, #40]                 // obj
    ldr     x16, [x0, #0x10]
    str     x16, [x17, #48]                 // member fn
    ldr     x16, [x0, #0x18]
    str     x16, [x17, #56]                 // adj
    stp     x29, x30, [sp, #-0x40]!
    str     x23, [sp, #0x10]
    stp     x22, x21, [sp, #0x20]
    stp     x20, x19, [sp, #0x30]
    adrp    x16, _nx_probe4@PAGE
    add     x16, x16, _nx_probe4@PAGEOFF
    ldr     x16, [x16, #8]
    br      x16

// Probe: main+0x292894, the scene state machine (x0 = S; stage flag bit 3 = ([S+0x4e8] == 0)).
// Displaced: sub sp,sp,#0x60 ; stp x29,x30,[sp,#0x10] ; stp x26,x25,[sp,#0x20] ; stp x24,x23,[sp,#0x30].
    .p2align 2
    .globl _nx_probe_statem
_nx_probe_statem:
    adrp    x16, _nx_probe5@PAGE
    add     x16, x16, _nx_probe5@PAGEOFF
    str     x0, [x16, #16]
    mov     x17, #1
    ldadd   x17, x17, [x16]
    sub     sp, sp, #0x60
    stp     x29, x30, [sp, #0x10]
    stp     x26, x25, [sp, #0x20]
    stp     x24, x23, [sp, #0x30]
    ldr     x16, [x16, #8]
    br      x16

// Probe: main+0x7ad02c (x0 = T, a timed sequence; clears scene-pending bit 2 when [T+0x24]==0 && [T+0x43]).
// Displaced: sub sp,sp,#0x30 ; stp x29,x30,[sp,#0x10] ; stp x20,x19,[sp,#0x20] ; add x29,sp,#0x10.
    .p2align 2
    .globl _nx_probe_seq
_nx_probe_seq:
    adrp    x16, _nx_probe6@PAGE
    add     x16, x16, _nx_probe6@PAGEOFF
    str     x0, [x16, #16]
    mov     x17, #1
    ldadd   x17, x17, [x16]
    sub     sp, sp, #0x30
    stp     x29, x30, [sp, #0x10]
    stp     x20, x19, [sp, #0x20]
    add     x29, sp, #0x10
    ldr     x16, [x16, #8]
    br      x16

// Probe: main+0xa62a80, boot-sequence state registration (x0 = owner M; state machine at M+0x20,
// states at [M+0x50]). Displaced: stp x29,x30,[sp,#-0x30]! ; str x21,[sp,#0x10] ; stp x20,x19,[sp,#0x20] ; mov x29,sp.
    .p2align 2
    .globl _nx_probe_boot
_nx_probe_boot:
    adrp    x16, _nx_probe7@PAGE
    add     x16, x16, _nx_probe7@PAGEOFF
    str     x0, [x16, #16]
    mov     x17, #1
    ldadd   x17, x17, [x16]
    stp     x29, x30, [sp, #-0x30]!
    str     x21, [sp, #0x10]
    stp     x20, x19, [sp, #0x20]
    mov     x29, sp
    ldr     x16, [x16, #8]
    br      x16

// Probe: main+0x17c43c in the engine's bind function (main+0x17c260): `tbz w9, #1, skip` tests the
// "ready" bit of the mesh's per-frame wrapper slot. NXRT_SKIPPROBE=1 replaces 16 bytes there
// (tbz ; ldr x8,[x19,#0x20] ; ldr x22,[x8,#0xb8] ; mov w8,#1). On the skip path it records the
// slot base x27, variant x21, item x20, renderer x19, the 4 variants' flag bytes, the renderer's
// frame index [x19+0x34], the item's frame bits [x20+0x1d] and [[x20+8]+0x14], and the time.
// Header: calls, skip target (main+0x17c4d4), return (main+0x17c44c), pad; 1024 entries of 64 bytes.
    .p2align 2
    .globl _nx_probe_skip
_nx_probe_skip:
    tbnz    w9, #1, 1f
    adrp    x16, _nx_skipprobe@PAGE
    add     x16, x16, _nx_skipprobe@PAGEOFF
    mov     x17, #1
    ldadd   x17, x17, [x16]
    and     x17, x17, #1023
    add     x17, x16, x17, lsl #6
    stp     x27, x21, [x17, #32]
    stp     x20, x19, [x17, #48]
    ldrb    w16, [x27, #16]
    strb    w16, [x17, #64]
    ldrb    w16, [x27, #32]
    strb    w16, [x17, #65]
    ldrb    w16, [x27, #48]
    strb    w16, [x17, #66]
    ldrb    w16, [x27, #64]
    strb    w16, [x17, #67]
    ldr     w16, [x19, #0x34]
    str     w16, [x17, #68]
    ldrb    w16, [x20, #0x1d]
    strb    w16, [x17, #72]
    ldr     x16, [x20, #8]
    ldrb    w16, [x16, #0x14]
    strb    w16, [x17, #73]
    mrs     x16, cntvct_el0
    str     x16, [x17, #80]
    adrp    x16, _nx_skipprobe@PAGE
    add     x16, x16, _nx_skipprobe@PAGEOFF
    ldr     x16, [x16, #8]
    br      x16
1:  adrp    x16, _nx_skipprobe@PAGE
    add     x16, x16, _nx_skipprobe@PAGEOFF
    add     x16, x16, #24
    mov     x17, #1
    stadd   x17, [x16]                      // header +24: ready-path count
    ldr     x8, [x19, #0x20]
    ldr     x22, [x8, #0xb8]
    mov     w8, #1
    adrp    x16, _nx_skipprobe@PAGE
    add     x16, x16, _nx_skipprobe@PAGEOFF
    ldr     x16, [x16, #16]
    br      x16

// Probe: main+0x40046c in the vertex-bind fallback main+0x400410 (also what bakes a mesh's bind list):
// `ldrb w8, [x25, #0x225] ; cbz w8, skip` skips all vertex binds when the vertex object x25 has no
// valid attributes. NXRT_VOBJPROBE=1 records x25 and the caller (x30) on the skip path; the stats
// re-read [x25+0x225] later (non-zero then = the object was built after the bake: a race).
// Header: calls, skip target (main+0x4004d4), return (main+0x40047c), pass count; 256 entries of 16 bytes.
    .p2align 2
    .globl _nx_probe_vobj
_nx_probe_vobj:
    ldrb    w8, [x25, #0x225]
    cbnz    w8, 1f
    adrp    x16, _nx_vobjprobe@PAGE
    add     x16, x16, _nx_vobjprobe@PAGEOFF
    mov     x17, #1
    ldadd   x17, x17, [x16]
    and     x17, x17, #255
    add     x17, x16, x17, lsl #4
    stp     x25, x30, [x17, #32]
    adrp    x16, _nx_vobjprobe@PAGE
    add     x16, x16, _nx_vobjprobe@PAGEOFF
    ldr     x16, [x16, #8]
    br      x16
1:  add     x21, x19, #0x8
    add     x1, x25, #0x180
    adrp    x16, _nx_vobjprobe@PAGE
    add     x16, x16, _nx_vobjprobe@PAGEOFF
    add     x17, x16, #24
    mov     x16, #1
    stadd   x16, [x17]
    adrp    x16, _nx_vobjprobe@PAGE
    add     x16, x16, _nx_vobjprobe@PAGEOFF
    ldr     x16, [x16, #16]
    br      x16

// NXRT_PASSPROBE=1: outcome probes inside the pass executor.
// main+0x1854ac: pass-cache miss path (the pass has no cached list set this frame). Counts, then runs
// the displaced ldr x8,[x21,#0x580] ; add x20,x21,#0x580 ; mov x0,x20 ; ldr x8,[x8,#0x10].
// _nx_passprobe: {miss, calls, lists, baked, partial, ret_miss, ret_go, ret_skip}
    .p2align 2
    .globl _nx_probe_passmiss
_nx_probe_passmiss:
    adrp    x16, _nx_passprobe@PAGE
    add     x16, x16, _nx_passprobe@PAGEOFF
    mov     x17, #1
    stadd   x17, [x16]
    ldr     x8, [x21, #0x580]
    add     x20, x21, #0x580
    mov     x0, x20
    ldr     x8, [x8, #0x10]
    ldr     x16, [x16, #40]
    br      x16
// main+0x18531c: lists in the pass = x19 + 1, baked (bit 0 of +0x58) = w21. Replaces
// cmp w21,#0 ; b.le 0x185398 ; ldr x20,[x25,#0xb8] ; mov w8,#1.
    .p2align 2
    .globl _nx_probe_passbaked
_nx_probe_passbaked:
    adrp    x16, _nx_passprobe@PAGE
    add     x16, x16, _nx_passprobe@PAGEOFF
    add     x16, x16, #8
    mov     x17, #1
    stadd   x17, [x16]                      // [1] passes
    add     x16, x16, #8
    add     x17, x19, #1
    and     x17, x17, #0xffffffff
    stadd   x17, [x16]                      // [2] lists
    add     x16, x16, #8
    sxtw    x17, w21
    stadd   x17, [x16]                      // [3] baked
    add     x16, x16, #8
    add     x17, x19, #1
    cmp     w21, w17
    b.ge    1f
    mov     x17, #1
    stadd   x17, [x16]                      // [4] passes with unbaked lists
1:  adrp    x16, _nx_passprobe@PAGE
    add     x16, x16, _nx_passprobe@PAGEOFF
    cmp     w21, #0
    b.le    2f
    ldr     x20, [x25, #0xb8]
    mov     w8, #1
    ldr     x16, [x16, #48]
    br      x16
2:  ldr     x16, [x16, #56]
    br      x16

// NXRT_RACEPROBE=1: timestamped ring of pass executor reads and collector appends.
// _nx_racering: {idx, ret_exec, ret_app_go, ret_app_skip} then 65536 x {ptr, n, ts, type}.
// main+0x18521c: the executor found the pass entry; runs mov w8,#0xe0 ; madd x8,x26,x8,x10 ;
// ldr w9,[x8,#0xc8]! ; cmp w9,#1, records (entry, count), returns to 0x18522c (b.lt uses the flags).
    .p2align 2
    .globl _nx_probe_raceexec
_nx_probe_raceexec:
    mov     w8, #0xe0
    madd    x8, x26, x8, x10
    ldr     w9, [x8, #0xc8]!
    adrp    x16, _nx_racering@PAGE
    add     x16, x16, _nx_racering@PAGEOFF
    mov     x17, #1
    ldadd   x17, x17, [x16]
    and     x17, x17, #0xffff
    add     x17, x16, x17, lsl #5
    add     x17, x17, #32
    str     x8, [x17]
    str     x9, [x17, #8]
    mrs     x16, cntvct_el0
    str     x16, [x17, #16]
    mov     x16, #1
    str     x16, [x17, #24]
    cmp     w9, #1
    adrp    x16, _nx_racering@PAGE
    add     x16, x16, _nx_racering@PAGEOFF
    ldr     x16, [x16, #8]
    br      x16
// main+0x17a0b4: a list was appended to collector x12 at index w8. Runs ldr w9,[x12,#0xcc] ;
// cmp w9,w8 ; b.le 0x17a0cc ; ldr x9,[x12,#0xd0], then 0x17a0c4.
    .p2align 2
    .globl _nx_probe_raceapp
_nx_probe_raceapp:
    adrp    x16, _nx_racering@PAGE
    add     x16, x16, _nx_racering@PAGEOFF
    mov     x17, #1
    ldadd   x17, x17, [x16]
    and     x17, x17, #0xffff
    add     x17, x16, x17, lsl #5
    add     x17, x17, #32
    add     x16, x12, #0xc8
    str     x16, [x17]
    str     x8, [x17, #8]
    mrs     x16, cntvct_el0
    str     x16, [x17, #16]
    mov     x16, #2
    str     x16, [x17, #24]
    adrp    x16, _nx_racering@PAGE
    add     x16, x16, _nx_racering@PAGEOFF
    ldr     w9, [x12, #0xcc]
    cmp     w9, w8
    b.le    1f
    ldr     x9, [x12, #0xd0]
    ldr     x16, [x16, #16]
    br      x16
1:  ldr     x16, [x16, #24]
    br      x16
// main+0x178b00 (NXRT_RACEPROBE): chunk function entry, x0 = pass, x5 = {start, count} range.
// Ring entry: ptr = pass, n = start << 32 | count, ts, type = 3 | pass count (+0x2c) << 8.
// Displaced: stp x29,x30,[sp,#-0x60]! ; stp x28,x27,[sp,#0x10] ; mov x29,sp ; stp x26,x25,[sp,#0x20].
    .p2align 2
    .globl _nx_probe_racechunk
_nx_probe_racechunk:
    stp     x8, x9, [sp, #-16]!
    adrp    x16, _nx_racering@PAGE
    add     x16, x16, _nx_racering@PAGEOFF
    mov     x17, #1
    ldadd   x17, x17, [x16]
    and     x17, x17, #0xffff
    add     x17, x16, x17, lsl #5
    add     x17, x17, #32
    str     x0, [x17]
    ldr     w8, [x5]
    ldr     w9, [x5, #4]
    orr     x8, x9, x8, lsl #32
    str     x8, [x17, #8]
    mrs     x8, cntvct_el0
    str     x8, [x17, #16]
    ldr     w8, [x0, #0x2c]
    lsl     x8, x8, #8
    orr     x8, x8, #3
    str     x8, [x17, #24]
    ldp     x8, x9, [sp], #16
    stp     x29, x30, [sp, #-0x60]!
    stp     x28, x27, [sp, #0x10]
    mov     x29, sp
    stp     x26, x25, [sp, #0x20]
    adrp    x16, _nx_chunkret@PAGE
    add     x16, x16, _nx_chunkret@PAGEOFF
    ldr     x16, [x16]
    br      x16

// NXRT_OBJPROBE=1: why the scene-list chunk loop skips objects. _nx_objprobe counters:
// [0] objects visited, [1] mask skips, [2] LOD skips, [3] not-ready skips (main+0x17c260 false).
// _nx_objret: {skip 0x17a260, a 0x17a2cc, b 0x17a334, c 0x17a35c}.
.macro OBJCOUNT idx
    adrp    x16, _nx_objprobe@PAGE
    add     x16, x16, _nx_objprobe@PAGEOFF
    add     x16, x16, #(\idx * 8)
    mov     x17, #1
    stadd   x17, [x16]
    mrs     x16, tpidrro_el0
    lsr     x16, x16, #23
    and     x16, x16, #63
    adrp    x17, _nx_objthr@PAGE
    add     x17, x17, _nx_objthr@PAGEOFF
    add     x17, x17, x16, lsl #6
    add     x17, x17, #(\idx * 8)
    ldr     x16, [x17]
    add     x16, x16, #1
    str     x16, [x17]
.endm
// main+0x17a2bc: tst w10,w8 ; b.eq skip ; ldrh w8,[x21,#0xe] ; ubfx w9,w8,#4,#1
    .p2align 2
    .globl _nx_probe_obja
_nx_probe_obja:
    OBJCOUNT 0
    tst     w10, w8
    b.eq    1f
    ldrh    w8, [x21, #0xe]
    ubfx    w9, w8, #4, #1
    adrp    x16, _nx_objret@PAGE
    add     x16, x16, _nx_objret@PAGEOFF
    ldr     x16, [x16, #8]
    br      x16
1:  OBJCOUNT 1
    adrp    x16, _nx_objprobe@PAGE
    add     x16, x16, _nx_objprobe@PAGEOFF
    str     x21, [x16, #40]                 // [5] last masked-out object
    str     w8, [x16, #48]                  // [6] pass mask it was tested against
    adrp    x16, _nx_objret@PAGE
    add     x16, x16, _nx_objret@PAGEOFF
    ldr     x16, [x16]
    br      x16
// main+0x17a324: ldrh w8,[x10,#0x1c] ; ubfx w8,w8,#4,#3 ; cmp w8,w20 ; b.ls skip
    .p2align 2
    .globl _nx_probe_objb
_nx_probe_objb:
    ldrh    w8, [x10, #0x1c]
    ubfx    w8, w8, #4, #3
    cmp     w8, w20
    b.ls    1f
    adrp    x16, _nx_objret@PAGE
    add     x16, x16, _nx_objret@PAGEOFF
    ldr     x16, [x16, #16]
    br      x16
1:  OBJCOUNT 2
    adrp    x16, _nx_objret@PAGE
    add     x16, x16, _nx_objret@PAGEOFF
    ldr     x16, [x16]
    br      x16
// main+0x17a34c: tbz w0,#0,skip ; ldrb w8,[x21,#0x49] ; ldr w9,[sp,#0x78] ; tst w9,w8
    .p2align 2
    .globl _nx_probe_objc
_nx_probe_objc:
    tbz     w0, #0, 1f
    ldrb    w8, [x21, #0x49]
    ldr     w9, [sp, #0x78]
    tst     w9, w8
    adrp    x16, _nx_objret@PAGE
    add     x16, x16, _nx_objret@PAGEOFF
    ldr     x16, [x16, #24]
    br      x16
1:  OBJCOUNT 3
    adrp    x16, _nx_objret@PAGE
    add     x16, x16, _nx_objret@PAGEOFF
    ldr     x16, [x16]
    br      x16

// main+0x178b00 (NXRT_OBJPROBE): chunk entry, zero this thread's row (owner = tpidrro_el0).
    .p2align 2
    .globl _nx_probe_objentry
_nx_probe_objentry:
    mrs     x16, tpidrro_el0
    lsr     x16, x16, #23
    and     x16, x16, #63
    adrp    x17, _nx_objthr@PAGE
    add     x17, x17, _nx_objthr@PAGEOFF
    add     x17, x17, x16, lsl #6
    stp     xzr, xzr, [x17]
    stp     xzr, xzr, [x17, #16]
    mrs     x16, tpidrro_el0
    str     x16, [x17, #32]
    stp     x29, x30, [sp, #-0x60]!
    stp     x28, x27, [sp, #0x10]
    mov     x29, sp
    stp     x26, x25, [sp, #0x20]
    adrp    x16, _nx_chunkret@PAGE
    add     x16, x16, _nx_chunkret@PAGEOFF
    ldr     x16, [x16]
    br      x16

// General C probe: save x0-x15, x18, x30, NZCV and q0-q31 on the guest stack, call
// nx_cprobe(regs, id), restore, run the displaced code and return. x16/x17 are already used by the
// patch (ldr x16 ; br x16), so the hooked spots must not have them live.
.macro CPROBE_SAVE id
    sub     sp, sp, #0x300
    stp     x0, x1, [sp, #0x00]
    stp     x2, x3, [sp, #0x10]
    stp     x4, x5, [sp, #0x20]
    stp     x6, x7, [sp, #0x30]
    stp     x8, x9, [sp, #0x40]
    stp     x10, x11, [sp, #0x50]
    stp     x12, x13, [sp, #0x60]
    stp     x14, x15, [sp, #0x70]
    stp     x18, x30, [sp, #0x80]
    stp     x19, x20, [sp, #0x90]
    stp     x21, x22, [sp, #0xa0]
    stp     x23, x24, [sp, #0xb0]
    stp     x25, x26, [sp, #0xc0]
    stp     x27, x28, [sp, #0xd0]
    stp     x29, xzr, [sp, #0xe0]
    mrs     x0, nzcv
    str     x0, [sp, #0xf0]
    stp     q0, q1, [sp, #0x100]
    stp     q2, q3, [sp, #0x120]
    stp     q4, q5, [sp, #0x140]
    stp     q6, q7, [sp, #0x160]
    stp     q16, q17, [sp, #0x180]
    stp     q18, q19, [sp, #0x1a0]
    stp     q20, q21, [sp, #0x1c0]
    stp     q22, q23, [sp, #0x1e0]
    stp     q24, q25, [sp, #0x200]
    stp     q26, q27, [sp, #0x220]
    stp     q28, q29, [sp, #0x240]
    stp     q30, q31, [sp, #0x260]
    mov     x0, sp
    mov     w1, #\id
    bl      _nx_cprobe
    ldp     q0, q1, [sp, #0x100]
    ldp     q2, q3, [sp, #0x120]
    ldp     q4, q5, [sp, #0x140]
    ldp     q6, q7, [sp, #0x160]
    ldp     q16, q17, [sp, #0x180]
    ldp     q18, q19, [sp, #0x1a0]
    ldp     q20, q21, [sp, #0x1c0]
    ldp     q22, q23, [sp, #0x1e0]
    ldp     q24, q25, [sp, #0x200]
    ldp     q26, q27, [sp, #0x220]
    ldp     q28, q29, [sp, #0x240]
    ldp     q30, q31, [sp, #0x260]
    ldr     x0, [sp, #0xf0]
    msr     nzcv, x0
    ldp     x0, x1, [sp, #0x00]
    ldp     x2, x3, [sp, #0x10]
    ldp     x4, x5, [sp, #0x20]
    ldp     x6, x7, [sp, #0x30]
    ldp     x8, x9, [sp, #0x40]
    ldp     x10, x11, [sp, #0x50]
    ldp     x12, x13, [sp, #0x60]
    ldp     x14, x15, [sp, #0x70]
    ldp     x18, x30, [sp, #0x80]
    add     sp, sp, #0x300
.endm

// NXRT_CHUNKPROBE: id 1 = chunk entry main+0x178b00 (x0 pass, x3 key, x5 range),
// id 2 = per object main+0x17a2bc before the mask test (x21 object, w8 pass mask, w10 object mask).
    .p2align 2
    .globl _nx_cp_chunk
_nx_cp_chunk:
    CPROBE_SAVE 1
    stp     x29, x30, [sp, #-0x60]!
    stp     x28, x27, [sp, #0x10]
    mov     x29, sp
    stp     x26, x25, [sp, #0x20]
    adrp    x16, _nx_cpret@PAGE
    add     x16, x16, _nx_cpret@PAGEOFF
    ldr     x16, [x16]
    br      x16
    .p2align 2
    .globl _nx_cp_obj
_nx_cp_obj:
    CPROBE_SAVE 2
    tst     w10, w8
    b.eq    1f
    ldrh    w8, [x21, #0xe]
    ubfx    w9, w8, #4, #1
    adrp    x16, _nx_cpret@PAGE
    add     x16, x16, _nx_cpret@PAGEOFF
    ldr     x16, [x16, #16]
    br      x16
1:  adrp    x16, _nx_cpret@PAGE
    add     x16, x16, _nx_cpret@PAGEOFF
    ldr     x16, [x16, #8]
    br      x16
// NXRT_CHUNKPROBE: id 3 = LOD test main+0x17a324 (x10 mesh set, w20 LOD), id 4 = ready test main+0x17a34c (w0).
    .p2align 2
    .globl _nx_cp_lod
_nx_cp_lod:
    CPROBE_SAVE 3
    ldrh    w8, [x10, #0x1c]
    ubfx    w8, w8, #4, #3
    cmp     w8, w20
    b.ls    1f
    adrp    x16, _nx_cpret@PAGE
    add     x16, x16, _nx_cpret@PAGEOFF
    ldr     x16, [x16, #24]
    br      x16
1:  adrp    x16, _nx_cpret@PAGE
    add     x16, x16, _nx_cpret@PAGEOFF
    ldr     x16, [x16, #8]
    br      x16
    .p2align 2
    .globl _nx_cp_ready
_nx_cp_ready:
    CPROBE_SAVE 4
    tbz     w0, #0, 1f
    ldrb    w8, [x21, #0x49]
    ldr     w9, [sp, #0x78]
    tst     w9, w8
    adrp    x16, _nx_cpret@PAGE
    add     x16, x16, _nx_cpret@PAGEOFF
    ldr     x16, [x16, #32]
    br      x16
1:  adrp    x16, _nx_cpret@PAGE
    add     x16, x16, _nx_cpret@PAGEOFF
    ldr     x16, [x16, #8]
    br      x16

// NXRT_TICKPROBE=<frame>: replaces main's PLT stub for nn::os::GetSystemTick (main+0x25cb8c0). Records the
// caller's return address in a ring, then jumps through the stub's GOT slot (rtld fills it after we patch).
// _nx_tickring: {idx, GOT slot address} then 65536 return addresses.
    .p2align 2
    .globl _nx_probe_tick
_nx_probe_tick:
    adrp    x16, _nx_tickring@PAGE
    add     x16, x16, _nx_tickring@PAGEOFF
    mov     x17, #1
    ldadd   x17, x17, [x16]
    and     x17, x17, #0xffff
    add     x17, x16, x17, lsl #3
    str     x30, [x17, #16]
    ldr     x16, [x16, #8]                  // like the stub: x16 = GOT slot (the lazy resolver reads it)
    ldr     x17, [x16]
    br      x17
    .data
    .p2align 4
    .globl _nx_tickring
_nx_tickring:
    .space  8 * (2 + 65536)
    .text

// Widescreen UI camera (NXRT_WIDE): main+0x46c080(DrawInfo *x0, float w s0, float h s1) builds the UI projection
// ortho(-w/2, w/2, -h/2, h/2, 0, 300). Full-screen layouts pass 1920 x 1080; their width becomes the wide layout width
// (nx_ui_ortho_cfg: match w, match h, new w, pad, return address = entry + 16). Other sizes (render-to-texture panes)
// pass through. Displaced: sub sp,sp,#0x1e0 ; str d12,[sp,#0x180] ; stp d11,d10,[sp,#0x190] ; stp d9,d8,[sp,#0x1a0].
    .p2align 2
    .globl _nx_ui_ortho
_nx_ui_ortho:
    adrp    x16, _nx_ui_ortho_cfg@PAGE
    add     x16, x16, _nx_ui_ortho_cfg@PAGEOFF
    ldr     x17, [x16, #24]                 // calls (recon)
    add     x17, x17, #1
    str     x17, [x16, #24]
    stp     s0, s1, [x16, #32]              // last size (recon)
    ldr     s16, [x16]
    fcmp    s0, s16
    b.ne    1f
    ldr     s16, [x16, #4]
    fcmp    s1, s16
    b.ne    1f
    ldr     s0, [x16, #8]
    ldr     s16, [x16, #12]                 // tall: the new height (0 = unchanged)
    fcmp    s16, #0.0
    b.eq    1f
    fmov    s1, s16
1:  sub     sp, sp, #0x1e0
    str     d12, [sp, #0x180]
    stp     d11, d10, [sp, #0x190]
    stp     d9, d8, [sp, #0x1a0]
    ldr     x16, [x16, #16]
    br      x16

// The perspective UI camera main+0x6ec3c0(DrawInfo *x0, w s0, h s1, fov s2): full-screen layouts (aspect w/h). Same
// width swap; displaced: sub sp,sp,#0x1f0 ; str d12,[sp,#0x190] ; str x28,[sp,#0x1c8] ; stp d11,d10,[sp,#0x198].
    .p2align 2
    .globl _nx_ui_persp
_nx_ui_persp:
    adrp    x16, _nx_ui_ortho_cfg@PAGE
    add     x16, x16, _nx_ui_ortho_cfg@PAGEOFF
    ldr     x17, [x16, #48]                 // calls (recon)
    add     x17, x17, #1
    str     x17, [x16, #48]
    stp     s0, s1, [x16, #56]              // last size (recon)
    ldr     s16, [x16]
    fcmp    s0, s16
    b.ne    1f
    ldr     s16, [x16, #4]
    fcmp    s1, s16
    b.ne    1f
    ldr     s0, [x16, #8]
    ldr     s16, [x16, #12]                 // tall: the new height (0 = unchanged)
    fcmp    s16, #0.0
    b.eq    1f
    fmov    s1, s16
1:  sub     sp, sp, #0x1f0
    str     d12, [sp, #0x190]
    str     x28, [sp, #0x1c8]
    stp     d11, d10, [sp, #0x198]
    ldr     x16, [x16, #40]
    br      x16

// Widescreen crop: main+0x46e8dc applies the resolution every frame and stores the window crop (scale*1920 x
// scale*1080) in the display object (+0xb4), which also sizes the final picture. Mid-function hook at main+0x46e974
// (x16/x17 unused in that function, flags dead): handheld width 1280 -> the wide width. Displaced: fcvtzs w9,s2 ;
// fcvtzs w10,s1 ; ldr x8,[x8] ; ldr x8,[x8,#0x80]; back to main+0x46e984.
// Render scale (NXRT_RENDER_H, cfg +76 = scale bits, 0 = the game's): scale = height/1080 replaces the game's
// (docked 1, handheld 2/3) in the resolution object (x20 = its GOT slot: obj = *(*x20) + 0xd8, +0x518/+0x51c) and
// in the crop (s0 scale, s1 = scale*1080, s2 = scale*1920; s0-s2 are reloaded before their next use). With
// widescreen, cfg +72 is the scaled crop width. Render targets follow on the next frames (scale * base).
    .p2align 2
    .globl _nx_wide_crop
_nx_wide_crop:
    adrp    x16, _nx_ui_ortho_cfg@PAGE
    add     x16, x16, _nx_ui_ortho_cfg@PAGEOFF
    ldr     w17, [x16, #76]
    cbz     w17, 2f
    fmov    s0, w17
    movz    w17, #0x44f0, lsl #16
    fmov    s2, w17
    fmul    s2, s0, s2
    movz    w17, #0x4487, lsl #16
    fmov    s1, w17
    fmul    s1, s0, s1
    ldr     x17, [x20]
    ldr     x17, [x17, #0xd8]
    str     s0, [x17, #0x518]
    str     s0, [x17, #0x51c]
    fcvtzs  w9, s2
    fcvtzs  w10, s1
    ldr     w17, [x16, #72]
    cbz     w17, 1f
    mov     w9, w17
    b       1f
2:  fcvtzs  w9, s2
    fcvtzs  w10, s1
    ldr     w17, [x16, #72]
    cbz     w17, 1f
    cmp     w9, #0x500
    b.ne    1f
    mov     w9, w17
1:  ldr     w17, [x16, #80]                 // tall: crop height
    cbz     w17, 3f
    mov     w10, w17
3:  ldr     x8, [x8]
    ldr     x8, [x8, #0x80]
    ldr     x16, [x16, #64]
    br      x16

    .data
    .p2align 3
    .globl _nx_ui_ortho_cfg
_nx_ui_ortho_cfg:
    .float 1920.0, 1080.0, 1920.0, 0.0      // match w, match h, new w, new h (0 = unchanged)
    .quad 0, 0
    .float 0.0, 0.0
    .quad 0, 0
    .float 0.0, 0.0
    .quad 0                                 // +64 crop hook return address
    .word 0, 0                              // +72 crop width (0 = unchanged), +76 render scale bits (0 = the game's)
    .word 0                                 // +80 crop height (0 = unchanged; tall)
    .float 0.0                              // +84 projection y factor (0 = off; tall: 720 / height)
    .quad 0                                 // +88 sead::PerspectiveProjection vtable
    .float 0.0                              // +96 the screen aspect (the cameras' constant)
    .word 0, 0                              // +100 calls, +104 perspective matches (recon)

    .text
// Tall picture (taller than 16:9): sead::PerspectiveProjection::doUpdateMatrix main+0x208240(this x0, Matrix44 *dst x1)
// builds the projection from near +0x98, tan(fovy/2) +0xac, aspect +0xb0, offset +0xb4 (vtable slot 11; the game never
// uses the device-matrix path). Its tail (main+0x2082fc, the last 3 instructions + ret) jumps here: the displaced z-row
// store, then for a projection with the screen aspect (the cameras' shared constant) the y row (dst +0x10) times the
// factor: the same horizontal view, more of the world above and below (the cameras keep their vertical field of view,
// so a taller target alone would only crop the sides). Displaced: fmul s2,s1,s3 ; fmul s0,s0,s2 ; str s0,[x1,#0x2c].
    .p2align 2
    .globl _nx_proj_dev
_nx_proj_dev:
    fmul    s2, s1, s3
    fmul    s0, s0, s2
    str     s0, [x1, #0x2c]
    adrp    x16, _nx_ui_ortho_cfg@PAGE
    add     x16, x16, _nx_ui_ortho_cfg@PAGEOFF
    ldr     w9, [x16, #100]                 // calls (recon)
    add     w9, w9, #1
    str     w9, [x16, #100]
    ldr     s16, [x16, #84]
    fcmp    s16, #0.0
    b.eq    9f
    ldr     s17, [x0, #0xb0]
    ldr     s18, [x16, #96]
    fcmp    s17, s18
    b.ne    9f
    ldr     w9, [x16, #104]                 // screen-aspect matches (recon)
    add     w9, w9, #1
    str     w9, [x16, #104]
    ldr     q17, [x1, #0x10]
    fmul    v17.4s, v17.4s, v16.s[0]
    str     q17, [x1, #0x10]
9:  ret

// Probe: main+0x1d7bf78, the game's save request (x0 = save manager, x2 = completion callback, w3 = async flag;
// NXRT_SAVEPROBE, research for the shared island's automatic save). Calls nx_saveprobe_hit(x0, x1, x2, x3, lr, fp)
// with x0-x7 preserved, then the displaced stp x29,x30,[sp,#-0x50]! ; stp x28,x25,[sp,#0x10] ; mov x29,sp ;
// stp x24,x23,[sp,#0x20].
    .p2align 2
    .globl _nx_probe_saverq
_nx_probe_saverq:
    sub     sp, sp, #0x60
    stp     x0, x1, [sp]
    stp     x2, x3, [sp, #0x10]
    stp     x4, x5, [sp, #0x20]
    stp     x6, x7, [sp, #0x30]
    stp     x29, x30, [sp, #0x40]
    mov     x4, x30
    mov     x5, x29
    bl      _nx_saveprobe_hit
    ldp     x0, x1, [sp]
    ldp     x2, x3, [sp, #0x10]
    ldp     x4, x5, [sp, #0x20]
    ldp     x6, x7, [sp, #0x30]
    ldp     x29, x30, [sp, #0x40]
    add     sp, sp, #0x60
    stp     x29, x30, [sp, #-0x50]!
    stp     x28, x25, [sp, #0x10]
    mov     x29, sp
    stp     x24, x23, [sp, #0x20]
    adrp    x16, _nx_probe_saverq_ret@PAGE
    ldr     x16, [x16, _nx_probe_saverq_ret@PAGEOFF]
    br      x16
