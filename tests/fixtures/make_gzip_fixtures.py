"""Regenerate the gzip fixtures that tests/test_gzip.mojo reads.

    python3 tests/fixtures/make_gzip_fixtures.py

Every file is written by Python's `gzip`/`zlib`, the reference the tests hold
`gunzip` to. Headers with flags Python never sets (FTEXT, FHCRC, FEXTRA,
FCOMMENT) are assembled by hand around a zlib raw-DEFLATE body. Output is
deterministic (MTIME 0), so rerunning changes nothing.
"""

import gzip
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))

TEXT = b"hello, gzip\n" * 3
"""What every small fixture decodes to (the test spells it the same way)."""


def raw_deflate(data, level=9):
    c = zlib.compressobj(level, zlib.DEFLATED, -15)
    return c.compress(data) + c.flush()


def member(data, flags=0, extra=b"", name=b"", comment=b"", level=9):
    """One gzip member with the given header fields, by hand."""
    head = bytearray(b"\x1f\x8b\x08")
    head.append(flags)
    head += struct.pack("<I", 0)  # MTIME
    head += bytes([2, 3])  # XFL (max compression), OS (Unix)
    if flags & 4:
        head += struct.pack("<H", len(extra)) + extra
    if flags & 8:
        head += name + b"\x00"
    if flags & 16:
        head += comment + b"\x00"
    if flags & 2:
        head += struct.pack("<H", zlib.crc32(head) & 0xFFFF)
    trailer = struct.pack("<II", zlib.crc32(data), len(data) & 0xFFFFFFFF)
    return bytes(head) + raw_deflate(data, level) + trailer


def big_text():
    """~360 KB of GH-Archive-like JSON lines: enough for many dynamic blocks
    and a CRC over more than one buffer's worth, small once compressed."""
    lines = []
    for i in range(3000):
        lines.append(
            b'{"id":"%d","type":"%s","actor":{"login":"user%d"},'
            b'"repo":{"name":"org%d/repo%d"},"payload":{"size":%d}}\n'
            % (
                10**10 + i * 7919,
                [b"PushEvent", b"WatchEvent", b"ForkEvent"][i % 3],
                (i * 31) % 997,
                i % 13,
                (i * 17) % 101,
                (i * i) % 50,
            )
        )
    return b"".join(lines)


def write(name, data):
    with open(os.path.join(HERE, name), "wb") as f:
        f.write(data)


def main():
    write("plain.gz", gzip.compress(TEXT, mtime=0))
    with open(os.path.join(HERE, "fname.gz"), "wb") as f:
        with gzip.GzipFile("hello.txt", "wb", fileobj=f, mtime=0) as g:
            g.write(TEXT)
    write("ftext.gz", member(TEXT, flags=1))
    write("fhcrc.gz", member(TEXT, flags=2))
    write("fextra.gz", member(TEXT, flags=4, extra=b"AB\x04\x00wxyz"))
    write("fcomment.gz", member(TEXT, flags=16, comment=b"a comment"))
    write(
        "allflags.gz",
        member(
            TEXT,
            flags=1 | 2 | 4 | 8 | 16,
            extra=b"AB\x02\x00hi",
            name=b"hello.txt",
            comment=b"every flag",
        ),
    )
    # Three members: stored (level 0), an empty one, and a compressed one;
    # decodes to TEXT twice.
    write(
        "multi.gz",
        gzip.compress(TEXT, compresslevel=0, mtime=0)
        + gzip.compress(b"", mtime=0)
        + gzip.compress(TEXT, compresslevel=9, mtime=0),
    )
    # Zero padding after the last member (tape-block style), which gzip(1)
    # and Python accept.
    write("padded.gz", gzip.compress(TEXT, mtime=0) + b"\x00" * 7)
    big = big_text()
    write("big.json.gz", gzip.compress(big, compresslevel=6, mtime=0))
    print("big.json.gz decodes to", len(big), "bytes, crc32", zlib.crc32(big))


if __name__ == "__main__":
    main()
