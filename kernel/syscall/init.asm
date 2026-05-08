; Syscall MSR setup. Enables EFER.SCE so the syscall instruction is dispatched,
; programs STAR with kernel/user CS bases, points LSTAR at our entry stub, and
; sets FMASK so RFLAGS.IF is cleared on syscall entry (handler runs with IRQs
; disabled until it explicitly enables them).

[BITS 64]

global init_syscall

extern syscall_entry

%define MSR_EFER    0xC0000080
%define MSR_STAR    0xC0000081
%define MSR_LSTAR   0xC0000082
%define MSR_FMASK   0xC0000084

%define EFER_SCE    0x01

section .text

; STAR layout for SYSCALL/SYSRET 64-bit:
;   bits 47:32 = kernel CS    (=> SYSCALL CS = STAR[47:32], SS = STAR[47:32]+8)
;   bits 63:48 = user CS base (=> SYSRETQ CS = STAR[63:48]+16, SS = STAR[63:48]+8)
; With kernel code at 0x08, kernel data at 0x10, user data at 0x18, user code
; at 0x20: STAR[47:32] = 0x08, STAR[63:48] = 0x10.
init_syscall:
    ; EFER.SCE = 1
    mov     ecx, MSR_EFER
    rdmsr
    or      eax, EFER_SCE
    wrmsr

    ; STAR: high 32 bits encode (user_cs_base << 16) | kernel_cs.
    mov     ecx, MSR_STAR
    xor     eax, eax
    mov     edx, 0x00100008
    wrmsr

    ; LSTAR = &syscall_entry
    mov     ecx, MSR_LSTAR
    lea     rax, [rel syscall_entry]
    mov     rdx, rax
    shr     rdx, 32
    wrmsr

    ; FMASK: clear IF (bit 9) on syscall entry.
    mov     ecx, MSR_FMASK
    mov     eax, 0x200
    xor     edx, edx
    wrmsr
    ret
