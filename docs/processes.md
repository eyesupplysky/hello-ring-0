# Processes

Single CPU, cooperative scheduling, no preemption. Two processes ship in the
default boot path: the boot/shell process (pid 0, running the cooked-mode
shell from `kernel/shell/main.asm`) and a spawned child (pid 1, running
`child_main` from `kernel/shell/child.asm`). The shell's `spawn_selftest`
exercises the full lifecycle on every boot — spawn → yield → child runs →
child exits → parent reaps → parent prints `S OK`.

## The model

A process owns four kernel resources:

| Resource | Purpose |
|---|---|
| `process_t` struct | bookkeeping (pid, vm_space\*, two stack tops, saved kernel rsp, ready-list links) |
| `vm_space_t` | the address space — its own PML4/PDPT/PD, sharing the boot PT for the low 2 MiB |
| Kernel syscall stack | one 4 KiB frame; `syscall_entry` switches to its top on every `syscall` |
| Kernel IRQ stack | one 4 KiB frame; loaded into `TSS.RSP0` on every ring 3 → 0 transition |

The boot process is a static `.data` singleton — it pre-exists `init_kheap`
and uses the fixed kernel stacks at `0x80000`–`0x90000` from M4. Spawned
processes get all four resources from `kmalloc` / `frame_alloc`, and they're
freed (in reverse order) when the process exits and is reaped.

The set of currently-runnable processes lives in a circular doubly-linked
ring rooted at `boot_process`. `current_process` always points at one node
in the ring; `sys_yield` walks `current_process->next_proc`. The ring is
never empty — `sys_exit` refuses to unlink pid 0 — so `sys_yield` always
has somewhere to go.

## Cooperative, not preemptive

The kernel never preempts a running process. Control switches happen only
when the process explicitly calls `sys_yield`, `sys_spawn`, or `sys_exit` —
each of those goes through `context_switch`, which:

1. Pushes `RFLAGS` + the SystemV callee-saved GPRs (`RBX`, `RBP`, `R12`–`R15`) onto the current process's kernel syscall stack.
2. Snapshots `RSP` into the leaving process's `saved_kernel_rsp`.
3. Loads `RSP` from the entering process's `saved_kernel_rsp`.
4. Reloads `CR3` via `vm_space_switch`.
5. Patches `TSS.RSP0` via `tss_set_rsp0` to the entering process's irq stack.
6. Updates `current_process`.
7. Pops the 6 GPRs + `RFLAGS` from the new stack, `ret`s into the new process's frozen continuation.

For a brand-new spawned process the "frozen continuation" is hand-built by
`sys_spawn` — the pop+`ret` lands at `spawn_trampoline`, which `iretq`s into
ring 3 at the entry address.

The deliberate choice to defer preemption: timer-driven context switching
adds a real scheduler (policy, fairness, accounting) and forces the
context-save path to handle interrupts arriving in arbitrary kernel state.
Cooperative scheduling lets us land the address-space machinery — which is
the actual interesting milestone — without those concerns. The `process_t`
struct, `context_switch` primitive, and ring-list discipline are all
preemption-ready; what's missing is a timer ISR that calls `context_switch`
on every tick, plus a state field (`ready` / `running` / `blocked`) so the
scheduler can skip processes mid-`sys_read`.

## Lifecycle

```
                                          ┌──────────────┐
   sys_spawn(entry_addr)                  │  pending_    │
   ─────────────►  alloc → ring insert    │   zombie     │
                       │                  └──────┬───────┘
                       ▼                         ▲
                  ┌─────────┐                    │ set
                  │ running │ ◄─── context_switch│
                  └─┬─────┬─┘                    │
        sys_yield   │     │  sys_exit            │
                    ▼     ▼                      │
              context_switch  unlink ring + ─────┘
              (round-trips     context_switch (never returns)
               to peer)
                       
   reap_process (called from sys_yield post-switch):
       vm_space_destroy → frames_free_n × 2 → kfree
```

`sys_exit` doesn't free its own resources — the dying process is still
running on its own kernel stack right up to the `context_switch` call, so
freeing them would pull the rug out. Instead it stashes itself in
`pending_zombie` and switches away. The next process's `sys_yield`, after
`context_switch` returns, picks up `pending_zombie` and frees everything.

## Syscalls

| # | Name | Args | Returns | Notes |
|---|---|---|---|---|
| 7 | `sys_yield` | — | 0 | Switches to `current_process->next_proc`. Yield-to-self is a degenerate no-op round-trip. |
| 8 | `sys_spawn` | `void *entry_addr` | new pid, or –1 | Allocates a fresh `process_t`, two kernel stack frames, a new `vm_space_t`, and the child's user stack frame (mapped at virt `0x800000` in the child's vm_space). Hand-builds the kernel-stack save frame so the next `context_switch` into the child pops to ring 3 at `entry_addr` via `iretq`. Atomic: any allocation failure rolls back every prior step. |
| 9 | `sys_getpid` | — | current pid | M13a marker for the per-process indirection — proves `current_process` is wired and `syscall_entry` reads its `kernel_syscall_stack_top` slot rather than a baked literal. |

`sys_exit` (syscall 2) was rewritten to be process-aware in M13c. Pid 0
(boot/shell) falls back to the original M4 behavior — `sti; hlt` loop,
keeps the system diagnosable. Any other pid unlinks from the ring, hands
itself to `pending_zombie`, and `context_switch`es to its `next_proc`.

## Constraints

- The user-virt allocator (`user_va_bitmap` in `kernel/mm/user_vm.asm`) is
  one global bitmap shared across vm_spaces. Today only the boot/shell
  process calls `sys_mmap`, so no conflict surfaces — but two processes
  both calling `sys_mmap` would collide on bitmap accounting even though
  their actual mappings live in different vm_spaces. The fix (per-vm_space
  bitmap) is deferred until a milestone has multiple `sys_mmap` consumers.
- The pid allocator is a monotonic counter with no recycling — fine for
  the two-process demo, will need a slot allocator before any long-running
  workload.
- Spawned processes share `.user2_text` / `.user2_data` via the boot
  identity map under PD[0], so multiple instances of the same child share
  the same code and data section. M13c's child only writes to its own
  user stack, so no cross-instance state pollution; future shared writes
  would need either copy-on-spawn or explicit per-process data regions.
- `pending_zombie` holds at most one process. Two processes calling
  `sys_exit` between yields would lose the second corpse. Fine in M13c
  (only one spawned process can exit at a time), would need a linked
  zombie list under any multi-spawn workload.

## Reading more

- `kernel/process/process.asm` — `process_t` layout, `context_switch`, `sys_yield`, `sys_spawn`, `sys_exit`, `reap_process`, `spawn_trampoline`.
- `kernel/syscall/entry.asm` — per-process kernel-stack indirection and
  user RSP carried on the kernel syscall stack so peer syscalls can't
  clobber a paused process's RSP.
- `kernel/cpu/tss.asm` — `tss_set_rsp0` for per-process IRQ stack swaps.
- `kernel/shell/child.asm` — the embedded second user binary.
- `kernel/shell/main.asm` — `spawn_selftest` exercises the full lifecycle.
