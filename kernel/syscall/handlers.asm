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
extern kbd_shift_state
extern kbd_caps_lock

section .data

syscall_table:
    dq sys_read                     ; 0
    dq sys_write                    ; 1
    dq sys_exit                     ; 2

syscall_table_size: dq 3

; PS/2 Set 1 scancode -> ASCII (unshifted, no caps lock). Make codes only;
; break codes (high bit set) are filtered upstream in sys_read. Index by
; scancode; 0 means "unmapped — drop and keep waiting". Modifier scancodes
; (0x2A LShift, 0x36 RShift, 0x3A CapsLock) are also intercepted in sys_read
; before this lookup, so their entries here are 0 (would-be unmapped anyway).
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

; Shifted variant. Same indexing as scancode_to_ascii — sys_read picks this
; table when LShift or RShift is held. Letters are the uppercased glyph;
; number row and punctuation use the US-QWERTY shifted symbol. Control bytes
; (BS, TAB, Enter, ESC, SPACE) are unchanged.
align 8
scancode_to_ascii_shifted:
    db 0                                                            ; 0x00
    db 0x1B                                                         ; 0x01 ESC
    db '!','@','#','$','%','^','&','*','(',')','_','+'              ; 0x02-0x0D
    db 0x08, 0x09                                                   ; 0x0E BS, 0x0F TAB
    db 'Q','W','E','R','T','Y','U','I','O','P','{','}'              ; 0x10-0x1B
    db 0x0A, 0                                                      ; 0x1C Enter, 0x1D LCtrl
    db 'A','S','D','F','G','H','J','K','L',':','"','~'              ; 0x1E-0x29
    db 0, '|'                                                       ; 0x2A LShift, 0x2B '|'
    db 'Z','X','C','V','B','N','M','<','>','?'                      ; 0x2C-0x35
    db 0, 0, 0, ' '                                                 ; 0x36 RShift, 0x37 *, 0x38 LAlt, 0x39 SPACE
    times 128 - ($ - scancode_to_ascii_shifted) db 0

section .text

; sys_read(int fd, void *buf, size_t count)
; Currently always returns at most 1 byte. fd 0 (stdin) only; others -> -1.
; Blocks via cli/sti+hlt around the head/tail check until a printable scancode
; is decoded. Modifier scancodes (0x2A/0x36 shift make, 0xAA/0xB6 shift break,
; 0x3A caps lock toggle) are consumed silently and update kbd_shift_state /
; kbd_caps_lock without producing output. Translation picks the shifted LUT
; when either shift is held; caps lock then toggles letter case as a post-step.
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

    ; Modifier handling first — these include break codes (0xAA, 0xB6) that
    ; would otherwise be filtered out by the high-bit check below.
    cmp     al, 0x2A                ; LShift make
    je      .lshift_down
    cmp     al, 0x36                ; RShift make
    je      .rshift_down
    cmp     al, 0xAA                ; LShift break
    je      .lshift_up
    cmp     al, 0xB6                ; RShift break
    je      .rshift_up
    cmp     al, 0x3A                ; CapsLock make (toggle; break 0xBA ignored)
    je      .caps_toggle

    test    al, 0x80                ; high bit = break code; drop and re-wait
    jnz     .wait

    ; Pick LUT based on shift state.
    test    byte [rel kbd_shift_state], 0x03
    jz      .use_unshifted
    lea     r8, [rel scancode_to_ascii_shifted]
    jmp     .lookup
.use_unshifted:
    lea     r8, [rel scancode_to_ascii]
.lookup:
    movzx   rax, byte [r8 + rax]
    test    al, al                  ; unmapped scancode -> drop and re-wait
    jz      .wait

    ; Caps lock toggles case for ASCII letters only. Range check via
    ; AND 0xDF (clears case bit) then unsigned compare against 'A'..'Z'.
    test    byte [rel kbd_caps_lock], 0x01
    jz      .write
    mov     dl, al
    and     dl, 0xDF
    sub     dl, 'A'
    cmp     dl, 'Z' - 'A' + 1
    jae     .write
    xor     al, 0x20

.write:
    mov     [rsi], al
    mov     rax, 1
    ret

.lshift_down:
    or      byte [rel kbd_shift_state], 0x01
    jmp     .wait
.rshift_down:
    or      byte [rel kbd_shift_state], 0x02
    jmp     .wait
.lshift_up:
    and     byte [rel kbd_shift_state], 0xFE
    jmp     .wait
.rshift_up:
    and     byte [rel kbd_shift_state], 0xFD
    jmp     .wait
.caps_toggle:
    xor     byte [rel kbd_caps_lock], 0x01
    jmp     .wait

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
