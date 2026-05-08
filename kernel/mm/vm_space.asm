; vm_space_t address-space management. Wraps one PML4 plus bookkeeping
; and lets the kernel mint, switch between, and tear down address spaces.
; M11b is the foundation: data structure + interface + CR3 swap. Per-space
; isolation is partial here — vm_space_create memcpy's the boot PML4
; entries, so all spaces share the PDPT/PD/PT tree by reference. M11c
; will own real isolation when sys_mmap carves a user VA range and decides
; which level to copy-on-write (or, eventually, when higher-half kernel
; lands).
;
; vm_space_t layout (32 bytes, kmalloc'd at align 16):
;   +0x00  pml4_phys     phys addr of this space's PML4 (page-aligned)
;   +0x08  refcount      caller-managed; vm_space_destroy decrements first
;   +0x10  reserved      future PT-page list head (M11c+)
;   +0x18  reserved      future fields
;
; The boot kernel's address space is exposed as boot_vm_space — a static
; singleton initialized by init_vm_space. Its refcount is sentinel -1 so
; vm_space_destroy never frees it; any attempt to destroy underflows
; toward -2, never reaching 0.

[BITS 64]

global init_vm_space
global vm_space_create
global vm_space_destroy
global vm_space_switch
global get_boot_vm_space
global vm_space_selftest

extern boot_pml4_phys
extern frames_alloc_n
extern frames_free_n
extern kmalloc
extern kfree
extern vga_puts_at
extern serial_puts

%define VS_OFFSET_PML4      0
%define VS_OFFSET_REFCOUNT  8
%define VS_SIZE             32
%define VS_ALIGN            16

section .data

; The boot kernel address-space singleton. Sits in .data (not kheap) so
; it's available before init_kheap consumers run. Sentinel refcount = -1
; means vm_space_destroy never frees it (decrement underflows away from 0).
boot_vm_space:
    dq 0
    dq -1
    dq 0
    dq 0

msg_vs_ok:         db "VS OK", 0
msg_vs_ok_serial:  db "VS OK", 0x0D, 0x0A, 0

section .text

; Populate boot_vm_space.pml4_phys from the value init_vm stashed in
; boot_pml4_phys. Allocates nothing.
init_vm_space:
    mov     rax, [rel boot_pml4_phys]
    mov     [rel boot_vm_space + VS_OFFSET_PML4], rax
    ret

; get_boot_vm_space() -> rax: pointer to the boot kernel address space
; singleton. Stable across the kernel's lifetime; never freed.
get_boot_vm_space:
    lea     rax, [rel boot_vm_space]
    ret

; vm_space_create() -> rax: vm_space_t* or 0 on OOM. Allocates a struct
; from kheap, allocates a PML4 frame, memcpy's the boot PML4 entries into
; it (so kernel mappings are inherited by reference through the shared
; PDPTs), and returns the struct with refcount = 1.
vm_space_create:
    push    rbx
    push    r12

    mov     rdi, VS_SIZE
    mov     rsi, VS_ALIGN
    call    kmalloc
    test    rax, rax
    jz      .oom
    mov     rbx, rax

    mov     rdi, 1
    call    frames_alloc_n
    test    rax, rax
    jz      .oom_free_struct
    mov     r12, rax

    mov     rdi, r12
    mov     rsi, [rel boot_pml4_phys]
    mov     rcx, 512
    cld
    rep     movsq

    mov     [rbx + VS_OFFSET_PML4], r12
    mov     qword [rbx + VS_OFFSET_REFCOUNT], 1

    mov     rax, rbx
    pop     r12
    pop     rbx
    ret
.oom_free_struct:
    mov     rdi, rbx
    call    kfree
.oom:
    xor     rax, rax
    pop     r12
    pop     rbx
    ret

; vm_space_switch(rdi=vm_space_t*): load CR3 from the struct's pml4_phys.
; The CR3 write triggers a full TLB flush (we don't use the global-page
; bit). After this returns, all vm_map_4k / vm_walk / memory accesses go
; through the new PML4.
vm_space_switch:
    mov     rax, [rdi + VS_OFFSET_PML4]
    mov     cr3, rax
    ret

; vm_space_destroy(rdi=vm_space_t*): decrement refcount; if it reaches 0,
; free the PML4 frame and kfree the struct. boot_vm_space's sentinel
; refcount (-1) underflows toward -2 — never 0 — so the boot space is
; safe to pass through here.
;
; M11b does NOT walk the per-space PDPT/PD/PT tree: those pages are
; shared across spaces today (vm_space_create memcpy's PML4 entries
; verbatim, so child tables are referenced by all spaces that descend
; from the boot PML4). M11c will own per-space PT bookkeeping when
; sys_mmap carves real user VA.
vm_space_destroy:
    mov     rax, [rdi + VS_OFFSET_REFCOUNT]
    dec     rax
    mov     [rdi + VS_OFFSET_REFCOUNT], rax
    test    rax, rax
    jnz     .keep

    push    rbx
    mov     rbx, rdi

    mov     rdi, [rbx + VS_OFFSET_PML4]
    mov     rsi, 1
    call    frames_free_n

    mov     rdi, rbx
    call    kfree
    pop     rbx
.keep:
    ret

; vm_space_selftest: kernel-side, runs once at boot after init_vm_space.
; Snapshots CR3, creates a fresh vm_space, switches to it, verifies CR3
; reflects the new PML4 phys (and is distinct from the original), reads
; the kernel image at 0x100000 to confirm the inherited identity map
; still resolves, switches back, verifies CR3 restored to the original,
; destroys the space. Prints "VS OK" only on full success.
vm_space_selftest:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     rax, cr3
    mov     r14, rax

    call    vm_space_create
    test    rax, rax
    jz      .fail
    mov     r12, rax

    call    get_boot_vm_space
    mov     r13, rax

    mov     rdi, r12
    call    vm_space_switch

    mov     rax, cr3
    mov     rbx, [r12 + VS_OFFSET_PML4]
    cmp     rax, rbx
    jne     .fail_restore
    cmp     rax, r14
    je      .fail_restore

    mov     rax, [0x100000]
    test    rax, rax
    jz      .fail_restore

    mov     rdi, r13
    call    vm_space_switch

    mov     rax, cr3
    cmp     rax, r14
    jne     .fail_destroy

    mov     rdi, r12
    call    vm_space_destroy

    lea     rdi, [rel msg_vs_ok]
    mov     rsi, 17
    mov     rdx, 0
    call    vga_puts_at
    lea     rdi, [rel msg_vs_ok_serial]
    call    serial_puts

    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.fail_restore:
    mov     rdi, r13
    call    vm_space_switch
.fail_destroy:
    mov     rdi, r12
    call    vm_space_destroy
.fail:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
