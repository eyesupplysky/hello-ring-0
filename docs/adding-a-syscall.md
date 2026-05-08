# Adding a syscall

Concrete recipe. The example: a `sys_uptime` syscall (number 3) that
returns the number of timer ticks since boot.

## 1. Implement the handler

Open `kernel/syscall/handlers.asm` and add a new function. The kernel
already exports `tick_count` from `kernel/interrupts/timer.asm`, so we
import it.

```nasm
extern tick_count                       ; add to existing externs

; ...

; sys_uptime() — returns the tick counter (currently ~100 ticks/sec).
sys_uptime:
    mov     rax, [rel tick_count]
    ret
```

## 2. Wire it into the dispatch table

Same file. Add a `global` declaration up top and a table entry.

```diff
 global syscall_table
 global syscall_table_size
 global sys_read
 global sys_write
 global sys_exit
+global sys_uptime
```

```diff
 syscall_table:
     dq sys_read                     ; 0
     dq sys_write                    ; 1
     dq sys_exit                     ; 2
+    dq sys_uptime                   ; 3

-syscall_table_size: dq 3
+syscall_table_size: dq 4
```

The dispatcher (`kernel/syscall/entry.asm`) reads
`[syscall_table_size]` and rejects numbers `≥` it. Bumping the size is
the one-line change that makes the new entry reachable.

## 3. Build and verify it dispatches

```
./build.sh
```

That's the whole kernel-side change — no other files need editing.

## 4. Call it from user mode

Modify `kernel/shell/main.asm` (or write a separate user-mode test) to
invoke the new syscall. Quickest test:

```nasm
.loop:
    mov     rax, 3                  ; sys_uptime
    syscall
    ; rax now holds the tick count

    ; ... do something visible with it, e.g. write low byte as hex via sys_write
```

Run `./run.sh` and verify the value moves over time.

## Conventions worth preserving

- **First three args go in `RDI`/`RSI`/`RDX`.** SystemV calling
  convention matches our syscall convention for the first three slots,
  so handlers can be written as plain functions.
- **For arg 4+, you'll need to remap `R10` into `RCX`** before the
  `call rcx` in `kernel/syscall/entry.asm`. None of the current handlers
  need it; add it when the first 4-arg syscall lands.
- **Handler must preserve `RBX`, `RBP`, `R12`–`R15`** per SystemV
  callee-saved discipline. The dispatcher does not save them.
- **Return value goes in `RAX`.** Convention is ≥ 0 for success, –1 for
  error. We don't have errno; –1 is the universal failure sentinel.
- **Don't enable interrupts unless you're prepared for re-entry.**
  Syscall entry runs with `IF=0` (FMASK clears it). `sti` is fine if
  your handler can tolerate IRQs landing on its stack — `sys_read` does
  this for its sleep loop.

## When to split a handler into its own file

The current convention is "all syscall handlers in one file." If a
handler grows past ~50 lines or pulls in significant data tables (the
scancode LUT in `sys_read` is the example), split into a separate
`kernel/syscall/sys_<name>.asm` and add it to `KERNEL_SRCS` in
`build.sh`. Cohesion over enumeration.
