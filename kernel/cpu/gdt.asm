; Kernel-resident GDT. Replaces stage 2's transient GDT — kernel code is now
; at selector 0x08, kernel data at 0x10. IDT gates depend on this layout.

[BITS 64]

global init_gdt

%define KCODE_SEL   0x08
%define KDATA_SEL   0x10

section .data

align 8
gdt_start:
    dq 0                                                ; null
    ; 64-bit code: P=1, DPL=0, S=1, type=1010, L=1, D=0
    dw 0xFFFF, 0x0000
    db 0x00, 10011010b, 10101111b, 0x00
    ; data: P=1, DPL=0, S=1, type=0010
    dw 0xFFFF, 0x0000
    db 0x00, 10010010b, 11001111b, 0x00
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dq gdt_start

section .text

; Load the kernel GDT and reload all segment selectors.
;            way to update CS in 64-bit mode
init_gdt:
    lgdt    [rel gdt_descriptor]

    mov     ax, KDATA_SEL
    mov     ds, ax
    mov     es, ax
    mov     fs, ax
    mov     gs, ax
    mov     ss, ax

    ; Far return to reload CS with KCODE_SEL.
    push    qword KCODE_SEL
    lea     rax, [rel .reload_cs]
    push    rax
    retfq
.reload_cs:
    ret
