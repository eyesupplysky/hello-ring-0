; Page-protection: kernel-text RO, kernel-data NX, user-half US=1, EFER.NXE.
;
; M11d turns on the CPU's NX honor bit (EFER.NXE) so the high bit of every
; PTE governs no-execute, then walks the loaded kernel image and stamps
; per-page protection on each leaf:
;
;   [0x100000, _etext)        — kernel .text   → P             (RO+exec, no US)
;   [_etext, _kdata_end)      — kernel .data   → P|RW|NX       (RW, no US)
;   [_kdata_end, _user_etext) — shell .text    → P|US          (RO+exec from ring 3)
;   [_user_etext, _kend_pg)   — shell .data    → P|RW|US|NX    (RW from ring 3, no exec)
;
; The four boundaries (_etext / _kdata_end / _user_etext) are page-aligned
; by kernel.ld so each range is a clean run of PTEs. _kernel_end is rounded
; up so the tail-padding of the loaded image is included in the user-data
; sweep.
;
; The user-half exists because the shell runs in ring 3 from the kernel
; image — without US=1 on its pages, the iretq into shell_main would
; instantly #PF on instruction fetch from a kernel page. Splitting the
; image into kernel and user halves at page granularity is what makes the
; per-page protection consistent with where the bytes were actually emitted.
;
; init_nx must run before init_page_protect because vm_protect propagates
; bit 63 (NX) into the PTE only when EFER.NXE = 1; otherwise bit 63 is
; reserved-must-be-zero and the CPU triggers #GP on access.
;
; pp_selftest verifies EFER.NXE is set, that vm_protect succeeds on a
; mapped page, and that vm_protect rejects an unmapped one. It does NOT
; trigger a fault to test enforcement — that needs longjmp recovery
; infrastructure we don't have. Real enforcement is exercised when any
; kernel/user code does the wrong thing and lands in handler_page_fault.

[BITS 64]

global init_nx
global init_page_protect
global pp_selftest

extern vm_protect
extern vga_puts_at
extern serial_puts
extern _etext
extern _kdata_end
extern _user_etext
extern _kernel_end

%define IA32_EFER           0xC0000080
%define EFER_NXE_BIT        (1 << 11)

%define PAGE_SIZE           0x1000
%define PAGE_MASK           (PAGE_SIZE - 1)
%define KERNEL_BASE         0x100000

%define PTE_P               0x001
%define PTE_RW              0x002
%define PTE_US              0x004
%define PTE_NX              0x8000000000000000

%define KTEXT_FLAGS         PTE_P
%define KDATA_FLAGS         (PTE_P | PTE_RW | PTE_NX)
%define UTEXT_FLAGS         (PTE_P | PTE_US)
%define UDATA_FLAGS         (PTE_P | PTE_RW | PTE_US | PTE_NX)

section .data

msg_pp_ok:         db "PP OK", 0
msg_pp_ok_serial:  db "PP OK", 0x0D, 0x0A, 0

section .text

; Enable EFER.NXE so PTE bit 63 honors no-execute. After this call, every
; subsequent vm_map_4k / vm_protect that sets bit 63 actually disables
; instruction fetch from the mapped page; before this call, bit 63 is
; reserved and any PTE with it set faults at access time.
init_nx:
    mov     ecx, IA32_EFER
    rdmsr
    or      eax, EFER_NXE_BIT
    wrmsr
    ret

; Walk the loaded kernel image PTEs and stamp protection across four
; ranges, each closed-open and page-aligned by the linker:
;   [KERNEL_BASE, _etext)        → KTEXT_FLAGS  (P,            no US)
;   [_etext, _kdata_end)         → KDATA_FLAGS  (P|RW|NX,      no US)
;   [_kdata_end, _user_etext)    → UTEXT_FLAGS  (P|US,         ring-3 RO+exec)
;   [_user_etext, _kend_pg)      → UDATA_FLAGS  (P|RW|US|NX,   ring-3 RW)
; vm_protect preserves the existing phys mapping and only swaps the flag
; bits; the call sequence is therefore safe to run from kernel .text itself
; (the CPU keeps executing through the protected page; the mutation is
; reflected by the next instruction fetch via the now-RO PTE, but RO
; doesn't block fetches).
init_page_protect:
    push    rbx
    push    r12

    mov     rbx, KERNEL_BASE
    lea     r12, [rel _etext]
.kt_loop:
    cmp     rbx, r12
    jge     .kd_phase
    mov     rdi, rbx
    mov     rsi, KTEXT_FLAGS
    call    vm_protect
    add     rbx, PAGE_SIZE
    jmp     .kt_loop

.kd_phase:
    lea     r12, [rel _kdata_end]
.kd_loop:
    cmp     rbx, r12
    jge     .ut_phase
    mov     rdi, rbx
    mov     rsi, KDATA_FLAGS
    call    vm_protect
    add     rbx, PAGE_SIZE
    jmp     .kd_loop

.ut_phase:
    lea     r12, [rel _user_etext]
.ut_loop:
    cmp     rbx, r12
    jge     .ud_phase
    mov     rdi, rbx
    mov     rsi, UTEXT_FLAGS
    call    vm_protect
    add     rbx, PAGE_SIZE
    jmp     .ut_loop

.ud_phase:
    lea     r12, [rel _kernel_end]
    add     r12, PAGE_MASK
    and     r12, ~PAGE_MASK
.ud_loop:
    cmp     rbx, r12
    jge     .done
    mov     rdi, rbx
    mov     rsi, UDATA_FLAGS
    call    vm_protect
    add     rbx, PAGE_SIZE
    jmp     .ud_loop
.done:
    pop     r12
    pop     rbx
    ret

; pp_selftest: verify EFER.NXE is set, vm_protect succeeds on a mapped
; virt (kernel base), vm_protect rejects an unmapped virt (2 GiB — well
; outside both the boot identity map and the user-VA range). Prints "PP
; OK" at row 21 col 0 and to serial. Does not trigger or recover from a
; real fault — that's what handler_page_fault is for in production.
pp_selftest:
    push    rbx

    mov     ecx, IA32_EFER
    rdmsr
    test    eax, EFER_NXE_BIT
    jz      .fail

    mov     rdi, KERNEL_BASE
    mov     rsi, KTEXT_FLAGS
    call    vm_protect
    test    rax, rax
    jnz     .fail

    mov     rdi, 0x80000000
    mov     rsi, PTE_P
    call    vm_protect
    cmp     rax, -1
    jne     .fail

    lea     rdi, [rel msg_pp_ok]
    mov     rsi, 21
    mov     rdx, 0
    call    vga_puts_at
    lea     rdi, [rel msg_pp_ok_serial]
    call    serial_puts

    pop     rbx
    ret
.fail:
    pop     rbx
    ret
