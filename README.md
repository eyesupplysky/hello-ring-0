# hello-ring-0

x86-64 kernel in NASM, from a 512-byte BIOS sector to ring-3 cooperative multiprocess. Assembly.

No GRUB, no Multiboot, no C, no Rust. The first of four portfolio projects, designed to be readable end-to-end and usable as a starting base for your own kernel work.

## Status

Boots to long mode, sets up paging and per-process address spaces, drops into a ring-3 cooked-mode shell, and can `sys_spawn` a second user-mode process that runs cooperatively alongside it.

What works:

- **Stage 1 boot sector.** BIOS-loaded at 0x7C00. Reads the rest of the image off disk via INT 13h with retry-on-failure, hands off to Stage 2.
- **Stage 2 trampoline.** Enables A20, builds a flat GDT, switches to protected mode, builds 4-level page tables identity-mapping the first 2 MB at 4 KiB granularity, sets PAE + EFER.LME + CR0.PG, far-jumps into 64-bit code, copies the kernel to 1 MB, jumps in.
- **Kernel.**
  - Loads its own GDT and a 256-entry IDT with macro-generated ISR stubs and a common dispatcher.
  - 8259 PIC remap, PIT @ ~100 Hz, PS/2 keyboard with a 256-byte scancode ring buffer.
  - VGA text driver (cursor + absolute-position helpers, with scroll) and 16550 UART polling driver.
  - TSS for ring transitions; user CS/data selectors in the GDT.
  - Bitmap frame allocator (4 KiB pages, phys 0..2 MiB) and a slab kernel heap (`kmalloc` / `kzalloc` / `kfree` / `krealloc`) with size classes 16-2048 plus a large-allocation path.
  - 4 KiB virtual memory: `vm_map_4k` / `vm_unmap_4k` / `vm_walk` / `vm_protect`. Per-PML4 address spaces with kernel-half inheritance via a shared boot PT.
  - W^X kernel image: kernel `.text` RO+exec, kernel `.data` RW+NX, user `.text` US+exec, user `.data` US+RW+NX. EFER.NXE on, `#PF` handler dumps CR2 / RIP / err to serial.
  - Cooperative process model: per-process kernel stacks + vm_space, a circular ready-list ring, `context_switch` saves callee-saved registers + RFLAGS, `sys_yield` round-trips to the next process, `sys_spawn` builds a child with its own address space + user stack, `sys_exit` reaps via a `pending_zombie` hand-off on the next yield.
  - Syscall ABI (`syscall` / `sysretq`, Linux register convention): `sys_read`, `sys_write`, `sys_exit`, `sys_open`, `sys_close`, `sys_mmap`, `sys_munmap`, `sys_yield`, `sys_spawn`, `sys_getpid`. fd table with `/dev/null` and `/dev/zero` wired up.
- **Shell.** Ring-3 cooked-mode line shell. 128-byte buffer with per-keystroke echo, backspace, Ctrl+C cancel, LF commit. Only kernel contact is via `syscall`.

What's not here yet: no preemptive scheduler (yield is cooperative), no filesystem, no disk I/O after boot, no networking, no SMP, no userland loader — user binaries are linked into the kernel image.

## Use this as a base

The kernel is intentionally small — every shortcut taken is documented, and most of them are good first extensions.

Recommended reading order for forking:

1. [`docs/boot-sequence.md`](docs/boot-sequence.md) — what runs when, with an ASCII diagram.
2. [`docs/memory-map.md`](docs/memory-map.md) — physical addresses and what lives where.
3. [`docs/syscall-abi.md`](docs/syscall-abi.md) — register convention and reference for every syscall.
4. [`docs/processes.md`](docs/processes.md) — process model, ready-list, context switch, and why scheduling is cooperative for now.
5. [`docs/kernel-heap.md`](docs/kernel-heap.md) — slab allocator design, size classes, large-allocation path.
6. [`docs/adding-a-syscall.md`](docs/adding-a-syscall.md) and [`docs/adding-a-driver.md`](docs/adding-a-driver.md) — concrete recipes with file diffs.
7. [`docs/minimal.md`](docs/minimal.md) — what's deliberately not done, and a ranked list of good first extensions.

Use the "Use this template" button at the top of the repo to spawn your own copy.

## Build and run

Requires `nasm`, `ld.lld` (from LLVM), and `qemu-system-x86_64` on PATH.

```
./build.sh   # produces build/disk.img
./run.sh     # boots the image headless, asserts VGA checkpoints + serial log
```

Interactive run (you'll see the prompt and can type into it):

```
qemu-system-x86_64 -fda build/disk.img
```

## Layout

```
boot/        Stage 1 + Stage 2 (real → protected → long mode)
kernel/
  cpu/        GDT, IDT, TSS
  interrupts/ ISR dispatcher, PIC, timer, keyboard, page-fault handler
  drivers/    VGA text, 16550 UART
  mm/         frame allocator, kernel heap, paging, vm_spaces, user-VA, page protection
  process/    process_t, ready-list ring, context switch, sys_spawn / sys_yield / sys_exit
  syscall/    MSR setup, syscall entry, fd table, dispatchers
  shell/      ring-3 cooked-mode shell + spawned child binary
docs/        forker reference
build.sh     assemble + link + compose disk.img
run.sh       boot disk.img and verify VGA + serial output
```

## License

[MIT](LICENSE).
