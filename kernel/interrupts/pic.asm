; 8259 PIC remap and helpers. Master IRQs 0-7 -> vectors 0x20-0x27, slave
; IRQs 8-15 -> 0x28-0x2F (away from CPU exception range 0x00-0x1F).

[BITS 64]

global init_pic
global pic_send_eoi
global pic_unmask_irq

%define PIC1_CMD    0x20
%define PIC1_DATA   0x21
%define PIC2_CMD    0xA0
%define PIC2_DATA   0xA1

%define ICW1_INIT   0x11        ; init + ICW4 needed + cascade
%define ICW4_8086   0x01        ; 8086 mode, normal EOI
%define PIC_EOI     0x20

section .text

; Short delay via dummy write to port 0x80. Some real BIOSes need this
; between PIC writes; on QEMU it's harmless.
io_wait:
    push    rax
    xor     al, al
    out     0x80, al
    pop     rax
    ret

; Remap both PICs and mask all IRQs. Caller unmasks specific lines via
; pic_unmask_irq once the corresponding handler is registered.
init_pic:
    mov     al, ICW1_INIT
    out     PIC1_CMD, al
    call    io_wait
    out     PIC2_CMD, al
    call    io_wait

    mov     al, 0x20                ; ICW2 master: vector base 0x20
    out     PIC1_DATA, al
    call    io_wait
    mov     al, 0x28                ; ICW2 slave: vector base 0x28
    out     PIC2_DATA, al
    call    io_wait

    mov     al, 0x04                ; ICW3 master: slave at IRQ2
    out     PIC1_DATA, al
    call    io_wait
    mov     al, 0x02                ; ICW3 slave: cascade ID 2
    out     PIC2_DATA, al
    call    io_wait

    mov     al, ICW4_8086
    out     PIC1_DATA, al
    call    io_wait
    out     PIC2_DATA, al
    call    io_wait

    mov     al, 0xFF                ; OCW1 mask all
    out     PIC1_DATA, al
    out     PIC2_DATA, al
    ret

; End-of-interrupt for an IRQ. For IRQs >= 8, must EOI both slave and master.
pic_send_eoi:
    ; rdi = IRQ number (0-15)
    cmp     rdi, 8
    jl      .master_only
    mov     al, PIC_EOI
    out     PIC2_CMD, al
.master_only:
    mov     al, PIC_EOI
    out     PIC1_CMD, al
    ret

; Clear the mask bit for one IRQ on its PIC.
pic_unmask_irq:
    ; rdi = IRQ number (0-15)
    mov     ecx, edi
    cmp     rdi, 8
    jl      .master
    sub     ecx, 8
    in      al, PIC2_DATA
    mov     dl, 1
    shl     dl, cl
    not     dl
    and     al, dl
    out     PIC2_DATA, al
    ret
.master:
    in      al, PIC1_DATA
    mov     dl, 1
    shl     dl, cl
    not     dl
    and     al, dl
    out     PIC1_DATA, al
    ret
