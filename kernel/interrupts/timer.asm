; PIT (8254 channel 0) at ~100 Hz on IRQ0. Handler increments tick_count and
; writes "TICK" to row 18 via the VGA driver so headless verification can
; confirm IRQs are firing without needing to read the counter directly.

[BITS 64]

global init_pit
global handler_irq0
global tick_count

extern pic_send_eoi
extern pic_unmask_irq
extern vga_puts_at

%define PIT_CHAN0   0x40
%define PIT_CMD     0x43

; Base 1193182 Hz / 100 Hz ≈ 11932 (0x2E9C) — close enough to 100 Hz.
%define PIT_DIVISOR 0x2E9C

section .data

tick_count: dq 0
msg_tick:   db "TICK", 0

section .text

; Configure PIT channel 0 for ~100 Hz square wave on OUT 0 -> IRQ0, then
; unmask IRQ0 on the master PIC.
init_pit:
    mov     al, 0x36
    out     PIT_CMD, al

    mov     ax, PIT_DIVISOR
    out     PIT_CHAN0, al           ; low byte
    mov     al, ah
    out     PIT_CHAN0, al           ; high byte

    mov     rdi, 0
    call    pic_unmask_irq
    ret

; IRQ0 handler. Increments tick_count, mirrors "TICK" to VGA, EOI.
;            isr_common saves all GPRs so this handler clobbers freely
handler_irq0:
    inc     qword [rel tick_count]

    lea     rdi, [rel msg_tick]
    mov     rsi, 18
    mov     rdx, 0
    call    vga_puts_at

    mov     rdi, 0
    call    pic_send_eoi
    ret
