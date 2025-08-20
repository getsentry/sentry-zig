const std = @import("std");
const Allocator = std.mem.Allocator;

const SentryItemType = @import("SentryItemType.zig").SentryItemType;

pub const SentryEnvelopeItemHeader = struct {
    allocator: ?Allocator = null,

    type: SentryItemType,
    length: i64,
    content_type: ?[]const u8 = null,
    file_name: ?[]const u8 = null,
    attachment_type: ?[]const u8 = null,
    platform: ?[]const u8 = null,
    item_count: ?i64 = null,

    pub fn init(
        allocator: Allocator,
        @"type": SentryItemType,
        length: i64,
        content_type: ?[]const u8,
        file_name: ?[]const u8,
        attachment_type: ?[]const u8,
        platform: ?[]const u8,
        item_count: ?i64,
    ) !@This() {
        const type_copy = if (@"type") |type_capture| try allocator.dupe(u8, type_capture);
        const content_type_copy = if (content_type) |content_type_capture| try allocator.dupe(u8, content_type_capture);
        const file_name_copy = if (file_name) |file_name_capture| try allocator.dupe(u8, file_name_capture);
        const attachment_type_copy = if (attachment_type) |attachment_type_capture| try allocator.dupe(u8, attachment_type_capture);
        const platform_copy = if (platform) |platform_capture| try allocator.dupe(u8, platform_capture);

        return .{
            .allocator = allocator,
            .type = type_copy,
            .length = length,
            .content_type = content_type_copy,
            .file_name = file_name_copy,
            .attachment_type = attachment_type_copy,
            .platform = platform_copy,
            .item_count = item_count,
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.allocator) |allocator| if (self.type) |@"type"| allocator.free(@"type");

        if (self.allocator) |allocator| if (self.content_type) |content_type| allocator.free(content_type);
        if (self.allocator) |allocator| if (self.file_name) |file_name| allocator.free(file_name);
        if (self.allocator) |allocator| if (self.attachment_type) |attachment_type| allocator.free(attachment_type);
        if (self.allocator) |allocator| if (self.platform) |platform| allocator.free(platform);
    }

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
