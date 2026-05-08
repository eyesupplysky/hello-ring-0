; Stage 2: real mode → A20 → GDT → protected mode → 4-level paging → long mode →
; copy kernel from 0x8E00 to 0x100000 → jump to kernel.

[BITS 16]
[ORG 0x7E00]

%define STAGE2_STACK_TOP    0x7C00
%define KERNEL_LOAD_SRC     0x8E00          ; where Stage 1 placed the kernel image
%define KERNEL_DEST         0x100000        ; 1 MB
%define KERNEL_COPY_BYTES   0x7000          ; 56 sectors = 28 KB max

%define PML4_ADDR           0x70000
%define PDPT_ADDR           0x71000
%define PD_ADDR             0x72000
%define PT_ADDR             0x73000

%define CODE32_SEL          0x08
%define DATA_SEL            0x10
%define CODE64_SEL          0x18

; Stage 2 entry — Stage 1 jumps here in real mode with DL = boot drive.
stage2_entry:
    cli
    xor     ax, ax
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     sp, STAGE2_STACK_TOP
    sti

    mov     [boot_drive_s2], dl

    mov     si, msg_s2_ok
    call    print_string16

    call    enable_a20

    cli
    lgdt    [gdt_descriptor]

    mov     eax, cr0
    or      eax, 1
    mov     cr0, eax

    jmp     CODE32_SEL:pm32_entry

; Print a NUL-terminated string at DS:SI via BIOS teletype (int 10h, AH=0x0E).
print_string16:
    push    ax
    push    bx
    push    si
.next:
    lodsb
    test    al, al
    jz      .done
    mov     ah, 0x0E
    mov     bh, 0
    mov     bl, 0x07
    int     0x10
    jmp     .next
.done:
    pop     si
    pop     bx
    pop     ax
    ret

; Enable A20 via System Control Port A (0x92, bit 1 = A20 enable, bit 0 = fast reset).
enable_a20:
    in      al, 0x92
    test    al, 2
    jnz     .done
    or      al, 2
    and     al, 0xFE
    out     0x92, al
.done:
    ret

[BITS 32]

; Protected-mode trampoline. Builds page tables, enables PAE, sets EFER.LME,
; turns on paging, then far-jmps to a 64-bit code segment.
pm32_entry:
    mov     ax, DATA_SEL
    mov     ds, ax
    mov     es, ax
    mov     fs, ax
    mov     gs, ax
    mov     ss, ax
    mov     esp, STAGE2_STACK_TOP

    call    build_page_tables

    mov     eax, PML4_ADDR
    mov     cr3, eax

    mov     eax, cr4
    or      eax, 1 << 5                    ; CR4.PAE
    mov     cr4, eax

    mov     ecx, 0xC0000080                ; IA32_EFER
    rdmsr
    or      eax, 1 << 8                    ; EFER.LME
    wrmsr

    mov     eax, cr0
    or      eax, 1 << 31                   ; CR0.PG
    mov     cr0, eax

    jmp     CODE64_SEL:lm_entry

; Zero PML4/PDPT/PD/PT (16 KB), then identity-map the first 2 MB at 4 KiB
; granularity: PML4[0] -> PDPT[0] -> PD[0] -> PT[0..512], each PT entry
; mapping a single 4 KiB page. M11a switched away from the original 2 MB
; PS=1 leaf to give the kernel per-page granularity (vm_map_4k consumers).
build_page_tables:
    mov     edi, PML4_ADDR
    xor     eax, eax
    mov     ecx, 0x4000 / 4
    rep     stosd

    mov     dword [PML4_ADDR], PDPT_ADDR | 0x07         ; U|RW|P
    mov     dword [PDPT_ADDR], PD_ADDR   | 0x07         ; U|RW|P
    mov     dword [PD_ADDR],   PT_ADDR   | 0x07         ; U|RW|P (no PS — points at PT)

    mov     edi, PT_ADDR
    mov     eax, 0x000 | 0x07                           ; first PT entry: phys 0, U|RW|P
    mov     ecx, 512
.pt_fill:
    mov     [edi], eax
    mov     dword [edi + 4], 0
    add     eax, 0x1000
    add     edi, 8
    dec     ecx
    jnz     .pt_fill
    ret

[BITS 64]

; Long-mode trampoline. Reloads data segments, copies kernel to 0x100000, jumps in.
lm_entry:
    mov     ax, DATA_SEL
    mov     ds, ax
    mov     es, ax
    mov     fs, ax
    mov     gs, ax
    mov     ss, ax

    mov     rsi, KERNEL_LOAD_SRC
    mov     rdi, KERNEL_DEST
    mov     rcx, KERNEL_COPY_BYTES
    rep     movsb

    jmp     KERNEL_DEST

; -------------------- data --------------------

boot_drive_s2:  db 0
msg_s2_ok:      db "S2 OK", 0x0D, 0x0A, 0

align 8
gdt_start:
    dq 0                                        ; null descriptor
    ; 32-bit code: base 0, limit 4 GiB, ring 0
    dw 0xFFFF, 0x0000
    db 0x00, 10011010b, 11001111b, 0x00
    ; data: base 0, limit 4 GiB, ring 0
    dw 0xFFFF, 0x0000
    db 0x00, 10010010b, 11001111b, 0x00
    ; 64-bit code: L=1, D=0
    dw 0xFFFF, 0x0000
    db 0x00, 10011010b, 10101111b, 0x00
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

; Pad to 8 sectors so the kernel lives at a known on-disk offset.
times (8 * 512) - ($ - $$) db 0
