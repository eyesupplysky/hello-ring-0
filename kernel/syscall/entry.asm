; syscall entry stub. Switches to the current process's kernel syscall stack
; (looked up via current_process), pushes the user RSP onto that stack so it
; rides along with the rest of the per-process saved state, then dispatches
; via syscall_table[RAX] and returns to ring 3 via sysretq. RCX (user RIP)
; and R11 (user RFLAGS) must round-trip intact across the dispatch — sysretq
; depends on them.
;
; M13a indirected the kernel-stack load: pre-M13a this file baked the literal
; KERNEL_SYSCALL_STACK_TOP=0x88000; now that literal lives in the boot
; process's process_t and any context switch (M13b) updates current_process
; to point at the new owner of the stack.
;
; M13c reworked the user-RSP save: pre-M13c the user RSP lived in a single
; global cell (`saved_user_rsp`), which broke the moment a peer process made
; a syscall while we were paused mid-sys_yield — the peer's syscall_entry
; would clobber the global, and our post-handler sysretq would land in ring
; 3 with the peer's RSP, faulting on the first stack op against an
; unmapped-in-our-vm_space VA. Now the user RSP is pushed onto the kernel
; syscall stack (per-process by construction) and popped directly into RSP
; right before sysretq. The remaining global, `entry_rsp_scratch`, is only
; touched in the few-instruction window between "load kernel rsp" and "push
; user rsp" — a window that runs with IF=0 (FMASK) and has no calls, so
; preemption / nested syscall can't enter it.

[BITS 64]

global syscall_entry

extern syscall_table
extern syscall_table_size
extern current_process

; Must match PROC_OFF_KERNEL_SYSCALL_RSP in kernel/process/process.asm. Kept
; as a literal here because NASM %define symbols don't cross object-file
; boundaries.
%define PROC_OFF_KERNEL_SYSCALL_RSP 0x10

section .data

; Single-cell scratch for the user-RSP hand-off between the user-side rsp
; (still pointing into the user stack) and the kernel-side rsp (the process's
; kernel syscall stack top, which we then push the user rsp onto). Touched
; only inside the syscall_entry stub's pre-handler window with IF=0 and no
; embedded calls; safe to be a global because nothing else can run between
; the write and the read.
entry_rsp_scratch: dq 0

section .text

; syscall enters here from ring 3:
;   RCX = user RIP, R11 = user RFLAGS, RAX = syscall number,
;   RDI/RSI/RDX/R10/R8/R9 = args (Linux convention; R10 because RCX is taken).
;   CS=0x08, SS=0x10 (set by syscall instruction), RSP still points into user
;   stack — the kernel must switch before doing anything stack-y.
;            to the wrong RIP or with the wrong RFLAGS
;            whose kernel_syscall_stack_top is reserved memory
syscall_entry:
    ; Phase 1 (IF=0, non-interruptible): swap from user rsp to the current
    ; process's kernel syscall stack and push the user rsp onto the kernel
    ; stack. rsp is briefly used as a scratch register here — between the
    ; user-rsp stash to entry_rsp_scratch and the kernel-rsp load, no other
    ; reg may be clobbered (RAX is the syscall number, RCX/R11 are user
    ; RIP/RFLAGS, RDI/RSI/RDX/R10/R8/R9 are the args).
    mov     [rel entry_rsp_scratch], rsp
    mov     rsp, [rel current_process]
    mov     rsp, [rsp + PROC_OFF_KERNEL_SYSCALL_RSP]
    push    qword [rel entry_rsp_scratch]      ; user RSP — rides on per-process stack

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
    pop     rsp                                 ; user RSP — pops directly
    o64 sysret

.invalid:
    mov     rax, -1
    jmp     .return
