# novofs

novofs is a filesystem for raw NOR-class flash that survives a power
cut at any moment and spreads its writes over the device, written
entirely in novo-lang.  Its on-flash format is modelled on
[littlefs](https://github.com/littlefs-project/littlefs): metadata
pairs, commit logs checked by CRC-32C, and files kept in CTZ
skip-lists.  A novofs volume is not a littlefs volume.  The package is
a library, which mounts a volume on any storage that implements its
`Flash` trait, and a command-line image tool, which builds, inspects
and unpacks volume images on the host.

## What it is

NOR flash programs in small pages but erases in large blocks, and a
program can only clear bits: a byte goes back to 0xFF only when its
whole block is erased.  A filesystem on it must never program a byte
twice without an erase between, and must leave a readable state when
power fails in the middle of any prog or erase.

Every directory, the root included, lives in a metadata pair: two
erase blocks that hold an append-only log of records, each record
checked by its own CRC-32C.  The root's pair, blocks 0 and 1, also
holds the superblock, as in littlefs.  The block of a pair with the
higher sealed revision is the active one.  A directory's state is the
fold of its active block's records in log order: a directory entry
adds or replaces a name, a tombstone removes it, and a rename moves
it.

Every change to the filesystem is exactly one record, a rename
included, so the atomicity of one record's commit is the whole of
the crash-consistency rule.  When a record does not fit its block,
compaction folds the live state into the sibling block with the
revision plus one, and the new record rides inside that compaction.
The sibling's revision word is programmed last, which seals it, so a
compaction cut short is invisible.  An append cut short ends the log,
and the block is treated as full.

A file of at most `inline_max` bytes lives in its directory entry.  A
larger file lives in a CTZ skip-list of data blocks, which seeks in
O(log n).  Writes are copy-on-write: the allocator, a rotating cursor
over a walk of every block reachable from the root, never hands out a
live block, so a crash in the middle of a write keeps the old file.
Allocation rotates over the device, a metadata pair moves to fresh
blocks every `block_cycles` compactions, and a block that fails an
erase or a prog is retired and the operation retried.

### The mounted volume

`nvfs.mount(dev)` moves the device into a `Volume<D>`, and
`vol.unmount()` gives it back.  Because nothing writes the device
between two operations of the volume except the volume, the state one
operation builds stays true for the next: the read cache, the last two
block scans (a scan reads a block's whole log and checks every
record's CRC), and the allocator's free-space window.  An append files
the scan its block now has instead of reading the block again, so an
operation on a volume whose metadata block is 128 KB reads the log's
record headers, not its every byte.  A volume that did not mount
answers every operation with the mount's error.

The state is module storage of a fixed size and belongs to one volume
at a time.  A program with two volumes mounted gets right answers from
both; each time it moves from one to the other, the state is dropped
and built again.  A host device that keeps a reference to shared
storage (a `RamFlash` the caller still holds) can be written around
the volume; such a write is seen by a volume mounted after it.

The volume is the one allocation of a mount: on the STM32F407 it takes
168 bytes of the arena, the volume and the copy of its device.  Each
operation is charged the effects of the volume's device: the struct
binds the `Flash` trait's effect parameter on its type parameter,
`Volume<D: Flash[e]>`, and its methods are `[mutate, e]`
(SPEC §5.6).

## Install

```sh
novo pkg add novofs       # the library, in a program's novo.toml
novo install novofs       # the image tool, into ~/.novo/bin
```

From a checkout of this repository:

```sh
novo pkg build            # builds ./novofs, the image tool
novo test tests           # runs the host suites
```

## Example

On the host, `hostfs` takes and answers `Bytes` and lists:

```novo norun:needs-pkg
use std.bytes
use hostdev
use nvfs
use hostfs

fn main() [io, mutate, ffi]
    // 32 blocks of 512 bytes, read and programmed in 16-byte pages
    let dev = hostdev.ram_flash(16, 16, 512, 32)
    let _ = nvfs.format(dev, nvfs.default_config())
    let vol = nvfs.mount(dev)
    match vol.mounted()
        MOk(info) =>
            let _ = vol.mkdir("/logs")
            let _ = hostfs.file_write(vol, "/logs/boot", bytes.from_str("booted"))
            match hostfs.file_read(vol, "/logs/boot")
                FOk(b) => println(bytes.to_str(b))
                FErr(e) => println(nvfs.err_str(e))
        MErr(e) => println("mount: " + nvfs.err_str(e))
```

On a device, the core itself: a file is written from a `ByteSrc`, read
into a `Buf` the caller owns, and a directory is walked with a cursor.
The mount allocates the volume from the arena; nothing in the calls on
it allocates, so they run in a `@no_alloc` function:

```novo norun:fragment
use flash
use nvfs
use halflash

@value
struct Word
    v: Int

impl ByteSrc for Word
    fn src_len(self) -> Int
        4
    fn src_at(self, i: Int) -> Int
        (self.v >>> (8 * i)) & 255

let vol = nvfs.mount(halflash.hal_flash())    // the board's hal.block storage
if vol.status() == EOk
    let _ = vol.file_append("/log", Word { v: reading })
    var buf: Buf = Vec.new()
    let _ = vol.file_read_at("/log", 0, 4, buf)
```

## What the package contains

| Module | What is in it |
|---|---|
| `flash` | The `Flash` trait a volume sits on, the `Buf` bytes move through, and the `ByteSrc` trait a file is written from |
| `crc32` | CRC-32C (Castagnoli), four bits at a time through a 16-entry table |
| `meta` | The metadata-pair mechanics: the read cache, the program buffer, scanning a block's log, and writing a record or a revision word |
| `nvfs` | The filesystem: the configuration, the errors, the superblock, the directory tree, files, the allocator, and the mounted volume |
| `hostdev` | The host devices: `RamFlash`, with strict NOR rules, wear counters, bad blocks and power-cut injection, and `FileFlash`, over an image file |
| `hostfs` | The host's view of a volume: files as `Bytes` and directories as lists |
| `vfs` | The `FileSystem` trait, and novofs behind it over a `RamFlash` and over an image file |
| `haladapt` | A `Flash` device over any `BlockDevice` from embedded-hal-nv, and `RamBlock`, a block device in RAM |
| `halflash` | `HalFlash`, a board's `hal.block` storage as a `Flash` device |
| `regionflash` | `RegionFlash`, a partition of a board's reserved flash region as a `Flash` device |
| `main` | The image tool: `mk`, `ls`, `cat`, `extract`, `fsck`, `df` |

## How to choose an entry point

- A device program calls the volume's methods with its board's device,
  `HalFlash` or `RegionFlash`.  They take a `ByteSrc` and fill a `Buf`,
  and allocate nothing.
- A host program that wants whole files and lists uses `hostfs` over a
  volume on a `RamFlash` or a `FileFlash`.
- A program that should work with any filesystem takes a
  `FileSystem`; `vfs.novofs` and `vfs.novofs_file` put a novofs volume
  behind it.
- A host build that prepares a volume for a board uses the image tool.

The library's surface, in `src/nvfs.nv`: `format(dev, cfg)` and
`validate(dev, cfg)` on a device; `mount(dev)` and
`mount_with(dev, cfg, format_on_empty)`, which answer a `Volume`; and
the volume's methods: `mounted` (the superblock's facts, or why it did
not mount), `status`, `info`, `mkdir`, `remove`, `rename` (within one
directory), `file_write`, `file_append`, `file_truncate`, `file_size`,
`file_read_at` (into a `Buf`), `stat` and `ent_read`, `ent_name_byte`,
`dir_open`, `dir_open_pair` and `dir_next`, `used_blocks`, and
`unmount`, which gives the device back.  Every operation takes a path.
`hostfs` adds `file_read`, `file_read_at`, `dir_list`, `file_write` and
`file_append` over `Bytes` and lists, each taking the volume.

### Plugging in storage: the `Flash` trait

```novo norun:fragment
trait Flash[e]                                // src/flash.nv
    fn read_size(self) -> Int [e]             // geometry
    fn prog_size(self) -> Int [e]
    fn block_size(self) -> Int [e]
    fn block_count(self) -> Int [e]
    fn read(self, block, off, len, var dst: Buf) -> Bool [e]
    fn prog(self, block, off, src: Buf) -> Bool [e]   // NOR: only clears bits
    fn erase(self, block) -> Bool [e]                 // → all 0xFF
    fn sync(self) -> Bool [e]
```

The trait binds one effect parameter, `e`, and each implementation
supplies the effects its storage costs.  The filesystem core is
generic over `D: Flash[e]` and declares `[mutate, e]`, so it names no
hardware, file or foreign-function effect of its own: a caller is
charged the effects of the device it passes.  Bytes cross the trait in
a `Buf`, a `Vec[u8; 512]` the caller owns, so a read or a prog
allocates nothing.

| Device | Module | Implements |
|---|---|---|
| `RamFlash`: host tests, with strict NOR rules, wear counters and power-cut injection | `hostdev` | `Flash[mutate, ffi]` |
| `FileFlash`: host image files; backs the image tool | `hostdev` | `Flash[fs]` |
| `BlockFlash`: any `dyn BlockDevice` from embedded-hal-nv, with a read-modify-write prog that keeps NOR rules | `haladapt` | `Flash[hw, ffi]` |
| `HalFlash`: a board's `hal.block` storage, the nRF52840-DK's flash or `novo_block.img` under QEMU | `halflash` | `Flash[hw, async, mutate]` |
| `RegionFlash`: a partition of a board's reserved flash region, one block per erase unit, through `hal.block`'s region surface | `regionflash` | `Flash[hw]` |

A device build uses `flash`, `crc32`, `meta`, `nvfs` and its device,
and never sees `hostdev` or `hostfs`.

### Substituting the whole filesystem: the `FileSystem` trait

A program that needs a filesystem, any filesystem, programs against
`dyn FileSystem` (`src/vfs.nv`): ten methods that each take a path,
with the shared `FsError` and `DirEntry` vocabulary.  A capability a
filesystem lacks answers `ENotSupported`.  The trait binds an effect
parameter, and novofs provides `NovoFs` over a `RamFlash`
(`FileSystem[mutate, ffi]`) and `NovoFsFile` over a `FileFlash`
(`FileSystem[fs, mutate]`).  Another filesystem plugs into the same
programs by implementing the trait.  The image tool's `fsck` and
`extract` walk a `FileSystem`.

## The image tool

```bash
novofs mk ./mytree -o image.bin --block-size 4096 --block-count 256
novofs mk ./mytree -o image.bin --target=nrf52832-dk   # the board's data region
novofs ls image.bin                 # kinds and sizes
novofs ls image.bin /sub
novofs cat image.bin /readme.txt    # text output (extract is byte-exact)
novofs fsck image.bin               # verifies the whole tree and counts it
novofs df image.bin                 # block usage
novofs extract image.bin -o ./out   # a byte-exact copy of the tree
```

- `mk` is deterministic: the same tree and flags give a byte-identical
  image (a sorted walk, an allocation that depends only on the cursor).
- `mk` must be told the target's geometry (`--prog-size` shapes the
  metadata layout), typed or with `--target=<board>`.  The read verbs
  need no flags: they find the superblock in block 0.
- Every error exits nonzero.

### An image for a board

`mk --target=<board>` builds an image for the board's data region: the
block size is the flash's erase unit, the block count the region's
units, and the page the one RegionFlash uses on the board.  The tool
asks the toolchain for them, `novo bsp region --target=<board>` (the
toolchain at `$NOVO`, else `novo` on PATH), so the board's manifest,
its `[flash]` table and the flash's units are read in one place.
`novo flash --data` then writes the image into the region at its
start.

```bash
mkdir -p files/etc
printf 'hello from the host\n' > files/readme.txt
printf 'rate=100\n' > files/etc/config
novofs mk files -o files.bin --target=nrf52832-dk
novo flash --target=nrf52832-dk --data files.bin
```

```text
mk: files.bin ok (5/8 blocks used), for the data region of nrf52832-dk at 0x78000, 8 blocks of 4096 bytes
novo: writing files.bin into the board nrf52832-dk's data region (block_region), 0x78000 to 0x80000, 8 blocks of 4096 bytes (chip=nRF52832_xxAA, probe=1366:1015:000682139029)
novo: the data region holds files.bin, read back and compared; the board was reset
```

A geometry option typed beside `--target` must agree with the
board's, or `mk` refuses it naming both.  A folder that does not fit
is refused with the shortfall, in blocks and bytes, and no image is
written.  On the nRF52832-DK each directory takes a metadata pair of
two 4 KB blocks and each file larger than `--inline-max` (128 bytes by
default) at least one block, so the eight blocks hold the root, one
directory and four such files, and an image that uses all eight leaves
the board no block for a write that needs one.  `novo flash --data`
refuses an image whose size, block size, block count or page is not
the board's.

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
4. Append and a truncate that extends rewrite the file, in O(n) of its
   size.  A truncate that shrinks a chain keeps the chain's prefix.
5. `nvfs.mount_with(dev, cfg, format_on_empty)` formats a device that
   holds no filesystem when asked, and never one that holds something
   else.  An application formats its data region this way on its first
   boot, and a bootloader never writes it.
6. A RamFlash's wear counters, bad blocks and power-cut schedule are
   module state and describe the most recently made RamFlash.

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

The block layout in `src/meta.nv` is the second shape the format took,
and the change is not backward compatible: a volume written by the
first shape does not mount.  There is no migration path; `novofs mk`
rebuilds images from a source tree, so the format is versioned by the
superblock's `VERSION` word rather than by upgrade code.

The first shape placed records immediately after the 4-byte revision
word.  The current shape pads records out to
`meta_off = max(4, prog_size)`, so that records begin on their own prog
page.  That padding is what makes sealing the revision last safe:
because no record shares a prog page with the revision word, a
compaction can program every record and then program the revision
word as a separate, final operation.  A power cut before that last
operation leaves the sibling's revision word erased (0xFFFFFFFF, read
as invalid) and the old block still winning; a power cut after it
leaves a block that is complete by construction.  With records packed
against the revision word, one prog page could carry both a partial
record and a live revision, and neither outcome would be recoverable.

The other format rules, unchanged since the first shape:

- 0xFF is a reserved record type forever, because it is what erased
  NOR reads as.  The scanner skips runs of 0xFF between records rather
  than stopping at the first one, since an appended commit starts on a
  prog-size boundary and padding then a record is the normal layout.
- A bad CRC ends the block's valid log and marks the block full.  The
  garbage tail cannot be programmed again reliably, since a prog only
  clears bits, so the next append goes through a compaction to the
  sibling.
- Revision wraparound is undefined.  The revision is a u32 and nothing
  handles it rolling over; at one compaction per second it would take
  about 136 years.

## Running on a microcontroller

The core (`flash`, `crc32`, `meta`, `nvfs`) is declared
`@tier(embedded)`, so every build checks it against the embedded tier,
and it runs in fixed memory: three `Buf`s of static storage (the read
cache, the program buffer and the staging buffer of a record's inline
data, 1,560 bytes), the allocator's 64-byte bitmap and 136-byte
retired-block list, the last two block scans (32 bytes), and the
frames of the call in progress, beside the mounted volume in the
arena.  It walks a metadata log in place instead of folding it into a
list, and writes a record or a data block through the program buffer
as it reads its source.  Every operation on a mounted volume passes
`@no_alloc`.

| Measure | Value |
|---|---|
| `.text` of the core, MPS2 AN386 build | 39,168 bytes |
| Static RAM beyond the read cache and the program buffer | 984 bytes |
| Deepest chain of stack frames below a volume's `file_write`, STM32F407 image | 3,624 bytes |

| Device | Module | Implements |
|---|---|---|
| `HalFlash`: a board's `hal.block`, the nRF52840-DK's flash, or `novo_block.img` under QEMU | `src/halflash.nv` | `Flash[hw, async, mutate]` |
| `RegionFlash`: a partition of a board's reserved region, one block per erase unit | `src/regionflash.nv` | `Flash[hw]` |
| `EmRam`: a RAM volume in static storage, with power-cut injection | `examples/emram.nv` | `Flash[mutate]` |

The host modules (`hostdev`, `hostfs`, `haladapt`, `vfs`) declare
every function `@tier(app)`: a device program that depends on novofs
is checked and linked without them.  The image tool, `src/main.nv`,
keeps the package as a whole at the app tier; the registry lists the
embedded, rt and system tiers for every other module, and wasm for
`crc32`, `flash`, `hostfs`, `meta` and `nvfs`.

### HalFlash

A board with storage offers `hal.block`: a fixed number of blocks of a
fixed size, a staging buffer the size of a block, and three arms
(read, write, erase) that each resolve a Future.  On the nRF52840-DK
the blocks are 512-byte slices of the top eight 4 KB pages of the
chip's flash, driven through its NVMC; under QEMU's MPS2 AN386 they
are 64 blocks of 512 bytes in `novo_block.img`, over semihosting.
HalFlash reports a 16-byte page and programs by a read-modify-write of
the whole block, so each prog costs one page erase on the DK.

### On a board's flash: RegionFlash

A board with a flash driver states the bytes the block device may
erase and write, `block_region` in its manifest, and `hal.block`'s
region surface reaches them by offset in the units the flash erases
and programs.  RegionFlash is a partition of that region: the whole of
it, `regionflash.region_flash()`, or `size` bytes from the address
`start`, `regionflash.region_flash_at(start, size)`, which must lie
inside the region and start and end on erase units (a partition that
does not has no blocks, and its mount is refused).

```novo norun:fragment
use flash
use nvfs
use regionflash

let dev = regionflash.region_flash()          // the manifest's block_region
let vol = nvfs.mount_with(dev, nvfs.default_config(), true)   // format on empty
match vol.mounted()
    MOk(info) =>
        let _ = vol.file_append("/log", Word { v: reading })
    MErr(e) => ...
```

One novofs block is one erase unit.  A metadata pair is two blocks the
filesystem erases one at a time, and a block is erased only when
nothing in it is live, so a block has to be a unit the flash erases on
its own.  Inside a block the filesystem appends: a prog programs bytes
of an erased unit and never erases, so a reset in the middle of a prog
loses that prog only, and the record's checksum rejects what it left.
What the mapping costs: a file too large for its directory record
takes at least one whole unit, and a compaction erases a whole unit.

| Board | Region | Blocks | Erase of a block | What a volume holds |
|---|---|---|---|---|
| nRF52832-DK, nRF52840-DK | the top 32 KB | 8 of 4,096 bytes | up to 85 ms, by the nRF52840 Product Specification | the metadata pair and six data blocks |
| STM32F407G-DISC1 | sectors 10 and 11, 256 KB | 2 of 131,072 bytes | 1.0 s, measured by the flash suite | the metadata pair only: files up to `inline_max` bytes, in their directory records |

### The examples

The examples are device programs, built with the novofs modules they
name copied beside them:

| Example | What it shows |
|---|---|
| `examples/boot_counter.nv` | format, mount, a counter file incremented across five mounts, remount, verify |
| `examples/powerloss.nv` | every cut point of a scripted workload, clean and torn, remounts to a state the workload passed through |
| `examples/crossmount.nv` | a `novofs mk` image mounted and written on the device, read back on the host |
| `examples/region_bench.nv` | four boots on a board's reserved region: format, write, read, a fill to the refusal, a cut in the middle of a write, a reset by the probe |
| `examples/image_read.nv` | a `mk --target` image mounted read-only from the board's data region: the geometry the driver answers, every entry, each file's CRC-32C, the digest |
| `examples/image_write.nv` | a file written on the board into that volume, for the host's `ls` and `cat` |
| `examples/emram.nv`, `examples/devtools.nv` | the RAM device and the helpers the other examples share |

## What is not included

- A `Flash` device over embedded-hal-nv's `AsyncBlock`, for storage
  that completes on an interrupt.  Such a device implements `Flash`
  over the awaitable trait.
- O(1) append at a file's tail: it needs file handles, which this
  API's path-based operations do not have.  The format leaves room for
  them.
- A rename across directories: it needs littlefs-style global move
  state.
- A record on the flash of the blocks retired after a failure: the
  retired set lives as long as the process, and a block retired after a
  failed erase is a candidate again on the next mount.
- Revision wraparound, as above.
- littlefs compatibility.

## Related packages

- [embedded-hal-nv](https://novo-lang.org/packages/embedded-hal-nv)
  defines the `BlockDevice` trait, which `haladapt` turns into a
  `Flash` device, and the board handles a program reaches storage
  through.
- [littlefs](https://github.com/littlefs-project/littlefs), in C, is
  the design this format is modelled on.

## Tests

`novo test tests` runs the host suites:

| Suite | What it asserts |
|---|---|
| `tests/core_tests.nv` | the CRC-32C check value, the record sizes, the path components, the skip-list geometry, the default configuration |
| `tests/volume_tests.nv` | format, mount and its refusals, `mount_with`, every operation of the volume and what each answers for a path it cannot serve, inline and chained files, append, truncate, a full volume, two volumes in turn |
| `tests/media_tests.nv` | compaction, the move of a worn metadata pair, superblocks and records written by hand, the arbitration of a pair, renames from absent names, devices whose reads, progs, erases or syncs fail, a power cut at every step of a compaction, reads that fail at every point of a mount, a compaction and a move |
| `tests/layout_tests.nv` | every rule `validate` checks, the read cache and the kept scans, a record that runs past its block, 4-byte pages, 2 KB blocks, a long chain of renames, the allocator's retries, a directory that contains itself |
| `tests/host_tests.nv` | RamFlash's NOR rules, bad blocks and power cuts; FileFlash over an image file and on a full device; the `FileSystem` trait over both host devices; RamBlock and the block-device adapter |
| `tests/board_tests.nv` | HalFlash and RegionFlash on the host, which has no storage for them |

Together they run every line under `src/` that the host reaches; the
coverage the publish measures is the host's.  The lines that only a
board's storage reaches, in `halflash.nv` and `regionflash.nv`, carry a
`cov: skip` marker that says so, and they are measured on the boards.
The novo-lang repository runs the device half and the image tool
against this package's sources: a 115-check functional suite, a
power-loss harness of 1,096 cuts (every prog and erase boundary, clean
and with three kinds of tear, with no state left unexplained), the
image tool's checks, the 0.1.0 image in `tests/fixtures/` read and
written by this release, a QEMU run of the examples (both directions
of the cross-mount, the boot counter, 46 cut points on the device, the
footprint), and the four-boot bench of `examples/region_bench.nv` on
the nRF52832-DK and the STM32F407G-DISC1 (`tests/board_bench.sh` and
`tests/board_image.sh`, driven by each board's `tests/novofs.sh` and
`tests/image.sh`), which measures `regionflash.nv`'s line coverage on
the board.

## Licence

Apache-2.0.  See [LICENSE](LICENSE).
