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
- **No memory allocator.** Everything that needs RAM gets a hardcoded
  physical address baked into the source. See [memory-map.md](memory-map.md).
- **No userland heap.** The shell uses static `.data` only.

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

- **`sys_read` returns 1 byte at a time.** Ignores `count > 1`. A
  proper implementation would loop until count is satisfied or the
  buffer's empty.
- **No errno.** Failures return –1 unconditionally; no way to
  distinguish "bad fd" from "buffer full."
- **No buffer validation.** Pointers passed across the syscall boundary
  are dereferenced directly. A user pointer outside identity-mapped
  RAM faults. A real OS uses `copy_from_user` / `copy_to_user`.
- **fds are positional, not allocated.** 0 = keyboard, 1/2 = VGA+serial,
  no `open`, no descriptor table.

## Input

- **No shift / caps / control / alt.** The 128-byte scancode LUT covers
  unshifted ASCII only. Adding shift state is a small extension —
  track LShift/RShift make/break (scancodes `0x2A` / `0x36` / `0xAA` /
  `0xB6`) and pick from a second LUT when shifted.
- **No line editing.** Backspace just decrements the VGA cursor; the
  glyph stays on screen. Enter has no buffer-flush semantics — every
  keystroke is `sys_read`-ed and `sys_write`-d immediately.
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

1. **Shift / caps lock** in the scancode translator — tiny diff, big
   ergonomic win.
2. **Backspace that erases** (vga_putc emits `\b ` `\b` to clear).
3. **A line buffer** in the shell, so the user can edit before
   pressing Enter and the program reads whole lines.
4. **A new syscall** (see [`adding-a-syscall.md`](adding-a-syscall.md)).
5. **`sys_open` / `sys_close` and a proper fd table.**
6. **A real frame allocator** so you can `mmap` pages.
7. **A second user process** + a tiny scheduler.
