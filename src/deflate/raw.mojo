"""Raw DEFLATE (RFC 1951) — `inflate` and `deflate`, in pure Mojo.

*Raw* DEFLATE is the compressed stream on its own: no zlib (RFC 1950) header,
no gzip (RFC 1952) wrapper, no trailing checksum. A caller that needs one of
those framings parses it itself and hands the body here — Avro's `deflate`
block codec is raw already, and Parquet's `GZIP` codec is this plus a gzip
header and trailer.

Implementing it rather than binding zlib keeps the tin free of FFI and of any
sibling dependency, so a consumer needs nothing but `-I ../deflate.mojo/src`.

`inflate` handles all three block types (stored, fixed-Huffman,
dynamic-Huffman). `deflate` emits fixed-Huffman blocks from a single-slot
hash-chain LZ77 matcher — the same "fast" strategy `snappy.mojo` uses —
which keeps the encoder small.
"""

# ── length / distance tables (RFC 1951 §3.2.5) ─────────────────────────────

from std.memory import unsafe_memcpy

comptime _LEN_BASE_S: StaticString = (
    "3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,"
    "163,195,227,258"
)
comptime _LEN_EXTRA_S: StaticString = (
    "0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0"
)
comptime _DIST_BASE_S: StaticString = (
    "1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,"
    "2049,3073,4097,6145,8193,12289,16385,24577"
)
comptime _DIST_EXTRA_S: StaticString = (
    "0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13"
)
comptime _CLEN_ORDER_S: StaticString = (
    "16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15"
)


def _ints(text: StringSlice) raises -> List[Int]:
    var out = List[Int]()
    for part in text.split(","):
        out.append(Int(String(part)))
    return out^


@fieldwise_init
struct _Tables(Copyable, Movable):
    """RFC 1951\'s length and distance tables.

    Mojo cannot materialise a `comptime List[Int]` into runtime code, so the
    tables are rebuilt once per `inflate`/`deflate` call and passed down by
    reference: from the rule that generates them, which is cheaper than
    parsing their text (`_LEN_BASE_S` and friends, which `test_deflate`
    checks them against)."""

    var len_base: List[Int]
    var len_extra: List[Int]
    var dist_base: List[Int]
    var dist_extra: List[Int]
    var clen_order: List[Int]

    def __init__(out self):
        # Lengths: codes 257..284 carry (i - 4) / 4 extra bits from the
        # ninth on, each base the previous plus its span; 285 is 258 flat.
        self.len_base = List[Int](capacity=29)
        self.len_extra = List[Int](capacity=29)
        var b = 3
        for i in range(28):
            var x = 0 if i < 8 else (i - 4) >> 2
            self.len_base.append(b)
            self.len_extra.append(x)
            b += 1 << x
        self.len_base.append(258)
        self.len_extra.append(0)
        # Distances: (i - 2) / 2 extra bits from the fifth code on.
        self.dist_base = List[Int](capacity=30)
        self.dist_extra = List[Int](capacity=30)
        b = 1
        for i in range(30):
            var x = 0 if i < 4 else (i - 2) >> 1
            self.dist_base.append(b)
            self.dist_extra.append(x)
            b += 1 << x
        self.clen_order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]


# ── canonical Huffman decoding ─────────────────────────────────────────────

comptime _FAST_BITS: Int = 10
"""Width of the direct-lookup table. Ten bits covers nearly every code a
real compressor emits (zlib's literal codes for text are 5 to 10 bits) in a
1024-entry table, small enough to rebuild per block and to stay in L1; the
rest are walked a bit at a time."""
comptime _FAST_SIZE: Int = 1 << _FAST_BITS


comptime _E_LIT: UInt32 = 0
comptime _E_LEN: UInt32 = 1 << 12
"""A length (or, in a distance table, a distance): `value` is its base."""
comptime _E_EOB: UInt32 = 2 << 12
comptime _E_SLOW: UInt32 = 3 << 12
"""A code longer than the table, or a symbol that is not valid there."""
comptime _E_KIND: UInt32 = 3 << 12


@always_inline
def _entry(kind: UInt32, value: Int, codelen: Int, extra: Int) -> UInt32:
    """A fast-loop table entry: `value << 16 | kind | codelen << 8 | total`,
    where total = code length + extra bits, the bits the symbol consumes.
    The value with its extra bits is then
    `value + ((bitbuf & ((1 << total) - 1)) >> codelen)`, as in libdeflate."""
    return (
        (UInt32(value) << 16)
        | kind
        | (UInt32(codelen) << 8)
        | UInt32(codelen + extra)
    )


def _reverse_bits(value: Int, count: Int) -> Int:
    """DEFLATE writes Huffman codes most-significant bit first but reads the
    stream least-significant bit first, so a table indexed by the next bits
    of the stream wants the code reversed."""
    var v = 0
    for k in range(count):
        v |= ((value >> (count - 1 - k)) & 1) << k
    return v


struct _Huffman(Copyable, Defaultable, Movable):
    var counts: List[Int]
    """counts[n] = how many symbols have a code of n bits (n = 0..15)."""
    var symbols: List[Int]
    """Symbols ordered by code length, then by symbol value."""
    var fast: List[Int32]
    """`(length << 16) | symbol` for every code of at most `_FAST_BITS` bits,
    indexed by the next `_FAST_BITS` bits of the stream; -1 where the code is
    longer (or absent) and the bit-at-a-time walk has to finish the job."""
    var offs: List[Int]
    """Scratch for `build`."""
    var ent: List[UInt32]
    """`fast` decoded further, for the fast loop (`_codes`): what a symbol
    means, with its extra bits folded in. See `_E_*`."""

    def __init__(out self):
        """An empty code; `build` allocates its tables the first time."""
        self.counts = List[Int]()
        self.symbols = List[Int]()
        self.fast = List[Int32]()
        self.offs = List[Int]()
        self.ent = List[UInt32]()

    def entries(mut self, litlen: Bool, t: _Tables):
        """Fill `ent` from `fast`: literal/length meanings when `litlen`,
        distance ones otherwise."""
        var f = self.fast.unsafe_ptr()
        var en = self.ent.unsafe_ptr()
        var lb = t.len_base.unsafe_ptr()
        var lx = t.len_extra.unsafe_ptr()
        var db = t.dist_base.unsafe_ptr()
        var dx = t.dist_extra.unsafe_ptr()
        for k in range(_FAST_SIZE):
            var e = Int(f[unsafe_offset=k])
            var v = _E_SLOW
            if e >= 0:
                var n = e >> 16
                var sym = e & 0xFFFF
                if litlen:
                    if sym < 256:
                        v = _entry(_E_LIT, sym, n, 0)
                    elif sym == 256:
                        v = _entry(_E_EOB, 0, n, 0)
                    elif sym < 286:
                        v = _entry(
                            _E_LEN,
                            lb[unsafe_offset=sym - 257],
                            n,
                            lx[unsafe_offset=sym - 257],
                        )
                elif sym < 30:
                    v = _entry(
                        _E_LEN, db[unsafe_offset=sym], n, dx[unsafe_offset=sym]
                    )
            en[unsafe_offset=k] = v

    def __init__(out self, lengths: List[Int]) raises:
        self = Self()
        self.build(lengths, 0, len(lengths))

    def build(mut self, lengths: List[Int], start: Int, count: Int) raises:
        """The code for `lengths[start : start + count]`, in place, so a
        dynamic block rebuilds its three tables without allocating."""
        if len(self.fast) == 0:
            self.counts = List[Int](length=16, fill=0)
            self.offs = List[Int](length=16, fill=0)
            self.fast = List[Int32](length=_FAST_SIZE, fill=-1)
            self.ent = List[UInt32](length=_FAST_SIZE, fill=_E_SLOW)
        var c = self.counts.unsafe_ptr()
        for n in range(16):
            c[unsafe_offset=n] = 0
        for i in range(count):
            var l = lengths[start + i]
            if l < 0 or l > 15:
                raise Error("inflate: bad code length")
            c[unsafe_offset=l] += 1
        var f = self.fast.unsafe_ptr()
        for k in range(_FAST_SIZE):
            f[unsafe_offset=k] = -1
        if c[unsafe_offset=0] == count:
            # An all-zero table is legal (an unused distance tree); any
            # symbol read from it is an invalid code.
            self.symbols.resize(0, 0)
            return
        var left = 1
        for n in range(1, 16):
            left <<= 1
            left -= c[unsafe_offset=n]
            if left < 0:
                raise Error("inflate: over-subscribed Huffman code")
        var o = self.offs.unsafe_ptr()
        o[unsafe_offset=1] = 0
        for n in range(1, 15):
            o[unsafe_offset=n + 1] = o[unsafe_offset=n] + c[unsafe_offset=n]
        self.symbols.resize(count, 0)
        var sy = self.symbols.unsafe_ptr()
        for i in range(count):
            var l = lengths[start + i]
            if l:
                sy[unsafe_offset=o[unsafe_offset=l]] = i
                o[unsafe_offset=l] += 1
        var code = 0
        var idx = 0
        for n in range(1, _FAST_BITS + 1):
            for _k in range(c[unsafe_offset=n]):
                var entry = Int32((n << 16) | sy[unsafe_offset=idx])
                idx += 1
                var step = 1 << n
                var at = _reverse_bits(code, n)
                while at < _FAST_SIZE:
                    f[unsafe_offset=at] = entry
                    at += step
                code += 1
            code <<= 1


struct _BitReader[origin: ImmOrigin](Copyable, Movable):
    """A 64-bit bit buffer, so one refill serves several symbols."""

    var data: Span[UInt8, Self.origin]
    var pos: Int
    """Offset of the next byte *not yet in* `bitbuf`."""
    var bitbuf: UInt64
    var bitcnt: Int

    def __init__(out self, data: Span[UInt8, Self.origin]):
        self.data = data
        self.pos = 0
        self.bitbuf = 0
        self.bitcnt = 0

    @always_inline
    def refill(mut self):
        """Top the buffer up to at least 57 bits, if the stream has them.

        Away from the end of the stream this is one eight-byte read and two
        integer ops — the per-byte loop below only runs for the last few
        bytes of the block."""
        if self.pos + 8 <= len(self.data):
            # One unaligned little-endian read of the next eight bytes.
            # avro.mojo targets little-endian platforms only (the Avro binary
            # encoding is little-endian throughout, and so is every platform
            # this builds for).
            var chunk = (
                self.data.unsafe_ptr()
                .unsafe_offset(self.pos)
                .unsafe_bitcast[UInt64]()
                .unsafe_load[alignment=1]()
            )
            self.bitbuf |= chunk << UInt64(self.bitcnt)
            self.pos += (63 - self.bitcnt) >> 3
            self.bitcnt |= 56
            return
        while self.bitcnt <= 56 and self.pos < len(self.data):
            self.bitbuf |= UInt64(self.data[self.pos]) << UInt64(self.bitcnt)
            self.pos += 1
            self.bitcnt += 8

    @always_inline
    def bits(mut self, need: Int) raises -> Int:
        if self.bitcnt < need:
            self.refill()
            if self.bitcnt < need:
                raise Error("inflate: truncated DEFLATE stream")
        var v = Int(self.bitbuf & ((UInt64(1) << UInt64(need)) - 1))
        self.bitbuf >>= UInt64(need)
        self.bitcnt -= need
        return v

    def align(mut self):
        """Drop to the next byte boundary, rewinding the bytes the buffer
        read ahead — a stored block is copied from `data` directly."""
        self.pos -= self.bitcnt // 8
        self.bitbuf = 0
        self.bitcnt = 0

    @always_inline
    def decode(mut self, h: _Huffman) raises -> Int:
        """One Huffman symbol: a table hit, or the bit-at-a-time walk."""
        if self.bitcnt < 15:
            self.refill()
        var e = Int(h.fast[Int(self.bitbuf & UInt64(_FAST_SIZE - 1))])
        if e >= 0:
            var n = e >> 16
            if n > self.bitcnt:
                raise Error("inflate: truncated DEFLATE stream")
            self.bitbuf >>= UInt64(n)
            self.bitcnt -= n
            return e & 0xFFFF
        return self.decode_long(h)

    def decode_long(mut self, h: _Huffman) raises -> Int:
        """Codes longer than `_FAST_BITS` — rare, so walked one bit at a
        time rather than paid for with a second-level table."""
        var code = 0
        var first = 0
        var index = 0
        for length in range(1, 16):
            code |= self.bits(1)
            var count = h.counts[length]
            if code - first < count:
                return h.symbols[index + (code - first)]
            index += count
            first = (first + count) << 1
            code <<= 1
        raise Error("inflate: invalid Huffman code")


def _fixed_literal_lengths() -> List[Int]:
    var l = List[Int](length=288, fill=8)
    for i in range(144, 256):
        l[i] = 9
    for i in range(256, 280):
        l[i] = 7
    return l^


comptime _WINDOW: Int = 32768
"""How far back a DEFLATE back-reference can reach: what `compact` keeps."""

comptime _SLACK: Int = 258 + 16
"""Room kept free past the write position before each symbol: the longest
match, plus the overshoot of the sixteen-byte match copy."""

comptime MARGIN: Int = 1 << 18
"""The input a block is started with when more is still to come (`run` with
`complete=False`). zlib ends a block every 16 Ki or 32 Ki symbols, at most
about 200 KB of input, so with 256 KiB in hand a block almost never runs
past what has arrived; one that does is rolled back and decoded again once
more input is there."""


struct _Out(Copyable, Defaultable, Movable, Sized):
    """The inflate output window.

    A `List[UInt8]` grown with `append` costs a capacity check per literal
    byte and a zero-fill per match; this keeps the buffer valid to its full
    capacity and tracks the write position itself, so the inner loops are a
    store through a pointer and nothing else.
    """

    var buf: List[UInt8]
    var n: Int
    var base: Int
    """Where the stream being decoded began. A back-reference may not reach
    before it, so several streams can share one window (`gunzip` decodes
    every member into the same buffer) without one reading another's bytes.
    0 once `compact` has moved the window past it."""

    def __init__(out self):
        self.buf = List[UInt8]()
        self.n = 0
        self.base = 0

    def __init__(out self, capacity: Int):
        self.buf = List[UInt8](length=max(capacity, 64), fill=0)
        self.n = 0
        self.base = 0

    def __len__(self) -> Int:
        return self.n

    @always_inline
    def room(mut self, extra: Int):
        """Make sure `extra` more bytes can be written without a check."""
        if self.n + extra <= len(self.buf):
            return
        var want = len(self.buf) * 2
        if want < self.n + extra:
            want = self.n + extra
        if want < 4096:
            want = 4096
        self.buf.resize(want, 0)

    @always_inline
    def push(mut self, b: UInt8):
        self.buf[self.n] = b
        self.n += 1

    def extend(mut self, src: Span[UInt8, _]):
        self.room(len(src) + _SLACK)
        unsafe_memcpy(
            dest=self.buf.unsafe_ptr().unsafe_offset(self.n),
            src=src.unsafe_ptr(),
            count=len(src),
        )
        self.n += len(src)

    @always_inline
    def copy_match(mut self, distance: Int, length: Int):
        """LZ77 back-reference, forward, because an overlapping copy
        (`distance < length`) is how DEFLATE spells a run.

        When the source is at least sixteen (or eight) bytes behind, that
        many bytes move at a time: each load then reads only bytes already
        written, and the copy may run up to fifteen bytes past the match,
        into the slack that `room` keeps. Closer than that, it goes byte by
        byte."""
        var at = self.n
        var start = at - distance
        var p = self.buf.unsafe_ptr()
        if distance >= 16:
            var k = 0
            while k < length:
                p.unsafe_offset(at + k).unsafe_store[width=16](
                    p.unsafe_offset(start + k).unsafe_load[width=16]()
                )
                k += 16
        elif distance >= 8:
            var k = 0
            while k < length:
                var v = (
                    p.unsafe_offset(start + k)
                    .unsafe_bitcast[UInt64]()
                    .unsafe_load[alignment=1]()
                )
                p.unsafe_offset(at + k).unsafe_bitcast[UInt64]().unsafe_store[
                    alignment=1
                ](v)
                k += 8
        else:
            for k in range(length):
                p[unsafe_offset=at + k] = p[unsafe_offset=start + k]
        self.n = at + length

    def compact(mut self, keep_from: Int) -> Int:
        """Drop `buf[0:keep_from]`, keeping the last `_WINDOW` bytes however
        small `keep_from` is; return how many bytes went."""
        var drop = min(keep_from, self.n - _WINDOW)
        if drop <= 0:
            return 0
        var p = self.buf.unsafe_ptr()
        var keep = self.n - drop
        # Overlapping, toward the front: a forward copy is safe.
        for k in range(keep):
            p[unsafe_offset=k] = p[unsafe_offset=drop + k]
        self.n = keep
        self.base = max(self.base - drop, 0)
        return drop

    def finish(deinit self) -> List[UInt8]:
        var buf = self.buf^
        buf.resize(self.n, 0)
        return buf^


# ── the streaming inflater ─────────────────────────────────────────────────


@fieldwise_init
struct InflateStatus(Equatable, TrivialRegisterPassable, Writable):
    """Why `Inflater.run` or `GzipReader.run` returned."""

    var value: Int

    comptime OUTPUT = InflateStatus(0)
    """The window holds the output asked for (`n >= want`)."""
    comptime NEED_INPUT = InflateStatus(1)
    """More input is needed before anything more can be decoded."""
    comptime FINISHED = InflateStatus(2)
    """The stream (every gzip member) has been decoded and checked."""

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def write_to(self, mut writer: Some[Writer]):
        if self.value == 0:
            writer.write("OUTPUT")
        elif self.value == 1:
            writer.write("NEED_INPUT")
        else:
            writer.write("FINISHED")


comptime _BLOCKS = 0
comptime _DONE = 1


def _is_short(e: Error) -> Bool:
    """Whether `e` is the decoder running out of input (which more input
    may cure) rather than the input being wrong."""
    return "truncated" in String(e)


struct Inflater(Movable, Sized):
    """A raw DEFLATE stream decoded a window at a time.

    The output collects in a window, `output()`. `run` decodes
    blocks until the window holds `want` bytes, the input runs short or the
    stream ends; the caller uses what is there, then `compact`s away what it
    no longer needs. The window keeps the last 32 KiB whatever is dropped,
    since later back-references may reach that far.

    The input may still be arriving. `run` takes the input so far and
    whether that is all of it; a block that runs past the bytes there is
    rolled back to its start and decoded again on a later call, with more.
    The caller may drop input the inflater has finished with: see
    `discard_input`.

    ```mojo
    var inf = Inflater()
    while True:
        var st = inf.run(Span(input), complete, want=len(inf) + (1 << 20))
        use(inf.output())
        _ = inf.compact(len(inf))
        if st == InflateStatus.FINISHED:
            break
        if st == InflateStatus.NEED_INPUT:
            ...  # append more to `input` (or set complete)
    ```

    `inflate` and `inflate_at` are this with the whole input and a window
    that is never compacted.
    """

    var out: _Out
    var pos: Int
    """The next input byte not yet in the bit buffer, as an offset into the
    `data` passed to `run`."""
    var bitbuf: UInt64
    var bitcnt: Int
    var state: Int
    var margin: Int
    """Input to have in hand before starting a block while more is still to
    come (`MARGIN`). 0 starts every block at once and rolls back each one
    that outruns the input, which tests use."""
    var dropped_in: Int
    """Input bytes `discard_input` has released: what `pos` is relative to."""
    var dropped_out: Int
    """Output bytes `compact` has dropped."""
    var t: _Tables
    var fixed_lit: _Huffman
    var fixed_dist: _Huffman
    var dyn_lit: _Huffman
    var dyn_dist: _Huffman
    var dyn_clen: _Huffman
    """A dynamic block's three codes, rebuilt in place block after block."""
    var lengths: List[Int]
    """Scratch for a dynamic block's code lengths."""

    def __init__(out self, capacity: Int = 1 << 20) raises:
        """`capacity` is the window's starting size; it grows as needed."""
        self.out = _Out(capacity + _SLACK)
        self.pos = 0
        self.bitbuf = 0
        self.bitcnt = 0
        self.state = _BLOCKS
        self.margin = MARGIN
        self.dropped_in = 0
        self.dropped_out = 0
        self.t = _Tables()
        self.fixed_lit = _Huffman()
        self.fixed_dist = _Huffman()
        self.dyn_lit = _Huffman()
        self.dyn_dist = _Huffman()
        self.dyn_clen = _Huffman()
        self.lengths = List[Int](length=320, fill=0)

    # ── window ──

    @always_inline
    def output(self) -> Span[UInt8, origin_of(self.out.buf)]:
        """The window: everything decoded and not yet compacted away."""
        return Span(self.out.buf)[: self.out.n]

    @always_inline
    def __len__(self) -> Int:
        """`len(output())`."""
        return self.out.n

    def compact(mut self, keep_from: Int) -> Int:
        """Drop `output()[0:keep_from]`, as far as back-references allow,
        and return how many bytes went: subtract it from any offsets into
        the window the caller holds."""
        var drop = self.out.compact(keep_from)
        self.dropped_out += drop
        return drop

    def total_out(self) -> Int:
        """Bytes decoded so far, compacted or not."""
        return self.dropped_out + self.out.n

    def finished(self) -> Bool:
        """Whether the final block has been decoded."""
        return self.state == _DONE

    def finish(deinit self) -> List[UInt8]:
        """The window as a list (trimmed to `n`), consuming the inflater."""
        return self.out^.finish()

    # ── input ──

    def input_used(self) -> Int:
        """How many bytes of `data` the inflater is done with. Once the
        stream has finished this is where it ended (rounded up to a byte),
        as `inflate_at` reports."""
        return self.pos - self.bitcnt // 8

    def discard_input(mut self) -> Int:
        """Forget the input before `input_used()` and return how many bytes
        that is: the next `run` must be passed `data` without them. A long
        stream can then be fed through a bounded input buffer."""
        var k = self.input_used()
        # Whole bytes still in the bit buffer are given back, so `pos` can
        # stay a plain offset.
        self.pos = k
        self.bitbuf &= (UInt64(1) << UInt64(self.bitcnt % 8)) - 1
        self.bitcnt %= 8
        self.pos -= k
        self.dropped_in += k
        return k

    def total_in(self) -> Int:
        """Input consumed so far, discarded or not."""
        return self.dropped_in + self.input_used()

    def _begin(mut self, at: Int):
        """Start a fresh stream at `data[at]`, appending to the window."""
        self.pos = at
        self.bitbuf = 0
        self.bitcnt = 0
        self.state = _BLOCKS
        self.out.base = self.out.n

    # ── decoding ──

    def run(
        mut self,
        data: Span[UInt8, _],
        complete: Bool,
        want: Int = Int.MAX,
    ) raises -> InflateStatus:
        """Decode from `data` (the input so far, from where the last call
        left off unless `discard_input` said otherwise; all of it if
        `complete`) until the window holds `want` bytes.

        Returns `OUTPUT` when it does, `NEED_INPUT` when a block is waiting
        for more input than `data` has, or `FINISHED` after the final block.
        Raises on corrupt input, and on input that ends early once
        `complete` is set."""
        while self.out.n < want:
            if self.state == _DONE:
                return InflateStatus.FINISHED
            if not complete and len(data) - self.pos < self.margin:
                return InflateStatus.NEED_INPUT
            var s_pos = self.pos
            var s_buf = self.bitbuf
            var s_cnt = self.bitcnt
            var s_n = self.out.n
            var final: Bool
            try:
                final = self._block(data)
            except e:
                if complete or not _is_short(e):
                    raise e^
                self.pos = s_pos
                self.bitbuf = s_buf
                self.bitcnt = s_cnt
                self.out.n = s_n
                return InflateStatus.NEED_INPUT
            if final:
                self.state = _DONE
        if self.state == _DONE:
            return InflateStatus.FINISHED
        return InflateStatus.OUTPUT

    def _block(mut self, data: Span[UInt8, _]) raises -> Bool:
        """One block onto the window; whether it was the final one."""
        var br = _BitReader(data)
        br.pos = self.pos
        br.bitbuf = self.bitbuf
        br.bitcnt = self.bitcnt
        var final = br.bits(1) == 1
        var btype = br.bits(2)
        if btype == 0:
            br.align()
            if br.pos + 4 > len(br.data):
                raise Error("inflate: truncated stored block header")
            var length = Int(br.data[br.pos]) | (Int(br.data[br.pos + 1]) << 8)
            var nlen = Int(br.data[br.pos + 2]) | (
                Int(br.data[br.pos + 3]) << 8
            )
            if length != (~nlen & 0xFFFF):
                raise Error("inflate: stored block length check failed")
            br.pos += 4
            if br.pos + length > len(br.data):
                raise Error("inflate: truncated stored block")
            self.out.extend(br.data[br.pos : br.pos + length])
            br.pos += length
        elif btype == 1:
            if len(self.fixed_lit.fast) == 0:
                # Built on first use: one-shot callers on small inputs pay
                # only for the codes their stream uses.
                self.fixed_lit.build(_fixed_literal_lengths(), 0, 288)
                self.fixed_dist.build(List[Int](length=30, fill=5), 0, 30)
                self.fixed_lit.entries(True, self.t)
                self.fixed_dist.entries(False, self.t)
            _codes(br, self.fixed_lit, self.fixed_dist, self.t, self.out)
        elif btype == 2:
            var nlen = br.bits(5) + 257
            var ndist = br.bits(5) + 1
            var ncode = br.bits(4) + 4
            if nlen > 286 or ndist > 30:
                raise Error("inflate: too many length or distance codes")
            var lengths = self.lengths.unsafe_ptr()
            for k in range(19):
                lengths[unsafe_offset=k] = 0
            for i in range(ncode):
                lengths[unsafe_offset=self.t.clen_order[i]] = br.bits(3)
            self.dyn_clen.build(self.lengths, 0, 19)
            var total = nlen + ndist
            var i = 0
            while i < total:
                var sym = br.decode(self.dyn_clen)
                var rep: Int
                var fill = 0
                if sym < 16:
                    lengths[unsafe_offset=i] = sym
                    i += 1
                    continue
                elif sym == 16:
                    if i == 0:
                        raise Error("inflate: repeat with no previous length")
                    fill = lengths[unsafe_offset=i - 1]
                    rep = 3 + br.bits(2)
                elif sym == 17:
                    rep = 3 + br.bits(3)
                else:
                    rep = 11 + br.bits(7)
                if i + rep > total:
                    raise Error("inflate: code-length overflow")
                for _k in range(rep):
                    lengths[unsafe_offset=i] = fill
                    i += 1
            self.dyn_lit.build(self.lengths, 0, nlen)
            self.dyn_dist.build(self.lengths, nlen, ndist)
            self.dyn_lit.entries(True, self.t)
            self.dyn_dist.entries(False, self.t)
            _codes(br, self.dyn_lit, self.dyn_dist, self.t, self.out)
        else:
            raise Error("inflate: reserved block type 3")
        if final:
            br.align()
        self.pos = br.pos
        self.bitbuf = br.bitbuf
        self.bitcnt = br.bitcnt
        return final


# ── one-shot ───────────────────────────────────────────────────────────────


def inflate(data: Span[UInt8, _]) raises -> List[UInt8]:
    """Decompress a raw DEFLATE stream."""
    var end = 0
    return inflate_at(data, end)


def inflate_at(data: Span[UInt8, _], mut end: Int) raises -> List[UInt8]:
    """Decompress a DEFLATE stream, and report where it ended.

    `end` is set to the offset of the first byte *after* the stream, rounded
    up to a byte boundary. Callers with several streams back to back —
    concatenated gzip members, for instance — need it to find the next one;
    callers that do not can use `inflate`.
    """
    var inf = Inflater(len(data) * 3 + 64)
    _ = inf.run(data, complete=True)
    end = inf.input_used()
    return inf^.finish()


def _codes(
    mut br: _BitReader,
    lit: _Huffman,
    dist: _Huffman,
    t: _Tables,
    mut out: _Out,
) raises:
    """A block's literal/length and distance codes onto `out`, up to and
    including its end-of-block code.

    While eight bytes of input remain, one refill per symbol leaves at least
    56 bits in the buffer: enough for a literal/length code (15), its extra
    bits (5), a distance code (15) and its extra bits (13), so none of them
    is checked against the bit count. After a literal, more literals are
    taken from the same refill while their codes are in the table. Lengths
    and distances come out of the table with their base and extra bits
    folded in (`_entry`). The last few bytes of input go through
    `_codes_checked`."""
    var n = out.n
    var limit = len(out.buf) - _SLACK
    var p = out.buf.unsafe_ptr()
    var ip = br.data.unsafe_ptr()
    var in_n = len(br.data)
    var bitbuf = br.bitbuf
    var bitcnt = br.bitcnt
    var pos = br.pos
    var lite = lit.ent.unsafe_ptr()
    var diste = dist.ent.unsafe_ptr()
    var lbase = t.len_base.unsafe_ptr()
    var lextra = t.len_extra.unsafe_ptr()
    var dbase = t.dist_base.unsafe_ptr()
    var dextra = t.dist_extra.unsafe_ptr()
    var base = out.base
    comptime MASK = UInt64(_FAST_SIZE - 1)
    while True:
        if pos + 8 > in_n:
            br.bitbuf = bitbuf
            br.bitcnt = bitcnt
            br.pos = pos
            out.n = n
            _codes_checked(br, lit, dist, t, out)
            return
        if n > limit:
            out.n = n
            out.room(_SLACK)
            limit = len(out.buf) - _SLACK
            p = out.buf.unsafe_ptr()
        # Refill: one unaligned little-endian load (every target this builds
        # for is little-endian), topping the buffer up to 56..63 bits.
        var chunk = (
            ip.unsafe_offset(pos).unsafe_bitcast[UInt64]().unsafe_load[
                alignment=1
            ]()
        )
        bitbuf |= chunk << UInt64(bitcnt)
        pos += (63 - bitcnt) >> 3
        bitcnt |= 56
        var e = lite[unsafe_offset=Int(bitbuf & MASK)]
        var kind = e & _E_KIND
        if kind == _E_LIT:
            var used = Int(e & 0xFF)
            bitbuf >>= UInt64(used)
            bitcnt -= used
            p[unsafe_offset=n] = UInt8(e >> 16)
            n += 1
            # At most 56 one-bit literals per refill: well inside the slack.
            while bitcnt >= _FAST_BITS:
                e = lite[unsafe_offset=Int(bitbuf & MASK)]
                if (e & _E_KIND) != _E_LIT:
                    break
                used = Int(e & 0xFF)
                bitbuf >>= UInt64(used)
                bitcnt -= used
                p[unsafe_offset=n] = UInt8(e >> 16)
                n += 1
            continue
        var length: Int
        if kind == _E_LEN:
            var total = Int(e & 0xFF)
            length = Int(e >> 16) + Int(
                (bitbuf & ((UInt64(1) << UInt64(total)) - 1))
                >> UInt64((e >> 8) & 0xF)
            )
            bitbuf >>= UInt64(total)
            bitcnt -= total
        elif kind == _E_EOB:
            var used = Int(e & 0xFF)
            bitbuf >>= UInt64(used)
            bitcnt -= used
            break
        else:
            # A code longer than the table (or an invalid symbol).
            br.bitbuf = bitbuf
            br.bitcnt = bitcnt
            br.pos = pos
            var sym = br.decode_long(lit)
            bitbuf = br.bitbuf
            bitcnt = br.bitcnt
            pos = br.pos
            if sym < 256:
                p[unsafe_offset=n] = UInt8(sym)
                n += 1
                continue
            if sym == 256:
                break
            var lc = sym - 257
            if lc >= 29:
                raise Error("inflate: invalid length symbol")
            var le = lextra[unsafe_offset=lc]
            length = lbase[unsafe_offset=lc] + Int(
                bitbuf & ((UInt64(1) << UInt64(le)) - 1)
            )
            bitbuf >>= UInt64(le)
            bitcnt -= le
        var ed = diste[unsafe_offset=Int(bitbuf & MASK)]
        var d: Int
        if (ed & _E_KIND) == _E_LEN:
            var total = Int(ed & 0xFF)
            d = Int(ed >> 16) + Int(
                (bitbuf & ((UInt64(1) << UInt64(total)) - 1))
                >> UInt64((ed >> 8) & 0xF)
            )
            bitbuf >>= UInt64(total)
            bitcnt -= total
        else:
            br.bitbuf = bitbuf
            br.bitcnt = bitcnt
            br.pos = pos
            var dc = br.decode_long(dist)
            bitbuf = br.bitbuf
            bitcnt = br.bitcnt
            pos = br.pos
            if dc >= 30:
                raise Error("inflate: invalid distance symbol")
            var de = dextra[unsafe_offset=dc]
            d = dbase[unsafe_offset=dc] + Int(
                bitbuf & ((UInt64(1) << UInt64(de)) - 1)
            )
            bitbuf >>= UInt64(de)
            bitcnt -= de
        if d > n - base:
            raise Error("inflate: distance runs before the output start")
        var src = n - d
        if d >= 16:
            var k = 0
            while k < length:
                p.unsafe_offset(n + k).unsafe_store[width=16](
                    p.unsafe_offset(src + k).unsafe_load[width=16]()
                )
                k += 16
        elif d >= 8:
            var k = 0
            while k < length:
                var v = (
                    p.unsafe_offset(src + k)
                    .unsafe_bitcast[UInt64]()
                    .unsafe_load[alignment=1]()
                )
                p.unsafe_offset(n + k).unsafe_bitcast[UInt64]().unsafe_store[
                    alignment=1
                ](v)
                k += 8
        elif d == 1:
            # A run of one byte: broadcast it, eight at a time.
            var v = UInt64(p[unsafe_offset=src]) * 0x0101010101010101
            var k = 0
            while k < length:
                p.unsafe_offset(n + k).unsafe_bitcast[UInt64]().unsafe_store[
                    alignment=1
                ](v)
                k += 8
        else:
            for k in range(length):
                p[unsafe_offset=n + k] = p[unsafe_offset=src + k]
        n += length
    br.bitbuf = bitbuf
    br.bitcnt = bitcnt
    br.pos = pos
    out.n = n


def _codes_checked(
    mut br: _BitReader,
    lit: _Huffman,
    dist: _Huffman,
    t: _Tables,
    mut out: _Out,
) raises:
    """`_codes` for the last bytes of the input: every read checked."""
    while True:
        out.room(_SLACK)
        var sym = br.decode(lit)
        if sym < 256:
            out.push(UInt8(sym))
        elif sym == 256:
            return
        else:
            var lc = sym - 257
            if lc >= 29:
                raise Error("inflate: invalid length symbol")
            var length = t.len_base[lc] + br.bits(t.len_extra[lc])
            var dc = br.decode(dist)
            if dc >= 30:
                raise Error("inflate: invalid distance symbol")
            var d = t.dist_base[dc] + br.bits(t.dist_extra[dc])
            if d > out.n - out.base:
                raise Error("inflate: distance runs before the output start")
            out.copy_match(d, length)


# ── compression ────────────────────────────────────────────────────────────


struct _BitWriter(Copyable, Defaultable, Movable):
    var out: List[UInt8]
    var bitbuf: UInt32
    var bitcnt: Int

    def __init__(out self):
        self.out = List[UInt8]()
        self.bitbuf = 0
        self.bitcnt = 0

    def put(mut self, value: Int, count: Int):
        """Write `count` low bits of `value`, least-significant first."""
        self.bitbuf |= UInt32(value) << UInt32(self.bitcnt)
        self.bitcnt += count
        while self.bitcnt >= 8:
            self.out.append(UInt8(self.bitbuf & 0xFF))
            self.bitbuf >>= 8
            self.bitcnt -= 8

    def put_code(mut self, code: Int, count: Int):
        """Write a Huffman code: its bits go out most-significant first."""
        var v = 0
        for k in range(count):
            v |= ((code >> (count - 1 - k)) & 1) << k
        self.put(v, count)

    def take(deinit self) -> List[UInt8]:
        return self.out^

    def flush(mut self):
        if self.bitcnt:
            self.out.append(UInt8(self.bitbuf & 0xFF))
            self.bitbuf = 0
            self.bitcnt = 0


def _fixed_lit_code(sym: Int) -> Tuple[Int, Int]:
    """(code, bit count) for a literal/length symbol in a fixed block."""
    if sym < 144:
        return (0x30 + sym, 8)
    if sym < 256:
        return (0x190 + sym - 144, 9)
    if sym < 280:
        return (sym - 256, 7)
    return (0xC0 + sym - 280, 8)


comptime _HASH_BITS = 15
comptime _HASH_SIZE = 1 << _HASH_BITS
comptime _MAX_MATCH = 258
comptime _MIN_MATCH = 3
comptime _MAX_DIST = 32768


def deflate(data: Span[UInt8, _]) raises -> List[UInt8]:
    """Compress to a raw DEFLATE stream (one fixed-Huffman block)."""
    var t = _Tables()
    var w = _BitWriter()
    w.put(1, 1)  # BFINAL
    w.put(1, 2)  # BTYPE = fixed Huffman
    var head = List[Int](length=_HASH_SIZE, fill=-1)
    var prev = List[Int](length=max(len(data), 1), fill=-1)
    var i = 0
    var n = len(data)
    while i < n:
        var best_len = 0
        var best_dist = 0
        if i + _MIN_MATCH <= n:
            var h = _hash3(data, i)
            var cand = head[h]
            var chain = 0
            while cand >= 0 and i - cand <= _MAX_DIST and chain < 16:
                var l = _match_len(data, cand, i, n)
                if l > best_len:
                    best_len = l
                    best_dist = i - cand
                    if l >= _MAX_MATCH:
                        break
                cand = prev[cand]
                chain += 1
            prev[i] = head[h]
            head[h] = i
        if best_len >= _MIN_MATCH:
            var lc = 0
            while lc < 28 and t.len_base[lc + 1] <= best_len:
                lc += 1
            var code_bits = _fixed_lit_code(257 + lc)
            w.put_code(code_bits[0], code_bits[1])
            if t.len_extra[lc]:
                w.put(best_len - t.len_base[lc], t.len_extra[lc])
            var dc = 0
            while dc < 29 and t.dist_base[dc + 1] <= best_dist:
                dc += 1
            w.put_code(dc, 5)
            if t.dist_extra[dc]:
                w.put(best_dist - t.dist_base[dc], t.dist_extra[dc])
            # Index the bytes the match covers so later matches can find them.
            for k in range(1, best_len):
                var p = i + k
                if p + _MIN_MATCH <= n:
                    var hh = _hash3(data, p)
                    prev[p] = head[hh]
                    head[hh] = p
            i += best_len
        else:
            var code_bits = _fixed_lit_code(Int(data[i]))
            w.put_code(code_bits[0], code_bits[1])
            i += 1
    var end = _fixed_lit_code(256)
    w.put_code(end[0], end[1])
    w.flush()
    return w^.take()


def _hash3(data: Span[UInt8, _], i: Int) -> Int:
    var v = (
        (UInt32(data[i]) << 16)
        | (UInt32(data[i + 1]) << 8)
        | UInt32(data[i + 2])
    )
    var h = (v * UInt32(0x1E35A7BD)) >> UInt32(32 - _HASH_BITS)
    return Int(h) & (_HASH_SIZE - 1)


def _match_len(data: Span[UInt8, _], a: Int, b: Int, n: Int) -> Int:
    var l = 0
    while b + l < n and l < _MAX_MATCH and data[a + l] == data[b + l]:
        l += 1
    return l
