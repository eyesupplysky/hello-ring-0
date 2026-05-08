; Kernel entry. M4a boot sequence: VGA + serial init, GDT, TSS, IDT/handlers,
; PIC, PIT, PS/2, then iretq to ring 3 to run user_test_entry. From here on
; the kernel only runs in interrupt handlers (entered via TSS.RSP0).

[BITS 64]

global _start

extern init_gdt
extern init_tss
extern init_interrupts
extern init_pic
extern init_pit
extern init_kbd
extern init_syscall
extern init_fd
extern init_frame
extern init_kheap
extern kheap_selftest
extern init_vm
extern vm_selftest
extern init_vm_space
extern vm_space_selftest
extern init_user_vm
extern um_selftest
extern init_nx
extern init_page_protect
extern pp_selftest
extern vga_init
extern vga_puts_at
extern serial_init
extern serial_puts
extern shell_main

%define USER_DATA_SEL    (0x18 | 3)
%define USER_CODE_SEL    (0x20 | 3)
%define USER_STACK_TOP   0x60000
%define RFLAGS_INIT      0x202                  ; reserved bit 1 + IF (bit 9)

section .text

; Kernel entry. Long mode active, identity-mapped 0..2 MB with U/S=1.
_start:
    call    vga_init
    call    serial_init

    call    init_gdt
    call    init_tss
    call    init_interrupts
    call    init_pic
    call    init_pit
    call    init_kbd
    call    init_syscall
    call    init_fd
    call    init_frame
    call    init_kheap
    call    kheap_selftest
    call    init_vm
    call    vm_selftest
    call    init_vm_space
    call    vm_space_selftest
    call    init_user_vm
    call    um_selftest
    call    init_nx
    call    init_page_protect
    call    pp_selftest

    lea     rdi, [rel msg_k_ok]
    mov     rsi, 14
    mov     rdx, 0
    call    vga_puts_at

    lea     rdi, [rel msg_k_ok_serial]
    call    serial_puts

    ; Build the iretq frame and jump to ring 3. iretq atomically loads CS/SS/
    ; RFLAGS/RIP/RSP and switches CPL — no need for a separate sti.
    push    qword USER_DATA_SEL
    push    qword USER_STACK_TOP
    push    qword RFLAGS_INIT
    push    qword USER_CODE_SEL
    lea     rax, [rel shell_main]
    push    rax
    iretq

.unreached:
    cli
    hlt
    jmp     .unreached

msg_k_ok:        db "K OK", 0
msg_k_ok_serial: db "K OK", 0x0D, 0x0A, 0
