; Line-echo shell. Runs in ring 3, talks to the kernel only via syscalls.
; Loop: read one byte from stdin, echo it to stdout, redraw the prompt after
; a newline. No history, no editing — backspace just moves the VGA cursor
; back without erasing (vga_putc behaviour).

[BITS 64]

global shell_main

%define SYS_READ    0
%define SYS_WRITE   1
%define SYS_EXIT    2
%define FD_STDIN    0
%define FD_STDOUT   1

section .text

; Ring-3 entry. Prints initial prompt, then enters the read/echo loop.
shell_main:
    lea     rdi, [rel prompt]
    mov     rsi, prompt_len
    call    write_str

.loop:
    ; Read one byte from stdin (blocks until a key is decoded).
    mov     rax, SYS_READ
    mov     rdi, FD_STDIN
    lea     rsi, [rel char_buf]
    mov     rdx, 1
    syscall

    ; Echo it.
    mov     rax, SYS_WRITE
    mov     rdi, FD_STDOUT
    lea     rsi, [rel char_buf]
    mov     rdx, 1
    syscall

    ; On newline, redraw the prompt.
    cmp     byte [rel char_buf], 0x0A
    jne     .loop

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
