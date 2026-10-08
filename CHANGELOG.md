# Changelog

All notable changes to novofs are recorded here. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
package follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
with the pre-1.0 rule that a breaking change bumps the MINOR number.

## 0.3.0 — 2026-10-08

The package is the device's filesystem, with one public module,
`nvfs`.  The host's tools are the new `novofs-tools` package.  It needs
novo 0.20.1 or later, the first release in which a trait impl for a
struct forwards the effect parameter the struct binds (SPEC § 5.6, "An
impl forwards it").

### Added

- `FileSystem[e]`, a public trait whose methods carry the volume's
  names: `mkdir`, `remove`, `rename`, `stat`, `list`, `list_next`,
  `file_write`, `file_append`, `file_read_at`, `file_size`,
  `file_truncate` and `used_blocks`.  `Volume<D>` implements it as
  `FileSystem[mutate, e]`, charged the effects of its device, and
  another filesystem implements it too.
- `list(path)` and `list_next(listing)`, which list a directory as a
  `Listing` and answer each `Entry` in order, then `None`.
- `Entry`, a directory entry with `is_dir`, `size` and its name's
  bytes, and `Entry.name_str()`, its name as a string.  `stat` answers
  an `Entry`.
- Sources a write takes without an impl of the program's own: a string
  literal, a `Buf`, and a list of bytes, each `ByteSrc`.
- `RegionFlash`, `region_flash()` and `region_flash_at(start, size)` in
  `nvfs`.
- The README leads with three programs for a board, in `examples/`:
  `settings.nv`, a record kept across resets; `logger.nv`, a log of
  readings appended one record at a time; and `config.nv`, a file read
  from a volume built on the host.  It has a section for a reader who
  knows littlefs.

### Changed

- CRC-32C is crc-nv's (`crc32c_start`, `crc32c_step`, `crc32c_finish`,
  crc-nv 0.1.6), a new dependency.  The values are the same.
- `layer = "host"`: the public surface's effects are `hw` and `mutate`.
  embedded-hal-nv is no longer a dependency.
- `format` forgets the blocks retired after failures and starts the
  allocator from its first block, as a fresh volume.  A program that
  formatted twice in one run kept the first volume's retired blocks.
- The filesystem is one module, so a device image that names `nvfs`
  carries its static storage, 1,800 bytes, whether or not it mounts a
  volume.  The `.text` of a build that uses every operation is 45,704
  bytes on the MPS2 AN386, where 0.2.1's was 39,168: the `FileSystem`
  impl, `Entry` and the listing.

### Removed (breaking)

Each removal names what replaces it.

- **The modules `flash`, `meta`, `crc32`, `regionflash`, `hostdev`,
  `hostfs`, `vfs`, `haladapt`, `halflash` and the program `main`.**
  `use flash`, `use regionflash` and `use crc32` become `use nvfs`:
  `Flash`, `Buf`, `BUF_CAP`, `ByteSrc`, `NoSrc`, `no_src`,
  `RegionFlash`, `region_flash` and `region_flash_at` are `nvfs`'s.
  `crc32.update(c, b)` is crc-nv's `crc.crc32c_step(c, b)`, from a
  register started with `crc.crc32c_start()` and finished with
  `crc.crc32c_finish(c)`.
- **`halflash` and `HalFlash`**, the device over `hal.block`'s 512-byte
  blocks.  A program mounts the board's reserved region with
  `nvfs.region_flash()`, which QEMU's MPS2 machines reach too.  A
  volume written by HalFlash does not mount on RegionFlash: the blocks
  differ in size, and `mount_with(dev, cfg, true)` reports it rather
  than formatting over it, so a program that changes device formats
  the region once with `nvfs.format`.
- **The image tool, `novofs mk|ls|cat|fsck|df|extract`**, and the host
  modules `hostdev` (`RamFlash`, `FileFlash`, `ram_flash`,
  `file_flash`, the power-cut, wear and bad-block controls,
  `prog_bytes`, `read_bytes`), `hostfs` (`src`, `dir_list`,
  `file_read`, `file_read_at`, `file_write`, `file_append`,
  `entry_size`) and `haladapt` (`RamBlock`, `BlockFlash`, `ram_block`,
  `block_flash`).  They are the `novofs-tools` package: `novo install
  novofs-tools` installs the image tool as `novofs-tools`, and a host
  program takes the devices and the wrappers from it with
  `novofs-tools = "^0.1.0"`.  The RAM device keeps its cells in a list,
  so its effects are `[mutate]` where they were `[mutate, ffi]`.
- **`vfs`'s `FileSystem` with its `fs_` methods, `NovoFs`,
  `NovoFsFile`, `novofs()` and `novofs_file()`.**  The volume
  implements `nvfs.FileSystem` itself: `f.fs_mkdir(p)` is
  `vol.mkdir(p)`, `f.fs_list(p)` is `vol.list(p)` with `list_next`,
  `f.fs_read_at(p, off, len)` is `vol.file_read_at(p, off, len, buf)`,
  and the `Bytes` forms are novofs-tools' `hostfs`.
- **The volume's methods `dir_open`, `dir_open_pair`, `dir_next`,
  `ent_read` and `ent_name_byte`, and `DirOpen`, `DirCur` and `Ent`.**
  `vol.list(path)` and `vol.list_next(listing)` list a directory and
  answer `Entry` values; a file's bytes are read by path with
  `file_read_at`.
- **`validate`, `ent_size` and `wear_reset` are no longer public.**
  `format` answers EInvalidConfig for a configuration `validate`
  refused, and an `Entry`'s `size` is what `ent_size` answered.

## 0.2.1 — 2026-10-08

- The rename resolver's backward search is a function of its own, so
  the resolver's frame holds the outer walk's records and not both
  walks': the deepest chain below `file_write` on the STM32F407 image
  is 3,656 bytes, where 0.2.0's was 3,696.  No change in what any
  operation answers.
- The stack-chain tool counts a function's largest call-site stack
  adjustment, not the sum of them: two calls' argument areas are never
  live at once.  0.2.0's tool read the resolver as 1,352 bytes of frame
  and the chain as 4,408, over a 4 KB task stack, for a frame that is
  728 bytes.
- The README's figure for the write chain follows the tool.

## 0.2.0 — 2026-10-08

A mounted volume.  It needs novo 0.20.0 or later, the first release in
which a struct binds its bound's effect parameter (SPEC §5.6, "A struct
binds it too").

### Added

- The host surface is public, so a program that depends on novofs uses
  it without a package-privacy warning: hostdev's `ram_flash` and
  `file_flash`, RamFlash's power-cut, wear and bad-block controls
  (`ram_schedule_cut`, `ram_clear_cut`, `ram_op_count_get`,
  `ram_op_count_reset`, `ram_mark_bad`, `ram_is_bad`, `ram_erase_count`,
  `ram_recycle`), `prog_bytes` and `read_bytes`; hostfs's `src`,
  `entry_size`, `dir_list`, `file_read`, `file_read_at`, `file_write` and
  `file_append`; vfs's `novofs` and `novofs_file`; haladapt's
  `ram_block` and `block_flash`.
- Host test suites under `tests/`: the volume's operations, compaction,
  the relocation of a worn metadata pair, superblocks and records written
  by hand, devices that fail reads, progs, erases and syncs, power cut
  at every step of a compaction, the host devices, the `FileSystem`
  trait and the block-device adapter.  They run every line under `src/`
  that the host reaches.

### Changed

- `nvfs.mount(dev)` and `nvfs.mount_with(dev, cfg, format_on_empty)`
  answer a `Volume<D>`, which owns the device, in place of a
  `MountRes`.  `vol.mounted()` answers the `MountRes` the mount used to,
  `vol.status()` its error alone, `vol.info()` the superblock's facts,
  and `vol.unmount()` gives the device back.  A volume that did not
  mount answers every operation with the mount's error.
- Every operation is a method of the volume: `mkdir`, `remove`,
  `rename`, `file_write`, `file_append`, `file_truncate`, `file_size`,
  `file_read_at`, `stat`, `ent_read`, `ent_name_byte`, `dir_open`,
  `dir_open_pair`, `dir_next` and `used_blocks`, each without the device
  and the `FsInfo` arguments.  `format` and `validate` still take a
  device.
- `hostfs`'s `file_read`, `file_read_at`, `dir_list`, `file_write` and
  `file_append` take the volume, and `vfs.novofs` and `vfs.novofs_file`
  wrap one.

### Fixed

- A file or directory renamed more than 32 times between two
  compactions of its directory's metadata block read as absent, and the
  next compaction dropped it.  The chain of renames is now followed in a
  loop with no length limit.  A 512-byte block compacts before a chain
  grows that long; a 4 KB or 128 KB block did not.
- The core's test module moved from `src/` to `tests/`, so a program
  that depends on novofs no longer compiles it.
- The documentation of `ram_schedule_cut` says what it does: of the next
  progs and erases, `after_ops - 1` succeed and the next one is cut.
- An operation on a volume whose metadata block is large no longer reads
  and checks the block's whole log each time.  The volume keeps the read
  cache, the last two block scans and the allocator's free-space window
  from one operation to the next, an append files the scan its block now
  has, and a walk over a log's record headers reads short windows.  On
  the STM32F407G-DISC1's 128 KB sectors the bench's fill of 314 files
  took 117.6 s and their removal 408.0 s; they take 7.5 s and 16.8 s.

### Unchanged

- The on-flash format.  A volume novofs 0.1.x wrote mounts on 0.2.0 and
  the reverse: for the same workload 0.2.0 writes the image 0.1.0 wrote,
  byte for byte (the novo-lang repository's
  tests/orbit/test_novofs_cli.sh, with the 0.1.0 image in this
  package's tests/fixtures/).

## 0.1.0

The first release: the `Flash` trait with RAM, file, block-device,
`hal.block` and region devices, copy-on-write metadata pairs,
CRC-checked commits, CTZ files, and the image tool.
