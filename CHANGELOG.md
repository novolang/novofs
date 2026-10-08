# Changelog

All notable changes to novofs are recorded here. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
package follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
with the pre-1.0 rule that a breaking change bumps the MINOR number.

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
