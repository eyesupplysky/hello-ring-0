; Concrete interrupt handlers. Called from isr_common with RDI = vector number.
; M3a kept the #DE handler as an accidental-crash net even though M3b's main
; no longer triggers it deliberately.

[BITS 64]

global default_handler
global handler_div_by_zero

extern vga_puts_at

section .text

; Catch-all for unregistered vectors. Silent halt — we'll add a panic message
; once we have a richer VGA story (color attributes, full-screen panic frame).
default_handler:
    cli
.halt:
    hlt
    jmp     .halt

; Divide-by-zero (#DE) handler. Writes "X0!" to row 16 and halts. Returning
; would re-execute the offending div, so we never iretq.
handler_div_by_zero:
    lea     rdi, [rel msg_de]
    mov     rsi, 16
    mov     rdx, 0
    call    vga_puts_at
    cli
.halt:
    hlt
    jmp     .halt

section .data
msg_de: db "X0!", 0
