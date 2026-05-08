; 16550 UART driver for COM1 (0x3F8). Polling-only — no IRQs registered.
; Used for headless verification: the run.sh harness wires QEMU's COM1 to
; a file and asserts kernel-emitted strings appear there.

[BITS 64]

global serial_init
global serial_putc
global serial_puts
global serial_put_hex_qword

%define COM1_BASE       0x3F8
%define COM1_DATA       (COM1_BASE + 0)
%define COM1_INT_EN     (COM1_BASE + 1)
%define COM1_FIFO       (COM1_BASE + 2)
%define COM1_LINE_CTL   (COM1_BASE + 3)
%define COM1_MODEM_CTL  (COM1_BASE + 4)
%define COM1_LINE_STS   (COM1_BASE + 5)
%define COM1_DLAB_LO    (COM1_BASE + 0)        ; with LCR.DLAB=1
%define COM1_DLAB_HI    (COM1_BASE + 1)        ; with LCR.DLAB=1

%define LSR_THR_EMPTY   0x20                   ; transmitter holding register empty

section .text

; Configure COM1: 115200 baud, 8N1, FIFO enabled, IRQs off.
serial_init:
    ; Disable all UART IRQs.
    mov     dx, COM1_INT_EN
    mov     al, 0
    out     dx, al

    ; DLAB=1 to access divisor latch.
    mov     dx, COM1_LINE_CTL
    mov     al, 0x80
    out     dx, al

    ; Divisor 1 -> 115200 baud (base 1.8432 MHz / 16).
    mov     dx, COM1_DLAB_LO
    mov     al, 0x01
    out     dx, al
    mov     dx, COM1_DLAB_HI
    mov     al, 0x00
    out     dx, al

    ; 8N1, DLAB=0.
    mov     dx, COM1_LINE_CTL
    mov     al, 0x03
    out     dx, al

    ; FIFO: enable, clear RX/TX, 14-byte threshold.
    mov     dx, COM1_FIFO
    mov     al, 0xC7
    out     dx, al

    ; DTR + RTS, IRQs disabled.
    mov     dx, COM1_MODEM_CTL
    mov     al, 0x0B
    out     dx, al
    ret

; Spin until THR is empty, then transmit one byte. dil = byte.
serial_putc:
    push    rdx
    mov     dx, COM1_LINE_STS
.wait:
    in      al, dx
    test    al, LSR_THR_EMPTY
    jz      .wait
    mov     dx, COM1_DATA
    mov     al, dil
    out     dx, al
    pop     rdx
    ret

; Print NUL-terminated string. rdi = str.
serial_puts:
    push    rbx
    mov     rbx, rdi
.loop:
    mov     dil, [rbx]
    test    dil, dil
    jz      .done
    call    serial_putc
    inc     rbx
    jmp     .loop
.done:
    pop     rbx
    ret

; serial_put_hex_qword(rdi=value): print 16 uppercase hex chars (most-
; significant nibble first) for the 64-bit value via COM1. Used by the
; M11d #PF handler to dump CR2 / RIP / error code; generally useful for
; any kernel debug output that must reach CI's serial log.
serial_put_hex_qword:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     r12, 16
.nibble:
    rol     rbx, 4
    mov     rdi, rbx
    and     rdi, 0xF
    cmp     rdi, 10
    jb      .digit
    add     rdi, 'A' - '0' - 10
.digit:
    add     rdi, '0'
    call    serial_putc
    dec     r12
    jnz     .nibble
    pop     r12
    pop     rbx
    ret
