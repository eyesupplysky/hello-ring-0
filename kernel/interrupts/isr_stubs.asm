; 256 ISR stubs, macro-generated. Each pushes a (fake or real) error code,
; pushes its vector number, and jumps to the common dispatcher.

[BITS 64]

global isr_stub_table

extern isr_common

section .text

; ISR with no CPU-pushed error code: push a fake 0 to make the stack uniform.
%macro ISR_NOERR 1
isr_stub_%1:
    push    qword 0
    push    qword %1
    jmp     isr_common
%endmacro

; ISR where the CPU pushes an error code (vectors 8, 10-14, 17, 21).
%macro ISR_ERR 1
isr_stub_%1:
    push    qword %1
    jmp     isr_common
%endmacro

; Dispatch ERR vs NOERR based on Intel SDM Vol 3 §6.13.
%macro DEF_STUB 1
    %if %1 == 8 || %1 == 10 || %1 == 11 || %1 == 12 || %1 == 13 || %1 == 14 || %1 == 17 || %1 == 21
        ISR_ERR %1
    %else
        ISR_NOERR %1
    %endif
%endmacro

%assign vec 0
%rep 256
    DEF_STUB vec
%assign vec vec + 1
%endrep

section .data

; Table of stub addresses indexed by vector. init_idt walks this to populate
; gates without needing 256 individual extern declarations.
align 8
isr_stub_table:
%assign vec 0
%rep 256
    dq isr_stub_ %+ vec
%assign vec vec + 1
%endrep
