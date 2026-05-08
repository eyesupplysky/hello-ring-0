; Cooked-mode line shell. Runs in ring 3, talks to the kernel only via
; syscalls. Maintains a 128-byte line buffer; printable bytes append + echo
; per-keystroke; backspace decrements + echoes (kernel vga_putc handles the
; glyph erase) but is suppressed when the buffer is empty so it can't damage
; the prompt; LF commits the line, resets the buffer, and re-emits the prompt.

[BITS 64]

global shell_main

%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_EXIT        2
%define FD_STDIN        0
%define FD_STDOUT       1
%define LINE_BUF_SIZE   128

section .text

; Ring-3 entry. Prints initial prompt, then enters the cooked-mode line loop.
; process_line is a no-op stub on commit — future milestones (commands,
; parsing) hook in there.
shell_main:
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

; sys_write(fd=stdout, buf, count). Takes (rdi=buf, rsi=count) for ergonomics.
write_str:
    mov     rdx, rsi
    mov     rsi, rdi
    mov     rax, SYS_WRITE
    mov     rdi, FD_STDOUT
    syscall
    ret

section .data

prompt:     db "> "
prompt_len  equ $ - prompt

char_buf:   db 0
line_buf:   times LINE_BUF_SIZE db 0
line_len:   dq 0
