const std = @import("std");
const Random = std.Random;

/// 16-byte trace identifier (128 bits) used for distributed tracing
pub const TraceId = struct {
    bytes: [16]u8,

    /// Generate a new random TraceId
    pub fn generate() TraceId {
        var trace_id = TraceId{ .bytes = undefined };

        // Use a combination of timestamp and thread ID for seed
        var seed: u64 = 0;
        seed ^= @as(u64, @intCast(std.time.nanoTimestamp()));
        seed ^= std.Thread.getCurrentId();

        var prng = Random.DefaultPrng.init(seed);
        prng.random().bytes(&trace_id.bytes);

        return trace_id;
    }

    /// Create TraceId from hex string (32 characters)
    pub fn fromHex(hex_str: []const u8) !TraceId {
        if (hex_str.len != 32) {
            return error.InvalidTraceIdLength;
        }

        var trace_id = TraceId{ .bytes = undefined };

        for (0..16) |i| {
            const high_nibble = try std.fmt.charToDigit(hex_str[i * 2], 16);
            const low_nibble = try std.fmt.charToDigit(hex_str[i * 2 + 1], 16);
            trace_id.bytes[i] = (high_nibble << 4) | low_nibble;
        }

        return trace_id;
    }

    /// Convert TraceId to hex string (allocates)
    pub fn toHex(self: TraceId, allocator: std.mem.Allocator) ![]u8 {
        const hex_str = try allocator.alloc(u8, 32);
        self.toHexBuf(hex_str);
        return hex_str;
    }

    /// Convert TraceId to hex string into provided buffer (must be 32 bytes)
    pub fn toHexBuf(self: TraceId, buf: []u8) void {
        std.debug.assert(buf.len >= 32);
        const hex_chars = "0123456789abcdef";

        for (self.bytes, 0..) |byte, i| {
            buf[i * 2] = hex_chars[byte >> 4];
            buf[i * 2 + 1] = hex_chars[byte & 0x0F];
        }
    }

    /// Convert to a fixed-size hex string (for JSON serialization)
    pub fn toHexFixed(self: TraceId) [32]u8 {
        var result: [32]u8 = undefined;
        self.toHexBuf(&result);
        return result;
    }

    /// Check if trace ID is nil (all zeros)
    pub fn isNil(self: TraceId) bool {
        for (self.bytes) |b| {
            if (b != 0) return false;
        }
        return true;
    }

    /// Create a nil (all zeros) TraceId
    pub fn nil() TraceId {
        return TraceId{ .bytes = [_]u8{0} ** 16 };
    }

    /// JSON serialization
    pub fn jsonStringify(self: TraceId, jw: anytype) !void {
        const hex_str = self.toHexFixed();
        try jw.write(hex_str);
    }

    /// Compare two TraceIds for equality
    pub fn eql(self: TraceId, other: TraceId) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

test "TraceId generation" {
    const trace_id1 = TraceId.generate();
    const trace_id2 = TraceId.generate();

    // Should not be nil
    try std.testing.expect(!trace_id1.isNil());
    try std.testing.expect(!trace_id2.isNil());

    // Should be different
    try std.testing.expect(!trace_id1.eql(trace_id2));
}

test "TraceId hex conversion" {
    const allocator = std.testing.allocator;

    const original = TraceId.generate();
    const hex_str = try original.toHex(allocator);
    defer allocator.free(hex_str);

    try std.testing.expectEqual(@as(usize, 32), hex_str.len);

    const reconstructed = try TraceId.fromHex(hex_str);
    try std.testing.expect(original.eql(reconstructed));
}

test "TraceId nil operations" {
    const nil_id = TraceId.nil();
    try std.testing.expect(nil_id.isNil());

    const non_nil = TraceId.generate();
    try std.testing.expect(!non_nil.isNil());
    try std.testing.expect(!nil_id.eql(non_nil));
}

test "TraceId hex buffer operations" {
    const trace_id = TraceId.generate();

    // Test toHexFixed
    const hex_fixed = trace_id.toHexFixed();
    try std.testing.expectEqual(@as(usize, 32), hex_fixed.len);

    // Test toHexBuf
    var buf: [32]u8 = undefined;
    trace_id.toHexBuf(&buf);
    try std.testing.expect(std.mem.eql(u8, &hex_fixed, &buf));
}

test "TraceId invalid hex" {
    try std.testing.expectError(error.InvalidTraceIdLength, TraceId.fromHex("short"));
    try std.testing.expectError(error.InvalidTraceIdLength, TraceId.fromHex("toolongtoolongtoolongtoolong"));
    try std.testing.expectError(error.InvalidCharacter, TraceId.fromHex("gggggggggggggggggggggggggggggggg"));
}
