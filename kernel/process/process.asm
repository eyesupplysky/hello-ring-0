; Process abstraction. M13a introduced the data structure and the syscall-entry
; indirection; M13b adds context_switch + sys_yield so a process can park
; itself mid-syscall and resume another process's mid-syscall continuation.
; M13c lands sys_spawn / sys_exit + a circular doubly-linked ready list so a
; second process with its own vm_space and kernel stacks can run cooperatively
; alongside the boot/shell process.
;
; process_t layout (56 bytes; offsets duplicated as %defines below and in any
; consumer that dereferences a process_t — kept in sync the same way
; FD_TABLE_SIZE is in fd.asm + handlers.asm):
;
;   +0x00 pid                          quad. 0 is the boot process (the shell);
;                                      sys_spawn assigns pid = 1, 2, ...
;                                      monotonically.
;   +0x08 vm_space                     vm_space_t*. The address space this
;                                      process runs in. context_switch loads
;                                      CR3 from vm_space->pml4_phys via
;                                      vm_space_switch.
;   +0x10 kernel_syscall_stack_top     qword. RSP that syscall_entry switches
;                                      to before any stack-touching instruction.
;                                      Replaces the literal
;                                      KERNEL_SYSCALL_STACK_TOP that
;                                      kernel/syscall/entry.asm baked in
;                                      pre-M13a. Spawned processes get one
;                                      frame_alloc'd 4 KiB frame; the slot
;                                      stores the TOP, so the base is
;                                      `top - FRAME_SIZE`.
;   +0x18 kernel_irq_stack_top         qword. RSP loaded into TSS.RSP0 when
;                                      this process is current; used by IRQs
;                                      from ring 3. context_switch patches
;                                      TSS.RSP0 from this slot on every swap
;                                      via tss_set_rsp0. Same per-process
;                                      sizing rule as the syscall stack.
;   +0x20 saved_kernel_rsp             qword (M13b). RSP snapshot taken when
;                                      this process was last switched OUT —
;                                      points at the top of its frozen
;                                      mid-syscall save area on its kernel
;                                      stack (RFLAGS + 6 callee-saved GPRs +
;                                      the return-address chain back through
;                                      sys_yield -> syscall_entry .return,
;                                      OR a hand-built spawn frame for a
;                                      brand-new process — see sys_spawn).
;                                      For the boot process the slot starts
;                                      at 0; the first context_switch writes
;                                      it before reading it back, so the 0 is
;                                      never observed.
;   +0x28 next_proc                    process_t* (M13c). Next process in the
;                                      circular doubly-linked ready list.
;   +0x30 prev_proc                    process_t* (M13c). Previous in the
;                                      same ring. boot_process starts as a
;                                      singleton (next = prev = self).
;
; The boot process (pid 0) is a static singleton in .data so it exists before
; init_kheap and so a stray free path can't reach it (it is not kmalloc'd).
; sys_exit specifically refuses to reap pid 0 — falls back to the M4b halt
; behavior.

[BITS 64]

global init_process
global sys_getpid
global sys_yield
global sys_spawn
global sys_exit
global context_switch
global current_process

extern get_boot_vm_space
extern vm_space_create
extern vm_space_destroy
extern vm_space_switch
extern vm_map_4k
extern tss_set_rsp0
extern kmalloc
extern kfree
extern frames_alloc_n
extern frames_free_n

%define PROC_OFF_PID                  0x00
%define PROC_OFF_VM_SPACE             0x08
%define PROC_OFF_KERNEL_SYSCALL_RSP   0x10
%define PROC_OFF_KERNEL_IRQ_RSP       0x18
%define PROC_OFF_SAVED_KRSP           0x20
%define PROC_OFF_NEXT                 0x28
%define PROC_OFF_PREV                 0x30
%define PROC_T_SIZE                   0x38

%define FRAME_SIZE                    0x1000

; Selector + RFLAGS literals duplicated from kernel/main.asm. The values are
; baked into the GDT layout (RISKS.md "GDT layout"); reordering selectors
; means updating both files. Kept as %defines because NASM symbols don't
; cross object-file boundaries.
%define USER_DATA_SEL                 (0x18 | 3)
%define USER_CODE_SEL                 (0x20 | 3)
%define USER_RFLAGS_INIT              0x202        ; reserved bit 1 + IF (bit 9)
%define KERNEL_RFLAGS_INIT            0x002        ; reserved bit 1 only — IF=0
                                                  ; on first kernel-side resume

; PTE flag bits used when mapping the child's user stack into its vm_space.
; Duplicated rather than imported because vm.asm uses internal-only %defines.
%define PTE_P                         0x01
%define PTE_RW                        0x02
%define PTE_US                        0x04

; Where the child's user stack lives in the child's vm_space. Inside the
; user-VA window [0x800000, 0x1000000) tracked nominally by user_va_bitmap,
; but we bypass that bitmap and vm_map_4k directly — the mapping is
; this-space-only and never observed by the parent's bitmap accounting.
; See RISKS.md "user_va_bitmap shared across vm_spaces".
%define USER2_STACK_BASE              0x800000
%define USER2_STACK_TOP               0x801000

; Boot process's two kernel stacks. Today these are the same regions
; init_frame reserves at [0x80000, 0x90000): syscall stack tops at 0x88000,
; irq stack tops at 0x90000 (= TSS.RSP0 written by init_tss). M13c will mint
; per-process stacks for spawned processes from kmalloc.
%define KERNEL_SYSCALL_STACK_TOP      0x88000
%define KERNEL_IRQ_STACK_TOP          0x90000

section .data

; The boot process. Pid 0; vm_space slot is filled in by init_process from
; get_boot_vm_space (boot_vm_space's address is not a link-time constant we
; want to bake in here — go through the accessor so the dependency on
; init_vm_space having run is explicit).
;            kernel/syscall/entry.asm dereferences at PROC_OFF_KERNEL_SYSCALL_RSP
align 16
boot_process:
    dq 0                              ; +0x00 pid
    dq 0                              ; +0x08 vm_space — patched by init_process
    dq KERNEL_SYSCALL_STACK_TOP       ; +0x10 kernel_syscall_stack_top
    dq KERNEL_IRQ_STACK_TOP           ; +0x18 kernel_irq_stack_top
    dq 0                              ; +0x20 saved_kernel_rsp — written on first context_switch
    dq 0                              ; +0x28 next_proc — patched by init_process to self
    dq 0                              ; +0x30 prev_proc — patched by init_process to self

; Pointer to the currently-executing process. syscall_entry reads this every
; syscall to locate the kernel syscall stack. Initialized to boot_process so
; the first syscall after the iretq into ring 3 finds a live process_t.
;            destroyed process_t
current_process: dq boot_process

; Reaping handoff (M13c). sys_exit unlinks the dying process, stores its
; pointer here, then context_switches away — never returning. The first
; sys_yield that runs after the switch picks the pointer up and calls
; reap_process to free vm_space + kernel stacks + struct, then clears the
; slot. boot_process can never land here (sys_exit refuses pid 0).
pending_zombie: dq 0

; Monotonic pid allocator. boot_process is pid 0; sys_spawn assigns 1, 2, ...
; without recycling. Wraps after 2^64 — not a concern for M13c's two-process
; demo and easy to swap for a slot allocator later if needed.
next_pid: dq 1

section .text

; init_process: boot-time hookup. M13a: store boot_vm_space in the boot
; process's vm_space slot. M13c: initialize the ready-list links so boot_process
; forms a singleton circular ring (next = prev = self). After this call,
; current_process is fully initialized and both syscall_entry and sys_yield
; can dereference it safely.
;            boot_vm_space.pml4_phys having been populated)
init_process:
    call    get_boot_vm_space
    mov     [rel boot_process + PROC_OFF_VM_SPACE], rax
    lea     rax, [rel boot_process]
    mov     [rel boot_process + PROC_OFF_NEXT], rax
    mov     [rel boot_process + PROC_OFF_PREV], rax
    ret

; sys_getpid() -> rax: current process's pid.
; M13a: only the boot process exists, so this returns 0. M13c will spawn
; further processes with pid 1, 2, ... and this dispatch picks up the live
; current_process automatically.
sys_getpid:
    mov     rax, [rel current_process]
    mov     rax, [rax + PROC_OFF_PID]
    ret

; context_switch(rdi=prev, rsi=next): freeze prev's mid-syscall continuation
; and resume next's. Saves RFLAGS + the SystemV callee-saved GPRs (RBX, RBP,
; R12-R15) onto prev's kernel syscall stack, snapshots RSP into
; prev->saved_kernel_rsp, loads RSP from next->saved_kernel_rsp, swaps CR3 via
; vm_space_switch, patches TSS.RSP0 via tss_set_rsp0, updates current_process,
; then unwinds the new stack (popfq + 6 pops) and rets — landing at next's
; sys_yield continuation, which in turn returns to next's syscall_entry
; .return path and sysretq's back to ring 3.
;
; Yield-to-self (M13b selftest): prev = next = current_process. The save area
; is written and then read back; CR3 / TSS.RSP0 / current_process all
; round-trip to the same values; the pops restore what the pushes put down.
; Any corruption between save and restore would surface as a wrong RBX/RBP/
; R12-R15 sentinel after sys_yield returns — exactly what yield_selftest
; checks.
;
; Brand-new processes (M13c sys_spawn): the spawner hand-builds a save frame
; on the new kernel stack so this routine's pop+ret sequence lands at a
; trampoline that iretq's into ring 3. M13b never exercises that path; the
; selftest only swaps to and from the boot process.
;
;            FMASK on syscall entry, so no IRQ can land between the rsp swap
;            and the current_process update — both halves see consistent state)
;            stack the pushes target; next->saved_kernel_rsp must be either
;            the previous saved frame or a hand-built spawn frame
;            calls to vm_space_switch / tss_set_rsp0 — sys_yield does not
;            rely on any of those past this call
context_switch:
    pushfq
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15

    mov     [rdi + PROC_OFF_SAVED_KRSP], rsp
    mov     rsp, [rsi + PROC_OFF_SAVED_KRSP]

    push    rsi                                 ; preserve next across calls
    mov     rdi, [rsi + PROC_OFF_VM_SPACE]
    call    vm_space_switch
    mov     rsi, [rsp]                          ; reload (call may clobber rsi)
    mov     rdi, [rsi + PROC_OFF_KERNEL_IRQ_RSP]
    call    tss_set_rsp0
    pop     rsi

    mov     [rel current_process], rsi

    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    popfq
    ret

; sys_yield() -> rax: 0. Switches to current_process->next_proc via
; context_switch. With one process in the ring (boot at boot, M13a/b
; selftests) next == self, so this becomes a yield-to-self round-trip; with
; two or more processes (M13c after sys_spawn) next is a peer and control
; transfers to its frozen mid-syscall continuation.
;
; After context_switch returns we may have just resumed from a peer that
; called sys_exit and left its corpse pinned in pending_zombie. Reaping is
; safe here because context_switch already swapped CR3 off the dying
; process's vm_space and rsp off its kernel stack.
sys_yield:
    mov     rdi, [rel current_process]
    mov     rsi, [rdi + PROC_OFF_NEXT]
    call    context_switch

    mov     rdi, [rel pending_zombie]
    test    rdi, rdi
    jz      .done
    mov     qword [rel pending_zombie], 0
    call    reap_process
.done:
    xor     rax, rax
    ret

; sys_spawn(rdi=entry_addr) -> rax: pid of the new process, or -1 on any
; failure. Allocates the process_t, two kernel stacks (one frame each), a
; brand-new vm_space, and the child's ring-3 user stack — then hand-builds
; the kernel-stack save frame so the next context_switch into this process
; pops to ring 3 at entry_addr via iretq.
;
; Atomicity: every step has a labelled rollback target. On failure of step N,
; the .fail_N target unwinds steps 1..N-1 (in reverse) and returns -1; the
; ready list is never touched until the final step succeeds, so the parent
; observes a clean -1 with no half-built peer.
;
; The ring-3 user stack is mapped DIRECTLY into the child's vm_space via
; vm_map_4k (we briefly switch CR3 to the child to do this), bypassing
; user_va_bitmap. The bitmap is shared across vm_spaces today (M13c didn't
; per-space-ize it — see RISKS.md "user_va_bitmap shared across vm_spaces"),
; but the child's stack mapping at virt 0x800000 is not visible from the
; parent's CR3 anyway, so no conflict surfaces in M13c's two-process demo.
;
;            vm_space at the moment of iretq — the boot identity map (PD[0])
;            is shared, and `.user2_text` lives inside it (page-aligned by
;            kernel.ld), so any address in the embedded child binary works.
sys_spawn:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15

    mov     rbx, rdi                            ; rbx = entry_addr (callee-saved)

    ; Step 1: kmalloc process_t.
    mov     rdi, PROC_T_SIZE
    mov     rsi, 16
    call    kmalloc
    test    rax, rax
    jz      .fail_proc
    mov     r12, rax                            ; r12 = new process_t*

    ; Step 2: frame_alloc kernel syscall stack (1 frame = 4 KiB).
    mov     rdi, 1
    call    frames_alloc_n
    test    rax, rax
    jz      .fail_kstack
    mov     r13, rax                            ; r13 = ksyscall_base

    ; Step 3: frame_alloc kernel irq stack.
    mov     rdi, 1
    call    frames_alloc_n
    test    rax, rax
    jz      .fail_irqstack
    mov     r14, rax                            ; r14 = kirq_base

    ; Step 4: vm_space_create (returns a kmalloc'd struct + 3 fresh frames
    ; with shared boot PT via PD[0]). Internal OOM unwinds itself.
    call    vm_space_create
    test    rax, rax
    jz      .fail_vmspace
    mov     r15, rax                            ; r15 = vm_space_t*

    ; Step 5: frame_alloc the child's ring-3 user stack frame.
    mov     rdi, 1
    call    frames_alloc_n
    test    rax, rax
    jz      .fail_ustack
    mov     rbp, rax                            ; rbp = ustack_phys

    ; Step 6: switch CR3 to child, vm_map_4k the user stack, switch back.
    ; vm_map_4k may allocate intermediate PT pages internally; on OOM there
    ; the leaf isn't installed and we own the cleanup of ustack_phys.
    mov     rdi, r15
    call    vm_space_switch
    mov     rdi, USER2_STACK_BASE
    mov     rsi, rbp
    mov     rdx, PTE_P | PTE_RW | PTE_US
    call    vm_map_4k
    test    rax, rax
    js      .fail_map_pre_switchback

    mov     rdi, [rel current_process]
    mov     rdi, [rdi + PROC_OFF_VM_SPACE]
    call    vm_space_switch

    ; Step 7: populate process_t fields (pid, vm_space, both stack tops).
    mov     rax, [rel next_pid]
    mov     [r12 + PROC_OFF_PID], rax
    inc     qword [rel next_pid]

    mov     [r12 + PROC_OFF_VM_SPACE], r15

    mov     rax, r13
    add     rax, FRAME_SIZE
    mov     [r12 + PROC_OFF_KERNEL_SYSCALL_RSP], rax

    mov     rax, r14
    add     rax, FRAME_SIZE
    mov     [r12 + PROC_OFF_KERNEL_IRQ_RSP], rax

    ; Step 8: hand-build the initial save frame on the child's kernel syscall
    ; stack so context_switch's pop+ret sequence lands at spawn_trampoline,
    ; which iretq's into ring 3 at entry_addr.
    ;
    ; Layout from low (= saved_kernel_rsp) upward to ksyscall_top:
    ;   [r15 = 0]                           <- saved_kernel_rsp
    ;   [r14 = 0]
    ;   [r13 = 0]
    ;   [r12 = 0]
    ;   [rbp = 0]
    ;   [rbx = 0]
    ;   [rflags = KERNEL_RFLAGS_INIT]       (popfq target — IF=0)
    ;   [ret-addr = &spawn_trampoline]      (ret target)
    ;   [user RIP = entry_addr]             (iretq frame: bottom)
    ;   [user CS = USER_CODE_SEL]
    ;   [user RFLAGS = USER_RFLAGS_INIT]    (IF=1 in ring 3)
    ;   [user RSP = USER2_STACK_TOP]
    ;   [user SS = USER_DATA_SEL]           (iretq frame: top)
    mov     rax, r13
    add     rax, FRAME_SIZE                     ; rax = ksyscall_top

    sub     rax, 8
    mov     qword [rax], USER_DATA_SEL
    sub     rax, 8
    mov     qword [rax], USER2_STACK_TOP
    sub     rax, 8
    mov     qword [rax], USER_RFLAGS_INIT
    sub     rax, 8
    mov     qword [rax], USER_CODE_SEL
    sub     rax, 8
    mov     [rax], rbx                          ; user RIP = entry_addr
    sub     rax, 8
    lea     rcx, [rel spawn_trampoline]
    mov     [rax], rcx
    sub     rax, 8
    mov     qword [rax], KERNEL_RFLAGS_INIT
    sub     rax, 8
    mov     qword [rax], 0                      ; rbx
    sub     rax, 8
    mov     qword [rax], 0                      ; rbp
    sub     rax, 8
    mov     qword [rax], 0                      ; r12
    sub     rax, 8
    mov     qword [rax], 0                      ; r13
    sub     rax, 8
    mov     qword [rax], 0                      ; r14
    sub     rax, 8
    mov     qword [rax], 0                      ; r15

    mov     [r12 + PROC_OFF_SAVED_KRSP], rax

    ; Step 9: insert child into ready list AFTER current. Doubly-linked
    ; circular: child.prev = current; child.next = current.next;
    ; current.next.prev = child; current.next = child.
    mov     rdi, [rel current_process]
    mov     rcx, [rdi + PROC_OFF_NEXT]          ; rcx = current.next
    mov     [r12 + PROC_OFF_PREV], rdi
    mov     [r12 + PROC_OFF_NEXT], rcx
    mov     [rcx + PROC_OFF_PREV], r12
    mov     [rdi + PROC_OFF_NEXT], r12

    mov     rax, [r12 + PROC_OFF_PID]
    jmp     .done

.fail_map_pre_switchback:
    ; vm_map_4k failed while CR3 was set to child. Switch back to parent
    ; before doing anything else (kheap and frame_alloc work in either CR3
    ; via the shared boot PT, but the rest of the rollback expects parent's
    ; view).
    mov     rdi, [rel current_process]
    mov     rdi, [rdi + PROC_OFF_VM_SPACE]
    call    vm_space_switch
    mov     rdi, rbp
    mov     rsi, 1
    call    frames_free_n
.fail_ustack:
    mov     rdi, r15
    call    vm_space_destroy
.fail_vmspace:
    mov     rdi, r14
    mov     rsi, 1
    call    frames_free_n
.fail_irqstack:
    mov     rdi, r13
    mov     rsi, 1
    call    frames_free_n
.fail_kstack:
    mov     rdi, r12
    call    kfree
.fail_proc:
    mov     rax, -1
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; spawn_trampoline: target of the hand-built ret-addr in a brand-new
; process's initial save frame. context_switch's pop+ret unwinds the 7
; saved slots and rets here; rsp now points at the iretq frame
; (RIP / CS / RFLAGS / RSP / SS) the spawner placed immediately above. The
; iretq atomically loads CS/SS/RFLAGS/RIP/RSP and switches CPL — the new
; process executes its first instruction at entry_addr in ring 3.
;            this out unconditionally
spawn_trampoline:
    iretq

; reap_process(rdi=process_t*): tear down a zombie. Frees, in order, the
; child's vm_space (which walks PD[1..511] and unwinds every leaf + PT page),
; then the syscall and irq kernel stacks (1 frame each, base computed as
; top - FRAME_SIZE), then the process_t struct itself.
;
; Caller must have already ensured CR3 is no longer the zombie's vm_space
; and that rsp is no longer on the zombie's kernel stack — sys_yield's
; post-context_switch position satisfies both.
;
;            would corrupt the kernel image and leave the kernel without a
;            process_t at all)
reap_process:
    push    rbx
    mov     rbx, rdi

    mov     rdi, [rbx + PROC_OFF_VM_SPACE]
    call    vm_space_destroy

    mov     rdi, [rbx + PROC_OFF_KERNEL_SYSCALL_RSP]
    sub     rdi, FRAME_SIZE
    mov     rsi, 1
    call    frames_free_n

    mov     rdi, [rbx + PROC_OFF_KERNEL_IRQ_RSP]
    sub     rdi, FRAME_SIZE
    mov     rsi, 1
    call    frames_free_n

    mov     rdi, rbx
    call    kfree

    pop     rbx
    ret

; sys_exit(rdi=code): never returns. Pid 0 (boot_process) falls back to the
; pre-M13c halt — interrupts re-enabled, hlt loop. Otherwise: unlink current
; from the ready list, hand the corpse to pending_zombie, and context_switch
; to current.next; that next process's sys_yield reaps the zombie when it
; returns from the switch.
;            past the call only as defensive halts
sys_exit:
    mov     rax, [rel current_process]
    cmp     qword [rax + PROC_OFF_PID], 0
    je      .boot_halt

    ; Unlink. current.prev.next = current.next; current.next.prev = current.prev.
    mov     rdi, [rax + PROC_OFF_PREV]
    mov     rsi, [rax + PROC_OFF_NEXT]
    mov     [rdi + PROC_OFF_NEXT], rsi
    mov     [rsi + PROC_OFF_PREV], rdi

    mov     [rel pending_zombie], rax

    ; context_switch(prev = self, next = current.next).
    mov     rdi, rax
    ; rsi already = current.next
    call    context_switch

    ; Unreachable.
.unreachable:
    cli
    hlt
    jmp     .unreachable

.boot_halt:
    sti
.boot_loop:
    hlt
    jmp     .boot_loop
