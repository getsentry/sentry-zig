const std = @import("std");
const Allocator = std.mem.Allocator;

const SentryItemType = @import("SentryItemType.zig").SentryItemType;

pub const SentryEnvelopeItemHeader = struct {
    type: SentryItemType,
    length: i64,
    content_type: ?[]const u8 = null,
    file_name: ?[]const u8 = null,
    attachment_type: ?[]const u8 = null,
    platform: ?[]const u8 = null,
    item_count: ?i64 = null,

    /// Custom JSON serialization to omit null optional fields
    pub fn jsonStringify(self: SentryEnvelopeItemHeader, jw: anytype) !void {
        try jw.beginObject();

        // Required fields
        try jw.objectField("type");
        try jw.write(@tagName(self.type));
        try jw.objectField("length");
        try jw.write(self.length);

        // Optional fields - only include if not null
        if (self.content_type) |content_type| {
            try jw.objectField("content_type");
            try jw.write(content_type);
        }
        if (self.file_name) |file_name| {
            try jw.objectField("file_name");
            try jw.write(file_name);
        }
        if (self.attachment_type) |attachment_type| {
            try jw.objectField("attachment_type");
            try jw.write(attachment_type);
        }
        if (self.platform) |platform| {
            try jw.objectField("platform");
            try jw.write(platform);
        }
        if (self.item_count) |item_count| {
            try jw.objectField("item_count");
            try jw.write(item_count);
        }

        try jw.endObject();
    }
};
