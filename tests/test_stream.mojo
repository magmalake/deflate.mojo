"""The streaming API — `Inflater` and `GzipReader` — run with `pixi run test`
(from the repository root, where the fixture paths are relative to).

Every test feeds the input in pieces (one byte at a time, random sizes, or
all at once), drains the window a little at a time, and compares what came
out with the one-shot `inflate` / `gunzip`. A piece that ends inside a block
makes the decoder roll the block back and decode it again later; a margin of
0 makes that happen for every block, so the rollback path is exercised on
small inputs too.
"""

from std.testing import TestSuite, assert_equal, assert_true

from deflate import (
    GzipReader,
    InflateStatus,
    Inflater,
    deflate,
    gunzip,
    gunzip_at,
    gzip,
    inflate,
    inflate_at,
)


comptime _DIR: StaticString = "tests/fixtures/"


# ── helpers ────────────────────────────────────────────────────────────────


def fixture(name: StringSlice) raises -> List[UInt8]:
    with open(String(_DIR, name), "r") as f:
        return f.read_bytes()


def assert_bytes_equal(
    got: Span[UInt8, _], want: Span[UInt8, _], name: StringSlice
) raises:
    assert_equal(len(got), len(want), String(name, ": length"))
    for i in range(len(want)):
        if got[i] != want[i]:
            raise Error(String(name, ": differs at byte ", i))


def _lines(n: Int, salt: Int) -> List[UInt8]:
    """JSON-ish lines: compressible, with matches near and far."""
    var s = String()
    for i in range(n):
        s += String(
            '{"id":"', i * 7 + salt, '","type":"PushEvent","payload":{"n":',
            (i * 31 + salt) % 977, ',"msg":"line \\"', i, '\\" of many"}}\n',
        )
    return List[UInt8](s.as_bytes())


struct _Sizes(Movable):
    """Piece sizes: a fixed step, or pseudo-random in [1, step] (an LCG, so
    a failure reproduces)."""

    var step: Int
    var random: Bool
    var state: UInt64

    def __init__(out self, step: Int, random: Bool = False, seed: Int = 1):
        self.step = step
        self.random = random
        self.state = UInt64(seed) * 0x9E3779B97F4A7C15 + 1

    def next(mut self) -> Int:
        if not self.random:
            return self.step
        self.state = self.state * 6364136223846793005 + 1442695040888963407
        return 1 + Int((self.state >> 33) % UInt64(self.step))


struct _Run(Movable):
    var out: List[UInt8]
    var max_input_held: Int
    var calls: Int

    def __init__(out self):
        self.out = List[UInt8]()
        self.max_input_held = 0
        self.calls = 0


def _stream_gzip(
    data: List[UInt8],
    var sizes: _Sizes,
    window: Int,
    margin: Int = -1,
    discard: Bool = False,
    multi_member: Bool = True,
) raises -> _Run:
    """Run `data` through a `GzipReader`, `sizes` more bytes arriving each
    time it asks for input, taking `window` bytes of output per call. With
    `discard`, the input the reader is done with is dropped as it goes, so
    only a bounded tail of `data` is ever held."""
    var r = GzipReader(window, multi_member=multi_member)
    if margin >= 0:
        r.inflater.margin = margin
    var result = _Run()
    var held = List[UInt8]()  # data[gone : arrived]
    var gone = 0
    var arrived = 0
    var lo = 0
    while True:
        var complete = arrived == len(data)
        var st = r.run(Span(held), complete, lo + window)
        result.calls += 1
        var o = r.output()
        for k in range(lo, len(o)):
            result.out.append(o[k])
        lo = len(o)
        lo -= r.compact(lo)
        if st == InflateStatus.FINISHED:
            break
        if st == InflateStatus.NEED_INPUT:
            assert_true(not complete, "NEED_INPUT with all the input")
            if discard:
                var k = r.discard_input()
                var rest = List[UInt8](capacity=len(held) - k + sizes.step)
                rest.extend(Span(held)[k:])
                held = rest^
                gone += k
            var take = min(sizes.next(), len(data) - arrived)
            held.extend(Span(data)[arrived : arrived + take])
            arrived += take
            result.max_input_held = max(result.max_input_held, len(held))
    return result^


def _stream_raw(
    data: List[UInt8], var sizes: _Sizes, window: Int, margin: Int = -1
) raises -> List[UInt8]:
    """`_stream_gzip` for a raw DEFLATE stream through an `Inflater`."""
    var inf = Inflater(window)
    if margin >= 0:
        inf.margin = margin
    var out = List[UInt8]()
    var have = 0
    var lo = 0
    while True:
        var complete = have == len(data)
        var st = inf.run(Span(data)[:have], complete, lo + window)
        var o = inf.output()
        for k in range(lo, len(o)):
            out.append(o[k])
        lo = len(o)
        lo -= inf.compact(lo)
        if st == InflateStatus.FINISHED:
            var end = 0
            _ = inflate_at(Span(data), end)
            assert_equal(inf.input_used(), end, "input_used is the stream end")
            break
        if st == InflateStatus.NEED_INPUT:
            assert_true(not complete, "NEED_INPUT with all the input")
            have = min(have + sizes.next(), len(data))
    return out^


def _mixed_gzip() raises -> List[UInt8]:
    """A multi-member file: zlib's dynamic blocks (big.json.gz), a stored
    member, an empty one, and this library's own fixed-block member."""
    var gz = fixture("big.json.gz")
    gz.extend(Span(gzip(Span(_lines(900, 2)), level=0)))
    gz.extend(Span(gzip(Span(List[UInt8]()))))
    gz.extend(Span(gzip(Span(_lines(1500, 1)))))
    gz.extend(Span(fixture("multi.gz")))
    return gz^


def _raises_gzip(
    data: List[UInt8], var sizes: _Sizes, needle: StringSlice, name: StringSlice
) raises:
    var message = String()
    try:
        _ = _stream_gzip(data, sizes^, 1 << 16)
    except e:
        message = String(e)
    assert_true(message.byte_length() > 0, String(name, ": did not raise"))
    assert_true(
        needle in message,
        String(name, ": expected '", needle, "' in: ", message),
    )


# ── output matches the one-shot functions ──────────────────────────────────


def test_gzip_whole_input() raises:
    var gz = _mixed_gzip()
    var want = gunzip(Span(gz))
    for window in [1 << 15, 100_000, 1 << 24]:
        var got = _stream_gzip(gz, _Sizes(len(gz)), window)
        assert_bytes_equal(Span(got.out), Span(want), String("window ", window))


def test_gzip_random_pieces() raises:
    var gz = _mixed_gzip()
    var want = gunzip(Span(gz))
    for seed in range(1, 4):
        for step in [7, 600, 9000]:
            for margin in [-1, 0]:
                var name = String("seed ", seed, " step ", step, " margin ", margin)
                var got = _stream_gzip(
                    gz, _Sizes(step, random=True, seed=seed), 40_000, margin
                )
                assert_bytes_equal(Span(got.out), Span(want), name)


def test_gzip_one_byte_at_a_time() raises:
    """Every byte arriving on its own, with every block rolled back each time
    it runs short (margin 0), and with the default margin."""
    var small = List[UInt8]()
    for name in ["allflags.gz", "fhcrc.gz", "multi.gz"]:
        small.extend(Span(fixture(name)))
    small.extend(Span(gzip(Span(_lines(60, 3)))))
    small.extend(Span(gzip(Span(_lines(40, 4)), level=0)))
    small.extend(Span(fixture("padded.gz")))  # zero padding: last
    var want = gunzip(Span(small))
    for margin in [-1, 0]:
        var got = _stream_gzip(small, _Sizes(1), 1 << 12, margin)
        assert_bytes_equal(Span(got.out), Span(want), String("margin ", margin))
    # A zlib file with several dynamic blocks, one byte at a time.
    var big = fixture("big.json.gz")
    var got = _stream_gzip(big, _Sizes(1), 1 << 16)
    assert_bytes_equal(Span(got.out), Span(gunzip(Span(big))), "big")


def test_gzip_tiny_window() raises:
    """A window barely larger than 32 KiB, so back-references keep reaching
    into bytes that compaction just moved."""
    var gz = _mixed_gzip()
    var got = _stream_gzip(gz, _Sizes(4096, random=True, seed=9), 1)
    assert_bytes_equal(Span(got.out), Span(gunzip(Span(gz))), "window 1")


def test_raw_inflater_matches_inflate() raises:
    var streams = List[List[UInt8]]()
    streams.append(deflate(Span(_lines(2000, 5))))
    var big = fixture("big.json.gz")
    # big.json.gz has a bare 10-byte header: the raw stream follows it.
    streams.append(List[UInt8](Span(big)[10 : len(big) - 8]))
    streams.append(deflate(Span(List[UInt8]())))
    for i in range(len(streams)):
        var want = inflate(Span(streams[i]))
        for step in [1, 13, 5000, len(streams[i]) + 1]:
            for margin in [-1, 0]:
                if step == 1 and i == 0 and margin == 0:
                    continue  # one fixed block: quadratic, and covered below
                var name = String("stream ", i, " step ", step, " margin ", margin)
                var got = _stream_raw(
                    streams[i], _Sizes(step, random=step > 1), 40_000, margin
                )
                assert_bytes_equal(Span(got), Span(want), name)


def test_raw_stream_followed_by_other_bytes() raises:
    """After the final block the inflater stops, wherever the input goes on,
    and says where the stream ended."""
    var z = deflate(Span(_lines(50, 6)))
    var n = len(z)
    var again = z.copy()
    z.extend(Span(again))
    var inf = Inflater()
    var st = inf.run(Span(z), complete=True)
    assert_true(st == InflateStatus.FINISHED, "finished")
    assert_equal(inf.input_used(), n, "end of the first stream")
    assert_bytes_equal(inf.output(), Span(_lines(50, 6)), "first stream")


def test_single_member_reader_is_gunzip_at() raises:
    var gz = _mixed_gzip()
    var end = 0
    var want = gunzip_at(Span(gz), end)
    var r = GzipReader(multi_member=False)
    var st = r.run(Span(gz), complete=True)
    assert_true(st == InflateStatus.FINISHED, "finished")
    assert_equal(r.members(), 1, "one member")
    assert_equal(r.input_used(), end, "end of the member")
    assert_bytes_equal(r.output(), Span(want), "first member")
    # Streamed in pieces, the rest of the file is never looked at.
    var got = _stream_gzip(gz, _Sizes(333, random=True), 1 << 16, multi_member=False)
    assert_bytes_equal(Span(got.out), Span(want), "streamed")


def test_discarded_input_stays_bounded() raises:
    """Dropping consumed input as it goes, the input held stays near the
    margin plus one piece however long the file is."""
    var gz = List[UInt8]()
    var big = fixture("big.json.gz")
    for _k in range(40):
        gz.extend(Span(big))
    var want = gunzip(Span(gz))
    var got = _stream_gzip(gz, _Sizes(20_000), 1 << 16, discard=True)
    assert_bytes_equal(Span(got.out), Span(want), "discarding")
    assert_true(
        got.max_input_held < (1 << 18) + 60_000,
        String("held ", got.max_input_held, " of ", len(gz)),
    )
    var small_margin = _stream_gzip(
        gz, _Sizes(997, random=True), 1 << 16, margin=0, discard=True
    )
    assert_bytes_equal(Span(small_margin.out), Span(want), "margin 0")
    assert_true(small_margin.max_input_held < len(big), "held less than a member")


def test_status_and_counters() raises:
    var data = _lines(3000, 7)
    var gz = gzip(Span(data))
    var r = GzipReader(1 << 15)
    var st = r.run(Span(gz)[:5], complete=False)
    assert_true(st == InflateStatus.NEED_INPUT, "header not there yet")
    st = r.run(Span(gz), complete=True, want=1000)
    assert_true(st == InflateStatus.OUTPUT, "stopped at want")
    st = r.run(Span(gz), complete=True)
    assert_true(st == InflateStatus.FINISHED, "finished")
    assert_true(r.finished(), "finished()")
    assert_equal(r.total_out(), len(data), "total_out")
    assert_equal(r.total_in(), len(gz), "total_in")
    assert_equal(String(InflateStatus.NEED_INPUT), "NEED_INPUT")


# ── corrupt and truncated input ────────────────────────────────────────────


def test_streamed_corruption_raises() raises:
    var gz = fixture("plain.gz")
    gz[len(gz) - 8] ^= 0x01
    _raises_gzip(gz, _Sizes(1), "CRC-32 mismatch", "crc")
    gz = fixture("plain.gz")
    gz[len(gz) - 4] ^= 0x01
    _raises_gzip(gz, _Sizes(3), "ISIZE mismatch", "isize")
    gz = fixture("fhcrc.gz")
    gz[11] ^= 0x01
    _raises_gzip(gz, _Sizes(1), "FHCRC", "fhcrc")
    gz = fixture("plain.gz")
    gz[1] = 0x8C
    _raises_gzip(gz, _Sizes(1), "bad magic", "magic")
    gz = fixture("multi.gz")
    gz[len(gz) - 12] ^= 0x10
    _raises_gzip(gz, _Sizes(2), "member 2", "second member")
    gz = fixture("plain.gz")
    gz.append(0)
    gz.append(0x41)
    _raises_gzip(gz, _Sizes(1), "trailing garbage", "garbage")
    _raises_gzip(List[UInt8](), _Sizes(1), "empty input", "empty")


def test_corrupt_body_raises_before_input_ends() raises:
    """A bad block is reported as soon as it is decoded with input to spare,
    not mistaken for a block still waiting for its bytes."""
    var gz = fixture("big.json.gz")
    for _k in range(10):
        gz.extend(Span(fixture("big.json.gz")))
    gz[2000] ^= 0xFF
    var r = GzipReader()
    r.inflater.margin = 0
    var raised = False
    var have = 0
    try:
        while have < len(gz):
            have = min(have + 50_000, len(gz))
            _ = r.run(Span(gz)[:have], complete=False)
    except:
        raised = True
    assert_true(raised, "corruption raised")
    assert_true(have < len(gz), String("raised only at the end: ", have))


def test_truncated_streams() raises:
    """Every proper prefix, streamed and then declared complete, raises; and
    streamed without being declared complete never reports FINISHED."""
    for name in ["allflags.gz", "plain.gz", "fhcrc.gz"]:
        var data = fixture(name)
        for cut in range(len(data)):
            var prefix = List[UInt8](Span(data)[:cut])
            var raised = False
            try:
                _ = _stream_gzip(prefix, _Sizes(1), 1 << 12, margin=0)
            except:
                raised = True
            assert_true(raised, String(name, ": prefix ", cut, " decoded"))
            var r = GzipReader()
            r.inflater.margin = 0
            var st = r.run(Span(prefix), complete=False)
            assert_true(
                st == InflateStatus.NEED_INPUT,
                String(name, ": prefix ", cut, ": ", st),
            )
    var big = fixture("big.json.gz")
    for cut in [10, 100, 4096, len(big) // 2, len(big) - 9, len(big) - 1]:
        var raised = False
        try:
            _ = _stream_gzip(
                List[UInt8](Span(big)[:cut]), _Sizes(777, random=True), 1 << 15
            )
        except:
            raised = True
        assert_true(raised, String("big: prefix ", cut, " decoded"))
    var z = deflate(Span(_lines(100, 8)))
    for cut in [0, 1, len(z) // 2, len(z) - 1]:
        var raised = False
        try:
            _ = _stream_raw(List[UInt8](Span(z)[:cut]), _Sizes(5), 1 << 15)
        except:
            raised = True
        assert_true(raised, String("raw: prefix ", cut, " decoded"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
