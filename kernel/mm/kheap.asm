; Kernel heap allocator: kmalloc/kzalloc/kfree/krealloc on top of frames_alloc_n.
; Segregated freelists per size class for sizes ≤ 2048; larger sizes (and any
; alignment > 2048) route through a multi-frame large-allocation path. Empty
; slab pages return immediately to the frame allocator. Single-threaded today;
; every public entry point brackets through kheap_enter_critical / kheap_leave_critical
; so the SMP-day spinlock conversion is a single-line change at one site.
;
; M10a delivered the API surface, data layout, and locking-shim symbols.
; M10b lands the slab-page allocator: 10 size classes (16/32/64/96/128/192/
; 256/512/1024/2048) with intrusive freelists per slab page, per-slot canary,
; lazy slab acquisition, immediate slab return on empty, full stats.
; M10c (this revision) adds the large-allocation path (size > 2048 or
; alignment-forced into multi-frame), real krealloc with slab-in-place,
; large-in-place, and alloc-copy-free fallback, and extends kheap_selftest
; with one large alloc and two krealloc traversals (slab→slab grow and
; slab→large grow).
;
; Slab-page format (one frame, 4096 bytes):
;   [0x00..0x3F]                  fixed metadata (magic, class, slot info, list links)
;   [0x40..0x40 + slot_count)     per-slot canary bitmap (1 byte/slot)
;   [data_offset..4095]           slot storage (slot_count * slot_size bytes)
; data_offset is the canary-bitmap end rounded up to slot_size, precomputed in
; class_table so kmalloc/kfree never recompute it.
;
; Large-allocation format (one or more contiguous frames):
;   [0x00..0x1F]                  32-byte header (magic / frame_count / req_size /
;                                 payload_offset / canary)
;   [payload_offset..end]         caller payload
; payload_offset = max(32, align). For align > 32 the caller's pointer is
; aligned to `align` while the header still sits at offset 0 of the first
; frame. kfree recovers the header by masking ptr to the page boundary.
;
; Free slots in slab pages are threaded through their own storage: each free
; slot's first 8 bytes hold the page-relative offset of the next free slot
; (0 = end of list).

[BITS 64]

global init_kheap
global kmalloc
global kzalloc
global kfree
global krealloc
global kheap_stats
global kheap_selftest
global kheap_enter_critical
global kheap_leave_critical

extern frames_alloc_n
extern frames_free_n
extern vga_puts_at
extern serial_puts

%define KHEAP_NUM_CLASSES   10
%define KHEAP_STATS_QWORDS  8

%define FRAME_SIZE          4096
%define PAGE_MASK           -4096

; "SLABPAGE" little-endian as a u64. Distinguishes a slab page from a large
; allocation header and from random user memory.
%define SLAB_MAGIC          0x4547415042414C53

; "LARGEMEM" little-endian as a u64. Marks the first frame of a large
; allocation; kfree dispatches on it after a slab-magic miss.
%define LARGE_MAGIC         0x4D454D454752414C
%define LARGE_CANARY        0xCAFEBA5ECAFEC0DE

; Per-slot canary states held in the slab-page header's canary bitmap.
;   FREED — initial state of every slot in a fresh slab page; also written by
;           kfree. A slot in this state must NOT be allocated without first
;           transitioning to ALLOC.
;   ALLOC — written by kmalloc on alloc; checked by kfree to catch double-free
;           and free-of-never-allocated.
%define CANARY_FREED        0xF7
%define CANARY_ALLOC        0xC0

; Slab-page header offsets.
%define SLAB_HDR_MAGIC          0x00
%define SLAB_HDR_CLASS_IDX      0x08
%define SLAB_HDR_SLOT_SIZE      0x0C
%define SLAB_HDR_SLOT_COUNT     0x10
%define SLAB_HDR_SLOTS_IN_USE   0x14
%define SLAB_HDR_DATA_OFFSET    0x18
%define SLAB_HDR_FREELIST_HEAD  0x20
%define SLAB_HDR_NEXT_PAGE      0x28
%define SLAB_HDR_PREV_PAGE      0x30
%define SLAB_HDR_CANARY_BASE    0x40

; Large-allocation header offsets.
%define LARGE_HDR_MAGIC          0x00
%define LARGE_HDR_FRAME_COUNT    0x08
%define LARGE_HDR_REQ_SIZE       0x0C
%define LARGE_HDR_PAYLOAD_OFFSET 0x10
%define LARGE_HDR_RESERVED       0x14
%define LARGE_HDR_CANARY         0x18
%define LARGE_HDR_MIN_OFFSET     0x20    ; 32 — payload starts here unless align > 32

; Stats block field offsets (8 quadwords).
%define KHS_BYTES_IN_USE        0x00
%define KHS_BYTES_PEAK          0x08
%define KHS_ALLOC_COUNT         0x10
%define KHS_FREE_COUNT          0x18
%define KHS_SLAB_PAGES_OWNED    0x20
%define KHS_LARGE_ALLOCS_ACTIVE 0x28
%define KHS_LARGE_BYTES_IN_USE  0x30
%define KHS_ALLOC_FAILURES      0x38

; Class metadata table entry offsets.
%define CT_SLOT_SIZE        0
%define CT_SLOT_COUNT       4
%define CT_DATA_OFFSET      8
%define CT_ENTRY_SIZE       16

section .data

kheap_freelist_heads:    times KHEAP_NUM_CLASSES dq 0

kheap_stats_block:       times KHEAP_STATS_QWORDS dq 0

kheap_critical_depth:    dq 0

; Per-class metadata: 16 bytes per entry, indexed by class_idx * 16.
; slot_count and data_offset are precomputed so the page setup is a fixed
; sequence of stores rather than per-page arithmetic. The 64 + slot_count
; bytes of header (metadata + canary bitmap) are rounded up to slot_size to
; produce data_offset; the resulting slot_count is the largest count that
; fits into the remaining bytes.
class_table:
    dd 16,   237, 304,  0
    dd 32,   122, 192,  0
    dd 64,   62,  128,  0
    dd 96,   40,  192,  0
    dd 128,  31,  128,  0
    dd 192,  20,  192,  0
    dd 256,  15,  256,  0
    dd 512,  7,   512,  0
    dd 1024, 3,   1024, 0
    dd 2048, 1,   2048, 0

msg_kh_ok:        db "KH OK", 0
msg_kh_ok_serial: db "KH OK", 0x0D, 0x0A, 0

section .text

; Boot-time. Zeros the freelist heads, the stats block, and the critical-section
; depth counter. Pre-allocates nothing — slab pages are acquired lazily on the
; first kmalloc that needs one.
init_kheap:
    lea     rdi, [rel kheap_freelist_heads]
    mov     rcx, KHEAP_NUM_CLASSES
    xor     rax, rax
    rep stosq
    lea     rdi, [rel kheap_stats_block]
    mov     rcx, KHEAP_STATS_QWORDS
    xor     rax, rax
    rep stosq
    mov     qword [rel kheap_critical_depth], 0
    ret

; kmalloc(rdi=size, rsi=align) -> rax: pointer or 0.
; Fails closed on size==0, align not a power of two, align > FRAME_SIZE, or OOM.
; size > 2048 (or align that forces effective_size > 2048) routes to the large
; path. The returned region is aligned to max(align, 16) by construction:
; slab slots are slot_size-aligned (≥ 16) and large allocs honor max(32, align).
kmalloc:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    kheap_enter_critical

    test    rdi, rdi
    jz      .fail
    test    rsi, rsi
    jnz     .check_align
    mov     rsi, 16
    jmp     .align_ok
.check_align:
    cmp     rsi, FRAME_SIZE
    ja      .fail
    cmp     rsi, 1
    jne     .pow2_test
    mov     rsi, 16
    jmp     .align_ok
.pow2_test:
    mov     rax, rsi
    dec     rax
    test    rsi, rax
    jnz     .fail
.align_ok:
    cmp     rdi, rsi
    jae     .size_ok
    mov     rdi, rsi
.size_ok:
    mov     r14, rdi
    mov     r15, rsi
    call    class_from_size
    test    rax, rax
    js      .try_large
    mov     rbx, rax

    lea     rax, [rel kheap_freelist_heads]
    mov     r12, [rax + rbx*8]
.scan:
    test    r12, r12
    jz      .acquire
    mov     eax, [r12 + SLAB_HDR_SLOTS_IN_USE]
    cmp     eax, [r12 + SLAB_HDR_SLOT_COUNT]
    jb      .alloc_in_page
    mov     r12, [r12 + SLAB_HDR_NEXT_PAGE]
    jmp     .scan
.acquire:
    mov     rdi, rbx
    call    slab_acquire
    test    rax, rax
    jz      .fail
    mov     r12, rax
.alloc_in_page:
    mov     rdi, r12
    call    slot_alloc
    test    rax, rax
    jz      .fail
    mov     r13, rax

    mov     edx, [r12 + SLAB_HDR_SLOT_SIZE]
    add     [rel kheap_stats_block + KHS_BYTES_IN_USE], rdx
    inc     qword [rel kheap_stats_block + KHS_ALLOC_COUNT]
    mov     rax, [rel kheap_stats_block + KHS_BYTES_IN_USE]
    cmp     rax, [rel kheap_stats_block + KHS_BYTES_PEAK]
    jbe     .peak_ok
    mov     [rel kheap_stats_block + KHS_BYTES_PEAK], rax
.peak_ok:
    mov     rax, r13
    call    kheap_leave_critical
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.try_large:
    mov     rdi, r14
    mov     rsi, r15
    call    large_alloc
    test    rax, rax
    jz      .fail
    call    kheap_leave_critical
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.fail:
    inc     qword [rel kheap_stats_block + KHS_ALLOC_FAILURES]
    xor     rax, rax
    call    kheap_leave_critical
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; kzalloc(rdi=size, rsi=align) -> rax: zero-filled pointer or 0.
; Zeros exactly `size` bytes (the contracted region), not the whole slot or
; allocation.
kzalloc:
    push    rbx
    mov     rbx, rdi
    call    kmalloc
    test    rax, rax
    jz      .ret
    mov     rdi, rax
    mov     rcx, rbx
    push    rax
    xor     eax, eax
    rep stosb
    pop     rax
.ret:
    pop     rbx
    ret

; kfree(rdi=ptr): release a kmalloc/kzalloc/krealloc allocation. ptr=0 is a no-op.
; Detects whether ptr belongs to a slab page or a large allocation by reading
; the magic at (ptr & PAGE_MASK). Other magics (or none) are silently ignored —
; freeing a non-kheap pointer is undefined and we'd rather keep going than panic.
kfree:
    test    rdi, rdi
    jz      .ret
    push    rbx
    push    r12
    call    kheap_enter_critical
    mov     rax, rdi
    and     rax, PAGE_MASK
    mov     rdx, SLAB_MAGIC
    cmp     [rax], rdx
    je      .slab_free
    mov     rdx, LARGE_MAGIC
    cmp     [rax], rdx
    je      .large_free_path
    jmp     .epilogue
.slab_free:
    mov     rbx, rax
    sub     rdi, rax
    mov     r12d, [rbx + SLAB_HDR_SLOT_SIZE]
    mov     rsi, rdi
    mov     rdi, rbx
    call    slot_free
    sub     [rel kheap_stats_block + KHS_BYTES_IN_USE], r12
    inc     qword [rel kheap_stats_block + KHS_FREE_COUNT]
    test    rax, rax
    jz      .epilogue
    mov     rdi, rbx
    call    slab_release
    jmp     .epilogue
.large_free_path:
    call    large_free
.epilogue:
    call    kheap_leave_critical
    pop     r12
    pop     rbx
.ret:
    ret

; krealloc(rdi=ptr, rsi=new_size, rdx=align) -> rax: new pointer or 0.
; Specials: krealloc(0, n, a) == kmalloc(n, a). krealloc(p, 0, _) frees p and returns 0.
; Slab path: in-place if new_size fits in current class's slot_size.
; Large path: in-place if new_size fits in current frames' usable capacity.
; Otherwise: alloc new + copy min(old, new) + free old. On allocation failure
; the original ptr remains valid and 0 is returned (glibc-style realloc-fail).
krealloc:
    test    rdi, rdi
    jnz     .have_ptr
    mov     rdi, rsi
    mov     rsi, rdx
    jmp     kmalloc
.have_ptr:
    test    rsi, rsi
    jnz     .real
    call    kfree
    xor     rax, rax
    ret
.real:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     rax, rbx
    and     rax, PAGE_MASK
    mov     rdx, SLAB_MAGIC
    cmp     [rax], rdx
    je      .slab
    mov     rdx, LARGE_MAGIC
    cmp     [rax], rdx
    je      .large
    jmp     .fail
.slab:
    mov     r14d, [rax + SLAB_HDR_SLOT_SIZE]
    cmp     r12, r14
    jbe     .return_unchanged
    jmp     .acf
.large:
    mov     ecx, [rax + LARGE_HDR_FRAME_COUNT]
    mov     edx, [rax + LARGE_HDR_PAYLOAD_OFFSET]
    shl     rcx, 12
    sub     rcx, rdx
    cmp     r12, rcx
    ja      .large_grow
    call    kheap_enter_critical
    mov     r14d, [rax + LARGE_HDR_REQ_SIZE]
    mov     [rax + LARGE_HDR_REQ_SIZE], r12d
    sub     [rel kheap_stats_block + KHS_BYTES_IN_USE], r14
    add     [rel kheap_stats_block + KHS_BYTES_IN_USE], r12
    call    kheap_leave_critical
    jmp     .return_unchanged
.large_grow:
    mov     r14d, [rax + LARGE_HDR_REQ_SIZE]
    jmp     .acf
.return_unchanged:
    mov     rax, rbx
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.acf:
    mov     rdi, r12
    mov     rsi, r13
    call    kmalloc
    test    rax, rax
    jz      .fail
    mov     rcx, r14
    cmp     rcx, r12
    jbe     .copy_size_set
    mov     rcx, r12
.copy_size_set:
    push    rax
    mov     rdi, rax
    mov     rsi, rbx
    cld
    rep movsb
    pop     rax
    push    rax
    mov     rdi, rbx
    call    kfree
    pop     rax
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.fail:
    xor     rax, rax
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; kheap_stats(rdi=out_buf): copy 64-byte stats snapshot into caller buffer.
kheap_stats:
    lea     rsi, [rel kheap_stats_block]
    mov     rcx, KHEAP_STATS_QWORDS
    rep movsq
    ret

; Bracket every public allocator entry. Today: bump/drop the depth counter.
; SMP-day swap point: bodies become spinlock acquire/release.
kheap_enter_critical:
    inc     qword [rel kheap_critical_depth]
    ret

kheap_leave_critical:
    dec     qword [rel kheap_critical_depth]
    ret

; class_from_size(rdi=size) -> rax: class index (0..9) or -1 if size==0 or size > 2048.
class_from_size:
    test    rdi, rdi
    jz      .fail
    xor     eax, eax
    cmp     rdi, 16
    jbe     .done
    mov     eax, 1
    cmp     rdi, 32
    jbe     .done
    mov     eax, 2
    cmp     rdi, 64
    jbe     .done
    mov     eax, 3
    cmp     rdi, 96
    jbe     .done
    mov     eax, 4
    cmp     rdi, 128
    jbe     .done
    mov     eax, 5
    cmp     rdi, 192
    jbe     .done
    mov     eax, 6
    cmp     rdi, 256
    jbe     .done
    mov     eax, 7
    cmp     rdi, 512
    jbe     .done
    mov     eax, 8
    cmp     rdi, 1024
    jbe     .done
    mov     eax, 9
    cmp     rdi, 2048
    jbe     .done
.fail:
    mov     rax, -1
.done:
    ret

; canary_at(rdi=page, rsi=slot_offset_in_page) -> rax: address of slot's canary byte.
canary_at:
    mov     eax, esi
    sub     eax, [rdi + SLAB_HDR_DATA_OFFSET]
    xor     edx, edx
    div     dword [rdi + SLAB_HDR_SLOT_SIZE]
    lea     rax, [rdi + rax + SLAB_HDR_CANARY_BASE]
    ret

; slab_init(rdi=page, rsi=class_idx)
; Writes the slab page header, threads the intrusive freelist through every
; slot, and fills the canary bitmap with FREED.
slab_init:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, rdi
    lea     rdx, [rel class_table]
    mov     rax, rsi
    shl     rax, 4
    add     rdx, rax
    mov     r12d, [rdx + CT_SLOT_SIZE]
    mov     r13d, [rdx + CT_SLOT_COUNT]
    mov     r14d, [rdx + CT_DATA_OFFSET]
    mov     rax, SLAB_MAGIC
    mov     [rbx + SLAB_HDR_MAGIC], rax
    mov     [rbx + SLAB_HDR_CLASS_IDX], esi
    mov     [rbx + SLAB_HDR_SLOT_SIZE], r12d
    mov     [rbx + SLAB_HDR_SLOT_COUNT], r13d
    mov     dword [rbx + SLAB_HDR_SLOTS_IN_USE], 0
    mov     [rbx + SLAB_HDR_DATA_OFFSET], r14d
    mov     [rbx + SLAB_HDR_FREELIST_HEAD], r14
    mov     qword [rbx + SLAB_HDR_NEXT_PAGE], 0
    mov     qword [rbx + SLAB_HDR_PREV_PAGE], 0
    mov     ecx, r13d
    test    ecx, ecx
    jz      .canary
    mov     rax, r14
    mov     rdi, r12
    dec     ecx
.lloop:
    test    ecx, ecx
    jz      .lterm
    lea     rdx, [rax + rdi]
    mov     [rbx + rax], rdx
    mov     rax, rdx
    dec     ecx
    jmp     .lloop
.lterm:
    mov     qword [rbx + rax], 0
.canary:
    lea     rdi, [rbx + SLAB_HDR_CANARY_BASE]
    mov     ecx, r13d
    mov     al, CANARY_FREED
    rep stosb
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; slab_acquire(rdi=class_idx) -> rax: page address or 0 on OOM.
; Allocates one frame, initializes it as a slab page for the class, links it
; at the head of the class's slab-page list, and bumps slab_pages_owned.
slab_acquire:
    push    rbx
    mov     rbx, rdi
    mov     rdi, 1
    call    frames_alloc_n
    test    rax, rax
    jz      .fail
    push    rax
    mov     rdi, rax
    mov     rsi, rbx
    call    slab_init
    pop     rax
    lea     rcx, [rel kheap_freelist_heads]
    mov     rdx, [rcx + rbx*8]
    mov     [rax + SLAB_HDR_NEXT_PAGE], rdx
    mov     qword [rax + SLAB_HDR_PREV_PAGE], 0
    test    rdx, rdx
    jz      .no_old
    mov     [rdx + SLAB_HDR_PREV_PAGE], rax
.no_old:
    mov     [rcx + rbx*8], rax
    inc     qword [rel kheap_stats_block + KHS_SLAB_PAGES_OWNED]
    pop     rbx
    ret
.fail:
    xor     rax, rax
    pop     rbx
    ret

; slab_release(rdi=page)
; Caller guarantees slots_in_use == 0. Unlinks the page from its class's
; slab-page list and returns the frame to frames_free_n.
slab_release:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     r12d, [rbx + SLAB_HDR_CLASS_IDX]
    mov     rax, [rbx + SLAB_HDR_PREV_PAGE]
    mov     rdx, [rbx + SLAB_HDR_NEXT_PAGE]
    test    rax, rax
    jz      .we_are_head
    mov     [rax + SLAB_HDR_NEXT_PAGE], rdx
    jmp     .check_next
.we_are_head:
    lea     rcx, [rel kheap_freelist_heads]
    mov     [rcx + r12*8], rdx
.check_next:
    test    rdx, rdx
    jz      .unlinked
    mov     [rdx + SLAB_HDR_PREV_PAGE], rax
.unlinked:
    dec     qword [rel kheap_stats_block + KHS_SLAB_PAGES_OWNED]
    mov     rdi, rbx
    mov     rsi, 1
    call    frames_free_n
    pop     r12
    pop     rbx
    ret

; slot_alloc(rdi=page) -> rax: pointer to slot data, or 0 if page is full.
; Pops the head of the page's intrusive freelist, marks the canary as ALLOC,
; and increments slots_in_use.
slot_alloc:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     r12, [rbx + SLAB_HDR_FREELIST_HEAD]
    test    r12, r12
    jz      .empty
    mov     rax, [rbx + r12]
    mov     [rbx + SLAB_HDR_FREELIST_HEAD], rax
    inc     dword [rbx + SLAB_HDR_SLOTS_IN_USE]
    mov     rdi, rbx
    mov     rsi, r12
    call    canary_at
    mov     byte [rax], CANARY_ALLOC
    lea     rax, [rbx + r12]
    pop     r12
    pop     rbx
    ret
.empty:
    xor     rax, rax
    pop     r12
    pop     rbx
    ret

; slot_free(rdi=page, rsi=slot_offset_in_page) -> rax: 1 if page becomes empty, 0 otherwise.
; Verifies canary == ALLOC (rejects double-free and free-of-never-allocated by
; refusing to update state and returning 0). Pushes the slot onto the
; freelist and transitions canary to FREED.
slot_free:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     r12, rsi
    mov     rdi, rbx
    mov     rsi, r12
    call    canary_at
    cmp     byte [rax], CANARY_ALLOC
    jne     .bad
    mov     byte [rax], CANARY_FREED
    mov     rax, [rbx + SLAB_HDR_FREELIST_HEAD]
    mov     [rbx + r12], rax
    mov     [rbx + SLAB_HDR_FREELIST_HEAD], r12
    dec     dword [rbx + SLAB_HDR_SLOTS_IN_USE]
    jnz     .nonempty
    mov     rax, 1
    pop     r12
    pop     rbx
    ret
.nonempty:
    xor     rax, rax
    pop     r12
    pop     rbx
    ret
.bad:
    xor     rax, rax
    pop     r12
    pop     rbx
    ret

; large_alloc(rdi=size, rsi=align) -> rax: ptr or 0.
; Caller must already be in the kheap critical section. Caller has validated
; that size > 0 and align is a power of two ≤ FRAME_SIZE; large_alloc accepts
; either size > 2048 or align > class_size that pushed effective_size above
; the slab range.
large_alloc:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, 32
    cmp     r12, r13
    jbe     .po_ok
    mov     r13, r12
.po_ok:
    mov     rax, r13
    add     rax, rbx
    add     rax, FRAME_SIZE - 1
    shr     rax, 12
    mov     r12, rax
    mov     rdi, r12
    call    frames_alloc_n
    test    rax, rax
    jz      .fail
    mov     rcx, LARGE_MAGIC
    mov     [rax + LARGE_HDR_MAGIC], rcx
    mov     [rax + LARGE_HDR_FRAME_COUNT], r12d
    mov     [rax + LARGE_HDR_REQ_SIZE], ebx
    mov     [rax + LARGE_HDR_PAYLOAD_OFFSET], r13d
    mov     dword [rax + LARGE_HDR_RESERVED], 0
    mov     rcx, LARGE_CANARY
    mov     [rax + LARGE_HDR_CANARY], rcx
    inc     qword [rel kheap_stats_block + KHS_LARGE_ALLOCS_ACTIVE]
    mov     rcx, r12
    shl     rcx, 12
    add     [rel kheap_stats_block + KHS_LARGE_BYTES_IN_USE], rcx
    add     [rel kheap_stats_block + KHS_BYTES_IN_USE], rbx
    inc     qword [rel kheap_stats_block + KHS_ALLOC_COUNT]
    mov     rcx, [rel kheap_stats_block + KHS_BYTES_IN_USE]
    cmp     rcx, [rel kheap_stats_block + KHS_BYTES_PEAK]
    jbe     .peak_ok
    mov     [rel kheap_stats_block + KHS_BYTES_PEAK], rcx
.peak_ok:
    add     rax, r13
    pop     r13
    pop     r12
    pop     rbx
    ret
.fail:
    xor     rax, rax
    pop     r13
    pop     r12
    pop     rbx
    ret

; large_free(rdi=ptr) — ptr was returned by a prior large_alloc.
; Caller must already be in the kheap critical section and have verified
; LARGE_MAGIC at (ptr & PAGE_MASK). Verifies the canary; on canary mismatch
; the call is silently dropped (state unchanged) — corrupted header, can't
; trust frame_count to call frames_free_n safely.
large_free:
    push    rbx
    push    r12
    mov     rbx, rdi
    and     rbx, PAGE_MASK
    mov     r12d, [rbx + LARGE_HDR_FRAME_COUNT]
    mov     edx, [rbx + LARGE_HDR_REQ_SIZE]
    mov     rax, LARGE_CANARY
    cmp     [rbx + LARGE_HDR_CANARY], rax
    jne     .bad
    sub     [rel kheap_stats_block + KHS_BYTES_IN_USE], rdx
    inc     qword [rel kheap_stats_block + KHS_FREE_COUNT]
    dec     qword [rel kheap_stats_block + KHS_LARGE_ALLOCS_ACTIVE]
    mov     rdx, r12
    shl     rdx, 12
    sub     [rel kheap_stats_block + KHS_LARGE_BYTES_IN_USE], rdx
    mov     rdi, rbx
    mov     rsi, r12
    call    frames_free_n
.bad:
    pop     r12
    pop     rbx
    ret

; kheap_selftest: kernel-side, runs once at boot after init_kheap.
;
; M10b coverage: classes 16/64/256/1024 alloc → write → free-and-reuse → free
;                everything → verify zero-leak invariants.
; M10c coverage: one large alloc (16 KiB) with end-of-region write → verify
;                large stats clear; krealloc 64→256 (slab→slab grow) with
;                content preservation; krealloc 256→8192 (slab→large grow)
;                with content preservation and writability past slab boundary.
;
; Prints "KH OK" to VGA + serial only when every check passes; on any failure
; the marker is omitted and CI sees the missing string.
kheap_selftest:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    ; --- M10b: small-class coverage + reuse ---
    mov     rdi, 16
    mov     rsi, 0
    call    kmalloc
    test    rax, rax
    jz      .fail
    mov     rbx, rax
    mov     rdi, 64
    mov     rsi, 0
    call    kmalloc
    test    rax, rax
    jz      .fail
    mov     r12, rax
    mov     rdi, 256
    mov     rsi, 0
    call    kmalloc
    test    rax, rax
    jz      .fail
    mov     r13, rax
    mov     rdi, 1024
    mov     rsi, 0
    call    kmalloc
    test    rax, rax
    jz      .fail
    mov     r14, rax
    mov     byte [rbx], 0xAB
    mov     byte [r12], 0xCD
    mov     byte [r13], 0xEF
    mov     byte [r14], 0x77
    cmp     byte [rbx], 0xAB
    jne     .fail
    cmp     byte [r12], 0xCD
    jne     .fail
    cmp     byte [r13], 0xEF
    jne     .fail
    cmp     byte [r14], 0x77
    jne     .fail
    mov     rdi, rbx
    call    kfree
    mov     rdi, 16
    mov     rsi, 0
    call    kmalloc
    cmp     rax, rbx
    jne     .fail
    mov     r15, rax
    mov     rdi, r15
    call    kfree
    mov     rdi, r12
    call    kfree
    mov     rdi, r13
    call    kfree
    mov     rdi, r14
    call    kfree

    ; --- M10c phase A: one large alloc (16 KiB) ---
    mov     rdi, 16384
    mov     rsi, 0
    call    kmalloc
    test    rax, rax
    jz      .fail
    mov     rbx, rax
    mov     byte [rbx], 0xA1
    mov     byte [rbx + 16383], 0xA9
    cmp     byte [rbx], 0xA1
    jne     .fail
    cmp     byte [rbx + 16383], 0xA9
    jne     .fail
    mov     rdi, rbx
    call    kfree
    cmp     qword [rel kheap_stats_block + KHS_LARGE_ALLOCS_ACTIVE], 0
    jne     .fail
    cmp     qword [rel kheap_stats_block + KHS_LARGE_BYTES_IN_USE], 0
    jne     .fail

    ; --- M10c phase B: krealloc 64 → 256 (slab to slab) ---
    mov     rdi, 64
    mov     rsi, 0
    call    kmalloc
    test    rax, rax
    jz      .fail
    mov     rbx, rax
    mov     byte [rbx], 0xB1
    mov     byte [rbx + 63], 0xBF
    mov     rdi, rbx
    mov     rsi, 256
    mov     rdx, 0
    call    krealloc
    test    rax, rax
    jz      .fail
    mov     r12, rax
    cmp     byte [r12], 0xB1
    jne     .fail
    cmp     byte [r12 + 63], 0xBF
    jne     .fail
    mov     rdi, r12
    call    kfree

    ; --- M10c phase C: krealloc 256 → 8192 (slab to large) ---
    mov     rdi, 256
    mov     rsi, 0
    call    kmalloc
    test    rax, rax
    jz      .fail
    mov     rbx, rax
    mov     byte [rbx], 0xC1
    mov     byte [rbx + 255], 0xCF
    mov     rdi, rbx
    mov     rsi, 8192
    mov     rdx, 0
    call    krealloc
    test    rax, rax
    jz      .fail
    mov     r12, rax
    cmp     byte [r12], 0xC1
    jne     .fail
    cmp     byte [r12 + 255], 0xCF
    jne     .fail
    mov     byte [r12 + 8191], 0xCC
    cmp     byte [r12 + 8191], 0xCC
    jne     .fail
    mov     rdi, r12
    call    kfree

    ; --- final invariant checks ---
    cmp     qword [rel kheap_stats_block + KHS_BYTES_IN_USE], 0
    jne     .fail
    cmp     qword [rel kheap_stats_block + KHS_SLAB_PAGES_OWNED], 0
    jne     .fail
    cmp     qword [rel kheap_stats_block + KHS_LARGE_ALLOCS_ACTIVE], 0
    jne     .fail
    cmp     qword [rel kheap_stats_block + KHS_LARGE_BYTES_IN_USE], 0
    jne     .fail
    cmp     qword [rel kheap_critical_depth], 0
    jne     .fail

    lea     rdi, [rel msg_kh_ok]
    mov     rsi, 15
    mov     rdx, 0
    call    vga_puts_at
    lea     rdi, [rel msg_kh_ok_serial]
    call    serial_puts
.fail:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
