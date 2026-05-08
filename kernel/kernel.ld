/* Kernel linker script. Places .text first (so _start lands at 0x100000 for
 * --oformat=binary), then .rodata, .data; .bss is unused (zero-init regions
 * use fixed physical addresses zeroed at runtime). ELF noise is discarded.
 *
 * M11d adds two symbols and one alignment:
 *   _etext       — page-aligned end of .text. init_page_protect uses it to
 *                  mark pages [0x100000, _etext) as RO (kernel code).
 *   _kernel_end  — end of the loaded image (after .data). init_page_protect
 *                  rounds it up to a page and marks pages [_etext, end) as
 *                  RW+NX (kernel data). The page-align before _etext costs
 *                  some padding inside the 16 KiB image but is required
 *                  for per-page protection — the unit of protection is one
 *                  PTE, so the .text/.data boundary must be page-aligned. */

ENTRY(_start)

SECTIONS {
    . = 0x100000;

    .text : ALIGN(16) {
        *(.text._start)
        *(.text)
        *(.text.*)
    }

    . = ALIGN(0x1000);
    _etext = .;

    .rodata : ALIGN(16) {
        *(.rodata)
        *(.rodata.*)
    }

    .data : ALIGN(16) {
        *(.data)
        *(.data.*)
    }

    _kernel_end = .;

    /DISCARD/ : {
        *(.note .note.*)
        *(.comment)
        *(.eh_frame)
        *(.eh_frame_hdr)
    }
}
