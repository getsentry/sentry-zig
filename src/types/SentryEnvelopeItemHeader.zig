const std = @import("std");
const Allocator = std.mem.Allocator;

const SentryItemType = @import("../Types.zig").SentryItemType;

pub const SentryEnvelopeItemHeader = struct {
    type: SentryItemType,
    length: i64,
    content_type: ?[]const u8 = null,
    file_name: ?[]const u8 = null,
    attachment_type: ?[]const u8 = null,
    platform: ?[]const u8 = null,
    item_count: ?i64 = null,
};
