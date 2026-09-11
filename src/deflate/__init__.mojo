"""Raw DEFLATE (RFC 1951) in pure Mojo — no FFI, no dependencies.

`deflate` compresses, `inflate` decompresses, and `inflate_at` decompresses
one stream out of several laid back to back, reporting where it ended.

```mojo
from deflate import deflate, inflate

var packed = deflate(Span(data))    # List[UInt8], raw DEFLATE
var back = inflate(Span(packed))    # List[UInt8], == data
```

The streams here are *raw*: no zlib (RFC 1950) header, no gzip (RFC 1952)
wrapper, no trailing checksum. Framed formats are the caller's to parse —
`parquet.mojo`'s `GZIP` codec reads the gzip header and trailer and hands the
body to `inflate_at`; Avro's `deflate` block codec is raw and needs nothing.
"""

from deflate.raw import deflate, inflate, inflate_at
