; 4 KiB physical-frame allocator covering phys 0..2 MiB. Bitmap-based: 1 bit
; per frame, 512 frames total = 64 bytes of bookkeeping. bit = 1 means "in
; use." First-fit linear scan; supports contiguous-N runs via frame_alloc /
; frame_free (count=1 is the single-frame degenerate case).
;
; The allocator is the only thing that hands out physical pages after init.
; M11c consumers: vm_map_4k (intermediate page-table pages), vm_space_create
; (per-space PML4), and user_vm.asm's sys_mmap (one frame per user page).
; All callers go through frame_alloc — no other path mints physical frames.

[BITS 64]

global init_frame
global frame_alloc
global frames_alloc_n
global frame_free
global frames_free_n

%define FRAME_SHIFT         12
%define FRAME_SIZE          (1 << FRAME_SHIFT)
%define FRAME_TOTAL         512
%define FRAME_BITMAP_BYTES  (FRAME_TOTAL / 8)

section .data

frame_bitmap: times FRAME_BITMAP_BYTES db 0

section .text

; Boot-time reservation. Marks frames the kernel/bootloader already own
; according to the documented memory map. Keep this in sync with the
; addresses defined elsewhere in the tree (boot/stage2.asm, kernel/main.asm,
; kernel/cpu/{idt,tss}.asm, kernel/syscall/entry.asm).
;
; Reserved physical ranges:
;   [0x00000, 0x10000)   — BIOS, IVT, low memory used by Stage 1 / Stage 2
;   [0x50000, 0x60000)   — region just below USER_STACK_TOP (0x60000)
;   [0x70000, 0x74000)   — PML4, PDPT, PD, PT page tables built in Stage 2 (M11a: PT added for 4 KiB granularity)
;   [0x80000, 0x90000)   — KERNEL_SYSCALL_STACK_TOP (0x88000) + KERNEL_STACK_TOP (0x90000) regions
;   [0xB8000, 0xC0000)   — VGA text buffer (4 KiB at 0xB8000, padded to 32 KiB)
;   [0x100000, 0x140000) — kernel image (16 KiB at 0x100000) + IDT (0x110000) + handler table (0x111000) + breathing room
init_frame:
    mov     rdi, 0x00
    mov     rsi, 0x10
    call    mark_range_used

    mov     rdi, 0x50
    mov     rsi, 0x60
    call    mark_range_used

    mov     rdi, 0x70
    mov     rsi, 0x74
    call    mark_range_used

    mov     rdi, 0x80
    mov     rsi, 0x90
    call    mark_range_used

    mov     rdi, 0xB8
    mov     rsi, 0xC0
    call    mark_range_used

    mov     rdi, 0x100
    mov     rsi, 0x140
    call    mark_range_used

    ret

; frame_alloc(count) -> rax: physical address of the first frame in a run
; of `count` contiguous free frames, or 0 if no such run exists.
; frames_alloc_n is the same function under the name kheap.asm uses, so a
; reader of the heap call sites doesn't have to remember that frame_alloc
; took a count all along.
frame_alloc:
frames_alloc_n:
    push    rbx
    push    r12
    push    r13
    push    r14
    test    rdi, rdi
    jz      .none
    cmp     rdi, FRAME_TOTAL
    ja      .none
    mov     r12, rdi                ; needed count
    xor     rbx, rbx                ; current frame idx
    xor     r13, r13                ; run length
.scan:
    cmp     rbx, FRAME_TOTAL
    jge     .none
    mov     rdi, rbx
    call    bit_test
    test    rax, rax
    jnz     .used
    test    r13, r13
    jnz     .extend
    mov     r14, rbx                ; run start
.extend:
    inc     r13
    cmp     r13, r12
    je      .found
    inc     rbx
    jmp     .scan
.used:
    xor     r13, r13
    inc     rbx
    jmp     .scan
.found:
    mov     rdi, r14
    lea     rsi, [r14 + r12]
    call    mark_range_used
    mov     rax, r14
    shl     rax, FRAME_SHIFT
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

; frame_free(phys_addr, count): clear bits for `count` frames starting at addr.
; Out-of-range frame indices are silently skipped — not the allocator's job
; to detect mistaken frees.
; frames_free_n is the same function under the name kheap.asm uses.
frame_free:
frames_free_n:
    push    rbx
    push    r12
    shr     rdi, FRAME_SHIFT
    mov     rbx, rdi
    mov     r12, rsi
.loop:
    test    r12, r12
    jz      .done
    cmp     rbx, FRAME_TOTAL
    jge     .done
    mov     rdi, rbx
    call    bit_clear
    inc     rbx
    dec     r12
    jmp     .loop
.done:
    pop     r12
    pop     rbx
    ret

; mark_range_used(rdi=start_frame, rsi=end_frame_exclusive)
mark_range_used:
    push    rbx
.loop:
    cmp     rdi, rsi
    jge     .done
    push    rdi
    push    rsi
    call    bit_set
    pop     rsi
    pop     rdi
    inc     rdi
    jmp     .loop
.done:
    pop     rbx
    ret

; bit_test(rdi=frame_idx) -> rax: 1 if used, 0 if free.
bit_test:
    mov     rax, rdi
    mov     rcx, rdi
    shr     rax, 3
    and     rcx, 7
    lea     rdx, [rel frame_bitmap]
    movzx   rax, byte [rdx + rax]
    shr     rax, cl
    and     rax, 1
    ret

; bit_set(rdi=frame_idx)
bit_set:
    push    rbx
    mov     rax, rdi
    mov     rcx, rdi
    shr     rax, 3
    and     rcx, 7
    mov     bl, 1
    shl     bl, cl
    lea     rdx, [rel frame_bitmap]
    or      [rdx + rax], bl
    pop     rbx
    ret

; bit_clear(rdi=frame_idx)
bit_clear:
    push    rbx
    mov     rax, rdi
    mov     rcx, rdi
    shr     rax, 3
    and     rcx, 7
    mov     bl, 1
    shl     bl, cl
    not     bl
    lea     rdx, [rel frame_bitmap]
    and     [rdx + rax], bl
    pop     rbx
    ret

