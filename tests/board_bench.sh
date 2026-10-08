#!/bin/bash
# orbit/novofs/tests/board_bench.sh: novofs on a board's reserved flash
# region, through RegionFlash and `hal.block`'s region surface.  Each
# board's tests/novofs.sh sets the board's facts and sources this file.
#
# The board's script sets:
#
#   SLUG        the board's --target slug
#   CHIP        the probe-rs chip name
#   BENCH_VAR   the name of the variable that selects the board's probe
#   REGION_LO   the reserved region's first byte, as hex digits
#   REGION_LEN  the region's length in bytes
#   UNIT        the flash's erase unit in bytes, which is a novofs block
#   DRIVER_TY   the type of the board's @hal(block) driver
#   PAINT       the bytes of main stack the program paints to measure
#   BUILD_FLAGS (optional) more flags for the build of the program
#   LED_ADDR    the GPIO output register of the board's LED, as hex
#   LED_BIT     the LED's bit in it
#
# Without a board the suite checks the build:
#
#   1. orbit/novofs/examples/region_bench.nv builds for the board with
#      `--cov`, with the novofs modules beside it; the image's hal.block
#      is the board's flash driver; the main stack the memory report
#      gives holds the band the program paints; the deepest chain of
#      frames below mount, a write and a read, from the image's code;
#   2. the host's image tool and a host reader of the volume's digest
#      build.
#
# With the board's probe named, it runs the program in four boots and
# checks, from the lines it prints.  The first boot runs the image with
# coverage hooks; the probe then flashes the same program without them
# and resets the board, and the other three run that image, since the
# fill and its removal run some hundreds of operations that each walk
# the metadata log's record headers:
#
#   3. the region erased through the probe; a mount without
#      format-on-empty refused with ENoFs and one with it formatted; an
#      explicit format and a mount; /a written and read back; /b; /c
#      where the volume has a block for it, refused for space where it
#      has only its metadata pair; a remount reads them again;
#      RegionFlash's refusals; the RAM in use at the mount and at the
#      deepest write, by the arena's counters and the painted stack;
#   4. after a reset by the probe: the files read back; /a removed;
#      files written until the volume refuses one, and removed; /pl
#      written as 7, then as 8 through a device that programs half of
#      the write's first prog and resets the core;
#   5. after that cut: /pl reads 7, the record in flight lost, and the
#      volume reads whole; /pl takes 9 after the torn record; then the
#      program rewrites /pl and /p2 in a loop and the probe resets the
#      board at a moment the suite does not choose;
#   6. after that reset: /p2 holds the number /pl holds or the one before
#      it, and the rest of the volume is whole;
#   7. every line of regionflash.nv ran in the first boot, but for a line
#      a `cov: skip` marker excuses with its reason;
#   8. the region read through the probe: the host's image tool lists
#      the files the device wrote, its fsck accepts the volume, /b's
#      bytes extracted are the device's pattern, and the host's reading
#      of the volume's digest is the one the device printed;
#   9. blink flashed last, its LED pin read toggling through the probe.
#
# One probe-rs runs at a time on the board's probe: each call waits for
# any other on the same probe to finish.

set -uo pipefail

NV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$NV/../.." && pwd)"
NOVO="${NOVO:-$REPO/bin/novo}"
BLINK="$REPO/examples/intro/blink.nv"
BLOCKS=$((REGION_LEN / UNIT))

PASS=0; FAIL=0
pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /'; FAIL=$((FAIL + 1)); }
skip() { echo "  - $1"; }
# The wall-clock time of each section, printed at the end.
T_NAME=""; T_AT=0; TIMES=""
now_ms() { date +%s%3N; }
end_section() {
  [ -n "$T_NAME" ] && TIMES="$TIMES$(LC_NUMERIC=C printf '  %7.1f s  %s' "$(( $(now_ms) - T_AT ))e-3" "$T_NAME")"$'\n'
  T_NAME=""
}
section() {
  end_section
  T_NAME="$1"; T_AT=$(now_ms)
  echo ""
  echo "$1"
}
finish() {
  end_section
  if [ -n "$TIMES" ]; then
    echo ""
    echo "  wall-clock time per section:"
    printf '%s' "$TIMES"
  fi
  echo "══════════════════════════════════════════"
  echo "  pass=$PASS fail=$FAIL"
  echo "══════════════════════════════════════════"
  [ "$FAIL" = "0" ]
  exit $?
}

echo ""
echo "══════════════════════════════════════════"
echo "  novofs on the $SLUG's reserved flash region"
echo "══════════════════════════════════════════"

[ -x "$NOVO" ] || { echo "ERROR: $NOVO not found; build first" >&2; exit 1; }
for tool in arm-none-eabi-nm arm-none-eabi-objdump python3; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "  (skipped: $tool not installed)"
    finish
  fi
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/novofs_board_XXXXXX")
trap 'rm -rf "$WORK"' EXIT
DEV="$WORK/dev"
mkdir -p "$DEV"
cp "$NV"/src/{flash,crc32,meta,nvfs,regionflash}.nv "$NV"/examples/{devtools,region_bench}.nv "$DEV/"
sed -i "s/^let PAINT_BYTES = .*/let PAINT_BYTES = $PAINT/" "$DEV/region_bench.nv"
ELF="$DEV/bench.elf"
STEM="$DEV/_novo/region_bench_$SLUG"
# The same program without the coverage hooks, for boots 1 to 3: a hook
# is a call at every line, and the fill and its removal run some
# hundreds of operations that each walk the metadata log's headers.
FAST_DIR="$WORK/fast"
FAST="$FAST_DIR/bench.elf"
mkdir -p "$FAST_DIR"
cp "$DEV"/*.nv "$FAST_DIR/"

# ── 1. the build ───────────────────────────────────────────────────────────
section "1. the build"
if (cd "$DEV" && "$NOVO" build --target="$SLUG" --cov ${BUILD_FLAGS:-} -o "$ELF" region_bench.nv) \
     > "$WORK/build.log" 2>&1 && [ -f "$ELF" ]; then
  pass "region_bench.nv builds for $SLUG with --cov"
else
  fail "region_bench.nv does not build for $SLUG" "$(tail -10 "$WORK/build.log")"
  finish
fi
if (cd "$FAST_DIR" && "$NOVO" build --target="$SLUG" --memory-report=none -o "$FAST" region_bench.nv) \
     > "$WORK/fast.log" 2>&1 && [ -f "$FAST" ]; then
  pass "and without the coverage hooks, for the boots after the first"
else
  fail "region_bench.nv does not build for $SLUG without --cov" "$(tail -10 "$WORK/fast.log")"
  finish
fi
if grep -q "hal.block on $DRIVER_TY (hal_block)" "$WORK/build.log"; then
  pass "the image's hal.block is the board's $DRIVER_TY"
else
  fail "the image's hal.block is not $DRIVER_TY" "$(grep "board's drivers" "$WORK/build.log")"
fi
main_stack=$(sed -n 's/^ *stack .* main \([0-9,]*\) ·.*/\1/p' "$WORK/build.log" | tr -d ',' | head -1)
if [ -n "$main_stack" ] && [ "$main_stack" -ge $((PAINT + 512)) ]; then
  pass "the main stack, $main_stack bytes by the memory report, holds the $PAINT bytes the program paints"
else
  fail "the main stack (${main_stack:-unknown} bytes) does not hold the $PAINT painted bytes and 512 more"
fi
# The filesystem's static storage, by the memory report's owners: its
# read cache, program buffer and record staging buffer, the allocator's
# bitmap and retired list, the two kept scans, and the block device's
# staging buffer the region surface moves bytes through.
static=$(python3 - "$WORK/build.log" <<'PY'
import re, sys
line = next((l for l in open(sys.argv[1]) if ".data + .bss" in l), "")
own = dict((m.group(1), int(m.group(2).replace(",", "")))
           for m in re.finditer(r"([A-Za-z_][A-Za-z_0-9]*) ([0-9][0-9,]*)", line))
names = ["rc", "pb", "nvfs_stage", "la", "retired", "meta_sm_res0", "meta_sm_res1",
         "board_hal_block_buf"]
if all(n in own for n in names):
    print(sum(own[n] for n in names), " ".join(f"{n} {own[n]}" for n in names))
PY
)
if [ -n "$static" ]; then
  pass "the filesystem's static storage in .bss: ${static%% *} bytes (${static#* })"
else
  fail "the memory report does not list the filesystem's static storage" "$(grep '.data + .bss' "$WORK/build.log")"
fi
# The mount's work is mount_dev; a volume's operations are methods of
# Volume<RegionFlash>, and a type-parameterised one (file_write) is
# specialised in the unit that calls it.
for pair in "mount:nvfs\\.mount_dev_RegionFlash" \
            "file_write:(nvfs\\.)?Volume_RegionFlash_file_write_Pat" \
            "file_read_at:(nvfs\\.)?Volume_RegionFlash_file_read_at"; do
  op=${pair%%:*}; sym="novo_user_${pair#*:}"
  chain=$(python3 "$NV/tests/stack_chain.py" "$ELF" "$sym" | head -1 | cut -d' ' -f1)
  if [ -n "$chain" ] && [ "$chain" -le 4096 ]; then
    pass "the volume's $op: the deepest chain of frames, from the image's code, is $chain bytes"
  else
    fail "the volume's $op: the deepest chain of frames is ${chain:-unknown} bytes, more than a 4 KB task stack" \
         "$(python3 "$NV/tests/stack_chain.py" "$ELF" "$sym" | head -16)"
  fi
done

# ── 2. the host's tools ────────────────────────────────────────────────────
section "2. the host's tools"
# shellcheck source=../../../tests/lib/shared_build.sh
source "$REPO/tests/lib/shared_build.sh"
_novofs_build() {
  local dir="$1" e
  mkdir -p "$dir/novofs" || return 1
  shopt -s dotglob
  for e in "$NV"/*; do
    [ -e "$e" ] || continue
    [ "$(basename "$e")" = "_novo" ] && continue
    [ "$(basename "$e")" = "novofs" ] && [ -f "$e" ] && continue
    cp -a "$e" "$dir/novofs/" || { shopt -u dotglob; return 1; }
  done
  shopt -u dotglob
  ( cd "$dir/novofs" && "$NOVO" pkg build )
}
TOOL=""
if tool_dir=$(shared_build novofs "$WORK" _novofs_build); then
  TOOL="$tool_dir/novofs/novofs"
fi
if [ -x "$TOOL" ]; then
  pass "the host's image tool builds"
else
  fail "the host's image tool does not build" "$(shared_build_log novofs "$WORK" | tail -3)"
fi
HOST="$WORK/host"
mkdir -p "$HOST"
cp "$NV"/src/{flash,crc32,meta,nvfs,hostdev}.nv "$NV"/examples/devtools.nv "$HOST/"
cat > "$HOST/hostdigest.nv" <<EOF
use flash
use hostdev
use nvfs
use devtools

// The digest region_bench.nv prints, read by the host-built core
// through FileFlash from a region read through the probe.
fn main() [io, fs, mutate, ffi]
    let args = env.args()
    match hostdev.file_flash(args[1], 16, 16, $UNIT, $BLOCKS)
        None      => println("host digest -1")
        Some(dev) => println("host digest \${devtools.volume_digest(dev)}")
EOF
if (cd "$HOST" && "$NOVO" build hostdigest.nv -o hostdigest) > "$HOST/build.log" 2>&1 \
   && [ -x "$HOST/hostdigest" ]; then
  pass "the host's digest reader builds, over $BLOCKS blocks of $UNIT bytes"
else
  fail "the host's digest reader does not build" "$(tail -5 "$HOST/build.log")"
fi

# ── 3. stage 0 on the board ────────────────────────────────────────────────
section "3. format, write, read and remount, on the board"
SEL="${!BENCH_VAR:-}"
if [ -z "$SEL" ]; then
  skip "$BENCH_VAR is unset; set it to the board's probe to run sections 3 to 9"
  finish
fi
if ! command -v probe-rs > /dev/null 2>&1; then
  fail "$BENCH_VAR is set and probe-rs is not installed"
  finish
fi
wait_probe() {
  while grep -qF -- "$SEL" <<< "$(pgrep -a -x probe-rs)"; do sleep 1; done
}
# pr <verb> <args>: probe-rs on the board's probe, run again when it
# fails to attach.
pr() {
  local verb="$1" try; shift
  for try in 1 2 3; do
    wait_probe
    timeout 120 probe-rs "$verb" --chip "$CHIP" --probe "$SEL" "$@" && return 0
    sleep 2
  done
  return 1
}
# watch <log> <ERE> <seconds> <verb> <args>: probe-rs run or attach on the
# board's probe in the background, until a line of the log matches or the
# seconds pass.
watch() {
  local log="$1" want="$2" secs="$3" verb="$4" runner; shift 4
  wait_probe
  timeout "$((secs + 5))" probe-rs "$verb" --chip "$CHIP" --probe "$SEL" "$@" > "$log" 2>&1 &
  runner=$!
  for _ in $(seq 1 $((secs * 10))); do
    grep -aqE -- "$want" "$log" && break
    kill -0 "$runner" 2> /dev/null || break
    sleep 0.1
  done
  sleep 0.5
  kill "$runner" 2> /dev/null
  wait "$runner" 2> /dev/null
}
clean() {
  sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\[Terminal\] //g' -e 's/^[0-9:.]*: //' "$1" | tr -d '\r'
}
OUT=""
expect() {
  if grep -qxF -- "$1" <<< "$OUT"; then pass "$2"
  else fail "$2: no line '$1'" "$(grep -av '^\s*$' <<< "$OUT" | tail -16)"; fi
}
value() { sed -n "s/^$1=\\(-\\?[0-9]*\\)$/\\1/p" <<< "$OUT" | tail -1; }
cov_table() {
  local addr size
  read -r addr size < <(arm-none-eabi-nm -S "$ELF" | awk '$4 == "novo_cov_bits" {print "0x" $1, $2}')
  pr read b8 "$addr" "$((16#$size))" -o "$1" -f binary > /dev/null 2>&1
}

python3 -c "import sys; sys.stdout.buffer.write(b'\xff' * $REGION_LEN)" > "$WORK/erased.bin"
if pr download --binary-format bin --base-address "0x$REGION_LO" "$WORK/erased.bin" \
     > "$WORK/erase.log" 2>&1; then
  pass "the region, 0x$REGION_LO for $REGION_LEN bytes, erased through the probe"
else
  fail "the region could not be erased through the probe" "$(tail -3 "$WORK/erase.log")"
  finish
fi
watch "$WORK/s0.log" "stage 0 done" 120 run --no-catch-reset "$ELF"
OUT=$(clean "$WORK/s0.log")
expect "blocks=$BLOCKS"                       "RegionFlash has $BLOCKS blocks of $UNIT bytes, one per erase unit"
expect "erase size=$UNIT"                     "hal.block.erase_size() is the driver's erase unit, $UNIT bytes"
expect "region bytes=$REGION_LEN"             "hal.block.region_bytes() is the manifest's block_region, $REGION_LEN bytes"
expect "region start=$((16#$REGION_LO))"      "hal.block.region_start() is 0x$REGION_LO"
expect "stage 0"                              "an erased region holds no filesystem: stage 0"
expect "empty without format=no filesystem"   "mount_with without format-on-empty answers ENoFs"
expect "formatted on empty rev=1"             "mount_with with format-on-empty formats the region and mounts it"
expect "write path=1"                         "format, mount, /a and /b written from a @no_alloc function"
expect "mount=ok"                             "the volume mounts"
expect "read a=40"                            "/a reads back, 40 bytes of its pattern"
if [ "$BLOCKS" -gt 2 ]; then
  expect "write c=ok"                         "/c, 3000 bytes in data blocks, is written"
  expect "read c=3000"                        "and reads back after a remount"
else
  expect "write c=no space"                   "/c, 3000 bytes, is refused for space: the region's two units are the metadata pair"
fi
expect "remount rev=1"                        "a remount in the same boot finds revision 1"
expect "read a again=40"                      "/a reads back after the remount"
expect "read b=100"                           "and /b, 100 bytes"
for r in "read block -1" "read block count" "read misaligned" "read past block" "read too long" \
         "read negative" "read length -1" "prog misaligned length" "erase block -1" "erase block count"; do
  expect "$r=0"                               "RegionFlash refuses: $r"
done
expect "sync=1"                               "sync is a no-op that answers true"
expect "partition misaligned=0"               "a partition that does not start on an erase unit has no blocks"
expect "partition past region=0"              "nor one that runs past the region"
expect "partition below region=0"             "nor one below it"
expect "partition empty=0"                    "nor one of no bytes"
expect "partition top unit=1"                 "the region's top unit is a partition of one block"
expect "mount of no blocks=geometry mismatch" "a mount of a partition with no blocks is refused"
expect "stage write=1"                        "the stage is written to the volume"
expect "stage 0 done"                         "stage 0 runs to its end"
heap_mount=$(value "heap after mount"); heap_deep=$(value "heap at deepest write")
heap_high=$(value "heap high water")
st_start=$(value "stack after init"); st_mount=$(value "stack after mount")
st_deep=$(value "stack deepest")
# A mount takes the volume from the arena; two volumes are alive at the
# deepest write (the one written through and the one the write path
# used), beside 128 bytes of the program's start-up and printing.
heap_vol=$(value "heap per volume")
if [ -n "$heap_vol" ] && [ "$heap_vol" -gt 0 ] && [ "$heap_vol" -le 256 ]; then
  pass "a mounted volume takes $heap_vol bytes of the arena, the volume and the copy of its device"
else
  fail "a mounted volume takes ${heap_vol:-unknown} bytes of the arena, more than 256"
fi
if [ -n "$heap_high" ] && [ -n "$heap_vol" ] && [ "$heap_high" -le $((128 + 2 * heap_vol)) ]; then
  pass "the arena's high water is $heap_high bytes after the deepest write; asked since boot: $heap_mount at the mount, $heap_deep at the deepest write"
else
  fail "the arena's high water after the deepest write is ${heap_high:-unknown} bytes"
fi
if [ -n "$st_deep" ] && [ "$st_deep" -lt "$PAINT" ]; then
  pass "the main stack's deepest point: $st_start bytes after the board's init, $st_mount at the mount, $st_deep over stage 0"
else
  fail "the main stack reached the bottom of the painted band (${st_deep:-unknown} of $PAINT bytes)"
fi
cov_table "$WORK/cov0.bin" || fail "the coverage table of stage 0 could not be read"

# ── 4. and 5. the reset, the files, the fill and the cut ──────────────────
section "4. after a reset: the files, the fill and a cut in the middle of a write"
# The run flashes, resets and reads the RTT in one session, the way stage
# 0 ran: stage 1 on a small region is over, and the core reset by the
# cut, before a reader started after a separate reset could attach.
watch "$WORK/s1.log" ": loop$" 1200 run --no-catch-reset "$FAST"
if grep -aqiE "finished in|stage [12]" "$WORK/s1.log"; then
  pass "the program without coverage hooks is flashed over the first, and the board reset"
else
  fail "the program without coverage hooks could not be flashed" "$(tail -3 "$WORK/s1.log")"
  finish
fi
if ! grep -aq "stage 2" "$WORK/s1.log"; then
  # The core's reset after the cut ended the session: the next boot's
  # lines are in the log's buffer for a new one.
  watch "$WORK/s1b.log" ": loop$" 120 attach "$FAST"
  cat "$WORK/s1b.log" >> "$WORK/s1.log"
fi
OUT=$(clean "$WORK/s1.log")
expect "stage 1"                              "the volume mounts after the reset and holds stage 1"
expect "after reset a=40"                     "/a reads back after the reset"
expect "after reset b=100"                    "and /b"
[ "$BLOCKS" -gt 2 ] && expect "after reset c=3000" "and /c"
expect "remove a=ok"                          "/a is removed"
expect "a after remove=not found"             "and is gone"
expect "b after remove=100"                   "/b is untouched by the removal"
expect "fill refusal=no space"                "files are written until the volume refuses one for space"
fill_n=$(value "fill files"); fill_b=$(value "fill bytes")
[ -n "$fill_n" ] && [ "$fill_n" -gt 0 ] && pass "the volume took $fill_n files, $fill_b bytes, before the refusal"
fill_ms=$(value "fill ms"); remove_ms=$(value "remove ms")
if [ -n "$fill_ms" ] && [ -n "$remove_ms" ]; then
  pass "the board's timer: the fill took $fill_ms ms and the removal $remove_ms ms"
else
  fail "the program printed no time for the fill and the removal"
fi
expect "b when full=100"                      "/b reads back with the volume full"
expect "fill removed=$fill_n"                 "every fill file is removed"
expect "pl write=1"                           "/pl is written as 7"
expect "tearing pl=8"                         "/pl is written as 8 through the cutting device"
expect "resetting"                            "which programs half of the first prog and resets the core"
OUT=$(clean "$WORK/s1.log" | sed -n '/^stage 2$/,$p')
section "5. after the cut"
expect "stage 2"                              "the volume mounts after the cut and holds stage 2"
expect "pl after cut=7"                       "/pl reads 7: the record in flight is lost and the one before it whole"
expect "b after cut=100"                      "/b reads back"
[ "$BLOCKS" -gt 2 ] && expect "c after cut=3000" "and /c"
expect "pl write after cut=1"                 "/pl takes 9 after the torn record"
expect "pl=9"                                 "and reads 9"
expect "loop"                                 "the program rewrites /pl and /p2 in a loop"

# ── 6. the reset in the loop ───────────────────────────────────────────────
section "6. a reset at a moment the suite does not choose, in the loop"
sleep "$(python3 -c 'import random; print(round(random.uniform(0.5, 2.5), 2))')"
pr reset > /dev/null 2>&1
watch "$WORK/s3.log" "probe done" 120 attach "$FAST"
OUT=$(clean "$WORK/s3.log")
expect "stage 3"                              "the volume mounts after the reset and holds stage 3"
expect "loop ran=1"                           "the loop wrote before the reset"
expect "loop consistent=1"                    "/p2 holds /pl's number or the one before it: at most the write in flight lost"
pl=$(value "pl after reset"); p2=$(value "p2 after reset")
[ -n "$pl" ] && pass "/pl reads $pl and /p2 $p2 after the reset"
expect "b after reset=100"                    "/b reads back"
[ "$BLOCKS" -gt 2 ] && expect "c after reset=3000" "and /c"
expect "stage write=1"                        "the volume takes a write after the reset"
expect "probe done"                           "the program runs to its end"
digest=$(value "digest")

# ── 7. coverage ────────────────────────────────────────────────────────────
section "7. line coverage of regionflash.nv, on the board"
if [ -f "$WORK/cov0.bin" ]; then
  cp "$WORK/cov0.bin" "$WORK/cov.bin"
  # The build names the staged modules by their path from its own
  # directory, `./regionflash.nv`.
  if cov=$(cd "$DEV" && python3 "$REPO/scripts/device_coverage.py" "$ELF" "$WORK/cov.bin" "$STEM" ./regionflash.nv); then
    pass "every line of regionflash.nv with a hook ran: $(grep ': covered' <<< "$cov" | sed -E 's|^.*/([^/]+): covered |\1 |')"
  else
    fail "lines of regionflash.nv that did not run" "$cov"
  fi
else
  fail "the coverage table of the first boot could not be read"
fi

# ── 8. the region, through the probe ───────────────────────────────────────
section "8. the region read through the probe, on the host"
if pr read b8 "0x$REGION_LO" "$REGION_LEN" -o "$WORK/region.bin" -f binary > "$WORK/read.log" 2>&1 \
   && [ "$(stat -c %s "$WORK/region.bin")" = "$REGION_LEN" ]; then
  pass "the region's $REGION_LEN bytes are read through the probe"
else
  fail "the region could not be read through the probe" "$(tail -3 "$WORK/read.log")"
  finish
fi
if [ -x "$TOOL" ]; then
  ls_out=$("$TOOL" ls "$WORK/region.bin" 2>&1)
  want="b p2 pl stage"
  [ "$BLOCKS" -gt 2 ] && want="b c p2 pl stage"
  got=$(awk '{print $NF}' <<< "$ls_out" | sed 's|^/||' | sort | tr '\n' ' ' | sed 's/ $//')
  if [ "$got" = "$want" ]; then
    pass "novofs ls lists the files the device wrote: $got"
  else
    fail "novofs ls lists '$got', not '$want'" "$ls_out"
  fi
  if fsck=$("$TOOL" fsck "$WORK/region.bin" 2>&1); then
    pass "novofs fsck accepts the volume: $(head -1 <<< "$fsck")"
  else
    fail "novofs fsck refuses the volume" "$fsck"
  fi
  mkdir -p "$WORK/out"
  if "$TOOL" extract "$WORK/region.bin" -o "$WORK/out" > "$WORK/extract.log" 2>&1 \
     && python3 - "$WORK/out/b" <<'EOF'
import sys
b = open(sys.argv[1], "rb").read()
sys.exit(0 if b == bytes((i * 7 + 2) % 251 for i in range(100)) else 1)
EOF
  then
    pass "/b extracted on the host is the 100 bytes of the device's pattern"
  else
    fail "/b extracted on the host is not the device's pattern" "$(tail -3 "$WORK/extract.log")"
  fi
fi
if [ -x "$HOST/hostdigest" ]; then
  host=$("$HOST/hostdigest" "$WORK/region.bin" | sed -n 's/^host digest //p')
  if [ -n "$digest" ] && [ "$host" = "$digest" ]; then
    pass "the host's digest of the region is the device's, $digest"
  else
    fail "the host's digest of the region is ${host:-unknown}, the device's ${digest:-unknown}"
  fi
fi

# ── 9. blink, last ─────────────────────────────────────────────────────────
section "9. blink, flashed last"
if (cd "$WORK" && "$NOVO" build --target="$SLUG" --memory-report=none -o "$WORK/blink.elf" "$BLINK") \
     > "$WORK/blink.log" 2>&1 \
   && pr download "$WORK/blink.elf" > "$WORK/dl.log" 2>&1 \
   && pr reset > /dev/null 2>&1; then
  pass "blink builds and is flashed"
else
  fail "blink could not be built or flashed" "$(tail -4 "$WORK/blink.log" "$WORK/dl.log" 2>/dev/null)"
  finish
fi
sleep 1
seen=""
for _ in 1 2 3 4 5 6 7 8; do
  v=$(pr read b32 "0x$LED_ADDR" 1 2>/dev/null | awk '{print $2}' | tail -1)
  [ -n "$v" ] && seen="$seen $(( (16#$v >> LED_BIT) & 1 ))"
  sleep 0.25
done
if grep -q 0 <<< "$seen" && grep -q 1 <<< "$seen"; then
  pass "blink runs: the LED's pin read$seen"
else
  fail "the LED's pin did not toggle: it read${seen:- nothing}"
fi

finish
