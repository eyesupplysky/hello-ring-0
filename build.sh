#!/usr/bin/env bash
# Build hello-ring-0. Produces build/disk.img containing Stage 1 + Stage 2 + kernel.
set -euo pipefail

NASM="${NASM:-nasm}"
LLD="${LLD:-ld.lld}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
mkdir -p "$BUILD"

assert_size_eq() {
    local file="$1" exact="$2" actual
    actual=$(wc -c < "$file")
    if [ "$actual" -ne "$exact" ]; then
        echo "ERROR: $file is $actual bytes (expected $exact)" >&2
        exit 1
    fi
}

assert_size_le() {
    local file="$1" max="$2" actual
    actual=$(wc -c < "$file")
    if [ "$actual" -gt "$max" ]; then
        echo "ERROR: $file is $actual bytes (max $max)" >&2
        exit 1
    fi
}

echo "[asm] boot/stage1.asm -> build/stage1.bin"
"$NASM" -f bin -o "$BUILD/stage1.bin" "$ROOT/boot/stage1.asm"
assert_size_eq "$BUILD/stage1.bin" 512

echo "[asm] boot/stage2.asm -> build/stage2.bin"
"$NASM" -f bin -o "$BUILD/stage2.bin" "$ROOT/boot/stage2.asm"
assert_size_eq "$BUILD/stage2.bin" 4096

KERNEL_SRCS=(
    "kernel/main.asm"
    "kernel/cpu/gdt.asm"
    "kernel/cpu/idt.asm"
    "kernel/interrupts/isr_stubs.asm"
    "kernel/interrupts/isr_common.asm"
    "kernel/interrupts/handlers.asm"
    "kernel/interrupts/pic.asm"
    "kernel/interrupts/timer.asm"
    "kernel/interrupts/keyboard.asm"
    "kernel/drivers/vga.asm"
    "kernel/drivers/serial.asm"
    "kernel/cpu/tss.asm"
    "kernel/syscall/init.asm"
    "kernel/syscall/entry.asm"
    "kernel/syscall/handlers.asm"
    "kernel/syscall/fd.asm"
    "kernel/mm/frame.asm"
    "kernel/mm/kheap.asm"
    "kernel/mm/vm.asm"
    "kernel/mm/vm_space.asm"
    "kernel/mm/user_vm.asm"
    "kernel/mm/page_protect.asm"
    "kernel/shell/main.asm"
)

KERNEL_OBJS=()
for src in "${KERNEL_SRCS[@]}"; do
    obj="$BUILD/${src%.asm}.o"
    mkdir -p "$(dirname "$obj")"
    echo "[asm] $src -> ${obj#$ROOT/}"
    "$NASM" -f elf64 -o "$obj" "$ROOT/$src"
    KERNEL_OBJS+=("$obj")
done

echo "[link] kernel.bin via kernel.ld"
"$LLD" -m elf_x86_64 -nostdlib -static \
    --oformat=binary \
    -T "$ROOT/kernel/kernel.ld" \
    -o "$BUILD/kernel.bin" \
    "${KERNEL_OBJS[@]}"
assert_size_le "$BUILD/kernel.bin" 24576

echo "[pad] kernel.bin -> kernel.padded (24 KB)"
cp "$BUILD/kernel.bin" "$BUILD/kernel.padded"
truncate -s 24576 "$BUILD/kernel.padded"
assert_size_eq "$BUILD/kernel.padded" 24576

echo "[compose] disk.img"
cat "$BUILD/stage1.bin" "$BUILD/stage2.bin" "$BUILD/kernel.padded" > "$BUILD/disk.img"
assert_size_eq "$BUILD/disk.img" $((512 + 4096 + 24576))

echo "[ok] disk.img = $(wc -c < "$BUILD/disk.img") bytes (57 sectors)"
