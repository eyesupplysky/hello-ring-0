; Long-mode TSS. RSP0 is the kernel stack the CPU loads on ring 3 -> ring 0
; transitions (interrupts from user mode). I/O map base set past the TSS so
; ring 3 cannot use IN/OUT with IOPL=0; CPU raises #GP instead.

[BITS 64]

global init_tss
global tss_set_rsp0

extern gdt_tss_descriptor

%define TSS_SIZE          104
%define TSS_SELECTOR      0x28
%define KERNEL_STACK_TOP  0x90000

section .data

align 16
tss:
    dd 0                                ; +0x00  reserved
    dq KERNEL_STACK_TOP                 ; +0x04  RSP0
    times 0x66 - 12 db 0                ; +0x0C  RSP1, RSP2, IST1-7, reserved
    dw TSS_SIZE                         ; +0x66  I/O map base offset

section .text

; Patch the GDT TSS descriptor with the runtime address of the TSS, then LTR.
;            requires a 64-bit available TSS descriptor at TSS_SELECTOR
init_tss:
    lea     rax, [rel tss]
    lea     rdi, [rel gdt_tss_descriptor]

    mov     word [rdi], TSS_SIZE - 1            ; limit
    mov     [rdi + 2], ax                       ; base[15:0]
    shr     rax, 16
    mov     [rdi + 4], al                       ; base[23:16]
    mov     byte [rdi + 5], 0x89                ; P=1, DPL=0, type=1001 (avail 64-bit TSS)
    mov     byte [rdi + 6], 0x00                ; flags + limit[19:16]
    mov     [rdi + 7], ah                       ; base[31:24]
    shr     rax, 16
    mov     [rdi + 8], eax                      ; base[63:32]
    mov     dword [rdi + 12], 0                 ; reserved

    mov     ax, TSS_SELECTOR
    ltr     ax
    ret

; tss_set_rsp0(rdi=new_rsp): patch the TSS's RSP0 slot in place. context_switch
; calls this on every per-process kernel-irq-stack swap (M13b) so the next
; ring-3 -> ring-0 transition lands on the new owner's irq stack. The CPU
; reads RSP0 lazily on each ring-3 -> 0 entry, so a bare store is sufficient
; — no LTR re-issue or TLB flush.
;            any ring-3 process can be scheduled
;            reads whatever RSP0 it finds at that moment — a torn 8-byte write
;            with IF=1 would be catastrophic on a CPU that interrupted us
;            mid-store, but we run with FMASK clearing IF on syscall entry so
;            this is moot in practice)
tss_set_rsp0:
    mov     [rel tss + 4], rdi
    ret
