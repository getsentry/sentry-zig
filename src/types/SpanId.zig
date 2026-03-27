const std = @import("std");
const Random = std.Random;

/// 8-byte span identifier (64 bits) used for distributed tracing
pub const SpanId = struct {
    bytes: [8]u8,

    /// Generate a new random SpanId
    pub fn generate() SpanId {
        var span_id = SpanId{ .bytes = undefined };

        // Use a combination of timestamp and thread ID for seed
        var seed: u64 = 0;
        seed ^= @as(u64, @intCast(std.time.nanoTimestamp()));
        seed ^= std.Thread.getCurrentId();

        var prng = Random.DefaultPrng.init(seed);
        prng.random().bytes(&span_id.bytes);

        return span_id;
    }

    /// Create SpanId from hex string (16 characters)
    pub fn fromHex(hex_str: []const u8) !SpanId {
        if (hex_str.len != 16) {
            return error.InvalidSpanIdLength;
        }

        var span_id = SpanId{ .bytes = undefined };

        for (0..8) |i| {
            const high_nibble = try std.fmt.charToDigit(hex_str[i * 2], 16);
            const low_nibble = try std.fmt.charToDigit(hex_str[i * 2 + 1], 16);
            span_id.bytes[i] = (high_nibble << 4) | low_nibble;
        }

        return span_id;
    }

    /// Convert SpanId to hex string (allocates)
    pub fn toHex(self: SpanId, allocator: std.mem.Allocator) ![]u8 {
        const hex_str = try allocator.alloc(u8, 16);
        self.toHexBuf(hex_str);
        return hex_str;
    }

    /// Convert SpanId to hex string into provided buffer (must be 16 bytes)
    pub fn toHexBuf(self: SpanId, buf: []u8) void {
        std.debug.assert(buf.len >= 16);
        const hex_chars = "0123456789abcdef";

        for (self.bytes, 0..) |byte, i| {
            buf[i * 2] = hex_chars[byte >> 4];
            buf[i * 2 + 1] = hex_chars[byte & 0x0F];
        }
    }

    /// Convert to a fixed-size hex string (for JSON serialization)
    pub fn toHexFixed(self: SpanId) [16]u8 {
        var result: [16]u8 = undefined;
        self.toHexBuf(&result);
        return result;
    }

    /// Check if span ID is nil (all zeros)
    pub fn isNil(self: SpanId) bool {
        for (self.bytes) |b| {
            if (b != 0) return false;
        }
        return true;
    }

    /// Create a nil (all zeros) SpanId
    pub fn nil() SpanId {
        return SpanId{ .bytes = [_]u8{0} ** 8 };
    }

    /// JSON serialization
    pub fn jsonStringify(self: SpanId, jw: anytype) !void {
        const hex_str = self.toHexFixed();
        try jw.write(hex_str);
    }

    /// Compare two SpanIds for equality
    pub fn eql(self: SpanId, other: SpanId) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

test "SpanId generation" {
    const span_id1 = SpanId.generate();
    const span_id2 = SpanId.generate();

    // Should not be nil
    try std.testing.expect(!span_id1.isNil());
    try std.testing.expect(!span_id2.isNil());

    // Should be different (very likely)
    try std.testing.expect(!span_id1.eql(span_id2));
}

test "SpanId hex conversion" {
    const allocator = std.testing.allocator;

    const original = SpanId.generate();
    const hex_str = try original.toHex(allocator);
    defer allocator.free(hex_str);

    try std.testing.expectEqual(@as(usize, 16), hex_str.len);

    const reconstructed = try SpanId.fromHex(hex_str);
    try std.testing.expect(original.eql(reconstructed));
}

test "SpanId nil operations" {
    const nil_id = SpanId.nil();
    try std.testing.expect(nil_id.isNil());

    const non_nil = SpanId.generate();
    try std.testing.expect(!non_nil.isNil());
    try std.testing.expect(!nil_id.eql(non_nil));
}

test "SpanId hex buffer operations" {
    const span_id = SpanId.generate();

    // Test toHexFixed
    const hex_fixed = span_id.toHexFixed();
    try std.testing.expectEqual(@as(usize, 16), hex_fixed.len);

    // Test toHexBuf
    var buf: [16]u8 = undefined;
    span_id.toHexBuf(&buf);
    try std.testing.expect(std.mem.eql(u8, &hex_fixed, &buf));
}

test "SpanId invalid hex" {
    try std.testing.expectError(error.InvalidSpanIdLength, SpanId.fromHex("short"));
    try std.testing.expectError(error.InvalidSpanIdLength, SpanId.fromHex("toolongtoolong"));
    try std.testing.expectError(error.InvalidCharacter, SpanId.fromHex("gggggggggggggggg"));
}
