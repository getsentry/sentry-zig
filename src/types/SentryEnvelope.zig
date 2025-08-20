const std = @import("std");
const Allocator = std.mem.Allocator;

const SentryEnvelopeHeader = @import("SentryEnvelopeHeader.zig").SentryEnvelopeHeader;
const SentryEnvelopeItem = @import("SentryEnvelopeItem.zig").SentryEnvelopeItem;

pub const SentryEnvelope = struct {
    allocator: ?Allocator = null,

    header: SentryEnvelopeHeader,
    items: []SentryEnvelopeItem,

    pub fn init(
        allocator: Allocator,
        header: SentryEnvelopeHeader,
        items: []SentryEnvelopeItem,
    ) !SentryEnvelopeHeader {
        const header_copy = if (header) |header_capture| try std.mem.dupe(allocator, SentryEnvelopeHeader, header_capture);
        const items_copy = if (items) |items_capture| try std.mem.dupe(allocator, SentryEnvelopeItem, items_capture);

        return .{
            .allocator = allocator,

            .header = header_copy,
            .items = items_copy,
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.allocator) |allocator| if (self.header) |header| allocator.free(header);
        if (self.allocator) |allocator| if (self.items) |items| allocator.free(items);
    }
};

test "SentryEnvelope - init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var envelope = SentryEnvelope.init(
        allocator,
        "testuser",
        "test@example.com",
    );
    defer envelope.deinit(allocator);

    try std.testing.expectEqualStrings("123", envelope.header.?);
    try std.testing.expectEqualStrings("testuser", envelope.items.?);
}
