; Cooked-mode line shell. Runs in ring 3, talks to the kernel only via
; syscalls. Maintains a 128-byte line buffer; printable bytes append + echo
; per-keystroke; backspace decrements + echoes (kernel vga_putc handles the
; glyph erase) but is suppressed when the buffer is empty so it can't damage
; the prompt; Ctrl+C drops the in-flight line and emits "^C" + a fresh prompt;
; LF commits the line, resets the buffer, and re-emits the prompt.
;
; Lives in .user_text / .user_data — sections kernel.ld places past the
; kernel image's W^X-stamped range. M11d's init_page_protect stamps these
; pages with US=1 so ring 3 can fetch shell code and read/write shell data;
; without that, the iretq into shell_main would #PF on the first instruction
; fetch from a US=0 .text page.

[BITS 64]

global shell_main

extern child_main

%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_EXIT        2
%define SYS_OPEN        3
%define SYS_CLOSE       4
%define SYS_MMAP        5
%define SYS_MUNMAP      6
%define SYS_YIELD       7
%define SYS_SPAWN       8
%define SYS_GETPID      9
%define FD_STDIN        0
%define FD_STDOUT       1
%define LINE_BUF_SIZE   128

section .user_text

; Ring-3 entry. Prints initial prompt, then enters the cooked-mode line loop.
; process_line is a no-op stub on commit — future milestones (commands,
; parsing) hook in there.
shell_main:
    call    fd_selftest
    call    mm_selftest
    call    process_selftest
    call    yield_selftest
    call    spawn_selftest
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

; spawn_selftest: M13c — sys_spawn(child_main), then sys_yield. The child
; runs in its own vm_space, writes "C OK\n" via sys_write, calls sys_exit;
; sys_exit unlinks the child and switches back here, where sys_yield's
; reaper frees the child's resources. We then print "S OK\n" — the parent
; survived the round-trip and the cooperative ready list collapsed back to
; a singleton.
spawn_selftest:
    mov     rax, SYS_SPAWN
    lea     rdi, [rel child_main]
    syscall
    test    rax, rax
    js      .done                   ; spawn failed — bail silently (CI catches missing string)

    mov     rax, SYS_YIELD
    syscall

    lea     rdi, [rel s_ok_msg]
    mov     rsi, s_ok_msg_len
    call    write_str
.done:
    ret

; yield_selftest: M13b — sys_yield to ourselves and verify SystemV
; callee-saved registers (RBX, RBP, R12-R15) survive the round-trip through
; context_switch. If any sentinel reads back wrong, "Y OK" is suppressed and
; CI catches the missing string. The test exercises the full chain
; (syscall -> syscall_entry stack swap -> sys_yield -> context_switch save +
; restore -> sysretq) with one process, so any save-area mismatch surfaces
; here before M13c stresses the same code path with a real second process.
yield_selftest:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15

    mov     rbx, 0x1111111122222222
    mov     rbp, 0x3333333344444444
    mov     r12, 0x5555555566666666
    mov     r13, 0x7777777788888888
    mov     r14, 0x99999999AAAAAAAA
    mov     r15, 0xBBBBBBBBCCCCCCCC

    mov     rax, SYS_YIELD
    syscall

    mov     rax, 0x1111111122222222
    cmp     rbx, rax
    jne     .done
    mov     rax, 0x3333333344444444
    cmp     rbp, rax
    jne     .done
    mov     rax, 0x5555555566666666
    cmp     r12, rax
    jne     .done
    mov     rax, 0x7777777788888888
    cmp     r13, rax
    jne     .done
    mov     rax, 0x99999999AAAAAAAA
    cmp     r14, rax
    jne     .done
    mov     rax, 0xBBBBBBBBCCCCCCCC
    cmp     r15, rax
    jne     .done

    lea     rdi, [rel y_ok_msg]
    mov     rsi, y_ok_msg_len
    call    write_str
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; process_selftest: sys_getpid, write "P=" + pid as 2 hex digits + "\n".
; M13a: only the boot process exists, so the expected output is "P=00".
; CI asserts that string on VGA + serial.
process_selftest:
    mov     rax, SYS_GETPID
    syscall
    mov     [rel pid_byte], al

    lea     rdi, [rel pid_prefix]
    mov     rsi, 2
    call    write_str
    movzx   rdi, byte [rel pid_byte]
    call    write_hex_byte
    lea     rdi, [rel st_newline]
    mov     rsi, 1
    call    write_str
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

section .user_data

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

pid_prefix:  db "P="
pid_byte:    db 0

y_ok_msg:    db "Y OK", 0x0A
y_ok_msg_len equ $ - y_ok_msg

s_ok_msg:    db "S OK", 0x0A
s_ok_msg_len equ $ - s_ok_msg
