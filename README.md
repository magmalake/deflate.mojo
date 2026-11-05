# deflate.mojo

[![mojoshelf](https://mojoshelf.org/badge/deflate-mojo.svg)](https://mojoshelf.org/tins/deflate-mojo) [![mojo nightly](https://mojoshelf.org/badge/deflate-mojo/nightly.svg)](https://mojoshelf.org/tins/deflate-mojo)

> Part of [**magmalake**](https://magmalake.dev) — data lake building blocks in Mojo.

A pure-[Mojo](https://www.modular.com/mojo) implementation of **raw DEFLATE**
([RFC 1951](https://www.rfc-editor.org/rfc/rfc1951)) — the compression inside
gzip, zlib, Avro's `deflate` block codec and Parquet's `GZIP` page codec —
and of the **gzip** file format ([RFC 1952](https://www.rfc-editor.org/rfc/rfc1952))
around it. No FFI, no libz, no dependencies.

`inflate` handles all three block types (stored, fixed-Huffman,
dynamic-Huffman). `deflate` emits fixed-Huffman blocks from a single-slot
hash-chain LZ77 matcher — the same "fast" strategy [snappy.mojo](https://github.com/magmalake/snappy.mojo)
uses — which keeps the encoder small.

## Install

```sh
pixi shelf add deflate-mojo
```

Working with a coding agent? `npx skills add mojoshelf/mojoshelf --skill mojoshelf-consume --yes` teaches it to find and install tins itself — it installs the `shelf` CLI too.

That resolves the tin from [mojoshelf](https://mojoshelf.org) and adds it as a **pixi git source dependency**. magmalake tins are not published to a conda channel, so `pixi add deflate-mojo` will not find them.

## Use

```mojo
from deflate import deflate, inflate

var packed = deflate(Span(data))    # List[UInt8], raw DEFLATE
var back = inflate(Span(packed))    # List[UInt8], == data
```

Consume it like the other magmalake libs — `-I ../deflate.mojo/src` (no FFI,
so there is nothing else to link).

### gzip

```mojo
from deflate import gunzip, gunzip_at, gzip

var json = gunzip(Span(gz_bytes))   # a whole .gz file, every member
var gz = gzip(Span(json), 6)        # one member; level 0..9
```

`gunzip` reads every member of a concatenated (multi-member) file and
returns their outputs joined, as `gzip -d` does. Each header is parsed with
all of its optional fields (FTEXT, FHCRC, FEXTRA, FNAME, FCOMMENT; a header
CRC is checked), and each member's CRC-32 and ISIZE are verified against
what it decoded to. Zero padding after the last member is accepted. Anything
else raises an `Error` naming the member and its byte offset: bad magic, an
unknown method, reserved flags, a truncated header, body or trailer, a CRC
or length mismatch, or trailing garbage.

To hold one member at a time, walk them with `gunzip_at`, which checks the
same things and reports where the member ended:

```mojo
var pos = 0
while pos < len(data):
    var end = 0
    var part = gunzip_at(Span(data)[pos:], end)   # one member, verified
    pos += end
```

To decode without holding the whole output, stream it (below).

`gzip` writes one member with no name, comment or timestamp. Level 0 stores
the data uncompressed; levels 1 to 9 all use `deflate`'s single
fixed-Huffman strategy and give the same bytes, so the output is larger
than zlib's (about 17% of GH Archive JSON against zlib's 14% at level 6).

The CRC-32 uses the Arm CRC32 instructions where the build target has them
and a slice-by-8 table elsewhere (x86, and builds whose `mojo` resolved no
CPU).

### Speed

On an Apple M4, `gunzip` decodes a GH Archive hour (2025-01-01-0: 70 MB
compressed, 492 MB of JSON) in 0.34 s, about 1.4 GB/s of output, CRC-32
included; streamed through a 16 MiB `GzipReader` window it takes the same.
For comparison, on the same file: Python's `zlib.decompress` (zlib 1.3.2)
0.54 s, Apple's `gzip -dc` 0.23 s, and libdeflate 1.26's whole-buffer
`libdeflate_gzip_decompress` 0.20 s.

The decode loop refills a 64-bit bit buffer once per symbol with one
unaligned load, unchecked while eight bytes of input remain (enough bits
for a length, a distance and their extra bits); takes further literals from
the same refill; looks codes up in a 10-bit table whose entries carry a
length's or distance's base and extra-bit count, as libdeflate's do; and
copies matches 16 or 8 bytes at a time. Dynamic blocks rebuild their tables
in place, and nothing is built for a block type the stream does not use,
so a one-shot call on a small input costs about 5 µs.

There is no libdeflate backend: this tin is pure Mojo with no dependencies
on purpose, so consumers need nothing but `-I deflate.mojo/src`. A
libdeflate binding would be a separate tin.

### Streaming

`GzipReader` (gzip, every member) and `Inflater` (one raw DEFLATE stream)
decode a window at a time, for output too large to hold whole — an hour of
GH Archive is one 70 MB member of 490 MB of JSON. `run(data, complete,
want)` decodes until the window, `output()`, holds `want` bytes, the input
runs short, or the stream ends, and returns `InflateStatus.OUTPUT`,
`NEED_INPUT` or `FINISHED`. `compact(k)` drops the first `k` bytes of the
window once the caller has used them (the last 32 KiB stay, since
back-references can reach that far) and returns how many went.

```mojo
from deflate import GzipReader, InflateStatus

var gz = GzipReader()                    # GzipReader(multi_member=False): one member
while True:
    var st = gz.run(Span(data)[:have], complete, len(gz) + (1 << 20))
    parse(gz.output())                   # everything decoded so far
    _ = gz.compact(len(gz))              # done with it
    if st == InflateStatus.FINISHED:
        break
    if st == InflateStatus.NEED_INPUT:
        ...                              # wait for more of `data`
```

The input can still be arriving: `data` is what has come so far and
`complete` says whether that is all of it. A block that runs past the end of
`data` is rolled back and decoded again on a later call; so that this is
rare, a block is only started with `MARGIN` (256 KiB) of input in hand,
more than any block zlib writes. Input the decoder is done with can be
dropped: `discard_input()` returns how many bytes at the front of `data` it
no longer needs, and the next `run` is passed `data` without them, so a long
download can go through a bounded buffer.

The checks are `gunzip`'s, with the same messages; the CRC-32 is folded in
as output is produced, so it covers bytes long since compacted away.
`gunzip`, `gunzip_at`, `inflate` and `inflate_at` are these readers run once
over the whole input, with a window that is never compacted.

### Raw means raw

`inflate` and `deflate` streams carry no framing: no zlib ([RFC 1950](https://www.rfc-editor.org/rfc/rfc1950))
header, no gzip wrapper, no trailing checksum. Avro's `deflate` block codec
is raw and needs nothing; for gzip files use `gunzip` above. Parquet's
`GZIP` codec reads the gzip header and trailer itself and passes the body in.

For several raw streams laid back to back, `inflate_at` reports where each
one ended:

```mojo
from deflate import inflate_at

var end = 0
var first = inflate_at(Span(data), end)   # `end` now indexes the next stream
var second = inflate_at(Span(data)[end:], end)
```

`end` is the offset of the first byte *after* the stream, rounded up to a byte
boundary.

## Develop

```sh
pixi run test    # nightly
pixi run -e stable test
pixi run lint
```

## History

This code began inside [avro.mojo](https://github.com/magmalake/avro.mojo) as
the implementation of Avro's `deflate` block codec, and moved here once
[parquet.mojo](https://github.com/magmalake/parquet.mojo) and
[iceberg.mojo](https://github.com/magmalake/iceberg.mojo) turned out to want
it too — a Parquet reader should not have to depend on Avro to read a gzipped
page.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
