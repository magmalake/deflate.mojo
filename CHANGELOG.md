# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
