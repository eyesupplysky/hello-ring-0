/* Kernel linker script. Places .text first (so _start lands at 0x100000 for
 * --oformat=binary), then .rodata, .data; .bss is unused (zero-init regions
 * use fixed physical addresses zeroed at runtime). ELF noise is discarded.
 *
 * Layout symbols consumed by init_page_protect (in M11d's page-protect sweep):
 *   _etext       — page-aligned end of kernel .text. Pages [0x100000, _etext)
 *                  are stamped P only (kernel RO+exec, no US).
 *   _kdata_end   — page-aligned end of kernel .rodata + .data. Pages
 *                  [_etext, _kdata_end) are stamped P|RW|NX (kernel RW data,
 *                  no US).
 *   _user_etext  — page-aligned end of .user_text. Pages [_kdata_end,
 *                  _user_etext) are stamped P|US (ring-3 RO+exec — the shell
 *                  enters here via iretq).
 *   _kernel_end  — end of .user_data, also end of the loaded image. Pages
 *                  [_user_etext, page_align_up(_kernel_end)) are stamped
 *                  P|RW|US|NX (ring-3 RW data — shell line buffer, paths,
 *                  hex scratch).
 *
 * Splitting kernel and user halves with page-aligned boundaries is the only
 * way the per-page PTE protections can match the source-of-truth section
 * the byte was emitted into; otherwise a single page would straddle (e.g.)
 * kernel .text and shell .user_text, and stamping it kernel-only would
 * silently brick the shell. */

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

    . = ALIGN(0x1000);
    _kdata_end = .;

    .user_text : ALIGN(16) {
        *(.user_text)
        *(.user_text.*)
    }

    /* M13c: spawned-process binaries land in `.user2_text` so they share the
     * same US|exec protection range as the shell's `.user_text`. Stays
     * inside [_kdata_end, _user_etext) — init_page_protect's existing sweep
     * stamps both in one pass. */
    .user2_text : ALIGN(16) {
        *(.user2_text)
        *(.user2_text.*)
    }

    . = ALIGN(0x1000);
    _user_etext = .;

    .user_data : ALIGN(16) {
        *(.user_data)
        *(.user_data.*)
    }

    .user2_data : ALIGN(16) {
        *(.user2_data)
        *(.user2_data.*)
    }

    _kernel_end = .;

    /DISCARD/ : {
        *(.note .note.*)
        *(.comment)
        *(.eh_frame)
        *(.eh_frame_hdr)
    }
}
