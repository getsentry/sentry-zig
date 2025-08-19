const std = @import("std");
const Allocator = std.mem.Allocator;

const SentryEnvelopeItemHeader = @import("SentryEnvelopeItemHeader.zig").SentryEnvelopeItemHeader;

pub const SentryEnvelopeItem = struct {
    header: SentryEnvelopeItemHeader,
    data: []u8,
};
