; Common ISR dispatcher: saves all GPRs, looks up the per-vector handler from
; the handler table, calls it, restores GPRs, drops vector + error code, iretq.
; Also owns the handler table memory and the boot-time init helpers.

[BITS 64]

global isr_common
global init_interrupts
global set_isr

extern init_idt
extern default_handler
extern handler_div_by_zero
extern handler_page_fault
extern handler_irq0
extern handler_irq1

%define HANDLER_TABLE_ADDR   0x111000
%define HANDLER_TABLE_BYTES  (256 * 8)

section .text

; CPU stack on entry to a stub: [SS, RSP, RFLAGS, CS, RIP, error_code, vector].
; After saving 15 GPRs, vector lives at [rsp + 15*8].
isr_common:
    push    rax
    push    rcx
    push    rdx
    push    rbx
    push    rbp
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r10
    push    r11
    push    r12
    push    r13
    push    r14
    push    r15

    mov     rdi, [rsp + 15 * 8]                 ; vector number = first arg

    mov     rax, HANDLER_TABLE_ADDR
    mov     rax, [rax + rdi * 8]
    call    rax

    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rbp
    pop     rbx
    pop     rdx
    pop     rcx
    pop     rax

    add     rsp, 16                             ; drop vector + error code
    iretq

; Override one entry in the handler table.
set_isr:
    ; rdi = vector, rsi = handler address
    mov     rax, HANDLER_TABLE_ADDR
    mov     [rax + rdi * 8], rsi
    ret

; Boot-time interrupt initialization. Zeroes handler table, fills it with
; default_handler, populates the IDT, then registers real handlers.
init_interrupts:
    push    rbx

    ; Fill handler table with default_handler.
    mov     rdi, HANDLER_TABLE_ADDR
    lea     rax, [rel default_handler]
    mov     rcx, 256
.fill:
    mov     [rdi], rax
    add     rdi, 8
    dec     rcx
    jnz     .fill

    ; Populate IDT gates from the stub table.
    call    init_idt

    ; Register real handlers.
    mov     rdi, 0                              ; vector 0 = #DE
    lea     rsi, [rel handler_div_by_zero]
    call    set_isr

    mov     rdi, 14                             ; vector 14 = #PF (M11d)
    lea     rsi, [rel handler_page_fault]
    call    set_isr

    mov     rdi, 0x20                           ; vector 0x20 = IRQ0 (PIT)
    lea     rsi, [rel handler_irq0]
    call    set_isr

    mov     rdi, 0x21                           ; vector 0x21 = IRQ1 (PS/2 keyboard)
    lea     rsi, [rel handler_irq1]
    call    set_isr

    pop     rbx
    ret
