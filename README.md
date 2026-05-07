# hello-ring-0

A small x86_64 kernel I'm writing in NASM, from a 512-byte BIOS boot sector through 64-bit long mode. No GRUB, no Multiboot, no C, no Rust — just assembly all the way down.

The first of four portfolio projects.

## Status

Boots to long mode and writes to the VGA text buffer. That's it for now.

What works:

- **Stage 1 boot sector.** BIOS-loaded at 0x7C00. Reads the rest of the image off disk via INT 13h with retry-on-failure, hands off to Stage 2.
- **Stage 2 trampoline.** Enables A20, builds a flat GDT, switches to protected mode, identity-maps the first 2 MB with one 2 MB page, sets PAE + EFER.LME + CR0.PG, far-jumps into 64-bit code, copies the kernel to 1 MB, jumps in.
- **Kernel.** Writes "K OK" directly into 0xB8000 and halts.

What's coming: a GDT/IDT proper, PIT timer + PS/2 keyboard, VGA + 16550 UART drivers, a small syscall ABI, a line-echo shell on top.

## Build and run

Requires `nasm`, `ld.lld` (from LLVM), and `qemu-system-x86_64` on PATH.

```
./build.sh   # produces build/disk.img
./run.sh     # boots the image headless and asserts S1/S2/K reach VGA
```

Interactive run:

```
qemu-system-x86_64 -fda build/disk.img
```

## Layout

```
boot/        Stage 1 + Stage 2 (real → protected → long mode)
kernel/      64-bit kernel
build.sh     assemble + link + compose disk.img
run.sh       boot disk.img and verify VGA output
```

## License

[MIT](LICENSE).
