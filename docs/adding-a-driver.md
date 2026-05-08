# Adding a driver

The kernel's existing drivers (`kernel/drivers/vga.asm`,
`kernel/drivers/serial.asm`) and IRQ-driven subsystems
(`kernel/interrupts/timer.asm`, `kernel/interrupts/keyboard.asm`)
follow the same pattern. This recipe walks through adding a new one.
The example: a serial RX driver — currently the UART is TX-only (writes
go out, nothing reads back).

## The pattern

For a polling driver (no IRQs):

1. Write `kernel/drivers/<name>.asm` exporting an init function and one
   or more I/O functions.
2. Add the file to `KERNEL_SRCS` in `build.sh`.
3. Call the init function from `kernel/main.asm`'s `_start` (somewhere
   in the boot sequence).

For an interrupt-driven subsystem, add three more steps:

4. Write a handler function (`handler_irq<N>`) — typically lives in
   `kernel/interrupts/<name>.asm`.
5. Register it in `init_interrupts` (`kernel/interrupts/isr_common.asm`)
   at the appropriate vector (`0x20 + IRQ_NUMBER` for master PIC,
   `0x28 + IRQ_NUMBER - 8` for slave).
6. Unmask the IRQ via `pic_unmask_irq` from your init function.

## Walkthrough: serial RX

The 16550 UART's data port (0x3F8) is the same for read and write; LSR
bit 0 tells you when a byte has been received. Polling form:

### Step 1 — driver file

`kernel/drivers/serial_rx.asm`:

```nasm
[BITS 64]

global serial_has_rx
global serial_getc

%define COM1_DATA       0x3F8
%define COM1_LINE_STS   0x3FD
%define LSR_DR          0x01            ; data ready

section .text

; serial_has_rx() -> bool in RAX
serial_has_rx:
    mov     dx, COM1_LINE_STS
    in      al, dx
    and     rax, 1                      ; 1 if DR set, 0 otherwise
    ret

; serial_getc() -> byte in RAX (blocking)
serial_getc:
    push    rdx
    mov     dx, COM1_LINE_STS
.wait:
    in      al, dx
    test    al, LSR_DR
    jz      .wait
    mov     dx, COM1_DATA
    in      al, dx
    movzx   rax, al
    pop     rdx
    ret
```

No init needed — `serial_init` in the existing TX driver already enables
RX FIFO via `LCR=0x03` and `FCR=0xC7`.

### Step 2 — `KERNEL_SRCS`

```diff
 KERNEL_SRCS=(
     "kernel/main.asm"
     ...
     "kernel/drivers/vga.asm"
     "kernel/drivers/serial.asm"
+    "kernel/drivers/serial_rx.asm"
     ...
 )
```

### Step 3 — use it

There's no init step for this one (shared init with TX). Reference it
from anywhere. For example, you could expose it via a new syscall —
`sys_read` with `fd=3` reading from serial instead of keyboard — or
use it directly from kernel code.

## Walkthrough: a new IRQ-driven device

Suppose you wanted to add the RTC at IRQ 8 (slave PIC).

### Steps 4–6

`kernel/interrupts/rtc.asm`:

```nasm
[BITS 64]

global init_rtc
global handler_irq8
global rtc_seconds

extern pic_send_eoi
extern pic_unmask_irq

section .data
rtc_seconds: dq 0

section .text

init_rtc:
    ; ... configure RTC registers via 0x70/0x71 to enable periodic IRQ ...
    mov     rdi, 8                      ; IRQ number
    call    pic_unmask_irq
    ret

handler_irq8:
    inc     qword [rel rtc_seconds]
    ; ... read CMOS register C to acknowledge the RTC ...
    mov     rdi, 8
    call    pic_send_eoi
    ret
```

Register the handler in `kernel/interrupts/isr_common.asm` inside
`init_interrupts`:

```diff
+extern handler_irq8
+
 init_interrupts:
     ...
     mov     rdi, 0x21                           ; vector 0x21 = IRQ1 (PS/2 keyboard)
     lea     rsi, [rel handler_irq1]
     call    set_isr
+
+    mov     rdi, 0x28                           ; vector 0x28 = IRQ8 (RTC, slave PIC)
+    lea     rsi, [rel handler_irq8]
+    call    set_isr
     ...
```

Add the file to `KERNEL_SRCS` and call `init_rtc` from `_start`. That's
all the wiring.

## Why so spread out?

Five files for one IRQ-driven device feels heavy. The split is
deliberate — each file owns one concern (the device, the IRQ
registration, the boot sequence, the build inputs) so future
additions don't accidentally touch unrelated parts.

If you're prototyping and don't need that separation, write the whole
thing inline in `kernel/main.asm` and split when it earns its keep.

## Things to know

- **PIC EOI** must be the last PIC interaction in any IRQ handler
  before its `ret`/`iretq`. For IRQs ≥ 8, EOI must go to **both**
  master and slave — `pic_send_eoi` handles that.
- **Don't `sti` inside an IRQ handler** unless you've thought about
  re-entry. The IDT gates are interrupt gates, so `IF` is auto-cleared
  on entry — leave it cleared until `iretq`.
- **`isr_common` saves all 15 GPRs**, so handlers can clobber freely
  without push/pop discipline. The trade is ~120 cycles of save/restore
  per IRQ.
- **VGA writes from a handler use `vga_puts_at` style absolute
  positioning**, not the cursor — handlers fire at unpredictable times
  and shouldn't perturb foreground output flow.
