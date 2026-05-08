# Boot sequence

What happens between BIOS handoff and the shell's first prompt.

```
BIOS POST
   │
   │  reads sector 0 → 0x7C00, jumps there
   ▼
Stage 1 — boot/stage1.asm @ 0x7C00 (real mode, 16-bit)
   │  • DS=ES=SS=0, SP=0x7C00; prints "S1 OK" via INT 10h teletype
   │  • INT 13h AH=02 reads 40 sectors from LBA 1 → 0x0000:0x7E00
   │    (8 sectors of Stage 2 + 32 sectors of kernel image, retried 3x)
   │  • jmp 0x0000:0x7E00
   ▼
Stage 2 — boot/stage2.asm @ 0x7E00 (real → long mode trampoline)
   │  • prints "S2 OK"
   │  • enables A20 via port 0x92 (set bit 1; never touch bit 0 — that's reset)
   │  • LGDT (null + 32-bit code + flat data + 64-bit code)
   │  • CR0.PE = 1
   │  • jmp 0x08:pm32_entry  (far jump reloads CS, enters protected mode)
   │
   ├─▶ pm32_entry — 32-bit protected mode, [BITS 32]
   │     • reload DS/ES/FS/GS/SS with 0x10, ESP = 0x7C00
   │     • build_page_tables zeroes PML4 / PDPT / PD at 0x70000–0x72FFF
   │       and writes one 2 MB identity-mapped PD entry with PS|U|RW|P (0x87)
   │     • CR3 = 0x70000
   │     • CR4.PAE = 1
   │     • EFER.LME = 1
   │     • CR0.PG  = 1     (paging on; CPU enters compatibility submode)
   │     • jmp 0x18:lm_entry  (far jump to 64-bit code segment → 64-bit mode)
   │
   └─▶ lm_entry — 64-bit long mode
         • reload data segs with 0x10
         • rep movsb: copy 0x4000 bytes from 0x8E00 → 0x100000 (kernel image)
         • jmp 0x100000  (kernel _start)
   ▼
Kernel _start — kernel/main.asm @ 0x100000 (64-bit, ring 0)
   │  • vga_init, serial_init
   │  • init_gdt   — kernel-resident GDT replaces Stage 2's transient one;
   │                 null / kcode 0x08 / kdata 0x10 / udata 0x18 / ucode 0x20 / TSS slot 0x28
   │  • init_tss   — patch TSS descriptor with the runtime TSS address; LTR with 0x28
   │  • init_interrupts
   │       — zero IDT memory at 0x110000
   │       — install all 256 gates pointing to their isr_stub_N
   │       — fill handler table at 0x111000 with default_handler
   │       — register #DE (vector 0), IRQ0 (0x20), IRQ1 (0x21)
   │  • init_pic   — 8259 remap: master 0x20–0x27, slave 0x28–0x2F; mask all
   │  • init_pit   — channel 0 at ~100 Hz, unmask IRQ0
   │  • init_kbd   — drain stale bytes from PS/2 controller, unmask IRQ1
   │  • init_syscall — EFER.SCE, STAR, LSTAR (= syscall_entry), FMASK
   │  • prints "K OK" to VGA + serial
   │  • iretq frame: SS=0x18|3, RSP=0x60000, RFLAGS=IF, CS=0x20|3, RIP=shell_main
   │  • iretq → ring 3 (atomically: switches CPL, enables IF, jumps to user)
   ▼
Shell shell_main — kernel/shell/main.asm (64-bit, ring 3)
      • sys_write(1, "> ", 2)
      • loop:
          sys_read(0, &c, 1)        ── blocks via cli/check/sti+hlt until
          sys_write(1, &c, 1)         the keyboard IRQ handler enqueues
          if c == '\n':               a printable scancode; sys_read drains
              sys_write(1, "> ", 2)   it through the scancode→ASCII LUT
```

After the shell starts, interrupts keep firing. Timer (IRQ0) and keyboard (IRQ1) handlers run in ring 0; the CPU loads `TSS.RSP0 = 0x90000` for every ring 3 → ring 0 transition, so handler stacks never collide with user-mode RSP.

The same iretq trick at the bottom of `_start` — pushing a fake interrupt frame onto the kernel stack and executing `iretq` — is how every x86_64 kernel first enters user mode. There's no "switch to ring 3" instruction; you fake a return from a hypothetical interrupt that came from ring 3.

## Selectors and rings at each point

| Phase | CPL | CS | DS / SS | Mode |
|---|---|---|---|---|
| Stage 1 | 0 | (real, base=0x0000) | 0x0000 | 16-bit real |
| Stage 2 trampoline | 0 | 0x08 / 0x18 | 0x10 | 16 → 32 → 64-bit |
| Kernel after `init_gdt` | 0 | 0x08 | 0x10 | 64-bit |
| Shell after `iretq` | 3 | 0x20 \| 3 | 0x18 \| 3 | 64-bit |
| IRQ from ring 3 | 0 | 0x08 (from gate) | 0x10 (from TSS.RSP0) | 64-bit |
| `syscall` from ring 3 | 0 | 0x08 (from STAR) | 0x10 (from STAR) | 64-bit |

`sysretq` reverses the syscall transition: CS = STAR[63:48]+16 = 0x20, SS = STAR[63:48]+8 = 0x18, both with RPL=3.
