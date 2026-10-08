# novofs

novofs is a filesystem for a microcontroller's NOR flash that survives
a power cut at any moment and spreads its writes over the device,
written in novo-lang.  Its on-flash format is modelled on
[littlefs](https://github.com/littlefs-project/littlefs): metadata
pairs, commit logs checked by CRC-32C, and files kept in CTZ
skip-lists.  A novofs volume is not a littlefs volume.  A program
mounts a volume on the board's reserved flash region, or on any
storage that implements the package's `Flash` trait, and reads and
writes files in it by path.

## What it is

NOR flash programs in small pages but erases in large blocks, and a
program can only clear bits: a byte goes back to 0xFF only when its
whole block is erased.  A filesystem on it must never program a byte
twice without an erase between, and must leave a readable state when
power fails in the middle of any program or erase.

Every directory, the root included, lives in a metadata pair: two
erase blocks that hold an append-only log of records, each record
checked by its own CRC-32C.  The root's pair, blocks 0 and 1, also
holds the superblock, as in littlefs.  The block of a pair with the
higher sealed revision is the active one.  A directory's state is the
fold of its active block's records in log order: a directory entry
adds or replaces a name, a tombstone removes it, and a rename moves
it.

Every change to the filesystem is exactly one record, a rename
included, so the atomicity of one record's commit is the whole of the
crash-consistency rule.  When a record does not fit its block,
compaction folds the live state into the sibling block with the
revision plus one, and the new record rides inside that compaction.
The sibling's revision word is programmed last, which seals it, so a
compaction cut short is invisible.

A file of at most `inline_max` bytes lives in its directory entry.  A
larger file lives in a CTZ skip-list of data blocks, which seeks in
O(log n).  Writes are copy-on-write: the allocator never hands out a
block a walk from the root reaches, so a cut in the middle of a write
keeps the old file.  Allocation rotates over the device, a metadata
pair moves to fresh blocks every `block_cycles` compactions, and a
block that fails an erase or a program is retired and the operation
retried.

A program reaches all of it through one module, `nvfs`.  It mounts a
device and gets a `Volume`, the mounted volume, which owns the device.
The volume's operations each take a path and are one committed change
or one read: there are no open file handles.

## Install

```sh
novo pkg add novofs
```

## Example

Each example is a program for a board.  Put it in a project that
depends on novofs as `src/main.nv`, and build and flash it for the
board:

```sh
novo pkg init settings && cd settings
novo pkg add novofs
cp settings.nv src/main.nv
novo flash --target=nrf52832-dk src/main.nv
```

The programs print on the board's console, which `novo logs
--target=<board>` shows.  They are in this package's `examples/`.

### A record that survives a reset

`examples/settings.nv` mounts the board's data region, formatting it
on the first boot, reads a record from `/settings`, writes it back with
its boot count one higher, and reads it again.  The record is a
`@value` struct that implements `ByteSrc`, the trait a file is written
from.

```novo norun:needs-pkg
use nvfs

@value
struct Settings
    boots: Int
    rate_hz: Int

// The record's eight bytes, two 32-bit little-endian numbers.
impl ByteSrc for Settings
    fn src_len(self) -> Int
        8

    fn src_at(self, i: Int) -> Int
        if i < 4
            (self.boots >>> (8 * i)) & 255
        else
            (self.rate_hz >>> (8 * (i - 4))) & 255

fn u32_at(var b: Buf, off: Int) -> Int
    (b[off] as Int) | ((b[off + 1] as Int) << 8) | ((b[off + 2] as Int) << 16)
        | ((b[off + 3] as Int) << 24)

fn main() [hw, mutate, time]
    bsp.board.init()
    // The board's data region, formatted when it holds no filesystem.
    let vol = nvfs.mount_with(nvfs.region_flash(), nvfs.default_config(), true)
    if vol.status() != EOk
        hal.uart.write("settings: mount failed\n")
        return
    // The record from the last boot, or the defaults on the first.
    var s = Settings { boots: 0, rate_hz: 100 }
    var buf: Buf = Vec.new()
    if vol.file_read_at("/settings", 0, 8, buf) == EOk and buf.len() == 8
        s = Settings { boots: u32_at(buf, 0), rate_hz: u32_at(buf, 4) }
    // One more boot, written as one commit.
    s = Settings { boots: s.boots + 1, rate_hz: s.rate_hz }
    let _ = vol.file_write("/settings", s)
    hal.uart.write("settings: boots=")
    hal.uart.write(str.from_int(s.boots))
    hal.uart.write("\n")
```

Each reset of the board starts the program again, and the count it
prints is one higher:

```text
settings: mounted
settings: boots=3 rate=100
settings: read back boots=3 rate=100
```

### A log of readings

`examples/logger.nv` keeps a log the way a sensor node does: each
reading is a four-byte record, a sequence number and a value, appended
to `/log` as one commit.  At start the program reads the last record
to find where it left off.  When the volume is full the log starts
again from the record that did not fit.

```novo norun:fragment
let r = Record { seq: seq, reading: sample }
var rc = vol.file_append("/log", r)
if rc == ENoSpace
    rc = vol.file_write("/log", r)       // a full volume: start again
```

```text
logger: resumed after record 10
logger: appended 11 reading 33
...
logger: /log holds 15 records
```

### A configuration file from the host

`examples/config.nv` reads `/etc/config` from a volume that was built
on the host from a folder and written into the board's data region.
The image tool is the `novofs-tools` package:

```sh
mkdir -p files/etc
printf 'rate=250\n' > files/etc/config
novofs-tools mk files -o files.bin --target=nrf52832-dk
novo flash --target=nrf52832-dk --data files.bin
```

The program mounts the region without formatting it, so a region with
no volume is reported rather than formatted over, and reads the file
into a buffer:

```novo norun:fragment
let vol = nvfs.mount(nvfs.region_flash())
var buf: Buf = Vec.new()
let rc = vol.file_read_at("/etc/config", 0, vol.file_size("/etc/config"), buf)
```

```text
config: /etc/config holds 9 bytes
config: rate=250
config: rate is 250
```

## If you know littlefs

| littlefs | novofs |
|---|---|
| `struct lfs_config` and its `read`, `prog`, `erase` and `sync` callbacks | the `Flash` trait a device implements: `read`, `prog`, `erase`, `sync`, `read_size`, `prog_size`, `block_size`, `block_count` |
| `read_size`, `prog_size`, `block_size`, `block_count` | the device's methods of the same names |
| `cache_size`, `lookahead_size`, `block_cycles`, `name_max`, `file_max`, `inline_max` | the fields of `FsConfig`; `default_config()` is a filled one |
| `lfs_format` | `format(dev, cfg)` |
| `lfs_mount`, `lfs_unmount` | `mount(dev)`, `mount_with(dev, cfg, format_on_empty)`, `vol.unmount()` |
| `lfs_mkdir`, `lfs_remove`, `lfs_rename`, `lfs_stat` | `vol.mkdir`, `vol.remove`, `vol.rename`, `vol.stat` |
| `lfs_file_open`, `lfs_file_write`, `lfs_file_close` | `vol.file_write(path, src)`, `vol.file_append(path, src)` |
| `lfs_file_open`, `lfs_file_read`, `lfs_file_close` | `vol.file_read_at(path, off, len, buf)` |
| `lfs_file_size`, `lfs_file_truncate` | `vol.file_size(path)`, `vol.file_truncate(path, len)` |
| `lfs_dir_open`, `lfs_dir_read`, `lfs_dir_close` | `vol.list(path)`, then `vol.list_next(listing)` until `None` |
| `lfs_fs_size` | `vol.used_blocks()`, and `vol.info()` for the geometry |

novofs has no open file handles: every operation takes a path and is
one committed record or one read.  That is the power-cut rule in the
interface: an operation a cut interrupts leaves the volume as it was
before the operation or as it is after it.

## What the package contains

| Module | What is in it |
|---|---|
| `nvfs` | The whole public surface: the `Flash` trait and `RegionFlash`, the device over the board's reserved region; `ByteSrc` and the sources a write takes; `FsConfig`, `format`, `mount` and `mount_with`; the `Volume` and the `FileSystem` trait it implements; and the answers, `FsError`, `MountRes`, `FsInfo`, `Entry`, `EntRes` and `Listing` |

The generated reference lists every declaration with its comment.

## How to choose an entry point

- A program on a board mounts `nvfs.region_flash()`, the bytes its
  board's manifest reserves, with `mount_with(dev, cfg, true)` when it
  owns the region and formats it on the first boot, or with `mount`
  when the region was written from the host.
- A program on a board with storage of another kind implements `Flash`
  for it and mounts that device.
- A program that should work with any filesystem takes a `FileSystem`
  as a bounded type parameter, `fn log<F: FileSystem[e]>(fs: F)`; the
  volume implements it, and so can another filesystem.
- A host program that prepares a volume for a board, tests a program
  against a RAM device with power cuts, or wants whole files and
  listings as `Bytes` and lists, uses the `novofs-tools` package.

### What a write takes

A file is written from a `ByteSrc`: `src_len` bytes, each answered by
`src_at`.  The package's own sources:

| Source | Use |
|---|---|
| a string, `"booted"` | text |
| a `Buf`, a buffer of at most 512 bytes the program filled | bytes built at run time, in the caller's frame |
| a list of bytes, `[u8]` | bytes a host program or a program with a heap holds |
| `no_src()` | an empty file |

A record of the program's own, such as a `@value` struct, implements
`ByteSrc` and is written as it is.

### What a read gives

`file_read_at(path, off, len, buf)` replaces the contents of a `Buf`
with at most 512 bytes of the file.  `stat(path)` answers an `Entry`:
whether it is a directory, its size, and its name's bytes.  `list(path)`
opens a directory and `list_next(listing)` answers its entries in
order, and `None` after the last one.  `Entry.name_str()` gives the
name as a string, from the heap on the host and from the arena on a
board.

## The rules a user needs

1. Every change is one record, committed whole or not at all.  A power
   cut leaves each directory as it was before the change in flight or
   as it is after it.
2. `rename` works within one directory.  A move to another directory
   would need two pairs committed together, which this format cannot
   express without littlefs-style global move state, and it answers
   `ENotSupported`.
3. `remove` refuses a directory that still has entries (`ENotEmpty`):
   one tombstone is one atomic commit, and a recursive delete could
   not be.
4. `file_append` and a `file_truncate` that extends rewrite the file,
   in O(n) of its size.  A truncate that shrinks a chain keeps the
   chain's prefix.
5. `mount_with(dev, cfg, format_on_empty)` formats a device that holds
   no filesystem when asked, and never one that holds something else.
   An application formats its data region this way on its first boot,
   and a bootloader never writes it.
6. A volume that did not mount answers every operation with the
   mount's error, so a program checks `vol.status()` once.
7. One volume's state, the read cache and the last block scans, is
   module storage of a fixed size.  A program with two volumes mounted
   gets right answers from both, and the state is built again each
   time it moves from one to the other.

### The on-flash format

```text
block    = [ revision u32 | pad to meta_off | records ... | 0xFF free ]
meta_off = max(4, prog_size)
record   = [ type u8 | flags u8 | len u16 | payload | crc32c u32 ], padded with 0xFF to a prog_size multiple

0x01 superblock   magic, version, geometry, name, inline and file maxima, block_cycles
0x02 dir entry    kind u8 | name_len u8 | name | pair0 u32 | pair1 u32
                  (an inline file: kind u8 | name_len u8 | name | data)
0x03 tombstone    name_len u8 | name
0x04 rename       old_len u8 | old | new_len u8 | new
0xFF              reserved forever: erased flash
```

- Records start on their own prog page, `meta_off` bytes into the
  block, so a compaction can program every record and then the
  revision word as a separate, final operation.  A cut before that
  operation leaves the sibling's revision erased, and the old block
  still wins.
- 0xFF is a reserved record type, because it is what erased NOR reads
  as.  The scanner skips runs of 0xFF between records.
- A bad CRC ends the block's valid log and marks the block full, and
  the next append goes through a compaction to the sibling.
- The revision is a u32, and its wraparound is not handled; at one
  compaction a second it is about 136 years away.

## Running on a microcontroller

Every function of `nvfs` builds for a microcontroller with no heap
allocator, and the registry lists the package at the embedded tier.
The effects of a device program's calls are `hw` and `mutate`: a
volume on `RegionFlash` is charged `[mutate, hw]`, and each operation
is charged the effects of the device it holds.  The filesystem runs in
fixed memory: three 512-byte buffers of static storage (the read
cache, the program buffer and the staging buffer of a record's inline
data), the allocator's 64-byte bitmap and its list of retired blocks,
the last two block scans, and the frames of the call in progress.  The
volume is the one allocation a mount makes, from the arena.  Every
operation on a mounted volume allocates nothing, except
`Entry.name_str`, which builds a string.

| Measure | Value |
|---|---|
| `.text` of the filesystem, every operation used, MPS2 AN386 build | 45,704 bytes |
| Static RAM: the read cache and the program buffer | 1,040 bytes |
| Static RAM beyond them: the staging buffer, the allocator's bitmap and retired list, the kept scans | 760 bytes |
| Deepest chain of stack frames below a volume's `file_write`, STM32F407G-DISC1 and nRF52832-DK images | 3,656 bytes |

### On a board's flash: RegionFlash

A board with a flash driver states the bytes the block device may
erase and write, `block_region` in its manifest or the data region of
its `[flash]` table, and `hal.block`'s region surface reaches them by
offset in the units the flash erases and programs.  `region_flash()`
is the whole region, and `region_flash_at(start, size)` a partition of
it that starts and ends on erase units.

One novofs block is one erase unit.  A metadata pair is two blocks the
filesystem erases one at a time, and a block is erased only when
nothing in it is live, so a block has to be a unit the flash erases on
its own.  Inside a block the filesystem appends: a program writes
bytes of an erased unit and never erases, so a reset in the middle of
one loses that write only.  What the mapping costs: a file too large
for its directory record takes at least one whole unit, and a
compaction erases a whole unit.

| Board | Region | Blocks | Erase of a block | What a volume holds |
|---|---|---|---|---|
| nRF52832-DK, nRF52840-DK | the top 32 KB | 8 of 4,096 bytes | up to 85 ms, by the nRF52840 Product Specification | the metadata pair and six data blocks |
| STM32F407G-DISC1 | sectors 10 and 11, 256 KB | 2 of 131,072 bytes | 1.0 s, measured on the board | the metadata pair only: files up to `inline_max` bytes, in their directory records |
| Raspberry Pi Pico (RP2040) | the top 32 KB of its 2 MB flash | 8 of 4,096 bytes | as the flash part's datasheet gives it | the metadata pair and six data blocks |

## What is not included

- A device over embedded-hal-nv's `AsyncBlock`, for storage that
  completes on an interrupt.  Such a device implements `Flash` over the
  awaitable trait.
- O(1) append at a file's tail: it needs file handles, which this
  interface does not have.  The format leaves room for them.
- A rename across directories: it needs littlefs-style global move
  state.
- A record on the flash of the blocks retired after a failure: the
  retired set lives as long as the program, and a block retired after
  a failed erase is a candidate again on the next mount.
- Revision wraparound, as above.
- littlefs compatibility.
- The image tool, the RAM and image-file devices and the host's view
  of a volume: they are the `novofs-tools` package.

## Related packages

- [novofs-tools](https://novo-lang.org/packages/novofs-tools) is the
  host's side: the image tool (`mk`, `ls`, `cat`, `fsck`, `df`,
  `extract`), a RAM device with power-cut injection, an image-file
  device, an adapter from embedded-hal-nv's `BlockDevice`, and whole
  files and listings over any `FileSystem`.
- [crc-nv](https://novo-lang.org/packages/crc-nv) computes the
  CRC-32C every record carries.
- [littlefs](https://github.com/littlefs-project/littlefs), in C, is
  the design this format is modelled on.

## Tests

`novo test tests` runs the host suites, each over a RAM device of its
own:

| Suite | What it asserts |
|---|---|
| `tests/core_tests.nv` | the CRC-32C check value, the record sizes, the path components, the skip-list geometry, the default configuration |
| `tests/volume_tests.nv` | format, mount and its refusals, `mount_with`, every operation of the volume and what each answers for a path it cannot serve, listings, inline and chained files, append, truncate, a full volume, two volumes in turn |
| `tests/media_tests.nv` | compaction, the move of a worn metadata pair, superblocks and records written by hand, the arbitration of a pair, renames from absent names, devices whose reads, programs, erases or syncs fail, a power cut at every step of a compaction, reads that fail at every point of a mount, a compaction and a move |
| `tests/layout_tests.nv` | every rule the configuration is checked by, the read cache and the kept scans, a record that runs past its block, 4-byte pages, 2 KB blocks, a long chain of renames, the allocator's retries, a directory that contains itself |
| `tests/filesystem_tests.nv` | a program that names `nvfs` alone: a device of its own, and a write, an append and a listing through the `FileSystem` trait |
| `tests/board_tests.nv` | RegionFlash on the host, which has no region, and the sources a write takes |

Together they run every line of `src/` that the host reaches.  The
lines that only a board's region reaches carry a `cov: skip` marker
that says so.  The novo-lang repository runs the device half: the
examples on QEMU's MPS2 AN386 and on the nRF52832-DK and the
STM32F407G-DISC1, a power-loss harness over every program and erase
boundary of a scripted workload, and a four-boot bench on each board's
reserved region.

## Licence

Apache-2.0.  See [LICENSE](LICENSE).
