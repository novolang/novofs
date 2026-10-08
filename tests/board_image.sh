#!/bin/bash
# orbit/novofs/tests/board_image.sh: a novofs image built on the host for
# a board's data region, `novofs mk --target`, written into the region by
# `novo flash --data`, and read back.  Each board's tests/image.sh sets
# the board's facts and sources this file.
#
# The board's script sets:
#
#   SLUG        the board's --target slug
#   CHIP        the probe-rs chip name
#   BENCH_VAR   the name of the variable that selects the board's probe
#   PROG_LO     the program's first byte in flash, as hex digits
#   DEVICE      1 when a program on the board mounts the region, through
#               the board's @hal(block) driver; 0 when the board has none
#   DRIVE       1 to bench the BOOTSEL drive path of a Raspberry Pi board
#   LED_ADDR    the register that holds the LED pin's output, as hex
#   LED_BIT     the LED's bit in it
#
# Without a board the suite checks the host's side:
#
#   1. the image tool builds; `novo bsp region` names the board's data
#      region, its block (the erase unit) and its page;
#   2. `novofs mk --target` builds an image of the region's size from a
#      folder of three files and a directory, with the board's block
#      size, block count and page; `novo flash --data` refuses an image
#      of another size before it looks for a probe;
#   3. with DEVICE, image_read.nv and image_write.nv build for the board.
#
# With the board's probe named:
#
#   4. the program is flashed (image_read.nv with DEVICE, else blink) and
#      its flash read through the probe; `novo flash --data` writes the
#      image into the region through the probe;
#   5. with DEVICE, image_read.nv, flashed before the image, mounts the
#      region read-only after the reset `novo flash` gives, and prints the
#      geometry its flash driver answers, every entry with its size and
#      CRC-32C, the short files' text and the volume's digest, each
#      compared with the host's;
#   6. the region read back through the probe is the image byte for byte,
#      and the program's flash reads as it did before;
#   7. with DEVICE, image_write.nv writes /from-board.txt; the region read
#      back lists it with the host's tool, which reads its text, checks
#      the volume and reads the device's digest;
#   8. with DRIVE, the flash's first sector is erased so the boot ROM
#      finds no boot2 and shows the BOOTSEL drive, the drive is mounted, a
#      second image is written by `novo flash --data` with no probe-rs on
#      PATH, so through the drive, and the region read back through the
#      probe, once the first sector is written back and the program boots,
#      is that image byte for byte, with the program's flash as it was;
#   9. blink flashed last, its LED pin read toggling through the probe.
#
# One probe-rs runs at a time on the board's probe: each call, and each
# `novo flash`, waits for any other on the same probe to finish.

set -uo pipefail

NV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$NV/../.." && pwd)"
NOVO="${NOVO:-$REPO/bin/novo}"
BLINK="$REPO/examples/intro/blink.nv"
export NOVO

PASS=0; FAIL=0
pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /'; FAIL=$((FAIL + 1)); }
skip() { echo "  - $1"; }
finish() {
  echo "══════════════════════════════════════════"
  echo "  pass=$PASS fail=$FAIL"
  echo "══════════════════════════════════════════"
  [ "$FAIL" = "0" ]
  exit $?
}

echo ""
echo "══════════════════════════════════════════"
echo "  a novofs image in the $SLUG's data region"
echo "══════════════════════════════════════════"

[ -x "$NOVO" ] || { echo "ERROR: $NOVO not found; build first" >&2; exit 1; }
for tool in python3 cmp; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "  (skipped: $tool not installed)"
    finish
  fi
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/novofs_image_XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ── 1. the tool and the region ─────────────────────────────────────────────
echo ""
echo "1. the image tool and the board's data region"
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
  finish
fi
if "$NOVO" bsp region --target="$SLUG" > "$WORK/region.txt" 2>&1; then
  field() { sed -n "s/^$1 //p" "$WORK/region.txt"; }
  REGION_LO=$(field start); REGION_LEN=$(field bytes); UNIT=$(field erase)
  WRITE=$(field write); PAGE=$(field page); BLOCKS=$(field blocks)
  pass "novo bsp region: the data region at $REGION_LO, $REGION_LEN bytes, $BLOCKS blocks of $UNIT bytes, page $PAGE ($(field source))"
else
  fail "novo bsp region refuses the board" "$(cat "$WORK/region.txt")"
  finish
fi

# ── 2. the image ───────────────────────────────────────────────────────────
echo ""
echo "2. the image, built from a folder for the board"
TREE="$WORK/tree"
mkdir -p "$TREE/etc"
printf 'hello from the host\n' > "$TREE/readme.txt"
printf 'rate=100\nunit=ms\n' > "$TREE/etc/config"
seq 1 400 | tr '\n' ',' > "$TREE/etc/table.csv"
IMG="$WORK/image.bin"
mk_out=$("$TOOL" mk "$TREE" -o "$IMG" --target="$SLUG" 2>&1)
if [ $? -eq 0 ] && [ "$(stat -c %s "$IMG" 2> /dev/null)" = "$REGION_LEN" ]; then
  pass "novofs mk --target=$SLUG builds an image of the region's $REGION_LEN bytes: $mk_out"
else
  fail "novofs mk --target=$SLUG did not build an image of $REGION_LEN bytes" "$mk_out"
  finish
fi
ls_out=$("$TOOL" ls "$IMG" 2>&1; "$TOOL" ls "$IMG" /etc 2>&1)
if grep -q ' readme.txt$' <<< "$ls_out" && grep -q '^d .* etc$' <<< "$ls_out" \
   && grep -q '^f 1492 table.csv$' <<< "$ls_out"; then
  pass "the image lists readme.txt, etc/config and etc/table.csv"
else
  fail "the image does not list the folder" "$ls_out"
fi
head -c $((REGION_LEN / 2)) "$IMG" > "$WORK/half.bin"
out=$(PATH=/usr/bin:/bin "$NOVO" flash --target="$SLUG" --data "$WORK/half.bin" 2>&1)
if [ $? -ne 0 ] && grep -q "is $((REGION_LEN / 2)) bytes, and the board's data region is $REGION_LEN bytes" <<< "$out"; then
  pass "novo flash --data refuses half the image, naming both sizes, before it looks for a probe"
else
  fail "novo flash --data does not refuse half the image by its size" "$out"
fi

DEV="$WORK/dev"
if [ "$DEVICE" = "1" ]; then
  echo ""
  echo "3. the programs that mount the region"
  for tool in arm-none-eabi-nm; do
    command -v "$tool" > /dev/null 2>&1 || { fail "$tool is not installed"; finish; }
  done
  mkdir -p "$DEV"
  cp "$NV"/src/{flash,crc32,meta,nvfs,regionflash}.nv "$NV"/examples/{devtools,image_read,image_write}.nv "$DEV/"
  for p in image_read image_write; do
    if (cd "$DEV" && "$NOVO" build --target="$SLUG" --memory-report=none -o "$p.elf" "$p.nv") \
         > "$DEV/$p.log" 2>&1 && [ -f "$DEV/$p.elf" ]; then
      pass "$p.nv builds for $SLUG"
    else
      fail "$p.nv does not build for $SLUG" "$(tail -8 "$DEV/$p.log")"
      finish
    fi
  done
  # The digest image_read.nv and image_write.nv print, read by the
  # host-built core through FileFlash.
  HOST="$WORK/host"
  mkdir -p "$HOST"
  cp "$NV"/src/{flash,crc32,meta,nvfs,hostdev}.nv "$NV"/examples/devtools.nv "$HOST/"
  cat > "$HOST/hostdigest.nv" <<EOF
use flash
use hostdev
use nvfs
use devtools

fn main() [io, fs, mutate, ffi]
    let args = env.args()
    match hostdev.file_flash(args[1], $PAGE, $PAGE, $UNIT, $BLOCKS)
        None      => println("host digest -1")
        Some(dev) => println("host digest \${devtools.volume_digest(dev)}")
EOF
  if (cd "$HOST" && "$NOVO" build hostdigest.nv -o hostdigest) > "$HOST/build.log" 2>&1 \
     && [ -x "$HOST/hostdigest" ]; then
    pass "the host's digest reader builds"
  else
    fail "the host's digest reader does not build" "$(tail -5 "$HOST/build.log")"
  fi
fi

# ── 4. on the board ────────────────────────────────────────────────────────
echo ""
echo "4. the image written into the region through the probe"
SEL="${!BENCH_VAR:-}"
if [ -z "$SEL" ]; then
  skip "$BENCH_VAR is unset; set it to the board's probe to run sections 4 to 9"
  finish
fi
if ! command -v probe-rs > /dev/null 2>&1; then
  fail "$BENCH_VAR is set and probe-rs is not installed"
  finish
fi
wait_probe() {
  while grep -qF -- "$SEL" <<< "$(pgrep -a -x probe-rs)"; do sleep 1; done
}
pr() {
  local verb="$1" try; shift
  for try in 1 2 3; do
    wait_probe
    timeout 120 probe-rs "$verb" --chip "$CHIP" --probe "$SEL" "$@" && return 0
    sleep 2
  done
  return 1
}
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
# The program's flash, from its first byte to the data region's.
PROG_LEN=$(( REGION_LO - 0x$PROG_LO ))
[ "$PROG_LEN" -gt 262144 ] && PROG_LEN=262144

# blink, built once: the board's program while the image goes in when no
# program of this suite mounts the region, and its last image.
if (cd "$WORK" && "$NOVO" build --target="$SLUG" --memory-report=none -o "$WORK/blink.elf" "$BLINK") \
     > "$WORK/blink.log" 2>&1; then
  pass "blink builds for $SLUG"
else
  fail "blink does not build for $SLUG" "$(tail -4 "$WORK/blink.log")"
  finish
fi
if [ "$DEVICE" = "1" ]; then
  FIRST="$DEV/image_read.elf"
else
  FIRST="$WORK/blink.elf"
fi
if pr download "$FIRST" > "$WORK/dl_first.log" 2>&1 && pr reset > /dev/null 2>&1; then
  pass "$(basename "$FIRST" .elf).nv is flashed and running, before the image"
else
  fail "$(basename "$FIRST" .elf).nv could not be flashed" "$(tail -3 "$WORK/dl_first.log")"
  finish
fi
if pr read b8 "0x$PROG_LO" "$PROG_LEN" -o "$WORK/prog_before.bin" -f binary > /dev/null 2>&1; then
  pass "the program's flash, 0x$PROG_LO for $PROG_LEN bytes, read through the probe"
else
  fail "the program's flash could not be read through the probe"
fi
wait_probe
if "$NOVO" flash --target="$SLUG" --probe="$SEL" --data "$IMG" > "$WORK/flash.log" 2>&1; then
  pass "novo flash --target=$SLUG --data writes the image: $(grep -m1 'writing' "$WORK/flash.log" | sed 's/^novo: //')"
else
  fail "novo flash --data did not write the image" "$(tail -6 "$WORK/flash.log")"
  finish
fi

if [ "$DEVICE" = "1" ]; then
  echo ""
  echo "5. the image mounted read-only on the board"
  watch "$WORK/read.log" "read done" 30 attach "$DEV/image_read.elf"
  OUT=$(clean "$WORK/read.log")
  expect "region start=$((REGION_LO))"  "hal.block.region_start() is the region novo bsp region names, $REGION_LO"
  expect "region bytes=$REGION_LEN"     "hal.block.region_bytes() is its $REGION_LEN bytes"
  expect "erase size=$UNIT"             "the flash driver's erase unit is the block novo bsp region names, $UNIT bytes"
  expect "write size=$WRITE"            "the flash driver's write unit is the $WRITE bytes novo bsp region names"
  expect "page=$PAGE"                   "RegionFlash's page is novo bsp region's, $PAGE bytes"
  expect "blocks=$BLOCKS"               "RegionFlash has the region's $BLOCKS blocks"
  expect "mount=ok"                     "the image mounts on the board, without format-on-empty"
  expect "block size=$UNIT"             "the superblock's block size is the board's"
  expect "entries=4"                    "the root and /etc hold four entries"
  expect "entry d /etc"                 "the board lists the directory /etc"
  python3 - "$TREE" > "$WORK/expect.txt" <<'PY'
import os, sys
def crc32c(b):
    c = 0xFFFFFFFF
    for x in b:
        c ^= x
        for _ in range(8):
            c = (c >> 1) ^ 0x82F63B78 if c & 1 else c >> 1
    return c ^ 0xFFFFFFFF
root = sys.argv[1]
for rel in ["readme.txt", "etc/config", "etc/table.csv"]:
    b = open(os.path.join(root, rel), "rb").read()
    print(f"entry f /{rel} {len(b)} crc={crc32c(b)}")
    if len(b) <= 64:
        print(f"text /{rel} " + b.decode().replace("\n", "\\n"))
PY
  while IFS= read -r want; do
    expect "$want" "the board reads the host's file: $want"
  done < "$WORK/expect.txt"
  device_digest=$(value digest)
  host_digest=$("$HOST/hostdigest" "$IMG" | sed -n 's/^host digest //p')
  if [ -n "$device_digest" ] && [ "$device_digest" = "$host_digest" ]; then
    pass "the board's digest of the volume is the host's digest of the image, $device_digest"
  else
    fail "the board's digest is ${device_digest:-unknown}, the host's ${host_digest:-unknown}"
  fi
fi

echo ""
echo "6. the region read back through the probe"
if pr read b8 "$REGION_LO" "$REGION_LEN" -o "$WORK/back.bin" -f binary > "$WORK/back.log" 2>&1 \
   && cmp -s "$IMG" "$WORK/back.bin"; then
  pass "the region's $REGION_LEN bytes read back are the image byte for byte$([ "$DEVICE" = 1 ] && echo ', after the read-only mount')"
else
  fail "the region read back is not the image" "$(cmp "$IMG" "$WORK/back.bin" 2>&1 | head -3; tail -2 "$WORK/back.log")"
fi
if pr read b8 "0x$PROG_LO" "$PROG_LEN" -o "$WORK/prog_after.bin" -f binary > /dev/null 2>&1 \
   && cmp -s "$WORK/prog_before.bin" "$WORK/prog_after.bin"; then
  pass "the program's $PROG_LEN bytes read as they did before novo flash --data"
else
  fail "the program's flash changed under novo flash --data"
fi

if [ "$DEVICE" = "1" ]; then
  echo ""
  echo "7. a file written on the board, listed on the host"
  watch "$WORK/write.log" "write done" 60 run --no-catch-reset "$DEV/image_write.elf"
  OUT=$(clean "$WORK/write.log")
  expect "mount=ok"                 "image_write.nv mounts the volume"
  expect "write hello=ok"           "and writes /from-board.txt"
  expect "read hello same=1"        "which reads back the same"
  expect "root from-board.txt"      "and the root lists it"
  device_digest=$(value digest)
  if pr read b8 "$REGION_LO" "$REGION_LEN" -o "$WORK/after.bin" -f binary > /dev/null 2>&1; then
    pass "the region is read through the probe after the board's write"
  else
    fail "the region could not be read after the board's write"
  fi
  ls_out=$("$TOOL" ls "$WORK/after.bin" 2>&1)
  got=$(awk '{print $NF}' <<< "$ls_out" | sort | tr '\n' ' ' | sed 's/ $//')
  if [ "$got" = "etc from-board.txt readme.txt" ]; then
    pass "novofs ls lists the board's file beside the host's: $got"
  else
    fail "novofs ls lists '$got'" "$ls_out"
  fi
  cat_out=$("$TOOL" cat "$WORK/after.bin" /from-board.txt 2>&1)
  if [ "$cat_out" = "written by the board" ]; then
    pass "novofs cat reads the board's text: $cat_out"
  else
    fail "novofs cat reads '$cat_out'"
  fi
  if fsck=$("$TOOL" fsck "$WORK/after.bin" 2>&1); then
    pass "novofs fsck accepts the volume: $fsck"
  else
    fail "novofs fsck refuses the volume" "$fsck"
  fi
  host_digest=$("$HOST/hostdigest" "$WORK/after.bin" | sed -n 's/^host digest //p')
  if [ -n "$device_digest" ] && [ "$device_digest" = "$host_digest" ]; then
    pass "the host's digest of the region is the board's, $device_digest"
  else
    fail "the host's digest is ${host_digest:-unknown}, the board's ${device_digest:-unknown}"
  fi
fi

if [ "$DRIVE" = "1" ]; then
  echo ""
  echo "8. a second image through the BOOTSEL drive"
  printf 'the second image\n' > "$TREE/second.txt"
  IMG2="$WORK/image2.bin"
  if "$TOOL" mk "$TREE" -o "$IMG2" --target="$SLUG" > "$WORK/mk2.log" 2>&1 && ! cmp -s "$IMG" "$IMG2"; then
    pass "a second image, with /second.txt, is built for the board"
  else
    fail "the second image could not be built" "$(cat "$WORK/mk2.log")"
  fi
  # With the flash's first sector erased there is no boot2, so the boot
  # ROM starts its USB boot and shows the drive.  The boot ROM leaves the
  # flash unmapped, so the sector is written back through the probe after
  # the copy, the board boots its program again, and the flash is read
  # then: the program's bytes, sector 0 included, as section 4 read them.
  #
  # Once the drive is mounted, one more probe-rs session reads the
  # watchdog's control word.  On 2026-10-08, with no session between the
  # reset and the copy, or one only before the drive came up, the boot
  # ROM wrote every block of the copy and did not reboot: the watchdog
  # it reboots through stood at 1,000,000.  With a session after the
  # drive came up it rebooted each time.  A board put in BOOTSEL by its
  # button has no debugger attached.
  python3 -c "import sys; sys.stdout.buffer.write(b'\xff' * 4096)" > "$WORK/sector.bin"
  head -c 4096 "$WORK/prog_before.bin" > "$WORK/sector0.bin"
  if pr download --binary-format bin --base-address "0x$PROG_LO" "$WORK/sector.bin" > "$WORK/erase.log" 2>&1 \
     && pr reset > /dev/null 2>&1; then
    pass "the flash's first sector, boot2, is erased through the probe and the chip reset into the boot ROM's drive"
  else
    fail "the flash's first sector could not be erased" "$(tail -3 "$WORK/erase.log")"
  fi
  dev=""
  for _ in $(seq 1 60); do
    dev=$(lsblk -rno PATH,LABEL 2> /dev/null | awk '$2 == "RPI-RP2" {print $1}' | head -1)
    [ -n "$dev" ] && break
    sleep 0.5
  done
  if [ -n "$dev" ]; then
    mounted=$(lsblk -rno MOUNTPOINT "$dev" 2> /dev/null | head -1)
    if [ -z "$mounted" ]; then
      udisksctl mount -b "$dev" > /dev/null 2>&1
      sleep 1
      mounted=$(lsblk -rno MOUNTPOINT "$dev" 2> /dev/null | head -1)
    fi
  fi
  if [ -n "$dev" ] && [ -n "$mounted" ]; then
    pass "the RPI-RP2 drive is $dev, mounted at $(printf '%b' "$mounted")"
    pr read b32 0x40058000 1 > "$WORK/wdog.log" 2>&1
    # No probe-rs on PATH: no probe can be listed, so novo flash takes the
    # drive, as it does for a board with no probe.
    if PATH=/usr/bin:/bin NOVO_UF2_WAIT=30 "$NOVO" flash --target="$SLUG" --data "$IMG2" \
         > "$WORK/drive.log" 2>&1 && grep -q 'went away' "$WORK/drive.log"; then
      pass "novo flash --data with no probe copies the image's UF2 to the drive: $(grep -m1 'blocks for the data region' "$WORK/drive.log" | sed 's/^novo: //')"
    else
      fail "novo flash --data did not go through the drive" "$(tail -6 "$WORK/drive.log")"
    fi
    sleep 1
    if pr download --binary-format bin --base-address "0x$PROG_LO" "$WORK/sector0.bin" > "$WORK/restore.log" 2>&1 \
       && pr reset > /dev/null 2>&1; then
      pass "the program's first sector is written back through the probe and the board boots its program"
    else
      fail "the program's first sector could not be written back" "$(tail -3 "$WORK/restore.log")"
    fi
    sleep 1
    if pr read b8 "$REGION_LO" "$REGION_LEN" -o "$WORK/back2.bin" -f binary > /dev/null 2>&1 \
       && cmp -s "$IMG2" "$WORK/back2.bin"; then
      pass "the region read back through the probe is the second image byte for byte: the UF2 landed at $REGION_LO"
    else
      fail "the region read back is not the second image" "$(cmp "$IMG2" "$WORK/back2.bin" 2>&1 | head -3)"
    fi
    if pr read b8 "0x$PROG_LO" "$PROG_LEN" -o "$WORK/rest_after.bin" -f binary > /dev/null 2>&1 \
       && cmp -s "$WORK/prog_before.bin" "$WORK/rest_after.bin"; then
      pass "the program's $PROG_LEN bytes read as they did before: the drive path wrote the region only"
    else
      fail "the program's flash changed under the drive path"
    fi
    out=$("$TOOL" ls "$WORK/back2.bin" 2>&1)
    if grep -q ' second.txt$' <<< "$out"; then
      pass "novofs ls lists /second.txt in the region read back"
    else
      fail "novofs ls does not list /second.txt" "$out"
    fi
  else
    fail "no RPI-RP2 drive appeared, or it could not be mounted" "$(lsblk -rno PATH,LABEL,MOUNTPOINT 2>&1 | tail -8)"
  fi
fi

# ── 9. blink, last ─────────────────────────────────────────────────────────
echo ""
echo "9. blink, flashed last"
if pr download "$WORK/blink.elf" > "$WORK/dl.log" 2>&1 && pr reset > /dev/null 2>&1; then
  pass "blink is flashed"
else
  fail "blink could not be flashed" "$(tail -4 "$WORK/dl.log")"
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
