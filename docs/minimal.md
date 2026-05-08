# Intentionally minimal

This kernel takes shortcuts that a production OS wouldn't — to keep the
total size small enough to read end-to-end in one sitting. Each one is
a place a forker would naturally want to extend.

## Memory model

- **One 2 MB identity-mapped page covers everything.** No virtual
  memory, no demand paging, no per-process address space. Both kernel
  and shell live in the same physical region.
- **`U/S=1` on the entire region.** Ring 3 can read and write any
  identity-mapped address. The kernel/user boundary is enforced by CPL
  on instructions (privileged ops fault), not by page-level access
  control. A real OS would mark kernel pages `U/S=0` and copy buffers
  in and out at the syscall boundary.
- **No NX bit.** `EFER.NXE` is left clear, so every page is executable.
  Real systems set it and mark `.data` / `.bss` no-execute.
- **Bitmap frame allocator over the identity-mapped 2 MB.** 1 bit per
  4 KiB frame, 64 bytes total. `init_frame` reserves the regions
  occupied by BIOS, the user/kernel/syscall stacks, the page tables
  built in Stage 2, the VGA text buffer, and the kernel image. The
  rest is free. First-fit linear scan; supports contiguous-N
  allocation. See [memory-map.md](memory-map.md) for the address-by-
  address breakdown.
- **`sys_mmap` returns physical addresses, not virtual.** Because the
  whole kernel + user space lives in one 2 MB identity map, the
  physical address handed out by `frame_alloc` *is* a usable virtual
  address — the `mmap` syscall just allocates frames and returns the
  start address. No `MAP_FIXED`, no `PROT_*` flags, no separate VA
  space, no TLB invalidation. A real `mmap` would edit page tables;
  this one doesn't.
- **No userland heap.** The shell still uses static `.data` for its
  own state. `mmap` is available but the shell doesn't use it for a
  heap yet.

## Concurrency model

- **Single CPU.** No SMP, no MTRR setup, no APIC, no per-CPU data via
  `swapgs`. The TSS exists for the ring 3 → ring 0 stack swap; that's
  it.
- **Single process.** No fork, no scheduler, no context switching. The
  shell is the only thing running in ring 3 ever.
- **No `swapgs` / no per-CPU GS base.** The syscall entry stub uses a
  fixed memory cell (`saved_user_rsp`) for the user-RSP stash rather
  than per-CPU GS-relative storage. Adding a second CPU breaks this
  immediately.

## Devices

- **PIC, not APIC.** 8259 master/slave, remapped to `0x20–0x2F`. Modern
  systems use IO-APIC + LAPIC, which gives per-IRQ vector routing and
  scales past 16 lines.
- **Polling 16550 UART.** No serial RX driver in tree (see
  [`adding-a-driver.md`](adding-a-driver.md) for the recipe). TX is
  poll-on-LSR, no interrupt-driven completion.
- **No flow control on serial.** RTS/DTR set at init, never inspected.
- **PS/2 keyboard, no controller init.** We trust BIOS to leave the
  PS/2 controller in a sane state and just drain pending bytes before
  unmasking IRQ1. No 8042 init sequence, no scan-code-set selection.
- **No mouse.** PS/2 IRQ12 is unhandled.

## Disk and storage

- **BIOS INT 13h disk reads in Stage 1, then nothing.** Once we leave
  real mode there's no way to read more sectors. The kernel image and
  shell must fit in what Stage 1 already loaded.
- **Cross-track CHS reads.** Stage 1 reads 40 sectors with one INT 13h
  call, crossing track boundaries. SeaBIOS and any modern BIOS handle
  this; some retro hardware doesn't. LBA via INT 13h AH=0x42 would be
  more portable.
- **No filesystem of any kind.** Everything is a fixed disk offset.

## Syscall ABI

- **`sys_read` returns 1 byte at a time on stdin.** `kbd_read` ignores
  `count > 1`. `/dev/zero` respects count and fills the buffer;
  `/dev/null` always returns 0 (EOF). No partial-read loop, no signal
  handling.
- **No errno.** Failures return –1 unconditionally; no way to
  distinguish "bad fd" from "buffer full."
- **No buffer validation.** Pointers passed across the syscall boundary
  are dereferenced directly. A user pointer outside identity-mapped
  RAM faults. A real OS uses `copy_from_user` / `copy_to_user`.
- **Tiny fd table; two paths only.** The fd table has 16 slots,
  pre-populated at boot with `0 = keyboard`, `1/2 = VGA+serial`.
  `sys_open` recognizes exactly two paths — `/dev/null` and
  `/dev/zero` — by direct `strcmp`. There's no inode, no filesystem,
  no permission model, no `flags` interpretation. `sys_close` refuses
  to free fd 0/1/2 so the shell can't accidentally brick its own I/O.

## Input

- **Shift, caps lock, and ctrl/alt modifiers are tracked.** Shift state,
  caps lock, ctrl, and alt are tracked in the kernel and applied during
  scancode translation in `sys_read`. Two parallel 128-byte LUTs
  (unshifted + shifted); caps lock toggles letter case as a post-step;
  Ctrl+letter is folded to ASCII control codes (Ctrl+A=0x01,
  Ctrl+C=0x03, …, Ctrl+Z=0x1A) via `& 0x1F` and supersedes caps lock.
  Alt is tracked but produces no output — there's no consumer for it
  yet. Right-side ctrl/alt work transparently (the 0xE0 prefix is
  filtered as a stray break code; the suffix scancode matches the
  left-side variant).
- **Line buffer with destructive backspace, Ctrl+C aborts; no in-line
  cursor movement.** The shell maintains a 128-byte line buffer.
  Printable bytes echo per keystroke. Backspace decrements the buffer
  and echoes `\b`; the kernel's `vga_putc` overwrites the prior glyph
  with a space. Ctrl+C echoes `^C`, drops the in-flight line, and
  re-emits the prompt. Enter commits the line and resets the buffer —
  the line processor itself is a no-op stub for now. No left/right
  arrow movement, no kill-line, no Ctrl+L clear-screen, no history.
- **No keyboard repeat handling.** Hold-key behavior is whatever the
  PS/2 controller sends.

## What this kernel does NOT promise

- Booting on real hardware. It runs in QEMU; results on physical
  machines depend on BIOS quirks (disk-read geometry, A20 method, PIC
  state at handoff).
- Long-running stability. There's no panic handler, no fault recovery,
  no timer drift correction.
- Compatibility with multiboot loaders. Stage 1 owns the boot sector.

## What's a good first extension?

In rough order of payoff vs effort:

1. **A new syscall** (see [`adding-a-syscall.md`](adding-a-syscall.md)).
2. **A second user process** + a tiny scheduler.
3. **Real virtual memory.** Split the 2 MB huge page into 4 KiB pages,
   give `sys_mmap` a `MAP_FIXED` semantics, and edit the page tables
   on each map/unmap. Adds `invlpg` for TLB invalidation.
4. **More devices in `/dev/`** — `/dev/random` (small LCG), a raw
   `/dev/serial`, etc. Add a path branch in `sys_open` and wire up
   read/write handlers.
5. **Ctrl+L clear-screen** — needs either a `sys_clear` syscall or
   ANSI escape parsing in `vga_putc`.
