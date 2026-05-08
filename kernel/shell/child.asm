; Embedded second user binary (M13c). The shell's spawn_selftest hands
; child_main as entry_addr to sys_spawn; the spawner builds a child vm_space
; with its own user stack at virt 0x800000 and an iretq frame pointing here.
; The child writes "C OK\n" to fd 1 and sys_exits. Lives in `.user2_text` so
; init_page_protect stamps these pages with US=1; data lives in `.user2_data`
; with US=1 + RW + NX.

[BITS 64]

global child_main

%define SYS_WRITE       1
%define SYS_EXIT        2
%define FD_STDOUT       1

section .user2_text

; Ring-3 entry. Runs in the child's vm_space with its own stack at
; USER2_STACK_TOP (0x801000) — see kernel/process/process.asm sys_spawn for
; the iretq frame layout. Returns via sys_exit; never falls through.
;            is the user stack; everything else (kernel image, .user2_text,
;            .user2_data) reaches it via the shared boot PT under PD[0]
child_main:
    mov     rax, SYS_WRITE
    mov     rdi, FD_STDOUT
    lea     rsi, [rel child_msg]
    mov     rdx, child_msg_len
    syscall

    mov     rax, SYS_EXIT
    xor     rdi, rdi
    syscall

.unreached:
    ; sys_exit doesn't return; this is a defensive halt against any future
    ; bug where it would.
    hlt
    jmp     .unreached

section .user2_data

child_msg:     db "C OK", 0x0A
child_msg_len  equ $ - child_msg
