# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-11-05

### Added

- **Streaming inflate** ([#8](https://github.com/magmalake/deflate.mojo/issues/8)).
  `GzipReader` (gzip, multi-member) and `Inflater` (raw DEFLATE) decode into
  a window the caller drains: `run(data, complete, want)` decodes until the
  window holds `want` bytes, the input runs short or the stream ends, and
  returns an `InflateStatus` (`OUTPUT`, `NEED_INPUT`, `FINISHED`);
  `compact(k)` drops used output, keeping the 32 KiB back-references reach.
  The input may still be arriving: a block that runs past it is rolled back
  and decoded again once more is there (`MARGIN`, 256 KiB of input in hand,
  makes that rare), and `discard_input()` lets the caller drop input already
  consumed. Header, CRC-32 and ISIZE checks are `gunzip`'s. Moved here from
  mojo-census's `gharchive` pipeline, which carried it as `GzipInflater`.

### Changed

- `inflate`, `inflate_at`, `gunzip` and `gunzip_at` are now built on the
  streaming readers, run once over the whole input; results and error
  messages are unchanged, except that raw DEFLATE errors start `inflate:`
  rather than `avro.deflate:`.
- Matches whose distance is at least 8 are copied eight bytes at a time
  rather than byte by byte: `gunzip` of a GH Archive hour (70 MB to 491 MB)
  goes from 541 to 424 ms on an M4.
- **A faster decode loop** ([#9](https://github.com/magmalake/deflate.mojo/issues/9)),
  for every caller (one-shot and streaming). It refills the bit buffer once
  per symbol, with no bounds checks while eight bytes of input remain. It
  takes further literals from the same refill. Codes are looked up in a
  10-bit first-level table (was 9) whose length and distance entries carry
  their base and extra-bit count. Matches are copied 16 bytes at a time
  when the distance allows, and runs of one byte are broadcast. Dynamic
  blocks rebuild their Huffman tables in place instead of allocating them,
  and the fixed tables, the RFC 1951 tables and the CRC-32 table (unused
  where the Arm CRC instructions are) are built only when needed. On an M4,
  `gunzip` of a GH Archive hour takes 336 ms (1.46 GB/s), from 553 ms in
  0.1.3. avro.mojo's `bench_inflate` goes from 1.00 to 1.52 GB/s, and a
  one-shot `inflate` of a small stream from 8.4 to 5.7 µs.
- A stored block's NLEN is now checked against its LEN, and a dynamic block
  declaring more than 286 literal/length or 30 distance codes is refused.

## [0.1.3] - 2026-11-03

### Added

- **gzip (RFC 1952).** `gunzip(data)` decodes a whole `.gz` file: every
  member of a concatenated stream, all five header flags (FTEXT, FHCRC,
  FEXTRA, FNAME, FCOMMENT; FHCRC is verified), and each member's CRC-32 and
  ISIZE checked. Zero padding after the last member is accepted; any other
  trailing bytes, a truncated header, body or trailer, and a bad checksum
  raise an error naming the member and its offset. `gunzip_at(data, end)`
  decodes one member and reports where it ended, for walking a multi-member
  file without holding all of it. `gzip(data, level=6)` writes one member
  (level 0 as stored blocks, 1 to 9 through `deflate`).
- CRC-32 with the Arm CRC32 instructions where the target advertises them
  (about 10 GB/s on an M4) and a slice-by-8 table elsewhere.

### Changed

- `gunzip` decodes every member into one output buffer, sized from the final
  ISIZE, instead of a fresh buffer per member three times the size of the
  rest of the input.

## [0.1.2] - 2026-10-24

- Built with Mojo 1.2.0.
