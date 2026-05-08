; Kernel GDT. Five usable selectors plus a 16-byte TSS slot:
;   0x00  null
;   0x08  kernel code  (DPL=0, 64-bit)   <- STAR[47:32]
;   0x10  kernel data  (DPL=0)
;   0x18  user data    (DPL=3)            <- sysretq SS = STAR[63:48] + 8
;   0x20  user code    (DPL=3, 64-bit)    <- sysretq CS = STAR[63:48] + 16
;   0x28  TSS (16 bytes — long-mode system descriptor spans 2 GDT entries)

[BITS 64]

global init_gdt
global gdt_tss_descriptor

%define KCODE_SEL   0x08
%define KDATA_SEL   0x10

section .data

align 8
gdt_start:
    dq 0                                                ; null
    ; Kernel code: P, DPL=0, S, type=code/R/non-conf, L=1, D=0
    dw 0xFFFF, 0x0000
    db 0x00, 10011010b, 10101111b, 0x00
    ; Kernel data: P, DPL=0, S, type=data/W
    dw 0xFFFF, 0x0000
    db 0x00, 10010010b, 11001111b, 0x00
    ; User data: P, DPL=3, S, type=data/W
    dw 0xFFFF, 0x0000
    db 0x00, 11110010b, 11001111b, 0x00
    ; User code: P, DPL=3, S, type=code/R/non-conf, L=1, D=0
    dw 0xFFFF, 0x0000
    db 0x00, 11111010b, 10101111b, 0x00
gdt_tss_descriptor:
    times 16 db 0                                       ; patched at runtime by init_tss
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

    push    qword KCODE_SEL
    lea     rax, [rel .reload_cs]
    push    rax
    retfq
.reload_cs:
    ret
