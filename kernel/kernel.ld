/* Kernel linker script. Places .text first (so _start lands at 0x100000 for
 * --oformat=binary), then .rodata, .data; .bss is unused (zero-init regions
 * use fixed physical addresses zeroed at runtime). ELF noise is discarded. */

ENTRY(_start)

SECTIONS {
    . = 0x100000;

    .text : ALIGN(16) {
        *(.text._start)
        *(.text)
        *(.text.*)
    }

    .rodata : ALIGN(16) {
        *(.rodata)
        *(.rodata.*)
    }

    .data : ALIGN(16) {
        *(.data)
        *(.data.*)
    }

    /DISCARD/ : {
        *(.note .note.*)
        *(.comment)
        *(.eh_frame)
        *(.eh_frame_hdr)
    }
}
