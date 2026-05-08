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
| `0x111800`–`0x13FFFF` | up to 178 KB | Reserved breathing room — `init_frame` reserves the full `[0x100000, 0x140000)` block alongside the kernel image, IDT, and handler table. Not handed out by `frames_alloc_n`. |
| `0x140000`–`0x1FFFFF` | up to 768 KB | **Frame pool** — `frames_alloc_n` hands these out first-fit low-to-high to `sys_mmap` and to the kernel heap (`kmalloc` slab pages and large allocations). Empty kheap slabs are returned to the pool immediately. |
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
| `KERNEL_SYSCALL_STACK_TOP` | `kernel/process/process.asm` (boot_process initializer) | `0x88000` |
| `USER_STACK_TOP` | `kernel/main.asm` | `0x60000` |

A change to any of these tends to ripple — for instance bumping
`KERNEL_DEST` requires a matching `kernel.ld` `.text` base.

## Per-process kernel stacks (M13c)

The two stack regions at `0x80000`–`0x90000` belong to the **boot/shell
process** (pid 0). Spawned processes get their own pair of kernel stacks
allocated from the frame pool — one frame for the syscall stack, one for
the IRQ stack — at allocation time in `sys_spawn`. The slot in
`process_t` stores the *top* of each stack; the *base* is `top -
FRAME_SIZE` (4 KiB).

`syscall_entry` reads the current process's `kernel_syscall_stack_top`
through `current_process` rather than baking the literal, so a process
mid-syscall always lands on its own stack regardless of which process is
"current" at any given moment. `TSS.RSP0` is patched to the current
process's `kernel_irq_stack_top` on every `context_switch` via
`tss_set_rsp0`, so a ring 3 → 0 IRQ also lands on the right stack.

When a spawned process exits, its two kernel stack frames are returned
to the frame pool by `reap_process`. The boot process never enters the
reaper — it's a static `.data` singleton, and `sys_exit` refuses to
unlink pid 0.

## User-VA range

`[0x800000, 0x1000000)` — 8 MiB / 2048 pages — is reserved for ring-3
mappings outside the boot identity map. `sys_mmap` carves contiguous
virt runs here in the **current** vm_space, backed by scattered phys
frames. `sys_spawn` also maps the child's ring-3 user stack at virt
`0x800000` directly into the *child's* vm_space (bypassing the
`user_va_bitmap`, since the mapping is this-space-only). Multiple
processes can hold mappings at the same virt in this range — they live
in different vm_spaces and don't alias.

The bitmap that tracks which user-VA pages are mapped lives at
`user_va_bitmap` in `kernel/mm/user_vm.asm`. It's currently global, not
per-vm_space — see [`processes.md`](processes.md) for the constraint
this implies for any future workload with multiple `sys_mmap` consumers.
