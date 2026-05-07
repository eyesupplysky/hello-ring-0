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

echo "[asm] kernel/main.asm -> build/kernel.o"
"$NASM" -f elf64 -o "$BUILD/kernel.o" "$ROOT/kernel/main.asm"

echo "[link] kernel.o -> build/kernel.bin"
"$LLD" -m elf_x86_64 -nostdlib -static \
    --oformat=binary \
    --image-base=0x100000 \
    -Ttext=0x100000 \
    -o "$BUILD/kernel.bin" \
    "$BUILD/kernel.o"
assert_size_le "$BUILD/kernel.bin" 4096

echo "[pad] kernel.bin -> kernel.padded (4 KB)"
cp "$BUILD/kernel.bin" "$BUILD/kernel.padded"
truncate -s 4096 "$BUILD/kernel.padded"
assert_size_eq "$BUILD/kernel.padded" 4096

echo "[compose] disk.img"
cat "$BUILD/stage1.bin" "$BUILD/stage2.bin" "$BUILD/kernel.padded" > "$BUILD/disk.img"
assert_size_eq "$BUILD/disk.img" 8704

echo "[ok] disk.img = 8704 bytes (17 sectors)"
