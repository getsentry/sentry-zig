const std = @import("std");
const Random = std.Random;
const Breadcrumb = @import("breadcrumb.zig").Breadcrumb;
const User = @import("user.zig").User;
const Level = @import("enums.zig").Level;
const Request = @import("request.zig").Request;
const Contexts = @import("contexts.zig").Contexts;

// Thread-local PRNG for event ID generation with counter for uniqueness
threadlocal var event_id_prng: ?Random.DefaultPrng = null;
threadlocal var event_id_counter: u64 = 0;

/// UUID v4
pub const EventId = struct {
    value: [32]u8,

    fn new() EventId {
        // Initialize PRNG if not already done
        if (event_id_prng == null) {
            // Combine multiple sources for better seed entropy
            var seed: u64 = 0;
            seed ^= @as(u64, @intCast(std.time.nanoTimestamp()));
            seed ^= @as(u64, @intFromPtr(&event_id_counter));
            seed ^= std.Thread.getCurrentId();
            event_id_prng = Random.DefaultPrng.init(seed);
        }

        // Increment counter for additional uniqueness
        event_id_counter +%= 1;

        // Generate 16 random bytes (128 bits) for UUID v4
        var uuid_bytes: [16]u8 = undefined;
        const random = event_id_prng.?.random();
        random.bytes(&uuid_bytes);

        // Mix in the counter to ensure uniqueness even with same seed
        uuid_bytes[0] ^= @as(u8, @truncate(event_id_counter));
        uuid_bytes[1] ^= @as(u8, @truncate(event_id_counter >> 8));

        // Set version (4) and variant bits according to UUID v4 spec
        uuid_bytes[6] = (uuid_bytes[6] & 0x0F) | 0x40; // Version 4
        uuid_bytes[8] = (uuid_bytes[8] & 0x3F) | 0x80; // Variant 10

        // Convert to hex string (32 characters)
        var hex_id: [32]u8 = undefined;
        const hex_chars = "0123456789abcdef";

        for (uuid_bytes, 0..) |byte, i| {
            hex_id[i * 2] = hex_chars[byte >> 4];
            hex_id[i * 2 + 1] = hex_chars[byte & 0x0F];
        }

        return .{ .value = hex_id };
    }
};

/// A list of errors in capturing or handling this event. This provides meta data
/// about event capturing and processing itself, not about the error or
/// transaction that the event represents
pub const EventError = struct {
    type: []const u8,
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
    path: ?[]const u8 = null,
    details: ?[]const u8 = null,
};

/// Exception interface
pub const Exception = struct {
    type: ?[]const u8 = null,
    value: ?[]const u8 = null,
    module: ?[]const u8 = null,
    thread_id: ?u64 = null,
    stacktrace: ?StackTrace = null,
    mechanism: ?Mechanism = null,
};

/// Stack trace interface
pub const StackTrace = struct {
    frames: []Frame,
    registers: ?std.StringHashMap([]const u8) = null,
};

/// Stack frame
pub const Frame = struct {
    filename: ?[]const u8 = null,
    function: ?[]const u8 = null,
    module: ?[]const u8 = null,
    lineno: ?u32 = null,
    colno: ?u32 = null,
    abs_path: ?[]const u8 = null,
    context_line: ?[]const u8 = null,
    pre_context: ?[][]const u8 = null,
    post_context: ?[][]const u8 = null,
    in_app: ?bool = null,
    vars: ?std.StringHashMap([]const u8) = null,
    package: ?[]const u8 = null,
    platform: ?[]const u8 = null,
    image_addr: ?[]const u8 = null,
    symbol: ?[]const u8 = null,
    symbol_addr: ?[]const u8 = null,
    instruction_addr: ?[]const u8 = null,
};

/// Exception mechanism
pub const Mechanism = struct {
    type: []const u8,
    description: ?[]const u8 = null,
    help_link: ?[]const u8 = null,
    handled: ?bool = null,
    synthetic: ?bool = null,
    data: ?std.StringHashMap([]const u8) = null,
    meta: ?std.StringHashMap([]const u8) = null,
};

/// Message interface
pub const Message = struct {
    message: []const u8,
    params: ?[][]const u8 = null,
    formatted: ?[]const u8 = null,
};

/// Breadcrumbs interface
pub const Breadcrumbs = struct {
    values: []Breadcrumb,
};

/// Thread
pub const Thread = struct {
    id: ?u64 = null,
    name: ?[]const u8 = null,
    crashed: ?bool = null,
    current: ?bool = null,
    main: ?bool = null,
    stacktrace: ?StackTrace = null,
    held_locks: ?std.StringHashMap([]const u8) = null,
};

/// Threads interface
pub const Threads = struct {
    values: []Thread,
};

/// SDK interface
pub const SDK = struct {
    name: []const u8,
    version: []const u8,
    integrations: ?[][]const u8 = null,
    packages: ?[]SDKPackage = null,
};

/// SDK package
pub const SDKPackage = struct {
    name: []const u8,
    version: []const u8,
};

/// Debug meta interface
pub const DebugMeta = struct {
    images: ?[]DebugImage = null,
    sdk_info: ?SDKInfo = null,
};

/// Debug image
pub const DebugImage = struct {
    type: []const u8,
    image_addr: ?[]const u8 = null,
    image_size: ?u64 = null,
    debug_id: ?[]const u8 = null,
    debug_file: ?[]const u8 = null,
    code_id: ?[]const u8 = null,
    code_file: ?[]const u8 = null,
    image_vmaddr: ?[]const u8 = null,
    arch: ?[]const u8 = null,
    uuid: ?[]const u8 = null,
};

/// SDK info
pub const SDKInfo = struct {
    sdk_name: ?[]const u8 = null,
    version_major: ?u32 = null,
    version_minor: ?u32 = null,
    version_patchlevel: ?u32 = null,
};

/// Template interface
pub const Template = struct {
    filename: ?[]const u8 = null,
    name: ?[]const u8 = null,
    lineno: ?u32 = null,
    colno: ?u32 = null,
    abs_path: ?[]const u8 = null,
    context_line: ?[]const u8 = null,
    pre_context: ?[][]const u8 = null,
    post_context: ?[][]const u8 = null,
};

/// Main Event struct containing all required and optional attributes and interfaces
pub const Event = struct {
    // Required attributes
    event_id: EventId,
    timestamp: f64,
    platform: []const u8 = "native",

    // Optional attributes
    level: ?Level = null,
    logger: ?[]const u8 = null,
    transaction: ?[]const u8 = null,
    server_name: ?[]const u8 = null,
    release: ?[]const u8 = null,
    dist: ?[]const u8 = null,
    tags: ?std.StringHashMap([]const u8) = null,
    environment: ?[]const u8 = null,
    modules: ?std.StringHashMap([]const u8) = null,
    fingerprint: ?[][]const u8 = null,
    errors: ?[]EventError = null,

    // Core interfaces
    exception: ?Exception = null,
    message: ?Message = null,
    stacktrace: ?StackTrace = null,
    template: ?Template = null,

    // Scope interfaces
    breadcrumbs: ?Breadcrumbs = null,
    user: ?User = null,
    request: ?Request = null,
    contexts: ?Contexts = null,
    threads: ?Threads = null,

    // Other interfaces
    debug_meta: ?DebugMeta = null,
    sdk: ?SDK = null,
};
