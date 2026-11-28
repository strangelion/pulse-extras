//! Bounded multi-format desktop pet importer (Shimeji, animated GIF, PNG
//! sprite packs, and OpenPets PNG). Converts supported sources into a
//! canonical Classic v1 package (pet.json + 1536x1872 lossless VP8L WebP)
//! inside an exclusively owned private staging directory so every imported
//! asset passes the same strict validation, fingerprinting, and staging gate.
const std = @import("std");
const assets = @import("pet_assets.zig");
const inventory = @import("pet_inventory.zig");

pub const max_source_bytes: usize = 64 * 1024 * 1024;
pub const max_image_bytes: usize = 16 * 1024 * 1024;
pub const max_image_dim: u32 = 2048;
pub const max_gif_dim: u32 = 1024;
pub const max_frames: usize = 64;
pub const max_zip_entries: usize = 512;

pub const atlas_w: u32 = assets.frame_width * assets.columns; // 1536
pub const atlas_h: u32 = assets.frame_height * 9; // 1872

pub const Error = error{
    InvalidFormat,
    UnsupportedFormat,
    ResourceLimit,
    CorruptPayload,
    InvalidArchive,
    UnsafePath,
    OutOfMemory,
    Io,
};

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u8, // tightly packed RGBA8

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = .{ .width = 0, .height = 0, .pixels = &.{} };
    }
};

pub const FormatKind = enum {
    shimeji,
    gif,
    png_atlas,
    png_frames,
    png_static,
};

fn readU16Be(b: []const u8, off: usize) u16 {
    return (@as(u16, b[off]) << 8) | b[off + 1];
}

fn readU32Be(b: []const u8, off: usize) u32 {
    return (@as(u32, b[off]) << 24) | (@as(u32, b[off + 1]) << 16) | (@as(u32, b[off + 2]) << 8) | b[off + 3];
}

fn readU16Le(b: []const u8, off: usize) u16 {
    return @as(u16, b[off]) | (@as(u16, b[off + 1]) << 8);
}

fn readU32Le(b: []const u8, off: usize) u32 {
    return @as(u32, readU16Le(b, off)) | (@as(u32, readU16Le(b, off + 2)) << 16);
}

fn writeU32Le(out: []u8, v: u32) void {
    out[0] = @truncate(v);
    out[1] = @truncate(v >> 8);
    out[2] = @truncate(v >> 16);
    out[3] = @truncate(v >> 24);
}

fn bitReverse(value: u32, comptime bits: u5) u32 {
    var v = value;
    var out: u32 = 0;
    inline for (0..bits) |_| {
        out = (out << 1) | (v & 1);
        v >>= 1;
    }
    return out;
}

const BitWriter = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    acc: u64 = 0,
    bits: u6 = 0,

    fn deinit(self: *BitWriter) void {
        self.bytes.deinit(self.allocator);
    }

    fn writeBits(self: *BitWriter, value: u32, count: u6) !void {
        self.acc |= @as(u64, value) << self.bits;
        self.bits += count;
        while (self.bits >= 8) {
            try self.bytes.append(self.allocator, @truncate(self.acc));
            self.acc >>= 8;
            self.bits -= 8;
        }
    }

    fn flush(self: *BitWriter) !void {
        if (self.bits > 0) {
            try self.bytes.append(self.allocator, @truncate(self.acc));
            self.acc = 0;
            self.bits = 0;
        }
    }
};

fn vp8lLengthPrefix(length: u32) struct { code: u32, extra_bits: u6, extra_val: u32 } {
    const val = length - 1;
    if (val < 4) return .{ .code = val, .extra_bits = 0, .extra_val = 0 };
    const highest: u5 = @intCast(31 - @clz(val));
    const extra_bits: u6 = highest - 1;
    const second_bit: u32 = (val >> @intCast(extra_bits)) & 1;
    const code: u32 = 2 * @as(u32, extra_bits) + 2 + second_bit;
    const mask: u32 = (@as(u32, 1) << @intCast(extra_bits)) - 1;
    return .{ .code = code, .extra_bits = extra_bits, .extra_val = val & mask };
}

fn writeUniform256Code(bw: *BitWriter) !void {
    // Normal prefix code: symbols 0..255 all length 8.
    try bw.writeBits(0, 1); // is_simple = 0
    // VP8L kCodeLengthCodeOrder: [17,18,0,1,2,3,4,5,16,6,7,8,9,10,11,12,13,14,15]
    // index 8 = symbol 16 (code len 1 -> bit 1), index 11 = symbol 8 (code len 1 -> bit 0).
    try bw.writeBits(12 - 4, 4); // num_code_lengths = 12
    for (0..12) |i| {
        const cl: u32 = if (i == 8 or i == 11) 1 else 0;
        try bw.writeBits(cl, 3);
    }
    try bw.writeBits(0, 1); // use_max_symbol = 0
    // 1 literal '8', 42 repeats of 6 (=252), 1 repeat of 3 (=3) -> 256 symbols of length 8.
    try bw.writeBits(0, 1); // symbol 8
    for (0..42) |_| {
        try bw.writeBits(1, 1); // symbol 16
        try bw.writeBits(3, 2); // repeat 6
    }
    try bw.writeBits(1, 1); // symbol 16
    try bw.writeBits(0, 2); // repeat 3
}

fn writeGreenLength280Code(bw: *BitWriter) !void {
    // Normal prefix code for 280 symbols (256 literals + 24 LZ77 length codes):
    // Symbols 0..231 have length 8; symbols 232..279 have length 9.
    // Kraft sum = 232/256 + 48/512 = 1.0.
    try bw.writeBits(0, 1); // is_simple = 0
    // Code-length-code lengths: symbol 8 (idx 11) -> 1 (code 0),
    // symbol 9 (idx 12) -> 2 (code 10 -> LSB 01 = 1),
    // symbol 16 (idx 8) -> 2 (code 11 -> LSB 11 = 3).
    try bw.writeBits(13 - 4, 4); // num_code_lengths = 13
    for (0..13) |i| {
        const cl: u32 = if (i == 11) 1 else if (i == 8 or i == 12) 2 else 0;
        try bw.writeBits(cl, 3);
    }
    try bw.writeBits(0, 1); // use_max_symbol = 0
    // 232 symbols of length 8: 1 + 38*6 + 3 = 232.
    try bw.writeBits(0, 1); // symbol 8
    for (0..38) |_| {
        try bw.writeBits(3, 2); // symbol 16
        try bw.writeBits(3, 2); // repeat 6
    }
    try bw.writeBits(3, 2); // symbol 16
    try bw.writeBits(0, 2); // repeat 3
    // 48 symbols of length 9: 1 + 7*6 + 5 = 48.
    try bw.writeBits(1, 2); // symbol 9 (canonical 10 -> LSB-first 01)
    for (0..7) |_| {
        try bw.writeBits(3, 2); // symbol 16
        try bw.writeBits(3, 2); // repeat 6
    }
    try bw.writeBits(3, 2); // symbol 16
    try bw.writeBits(2, 2); // repeat 5
}

fn writeDistance1Code(bw: *BitWriter) !void {
    // Simple 1-symbol prefix code: symbol 1 -> raw distance code 2 -> 2D offset (1, 0) = previous pixel.
    try bw.writeBits(1, 1); // is_simple = 1
    try bw.writeBits(0, 1); // num_symbols - 1 = 0 (1 symbol)
    try bw.writeBits(0, 1); // is_first_8bits = 0 (1-bit symbol)
    try bw.writeBits(1, 1); // symbol0 = 1
}

/// Encode tightly packed RGBA8 pixels into a valid, static lossless VP8L WebP
/// file using distance-1 RLE and canonical Huffman codes.
pub fn encodeWebpVp8l(allocator: std.mem.Allocator, width: u32, height: u32, rgba: []const u8) ![]u8 {
    if (width == 0 or height == 0 or width > 16384 or height > 16384) return error.InvalidFormat;
    const pixel_count: usize = @as(usize, width) * @as(usize, height);
    if (rgba.len != pixel_count * 4) return error.InvalidFormat;

    var bw: BitWriter = .{ .allocator = allocator };
    defer bw.deinit();
    try bw.bytes.ensureTotalCapacity(allocator, @min(pixel_count, 2 * 1024 * 1024) + 64);

    // Reserve RIFF (12) + VP8L chunk header (8) + VP8L signature/dims (5) = 25 bytes.
    try bw.bytes.appendNTimes(allocator, 0, 25);

    // Bitstream header: no transforms, no color cache, no meta prefix.
    try bw.writeBits(0, 1);
    try bw.writeBits(0, 1);
    try bw.writeBits(0, 1);

    // 5 prefix codes: Green+Length, Red, Blue, Alpha, Distance.
    try writeGreenLength280Code(&bw);
    try writeUniform256Code(&bw);
    try writeUniform256Code(&bw);
    try writeUniform256Code(&bw);
    try writeDistance1Code(&bw);

    // Precompute bit-reversed tables for fast encoding.
    var rev8: [256]u32 = undefined;
    for (0..256) |i| rev8[i] = bitReverse(@intCast(i), 8);
    var rev9_tail: [48]u32 = undefined;
    for (0..48) |i| rev9_tail[i] = bitReverse(@intCast(464 + i), 9);

    var idx: usize = 0;
    while (idx < pixel_count) {
        const p = rgba[idx * 4 ..][0..4];
        // Check if current pixel matches immediately preceding pixel (distance 1).
        if (idx > 0 and std.mem.eql(u8, p, rgba[(idx - 1) * 4 ..][0..4])) {
            var run: usize = 1;
            const limit = @min(pixel_count - idx, 4096);
            while (run < limit and std.mem.eql(u8, rgba[(idx + run) * 4 ..][0..4], p)) : (run += 1) {}
            if (run >= 2) {
                const lp = vp8lLengthPrefix(@intCast(run));
                const sym = 256 + lp.code; // 256..279 -> index 24..47 in rev9_tail
                try bw.writeBits(rev9_tail[sym - 232], 9);
                if (lp.extra_bits > 0) try bw.writeBits(lp.extra_val, lp.extra_bits);
                // Distance code has 1 symbol -> 0 bits emitted.
                idx += run;
                continue;
            }
        }
        // Literal pixel in VP8L order: Green, Red, Blue, Alpha.
        const g = p[1];
        if (g < 232) {
            try bw.writeBits(rev8[g], 8);
        } else {
            try bw.writeBits(rev9_tail[g - 232], 9);
        }
        try bw.writeBits(rev8[p[0]], 8);
        try bw.writeBits(rev8[p[2]], 8);
        try bw.writeBits(rev8[p[3]], 8);
        idx += 1;
    }

    try bw.flush();
    const vp8l_payload_len: usize = bw.bytes.items.len - 20;
    if (vp8l_payload_len > assets.max_webp_bytes - 24) return error.ResourceLimit;
    if ((vp8l_payload_len & 1) != 0) try bw.bytes.append(allocator, 0);

    const out = bw.bytes.items;
    const riff_size: u32 = @intCast(out.len - 8);
    @memcpy(out[0..4], "RIFF");
    writeU32Le(out[4..8], riff_size);
    @memcpy(out[8..12], "WEBP");
    @memcpy(out[12..16], "VP8L");
    writeU32Le(out[16..20], @intCast(vp8l_payload_len));
    out[20] = 0x2f;
    const bits: u32 = (width - 1) | ((height - 1) << 14) | (@as(u32, 1) << 28);
    writeU32Le(out[21..25], bits);

    return bw.bytes.toOwnedSlice(allocator);
}

fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    const ia: i32 = a;
    const ib: i32 = b;
    const ic: i32 = c;
    const p = ia + ib - ic;
    const pa = @abs(p - ia);
    const pb = @abs(p - ib);
    const pc = @abs(p - ic);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Pure-Zig bounded PNG decoder (8-bit Gray/RGB/Indexed/GrayA/RGBA, non-interlaced).
pub fn decodePng(allocator: std.mem.Allocator, bytes: []const u8) Error!Image {
    if (bytes.len < 33 or bytes.len > max_image_bytes) return error.InvalidFormat;
    const sig = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
    if (!std.mem.eql(u8, bytes[0..8], &sig)) return error.InvalidFormat;

    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var got_ihdr = false;
    var palette: [256][3]u8 = @splat(.{ 0, 0, 0 });
    var palette_len: usize = 0;
    var trns_alpha: [256]u8 = @splat(255);
    var trns_rgb: ?[3]u8 = null;
    var trns_gray: ?u8 = null;

    var idat: std.ArrayListUnmanaged(u8) = .empty;
    defer idat.deinit(allocator);

    while (pos + 12 <= bytes.len) {
        const len = readU32Be(bytes, pos);
        const tag = bytes[pos + 4 ..][0..4];
        const data_start = pos + 8;
        if (len > bytes.len - data_start or bytes.len - data_start - len < 4) return error.InvalidFormat;
        const data = bytes[data_start..][0..len];
        const expected_crc = readU32Be(bytes, data_start + len);
        var crc = std.hash.Crc32.init();
        crc.update(tag);
        crc.update(data);
        if (crc.final() != expected_crc) return error.CorruptPayload;
        pos = data_start + len + 4;

        if (std.mem.eql(u8, tag, "IHDR")) {
            if (got_ihdr or len != 13) return error.InvalidFormat;
            width = readU32Be(data, 0);
            height = readU32Be(data, 4);
            bit_depth = data[8];
            color_type = data[9];
            const compression = data[10];
            const filter = data[11];
            const interlace = data[12];
            if (width == 0 or height == 0 or width > max_image_dim or height > max_image_dim) return error.ResourceLimit;
            if (compression != 0 or filter != 0 or interlace != 0) return error.UnsupportedFormat;
            if (bit_depth != 8 and !(color_type == 3 and (bit_depth == 1 or bit_depth == 2 or bit_depth == 4))) return error.UnsupportedFormat;
            if (color_type != 0 and color_type != 2 and color_type != 3 and color_type != 4 and color_type != 6) return error.UnsupportedFormat;
            got_ihdr = true;
        } else if (std.mem.eql(u8, tag, "PLTE")) {
            if (!got_ihdr or len == 0 or len % 3 != 0 or len / 3 > 256) return error.InvalidFormat;
            palette_len = len / 3;
            for (0..palette_len) |i| {
                palette[i] = .{ data[i * 3], data[i * 3 + 1], data[i * 3 + 2] };
            }
        } else if (std.mem.eql(u8, tag, "tRNS")) {
            if (!got_ihdr) return error.InvalidFormat;
            if (color_type == 3) {
                if (len > 256) return error.InvalidFormat;
                for (0..len) |i| trns_alpha[i] = data[i];
            } else if (color_type == 2 and len == 6) {
                trns_rgb = .{ data[1], data[3], data[5] };
            } else if (color_type == 0 and len == 2) {
                trns_gray = data[1];
            }
        } else if (std.mem.eql(u8, tag, "IDAT")) {
            if (!got_ihdr) return error.InvalidFormat;
            if (idat.items.len + len > max_image_bytes) return error.ResourceLimit;
            idat.appendSlice(allocator, data) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, tag, "IEND")) {
            break;
        }
    }

    if (!got_ihdr or idat.items.len == 0) return error.InvalidFormat;
    if (color_type == 3 and palette_len == 0) return error.InvalidFormat;

    const channels: usize = switch (color_type) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => return error.UnsupportedFormat,
    };
    const bits_per_pixel = channels * bit_depth;
    const row_bytes: usize = (@as(usize, width) * bits_per_pixel + 7) / 8;
    const filter_bpp: usize = @max(@as(usize, 1), bits_per_pixel / 8);
    const raw_len: usize = @as(usize, height) * (1 + row_bytes);
    if (raw_len > 32 * 1024 * 1024) return error.ResourceLimit;

    const raw = allocator.alloc(u8, raw_len) catch return error.OutOfMemory;
    defer allocator.free(raw);

    var input = std.Io.Reader.fixed(idat.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(&input, .zlib, &window);
    decomp.reader.readSliceAll(raw) catch return error.CorruptPayload;

    const pixels = allocator.alloc(u8, @as(usize, width) * @as(usize, height) * 4) catch return error.OutOfMemory;
    errdefer allocator.free(pixels);

    const prev_row = allocator.alloc(u8, row_bytes) catch return error.OutOfMemory;
    defer allocator.free(prev_row);
    @memset(prev_row, 0);

    const cur_row = allocator.alloc(u8, row_bytes) catch return error.OutOfMemory;
    defer allocator.free(cur_row);

    for (0..height) |y| {
        const src_row = raw[y * (1 + row_bytes) ..];
        const filter_type = src_row[0];
        const filtered = src_row[1 .. 1 + row_bytes];
        for (0..row_bytes) |i| {
            const left: u8 = if (i >= filter_bpp) cur_row[i - filter_bpp] else 0;
            const up: u8 = prev_row[i];
            const up_left: u8 = if (i >= filter_bpp) prev_row[i - filter_bpp] else 0;
            cur_row[i] = switch (filter_type) {
                0 => filtered[i],
                1 => filtered[i] +% left,
                2 => filtered[i] +% up,
                3 => filtered[i] +% @as(u8, @intCast((@as(u16, left) + @as(u16, up)) / 2)),
                4 => filtered[i] +% paethPredictor(left, up, up_left),
                else => return error.CorruptPayload,
            };
        }

        const dst_row = pixels[y * @as(usize, width) * 4 ..];
        for (0..width) |x| {
            const dst = dst_row[x * 4 ..][0..4];
            switch (color_type) {
                6 => @memcpy(dst, cur_row[x * 4 ..][0..4]),
                2 => {
                    const r = cur_row[x * 3];
                    const g = cur_row[x * 3 + 1];
                    const b = cur_row[x * 3 + 2];
                    const a: u8 = if (trns_rgb) |t| (if (t[0] == r and t[1] == g and t[2] == b) 0 else 255) else 255;
                    dst.* = .{ r, g, b, a };
                },
                0 => {
                    const v = cur_row[x];
                    const a: u8 = if (trns_gray) |t| (if (t == v) 0 else 255) else 255;
                    dst.* = .{ v, v, v, a };
                },
                4 => {
                    const v = cur_row[x * 2];
                    dst.* = .{ v, v, v, cur_row[x * 2 + 1] };
                },
                3 => {
                    const index: usize = switch (bit_depth) {
                        8 => cur_row[x],
                        4 => (cur_row[x / 2] >> @intCast(4 * (1 - (x & 1)))) & 0x0f,
                        2 => (cur_row[x / 4] >> @intCast(2 * (3 - (x & 3)))) & 0x03,
                        1 => (cur_row[x / 8] >> @intCast(7 - (x & 7))) & 0x01,
                        else => 0,
                    };
                    if (index >= palette_len) return error.CorruptPayload;
                    const rgb = palette[index];
                    dst.* = .{ rgb[0], rgb[1], rgb[2], trns_alpha[index] };
                },
                else => return error.UnsupportedFormat,
            }
        }
        @memcpy(prev_row, cur_row);
    }

    return .{ .width = width, .height = height, .pixels = pixels };
}

fn decodeGifLzw(allocator: std.mem.Allocator, min_code_size: u8, subblocks: []const u8, expected: usize) Error![]u8 {
    if (min_code_size < 2 or min_code_size > 8) return error.CorruptPayload;
    const clear_code: u16 = @as(u16, 1) << @intCast(min_code_size);
    const eoi_code: u16 = clear_code + 1;

    var prefix: [4096]u16 = undefined;
    var suffix: [4096]u8 = undefined;
    var stack: [4096]u8 = undefined;

    const out = allocator.alloc(u8, expected) catch return error.OutOfMemory;
    errdefer allocator.free(out);
    var out_pos: usize = 0;

    var code_size: u5 = @intCast(min_code_size + 1);
    var next_code: u16 = eoi_code + 1;
    var old_code: ?u16 = null;
    var first_char: u8 = 0;

    var bit_buf: u32 = 0;
    var bit_cnt: u5 = 0;
    var byte_pos: usize = 0;

    while (out_pos < expected) {
        while (bit_cnt < code_size) {
            if (byte_pos >= subblocks.len) return out;
            bit_buf |= @as(u32, subblocks[byte_pos]) << bit_cnt;
            byte_pos += 1;
            bit_cnt += 8;
        }
        const mask: u32 = (@as(u32, 1) << code_size) - 1;
        const code: u16 = @intCast(bit_buf & mask);
        bit_buf >>= code_size;
        bit_cnt -= code_size;

        if (code == clear_code) {
            code_size = @intCast(min_code_size + 1);
            next_code = eoi_code + 1;
            old_code = null;
            continue;
        }
        if (code == eoi_code) break;

        var in_code = code;
        var sp: usize = 0;
        if (code >= next_code) {
            if (code > next_code or old_code == null) return error.CorruptPayload;
            stack[sp] = first_char;
            sp += 1;
            in_code = old_code.?;
        }
        while (in_code >= clear_code) {
            if (sp >= stack.len) return error.CorruptPayload;
            stack[sp] = suffix[in_code];
            sp += 1;
            in_code = prefix[in_code];
        }
        first_char = @intCast(in_code);
        if (sp >= stack.len) return error.CorruptPayload;
        stack[sp] = first_char;
        sp += 1;

        while (sp > 0) {
            sp -= 1;
            if (out_pos >= expected) break;
            out[out_pos] = stack[sp];
            out_pos += 1;
        }

        if (old_code) |prev| {
            if (next_code < 4096) {
                prefix[next_code] = prev;
                suffix[next_code] = first_char;
                next_code += 1;
                if (next_code == (@as(u16, 1) << @intCast(code_size)) and code_size < 12) {
                    code_size += 1;
                }
            }
        }
        old_code = code;
    }
    return out;
}

/// Pure-Zig bounded GIF87a/GIF89a decoder producing composited RGBA8 frames.
pub fn decodeGifFrames(allocator: std.mem.Allocator, bytes: []const u8) Error![]Image {
    if (bytes.len < 14 or bytes.len > max_image_bytes) return error.InvalidFormat;
    if (!std.mem.eql(u8, bytes[0..6], "GIF87a") and !std.mem.eql(u8, bytes[0..6], "GIF89a")) return error.InvalidFormat;

    const canvas_w: u32 = readU16Le(bytes, 6);
    const canvas_h: u32 = readU16Le(bytes, 8);
    if (canvas_w == 0 or canvas_h == 0 or canvas_w > max_gif_dim or canvas_h > max_gif_dim) return error.ResourceLimit;

    const packed_lsd = bytes[10];
    var pos: usize = 13;
    var gct: [256][3]u8 = @splat(.{ 0, 0, 0 });
    var gct_len: usize = 0;
    if (packed_lsd & 0x80 != 0) {
        gct_len = @as(usize, 1) << @intCast((packed_lsd & 0x07) + 1);
        if (pos + gct_len * 3 > bytes.len) return error.InvalidFormat;
        for (0..gct_len) |i| {
            gct[i] = .{ bytes[pos + i * 3], bytes[pos + i * 3 + 1], bytes[pos + i * 3 + 2] };
        }
        pos += gct_len * 3;
    }

    const canvas_bytes = @as(usize, canvas_w) * @as(usize, canvas_h) * 4;
    const canvas = allocator.alloc(u8, canvas_bytes) catch return error.OutOfMemory;
    defer allocator.free(canvas);
    @memset(canvas, 0);

    const prev_backup = allocator.alloc(u8, canvas_bytes) catch return error.OutOfMemory;
    defer allocator.free(prev_backup);

    var frames: std.ArrayListUnmanaged(Image) = .empty;
    errdefer {
        for (frames.items) |*f| f.deinit(allocator);
        frames.deinit(allocator);
    }

    var transparent_index: ?u8 = null;
    var disposal: u3 = 0;

    while (pos < bytes.len and frames.items.len < max_frames) {
        const intro = bytes[pos];
        pos += 1;
        if (intro == 0x3b) break; // Trailer
        if (intro == 0x21) { // Extension
            if (pos >= bytes.len) break;
            const label = bytes[pos];
            pos += 1;
            if (label == 0xf9) {
                if (pos + 6 > bytes.len or bytes[pos] != 4) return error.InvalidFormat;
                const gce = bytes[pos + 1];
                disposal = @intCast((gce >> 2) & 7);
                transparent_index = if (gce & 1 != 0) bytes[pos + 4] else null;
                pos += 6;
            } else {
                while (pos < bytes.len) {
                    const blen = bytes[pos];
                    pos += 1;
                    if (blen == 0) break;
                    if (pos + blen > bytes.len) return error.InvalidFormat;
                    pos += blen;
                }
            }
            continue;
        }
        if (intro != 0x2c) return error.InvalidFormat;
        if (pos + 9 > bytes.len) return error.InvalidFormat;
        const fx: u32 = readU16Le(bytes, pos);
        const fy: u32 = readU16Le(bytes, pos + 2);
        const fw: u32 = readU16Le(bytes, pos + 4);
        const fh: u32 = readU16Le(bytes, pos + 6);
        const fpacked = bytes[pos + 8];
        pos += 9;
        if (fw == 0 or fh == 0 or fx + fw > canvas_w or fy + fh > canvas_h) return error.InvalidFormat;
        const interlaced = (fpacked & 0x40) != 0;

        var lct: [256][3]u8 = @splat(.{ 0, 0, 0 });
        var active_ct: *const [256][3]u8 = &gct;
        var active_ct_len: usize = gct_len;
        if (fpacked & 0x80 != 0) {
            const lct_len = @as(usize, 1) << @intCast((fpacked & 0x07) + 1);
            if (pos + lct_len * 3 > bytes.len) return error.InvalidFormat;
            for (0..lct_len) |i| {
                lct[i] = .{ bytes[pos + i * 3], bytes[pos + i * 3 + 1], bytes[pos + i * 3 + 2] };
            }
            pos += lct_len * 3;
            active_ct = &lct;
            active_ct_len = lct_len;
        }
        if (active_ct_len == 0 or pos >= bytes.len) return error.InvalidFormat;

        const min_code = bytes[pos];
        pos += 1;
        var lzw_data: std.ArrayListUnmanaged(u8) = .empty;
        defer lzw_data.deinit(allocator);
        while (pos < bytes.len) {
            const blen = bytes[pos];
            pos += 1;
            if (blen == 0) break;
            if (pos + blen > bytes.len) return error.InvalidFormat;
            lzw_data.appendSlice(allocator, bytes[pos..][0..blen]) catch return error.OutOfMemory;
            pos += blen;
        }

        const indices = try decodeGifLzw(allocator, min_code, lzw_data.items, @as(usize, fw) * @as(usize, fh));
        defer allocator.free(indices);

        if (disposal == 3) @memcpy(prev_backup, canvas);

        const pass_starts = [_]usize{ 0, 4, 2, 1 };
        const pass_steps = [_]usize{ 8, 8, 4, 2 };
        var src_y: usize = 0;
        if (interlaced) {
            for (pass_starts, pass_steps) |start, step| {
                var row = start;
                while (row < fh) : (row += step) {
                    for (0..fw) |col| {
                        const ci = indices[src_y * fw + col];
                        if (transparent_index != null and ci == transparent_index.?) continue;
                        if (ci >= active_ct_len) continue;
                        const rgb = active_ct[ci];
                        const dst = canvas[((fy + row) * canvas_w + (fx + col)) * 4 ..][0..4];
                        dst.* = .{ rgb[0], rgb[1], rgb[2], 255 };
                    }
                    src_y += 1;
                }
            }
        } else {
            for (0..fh) |row| {
                for (0..fw) |col| {
                    const ci = indices[row * fw + col];
                    if (transparent_index != null and ci == transparent_index.?) continue;
                    if (ci >= active_ct_len) continue;
                    const rgb = active_ct[ci];
                    const dst = canvas[((fy + row) * canvas_w + (fx + col)) * 4 ..][0..4];
                    dst.* = .{ rgb[0], rgb[1], rgb[2], 255 };
                }
            }
        }

        const copy = allocator.dupe(u8, canvas) catch return error.OutOfMemory;
        frames.append(allocator, .{ .width = canvas_w, .height = canvas_h, .pixels = copy }) catch {
            allocator.free(copy);
            return error.OutOfMemory;
        };

        if (disposal == 2) {
            for (0..fh) |row| {
                const start_off = ((fy + row) * canvas_w + fx) * 4;
                @memset(canvas[start_off..][0 .. @as(usize, fw) * 4], 0);
            }
        } else if (disposal == 3) {
            @memcpy(canvas, prev_backup);
        }
        transparent_index = null;
        disposal = 0;
    }

    if (frames.items.len == 0) return error.InvalidFormat;
    return frames.toOwnedSlice(allocator);
}

/// Blit `src` centered and aspect-fitted into cell `(col, row)` of a 1536x1872 Classic v1 atlas.
pub fn blitCell(atlas: []u8, col: u32, row: u32, src: *const Image, y_shift: i32) void {
    const cell_w: u32 = assets.frame_width;
    const cell_h: u32 = assets.frame_height;
    const pad: u32 = 8;
    const avail_w: f64 = @floatFromInt(cell_w - pad * 2);
    const avail_h: f64 = @floatFromInt(cell_h - pad * 2);
    const sw: f64 = @floatFromInt(src.width);
    const sh: f64 = @floatFromInt(src.height);
    const scale = @min(avail_w / sw, avail_h / sh);
    const dst_w: u32 = @max(@as(u32, 1), @min(cell_w, @as(u32, @intFromFloat(@round(sw * scale)))));
    const dst_h: u32 = @max(@as(u32, 1), @min(cell_h, @as(u32, @intFromFloat(@round(sh * scale)))));
    const off_x: i32 = @intCast((cell_w - dst_w) / 2);
    // Align near bottom of cell (ground line) with optional vertical bounce shift.
    const base_y: i32 = @intCast(cell_h - dst_h - @min(pad, cell_h - dst_h));
    const off_y: i32 = @max(0, @min(@as(i32, @intCast(cell_h - dst_h)), base_y + y_shift));

    const cell_x0: usize = @as(usize, col) * cell_w;
    const cell_y0: usize = @as(usize, row) * cell_h;

    for (0..dst_h) |dy| {
        const sy: usize = @min(src.height - 1, @as(usize, @intCast((dy * src.height) / dst_h)));
        const ay: usize = cell_y0 + @as(usize, @intCast(off_y)) + dy;
        for (0..dst_w) |dx| {
            const sx: usize = @min(src.width - 1, @as(usize, @intCast((dx * src.width) / dst_w)));
            const ax: usize = cell_x0 + @as(usize, @intCast(off_x)) + dx;
            const sp = src.pixels[(sy * src.width + sx) * 4 ..][0..4];
            const dp = atlas[(ay * atlas_w + ax) * 4 ..][0..4];
            @memcpy(dp, sp);
        }
    }
}

/// Pack a Shimeji frame table (`shimeji1.png`..`shimeji46.png`, 1-based slots) into Classic v1 atlas.
pub fn buildShimejiAtlas(allocator: std.mem.Allocator, shimeji: []const ?Image) ![]u8 {
    var fallback: ?*const Image = null;
    for (shimeji) |*slot| {
        if (slot.*) |*img| {
            fallback = img;
            break;
        }
    }
    const base = fallback orelse return error.InvalidFormat;

    const atlas = allocator.alloc(u8, @as(usize, atlas_w) * @as(usize, atlas_h) * 4) catch return error.OutOfMemory;
    errdefer allocator.free(atlas);
    @memset(atlas, 0);

    // Classic v1 rows (9 rows x 8 frames) mapped from standard Shimeji frame indices (1..46):
    // 0: idle, 1: review/sit, 2: running/walk, 3: waiting/sleep,
    // 4: waving/greet, 5: jumping, 6: failed/flail, 7: extra walk, 8: extra sit.
    const mapping = [9][8]u8{
        .{ 1, 1, 2, 1, 1, 3, 1, 1 },
        .{ 11, 26, 27, 28, 29, 26, 11, 11 },
        .{ 1, 2, 1, 3, 1, 2, 1, 3 },
        .{ 18, 19, 18, 19, 30, 31, 30, 31 },
        .{ 1, 18, 19, 22, 1, 18, 19, 22 },
        .{ 4, 22, 34, 35, 36, 22, 19, 1 },
        .{ 5, 6, 7, 8, 9, 10, 5, 6 },
        .{ 12, 13, 14, 12, 13, 14, 1, 1 },
        .{ 26, 27, 28, 29, 11, 1, 1, 1 },
    };

    for (0..9) |r| {
        for (0..8) |c| {
            const idx = mapping[r][c];
            const img: *const Image = if (idx < shimeji.len and shimeji[idx] != null) &shimeji[idx].? else base;
            const shift: i32 = if (r == 5 and (c == 2 or c == 3 or c == 4)) -10 else 0;
            blitCell(atlas, @intCast(c), @intCast(r), img, shift);
        }
    }
    return atlas;
}

/// Pack an ordered sequence of frames (from GIF or PNG folder/ZIP) into a Classic v1 atlas.
pub fn buildFrameSequenceAtlas(allocator: std.mem.Allocator, frames: []const Image) ![]u8 {
    if (frames.len == 0) return error.InvalidFormat;
    const atlas = allocator.alloc(u8, @as(usize, atlas_w) * @as(usize, atlas_h) * 4) catch return error.OutOfMemory;
    errdefer allocator.free(atlas);
    @memset(atlas, 0);

    if (frames.len == 1) {
        // Synthesize gentle breathing / hop offsets so a single static sprite feels alive.
        const idle_shifts = [8]i32{ 0, 0, -2, -3, -2, 0, 0, 0 };
        const hop_shifts = [8]i32{ 0, -6, -12, -16, -12, -6, -2, 0 };
        for (0..9) |r| {
            for (0..8) |c| {
                const shift = if (r == 5 or r == 4) hop_shifts[c] else idle_shifts[c];
                blitCell(atlas, @intCast(c), @intCast(r), &frames[0], shift);
            }
        }
        return atlas;
    }

    for (0..9) |r| {
        const stride: usize = if (r == 2 or r == 5) @max(@as(usize, 1), frames.len / 8) else 1;
        for (0..8) |c| {
            const fi = ((c * stride) + (r * 2)) % frames.len;
            const shift: i32 = if (r == 5 and (c == 2 or c == 3 or c == 4)) -8 else 0;
            blitCell(atlas, @intCast(c), @intCast(r), &frames[fi], shift);
        }
    }
    return atlas;
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.append('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.appendSlice("\\\""),
            '\\' => try writer.appendSlice("\\\\"),
            0x00...0x1f => {},
            else => try writer.append(c),
        }
    }
    try writer.append('"');
}

pub fn formatClassicMetadata(allocator: std.mem.Allocator, source_id: []const u8, display_name: []const u8, description: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"id\":");
    const w = struct {
        list: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        fn append(self: @This(), ch: u8) !void {
            try self.list.append(self.alloc, ch);
        }
        fn appendSlice(self: @This(), slice: []const u8) !void {
            try self.list.appendSlice(self.alloc, slice);
        }
    }{ .list = &out, .alloc = allocator };
    try writeJsonString(w, source_id);
    try out.appendSlice(allocator, ",\"displayName\":");
    try writeJsonString(w, if (display_name.len != 0) display_name else source_id);
    try out.appendSlice(allocator, ",\"description\":");
    try writeJsonString(w, description);
    try out.appendSlice(allocator, ",\"spritesheetPath\":\"spritesheet.webp\"}");
    return out.toOwnedSlice(allocator);
}

/// Derive a safe OpenPets source ID slug from any filename or folder name.
pub fn deriveSourceId(raw_name: []const u8, out: *[64]u8) usize {
    // Strip path components and known archive/image extensions.
    var base = raw_name;
    if (std.mem.lastIndexOfAny(u8, base, "\\/")) |sep| base = base[sep + 1 ..];
    for ([_][]const u8{ ".zip", ".gif", ".png", ".webp" }) |ext| {
        if (base.len > ext.len and std.ascii.eqlIgnoreCase(base[base.len - ext.len ..], ext)) {
            base = base[0 .. base.len - ext.len];
            break;
        }
    }
    var len: usize = 0;
    for (base) |c| {
        if (len >= 60) break;
        const lower = std.ascii.toLower(c);
        if ((lower >= 'a' and lower <= 'z') or std.ascii.isDigit(lower)) {
            out[len] = lower;
            len += 1;
        } else if ((lower == '-' or lower == '_' or lower == ' ' or lower == '.') and len > 0 and out[len - 1] != '-') {
            out[len] = '-';
            len += 1;
        }
    }
    while (len > 0 and (out[len - 1] == '-' or out[len - 1] == '_')) len -= 1;
    if (len == 0 or std.mem.eql(u8, out[0..len], "builtin")) {
        const fallback = "pet-import";
        @memcpy(out[0..fallback.len], fallback);
        return fallback.len;
    }
    return len;
}

fn parseShimejiIndex(leaf: []const u8) ?u8 {
    if (leaf.len < 12 or !std.ascii.endsWithIgnoreCase(leaf, ".png")) return null;
    if (!std.ascii.startsWithIgnoreCase(leaf, "shimeji") and !std.ascii.startsWithIgnoreCase(leaf, "shime")) return null;
    const prefix_len: usize = if (std.ascii.startsWithIgnoreCase(leaf, "shimeji")) 7 else 5;
    const digits = leaf[prefix_len .. leaf.len - 4];
    if (digits.len == 0 or digits.len > 2) return null;
    const num = std.fmt.parseInt(u8, digits, 10) catch return null;
    if (num < 1 or num > 46) return null;
    return num;
}

fn naturalLess(a: []const u8, b: []const u8) bool {
    var ia: usize = 0;
    var ib: usize = 0;
    while (ia < a.len and ib < b.len) {
        if (std.ascii.isDigit(a[ia]) and std.ascii.isDigit(b[ib])) {
            var ea = ia;
            while (ea < a.len and std.ascii.isDigit(a[ea])) : (ea += 1) {}
            var eb = ib;
            while (eb < b.len and std.ascii.isDigit(b[eb])) : (eb += 1) {}
            const na = std.fmt.parseInt(u64, a[ia..ea], 10) catch 0;
            const nb = std.fmt.parseInt(u64, b[ib..eb], 10) catch 0;
            if (na != nb) return na < nb;
            ia = ea;
            ib = eb;
        } else {
            const ca = std.ascii.toLower(a[ia]);
            const cb = std.ascii.toLower(b[ib]);
            if (ca != cb) return ca < cb;
            ia += 1;
            ib += 1;
        }
    }
    return a.len < b.len;
}

fn writeClassicStage(io: std.Io, scratch: std.Io.Dir, metadata_json: []const u8, webp_bytes: []const u8) !void {
    try scratch.createDir(io, "unpacked", .default_dir);
    const root = try scratch.openDir(io, "unpacked", .{ .follow_symlinks = false });
    defer root.close(io);
    {
        const f = try root.createFile(io, "pet.json", .{ .exclusive = true });
        defer f.close(io);
        try f.writeStreamingAll(io, metadata_json);
    }
    {
        const f = try root.createFile(io, "spritesheet.webp", .{ .exclusive = true });
        defer f.close(io);
        try f.writeStreamingAll(io, webp_bytes);
    }
}

pub fn cleanupConvertedStage(io: std.Io, scratch: std.Io.Dir) !void {
    if (scratch.openDir(io, "unpacked", .{ .follow_symlinks = false })) |root| {
        defer root.close(io);
        root.deleteFile(io, "pet.json") catch |err| if (err != error.FileNotFound) return err;
        root.deleteFile(io, "spritesheet.webp") catch |err| if (err != error.FileNotFound) return err;
    } else |err| if (err == error.FileNotFound) return else return err;
    try scratch.deleteDir(io, "unpacked");
}

const NamedBlob = struct {
    name: []u8,
    bytes: []u8,
};

fn convertBlobsToClassic(
    io: std.Io,
    allocator: std.mem.Allocator,
    scratch: std.Io.Dir,
    source_id: []const u8,
    blobs: []NamedBlob,
) !FormatKind {
    if (!inventory.validSource(source_id) or blobs.len == 0) return error.InvalidFormat;

    // 1. Check for Shimeji (shimeji1.png..shimeji46.png / shime1.png..shime46.png).
    var shimeji_slots: [47]?Image = @splat(null);
    defer for (&shimeji_slots) |*s| if (s.*) |*img| img.deinit(allocator);
    var shimeji_count: usize = 0;
    for (blobs) |blob| {
        const leaf = if (std.mem.lastIndexOfAny(u8, blob.name, "\\/")) |sep| blob.name[sep + 1 ..] else blob.name;
        if (parseShimejiIndex(leaf)) |idx| {
            if (shimeji_slots[idx] == null) {
                if (decodePng(allocator, blob.bytes)) |img| {
                    shimeji_slots[idx] = img;
                    shimeji_count += 1;
                } else |_| {}
            }
        }
    }
    if (shimeji_count >= 1) {
        const atlas = try buildShimejiAtlas(allocator, &shimeji_slots);
        defer allocator.free(atlas);
        const webp = try encodeWebpVp8l(allocator, atlas_w, atlas_h, atlas);
        defer allocator.free(webp);
        const meta = try formatClassicMetadata(allocator, source_id, source_id, "从 Shimeji 素材导入转换");
        defer allocator.free(meta);
        try writeClassicStage(io, scratch, meta, webp);
        return .shimeji;
    }

    // 2. Check for animated GIF.
    for (blobs) |blob| {
        if (std.ascii.endsWithIgnoreCase(blob.name, ".gif")) {
            const frames = try decodeGifFrames(allocator, blob.bytes);
            defer {
                for (frames) |*f| f.deinit(allocator);
                allocator.free(frames);
            }
            const atlas = try buildFrameSequenceAtlas(allocator, frames);
            defer allocator.free(atlas);
            const webp = try encodeWebpVp8l(allocator, atlas_w, atlas_h, atlas);
            defer allocator.free(webp);
            const meta = try formatClassicMetadata(allocator, source_id, source_id, "从 GIF 动图导入转换");
            defer allocator.free(meta);
            try writeClassicStage(io, scratch, meta, webp);
            return .gif;
        }
    }

    // 3. Collect PNG files (direct 1536x1872 OpenPets PNG atlas, multi-frame PNG sequence, or static PNG).
    var png_indices: std.ArrayListUnmanaged(usize) = .empty;
    defer png_indices.deinit(allocator);
    for (blobs, 0..) |blob, i| {
        if (std.ascii.endsWithIgnoreCase(blob.name, ".png")) {
            try png_indices.append(allocator, i);
        }
    }
    if (png_indices.items.len == 0) return error.UnsupportedFormat;

    // Sort naturally so frame_1.png, frame_2.png, ..., frame_10.png play in order.
    const SortCtx = struct {
        blobs: []const NamedBlob,
        fn less(ctx: @This(), a: usize, b: usize) bool {
            return naturalLess(ctx.blobs[a].name, ctx.blobs[b].name);
        }
    };
    std.mem.sort(usize, png_indices.items, SortCtx{ .blobs = blobs }, SortCtx.less);

    // Check if there is a direct 1536x1872 Classic v1 PNG spritesheet.
    for (png_indices.items) |pi| {
        const img = decodePng(allocator, blobs[pi].bytes) catch continue;
        if (img.width == atlas_w and img.height == atlas_h) {
            var owned = img;
            defer owned.deinit(allocator);
            const webp = try encodeWebpVp8l(allocator, atlas_w, atlas_h, owned.pixels);
            defer allocator.free(webp);
            const meta = try formatClassicMetadata(allocator, source_id, source_id, "从 PNG 精灵图导入转换");
            defer allocator.free(meta);
            try writeClassicStage(io, scratch, meta, webp);
            return .png_atlas;
        }
        var drop = img;
        drop.deinit(allocator);
    }

    var frames: std.ArrayListUnmanaged(Image) = .empty;
    defer {
        for (frames.items) |*f| f.deinit(allocator);
        frames.deinit(allocator);
    }
    for (png_indices.items) |pi| {
        if (frames.items.len >= max_frames) break;
        if (decodePng(allocator, blobs[pi].bytes)) |img| {
            try frames.append(allocator, img);
        } else |_| {}
    }
    if (frames.items.len == 0) return error.InvalidFormat;

    const atlas = try buildFrameSequenceAtlas(allocator, frames.items);
    defer allocator.free(atlas);
    const webp = try encodeWebpVp8l(allocator, atlas_w, atlas_h, atlas);
    defer allocator.free(webp);
    const kind: FormatKind = if (frames.items.len == 1) .png_static else .png_frames;
    const desc = if (kind == .png_static) "从 PNG 图像导入转换" else "从 PNG 序列帧导入转换";
    const meta = try formatClassicMetadata(allocator, source_id, source_id, desc);
    defer allocator.free(meta);
    try writeClassicStage(io, scratch, meta, webp);
    return kind;
}

/// Convert a single local `.gif` or `.png` file into a staged Classic v1 package.
pub fn convertSingleFileToClassic(
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    source_name: []const u8,
    scratch: std.Io.Dir,
    source_id: []const u8,
) !FormatKind {
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size == 0 or stat.size > max_image_bytes) return error.ResourceLimit;
    const data = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(data);
    const got = try file.readPositionalAll(io, data, 0);
    if (got != data.len) return error.Io;
    const name_copy = try allocator.dupe(u8, source_name);
    defer allocator.free(name_copy);
    var blobs = [_]NamedBlob{.{ .name = name_copy, .bytes = data }};
    return convertBlobsToClassic(io, allocator, scratch, source_id, &blobs);
}

/// Convert a non-OpenPets ZIP archive (Shimeji, GIF, or PNG sequence) into a staged Classic v1 package.
pub fn convertZipToClassic(
    io: std.Io,
    allocator: std.mem.Allocator,
    archive: std.Io.File,
    scratch: std.Io.Dir,
    source_id: []const u8,
) !FormatKind {
    const stat = try archive.stat(io);
    if (stat.kind != .file or stat.size < 22 or stat.size > max_source_bytes) return error.InvalidArchive;
    const total_size: usize = @intCast(stat.size);
    const raw = try allocator.alloc(u8, total_size);
    defer allocator.free(raw);
    if ((try archive.readPositionalAll(io, raw, 0)) != total_size) return error.Io;

    // Locate EOCD (allow up to 64 KiB ZIP comment, unlike strict OpenPets ZIP).
    const min_eocd = if (total_size > 65557) total_size - 65557 else 0;
    var eocd_pos: ?usize = null;
    var scan: usize = total_size - 22;
    while (true) {
        if (readU32Le(raw, scan) == 0x06054b50) {
            const comment_len = readU16Le(raw, scan + 20);
            if (scan + 22 + comment_len == total_size) {
                eocd_pos = scan;
                break;
            }
        }
        if (scan == min_eocd) break;
        scan -= 1;
    }
    const eocd = eocd_pos orelse return error.InvalidArchive;
    const entry_count = readU16Le(raw, eocd + 10);
    const cd_size: usize = readU32Le(raw, eocd + 12);
    const cd_off: usize = readU32Le(raw, eocd + 16);
    if (entry_count == 0 or entry_count > max_zip_entries or cd_off + cd_size > eocd) return error.InvalidArchive;

    var blobs: std.ArrayListUnmanaged(NamedBlob) = .empty;
    defer {
        for (blobs.items) |b| {
            allocator.free(b.name);
            allocator.free(b.bytes);
        }
        blobs.deinit(allocator);
    }

    var total_extracted: usize = 0;
    var pos = cd_off;
    for (0..entry_count) |_| {
        if (pos + 46 > cd_off + cd_size or readU32Le(raw, pos) != 0x02014b50) return error.InvalidArchive;
        const method = readU16Le(raw, pos + 10);
        const expected_crc = readU32Le(raw, pos + 16);
        const comp_size: usize = readU32Le(raw, pos + 20);
        const uncomp_size: usize = readU32Le(raw, pos + 24);
        const name_len: usize = readU16Le(raw, pos + 28);
        const extra_len: usize = readU16Le(raw, pos + 30);
        const comment_len: usize = readU16Le(raw, pos + 32);
        const local_off: usize = readU32Le(raw, pos + 42);
        const name_start = pos + 46;
        if (name_start + name_len + extra_len + comment_len > cd_off + cd_size) return error.InvalidArchive;
        const name = raw[name_start..][0..name_len];
        pos = name_start + name_len + extra_len + comment_len;

        if (name.len == 0 or name[name.len - 1] == '/') continue;
        if (std.mem.indexOf(u8, name, "..") != null or std.mem.startsWith(u8, name, "__MACOSX/")) continue;
        if (!std.ascii.endsWithIgnoreCase(name, ".png") and !std.ascii.endsWithIgnoreCase(name, ".gif")) continue;
        if (method != 0 and method != 8) continue;
        if (uncomp_size == 0 or uncomp_size > max_image_bytes or total_extracted + uncomp_size > max_source_bytes) continue;
        if (local_off + 30 > cd_off or readU32Le(raw, local_off) != 0x04034b50) return error.InvalidArchive;
        const local_name_len: usize = readU16Le(raw, local_off + 26);
        const local_extra_len: usize = readU16Le(raw, local_off + 28);
        const data_off = local_off + 30 + local_name_len + local_extra_len;
        if (data_off + comp_size > cd_off) return error.InvalidArchive;
        const comp_slice = raw[data_off..][0..comp_size];

        const out_buf = try allocator.alloc(u8, uncomp_size);
        errdefer allocator.free(out_buf);
        if (method == 0) {
            if (comp_size != uncomp_size) {
                allocator.free(out_buf);
                continue;
            }
            @memcpy(out_buf, comp_slice);
        } else {
            var reader = std.Io.Reader.fixed(comp_slice);
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var decomp = std.compress.flate.Decompress.init(&reader, .raw, &window);
            decomp.reader.readSliceAll(out_buf) catch {
                allocator.free(out_buf);
                continue;
            };
        }
        var crc = std.hash.Crc32.init();
        crc.update(out_buf);
        if (crc.final() != expected_crc) {
            allocator.free(out_buf);
            continue;
        }
        total_extracted += uncomp_size;
        const name_dup = try allocator.dupe(u8, name);
        try blobs.append(allocator, .{ .name = name_dup, .bytes = out_buf });
        if (blobs.items.len >= max_frames + 16) break;
    }

    return convertBlobsToClassic(io, allocator, scratch, source_id, blobs.items);
}

/// Convert a local directory (Shimeji, GIF, or PNG sequence) into a staged Classic v1 package.
pub fn convertDirectoryToClassic(
    io: std.Io,
    allocator: std.mem.Allocator,
    source_dir: std.Io.Dir,
    scratch: std.Io.Dir,
    source_id: []const u8,
) !FormatKind {
    var blobs: std.ArrayListUnmanaged(NamedBlob) = .empty;
    defer {
        for (blobs.items) |b| {
            allocator.free(b.name);
            allocator.free(b.bytes);
        }
        blobs.deinit(allocator);
    }

    var total_read: usize = 0;
    try collectDirImages(io, allocator, source_dir, "", 0, &blobs, &total_read);
    return convertBlobsToClassic(io, allocator, scratch, source_id, blobs.items);
}

fn collectDirImages(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    prefix: []const u8,
    depth: u8,
    blobs: *std.ArrayListUnmanaged(NamedBlob),
    total_read: *usize,
) !void {
    if (depth > 2 or blobs.items.len >= max_frames + 16) return;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (blobs.items.len >= max_frames + 16) break;
        if (entry.kind == .directory) {
            if (depth < 2 and !std.mem.eql(u8, entry.name, "__MACOSX")) {
                const sub = dir.openDir(io, entry.name, .{ .follow_symlinks = false }) catch continue;
                defer sub.close(io);
                var next_prefix_buf: [256]u8 = undefined;
                const next_prefix = if (prefix.len == 0)
                    entry.name
                else
                    std.fmt.bufPrint(&next_prefix_buf, "{s}/{s}", .{ prefix, entry.name }) catch continue;
                try collectDirImages(io, allocator, sub, next_prefix, depth + 1, blobs, total_read);
            }
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.ascii.endsWithIgnoreCase(entry.name, ".png") and !std.ascii.endsWithIgnoreCase(entry.name, ".gif")) continue;
        const f = dir.openFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
        defer f.close(io);
        const st = f.stat(io) catch continue;
        if (st.kind != .file or st.size == 0 or st.size > max_image_bytes) continue;
        if (total_read.* + @as(usize, @intCast(st.size)) > max_source_bytes) continue;
        const buf = try allocator.alloc(u8, @intCast(st.size));
        const got = f.readPositionalAll(io, buf, 0) catch {
            allocator.free(buf);
            continue;
        };
        if (got != buf.len) {
            allocator.free(buf);
            continue;
        }
        total_read.* += buf.len;
        const full_name = if (prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        try blobs.append(allocator, .{ .name = full_name, .bytes = buf });
    }
}

test "VP8L lossless encoder passes strict Classic v1 preflight" {
    const atlas = try std.testing.allocator.alloc(u8, @as(usize, atlas_w) * @as(usize, atlas_h) * 4);
    defer std.testing.allocator.free(atlas);
    @memset(atlas, 0);
    // Paint a small colored patch with high-value green (>= 232) and low-value green (< 232).
    for (0..32) |y| {
        for (0..32) |x| {
            const p = atlas[(y * atlas_w + x) * 4 ..][0..4];
            p.* = .{ @intCast(x * 7), if ((x & 1) == 0) 245 else 80, @intCast(y * 7), 255 };
        }
    }
    const webp = try encodeWebpVp8l(std.testing.allocator, atlas_w, atlas_h, atlas);
    defer std.testing.allocator.free(webp);
    try assets.preflightWebp(.v1, webp);
    // RLE should compress mostly-transparent 11.5 MB atlas to well under 512 KiB.
    try std.testing.expect(webp.len < 512 * 1024);
}

test "deriveSourceId normalizes archive and image paths into valid OpenPets slugs" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hoodie-cat", out[0..deriveSourceId("C:\\Pets\\Hoodie_Cat.zip", &out)]);
    try std.testing.expectEqualStrings("shimeji-neko", out[0..deriveSourceId("D:\\Downloads\\Shimeji Neko.ZIP", &out)]);
    try std.testing.expectEqualStrings("nyan", out[0..deriveSourceId("C:\\gifs\\nyan.gif", &out)]);
    try std.testing.expectEqualStrings("pet-import", out[0..deriveSourceId("C:\\Pets\\中文桌宠.zip", &out)]);
    try std.testing.expect(inventory.validSource(out[0..deriveSourceId("C:\\Pets\\builtin.zip", &out)]));
}

test "GIF89a animated decoder extracts multi-frame RGBA and builds valid Classic v1 package" {
    // Minimal 2x2 2-frame GIF89a (red frame 0, transparent+blue frame 1).
    const gif = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        2, 0, 2, 0, // 2x2
        0x80, 0, 0, // GCT present (2 colors)
        0xff, 0x00, 0x00, // color 0: red
        0x00, 0x00, 0xff, // color 1: blue
        // Frame 0: solid red (all 0s)
        0x2c, 0,    0,
        0,    0,    2,
        0,    2,    0,
        0,
        2, // LZW min code size = 2
        2, 0x44, 0x01, // clear(4), 0, 0, 0, 0, eoi(5) -> packed LSB: 4(3b)=100, 0=000, 0=000, 0=000, 0=000, 5=101
        0,
        // Frame 1: solid blue (all 1s)
        0x2c, 0,
        0, 0,    0,
        2, 0,    2,
        0, 0,    2,
        2, 0x4c, 0x01,
        0, 0x3b,
    };
    const frames = try decodeGifFrames(std.testing.allocator, &gif);
    defer {
        for (frames) |*f| f.deinit(std.testing.allocator);
        std.testing.allocator.free(frames);
    }
    try std.testing.expectEqual(@as(usize, 2), frames.len);
    try std.testing.expectEqual(@as(u8, 255), frames[0].pixels[0]); // red R
    try std.testing.expectEqual(@as(u8, 0), frames[0].pixels[2]); // red B
    const meta = try formatClassicMetadata(std.testing.allocator, "nyan", "Nyan", "从 GIF 动图导入转换");
    defer std.testing.allocator.free(meta);
    const parsed = try assets.parseMetadata(std.testing.allocator, meta, "nyan");
    try std.testing.expectEqual(assets.Layout.v1, parsed.layout);
}
