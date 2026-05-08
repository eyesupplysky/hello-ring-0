; Kernel IDT. 256 gates, each pointing to its corresponding ISR stub. The
; IDT lives at a fixed physical address (IDT_ADDR) outside the kernel image.

[BITS 64]

global init_idt

extern isr_stub_table

%define IDT_ADDR        0x110000
%define IDT_BYTES       (256 * 16)
%define KCODE_SEL       0x08
%define GATE_TYPE_INT64 0x8E            ; P=1, DPL=0, type=0xE (interrupt gate)

section .data

idt_descriptor:
    dw IDT_BYTES - 1
    dq IDT_ADDR

section .text

; Write a single 64-bit interrupt-gate descriptor at IDT_ADDR + vector*16.
install_idt_gate:
    ; rdi = vector, rsi = handler address
    mov     rax, IDT_ADDR
    mov     rcx, rdi
    shl     rcx, 4                              ; vector * 16
    add     rax, rcx                            ; rax = &idt[vector]

    mov     [rax],     si                       ; offset[15:0]
    mov     word [rax + 2], KCODE_SEL           ; selector
    mov     byte [rax + 4], 0                   ; ist = 0
    mov     byte [rax + 5], GATE_TYPE_INT64     ; type_attr

    mov     rcx, rsi
    shr     rcx, 16
    mov     [rax + 6], cx                       ; offset[31:16]

    mov     rcx, rsi
    shr     rcx, 32
    mov     [rax + 8], ecx                      ; offset[63:32]

    mov     dword [rax + 12], 0                 ; reserved
    ret

; Zero the IDT region, install all 256 gates pointing to their isr_stub_N,
; and load the IDT register.
init_idt:
    push    rbx
    push    r12

    ; Zero IDT region.
    mov     rdi, IDT_ADDR
    xor     eax, eax
    mov     rcx, IDT_BYTES / 8
    rep     stosq

    ; Install gates from isr_stub_table[].
    lea     rbx, [rel isr_stub_table]
    xor     r12, r12
.next:
    mov     rdi, r12
    mov     rsi, [rbx + r12 * 8]
    call    install_idt_gate
    inc     r12
    cmp     r12, 256
    jl      .next

    lidt    [rel idt_descriptor]

    pop     r12
    pop     rbx
    ret
