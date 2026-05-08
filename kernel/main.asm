; Kernel entry. M3d boot sequence: VGA + serial driver init, GDT, IDT/handler
; table, PIC remap, PIT, PS/2 keyboard, then sti + idle. "K OK" goes to both
; VGA (row 14) and serial (where run.sh captures it).

[BITS 64]

global _start

extern init_gdt
extern init_interrupts
extern init_pic
extern init_pit
extern init_kbd
extern vga_init
extern vga_puts_at
extern serial_init
extern serial_puts

section .text

; Kernel entry. Long mode active, identity-mapped 0..2 MB. RSP inherited from
; stage 2 (0x7C00 region — fine for M3, may be relocated at M4).
_start:
    call    vga_init
    call    serial_init

    call    init_gdt
    call    init_interrupts
    call    init_pic
    call    init_pit
    call    init_kbd

    lea     rdi, [rel msg_k_ok]
    mov     rsi, 14                             ; row
    mov     rdx, 0                              ; col
    call    vga_puts_at

    lea     rdi, [rel msg_k_ok_serial]
    call    serial_puts

    sti
.halt:
    hlt
    jmp     .halt

msg_k_ok:        db "K OK", 0
msg_k_ok_serial: db "K OK", 0x0D, 0x0A, 0
