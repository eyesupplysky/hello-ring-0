# hello-ring-0

A small x86_64 kernel I'm writing in NASM, from a 512-byte BIOS boot sector through 64-bit long mode. No GRUB, no Multiboot, no C, no Rust — just assembly all the way down.

The first of four portfolio projects.

## Status

Boots to long mode, drops into a ring-3 line-echo shell that talks to the kernel through `syscall`.

What works:

- **Stage 1 boot sector.** BIOS-loaded at 0x7C00. Reads the rest of the image off disk via INT 13h with retry-on-failure, hands off to Stage 2.
- **Stage 2 trampoline.** Enables A20, builds a flat GDT, switches to protected mode, identity-maps the first 2 MB with one 2 MB page, sets PAE + EFER.LME + CR0.PG, far-jumps into 64-bit code, copies the kernel to 1 MB, jumps in.
- **Kernel.**
  - Loads its own GDT and a 256-entry IDT with macro-generated ISR stubs and a common dispatcher.
  - 8259 PIC remap, PIT @ ~100 Hz, PS/2 keyboard with a 256-byte scancode ring buffer.
  - VGA text driver (cursor + absolute-position helpers, with scroll) and 16550 UART polling driver.
  - TSS for ring transitions; user CS/data selectors in the GDT.
  - Syscall ABI (`syscall`/`sysretq`): `sys_read`, `sys_write`, `sys_exit`.
- **Shell.** Ring-3 line-echo loop. Only kernel contact is via `syscall`.

What's coming: CI, docs, polish.

## Build and run

Requires `nasm`, `ld.lld` (from LLVM), and `qemu-system-x86_64` on PATH.

```
./build.sh   # produces build/disk.img
./run.sh     # boots the image headless, asserts VGA checkpoints + serial log
```

Interactive run:

```
qemu-system-x86_64 -fda build/disk.img
```

## Layout

```
boot/        Stage 1 + Stage 2 (real → protected → long mode)
kernel/
  cpu/        GDT, IDT, TSS
  interrupts/ ISR dispatcher, PIC, timer, keyboard
  drivers/    VGA text, 16550 UART
  syscall/    MSR setup, syscall entry, sys_read/sys_write/sys_exit
  shell/      ring-3 line-echo shell
build.sh     assemble + link + compose disk.img
run.sh       boot disk.img and verify VGA + serial output
```

## License

[MIT](LICENSE).
