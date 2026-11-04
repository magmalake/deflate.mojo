"""The gzip tests — run with `pixi run test` (from the repository root, which is
where the fixture paths are relative to).

The fixtures in tests/fixtures/ were written by Python's `gzip` and `zlib`
(tests/fixtures/make_gzip_fixtures.py regenerates them), so these check
`gunzip` against the reference implementation, header flag by header flag.
Corrupted and truncated copies are made here from those files.
"""

from std.testing import TestSuite, assert_equal, assert_true

from deflate import gunzip, gunzip_at, gzip
from deflate.gzip import _Crc32, crc32_backend


comptime _TEXT: StaticString = "hello, gzip\nhello, gzip\nhello, gzip\n"
"""What every small fixture decodes to."""

comptime _DIR: StaticString = "tests/fixtures/"


# ── helpers ────────────────────────────────────────────────────────────────


def fixture(name: StringSlice) raises -> List[UInt8]:
    with open(String(_DIR, name), "r") as f:
        return f.read_bytes()


def bytes_of(text: StringSlice) -> List[UInt8]:
    var out = List[UInt8]()
    for b in text.as_bytes():
        out.append(b)
    return out^


def assert_bytes_equal(
    got: Span[UInt8, _], want: Span[UInt8, _], name: StringSlice
) raises:
    assert_equal(len(got), len(want), String(name, ": length"))
    for i in range(len(want)):
        if got[i] != want[i]:
            raise Error(String(name, ": differs at byte ", i))


def assert_gunzip_raises(
    data: Span[UInt8, _], needle: StringSlice, name: StringSlice
) raises:
    """`gunzip(data)` raises, and the message names the problem."""
    var message = String()
    try:
        _ = gunzip(data)
    except e:
        message = String(e)
    assert_true(message.byte_length() > 0, String(name, ": did not raise"))
    assert_true(
        needle in message,
        String(name, ": expected '", needle, "' in: ", message),
    )


def text_fixture(name: StringSlice) raises:
    var got = gunzip(Span(fixture(name)))
    assert_bytes_equal(Span(got), Span(bytes_of(_TEXT)), name)


# ── CRC-32 ─────────────────────────────────────────────────────────────────


def test_crc32_check_values() raises:
    """The CRC catalogue's check value, and zlib.crc32 of a longer input,
    through both paths (on x86 they are the same path)."""
    print("    crc32 backend:", crc32_backend())
    var c = _Crc32()
    var check = bytes_of("123456789")
    assert_equal(c.update(0, Span(check)), UInt32(0xCBF43926))
    assert_equal(c.table_update(0, Span(check)), UInt32(0xCBF43926))
    var text = bytes_of(_TEXT)
    var want = UInt32(0x11072126)  # zlib.crc32(b"hello, gzip\n" * 3)
    assert_equal(c.update(0, Span(text)), want)
    assert_equal(c.table_update(0, Span(text)), want)
    # Chained over a split, for every split point and odd lengths.
    for cut in range(len(text)):
        var first = c.update(0, Span(text)[:cut])
        assert_equal(c.update(first, Span(text)[cut:]), want)
    assert_equal(c.update(0, Span(List[UInt8]())), UInt32(0))


# ── reading what Python wrote: one fixture per header flag ─────────────────


def test_plain() raises:
    text_fixture("plain.gz")


def test_fname() raises:
    text_fixture("fname.gz")


def test_ftext() raises:
    text_fixture("ftext.gz")


def test_fhcrc() raises:
    text_fixture("fhcrc.gz")


def test_fextra() raises:
    text_fixture("fextra.gz")


def test_fcomment() raises:
    text_fixture("fcomment.gz")


def test_all_flags() raises:
    text_fixture("allflags.gz")


def test_big_json() raises:
    """~360 KB over many dynamic blocks; the CRC-32 check inside `gunzip`
    is what says the bytes are Python's."""
    var got = gunzip(Span(fixture("big.json.gz")))
    assert_equal(len(got), 360304)
    assert_equal(got[0], UInt8(ord("{")))
    assert_equal(got[len(got) - 1], UInt8(ord("\n")))


# ── several members, padding, and walking members one at a time ────────────


def test_multi_member() raises:
    """Stored, empty and compressed members, back to back."""
    var got = gunzip(Span(fixture("multi.gz")))
    var want = bytes_of(_TEXT)
    want.extend(Span(bytes_of(_TEXT)))
    assert_bytes_equal(Span(got), Span(want), "multi")


def test_zero_padding_after_last_member() raises:
    text_fixture("padded.gz")


def test_gunzip_at_walks_members() raises:
    var data = fixture("multi.gz")
    var sizes = List[Int]()
    var pos = 0
    while pos < len(data):
        var end = 0
        var part = gunzip_at(Span(data)[pos:], end)
        sizes.append(len(part))
        pos += end
    assert_equal(pos, len(data))
    assert_equal(len(sizes), 3)
    assert_equal(sizes[0], _TEXT.byte_length())
    assert_equal(sizes[1], 0)
    assert_equal(sizes[2], _TEXT.byte_length())


# ── gzip: round trips ──────────────────────────────────────────────────────


def test_gzip_round_trip_every_level() raises:
    var src = List[UInt8]()
    for i in range(60000):
        src.append(UInt8((i * 7 + i // 97) % 251))
    for i in range(20000):
        src.append(UInt8(65 + i % 5))
    for level in [0, 1, 6, 9]:
        var z = gzip(Span(src), level)
        if level > 0:
            assert_true(len(z) < len(src))
        var back = gunzip(Span(z))
        assert_bytes_equal(Span(back), Span(src), String("level ", level))


def test_gzip_edge_cases() raises:
    var empty = List[UInt8]()
    for level in [0, 6]:
        var z = gzip(Span(empty), level)
        assert_equal(len(gunzip(Span(z))), 0)
    var back = gunzip(Span(gzip(Span(bytes_of(_TEXT)))))
    assert_bytes_equal(Span(back), Span(bytes_of(_TEXT)), "text")
    var raised = False
    try:
        _ = gzip(Span(empty), 10)
    except:
        raised = True
    assert_true(raised, "level 10 should raise")


def test_gzip_header_is_minimal() raises:
    var z = gzip(Span(bytes_of(_TEXT)), 9)
    assert_equal(z[0], UInt8(0x1F))
    assert_equal(z[1], UInt8(0x8B))
    assert_equal(z[2], UInt8(8))
    assert_equal(z[3], UInt8(0), "no flags")
    assert_equal(z[8], UInt8(2), "XFL for level 9")


def test_gzip_members_concatenate() raises:
    var a = gzip(Span(bytes_of("first ")))
    a.extend(Span(gzip(Span(bytes_of("second")), 0)))
    var back = gunzip(Span(a))
    assert_bytes_equal(Span(back), Span(bytes_of("first second")), "joined")


# ── corrupt and truncated input ────────────────────────────────────────────


def test_corrupt_crc() raises:
    var data = fixture("plain.gz")
    data[len(data) - 8] ^= 0x01
    assert_gunzip_raises(Span(data), "CRC-32 mismatch", "crc")


def test_corrupt_isize() raises:
    var data = fixture("plain.gz")
    data[len(data) - 4] ^= 0x01
    assert_gunzip_raises(Span(data), "ISIZE mismatch", "isize")


def test_corrupt_header_crc() raises:
    var data = fixture("fhcrc.gz")
    data[11] ^= 0x01  # the FHCRC field itself
    assert_gunzip_raises(Span(data), "FHCRC", "fhcrc")


def test_corrupt_body_in_second_member() raises:
    var data = fixture("multi.gz")
    data[len(data) - 12] ^= 0x10
    var message = String()
    try:
        _ = gunzip(Span(data))
    except e:
        message = String(e)
    assert_true("member 2" in message, message)


def test_bad_magic_method_and_flags() raises:
    var data = fixture("plain.gz")
    data[1] = 0x8C
    assert_gunzip_raises(Span(data), "bad magic", "magic")
    data = fixture("plain.gz")
    data[2] = 7
    assert_gunzip_raises(Span(data), "compression method", "method")
    data = fixture("plain.gz")
    data[3] = 0x20
    assert_gunzip_raises(Span(data), "reserved flag", "flags")


def test_empty_input_and_trailing_garbage() raises:
    assert_gunzip_raises(Span(List[UInt8]()), "empty input", "empty")
    var data = fixture("plain.gz")
    data.append(0)
    data.append(0x41)
    assert_gunzip_raises(Span(data), "trailing garbage", "garbage")


def test_every_truncation_raises() raises:
    """Every proper prefix of a member is an error, never a short result.

    A multi-member file cut exactly between members is a shorter valid
    file, so these are one-member fixtures.
    """
    for name in ["allflags.gz", "fname.gz", "plain.gz"]:
        var data = fixture(name)
        for cut in range(len(data)):
            var raised = False
            try:
                _ = gunzip(Span(data)[:cut])
            except:
                raised = True
            assert_true(raised, String(name, ": prefix ", cut, " decoded"))
    var big = fixture("big.json.gz")
    for cut in [10, 11, 100, 4096, len(big) // 2, len(big) - 9, len(big) - 1]:
        var raised = False
        try:
            _ = gunzip(Span(big)[:cut])
        except:
            raised = True
        assert_true(raised, String("big: prefix ", cut, " decoded"))


def test_truncated_messages() raises:
    var data = fixture("plain.gz")
    assert_gunzip_raises(Span(data)[:5], "truncated header", "header")
    assert_gunzip_raises(Span(data)[: len(data) - 3], "truncated trailer", "trailer")
    var named = fixture("allflags.gz")
    assert_gunzip_raises(Span(named)[:20], "truncated header", "fields")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
