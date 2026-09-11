# deflate.mojo

[![mojoshelf](https://mojoshelf.org/badge/deflate-mojo.svg)](https://mojoshelf.org/tins/deflate-mojo) [![mojo nightly](https://mojoshelf.org/badge/deflate-mojo/nightly.svg)](https://mojoshelf.org/tins/deflate-mojo)

> Part of [**magmalake**](https://magmalake.dev) — data lake building blocks in Mojo.

A pure-[Mojo](https://www.modular.com/mojo) implementation of **raw DEFLATE**
([RFC 1951](https://www.rfc-editor.org/rfc/rfc1951)) — the compression inside
gzip, zlib, Avro's `deflate` block codec and Parquet's `GZIP` page codec. No
FFI, no libz, no dependencies.

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

### Raw means raw

The streams here carry no framing: no zlib ([RFC 1950](https://www.rfc-editor.org/rfc/rfc1950))
header, no gzip ([RFC 1952](https://www.rfc-editor.org/rfc/rfc1952)) wrapper,
no trailing checksum. That is deliberate — the framings disagree with each
other, and every caller already knows which one it is holding. Avro's
`deflate` block codec is raw and needs nothing; Parquet's `GZIP` codec reads
the gzip header and trailer itself and passes the body in.

For several streams laid back to back — concatenated gzip members, for
instance — `inflate_at` reports where each one ended:

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
