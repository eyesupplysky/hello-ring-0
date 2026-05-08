; Syscall handlers and the dispatch table. Numbers:
;   0 = sys_read
;   1 = sys_write
;   2 = sys_exit

[BITS 64]

global syscall_table
global syscall_table_size
global sys_read
global sys_write
global sys_exit

extern vga_putc
extern serial_putc
extern kbd_buffer
extern kbd_head
extern kbd_tail

section .data

syscall_table:
    dq sys_read                     ; 0
    dq sys_write                    ; 1
    dq sys_exit                     ; 2

syscall_table_size: dq 3

; PS/2 Set 1 scancode -> ASCII (unshifted, no caps lock). Make codes only;
; break codes (high bit set) are filtered upstream in sys_read. Index by
; scancode; 0 means "unmapped — drop and keep waiting".
align 8
scancode_to_ascii:
    db 0                                                            ; 0x00
    db 0x1B                                                         ; 0x01 ESC
    db '1','2','3','4','5','6','7','8','9','0','-','='              ; 0x02-0x0D
    db 0x08, 0x09                                                   ; 0x0E BS, 0x0F TAB
    db 'q','w','e','r','t','y','u','i','o','p','[',']'              ; 0x10-0x1B
    db 0x0A, 0                                                      ; 0x1C Enter, 0x1D LCtrl
    db 'a','s','d','f','g','h','j','k','l',';',0x27,'`'             ; 0x1E-0x29
    db 0, 0x5C                                                      ; 0x2A LShift, 0x2B '\'
    db 'z','x','c','v','b','n','m',',','.','/'                      ; 0x2C-0x35
    db 0, 0, 0, ' '                                                 ; 0x36 RShift, 0x37 *, 0x38 LAlt, 0x39 SPACE
    times 128 - ($ - scancode_to_ascii) db 0

section .text

; sys_read(int fd, void *buf, size_t count)
; Currently always returns at most 1 byte. fd 0 (stdin) only; others -> -1.
; Blocks via cli/sti+hlt around the head/tail check until a printable scancode
; is decoded.
sys_read:
    cmp     rdi, 0
    jne     .bad
    cmp     rdx, 0
    je      .empty

.wait:
    cli
    mov     rax, [rel kbd_head]
    cmp     rax, [rel kbd_tail]
    jne     .have
    sti                             ; sti+hlt is the race-free sleep pair:
    hlt                             ; sti's one-instruction shadow guarantees
    jmp     .wait                   ; any pending IRQ fires when hlt begins

.have:
    ; Pop scancode while interrupts are still off (atomic with check).
    mov     rcx, [rel kbd_tail]
    lea     r8, [rel kbd_buffer]
    movzx   rax, byte [r8 + rcx]
    inc     rcx
    and     rcx, 0xFF
    mov     [rel kbd_tail], rcx
    sti

    test    al, 0x80                ; high bit = break code; drop and re-wait
    jnz     .wait

    lea     r8, [rel scancode_to_ascii]
    movzx   rax, byte [r8 + rax]
    test    al, al                  ; unmapped scancode -> drop and re-wait
    jz      .wait

    mov     [rsi], al
    mov     rax, 1
    ret

.empty:
    xor     rax, rax
    ret
.bad:
    mov     rax, -1
    ret

; sys_write(int fd, const void *buf, size_t count)
; fd 1 (stdout) and 2 (stderr) both write each byte to VGA and to COM1.
; Returns count on success, -1 if fd is unsupported.
sys_write:
    cmp     rdi, 1
    je      .ok
    cmp     rdi, 2
    je      .ok
    mov     rax, -1
    ret
.ok:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rsi                ; buf
    mov     r12, rdx                ; count
    xor     r13, r13                ; bytes written
.next:
    cmp     r13, r12
    jge     .done
    movzx   edi, byte [rbx + r13]
    push    rdi
    call    vga_putc
    pop     rdi
    push    rdi
    call    serial_putc
    pop     rdi
    inc     r13
    jmp     .next
.done:
    mov     rax, r13
    pop     r13
    pop     r12
    pop     rbx
    ret

; sys_exit(int code) — never returns. Re-enables interrupts so the timer and
; keyboard keep running (system stays diagnosable), then halts the CPU.
sys_exit:
    sti
.halt:
    hlt
    jmp     .halt
