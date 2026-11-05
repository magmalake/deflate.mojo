"""DEFLATE (RFC 1951) and gzip (RFC 1952) in pure Mojo — no FFI, no
dependencies.

`deflate` compresses, `inflate` decompresses, and `inflate_at` decompresses
one stream out of several laid back to back, reporting where it ended.
`gunzip` decodes a `.gz` file (every member, CRC-32 and length checked),
`gunzip_at` one member of it, and `gzip` writes one. `GzipReader` and
`Inflater` are the streaming forms: they decode a window at a time, from
input that may still be arriving.

```mojo
from deflate import deflate, inflate

var packed = deflate(Span(data))    # List[UInt8], raw DEFLATE
var back = inflate(Span(packed))    # List[UInt8], == data
```

`inflate` and `deflate` streams are *raw*: no zlib (RFC 1950) header, no
gzip wrapper, no trailing checksum. Avro's `deflate` block codec is raw and
needs nothing more; gzip files go through `gunzip`.
"""

from deflate.raw import (
    MARGIN,
    InflateStatus,
    Inflater,
    deflate,
    inflate,
    inflate_at,
)
from deflate.gzip import GzipReader, gunzip, gunzip_at, gzip
