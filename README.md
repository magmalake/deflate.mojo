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

There is no streaming (chunked-output) form, because `inflate` has none: a
member is decoded whole.

`gzip` writes one member with no name, comment or timestamp. Level 0 stores
the data uncompressed; levels 1 to 9 all use `deflate`'s single
fixed-Huffman strategy and give the same bytes, so the output is larger
than zlib's (about 17% of GH Archive JSON against zlib's 14% at level 6).

The CRC-32 uses the Arm CRC32 instructions where the build target has them
and a slice-by-8 table elsewhere (x86, and builds whose `mojo` resolved no
CPU).

On an Apple M4, `gunzip` decodes a GH Archive hour (94 MB compressed, 670 MB
of JSON) in 0.78 s, about 860 MB/s of output; Python's `zlib.decompress`
takes 0.73 s and Apple's `gzip -d` 0.31 s.

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
