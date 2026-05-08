; User-VA range allocator and the real sys_mmap / sys_munmap implementations.
; Carves a fixed virt window [0x800000, 0x1000000) — 8 MiB / 2048 pages —
; out of the boot PML4 below the canonical user/kernel boundary, and
; hands out contiguous virt runs backed by scattered physical frames.
;
; Layout:
;   USER_VA_BASE = 0x00800000   (8 MiB; PD[4] under PML4[0]→PDPT[0])
;   USER_VA_END  = 0x01000000   (16 MiB)
;   USER_VA_PAGES = 2048        (8 MiB / 4 KiB)
;   user_va_bitmap = 256 bytes  (bit i = 1 means page i is mapped)
;
; sys_mmap allocates `count` consecutive bits in the user-VA bitmap, then
; for each page calls frame_alloc(1) + vm_map_4k(virt, phys, P|RW|US).
; Phys frames are NOT contiguous — only the virt range is. Any failure
; mid-loop fully rolls back: every page already mapped is vm_unmap_4k'd
; and its frame freed, then the bitmap range is released.
;
; sys_munmap walks the page-table tree to recover each page's phys, frees
; the frame, unmaps the page, and clears the bitmap range. Out-of-range
; addresses are rejected; partial unmaps (count smaller than the original
; mapping) are fine — the bitmap is per-page.
;
; The user-VA range is shared across all vm_spaces in M11c because every
; vm_space inherits the boot PML4 verbatim and PD[4]'s child PT is
; therefore shared. Real per-process isolation lands when M11c+ unwinds
; the verbatim-PML4-copy in vm_space_create.

[BITS 64]

global init_user_vm
global sys_mmap
global sys_munmap
global um_selftest

extern frames_alloc_n
extern frames_free_n
extern vm_map_4k
extern vm_unmap_4k
extern vm_walk
extern vga_puts_at
extern serial_puts

%define USER_VA_BASE        0x00800000
%define USER_VA_END         0x01000000
%define USER_VA_PAGES       2048
%define USER_VA_BITMAP_BYTES (USER_VA_PAGES / 8)
%define FRAME_SIZE          0x1000
%define VM_FLAG_RW          0x002
%define VM_FLAG_US          0x004
%define USER_LEAF_FLAGS     (VM_FLAG_RW | VM_FLAG_US)

section .data

user_va_bitmap: times USER_VA_BITMAP_BYTES db 0

msg_um_ok:         db "UM OK", 0
msg_um_ok_serial:  db "UM OK", 0x0D, 0x0A, 0

section .text

; Boot-time. Zeros the user-VA bitmap so future sys_mmap calls find a
; clean range. Called from _start after vm_space_selftest.
init_user_vm:
    lea     rdi, [rel user_va_bitmap]
    mov     rcx, USER_VA_BITMAP_BYTES
    xor     al, al
    cld
    rep     stosb
    ret

; user_va_test_bit(rdi=page_idx) -> rax: 1 if used, 0 if free.
user_va_test_bit:
    mov     rax, rdi
    mov     rcx, rdi
    shr     rax, 3
    and     rcx, 7
    lea     rdx, [rel user_va_bitmap]
    movzx   rax, byte [rdx + rax]
    shr     rax, cl
    and     rax, 1
    ret

; user_va_set_bit(rdi=page_idx)
user_va_set_bit:
    push    rbx
    mov     rax, rdi
    mov     rcx, rdi
    shr     rax, 3
    and     rcx, 7
    mov     bl, 1
    shl     bl, cl
    lea     rdx, [rel user_va_bitmap]
    or      [rdx + rax], bl
    pop     rbx
    ret

; user_va_clear_bit(rdi=page_idx)
user_va_clear_bit:
    push    rbx
    mov     rax, rdi
    mov     rcx, rdi
    shr     rax, 3
    and     rcx, 7
    mov     bl, 1
    shl     bl, cl
    not     bl
    lea     rdx, [rel user_va_bitmap]
    and     [rdx + rax], bl
    pop     rbx
    ret

; user_va_alloc(rdi=count) -> rax: base virt of a `count`-page contiguous
; run, or 0 if no such run exists. First-fit linear scan over the bitmap;
; on success marks every page used. count must already be validated.
user_va_alloc:
    push    rbx
    push    r12
    push    r13
    push    r14
    test    rdi, rdi
    jz      .none
    cmp     rdi, USER_VA_PAGES
    ja      .none
    mov     r12, rdi
    xor     rbx, rbx
    xor     r13, r13
.scan:
    cmp     rbx, USER_VA_PAGES
    jge     .none
    mov     rdi, rbx
    call    user_va_test_bit
    test    rax, rax
    jnz     .reset
    test    r13, r13
    jnz     .extend
    mov     r14, rbx
.extend:
    inc     r13
    cmp     r13, r12
    je      .found
    inc     rbx
    jmp     .scan
.reset:
    xor     r13, r13
    inc     rbx
    jmp     .scan
.found:
    mov     rbx, r14
    add     r12, r14
.mark_loop:
    cmp     rbx, r12
    jge     .mark_done
    mov     rdi, rbx
    call    user_va_set_bit
    inc     rbx
    jmp     .mark_loop
.mark_done:
    mov     rax, r14
    shl     rax, 12
    add     rax, USER_VA_BASE
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.none:
    xor     rax, rax
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; user_va_free(rdi=virt, rsi=count): clear `count` bits starting at the
; page covering `virt`. Out-of-range pages are silently skipped.
user_va_free:
    push    rbx
    push    r12
    sub     rdi, USER_VA_BASE
    shr     rdi, 12
    mov     rbx, rdi
    mov     r12, rsi
.loop:
    test    r12, r12
    jz      .done
    cmp     rbx, USER_VA_PAGES
    jge     .done
    mov     rdi, rbx
    call    user_va_clear_bit
    inc     rbx
    dec     r12
    jmp     .loop
.done:
    pop     r12
    pop     rbx
    ret

; sys_mmap(rdi=count) -> rax: virt of the first page in a `count`-page
; contiguous virt run with each page backed by a freshly allocated phys
; frame, or -1 on failure. The virt range comes from the user_va_bitmap;
; phys frames come from frame_alloc one at a time (so phys may be
; scattered across the pool). Each leaf is mapped P|RW|US so ring 3 has
; full access.
;
; Atomicity: if any frame_alloc or vm_map_4k fails partway, every page
; mapped so far is vm_unmap_4k'd, every frame freed, and the user-VA
; bitmap range is released — caller observes -1 and the kernel state
; is unchanged.
sys_mmap:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    test    rdi, rdi
    jz      .bad
    mov     r12, rdi

    call    user_va_alloc
    test    rax, rax
    jz      .bad
    mov     r13, rax

    xor     r14, r14
.map_loop:
    cmp     r14, r12
    jge     .map_done

    mov     rdi, 1
    call    frames_alloc_n
    test    rax, rax
    jz      .rollback
    mov     r15, rax

    mov     rdi, r14
    shl     rdi, 12
    add     rdi, r13
    mov     rsi, r15
    mov     rdx, USER_LEAF_FLAGS
    call    vm_map_4k
    test    rax, rax
    jnz     .rollback_frame

    inc     r14
    jmp     .map_loop
.map_done:
    mov     rax, r13
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.rollback_frame:
    mov     rdi, r15
    mov     rsi, 1
    call    frames_free_n
.rollback:
    xor     rbx, rbx
.rollback_loop:
    cmp     rbx, r14
    jge     .rollback_done
    mov     rdi, rbx
    shl     rdi, 12
    add     rdi, r13
    call    vm_walk
    test    rax, rax
    jz      .rollback_skip
    mov     r15, rax
    mov     rdi, rbx
    shl     rdi, 12
    add     rdi, r13
    call    vm_unmap_4k
    mov     rdi, r15
    mov     rsi, 1
    call    frames_free_n
.rollback_skip:
    inc     rbx
    jmp     .rollback_loop
.rollback_done:
    mov     rdi, r13
    mov     rsi, r12
    call    user_va_free
.bad:
    mov     rax, -1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; sys_munmap(rdi=virt, rsi=count) -> rax: 0 on success, -1 if virt is not
; page-aligned, count is zero, or the range falls outside [USER_VA_BASE,
; USER_VA_END). Per-page: vm_walk to recover phys, vm_unmap_4k to drop
; the leaf, frame_free to release the underlying frame. Then the bitmap
; range is cleared. Pages that were already unmapped (vm_walk returns 0)
; are silently skipped — the bitmap clear still happens for the whole
; range so the slot is reusable.
sys_munmap:
    push    rbx
    push    r12
    push    r13
    push    r14

    test    rsi, rsi
    jz      .bad
    test    rdi, FRAME_SIZE - 1
    jnz     .bad
    mov     rax, USER_VA_BASE
    cmp     rdi, rax
    jb      .bad
    mov     rax, rsi
    shl     rax, 12
    add     rax, rdi
    mov     rcx, USER_VA_END
    cmp     rax, rcx
    ja      .bad

    mov     r12, rdi
    mov     r13, rsi
    xor     r14, r14
.unmap_loop:
    cmp     r14, r13
    jge     .unmap_done
    mov     rdi, r14
    shl     rdi, 12
    add     rdi, r12
    mov     rbx, rdi
    call    vm_walk
    test    rax, rax
    jz      .skip_page
    push    rax
    mov     rdi, rbx
    call    vm_unmap_4k
    pop     rdi
    mov     rsi, 1
    call    frames_free_n
.skip_page:
    inc     r14
    jmp     .unmap_loop
.unmap_done:
    mov     rdi, r12
    mov     rsi, r13
    call    user_va_free
    xor     rax, rax
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.bad:
    mov     rax, -1
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; um_selftest: kernel-side, runs once at boot after init_user_vm.
; sys_mmap(2) → verify virt is in [USER_VA_BASE, USER_VA_END), write
; distinct markers to each page, read them back, sys_munmap, verify
; vm_walk reports 0 for both pages. Prints "UM OK" on full success;
; any failure path attempts a best-effort munmap and skips the marker.
um_selftest:
    push    rbx
    push    r12
    push    r13

    mov     rdi, 2
    call    sys_mmap
    cmp     rax, -1
    je      .fail
    mov     r12, rax

    mov     rcx, USER_VA_BASE
    cmp     r12, rcx
    jb      .fail_unmap
    mov     rcx, USER_VA_END
    cmp     r12, rcx
    jae     .fail_unmap

    mov     rbx, 0xCAFE0001CAFE0001
    mov     [r12], rbx
    mov     r13, 0xCAFE0002CAFE0002
    mov     [r12 + FRAME_SIZE], r13

    cmp     [r12], rbx
    jne     .fail_unmap
    cmp     [r12 + FRAME_SIZE], r13
    jne     .fail_unmap

    mov     rdi, r12
    mov     rsi, 2
    call    sys_munmap
    test    rax, rax
    jnz     .fail

    mov     rdi, r12
    call    vm_walk
    test    rax, rax
    jnz     .fail
    mov     rdi, r12
    add     rdi, FRAME_SIZE
    call    vm_walk
    test    rax, rax
    jnz     .fail

    lea     rdi, [rel msg_um_ok]
    mov     rsi, 20
    mov     rdx, 0
    call    vga_puts_at
    lea     rdi, [rel msg_um_ok_serial]
    call    serial_puts

    pop     r13
    pop     r12
    pop     rbx
    ret
.fail_unmap:
    mov     rdi, r12
    mov     rsi, 2
    call    sys_munmap
.fail:
    pop     r13
    pop     r12
    pop     rbx
    ret
