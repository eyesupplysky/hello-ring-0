; VGA text-mode driver. 80x25, char/attr pairs at 0xB8000. Cursor-tracking
; output (putc/puts) for normal kernel output, plus absolute-position helpers
; (_at) used by IRQ handlers that pin status indicators to fixed rows.

[BITS 64]

global vga_init
global vga_clear
global vga_set_attr
global vga_putc
global vga_puts
global vga_putc_at
global vga_puts_at
global vga_put_hex_byte_at

%define VGA_BUFFER          0xB8000
%define VGA_COLS            80
%define VGA_ROWS            25
%define VGA_ATTR_DEFAULT    0x07

section .data

vga_cursor_row: dq 0
vga_cursor_col: dq 0
vga_attr:       db VGA_ATTR_DEFAULT

section .text

; Reset cursor to (0,0) and attribute to default. Does NOT clear the screen
; — leaves whatever the BIOS / earlier stages wrote in place. Caller invokes
; vga_clear separately if they want a blank canvas.
vga_init:
    mov     byte [rel vga_attr], VGA_ATTR_DEFAULT
    mov     qword [rel vga_cursor_row], 0
    mov     qword [rel vga_cursor_col], 0
    ret

; Fill the entire VGA buffer with spaces using the current attribute.
vga_clear:
    mov     rdi, VGA_BUFFER
    mov     al, ' '
    mov     ah, [rel vga_attr]
    mov     rcx, VGA_COLS * VGA_ROWS
    rep     stosw
    ret

; Set the current attribute byte. dil = attribute (foreground|background<<4).
vga_set_attr:
    mov     [rel vga_attr], dil
    ret

; Internal: scroll buffer up by one row, clear last row, park cursor on it.
vga_scroll:
    mov     rdi, VGA_BUFFER
    mov     rsi, VGA_BUFFER + (VGA_COLS * 2)
    mov     rcx, VGA_COLS * (VGA_ROWS - 1)
    rep     movsw

    mov     rdi, VGA_BUFFER + (VGA_COLS * (VGA_ROWS - 1) * 2)
    mov     al, ' '
    mov     ah, [rel vga_attr]
    mov     rcx, VGA_COLS
    rep     stosw

    mov     qword [rel vga_cursor_row], VGA_ROWS - 1
    mov     qword [rel vga_cursor_col], 0
    ret

; Write one char at the cursor, advance, scroll on overflow. dil = char.
; Handles LF (0x0A) as newline and BS (0x08) as backspace.
vga_putc:
    cmp     dil, 10
    je      .newline
    cmp     dil, 8
    je      .backspace

    mov     rax, [rel vga_cursor_row]
    imul    rax, rax, VGA_COLS
    add     rax, [rel vga_cursor_col]
    shl     rax, 1
    add     rax, VGA_BUFFER
    mov     [rax], dil
    mov     dl, [rel vga_attr]
    mov     [rax + 1], dl

    inc     qword [rel vga_cursor_col]
    cmp     qword [rel vga_cursor_col], VGA_COLS
    jl      .done
    mov     qword [rel vga_cursor_col], 0
    inc     qword [rel vga_cursor_row]
    cmp     qword [rel vga_cursor_row], VGA_ROWS
    jl      .done
    call    vga_scroll
.done:
    ret

.newline:
    mov     qword [rel vga_cursor_col], 0
    inc     qword [rel vga_cursor_row]
    cmp     qword [rel vga_cursor_row], VGA_ROWS
    jl      .done
    call    vga_scroll
    ret

.backspace:
    cmp     qword [rel vga_cursor_col], 0
    je      .done
    dec     qword [rel vga_cursor_col]
    ret

; Print NUL-terminated string at cursor. rdi = str.
vga_puts:
    push    rbx
    mov     rbx, rdi
.loop:
    mov     dil, [rbx]
    test    dil, dil
    jz      .done
    call    vga_putc
    inc     rbx
    jmp     .loop
.done:
    pop     rbx
    ret

; Internal: compute VGA buffer address for (row, col). rsi = row, rdx = col.
; Returns address in rax. Clobbers rax only.
vga_addr_at:
    mov     rax, rsi
    imul    rax, rax, VGA_COLS
    add     rax, rdx
    shl     rax, 1
    add     rax, VGA_BUFFER
    ret

; Write char at absolute (row, col) with current attribute. Doesn't touch cursor.
; rdi = char, rsi = row, rdx = col.
vga_putc_at:
    push    rcx
    call    vga_addr_at
    mov     [rax], dil
    mov     cl, [rel vga_attr]
    mov     [rax + 1], cl
    pop     rcx
    ret

; Write NUL-terminated string at absolute (row, col). rdi = str, rsi = row, rdx = col.
vga_puts_at:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
.loop:
    mov     dil, [rbx]
    test    dil, dil
    jz      .done
    mov     rsi, r12
    mov     rdx, r13
    call    vga_putc_at
    inc     rbx
    inc     r13
    jmp     .loop
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; Render byte as 2 hex chars at absolute (row, col). rdi = byte, rsi = row, rdx = col.
vga_put_hex_byte_at:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx

    ; high nibble
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
    movzx   rdi, al
    mov     rsi, r12
    mov     rdx, r13
    call    vga_putc_at

    ; low nibble
    mov     rax, rbx
    and     al, 0x0F
    cmp     al, 10
    jl      .l_num
    add     al, 'A' - 10
    jmp     .l_done
.l_num:
    add     al, '0'
.l_done:
    movzx   rdi, al
    mov     rsi, r12
    lea     rdx, [r13 + 1]
    call    vga_putc_at

    pop     r13
    pop     r12
    pop     rbx
    ret
