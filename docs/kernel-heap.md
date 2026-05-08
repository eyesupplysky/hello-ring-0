# Kernel heap

Kernel-internal allocator on top of the frame allocator. Exposed only to
ring 0 — there is no `sys_kmalloc`, and ring 3 cannot reach it. Lives in
`kernel/mm/kheap.asm`.

The heap is two paths under one API:

- **Slab path** — sizes ≤ 2048 bytes go into segregated freelists, one per
  size class, backed by 4 KiB slab pages drawn lazily from
  `frames_alloc_n`. Allocation and free are O(1) amortized; empty pages
  are returned to the frame pool the moment the last slot is freed.
- **Large path** — sizes > 2048 bytes (or alignments that push the
  effective size past 2048) round up to a whole number of frames, prepend
  a 32-byte header at the start of the first frame, and return a pointer
  inside the allocation. Free hands the frames back via `frames_free_n`.

Both paths share one frame pool with `sys_mmap`. There is no watermark;
mutual starvation is a documented constraint.

## API

All functions follow the project's SystemV-style register convention:
`RDI`/`RSI`/`RDX` for inputs, `RAX` for return, `RBX`/`RBP`/`R12`–`R15`
preserved.

| Function | Inputs | Returns |
|---|---|---|
| `init_kheap` | — | — (boot only) |
| `kmalloc(size, align)` | `RDI`=size, `RSI`=align | `RAX`=ptr or 0 |
| `kzalloc(size, align)` | `RDI`=size, `RSI`=align | `RAX`=zero-filled ptr or 0 |
| `kfree(ptr)` | `RDI`=ptr (0 = no-op) | — |
| `krealloc(ptr, new_size, align)` | `RDI`=ptr, `RSI`=new_size, `RDX`=align | `RAX`=new ptr or 0 |
| `kheap_stats(out_buf)` | `RDI`=64-byte buffer | — |
| `kheap_enter_critical` / `kheap_leave_critical` | — | — (preserves all GPRs, modifies FLAGS) |

### `kmalloc`

Returns `size` writable bytes aligned to `max(align, 16)`. Fails closed
(returns 0) on `size == 0`, `align` not a power of two, `align >
FRAME_SIZE`, or out of memory. Bytes past `size` are not part of the
allocation — do not read or write them. The caller's pointer is the
allocation; nothing precedes it that the caller can rely on.

`align == 0` and `align == 1` mean "natural" — both are normalized to 16.

### `kzalloc`

Same contract as `kmalloc`, but the returned region is zeroed. Only the
contracted `size` bytes are zeroed, not the rounded-up slot.

### `kfree`

Releases a `kmalloc`/`kzalloc`/`krealloc` return value. `kfree(0)` is a
no-op. The free path detects slab vs. large by reading a magic at
`ptr & ~0xFFF`. Magics that match neither are silently ignored — freeing
a non-kheap pointer is undefined; the kernel keeps running.

Double-free of a slab allocation is detected via the per-slot canary and
does not corrupt state — the call simply returns without re-pushing the
slot onto the freelist.

### `krealloc`

`krealloc(0, n, a)` is equivalent to `kmalloc(n, a)`.
`krealloc(p, 0, _)` frees `p` and returns 0.

For non-trivial calls:

- **Slab in-place** — `new_size` ≤ current class's slot size. Returns the
  same pointer; no copy.
- **Large in-place** — `new_size` ≤ `frame_count * 4096 - payload_offset`
  of the current allocation. Updates the header's stored size and returns
  the same pointer.
- **Otherwise** — allocates new, copies `min(old_size, new_size)` bytes,
  frees old. On allocation failure the original pointer remains valid
  and the call returns 0 (glibc-style).

For slab allocations, `old_size` for the copy is the slot size (the
slab path doesn't track requested size). For large allocations,
`old_size` is the requested size stored in the header.

### `kheap_stats`

Copies a 64-byte snapshot of the live counters into the caller's buffer.
Layout (eight `u64`s, in order):

| Offset | Field |
|---:|---|
| 0x00 | `bytes_in_use` (current; sum of slab slot_size + large requested_size) |
| 0x08 | `bytes_peak` (max `bytes_in_use` ever observed) |
| 0x10 | `alloc_count` (cumulative successful `kmalloc`s) |
| 0x18 | `free_count` (cumulative `kfree`s) |
| 0x20 | `slab_pages_owned` (frames currently held as slab pages) |
| 0x28 | `large_allocs_active` (current count of large allocations) |
| 0x30 | `large_bytes_in_use` (current; sum of frame_count × 4096) |
| 0x38 | `alloc_failures` (cumulative `kmalloc` returns of 0) |

The block layout is fixed; appending fields would change the snapshot
length and break callers.

### Locking shim

`kheap_enter_critical` / `kheap_leave_critical` bracket every public
entry. Today they bump and drop a depth counter; the kernel is
single-threaded so this is purely accounting. On SMP day the bodies
become spinlock acquire/release at one site — every existing call site
already brackets correctly.

The shim preserves every general-purpose register; callers may hold
arguments in `RAX` or any other register across the call. It does not
preserve FLAGS.

## Size classes

Ten classes, geometric powers-of-two with two SLUB-style interleavers
(96 and 192) that cut worst-case internal fragmentation in the
small-size regime from ~47% to ~33%.

| Class | slot_size | slots/page | data_offset |
|---:|---:|---:|---:|
| 0 | 16   | 237 | 304  |
| 1 | 32   | 122 | 192  |
| 2 | 64   | 62  | 128  |
| 3 | 96   | 40  | 192  |
| 4 | 128  | 31  | 128  |
| 5 | 192  | 20  | 192  |
| 6 | 256  | 15  | 256  |
| 7 | 512  | 7   | 512  |
| 8 | 1024 | 3   | 1024 |
| 9 | 2048 | 1   | 2048 |

`slot_count` and `data_offset` are precomputed to fit a 64-byte fixed
metadata header plus a `slot_count`-byte canary bitmap into one frame,
with the data area aligned to `slot_size`. The 2048 class wastes ~48% of
its frame on alignment padding — kept for API symmetry; see `RISKS.md`
for the alternative we declined.

## Slab-page format

One 4 KiB frame per slab page.

```
+---------+-------------------------------------------+
| 0x00    | magic = 0x4547415042414C53 ("SLABPAGE")   |
| 0x08    | class_idx (4)                             |
| 0x0C    | slot_size (4)                             |
| 0x10    | slot_count (4)                            |
| 0x14    | slots_in_use (4)                          |
| 0x18    | data_offset (4) + 4 bytes pad             |
| 0x20    | freelist_head (page-relative offset, u64) |
| 0x28    | next_slab_page (u64)                      |
| 0x30    | prev_slab_page (u64)                      |
| 0x38    | reserved (8)                              |
| 0x40    | canary bitmap[slot_count] (1B per slot)   |
|         | (padding to slot_size alignment)          |
| data_   |                                           |
| offset  | slot 0                                    |
| +N×size | slot N                                    |
| 4095    |                                           |
+---------+-------------------------------------------+
```

Free slots are threaded through their own storage: each free slot's
first 8 bytes hold the page-relative offset of the next free slot, with
0 as the terminator. `freelist_head == 0` means the page is full.

Slab pages for one class form a doubly-linked list; the head is held in
`kheap_freelist_heads[class_idx]`. New pages are linked at the head; on
empty, a page is unlinked and its frame returned to `frames_free_n`.

### Per-slot canary

One byte per slot in the page header's canary bitmap, indexed by slot
index.

| Value | Meaning |
|---|---|
| `0xF7` (`CANARY_FREED`) | Initial state on slab init; written by `kfree`. |
| `0xC0` (`CANARY_ALLOC`) | Written by `kmalloc` on allocation. |

`slot_free` requires `0xC0` to proceed; any other value (including
`0xF7`) leaves state unchanged. This catches double-free and
free-of-never-allocated at the cost of one byte per slot. Other use-after-
free patterns are not detected — a freed slot's payload bytes are
overwritten by the freelist next-pointer, but reads from the rest of the
slot still see stale memory until the slot is reallocated.

## Large-allocation format

Page-aligned, multiple consecutive frames. Header lives at offset 0 of
the first frame; payload starts at `payload_offset = max(32, align)`.

```
+---------+-------------------------------------------+
| 0x00    | magic = 0x4D454D454752414C ("LARGEMEM")   |
| 0x08    | frame_count (4)                           |
| 0x0C    | requested_size (4)                        |
| 0x10    | payload_offset (4) + 4 bytes pad          |
| 0x18    | canary = 0xCAFEBA5ECAFEC0DE               |
| 0x20    | payload start (default; aligned at 32)    |
| ...     | payload bytes                             |
| frames* |                                           |
| 4096    |                                           |
+---------+-------------------------------------------+
```

`frame_count` is what `frames_free_n` needs to release the entire
allocation. `payload_offset` lets `kfree` reconstruct the user pointer
from the page boundary and verify match. `requested_size` is the
caller's `size` (used for stats accounting and as the source length on
`krealloc`).

## Initialization order

`init_kheap` runs from `_start` immediately after `init_frame` and
immediately before `kheap_selftest`. It zeroes the freelist heads, the
stats block, and the critical-section depth counter; it does not
allocate. The first `kmalloc` consumer is `kheap_selftest` itself, which
runs in ring 0 before the iretq to ring 3.

## Failure modes

| Condition | Behavior |
|---|---|
| `kmalloc(0, _)` | Returns 0; bumps `alloc_failures`. |
| `kmalloc` with `align` not a power of two or `align > FRAME_SIZE` | Returns 0; bumps `alloc_failures`. |
| Frame allocator empty | Returns 0; bumps `alloc_failures`. |
| `kfree(0)` | No-op. |
| `kfree` of a non-kheap pointer | No state change; silent. |
| Double-free of a slab allocation | No state change; silent (canary mismatch). |
| Large allocation with corrupted header canary | No state change; silent (frames not freed). |
| `krealloc` allocation failure | Returns 0; original pointer remains valid. |

The "silent" cases reflect a deliberate stance: the kernel is small,
its callers are kernel-internal, and a panic on a corrupt pointer would
take the entire system down. We'd rather log when there's a logger and
keep going.
