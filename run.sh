#!/usr/bin/env bash
# Run Stage 1 in QEMU headless and assert "S1 OK" appears in the VGA text buffer at 0xB8000.
set -euo pipefail

QEMU="${QEMU:-qemu-system-x86_64}"
PORT="${MONITOR_PORT:-55555}"

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
"$QEMU" -fda "$IMG" \
    -display none \
    -monitor "tcp:127.0.0.1:$PORT,server,nowait" \
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

# Give SeaBIOS time to POST and hand off to the boot sector. ~3s in practice.
sleep 4

# Connect, dump the full 80x25 VGA text screen (4000 bytes), quit.
# QEMU closes the socket on `quit`; on Windows that surfaces as a connection-abort
# during read. Data prior to the abort still reaches us, so swallow the error.
exec 3<>/dev/tcp/127.0.0.1/"$PORT"
printf 'xp /4000bx 0xb8000\nquit\n' >&3
output=$(cat <&3 2>/dev/null) || true
exec 3<&- 2>/dev/null || true
exec 3>&- 2>/dev/null || true

wait "$QEMU_PID" 2>/dev/null || true
QEMU_PID=""

# Even-indexed bytes are character codes; odd-indexed are color attributes.
chars=$(echo "$output" \
    | grep -oE '0x[0-9a-fA-F]{2}' \
    | awk 'NR%2==1' \
    | awk '{
        code = strtonum($1)
        if (code >= 32 && code < 127) printf "%c", code
        else printf "."
      }')

echo "VGA screen:"
echo "$chars" | fold -w 80

ok=true
[[ "$chars" == *"S1 OK"* ]] || { echo "[fail] missing 'S1 OK' (Stage 1 didn't run)" >&2; ok=false; }
[[ "$chars" == *"S2 OK"* ]] || { echo "[fail] missing 'S2 OK' (Stage 2 didn't run)" >&2; ok=false; }
[[ "$chars" == *"K OK"* ]]  || { echo "[fail] missing 'K OK' (kernel didn't reach long mode)" >&2; ok=false; }

if $ok; then
    echo "[ok] S1 OK + S2 OK + K OK all reached"
    exit 0
fi

echo "--- monitor output ---" >&2
echo "$output" >&2
exit 1
