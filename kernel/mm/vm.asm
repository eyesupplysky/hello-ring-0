; Page-table primitives. Walks the active PML4 (read from CR3) and exposes
; vm_map_4k / vm_unmap_4k / vm_walk for 4 KiB virtual pages. Intermediate
; PML4/PDPT/PD tables are allocated on demand from frame_alloc when missing
; and installed PRESENT|RW|US=1 — leaf flags from the caller gate actual
; access. Every map/unmap is followed by invlpg on the affected virt.
;
; Boot context: stage2 builds a single PT page at PT_ADDR=0x73000 that
; identity-maps phys 0..2 MiB at 4 KiB granularity. vm_map_4k can target any
; virt outside that range; new intermediate frames are zeroed via the
; identity map (frame_alloc hands out frames in [0x140000, 0x200000), all
; of which is identity-mapped, so phys = virt for our internal accesses).
;
; vm_walk returns 0 on "not mapped". Frame 0 is reserved by init_frame, so
; the caller can treat 0 as unambiguous failure.

[BITS 64]

global init_vm
global vm_map_4k
global vm_unmap_4k
global vm_walk
global vm_protect
global vm_invlpg
global vm_selftest
global boot_pml4_phys

extern frames_alloc_n
extern frames_free_n
extern vga_puts_at
extern serial_puts

%define VM_FLAG_P           0x001
%define VM_FLAG_RW          0x002
%define VM_FLAG_US          0x004
%define VM_INTERMEDIATE     0x007                       ; P|RW|US — leaf flags govern access
%define VM_ADDR_MASK        0x000FFFFFFFFFF000          ; PTE bits [51:12] = phys frame addr

section .data

;            Reads of CR3 elsewhere remain authoritative — this is the
;            anchor M11b will use to mint per-process PML4s by copying the
;            kernel-half entries of this one.
boot_pml4_phys:    dq 0

msg_vm_ok:         db "VM OK", 0
msg_vm_ok_serial:  db "VM OK", 0x0D, 0x0A, 0

section .text

; Stash the boot PML4 phys for later cloning. Allocates nothing, touches no
; tables — pre-walks must be safe because the boot tables already exist.
init_vm:
    mov     rax, cr3
    mov     rcx, VM_ADDR_MASK
    and     rax, rcx
    mov     [rel boot_pml4_phys], rax
    ret

; vm_invlpg(rdi=virt): flush the per-page TLB for `virt`. Exposed so callers
; mutating page tables out-of-band can flush without redundant arithmetic.
vm_invlpg:
    invlpg  [rdi]
    ret

; zero_frame(rdi=phys): write 4 KiB of zeros starting at rdi (a valid VA
; under the identity map). Preserves rdi/rcx/rax for the caller.
zero_frame:
    push    rdi
    push    rcx
    push    rax
    mov     rcx, 512
    xor     rax, rax
    cld
    rep     stosq
    pop     rax
    pop     rcx
    pop     rdi
    ret

; ensure_intermediate(rdi=entry_ptr) -> rax: child table phys (page-aligned),
; or 0 on OOM. If *entry_ptr is present, returns its child phys. Otherwise
; allocates a fresh frame, zeroes it, installs PRESENT|RW|US, and returns
; the new phys. Preserves r12-r15; clobbers rcx.
ensure_intermediate:
    push    rbx
    push    rdi
    mov     rax, [rdi]
    test    rax, 1
    jz      .alloc
    mov     rcx, VM_ADDR_MASK
    and     rax, rcx
    pop     rdi
    pop     rbx
    ret
.alloc:
    mov     rdi, 1
    call    frames_alloc_n
    test    rax, rax
    jz      .oom
    mov     rbx, rax
    mov     rdi, rax
    call    zero_frame
    pop     rdi
    mov     rax, rbx
    or      rax, VM_INTERMEDIATE
    mov     [rdi], rax
    mov     rax, rbx
    pop     rbx
    ret
.oom:
    pop     rdi
    pop     rbx
    xor     rax, rax
    ret

; vm_map_4k(rdi=virt, rsi=phys, rdx=flags) -> rax: 0 on success, -1 on OOM.
; Maps the 4 KiB page at `virt` to `phys`, OR'ing flags with PRESENT.
; Allocates intermediate PML4/PDPT/PD entries from frame_alloc as needed.
; Clobbers any existing leaf entry without checking — caller must vm_unmap_4k
; first if the virt is in use.
vm_map_4k:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13, rsi
    mov     rbx, rdx

    mov     rax, cr3
    mov     rcx, VM_ADDR_MASK
    and     rax, rcx

    mov     rcx, r12
    shr     rcx, 39
    and     rcx, 0x1FF
    lea     rdi, [rax + rcx*8]
    call    ensure_intermediate
    test    rax, rax
    jz      .oom

    mov     rcx, r12
    shr     rcx, 30
    and     rcx, 0x1FF
    lea     rdi, [rax + rcx*8]
    call    ensure_intermediate
    test    rax, rax
    jz      .oom

    mov     rcx, r12
    shr     rcx, 21
    and     rcx, 0x1FF
    lea     rdi, [rax + rcx*8]
    call    ensure_intermediate
    test    rax, rax
    jz      .oom

    mov     rcx, r12
    shr     rcx, 12
    and     rcx, 0x1FF
    lea     rdi, [rax + rcx*8]

    mov     rax, r13
    mov     rcx, VM_ADDR_MASK
    and     rax, rcx
    or      rbx, VM_FLAG_P
    or      rax, rbx
    mov     [rdi], rax

    invlpg  [r12]
    xor     rax, rax
    pop     r13
    pop     r12
    pop     rbx
    ret
.oom:
    mov     rax, -1
    pop     r13
    pop     r12
    pop     rbx
    ret

; vm_unmap_4k(rdi=virt) -> rax: 0 on success, -1 if virt was not present at
; any of PML4/PDPT/PD/PT. Clears the leaf PT entry only — intermediate
; tables persist (other pages in the same 2 MiB may still need the PT).
vm_unmap_4k:
    push    r12
    mov     r12, rdi

    mov     rax, cr3
    mov     rcx, VM_ADDR_MASK
    and     rax, rcx

    mov     rcx, r12
    shr     rcx, 39
    and     rcx, 0x1FF
    mov     rax, [rax + rcx*8]
    test    rax, 1
    jz      .nope
    mov     rcx, VM_ADDR_MASK
    and     rax, rcx

    mov     rcx, r12
    shr     rcx, 30
    and     rcx, 0x1FF
    mov     rax, [rax + rcx*8]
    test    rax, 1
    jz      .nope
    mov     rcx, VM_ADDR_MASK
    and     rax, rcx

    mov     rcx, r12
    shr     rcx, 21
    and     rcx, 0x1FF
    mov     rax, [rax + rcx*8]
    test    rax, 1
    jz      .nope
    mov     rcx, VM_ADDR_MASK
    and     rax, rcx

    mov     rcx, r12
    shr     rcx, 12
    and     rcx, 0x1FF
    lea     rdi, [rax + rcx*8]
    mov     rax, [rdi]
    test    rax, 1
    jz      .nope

    xor     rax, rax
    mov     [rdi], rax
    invlpg  [r12]

    xor     rax, rax
    pop     r12
    ret
.nope:
    mov     rax, -1
    pop     r12
    ret

; vm_walk(rdi=virt) -> rax: phys frame addr (page-aligned) the leaf entry
; points at, or 0 if any level is non-present. Caller adds the page offset
; if they need a byte-precise address.
vm_walk:
    push    r12
    mov     r12, rdi

    mov     rax, cr3
    mov     rcx, VM_ADDR_MASK
    and     rax, rcx

    mov     rcx, r12
    shr     rcx, 39
    and     rcx, 0x1FF
    mov     rax, [rax + rcx*8]
    test    rax, 1
    jz      .nope
    mov     rcx, VM_ADDR_MASK
    and     rax, rcx

    mov     rcx, r12
    shr     rcx, 30
    and     rcx, 0x1FF
    mov     rax, [rax + rcx*8]
    test    rax, 1
    jz      .nope
    mov     rcx, VM_ADDR_MASK
    and     rax, rcx

    mov     rcx, r12
    shr     rcx, 21
    and     rcx, 0x1FF
    mov     rax, [rax + rcx*8]
    test    rax, 1
    jz      .nope
    mov     rcx, VM_ADDR_MASK
    and     rax, rcx

    mov     rcx, r12
    shr     rcx, 12
    and     rcx, 0x1FF
    mov     rax, [rax + rcx*8]
    test    rax, 1
    jz      .nope
    mov     rcx, VM_ADDR_MASK
    and     rax, rcx

    pop     r12
    ret
.nope:
    xor     rax, rax
    pop     r12
    ret

; vm_protect(rdi=virt, rsi=flags) -> rax: 0 on success, -1 if the leaf at
; `virt` is non-present at any level. Replaces the leaf PTE's flags while
; preserving the existing phys; OR's in the P bit; invlpg's the page.
; The full 64-bit `flags` is written verbatim into the entry's non-phys
; bits — caller controls RW/US/NX/etc. by setting the right bits.
vm_protect:
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13, rsi

    mov     rax, cr3
    mov     rcx, VM_ADDR_MASK
    and     rax, rcx

    mov     rcx, r12
    shr     rcx, 39
    and     rcx, 0x1FF
    mov     rax, [rax + rcx*8]
    test    rax, 1
    jz      .nope_p
    mov     rcx, VM_ADDR_MASK
    and     rax, rcx

    mov     rcx, r12
    shr     rcx, 30
    and     rcx, 0x1FF
    mov     rax, [rax + rcx*8]
    test    rax, 1
    jz      .nope_p
    mov     rcx, VM_ADDR_MASK
    and     rax, rcx

    mov     rcx, r12
    shr     rcx, 21
    and     rcx, 0x1FF
    mov     rax, [rax + rcx*8]
    test    rax, 1
    jz      .nope_p
    mov     rcx, VM_ADDR_MASK
    and     rax, rcx

    mov     rcx, r12
    shr     rcx, 12
    and     rcx, 0x1FF
    lea     rdi, [rax + rcx*8]
    mov     rax, [rdi]
    test    rax, 1
    jz      .nope_p

    mov     rcx, VM_ADDR_MASK
    and     rax, rcx
    or      r13, 1
    or      rax, r13
    mov     [rdi], rax

    invlpg  [r12]
    xor     rax, rax
    pop     r13
    pop     r12
    ret
.nope_p:
    mov     rax, -1
    pop     r13
    pop     r12
    ret

; vm_selftest: kernel-side, runs once at boot after init_vm. Allocates one
; frame, maps it kernel-RW (US=0) at virt 0x300000 (3 MiB — outside the
; boot identity range), writes a marker through the new VA, reads it back
; via the identity address (phys = virt under the boot map), unmaps,
; verifies vm_walk reports unmapped, frees the frame. Prints "VM OK" to
; VGA + serial only when every check passes; on any failure the marker is
; omitted and CI sees the missing string.
vm_selftest:
    push    rbx
    push    r12
    push    r13

    mov     rdi, 1
    call    frames_alloc_n
    test    rax, rax
    jz      .fail
    mov     r12, rax

    mov     r13, 0x300000

    mov     rdi, r13
    mov     rsi, r12
    mov     rdx, VM_FLAG_RW
    call    vm_map_4k
    test    rax, rax
    jnz     .fail_free

    mov     rdi, r13
    call    vm_walk
    cmp     rax, r12
    jne     .fail_unmap

    mov     rbx, 0xDEADBEEFCAFEBABE
    mov     [r13], rbx
    mov     rax, [r12]
    cmp     rax, rbx
    jne     .fail_unmap

    mov     rdi, r13
    call    vm_unmap_4k
    test    rax, rax
    jnz     .fail_free

    mov     rdi, r13
    call    vm_walk
    test    rax, rax
    jnz     .fail_free

    mov     rdi, r12
    mov     rsi, 1
    call    frames_free_n

    lea     rdi, [rel msg_vm_ok]
    mov     rsi, 16
    mov     rdx, 0
    call    vga_puts_at
    lea     rdi, [rel msg_vm_ok_serial]
    call    serial_puts

    pop     r13
    pop     r12
    pop     rbx
    ret
.fail_unmap:
    mov     rdi, r13
    call    vm_unmap_4k
.fail_free:
    mov     rdi, r12
    mov     rsi, 1
    call    frames_free_n
.fail:
    pop     r13
    pop     r12
    pop     rbx
    ret
