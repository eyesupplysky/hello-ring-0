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
| 0 | `sys_read`  | `int fd, void *buf, size_t count`  | bytes read (always ≤ 1), 0 if `count == 0`, –1 if `fd != 0` |
| 1 | `sys_write` | `int fd, const void *buf, size_t count` | bytes written (= `count`), –1 if `fd ∉ {1, 2}` |
| 2 | `sys_exit`  | `int code` | does not return |

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

Re-enables interrupts and halts the CPU. Timer and keyboard handlers
keep firing — the system stays diagnosable in QEMU even after the
process "exits."

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
