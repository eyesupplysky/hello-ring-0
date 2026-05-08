; Stage 1 boot sector: BIOS-loaded at 0x7C00. Prints "S1 OK", reads 16 sectors
; (Stage 2 + kernel) from disk to 0x7E00, jumps to Stage 2.

[BITS 16]
[ORG 0x7C00]

%define STAGE2_LOAD_SEG     0x0000
%define STAGE2_LOAD_OFF     0x7E00
%define POST_STAGE1_SECTORS 40          ; Stage 2 (8) + kernel (32); SeaBIOS handles cross-track
%define MAX_DISK_RETRIES    3

; Entry point — BIOS jumps here after loading the sector from disk.
stage1_entry:
    cli
    xor     ax, ax
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     sp, 0x7C00
    sti

    mov     [boot_drive], dl

    mov     si, msg_s1_ok
    call    print_string

    call    load_post_stage1

    ; Hand off to Stage 2 with DL = boot drive.
    mov     dl, [boot_drive]
    jmp     STAGE2_LOAD_SEG:STAGE2_LOAD_OFF

.halt:
    cli
    hlt
    jmp     .halt

; Print a NUL-terminated string at DS:SI via BIOS teletype (int 10h, AH=0x0E).
print_string:
    push    ax
    push    bx
    push    si
.next:
    lodsb
    test    al, al
    jz      .done
    mov     ah, 0x0E
    mov     bh, 0x00
    mov     bl, 0x07
    int     0x10
    jmp     .next
.done:
    pop     si
    pop     bx
    pop     ax
    ret

; Read POST_STAGE1_SECTORS sectors from LBA 1 (CHS 0/0/2) to STAGE2_LOAD_SEG:STAGE2_LOAD_OFF.
; Retries up to MAX_DISK_RETRIES on error; halts with "Disk!" on persistent failure.
load_post_stage1:
    pusha
    push    es

    mov     ax, STAGE2_LOAD_SEG
    mov     es, ax
    mov     bx, STAGE2_LOAD_OFF
    mov     byte [retry_count], MAX_DISK_RETRIES

.try:
    mov     ah, 0x02
    mov     al, POST_STAGE1_SECTORS
    mov     ch, 0
    mov     cl, 0x02
    mov     dh, 0
    mov     dl, [boot_drive]
    int     0x13
    jnc     .ok

    xor     ah, ah
    mov     dl, [boot_drive]
    int     0x13
    dec     byte [retry_count]
    jnz     .try

    mov     si, msg_disk_err
    call    print_string
.fail_halt:
    cli
    hlt
    jmp     .fail_halt

.ok:
    pop     es
    popa
    ret

msg_s1_ok:    db "S1 OK", 0x0D, 0x0A, 0
msg_disk_err: db "Disk!", 0
boot_drive:   db 0
retry_count:  db 0

times 510-($-$$) db 0
dw 0xAA55
