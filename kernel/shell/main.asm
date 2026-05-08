; Cooked-mode line shell. Runs in ring 3, talks to the kernel only via
; syscalls. Maintains a 128-byte line buffer; printable bytes append + echo
; per-keystroke; backspace decrements + echoes (kernel vga_putc handles the
; glyph erase) but is suppressed when the buffer is empty so it can't damage
; the prompt; Ctrl+C drops the in-flight line and emits "^C" + a fresh prompt;
; LF commits the line, resets the buffer, and re-emits the prompt.

[BITS 64]

global shell_main

%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_EXIT        2
%define SYS_OPEN        3
%define SYS_CLOSE       4
%define SYS_MMAP        5
%define SYS_MUNMAP      6
%define FD_STDIN        0
%define FD_STDOUT       1
%define LINE_BUF_SIZE   128

section .text

; Ring-3 entry. Prints initial prompt, then enters the cooked-mode line loop.
; process_line is a no-op stub on commit — future milestones (commands,
; parsing) hook in there.
shell_main:
    call    fd_selftest
    call    mm_selftest
    lea     rdi, [rel prompt]
    mov     rsi, prompt_len
    call    write_str

.loop:
    ; Read one byte (blocks until a printable scancode is decoded).
    mov     rax, SYS_READ
    mov     rdi, FD_STDIN
    lea     rsi, [rel char_buf]
    mov     rdx, 1
    syscall

    mov     al, [rel char_buf]
    cmp     al, 0x0A
    je      .commit
    cmp     al, 0x08
    je      .backspace
    cmp     al, 0x03                ; Ctrl+C — abort line, fresh prompt
    je      .ctrl_c

    ; Printable: append to buffer if room, else drop silently (no echo).
    mov     rcx, [rel line_len]
    cmp     rcx, LINE_BUF_SIZE - 1
    jge     .loop
    lea     rsi, [rel line_buf]
    mov     [rsi + rcx], al
    inc     qword [rel line_len]
    lea     rdi, [rel char_buf]
    mov     rsi, 1
    call    write_str
    jmp     .loop

.backspace:
    ; Empty buffer — drop silently so BS can't erase the prompt.
    cmp     qword [rel line_len], 0
    je      .loop
    dec     qword [rel line_len]
    lea     rdi, [rel char_buf]
    mov     rsi, 1
    call    write_str
    jmp     .loop

.commit:
    ; Echo the newline.
    lea     rdi, [rel char_buf]
    mov     rsi, 1
    call    write_str
    ; process_line(line_buf, line_len) — no-op stub for M6.
    mov     qword [rel line_len], 0
    lea     rdi, [rel prompt]
    mov     rsi, prompt_len
    call    write_str
    jmp     .loop

.ctrl_c:
    lea     rdi, [rel ctrl_c_indicator]
    mov     rsi, ctrl_c_indicator_len
    call    write_str
    mov     qword [rel line_len], 0
    lea     rdi, [rel prompt]
    mov     rsi, prompt_len
    call    write_str
    jmp     .loop

; sys_write(fd=stdout, buf, count). Takes (rdi=buf, rsi=count) for ergonomics.
write_str:
    mov     rdx, rsi
    mov     rsi, rdi
    mov     rax, SYS_WRITE
    mov     rdi, FD_STDOUT
    syscall
    ret

; fd_selftest: open /dev/zero, read 1 byte, write "Z=" + hex byte + "\n",
; close. Demonstrates the full sys_open/read/write/close round-trip and gives
; CI a stable signal to assert against. Silent on open failure (CI catches the
; missing string).
fd_selftest:
    mov     rax, SYS_OPEN
    lea     rdi, [rel path_zero]
    xor     rsi, rsi
    syscall
    test    rax, rax
    js      .done
    mov     [rel st_fd], rax

    mov     rax, SYS_READ
    mov     rdi, [rel st_fd]
    lea     rsi, [rel st_byte]
    mov     rdx, 1
    syscall

    lea     rdi, [rel st_prefix]
    mov     rsi, 2
    call    write_str
    movzx   rdi, byte [rel st_byte]
    call    write_hex_byte
    lea     rdi, [rel st_newline]
    mov     rsi, 1
    call    write_str

    mov     rax, SYS_CLOSE
    mov     rdi, [rel st_fd]
    syscall
.done:
    ret

; mm_selftest: sys_mmap(1), write 0xAB to the returned page, read it back,
; print "M=AB\n", sys_munmap. Demonstrates that the bitmap allocator and the
; mmap/munmap syscalls round-trip correctly with real memory access.
mm_selftest:
    mov     rax, SYS_MMAP
    mov     rdi, 1
    syscall
    test    rax, rax
    js      .done                   ; -1 → bail silently (CI catches missing string)
    mov     [rel mm_addr], rax

    mov     rdi, [rel mm_addr]
    mov     byte [rdi], 0xAB
    movzx   rax, byte [rdi]
    mov     [rel mm_byte], al

    lea     rdi, [rel mm_prefix]
    mov     rsi, 2
    call    write_str
    movzx   rdi, byte [rel mm_byte]
    call    write_hex_byte
    lea     rdi, [rel st_newline]
    mov     rsi, 1
    call    write_str

    mov     rax, SYS_MUNMAP
    mov     rdi, [rel mm_addr]
    mov     rsi, 1
    syscall
.done:
    ret

; write_hex_byte(rdi=byte): writes 2 ASCII hex chars via sys_write to stdout.
write_hex_byte:
    push    rbx
    mov     rbx, rdi
    mov     rax, rbx
    shr     rax, 4
    and     al, 0x0F
    cmp     al, 10
    jl      .h_num
    add     al, 'A' - 10
    jmp     .h_done
.h_num:
    add     al, '0'
.h_done:
    mov     [rel st_hex], al
    mov     rax, rbx
    and     al, 0x0F
    cmp     al, 10
    jl      .l_num
    add     al, 'A' - 10
    jmp     .l_done
.l_num:
    add     al, '0'
.l_done:
    mov     [rel st_hex + 1], al
    lea     rdi, [rel st_hex]
    mov     rsi, 2
    call    write_str
    pop     rbx
    ret

section .data

prompt:     db "> "
prompt_len  equ $ - prompt

ctrl_c_indicator:     db "^C", 0x0A
ctrl_c_indicator_len  equ $ - ctrl_c_indicator

char_buf:   db 0
line_buf:   times LINE_BUF_SIZE db 0
line_len:   dq 0

path_zero:   db "/dev/zero", 0
st_prefix:   db "Z="
st_newline:  db 0x0A
st_fd:       dq 0
st_byte:     db 0
st_hex:      db 0, 0

mm_prefix:   db "M="
mm_addr:     dq 0
mm_byte:     db 0
