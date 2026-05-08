; Concrete interrupt handlers. Called from isr_common with RDI = vector number.
; M3a kept the #DE handler as an accidental-crash net even though M3b's main
; no longer triggers it deliberately.

[BITS 64]

global default_handler
global handler_div_by_zero
global handler_page_fault

extern vga_puts_at
extern serial_puts
extern serial_put_hex_qword

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

; #PF (vector 14) handler. CPU pushed an error code; isr_common saved 15
; GPRs and reached us via `call rax`, which pushed a return address — so
; from inside this handler the stack is:
;   [rsp+ 0]      = call's return address (back into isr_common)
;   [rsp+ 1*8..15*8] = saved GPRs (r15 first, rax last)
;   [rsp+16*8]    = vector number (pushed by the stub)
;   [rsp+17*8]    = error code  (CPU-pushed for #PF)
;   [rsp+18*8]    = faulting RIP (CPU-pushed)
; The +1 qword vs the naive "15 GPRs above the frame" arithmetic is the
; call's return address; missing it shifts every read by one slot.
; CR2 holds the linear address that triggered the fault.
;
; We dump "#PF" to VGA row 22 col 0 (so the CI substring assertion has a
; stable anchor) and "#PF err=XXXX cr2=... rip=..." to serial via
; serial_put_hex_qword. Then halt — recovery from a kernel-mode #PF needs
; longjmp infrastructure we don't have yet.
handler_page_fault:
    mov     r12, [rsp + 17*8]
    mov     r13, [rsp + 18*8]
    mov     r14, cr2

    lea     rdi, [rel msg_pf_vga]
    mov     rsi, 22
    mov     rdx, 0
    call    vga_puts_at

    lea     rdi, [rel msg_pf_serial]
    call    serial_puts
    mov     rdi, r12
    call    serial_put_hex_qword
    lea     rdi, [rel msg_pf_cr2]
    call    serial_puts
    mov     rdi, r14
    call    serial_put_hex_qword
    lea     rdi, [rel msg_pf_rip]
    call    serial_puts
    mov     rdi, r13
    call    serial_put_hex_qword
    lea     rdi, [rel msg_pf_nl]
    call    serial_puts

    cli
.halt:
    hlt
    jmp     .halt

section .data
msg_de: db "X0!", 0
msg_pf_vga:    db "#PF", 0
msg_pf_serial: db "#PF err=", 0
msg_pf_cr2:    db " cr2=", 0
msg_pf_rip:    db " rip=", 0
msg_pf_nl:     db 0x0D, 0x0A, 0
