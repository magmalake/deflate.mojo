"""The deflate.mojo test suite — run with `pixi run test`.

Two kinds of test. The round trips check that `deflate` and `inflate` agree
with each other; the fixtures check that `inflate` agrees with *zlib*, which
is the one that matters — a decoder that only reads its own encoder's output
is a decoder that has never met RFC 1951. The fixture bytes were produced by
Python's `zlib.compressobj(..., wbits=-15)`, one per block type.
"""

from std.testing import TestSuite, assert_equal, assert_true

from deflate import deflate, inflate, inflate_at


# ── helpers ────────────────────────────────────────────────────────────────


def bytes_of(text: StringSlice) -> List[UInt8]:
    var out = List[UInt8]()
    for b in text.as_bytes():
        out.append(b)
    return out^


def parse_bytes(text: StringSlice) raises -> List[UInt8]:
    """Decode a comma-separated byte list — how the zlib fixtures are spelled."""
    var out = List[UInt8]()
    for part in text.split(","):
        out.append(UInt8(Int(String(part.strip()))))
    return out^


def assert_bytes_equal(
    got: Span[UInt8, _], want: Span[UInt8, _], name: StringSlice
) raises:
    assert_equal(len(got), len(want), String(name, ": length"))
    for i in range(len(want)):
        if got[i] != want[i]:
            raise Error(String(name, ": differs at byte ", i))


# ── fixtures: raw DEFLATE produced by zlib, one per block type ─────────────

# BTYPE=0, stored. zlib level 0 over the bytes 1..8.
comptime _STORED_Z: StaticString = "1, 8, 0, 247, 255, 1, 2, 3, 4, 5, 6, 7, 8"

# BTYPE=1, fixed Huffman. zlib level 9 over "hello".
comptime _FIXED_Z: StaticString = "203, 72, 205, 201, 201, 7, 0"
comptime _FIXED_TEXT: StaticString = "hello"

# BTYPE=2, dynamic Huffman. zlib level 9 over the 60 bytes below — a skewed
# alphabet with no long repeats, which is what makes dynamic beat fixed.
comptime _DYNAMIC_Z: StaticString = (
    "29, 200, 193, 13, 0, 32, 12, 195, 192, 85, 178, 154, 19, 74, 217, 127,"
    " 2, 10, 31, 75, 103, 147, 134, 194, 98, 1, 201, 164, 130, 160, 91, 72,"
    " 223, 56, 19, 185, 14, 179, 26, 63, 177, 47"
)
comptime _DYNAMIC_TEXT: StaticString = (
    "bacgaaeab adaaaccaaaeca aagg a  caaaeabcaea behaa  gabaea af"
)


# ── reading what zlib wrote ────────────────────────────────────────────────


def test_inflate_stored_block() raises:
    var want = List[UInt8]()
    for i in range(1, 9):
        want.append(UInt8(i))
    var got = inflate(Span(parse_bytes(_STORED_Z)))
    assert_bytes_equal(Span(got), Span(want), "stored")


def test_inflate_fixed_huffman_block() raises:
    var got = inflate(Span(parse_bytes(_FIXED_Z)))
    assert_bytes_equal(Span(got), Span(bytes_of(_FIXED_TEXT)), "fixed")


def test_inflate_dynamic_huffman_block() raises:
    var got = inflate(Span(parse_bytes(_DYNAMIC_Z)))
    assert_bytes_equal(Span(got), Span(bytes_of(_DYNAMIC_TEXT)), "dynamic")


# ── round trips ────────────────────────────────────────────────────────────


def test_deflate_round_trip() raises:
    var src = List[UInt8]()
    for i in range(50000):
        src.append(UInt8((i * 7 + i // 97) % 251))
    for i in range(20000):
        src.append(UInt8(65 + i % 5))
    var z = deflate(Span(src))
    assert_true(len(z) < len(src) // 2)
    var back = inflate(Span(z))
    assert_bytes_equal(Span(back), Span(src), "round trip")


def test_deflate_edge_cases() raises:
    var empty = List[UInt8]()
    assert_equal(len(inflate(Span(deflate(Span(empty))))), 0)
    var one = bytes_of("a")
    assert_equal(len(inflate(Span(deflate(Span(one))))), 1)
    var run = List[UInt8](length=1000, fill=7)
    var back = inflate(Span(deflate(Span(run))))
    assert_equal(len(back), 1000)
    assert_equal(back[999], UInt8(7))


def test_deflate_output_reads_in_zlib_terms() raises:
    """Our encoder's blocks decode through the same path as zlib's."""
    var src = bytes_of("the quick brown fox jumps over the lazy dog. " * 8)
    var z = deflate(Span(src))
    assert_true(len(z) < len(src))
    var end = 0
    var back = inflate_at(Span(z), end)
    assert_bytes_equal(Span(back), Span(src), "self round trip")
    assert_equal(end, len(z), "encoder leaves no trailing bytes")


# ── inflate_at: several streams back to back ───────────────────────────────


def test_inflate_at_reports_the_end_of_one_stream() raises:
    var z = parse_bytes(_FIXED_Z)
    var end = 0
    var got = inflate_at(Span(z), end)
    assert_bytes_equal(Span(got), Span(bytes_of(_FIXED_TEXT)), "first")
    assert_equal(end, len(z), "end is past the whole stream")


def test_inflate_at_walks_concatenated_members() raises:
    """Concatenated gzip members are what Parquet's GZIP pages look like."""
    var one = parse_bytes(_FIXED_Z)
    var joined = List[UInt8]()
    joined.extend(Span(one))
    joined.extend(Span(one))
    joined.extend(Span(one))

    var want = bytes_of(_FIXED_TEXT)
    var pos = 0
    for member in range(3):
        var end = 0
        var got = inflate_at(Span(joined)[pos:], end)
        assert_bytes_equal(Span(got), Span(want), String("member ", member))
        assert_equal(end, len(one), String("member ", member, ": end"))
        pos += end
    assert_equal(pos, len(joined), "walked the whole buffer")


# ── malformed input raises rather than reading past the end ────────────────


def test_truncated_stream_raises() raises:
    var z = parse_bytes(_DYNAMIC_Z)
    var cut = List[UInt8]()
    for i in range(len(z) // 2):
        cut.append(z[i])
    var raised = False
    try:
        _ = inflate(Span(cut))
    except:
        raised = True
    assert_true(raised, "truncated stream should raise")


def test_garbage_block_type_raises() raises:
    # BTYPE=3 is reserved; 0b111 in the low three bits is BFINAL=1, BTYPE=3.
    var bad = List[UInt8](length=8, fill=0xFF)
    var raised = False
    try:
        _ = inflate(Span(bad))
    except:
        raised = True
    assert_true(raised, "reserved block type should raise")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
