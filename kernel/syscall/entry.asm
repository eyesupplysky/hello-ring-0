; syscall entry stub. Saves user RSP into a fixed cell, switches to the
; kernel syscall stack, dispatches via syscall_table[RAX], then returns to
; ring 3 via sysretq. RCX (user RIP) and R11 (user RFLAGS) must round-trip
; intact across the dispatch — sysretq depends on them.

[BITS 64]

global syscall_entry

extern syscall_table
extern syscall_table_size

%define KERNEL_SYSCALL_STACK_TOP 0x88000

section .data

saved_user_rsp: dq 0

section .text

; syscall enters here from ring 3:
;   RCX = user RIP, R11 = user RFLAGS, RAX = syscall number,
;   RDI/RSI/RDX/R10/R8/R9 = args (Linux convention; R10 because RCX is taken).
;   CS=0x08, SS=0x10 (set by syscall instruction), RSP still points into user
;   stack — the kernel must switch before doing anything stack-y.
;            to the wrong RIP or with the wrong RFLAGS
syscall_entry:
    mov     [rel saved_user_rsp], rsp
    mov     rsp, KERNEL_SYSCALL_STACK_TOP

    push    rcx                                 ; user RIP
    push    r11                                 ; user RFLAGS

    cmp     rax, [rel syscall_table_size]
    jae     .invalid

    lea     rcx, [rel syscall_table]
    mov     rcx, [rcx + rax * 8]
    test    rcx, rcx
    jz      .invalid

    ; SystemV ABI matches our syscall convention for the first 3 args
    ; (RDI/RSI/RDX). Handlers needing arg 4+ would remap R10 -> RCX first;
    ; M4 handlers stop at 3 args.
    call    rcx

.return:
    pop     r11
    pop     rcx
    mov     rsp, [rel saved_user_rsp]
    o64 sysret

.invalid:
    mov     rax, -1
    jmp     .return
