; File descriptor table. Parallel arrays of per-operation function pointers
; and an in-use flag, indexed by fd. Each per-fd function takes (rdi=buf,
; rsi=count) and returns rax = bytes consumed/produced, 0 = EOF, -1 = error.
; The boot fds (0/1/2) are wired up in init_fd; sys_open/sys_close (M8b)
; allocate further slots for /dev/null and /dev/zero.

[BITS 64]

global init_fd
global sys_open
global sys_close
global fd_read_fns
global fd_write_fns
global fd_close_fns
global fd_in_use

extern kbd_read
extern console_write

%define FD_TABLE_SIZE 16

section .data

;            (e.g., a write-only fd has read_fn = 0 and is not readable)
fd_read_fns:    times FD_TABLE_SIZE dq 0
fd_write_fns:   times FD_TABLE_SIZE dq 0
fd_close_fns:   times FD_TABLE_SIZE dq 0
fd_in_use:      times FD_TABLE_SIZE db 0

section .text

; Boot-time fd setup: 0 = keyboard (read-only), 1 = stdout, 2 = stderr
; (1 and 2 share the same console writer — both go to VGA + serial).
; close_fns are deliberately null for these — sys_close refuses to free
; the std fds anyway.
init_fd:
    lea     rax, [rel kbd_read]
    mov     [rel fd_read_fns + 0*8], rax
    mov     byte [rel fd_in_use + 0], 1

    lea     rax, [rel console_write]
    mov     [rel fd_write_fns + 1*8], rax
    mov     byte [rel fd_in_use + 1], 1

    mov     [rel fd_write_fns + 2*8], rax
    mov     byte [rel fd_in_use + 2], 1

    ret

; sys_open(const char *pathname, int flags) -> int fd or -1
; Recognized paths: /dev/null, /dev/zero. Anything else returns -1.
; flags is currently ignored (no O_RDONLY/O_WRONLY/O_CREAT etc.).
sys_open:
    push    rdi
    lea     rsi, [rel path_dev_null]
    call    strcmp
    test    rax, rax
    pop     rdi
    jnz     .try_zero
    lea     rax, [rel null_read]
    lea     rcx, [rel null_write]
    jmp     .alloc

.try_zero:
    push    rdi
    lea     rsi, [rel path_dev_zero]
    call    strcmp
    test    rax, rax
    pop     rdi
    jnz     .no_match
    lea     rax, [rel zero_read]
    lea     rcx, [rel zero_write]
    jmp     .alloc

.no_match:
    mov     rax, -1
    ret

.alloc:
    ; rax = read_fn, rcx = write_fn. Reserve a slot, then wire them in.
    push    rax
    push    rcx
    call    fd_alloc
    test    rax, rax
    js      .alloc_fail
    pop     rcx                     ; write_fn
    pop     rdx                     ; read_fn
    lea     r8, [rel fd_read_fns]
    mov     [r8 + rax*8], rdx
    lea     r8, [rel fd_write_fns]
    mov     [r8 + rax*8], rcx
    ret
.alloc_fail:
    add     rsp, 16                 ; discard pushed read_fn / write_fn
    mov     rax, -1
    ret

; sys_close(int fd) -> 0 on success, -1 on error.
; Refuses fd 0/1/2 — closing stdin/stdout/stderr would brick the shell since
; there's no way to reopen them.
sys_close:
    cmp     rdi, 3
    jb      .bad
    cmp     rdi, FD_TABLE_SIZE
    jae     .bad
    lea     rcx, [rel fd_in_use]
    cmp     byte [rcx + rdi], 0
    je      .bad
    mov     byte [rcx + rdi], 0
    lea     rcx, [rel fd_read_fns]
    mov     qword [rcx + rdi*8], 0
    lea     rcx, [rel fd_write_fns]
    mov     qword [rcx + rdi*8], 0
    lea     rcx, [rel fd_close_fns]
    mov     qword [rcx + rdi*8], 0
    xor     rax, rax
    ret
.bad:
    mov     rax, -1
    ret

; fd_alloc() -> rax: first free fd, or -1 if the table is full.
; Marks the chosen slot in_use; caller must populate the fn pointers.
fd_alloc:
    xor     rcx, rcx
    lea     r8, [rel fd_in_use]
.loop:
    cmp     rcx, FD_TABLE_SIZE
    jge     .full
    cmp     byte [r8 + rcx], 0
    je      .found
    inc     rcx
    jmp     .loop
.found:
    mov     byte [r8 + rcx], 1
    mov     rax, rcx
    ret
.full:
    mov     rax, -1
    ret

; strcmp(rdi=a, rsi=b) -> rax: 0 if equal, nonzero otherwise.
; Preserves rdi and rsi.
strcmp:
    push    rdi
    push    rsi
.loop:
    mov     al, [rdi]
    mov     dl, [rsi]
    cmp     al, dl
    jne     .ne
    test    al, al
    jz      .eq
    inc     rdi
    inc     rsi
    jmp     .loop
.eq:
    xor     rax, rax
    pop     rsi
    pop     rdi
    ret
.ne:
    mov     rax, 1
    pop     rsi
    pop     rdi
    ret

; null_read(buf, count) -> 0 (EOF). Discards buf/count.
null_read:
    xor     rax, rax
    ret

; null_write(buf, count) -> count (consumes silently).
null_write:
    mov     rax, rsi
    ret

; zero_read(buf, count) -> count. Fills buf with 0x00 bytes.
; Clobbers rdi, rcx, al — caller responsibility (handlers run inside the
; syscall path; user GPRs other than the syscall-clobber set don't survive).
zero_read:
    mov     rcx, rsi
    xor     al, al
    rep     stosb
    mov     rax, rsi
    ret

; zero_write(buf, count) -> count (consumes silently).
zero_write:
    mov     rax, rsi
    ret

section .data

path_dev_null: db "/dev/null", 0
path_dev_zero: db "/dev/zero", 0
