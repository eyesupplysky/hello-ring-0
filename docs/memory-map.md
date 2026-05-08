# Memory map

All addresses physical. The kernel never sets up virtual memory beyond the
single 2 MB identity-mapped page covering `0x000000–0x1FFFFF`, so virtual
== physical throughout. PML4 / PDPT / PD entries all carry `U/S=1`, so
ring 3 can read and write any of these addresses; the kernel/user boundary
is enforced by CPL on instructions, not by page protection.

| Range | Size | Purpose |
|---|---:|---|
| `0x000000`–`0x0004FF` | 1.25 KB | BIOS data area / IVT (real-mode legacy) |
| `0x000500`–`0x007BFF` | ~30 KB | free conventional memory |
| `0x007C00`–`0x007DFF` | 512 B | Stage 1, BIOS-loaded, overwritten after handoff |
| `0x007E00`–`0x008DFF` | 4 KB | Stage 2 image (loaded by Stage 1, kept resident) |
| `0x008E00`–`0x00CDFF` | 16 KB | Kernel image post-load; copied to `0x100000` then unused |
| `0x010000`–`0x05FFFF` | 320 KB | free; user-mode stack grows down into here |
| `0x060000` | — | `USER_STACK_TOP` — ring 3 RSP starts here |
| `0x070000`–`0x070FFF` | 4 KB | PML4 |
| `0x071000`–`0x071FFF` | 4 KB | PDPT |
| `0x072000`–`0x072FFF` | 4 KB | PD (one entry: 2 MB page at base 0, PS\|U\|RW\|P) |
| `0x080000`–`0x087FFF` | 32 KB | free; syscall kernel stack grows down into here |
| `0x088000` | — | `KERNEL_SYSCALL_STACK_TOP` — `syscall` handler RSP loaded here |
| `0x088000`–`0x08FFFF` | 32 KB | free; IRQ kernel stack grows down into here |
| `0x090000` | — | `TSS.RSP0` — RSP loaded here on ring 3 → ring 0 IRQ transitions |
| `0x09FC00`–`0x09FFFF` | 1 KB | EBDA (BIOS reserved, do not touch) |
| `0x0A0000`–`0x0BFFFF` | 128 KB | VGA framebuffer / MMIO |
| `0x0B8000`–`0x0B8F9F` | 4000 B | VGA text buffer (80×25 char/attr pairs) |
| `0x100000`–`0x103FFF` | up to 16 KB | Kernel `.text` + `.rodata` + `.data` (linked at this base, executed in place) |
| `0x110000`–`0x110FFF` | 4 KB | IDT (256 × 16-byte gate descriptors) |
| `0x111000`–`0x1117FF` | 2 KB | Handler table (256 × 8-byte function pointers, used by `isr_common` dispatch) |
| `0x111800`–`0x1FFFFF` | rest of 2 MB | unused |
| `0x200000` and beyond | — | not mapped — accesses fault |

## Stack sizing

The two ring 0 stacks are adjacent (`0x80000–0x88000` for syscall,
`0x88000–0x90000` for IRQs) but never used simultaneously: a syscall
handler runs with `IF=0` (FMASK clears it), so no IRQ fires onto its
stack; an IRQ from ring 3 uses `TSS.RSP0=0x90000`, switching only on the
CPL change. The user stack at `0x60000` has ~320 KB of headroom growing
down before it'd reach the page tables at `0x70000`.

`sys_read` is the one place an IRQ can fire while a syscall handler is
on the stack — its `sti+hlt` sleep enables interrupts. In that case the
CPU is already in ring 0, so it pushes the IRQ frame onto the **current**
stack (the syscall stack at `0x88000` region), not `TSS.RSP0`. Both
flows share the syscall stack; IRQ frames are at most ~150 bytes and
`hlt` doesn't grow the stack between IRQs, so this is safe in practice.

## Hardcoded address constants

If you move things around, these defines are the load-bearing ones:

| Constant | Defined in | Address |
|---|---|---|
| `STAGE2_LOAD_OFF` | `boot/stage1.asm` | `0x7E00` |
| `KERNEL_LOAD_SRC` | `boot/stage2.asm` | `0x8E00` |
| `KERNEL_DEST` | `boot/stage2.asm` | `0x100000` |
| `PML4_ADDR` | `boot/stage2.asm` | `0x70000` |
| `IDT_ADDR` | `kernel/cpu/idt.asm` | `0x110000` |
| `HANDLER_TABLE_ADDR` | `kernel/interrupts/isr_common.asm` | `0x111000` |
| `KERNEL_STACK_TOP` (TSS.RSP0) | `kernel/cpu/tss.asm` | `0x90000` |
| `KERNEL_SYSCALL_STACK_TOP` | `kernel/syscall/entry.asm` | `0x88000` |
| `USER_STACK_TOP` | `kernel/main.asm` | `0x60000` |

A change to any of these tends to ripple — for instance bumping
`KERNEL_DEST` requires a matching `kernel.ld` `.text` base.
