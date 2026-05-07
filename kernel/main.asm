; M2 kernel: long-mode entry, write "K OK" to VGA text buffer, halt.

[BITS 64]

global _start

section .text

; Kernel entry. Long mode active, identity-mapped 0..2 MB, RSP not guaranteed.
_start:
    mov     rdi, 0xB8000 + (14 * 80 * 2)        ; row 14, col 0
    lea     rsi, [rel msg_k_ok]
.copy:
    mov     al, [rsi]
    test    al, al
    jz      .halt
    mov     [rdi], al
    mov     byte [rdi + 1], 0x07                ; light-gray on black
    add     rdi, 2
    inc     rsi
    jmp     .copy
.halt:
    cli
    hlt
    jmp     .halt

msg_k_ok:   db "K OK", 0
