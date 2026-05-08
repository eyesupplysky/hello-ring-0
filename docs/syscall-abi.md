# Syscall ABI

Modern x86_64 path: user code executes the `syscall` instruction; the CPU
loads `RIP` from `LSTAR`, `CS`/`SS` from `STAR`, masks `RFLAGS` with
`FMASK`, and saves the user `RIP` in `RCX` and the user `RFLAGS` in `R11`.
The kernel's entry stub swaps to a kernel stack, dispatches by syscall
number, and returns via `sysretq`, which restores `CS`/`SS`/`RIP`/`RFLAGS`
from `STAR`/`RCX`/`R11` and drops back to ring 3.

## Register convention

Linux-compatible. **Caller does:**

| Register | Role |
|---|---|
| `RAX` | syscall number |
| `RDI` | arg 1 |
| `RSI` | arg 2 |
| `RDX` | arg 3 |
| `R10` | arg 4 (not RCX — `syscall` clobbers RCX with the saved RIP) |
| `R8`  | arg 5 |
| `R9`  | arg 6 |

**Kernel returns:**

| Register | Role |
|---|---|
| `RAX` | return value (≥ 0 on success, –1 on error) |
| `RCX` | clobbered (was the saved user RIP) |
| `R11` | clobbered (was the saved user RFLAGS) |
| `RDI`, `RSI`, `RDX`, `R10`, `R8`, `R9` | clobbered (caller-saved per SystemV) |
| `RBX`, `RBP`, `R12`–`R15` | preserved (callee-saved) |

The first three args (`RDI`/`RSI`/`RDX`) match the SystemV AMD64 calling
convention exactly, so syscall handlers written as ordinary functions
work without any register remap. For arg 4+, the entry stub would need
to copy `R10` into `RCX` before the call; current handlers all stop at
3 args.

## Syscall reference

| # | Name | Args | Returns |
|---|---|---|---|
| 0 | `sys_read`   | `int fd, void *buf, size_t count`  | bytes read (always ≤ 1), 0 if `count == 0`, –1 on bad fd |
| 1 | `sys_write`  | `int fd, const void *buf, size_t count` | bytes written, –1 on bad fd |
| 2 | `sys_exit`   | `int code` | does not return |
| 3 | `sys_open`   | `const char *path, int flags` | new fd, or –1 |
| 4 | `sys_close`  | `int fd` | 0, or –1 if `fd ∈ {0, 1, 2}` or unallocated |
| 5 | `sys_mmap`   | `size_t pages` | virt of a `pages`-page contiguous run in `[0x800000, 0x1000000)`, or –1 |
| 6 | `sys_munmap` | `void *virt, size_t pages` | 0, or –1 on bad alignment / out-of-range |
| 7 | `sys_yield`  | — | 0 (always) |
| 8 | `sys_spawn`  | `void *entry_addr` | new pid (≥ 1), or –1 |
| 9 | `sys_getpid` | — | current pid |

### `sys_read`

Reads from `fd 0` (stdin). Blocks until at least one printable scancode
arrives, decoded through `kernel/syscall/handlers.asm:scancode_to_ascii`.
Break codes (high bit set) and unmapped scancodes are silently dropped
and the wait continues. Always returns at most 1 byte regardless of
`count > 1`.

The wait loop uses the canonical `cli; check; sti; hlt; jmp` race-free
sleep — `sti`'s one-instruction shadow guarantees any pending IRQ fires
exactly when `hlt` begins, so we either see the buffer non-empty on the
next check or get woken by the IRQ that filled it.

### `sys_write`

Writes `count` bytes from `buf` byte-by-byte through `vga_putc` and
`serial_putc`. `fd 1` (stdout) and `fd 2` (stderr) both go to both
sinks; there's currently no separation between them.

### `sys_exit`

Pid 0 (the boot/shell process) re-enables interrupts and halts the CPU —
timer and keyboard handlers keep firing, system stays diagnosable. Any
other pid unlinks itself from the ready ring, hands its `process_t` to
`pending_zombie`, and `context_switch`es to its successor; the next
`sys_yield` after the switch reaps the zombie's `vm_space`, two kernel
stack frames, and `process_t`. See [`processes.md`](processes.md) for the
lifecycle.

### `sys_open` / `sys_close`

`sys_open` recognizes `/dev/null` and `/dev/zero`; anything else returns
–1. `flags` is currently ignored. `sys_close` refuses fd 0/1/2 (closing
stdin/stdout/stderr would brick the shell with no way to reopen them).
The fd table is 16 slots, defined in `kernel/syscall/fd.asm`.

### `sys_mmap` / `sys_munmap`

`sys_mmap(pages)` allocates a `pages`-page contiguous virt run in
`[0x800000, 0x1000000)` (8 MiB / 2048 pages of user-VA window) and backs
each page with a freshly allocated physical frame, mapped `P|RW|US` in
the current vm_space. Phys frames are scattered; only the virt range is
contiguous. Atomic: on partial-map failure, every page mapped before the
failing one is `vm_unmap_4k`'d, every frame freed, and the user-VA bitmap
range cleared — the caller observes –1 and no kernel state changes.

`sys_munmap(virt, pages)` walks the page-table tree to recover each
page's phys, frees the frame, unmaps the leaf, and clears the bitmap.
Out-of-range or misaligned addresses return –1; pages that were already
unmapped are silently skipped (the bitmap clear still happens).

### `sys_yield` / `sys_spawn` / `sys_getpid`

Process-control syscalls — see [`processes.md`](processes.md) for the
cooperative scheduling model and lifecycle. Briefly: `sys_yield` switches
to `current_process->next_proc` (yield-to-self when the ring has one
node); `sys_spawn(entry_addr)` allocates a fresh process with its own
vm_space, kernel stacks, and user stack at virt `0x800000`, returning
the new pid; `sys_getpid` returns the current pid.

## Calling example

```nasm
section .data
msg:     db "hello", 0x0A
msg_len  equ $ - msg

section .text
example:
    ; sys_write(1, msg, msg_len)
    mov     rax, 1
    mov     rdi, 1
    lea     rsi, [rel msg]
    mov     rdx, msg_len
    syscall
    ; rax = bytes written, or -1

    ; sys_exit(0)
    mov     rax, 2
    xor     rdi, rdi
    syscall
    ; never returns
```

## What the kernel guarantees

- `RBX`, `RBP`, `R12`–`R15` are preserved across the call.
- `RFLAGS` is restored to its value at the `syscall` instruction (modulo
  `FMASK` clearing on entry — `R11` carries the original through and
  `sysretq` restores it).
- Syscall numbers ≥ `syscall_table_size` and entries equal to 0 in the
  table both return –1.
- The kernel never panics on a user-supplied buffer pointer. (It also
  doesn't validate them — passing a pointer outside the identity-mapped
  region will fault. Real OSes copy_from_user / copy_to_user; we don't.)

## Adding more syscalls

See [`adding-a-syscall.md`](adding-a-syscall.md).
