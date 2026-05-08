; vm_space_t address-space management. Wraps one PML4 plus bookkeeping
; and lets the kernel mint, switch between, and tear down address spaces
; with kernel-half-only inheritance.
;
; M12 lands real per-space isolation. vm_space_create allocates a fresh
; PML4 + PDPT + PD per space. The new PD[0] entry is copied verbatim
; from the boot PD's PD[0] — which points at the boot PT identity-mapping
; phys [0, 2 MiB) — so every space sees the kernel image, page tables,
; frame pool, etc., transparently. Every other PD entry starts empty;
; vm_map_4k installs PT pages on demand into PD[1..511], so user-range
; mappings (PD[4..7]) are this-space-only and don't leak across spaces.
;
; vm_space_destroy walks PML4[0]→PDPT[0]→PD and frees every PT page in
; PD[1..511] along with the leaf frames they map. PD[0] is skipped — its
; child is the shared boot PT, alive for the kernel's lifetime. PD, PDPT,
; and PML4 are then returned to frame_free, and the struct to kfree.
;
; vm_space_t layout (32 bytes, kmalloc'd at align 16):
;   +0x00  pml4_phys     phys addr of this space's PML4 (page-aligned)
;   +0x08  refcount      caller-managed; vm_space_destroy decrements first
;   +0x10  reserved      future fields
;   +0x18  reserved      future fields
;
; The boot kernel's address space is exposed as boot_vm_space — a static
; singleton initialized by init_vm_space. Its refcount is sentinel -1 so
; vm_space_destroy never frees it; any attempt to destroy underflows
; toward -2, never reaching 0. (boot_vm_space's PML4 is the boot PML4
; built in stage2; its PDPT/PD/PT subtree is shared by every vm_space
; created at runtime via PD[0], and must outlive them all.)

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
extern zero_frame
extern vm_map_4k
extern vm_unmap_4k
extern vm_walk
extern vga_puts_at
extern serial_puts

%define VS_OFFSET_PML4      0
%define VS_OFFSET_REFCOUNT  8
%define VS_SIZE             32
%define VS_ALIGN            16

%define VM_FLAG_RW          0x002
%define VM_INTERMEDIATE     0x007                       ; P|RW|US for intermediate tables
%define VM_ADDR_MASK        0x000FFFFFFFFFF000          ; PTE bits [51:12] = phys frame addr

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

; vm_space_create() -> rax: vm_space_t* or 0 on OOM. Allocates the struct
; from kheap, then three fresh frames (PML4, PDPT, PD), each zeroed.
; Wires PML4[0] → PDPT, PDPT[0] → PD, and copies boot PD[0] verbatim into
; the new PD[0] so the new space inherits the [0, 2 MiB) identity map (and
; with it the kernel image, IDT, page tables, frame pool, kheap pages, etc.)
; by sharing the boot PT. Every other PML4 / PDPT / PD entry stays zero;
; vm_map_4k installs PT pages on demand into PD[1..511], keeping any
; non-identity-map mapping this-space-only.
;
; On any OOM step, fully unwinds: returns previously allocated frames /
; struct, returns 0.
vm_space_create:
    push    rbx                         ; struct ptr
    push    r12                         ; pml4 phys
    push    r13                         ; pdpt phys
    push    r14                         ; pd phys

    mov     rdi, VS_SIZE
    mov     rsi, VS_ALIGN
    call    kmalloc
    test    rax, rax
    jz      .oom_struct
    mov     rbx, rax

    mov     rdi, 1
    call    frames_alloc_n
    test    rax, rax
    jz      .oom_pml4
    mov     r12, rax
    mov     rdi, r12
    call    zero_frame

    mov     rdi, 1
    call    frames_alloc_n
    test    rax, rax
    jz      .oom_pdpt
    mov     r13, rax
    mov     rdi, r13
    call    zero_frame

    mov     rdi, 1
    call    frames_alloc_n
    test    rax, rax
    jz      .oom_pd
    mov     r14, rax
    mov     rdi, r14
    call    zero_frame

    mov     rax, r13
    or      rax, VM_INTERMEDIATE
    mov     [r12], rax                  ; new PML4[0] -> new PDPT (P|RW|US)

    mov     rax, r14
    or      rax, VM_INTERMEDIATE
    mov     [r13], rax                  ; new PDPT[0] -> new PD (P|RW|US)

    mov     rax, [rel boot_pml4_phys]
    mov     rcx, VM_ADDR_MASK
    mov     rdx, [rax]                  ; boot PML4[0]
    and     rdx, rcx                    ; -> boot PDPT phys
    mov     rdx, [rdx]                  ; boot PDPT[0]
    and     rdx, rcx                    ; -> boot PD phys
    mov     rdx, [rdx]                  ; boot PD[0] entry (incl. flags)
    mov     [r14], rdx                  ; new PD[0] = boot PD[0]

    mov     [rbx + VS_OFFSET_PML4], r12
    mov     qword [rbx + VS_OFFSET_REFCOUNT], 1

    mov     rax, rbx
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.oom_pd:
    mov     rdi, r13
    mov     rsi, 1
    call    frames_free_n
.oom_pdpt:
    mov     rdi, r12
    mov     rsi, 1
    call    frames_free_n
.oom_pml4:
    mov     rdi, rbx
    call    kfree
.oom_struct:
    xor     rax, rax
    pop     r14
    pop     r13
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

; vm_space_destroy(rdi=vm_space_t*): decrement refcount; if it hits 0,
; tear down this space's private page-table tree and free the struct.
;
; The walk frees, for each present PD[i] with i in 1..511 (PD[0] is the
; shared boot PT — never freed): every present PT entry's leaf frame
; (the user-mapped page), then the PT page itself. Then the PD page,
; the PDPT page, the PML4 page, and finally kfree the struct.
;
; boot_vm_space's sentinel refcount (-1) underflows toward -2 — never 0
; — so the boot space is safe to pass through here without any teardown.
;            this; future kernel-side vm_map_4k that extends them must update this walk
vm_space_destroy:
    mov     rax, [rdi + VS_OFFSET_REFCOUNT]
    dec     rax
    mov     [rdi + VS_OFFSET_REFCOUNT], rax
    test    rax, rax
    jnz     .keep

    push    rbx                         ; struct ptr
    push    r12                         ; pml4 phys
    push    r13                         ; pdpt phys
    push    r14                         ; pd phys
    push    r15                         ; pd index

    mov     rbx, rdi
    mov     r12, [rbx + VS_OFFSET_PML4]

    mov     rax, [r12]                  ; PML4[0]
    test    rax, 1
    jz      .free_pml4
    mov     rcx, VM_ADDR_MASK
    and     rax, rcx
    mov     r13, rax

    mov     rax, [r13]                  ; PDPT[0]
    test    rax, 1
    jz      .free_pdpt
    mov     rcx, VM_ADDR_MASK
    and     rax, rcx
    mov     r14, rax

    mov     r15, 1                      ; iterate PD[1..511] — PD[0] is shared boot PT
.pd_loop:
    cmp     r15, 512
    jae     .free_pd
    mov     rax, [r14 + r15*8]
    test    rax, 1
    jz      .next_pd

    mov     rcx, VM_ADDR_MASK
    and     rax, rcx                    ; pt_phys
    push    rax
    xor     rcx, rcx
.pt_loop:
    cmp     rcx, 512
    jae     .pt_done
    mov     rax, [rsp]                  ; pt_phys (preserved across rcx push)
    mov     rax, [rax + rcx*8]
    test    rax, 1
    jz      .pt_next

    push    rcx
    mov     rcx, VM_ADDR_MASK
    and     rax, rcx
    mov     rdi, rax
    mov     rsi, 1
    call    frames_free_n               ; free leaf frame
    pop     rcx
.pt_next:
    inc     rcx
    jmp     .pt_loop
.pt_done:
    pop     rdi                         ; pt_phys
    mov     rsi, 1
    call    frames_free_n               ; free PT page
.next_pd:
    inc     r15
    jmp     .pd_loop

.free_pd:
    mov     rdi, r14
    mov     rsi, 1
    call    frames_free_n
.free_pdpt:
    mov     rdi, r13
    mov     rsi, 1
    call    frames_free_n
.free_pml4:
    mov     rdi, r12
    mov     rsi, 1
    call    frames_free_n

    mov     rdi, rbx
    call    kfree

    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
.keep:
    ret

; vm_space_selftest: kernel-side, runs once at boot after init_vm_space.
; Verifies create / switch / CR3 swap / inherited identity map / destroy
; (M11b coverage), then exercises M12's per-space isolation: maps a virt
; outside the boot identity range in the new space, switches to boot,
; confirms vm_walk reports unmapped (= the new mapping did not leak),
; switches back, confirms the mapping survived the round-trip, unmaps,
; frees, destroys. Prints "VS OK" only on full success; on any failure
; the marker is omitted and CI sees the missing string.
vm_space_selftest:
    push    rbx
    push    r12                         ; new vm_space*
    push    r13                         ; boot vm_space*
    push    r14                         ; boot pml4 phys (snapshot from CR3)
    push    r15                         ; F_A: phys frame backing the test mapping

    mov     rax, cr3
    mov     r14, rax

    call    vm_space_create
    test    rax, rax
    jz      .fail
    mov     r12, rax

    call    get_boot_vm_space
    mov     r13, rax

    mov     rdi, 1
    call    frames_alloc_n
    test    rax, rax
    jz      .fail_after_create
    mov     r15, rax

    mov     rdi, r12
    call    vm_space_switch

    mov     rax, cr3
    mov     rbx, [r12 + VS_OFFSET_PML4]
    cmp     rax, rbx
    jne     .fail_after_map
    cmp     rax, r14
    je      .fail_after_map

    mov     rax, [0x100000]             ; inherited identity map: kernel image readable
    test    rax, rax
    jz      .fail_after_map

    mov     rdi, 0x800000
    mov     rsi, r15
    mov     rdx, VM_FLAG_RW
    call    vm_map_4k
    test    rax, rax
    jnz     .fail_after_map

    mov     rax, 0xC0FFEEFEEDFACE12
    mov     [0x800000], rax

    mov     rdi, r13
    call    vm_space_switch
    mov     rax, cr3
    cmp     rax, r14
    jne     .fail_after_map

    mov     rdi, 0x800000
    call    vm_walk
    test    rax, rax
    jnz     .fail_after_map             ; isolation broken: boot saw new space's leaf

    mov     rdi, r12
    call    vm_space_switch
    mov     rax, [0x800000]
    mov     rbx, 0xC0FFEEFEEDFACE12
    cmp     rax, rbx
    jne     .fail_after_map

    mov     rdi, 0x800000
    call    vm_unmap_4k
    test    rax, rax
    jnz     .fail_after_map

    mov     rdi, r13
    call    vm_space_switch
    mov     rax, cr3
    cmp     rax, r14
    jne     .fail_after_F

    mov     rdi, r15
    mov     rsi, 1
    call    frames_free_n

    mov     rdi, r12
    call    vm_space_destroy

    lea     rdi, [rel msg_vs_ok]
    mov     rsi, 17
    mov     rdx, 0
    call    vga_puts_at
    lea     rdi, [rel msg_vs_ok_serial]
    call    serial_puts

    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.fail_after_map:
    mov     rdi, r12
    call    vm_space_switch
    mov     rdi, 0x800000
    call    vm_unmap_4k
.fail_after_F:
    mov     rdi, r13
    call    vm_space_switch
    mov     rdi, r15
    mov     rsi, 1
    call    frames_free_n
.fail_after_create:
    mov     rdi, r12
    call    vm_space_destroy
.fail:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
