#!/usr/bin/env bash
# Run Stage 1 in QEMU headless and assert "S1 OK" appears in the VGA text buffer at 0xB8000.
set -euo pipefail

QEMU="${QEMU:-qemu-system-x86_64}"
PORT="${MONITOR_PORT:-55555}"
BOOT_WAIT="${BOOT_WAIT:-4}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
IMG="$ROOT/build/disk.img"
LOG="$ROOT/build/qemu.log"

if [ ! -f "$IMG" ]; then
    echo "ERROR: $IMG missing — run ./build.sh first" >&2
    exit 1
fi

QEMU_PID=""
cleanup() {
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        # Try graceful, fall back to taskkill on Windows.
        kill "$QEMU_PID" 2>/dev/null || true
        sleep 0.2
        if kill -0 "$QEMU_PID" 2>/dev/null; then
            taskkill //PID "$QEMU_PID" //F >/dev/null 2>&1 || true
        fi
    fi
}
trap cleanup EXIT

# QEMU runs with TCP-based monitor (Windows piped-stdio to monitor doesn't drain reliably).
SERIAL_LOG="$ROOT/build/serial.log"
rm -f "$SERIAL_LOG"

# QEMU on Windows expects native paths for -serial file:; cygpath converts
# MSYS-style /d/... into D:\... which the Windows binary can open.
if command -v cygpath >/dev/null 2>&1; then
    SERIAL_LOG_NATIVE=$(cygpath -w "$SERIAL_LOG")
else
    SERIAL_LOG_NATIVE="$SERIAL_LOG"
fi

"$QEMU" -fda "$IMG" \
    -display none \
    -monitor "tcp:127.0.0.1:$PORT,server,nowait" \
    -serial "file:$SERIAL_LOG_NATIVE" \
    -no-reboot \
    > "$LOG" 2>&1 &
QEMU_PID=$!

# Wait up to ~3s for the monitor TCP server to accept connections.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if (exec 3<>/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null; then
        exec 3<&-
        exec 3>&-
        break
    fi
    sleep 0.3
done

# Give SeaBIOS time to POST and hand off to the boot sector. ~3s in practice;
# CI runners can be slower, override via BOOT_WAIT env var.
sleep "$BOOT_WAIT"

# Connect, dump the full 80x25 VGA text screen (4000 bytes), quit.
# QEMU closes the socket on `quit`; on Windows that surfaces as a connection-abort
# during read. Data prior to the abort still reaches us, so swallow the error.
exec 3<>/dev/tcp/127.0.0.1/"$PORT"
printf 'sendkey h\n'         >&3
sleep 0.2
printf 'sendkey i\n'         >&3
sleep 0.2
printf 'sendkey shift-a\n'   >&3
sleep 0.2
printf 'sendkey ret\n'       >&3
sleep 0.3
# M6b: type a sentinel, backspace, then commit. Without the destructive BS,
# the 'q' would still be visible because nothing overwrites it.
printf 'sendkey q\n'         >&3
sleep 0.2
printf 'sendkey backspace\n' >&3
sleep 0.2
printf 'sendkey ret\n'       >&3
sleep 0.3
# M6c: line buffer must clamp BS at empty so the prompt survives over-erase.
# Type "hello", press BS 7 times (only 5 should take effect — the line
# buffer ignores the rest), then type "world". With M6c the resulting line
# is "> world"; without M6c the prompt would be eaten and "world" would
# appear at column 0.
for k in h e l l o; do
    printf 'sendkey %s\n' "$k" >&3
    sleep 0.1
done
for _ in 1 2 3 4 5 6 7; do
    printf 'sendkey backspace\n' >&3
    sleep 0.1
done
for k in w o r l d; do
    printf 'sendkey %s\n' "$k" >&3
    sleep 0.1
done
printf 'sendkey ret\n'       >&3
sleep 0.3
# M7b: type 'a', press Ctrl+C — shell should echo "^C", drop the line,
# and re-emit the prompt. Without the Ctrl+C handler the line buffer
# would still hold 'a' and no '^C' would appear.
printf 'sendkey a\n'         >&3
sleep 0.2
printf 'sendkey ctrl-c\n'    >&3
sleep 0.5
printf 'xp /4000bx 0xb8000\nquit\n' >&3
output=$(cat <&3 2>/dev/null) || true
exec 3<&- 2>/dev/null || true
exec 3>&- 2>/dev/null || true

wait "$QEMU_PID" 2>/dev/null || true
QEMU_PID=""

# Even-indexed bytes are character codes; odd-indexed are color attributes.
# Uses POSIX awk only (no strtonum) so this works on mawk-default systems
# like Ubuntu CI runners as well as gawk-default ones like Git Bash.
chars=$(echo "$output" \
    | grep -oE '0x[0-9a-fA-F]{2}' \
    | awk 'NR%2==1' \
    | awk '{
        h = tolower($1)
        sub(/^0x/, "", h)
        code = 0
        n = length(h)
        for (i = 1; i <= n; i++) {
            d = index("0123456789abcdef", substr(h, i, 1)) - 1
            code = code * 16 + d
        }
        if (code >= 32 && code < 127) printf "%c", code
        else printf "."
      }')

echo "VGA screen:"
echo "$chars" | fold -w 80

ok=true
[[ "$chars" == *"S1 OK"* ]] || { echo "[fail] missing 'S1 OK' (Stage 1 didn't run)" >&2; ok=false; }
[[ "$chars" == *"S2 OK"* ]] || { echo "[fail] missing 'S2 OK' (Stage 2 didn't run)" >&2; ok=false; }
[[ "$chars" == *"K OK"* ]]  || { echo "[fail] missing 'K OK' (kernel didn't reach long mode)" >&2; ok=false; }
[[ "$chars" == *"TICK"* ]]   || { echo "[fail] missing 'TICK' (PIT IRQ0 didn't fire)" >&2; ok=false; }
[[ "$chars" == *"KEY "* ]]   || { echo "[fail] missing 'KEY' (PS/2 IRQ1 didn't fire)" >&2; ok=false; }
[[ "$chars" == *"> "* ]]     || { echo "[fail] missing prompt '> ' (shell didn't print via sys_write)" >&2; ok=false; }
[[ "$chars" == *"hiA"* ]]    || { echo "[fail] missing 'hiA' (echo path or shift translation broken)" >&2; ok=false; }
[[ "$chars" != *"> q"* ]]    || { echo "[fail] backspace did not erase 'q' on VGA (M6b regression)" >&2; ok=false; }
[[ "$chars" == *"> world"* ]] || { echo "[fail] missing '> world' (M6c line buffer let BS eat the prompt)" >&2; ok=false; }
[[ "$chars" == *"a^C"* ]]    || { echo "[fail] missing 'a^C' (M7b Ctrl+C handler didn't fire)" >&2; ok=false; }
[[ "$chars" == *"Z=00"* ]]   || { echo "[fail] missing 'Z=00' (M8 fd self-test didn't open/read /dev/zero)" >&2; ok=false; }
[[ "$chars" == *"M=AB"* ]]   || { echo "[fail] missing 'M=AB' (M9 mmap/munmap round-trip broken)" >&2; ok=false; }
[[ "$chars" == *"KH OK"* ]]  || { echo "[fail] missing 'KH OK' (M10b kheap selftest failed)" >&2; ok=false; }

# Serial log captures the kernel's serial_puts output.
serial_data=""
[ -f "$SERIAL_LOG" ] && serial_data=$(cat "$SERIAL_LOG")
echo "Serial log: $(printf '%s' "$serial_data" | tr -d '\r')"
[[ "$serial_data" == *"K OK"* ]] || { echo "[fail] missing 'K OK' in serial log (16550 UART driver broken)" >&2; ok=false; }
[[ "$serial_data" == *"> "* ]]   || { echo "[fail] missing prompt '> ' in serial log (sys_write to fd 1 didn't reach serial)" >&2; ok=false; }
[[ "$serial_data" == *"hiA"* ]]  || { echo "[fail] missing 'hiA' in serial log (echo or shift translation didn't reach serial)" >&2; ok=false; }
[[ "$serial_data" == *"a^C"* ]]  || { echo "[fail] missing 'a^C' in serial log (M7b Ctrl+C didn't reach serial)" >&2; ok=false; }
[[ "$serial_data" == *"Z=00"* ]] || { echo "[fail] missing 'Z=00' in serial log (M8 fd self-test didn't reach serial)" >&2; ok=false; }
[[ "$serial_data" == *"M=AB"* ]] || { echo "[fail] missing 'M=AB' in serial log (M9 mmap round-trip didn't reach serial)" >&2; ok=false; }
[[ "$serial_data" == *"KH OK"* ]] || { echo "[fail] missing 'KH OK' in serial log (M10b kheap selftest didn't reach serial)" >&2; ok=false; }

if $ok; then
    echo "[ok] shell echo confirmed — sys_read + sys_write round-trip in ring 3"
    exit 0
fi

echo "--- monitor output ---" >&2
echo "$output" >&2
exit 1
