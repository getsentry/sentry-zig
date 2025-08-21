const std = @import("std");
const Allocator = std.mem.Allocator;

const SentryEnvelopeItemHeader = @import("SentryEnvelopeItemHeader.zig").SentryEnvelopeItemHeader;

pub const SentryEnvelopeItem = struct {
    allocator: ?Allocator = null,

    header: SentryEnvelopeItemHeader,
    data: []u8,

    pub fn init(
        allocator: Allocator,
        header: SentryEnvelopeItemHeader,
        data: []u8,
    ) !SentryEnvelopeItemHeader {
        const header_copy = try allocator.dupe(u8, header);
        const data_copy = try allocator.dupe(u8, data);

        return .{
            .allocator = allocator,

            .header = header_copy,
            .data = data_copy,
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.allocator) |allocator| allocator.free(self.header);
        if (self.allocator) |allocator| allocator.free(self.data);
    }
};
