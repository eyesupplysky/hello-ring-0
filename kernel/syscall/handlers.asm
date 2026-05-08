; Syscall handlers and the dispatch table. Numbers:
;   0 = sys_read    (dispatches via fd_read_fns[fd])
;   1 = sys_write   (dispatches via fd_write_fns[fd])
;   2 = sys_exit
;   3 = sys_open    (in fd.asm)
;   4 = sys_close   (in fd.asm)
;   5 = sys_mmap    (in mm/user_vm.asm — M11c real virt mapping)
;   6 = sys_munmap  (in mm/user_vm.asm — M11c real virt unmapping)
;
; sys_read and sys_write are thin dispatchers: they validate fd, look up the
; per-fd function pointer in the fd table, shift the args (rdi=buf, rsi=count),
; and tail through. The actual work for stdin and stdout/stderr is in
; kbd_read and console_write — file-local, exposed only to fd.asm via
; init_fd's table population.

[BITS 64]

global syscall_table
global syscall_table_size
global sys_read
global sys_write
global sys_exit
global kbd_read
global console_write

extern vga_putc
extern serial_putc
extern kbd_buffer
extern kbd_head
extern kbd_tail
extern kbd_shift_state
extern kbd_caps_lock
extern fd_read_fns
extern fd_write_fns
extern fd_in_use
extern sys_open
extern sys_close
extern sys_mmap
extern sys_munmap

; Must match the table size in fd.asm. Kept as a literal here because NASM
; %define symbols don't cross object-file boundaries.
%define FD_TABLE_SIZE 16

section .data

syscall_table:
    dq sys_read                     ; 0
    dq sys_write                    ; 1
    dq sys_exit                     ; 2
    dq sys_open                     ; 3
    dq sys_close                    ; 4
    dq sys_mmap                     ; 5
    dq sys_munmap                   ; 6

syscall_table_size: dq 7

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

; sys_read(int fd, void *buf, size_t count) — dispatcher.
; Validates fd, looks up fd_read_fns[fd], shifts args to (rdi=buf, rsi=count),
; tail-calls. Returns -1 if fd is out of range, the slot is free, or no read
; handler is installed (e.g., a write-only file).
sys_read:
    cmp     rdi, FD_TABLE_SIZE
    jae     .bad
    test    rdx, rdx
    jz      .empty
    lea     rcx, [rel fd_in_use]
    cmp     byte [rcx + rdi], 0
    je      .bad
    lea     rcx, [rel fd_read_fns]
    mov     rax, [rcx + rdi*8]
    test    rax, rax
    jz      .bad
    mov     rdi, rsi
    mov     rsi, rdx
    jmp     rax                     ; tail-call: handler's ret returns to user
.empty:
    xor     rax, rax
    ret
.bad:
    mov     rax, -1
    ret

; kbd_read(buf, count) — fd 0 read handler.
; Blocks via cli/sti+hlt around the head/tail check until a printable scancode
; is decoded. Modifier scancodes are consumed silently and update kbd_shift_state
; / kbd_caps_lock without producing output: 0x2A/0xAA LShift, 0x36/0xB6 RShift,
; 0x1D/0x9D LCtrl, 0x38/0xB8 LAlt, 0x3A CapsLock toggle. Right-side Ctrl/Alt
; (0xE0-prefixed extended scancodes) work transparently because the 0xE0 byte
; is filtered by the break-code drop and the suffix scancode is identical to
; the left-side variant. Translation picks the shifted LUT when either shift
; is held; if Ctrl is held and the result is a letter, AND 0x1F yields the
; standard ASCII control code (Ctrl supersedes caps lock); otherwise caps lock
; toggles letter case as a post-step.
kbd_read:
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

    ; Modifier handling first — these include break codes (0xAA, 0xB6, 0x9D,
    ; 0xB8) that would otherwise be filtered out by the high-bit check below.
    cmp     al, 0x2A                ; LShift make
    je      .lshift_down
    cmp     al, 0x36                ; RShift make
    je      .rshift_down
    cmp     al, 0xAA                ; LShift break
    je      .lshift_up
    cmp     al, 0xB6                ; RShift break
    je      .rshift_up
    cmp     al, 0x1D                ; LCtrl make
    je      .lctrl_down
    cmp     al, 0x9D                ; LCtrl break
    je      .lctrl_up
    cmp     al, 0x38                ; LAlt make
    je      .lalt_down
    cmp     al, 0xB8                ; LAlt break
    je      .lalt_up
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

    ; If Ctrl held and the result is a letter, AND 0x1F yields the standard
    ; ASCII control code (Ctrl+A=0x01, Ctrl+C=0x03, Ctrl+Z=0x1A). Ctrl
    ; supersedes caps lock — Ctrl+a and Ctrl+A both produce the same code.
    test    byte [rel kbd_shift_state], 0x04
    jz      .check_caps
    mov     dl, al
    and     dl, 0xDF
    sub     dl, 'A'
    cmp     dl, 'Z' - 'A' + 1
    jae     .check_caps             ; not a letter — Ctrl has no effect
    and     al, 0x1F
    jmp     .write

.check_caps:
    ; Caps lock toggles case for ASCII letters only.
    test    byte [rel kbd_caps_lock], 0x01
    jz      .write
    mov     dl, al
    and     dl, 0xDF
    sub     dl, 'A'
    cmp     dl, 'Z' - 'A' + 1
    jae     .write
    xor     al, 0x20

.write:
    mov     [rdi], al
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
.lctrl_down:
    or      byte [rel kbd_shift_state], 0x04
    jmp     .wait
.lctrl_up:
    and     byte [rel kbd_shift_state], 0xFB
    jmp     .wait
.lalt_down:
    or      byte [rel kbd_shift_state], 0x08
    jmp     .wait
.lalt_up:
    and     byte [rel kbd_shift_state], 0xF7
    jmp     .wait
.caps_toggle:
    xor     byte [rel kbd_caps_lock], 0x01
    jmp     .wait

; sys_write(int fd, const void *buf, size_t count) — dispatcher.
; Symmetric to sys_read: validate fd, look up fd_write_fns[fd], dispatch.
sys_write:
    cmp     rdi, FD_TABLE_SIZE
    jae     .sw_bad
    test    rdx, rdx
    jz      .sw_empty
    lea     rcx, [rel fd_in_use]
    cmp     byte [rcx + rdi], 0
    je      .sw_bad
    lea     rcx, [rel fd_write_fns]
    mov     rax, [rcx + rdi*8]
    test    rax, rax
    jz      .sw_bad
    mov     rdi, rsi
    mov     rsi, rdx
    jmp     rax
.sw_empty:
    xor     rax, rax
    ret
.sw_bad:
    mov     rax, -1
    ret

; console_write(buf, count) — fd 1/2 write handler.
; Mirrors each byte to VGA (vga_putc) and to COM1 (serial_putc).
console_write:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi                ; buf
    mov     r12, rsi                ; count
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
