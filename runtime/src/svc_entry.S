// SVC entry from a guest trampoline (spill.py svc_trampoline):
//   stp x16, x30, [sp, #-16]! ; mov x16, #N ; blr <nx_svc_entry> ; ldp x16, x30, [sp], #16
// On entry: x16 = SVC number, [sp] = guest x16, x30 = return into the trampoline.
// Saves the guest's x0-x17 in a frame on the guest stack, switches to this thread's host
// stack, calls nx_svc_dispatch(num, regs) and restores everything (handlers write outputs
// into regs[]). Like the Horizon kernel, every register except the outputs is preserved.
    .text
    .p2align 2
    .globl _nx_svc_entry
_nx_svc_entry:
    sub     sp, sp, #0xC0
    stp     x0, x1, [sp, #0x00]
    stp     x2, x3, [sp, #0x10]
    stp     x4, x5, [sp, #0x20]
    stp     x6, x7, [sp, #0x30]
    stp     x8, x9, [sp, #0x40]
    stp     x10, x11, [sp, #0x50]
    stp     x12, x13, [sp, #0x60]
    stp     x14, x15, [sp, #0x70]
    ldr     x9, [sp, #0xC0]             // guest x16 (pushed by the trampoline)
    stp     x9, x17, [sp, #0x80]
    stp     x19, x29, [sp, #0x90]
    stp     x30, x16, [sp, #0xA0]       // return address, SVC number
    mov     x19, sp
    bl      _nx_host_stack_top          // tiny C helper, still on the guest stack
    mov     sp, x0
    ldr     x9, [x19, #0xA0]            // the guest's return address (x30 now points into this function)
    stp     x29, x9, [sp, #-16]!        // frame record linking the host stack back to the guest's chain
    mov     x29, sp                     // (backtraces from inside an SVC reach the guest caller)
    ldr     x0, [x19, #0xA8]
    mov     x1, x19
    bl      _nx_svc_dispatch
    mov     sp, x19
    ldp     x16, x17, [sp, #0x80]
    ldp     x19, x29, [sp, #0x90]
    ldr     x30, [sp, #0xA0]
    ldp     x14, x15, [sp, #0x70]
    ldp     x12, x13, [sp, #0x60]
    ldp     x10, x11, [sp, #0x50]
    ldp     x8, x9, [sp, #0x40]
    ldp     x6, x7, [sp, #0x30]
    ldp     x4, x5, [sp, #0x20]
    ldp     x2, x3, [sp, #0x10]
    ldp     x0, x1, [sp, #0x00]
    add     sp, sp, #0xC0
    ret

// nx_enter_guest(entry, x0, x1, sp): start running guest code on a guest stack.
    .globl _nx_enter_guest
_nx_enter_guest:
    mov     x16, x0
    mov     x0, x1
    mov     x1, x2
    mov     sp, x3
    mov     x29, #0
    mov     x30, #0                     // returning from the guest entry is a bug: jumps to 0
    br      x16
