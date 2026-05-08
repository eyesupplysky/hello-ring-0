; PS/2 keyboard on IRQ1. Reads scancodes from port 0x60, enqueues into a
; 256-byte ring buffer, mirrors "KEY XX" (literal + hex byte) to VGA row 19
; via the VGA driver. The PS/2 controller is left in its BIOS-initialized
; state — we just drain pending bytes and unmask IRQ1.

[BITS 64]

global init_kbd
global handler_irq1
global kbd_buffer
global kbd_head
global kbd_tail

extern pic_send_eoi
extern pic_unmask_irq
extern vga_puts_at
extern vga_put_hex_byte_at

%define KBD_DATA_PORT      0x60
%define KBD_STATUS_PORT    0x64
%define KBD_STATUS_OBF     0x01

section .data

kbd_head:   dq 0
kbd_tail:   dq 0
kbd_buffer: times 256 db 0
msg_key:    db "KEY ", 0

section .text

; Drain any scancodes left in the controller from BIOS, then unmask IRQ1.
init_kbd:
.drain:
    in      al, KBD_STATUS_PORT
    test    al, KBD_STATUS_OBF
    jz      .done
    in      al, KBD_DATA_PORT
    jmp     .drain
.done:
    mov     rdi, 1
    call    pic_unmask_irq
    ret

; IRQ1 handler. Reads scancode, pushes to ring buffer, mirrors hex to VGA, EOI.
;            isr_common saves all GPRs so this handler clobbers freely
handler_irq1:
    in      al, KBD_DATA_PORT
    mov     bl, al                              ; preserve scancode across driver calls

    ; Ring buffer push (head wraps mod 256; oldest byte gets overwritten on overflow).
    mov     rcx, [rel kbd_head]
    lea     rsi, [rel kbd_buffer]
    mov     [rsi + rcx], al
    inc     rcx
    and     rcx, 0xFF
    mov     [rel kbd_head], rcx

    ; "KEY " literal at row 19, col 0.
    lea     rdi, [rel msg_key]
    mov     rsi, 19
    mov     rdx, 0
    call    vga_puts_at

    ; Hex of scancode at row 19, col 4.
    movzx   rdi, bl
    mov     rsi, 19
    mov     rdx, 4
    call    vga_put_hex_byte_at

    mov     rdi, 1
    call    pic_send_eoi
    ret
