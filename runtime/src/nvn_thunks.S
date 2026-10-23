// Host-call thunks for NVN: the game calls these with the AAPCS64 arguments in x0-x7 /
// v0-v7. Each thunk switches from the (possibly small, guard-less) guest stack to this
// thread's host stack, calls the real function from nx_nvn_targets[i], and switches back.
// The NVN area sits 256 KiB below host_stack_top so SVCs made from guest callbacks during
// an NVN call (svc_entry starts at the top) cannot overwrite it.
    .text
    .p2align 2
    .globl _nx_nvn_thunk_common
_nx_nvn_thunk_common:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    stp     x19, x20, [sp, #-16]!
    mov     x19, sp                         // guest sp, restored on return
    mov     x20, x16                        // proc index
    adrp    x9, _nx_tsd_key_off@PAGE
    ldr     x9, [x9, _nx_tsd_key_off@PAGEOFF]
    mrs     x10, tpidrro_el0
    and     x10, x10, #0xfffffffffffffff8
    ldr     x10, [x10, x9]                  // GuestThread*
    cbz     x10, 1f                         // not a guest thread: stay on this stack
    ldr     x11, [x10, #0x10]               // host_stack_top
    sub     x11, x11, #0x40000
    // already on the host stack (nested call)? then keep going where we are
    cmp     x19, x11
    b.ls    2f
    sub     x12, x11, #0x40000
    cmp     x19, x12
    b.hi    2f
    mov     sp, x11
    b       1f
2:  nop
1:  adrp    x9, _nx_nvn_calls@PAGE                // per-proc call counter (NXRT_NVNSTATS)
    add     x9, x9, _nx_nvn_calls@PAGEOFF
    add     x9, x9, x20, lsl #3
    mov     x10, #1
    ldadd   x10, xzr, [x9]
    adrp    x9, _nx_nvn_targets@PAGE
    add     x9, x9, _nx_nvn_targets@PAGEOFF
    ldr     x16, [x9, x20, lsl #3]
    blr     x16
    mov     sp, x19
    ldp     x19, x20, [sp], #16
    ldp     x29, x30, [sp], #16
    ret

    .p2align 2
    .globl _nx_nvn_thunks
_nx_nvn_thunks:
    .set    i, 0
    .rept   1100
    mov     x16, #i
    b       _nx_nvn_thunk_common
    .set    i, i + 1
    .endr
