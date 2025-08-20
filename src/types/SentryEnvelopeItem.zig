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
        const header_copy = if (header) |header_capture| try std.mem.dupe(allocator, u8, header_capture);
        const data_copy = if (data) |data_capture| try std.mem.dupe(allocator, u8, data_capture);

        return .{
            .allocator = allocator,

            .header = header_copy,
            .data = data_copy,
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.allocator) |allocator| if (self.header) |header| allocator.free(header);
        if (self.allocator) |allocator| if (self.data) |data| allocator.free(data);
    }
};
