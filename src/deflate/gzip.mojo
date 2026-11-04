"""gzip (RFC 1952) framing over the raw DEFLATE in `raw.mojo`.

`gunzip` decodes a whole `.gz` file: every member of a concatenated stream,
each one's header (all five flags: FTEXT, FHCRC, FEXTRA, FNAME, FCOMMENT)
parsed and skipped, and each one's CRC-32 and ISIZE checked against what it
decoded to. `gunzip_at` decodes one member and reports where it ended, as
`inflate_at` does for raw streams. `gzip` writes a single member.

The CRC-32 is the zlib/gzip one (reflected polynomial 0xEDB88320), slice-by-8
as in hashes.mojo's `crc32`. It is repeated here rather than imported so the
tin keeps no sibling dependency: a consumer still needs nothing but
`-I deflate.mojo/src`.
"""

from std.sys import llvm_intrinsic
from std.sys.info import CompilationTarget

from deflate.raw import _inflate_into, _Out, deflate

# ── CRC-32 ─────────────────────────────────────────────────────────────────

comptime _CRC_POLY: UInt32 = 0xEDB88320

comptime _ARM_CRC = (
    not CompilationTarget.is_x86()
    and CompilationTarget._has_feature["neon"]()
    and CompilationTarget._has_feature["crc"]()
)
"""aarch64 with the CRC32 extension (every Apple Silicon and server Arm part):
`crc32x` folds eight bytes per instruction, several times the table's speed.
Only when the target CPU advertises it, so a build whose `mojo` resolved no
CPU (GitHub's macOS runners) still selects, on the table."""


def crc32_backend() -> String:
    """`armv8-crc` or `slice-by-8`: which CRC-32 this build uses."""
    comptime if _ARM_CRC:
        return String("armv8-crc")
    return String("slice-by-8")


struct _Crc32(Movable):
    """CRC-32: the Arm CRC instructions where the target has them, otherwise
    a slice-by-8 table (eight bytes per step, one unaligned 64-bit load and
    eight lookups)."""

    var table: List[UInt32]
    """Flat 8 x 256; table k occupies [k*256, k*256 + 256)."""

    def __init__(out self):
        self.table = List[UInt32](capacity=8 * 256)
        for i in range(256):
            var c = UInt32(i)
            for _k in range(8):
                c = (_CRC_POLY ^ (c >> 1)) if (c & 1) else (c >> 1)
            self.table.append(c)
        for k in range(1, 8):
            for i in range(256):
                var prev = self.table[(k - 1) * 256 + i]
                self.table.append(self.table[Int(prev & 0xFF)] ^ (prev >> 8))

    def update(self, crc_in: UInt32, data: Span[UInt8, _]) -> UInt32:
        """Continue `crc_in` (a finished CRC-32, 0 to start) over `data`."""
        comptime if _ARM_CRC:
            return _arm_crc32(crc_in, data)
        return self.table_update(crc_in, data)

    def table_update(self, crc_in: UInt32, data: Span[UInt8, _]) -> UInt32:
        """`update` through the slice-by-8 table, whatever the target."""
        var crc = ~crc_in
        var t = self.table.unsafe_ptr()
        var p = data.unsafe_ptr()
        var n = len(data)
        var i = 0
        while i + 8 <= n:
            # Little-endian only, like the bit reader in raw.mojo.
            var v = (
                p.unsafe_offset(i)
                .unsafe_bitcast[UInt64]()
                .unsafe_load[alignment=1]()
            )
            var lo = UInt32(v & 0xFFFFFFFF) ^ crc
            var hi = UInt32(v >> 32)
            crc = (
                t[unsafe_offset=7 * 256 + Int(lo & 0xFF)]
                ^ t[unsafe_offset=6 * 256 + Int((lo >> 8) & 0xFF)]
                ^ t[unsafe_offset=5 * 256 + Int((lo >> 16) & 0xFF)]
                ^ t[unsafe_offset=4 * 256 + Int(lo >> 24)]
                ^ t[unsafe_offset=3 * 256 + Int(hi & 0xFF)]
                ^ t[unsafe_offset=2 * 256 + Int((hi >> 8) & 0xFF)]
                ^ t[unsafe_offset=1 * 256 + Int((hi >> 16) & 0xFF)]
                ^ t[unsafe_offset=Int(hi >> 24)]
            )
            i += 8
        while i < n:
            var k = Int((crc ^ UInt32(p[unsafe_offset=i])) & 0xFF)
            crc = t[unsafe_offset=k] ^ (crc >> 8)
            i += 1
        return ~crc


def _arm_crc32(crc_in: UInt32, data: Span[UInt8, _]) -> UInt32:
    """`_Crc32.update` with the Arm CRC32 instructions; `_ARM_CRC` only."""
    var crc = ~crc_in
    var p = data.unsafe_ptr()
    var n = len(data)
    var i = 0
    while i + 8 <= n:
        var v = (
            p.unsafe_offset(i).unsafe_bitcast[UInt64]().unsafe_load[alignment=1]()
        )
        crc = llvm_intrinsic["llvm.aarch64.crc32x", UInt32](crc, v)
        i += 8
    while i < n:
        crc = llvm_intrinsic["llvm.aarch64.crc32b", UInt32](
            crc, UInt32(p[unsafe_offset=i])
        )
        i += 1
    return ~crc


# ── header and trailer ─────────────────────────────────────────────────────

comptime _ID1: UInt8 = 0x1F
comptime _ID2: UInt8 = 0x8B
comptime _CM_DEFLATE: UInt8 = 8
comptime _FTEXT = 1
comptime _FHCRC = 2
comptime _FEXTRA = 4
comptime _FNAME = 8
comptime _FCOMMENT = 16
comptime _FRESERVED = 0xE0


def _u32le(data: Span[UInt8, _], at: Int) -> UInt32:
    return (
        UInt32(data[at])
        | (UInt32(data[at + 1]) << 8)
        | (UInt32(data[at + 2]) << 16)
        | (UInt32(data[at + 3]) << 24)
    )


def _err(member: Int, at: Int, what: StringSlice) -> Error:
    return Error(String("gunzip: member ", member, " at byte ", at, ": ", what))


def _skip_zstring(
    data: Span[UInt8, _], var i: Int, member: Int, start: Int, what: StringSlice
) raises -> Int:
    """Offset just past the NUL that ends a FNAME or FCOMMENT field."""
    while i < len(data) and data[i] != 0:
        i += 1
    if i >= len(data):
        raise _err(member, start, String("truncated header (", what, ")"))
    return i + 1


def _header_end(
    data: Span[UInt8, _], start: Int, member: Int, crc: _Crc32
) raises -> Int:
    """Parse the member header at `start`; return where its DEFLATE body
    begins. Every optional field is bounds-checked, and FHCRC is verified."""
    var n = len(data)
    if start + 10 > n:
        raise _err(member, start, "truncated header")
    if data[start] != _ID1 or data[start + 1] != _ID2:
        raise _err(member, start, "not a gzip stream (bad magic)")
    if data[start + 2] != _CM_DEFLATE:
        raise _err(
            member,
            start,
            String("unknown compression method ", Int(data[start + 2])),
        )
    var flg = Int(data[start + 3])
    if flg & _FRESERVED:
        raise _err(member, start, String("reserved flag bits set: ", flg))
    var i = start + 10
    if flg & _FEXTRA:
        if i + 2 > n:
            raise _err(member, start, "truncated header (FEXTRA length)")
        var xlen = Int(data[i]) | (Int(data[i + 1]) << 8)
        i += 2 + xlen
        if i > n:
            raise _err(member, start, "truncated header (FEXTRA)")
    if flg & _FNAME:
        i = _skip_zstring(data, i, member, start, "FNAME")
    if flg & _FCOMMENT:
        i = _skip_zstring(data, i, member, start, "FCOMMENT")
    if flg & _FHCRC:
        if i + 2 > n:
            raise _err(member, start, "truncated header (FHCRC)")
        var want = Int(data[i]) | (Int(data[i + 1]) << 8)
        var got = Int(crc.update(0, data[start:i]) & 0xFFFF)
        if got != want:
            raise _err(member, start, "header CRC (FHCRC) mismatch")
        i += 2
    return i


def _member(
    data: Span[UInt8, _],
    start: Int,
    member: Int,
    crc: _Crc32,
    mut out: _Out,
) raises -> Int:
    """Decode the member at `start` onto the end of `out`, check its trailer,
    and return the offset just past it."""
    var body = _header_end(data, start, member, crc)
    var first = out.n
    var used = 0
    try:
        _inflate_into(data[body:], used, out)
    except e:
        raise _err(member, start, String(e))
    var tail = body + used
    if tail + 8 > len(data):
        raise _err(member, start, "truncated trailer (CRC-32 and ISIZE)")
    var produced = out.n - first
    var got = crc.update(0, Span(out.buf)[first : out.n])
    if got != _u32le(data, tail):
        raise _err(member, start, "CRC-32 mismatch")
    if UInt32(produced & 0xFFFFFFFF) != _u32le(data, tail + 4):
        raise _err(member, start, "ISIZE mismatch")
    return tail + 8


# ── public API ─────────────────────────────────────────────────────────────


def gunzip(data: Span[UInt8, _]) raises -> List[UInt8]:
    """Decompress a gzip file: all of its members, concatenated.

    Each member's CRC-32 and length are verified. Zero bytes after the last
    member are padding (as gzip(1) and Python's `gzip` accept); anything else
    there raises, as does an empty input.
    """
    var n = len(data)
    if n == 0:
        raise Error("gunzip: empty input")
    # The last four bytes are the final member's ISIZE: for the usual
    # one-member file, the exact output size. 1032:1 is DEFLATE's ceiling, so
    # a larger claim is corruption, not a reason to allocate.
    var hint = n * 4 + 64
    if n >= 18:
        var isize = Int(_u32le(data, n - 4))
        if isize <= n * 1032:
            hint = isize + 64
    var out = _Out(hint)
    var crc = _Crc32()
    var pos = 0
    var member = 0
    while True:
        pos = _member(data, pos, member, crc, out)
        member += 1
        if pos >= n:
            break
        if data[pos] != _ID1:
            var k = pos
            while k < n and data[k] == 0:
                k += 1
            if k == n:
                break
            raise Error(
                String("gunzip: trailing garbage after member ", member - 1,
                    " at byte ", pos)
            )
    return out^.finish()


def gunzip_at(data: Span[UInt8, _], mut end: Int) raises -> List[UInt8]:
    """Decompress the one gzip member at the start of `data`, verifying its
    CRC-32 and length, and set `end` to the offset just past its trailer.

    For walking a multi-member file one member at a time, so only one
    member's output is held at once:

    ```mojo
    var pos = 0
    while pos < len(data):
        var end = 0
        var part = gunzip_at(Span(data)[pos:], end)
        pos += end
    ```
    """
    # No ISIZE to size the buffer from until the member is decoded; start
    # modest and let the window double rather than reserve 3x the rest of a
    # possibly huge multi-member file per member.
    var out = _Out(min(len(data) * 3 + 64, 1 << 22))
    var crc = _Crc32()
    end = _member(data, 0, 0, crc, out)
    return out^.finish()


def gzip(data: Span[UInt8, _], level: Int = 6) raises -> List[UInt8]:
    """Compress `data` into a single gzip member.

    `level` 0 writes stored (uncompressed) DEFLATE blocks; 1 to 9 all use
    `deflate`'s one fixed-Huffman strategy, so they produce the same bytes.
    The header carries no name, comment or timestamp (MTIME 0, OS 255).
    """
    if level < 0 or level > 9:
        raise Error(String("gzip: level must be 0..9, got ", level))
    var out = List[UInt8](capacity=len(data) // 2 + 64)
    var xfl = UInt8(2) if level == 9 else (UInt8(4) if level == 1 else UInt8(0))
    for b in [_ID1, _ID2, _CM_DEFLATE, UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), xfl, UInt8(255)]:
        out.append(b)
    if level == 0:
        _stored_blocks(data, out)
    else:
        out.extend(Span(deflate(data)))
    var c = _Crc32().update(0, data)
    var size = UInt32(len(data) & 0xFFFFFFFF)
    for k in range(4):
        out.append(UInt8((c >> UInt32(8 * k)) & 0xFF))
    for k in range(4):
        out.append(UInt8((size >> UInt32(8 * k)) & 0xFF))
    return out^


def _stored_blocks(data: Span[UInt8, _], mut out: List[UInt8]):
    """Raw DEFLATE of stored blocks, at most 65535 bytes each."""
    var n = len(data)
    var i = 0
    while True:
        var take = min(n - i, 65535)
        var final = i + take == n
        out.append(UInt8(1) if final else UInt8(0))  # BFINAL, BTYPE 00
        out.append(UInt8(take & 0xFF))
        out.append(UInt8(take >> 8))
        out.append(UInt8(~take & 0xFF))
        out.append(UInt8((~take >> 8) & 0xFF))
        out.extend(data[i : i + take])
        i += take
        if final:
            return
