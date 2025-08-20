const std = @import("std");
const Random = std.Random;
const Breadcrumb = @import("Breadcrumb.zig").Breadcrumb;
const User = @import("User.zig").User;
const Level = @import("Level.zig").Level;
const Request = @import("Request.zig").Request;
const Contexts = @import("Contexts.zig").Contexts;
const TraceId = @import("TraceId.zig").TraceId;
const SpanId = @import("SpanId.zig").SpanId;
const json_utils = @import("../utils/json_utils.zig");

// Thread-local PRNG for event ID generation with counter for uniqueness
threadlocal var event_id_prng: ?Random.DefaultPrng = null;
threadlocal var event_id_counter: u64 = 0;

/// UUID v4
pub const EventId = struct {
    value: [32]u8,

    pub fn jsonStringify(self: EventId, jw: anytype) !void {
        try jw.write(self.value);
    }

    pub fn new() EventId {
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

    pub fn deinit(self: *EventError, allocator: std.mem.Allocator) void {
        allocator.free(self.type);
        if (self.name) |name| allocator.free(name);
        if (self.value) |value| allocator.free(value);
        if (self.path) |path| allocator.free(path);
        if (self.details) |details| allocator.free(details);
    }
};

/// Exception interface
pub const Exception = struct {
    type: ?[]const u8 = null,
    value: ?[]const u8 = null,
    module: ?[]const u8 = null,
    thread_id: ?u64 = null,
    stacktrace: ?StackTrace = null,
    mechanism: ?Mechanism = null,

    pub fn deinit(self: *Exception, allocator: std.mem.Allocator) void {
        if (self.type) |exception_type| allocator.free(exception_type);
        if (self.value) |value| allocator.free(value);
        if (self.module) |module| allocator.free(module);
        if (self.stacktrace) |*stacktrace| stacktrace.deinit(allocator);
        if (self.mechanism) |*mechanism| mechanism.deinit(allocator);
    }
};

/// Stack trace interface
pub const StackTrace = struct {
    frames: []Frame,
    registers: ?std.StringHashMap([]const u8) = null,

    /// Custom JSON serialization to handle StringHashMap function pointer issues
    pub fn jsonStringify(self: StackTrace, jw: anytype) !void {
        try jw.beginObject();

        try jw.objectField("frames");
        try jw.write(self.frames);

        if (self.registers) |registers| {
            try jw.objectField("registers");
            try json_utils.serializeStringHashMap(registers, jw);
        }

        try jw.endObject();
    }

    pub fn deinit(self: *StackTrace, allocator: std.mem.Allocator) void {
        for (self.frames) |*frame| {
            frame.deinit(allocator);
        }
        allocator.free(self.frames);

        if (self.registers) |*registers| {
            var iterator = registers.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            registers.deinit();
        }
    }
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

    /// Custom JSON serialization to handle StringHashMap function pointer issues
    pub fn jsonStringify(self: Frame, jw: anytype) !void {
        try jw.beginObject();

        // All the simple optional fields
        if (self.filename) |v| {
            try jw.objectField("filename");
            try jw.write(v);
        }
        if (self.function) |v| {
            try jw.objectField("function");
            try jw.write(v);
        }
        if (self.module) |v| {
            try jw.objectField("module");
            try jw.write(v);
        }
        if (self.lineno) |v| {
            try jw.objectField("lineno");
            try jw.write(v);
        }
        if (self.colno) |v| {
            try jw.objectField("colno");
            try jw.write(v);
        }
        if (self.abs_path) |v| {
            try jw.objectField("abs_path");
            try jw.write(v);
        }
        if (self.context_line) |v| {
            try jw.objectField("context_line");
            try jw.write(v);
        }
        if (self.pre_context) |v| {
            try jw.objectField("pre_context");
            try jw.write(v);
        }
        if (self.post_context) |v| {
            try jw.objectField("post_context");
            try jw.write(v);
        }
        if (self.in_app) |v| {
            try jw.objectField("in_app");
            try jw.write(v);
        }
        if (self.package) |v| {
            try jw.objectField("package");
            try jw.write(v);
        }
        if (self.platform) |v| {
            try jw.objectField("platform");
            try jw.write(v);
        }
        if (self.image_addr) |v| {
            try jw.objectField("image_addr");
            try jw.write(v);
        }
        if (self.symbol) |v| {
            try jw.objectField("symbol");
            try jw.write(v);
        }
        if (self.symbol_addr) |v| {
            try jw.objectField("symbol_addr");
            try jw.write(v);
        }
        if (self.instruction_addr) |v| {
            try jw.objectField("instruction_addr");
            try jw.write(v);
        }

        // HashMap field
        if (self.vars) |vars| {
            try jw.objectField("vars");
            try json_utils.serializeStringHashMap(vars, jw);
        }

        try jw.endObject();
    }

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        if (self.filename) |filename| allocator.free(filename);
        if (self.function) |function| allocator.free(function);
        if (self.module) |module| allocator.free(module);
        if (self.abs_path) |abs_path| allocator.free(abs_path);
        if (self.context_line) |context_line| allocator.free(context_line);

        if (self.pre_context) |pre_context| {
            for (pre_context) |line| {
                allocator.free(line);
            }
            allocator.free(pre_context);
        }

        if (self.post_context) |post_context| {
            for (post_context) |line| {
                allocator.free(line);
            }
            allocator.free(post_context);
        }

        if (self.vars) |*vars| {
            var iterator = vars.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            vars.deinit();
        }

        if (self.package) |package| allocator.free(package);
        if (self.platform) |platform| allocator.free(platform);
        if (self.image_addr) |image_addr| allocator.free(image_addr);
        if (self.symbol) |symbol| allocator.free(symbol);
        if (self.symbol_addr) |symbol_addr| allocator.free(symbol_addr);
        if (self.instruction_addr) |instruction_addr| allocator.free(instruction_addr);
    }
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

    /// Custom JSON serialization to handle StringHashMap function pointer issues
    pub fn jsonStringify(self: Mechanism, jw: anytype) !void {
        try jw.beginObject();

        // Required field
        try jw.objectField("type");
        try jw.write(self.type);

        // Optional simple fields
        if (self.description) |v| {
            try jw.objectField("description");
            try jw.write(v);
        }
        if (self.help_link) |v| {
            try jw.objectField("help_link");
            try jw.write(v);
        }
        if (self.handled) |v| {
            try jw.objectField("handled");
            try jw.write(v);
        }
        if (self.synthetic) |v| {
            try jw.objectField("synthetic");
            try jw.write(v);
        }

        // HashMap fields
        if (self.data) |data| {
            try jw.objectField("data");
            try json_utils.serializeStringHashMap(data, jw);
        }
        if (self.meta) |meta| {
            try jw.objectField("meta");
            try json_utils.serializeStringHashMap(meta, jw);
        }

        try jw.endObject();
    }

    pub fn deinit(self: *Mechanism, allocator: std.mem.Allocator) void {
        allocator.free(self.type);
        if (self.description) |description| allocator.free(description);
        if (self.help_link) |help_link| allocator.free(help_link);

        if (self.data) |*data| {
            var iterator = data.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            data.deinit();
        }

        if (self.meta) |*meta| {
            var iterator = meta.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            meta.deinit();
        }
    }
};

/// Message interface
pub const Message = struct {
    message: []const u8,
    params: ?[][]const u8 = null,
    formatted: ?[]const u8 = null,

    /// Custom JSON serialization to ensure proper message serialization
    pub fn jsonStringify(self: Message, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("message");
        try jw.write(self.message);
        if (self.params) |v| {
            try jw.objectField("params");
            try jw.write(v);
        }
        if (self.formatted) |v| {
            try jw.objectField("formatted");
            try jw.write(v);
        }
        try jw.endObject();
    }

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.formatted) |formatted| allocator.free(formatted);

        if (self.params) |params| {
            for (params) |param| {
                allocator.free(param);
            }
            allocator.free(params);
        }
    }
};

/// Breadcrumbs interface
pub const Breadcrumbs = struct {
    values: []Breadcrumb,

    /// Custom JSON serialization to ensure proper breadcrumb serialization
    pub fn jsonStringify(self: Breadcrumbs, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("values");
        try jw.write(self.values);
        try jw.endObject();
    }

    pub fn deinit(self: *Breadcrumbs, allocator: std.mem.Allocator) void {
        for (self.values) |*breadcrumb| {
            breadcrumb.deinit(allocator);
        }
        allocator.free(self.values);
    }
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

    /// Custom JSON serialization to handle StringHashMap function pointer issues
    pub fn jsonStringify(self: Thread, jw: anytype) !void {
        try jw.beginObject();

        // Simple optional fields
        if (self.id) |v| {
            try jw.objectField("id");
            try jw.write(v);
        }
        if (self.name) |v| {
            try jw.objectField("name");
            try jw.write(v);
        }
        if (self.crashed) |v| {
            try jw.objectField("crashed");
            try jw.write(v);
        }
        if (self.current) |v| {
            try jw.objectField("current");
            try jw.write(v);
        }
        if (self.main) |v| {
            try jw.objectField("main");
            try jw.write(v);
        }
        if (self.stacktrace) |v| {
            try jw.objectField("stacktrace");
            try jw.write(v);
        }

        // HashMap field
        if (self.held_locks) |held_locks| {
            try jw.objectField("held_locks");
            try json_utils.serializeStringHashMap(held_locks, jw);
        }

        try jw.endObject();
    }

    pub fn deinit(self: *Thread, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        if (self.stacktrace) |*stacktrace| stacktrace.deinit(allocator);

        if (self.held_locks) |*held_locks| {
            var iterator = held_locks.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            held_locks.deinit();
        }
    }
};

/// Threads interface
pub const Threads = struct {
    values: []Thread,

    pub fn deinit(self: *Threads, allocator: std.mem.Allocator) void {
        for (self.values) |*thread| {
            thread.deinit(allocator);
        }
        allocator.free(self.values);
    }
};

/// SDK interface
pub const SDK = struct {
    name: []const u8,
    version: []const u8,
    integrations: ?[][]const u8 = null,
    packages: ?[]SDKPackage = null,

    pub fn deinit(self: *SDK, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);

        if (self.integrations) |integrations| {
            for (integrations) |integration| {
                allocator.free(integration);
            }
            allocator.free(integrations);
        }

        if (self.packages) |packages| {
            for (packages) |*package| {
                package.deinit(allocator);
            }
            allocator.free(packages);
        }
    }

    pub fn jsonStringify(self: SDK, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("version");
        try jw.write(self.version);
        if (self.integrations) |integrations| {
            try jw.objectField("integrations");
            try jw.write(integrations);
        }
        if (self.packages) |packages| {
            try jw.objectField("packages");
            try jw.write(packages);
        }
        try jw.endObject();
    }
};

/// SDK package
pub const SDKPackage = struct {
    name: []const u8,
    version: []const u8,

    pub fn deinit(self: *SDKPackage, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
    }
};

/// Debug meta interface
pub const DebugMeta = struct {
    images: ?[]DebugImage = null,
    sdk_info: ?SDKInfo = null,

    pub fn deinit(self: *DebugMeta, allocator: std.mem.Allocator) void {
        if (self.images) |images| {
            for (images) |*image| {
                image.deinit(allocator);
            }
            allocator.free(images);
        }
        if (self.sdk_info) |*sdk_info| {
            sdk_info.deinit(allocator);
        }
    }
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

    pub fn deinit(self: *DebugImage, allocator: std.mem.Allocator) void {
        allocator.free(self.type);
        if (self.image_addr) |image_addr| allocator.free(image_addr);
        if (self.debug_id) |debug_id| allocator.free(debug_id);
        if (self.debug_file) |debug_file| allocator.free(debug_file);
        if (self.code_id) |code_id| allocator.free(code_id);
        if (self.code_file) |code_file| allocator.free(code_file);
        if (self.image_vmaddr) |image_vmaddr| allocator.free(image_vmaddr);
        if (self.arch) |arch| allocator.free(arch);
        if (self.uuid) |uuid| allocator.free(uuid);
    }
};

/// SDK info
pub const SDKInfo = struct {
    sdk_name: ?[]const u8 = null,
    version_major: ?u32 = null,
    version_minor: ?u32 = null,
    version_patchlevel: ?u32 = null,

    pub fn deinit(self: *SDKInfo, allocator: std.mem.Allocator) void {
        if (self.sdk_name) |sdk_name| allocator.free(sdk_name);
    }
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

    pub fn deinit(self: *Template, allocator: std.mem.Allocator) void {
        if (self.filename) |filename| allocator.free(filename);
        if (self.name) |name| allocator.free(name);
        if (self.abs_path) |abs_path| allocator.free(abs_path);
        if (self.context_line) |context_line| allocator.free(context_line);

        if (self.pre_context) |pre_context| {
            for (pre_context) |line| {
                allocator.free(line);
            }
            allocator.free(pre_context);
        }

        if (self.post_context) |post_context| {
            for (post_context) |line| {
                allocator.free(line);
            }
            allocator.free(post_context);
        }
    }
};

/// Main Event struct containing all required and optional attributes and interfaces
pub const Event = struct {
    // Required attributes
    event_id: EventId,
    timestamp: f64,
    platform: []const u8 = "native",

    // Optional attributes
    type: ?[]const u8 = null,
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

    // Tracing attributes
    trace_id: ?TraceId = null,
    span_id: ?SpanId = null,
    parent_span_id: ?SpanId = null,

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

    /// Custom JSON serialization to handle StringHashMap function pointer issues
    pub fn jsonStringify(self: Event, jw: anytype) !void {
        try jw.beginObject();

        // Required fields
        try jw.objectField("event_id");
        try jw.write(self.event_id.value);
        try jw.objectField("timestamp");
        try jw.write(self.timestamp);
        try jw.objectField("platform");
        try jw.write(self.platform);

        // Optional type field
        if (self.type) |event_type| {
            try jw.objectField("type");
            try jw.write(event_type);
        }

        // Let std.json.stringify handle most optional fields
        if (self.level) |level| {
            try jw.objectField("level");
            try jw.write(@tagName(level));
        }
        if (self.logger) |logger| {
            try jw.objectField("logger");
            try jw.write(logger);
        }
        if (self.transaction) |transaction| {
            try jw.objectField("transaction");
            try jw.write(transaction);
        }
        if (self.server_name) |server_name| {
            try jw.objectField("server_name");
            try jw.write(server_name);
        }
        if (self.release) |release| {
            try jw.objectField("release");
            try jw.write(release);
        }
        if (self.dist) |dist| {
            try jw.objectField("dist");
            try jw.write(dist);
        }
        if (self.environment) |environment| {
            try jw.objectField("environment");
            try jw.write(environment);
        }
        if (self.fingerprint) |fingerprint| {
            try jw.objectField("fingerprint");
            try jw.write(fingerprint);
        }

        // Custom handling only for HashMap fields with function pointers
        if (self.tags) |tags| {
            try jw.objectField("tags");
            try json_utils.serializeStringHashMap(tags, jw);
        }

        if (self.modules) |modules| {
            try jw.objectField("modules");
            try json_utils.serializeStringHashMap(modules, jw);
        }

        // Handle other fields normally
        if (self.errors) |errors| {
            try jw.objectField("errors");
            try jw.write(errors);
        }
        if (self.exception) |exception| {
            try jw.objectField("exception");
            try jw.write(exception);
        }
        if (self.message) |message| {
            try jw.objectField("message");
            try jw.write(message);
        }
        if (self.template) |template| {
            try jw.objectField("template");
            try jw.write(template);
        }
        if (self.breadcrumbs) |breadcrumbs| {
            try jw.objectField("breadcrumbs");
            try jw.write(breadcrumbs);
        }
        if (self.user) |user| {
            try jw.objectField("user");
            try jw.write(user);
        }
        if (self.request) |request| {
            try jw.objectField("request");
            try jw.write(request);
        }
        if (self.threads) |threads| {
            try jw.objectField("threads");
            try jw.write(threads);
        }
        if (self.debug_meta) |debug_meta| {
            try jw.objectField("debug_meta");
            try jw.write(debug_meta);
        }
        if (self.sdk) |sdk| {
            try jw.objectField("sdk");
            try jw.write(sdk);
        }

        // Custom handling for fields with nested HashMap
        if (self.contexts) |contexts| {
            try jw.objectField("contexts");
            try json_utils.serializeNestedStringHashMap(contexts, jw);
        }

        if (self.stacktrace) |stacktrace| {
            try jw.objectField("stacktrace");
            try jw.write(stacktrace);
        }

        // Tracing fields
        if (self.trace_id) |trace_id| {
            try jw.objectField("trace_id");
            try jw.write(trace_id);
        }
        if (self.span_id) |span_id| {
            try jw.objectField("span_id");
            try jw.write(span_id);
        }
        if (self.parent_span_id) |parent_span_id| {
            try jw.objectField("parent_span_id");
            try jw.write(parent_span_id);
        }

        try jw.endObject();
    }

    pub fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        // Free platform if it's not the default literal
        if (!std.mem.eql(u8, self.platform, "native")) {
            allocator.free(self.platform);
        }

        // Free optional string attributes
        if (self.logger) |logger| allocator.free(logger);
        if (self.transaction) |transaction| allocator.free(transaction);
        if (self.server_name) |server_name| allocator.free(server_name);
        if (self.release) |release| allocator.free(release);
        if (self.dist) |dist| allocator.free(dist);
        if (self.environment) |environment| allocator.free(environment);

        // Free tags HashMap
        if (self.tags) |*tags| {
            var iterator = tags.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            tags.deinit();
        }

        // Free modules HashMap
        if (self.modules) |*modules| {
            var iterator = modules.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            modules.deinit();
        }

        // Free fingerprint slice
        if (self.fingerprint) |fingerprint| {
            for (fingerprint) |fp| {
                allocator.free(fp);
            }
            allocator.free(fingerprint);
        }

        // Free errors slice
        if (self.errors) |errors| {
            for (errors) |*error_item| {
                error_item.deinit(allocator);
            }
            allocator.free(errors);
        }

        // Free core interfaces
        if (self.exception) |*exception| exception.deinit(allocator);
        if (self.message) |*message| message.deinit(allocator);
        if (self.stacktrace) |*stacktrace| stacktrace.deinit(allocator);
        if (self.template) |*template| template.deinit(allocator);

        // Free scope interfaces
        if (self.breadcrumbs) |*breadcrumbs| breadcrumbs.deinit(allocator);
        if (self.user) |*user| user.deinit(allocator);
        if (self.request) |*request| request.deinit(allocator);
        if (self.contexts) |*contexts| @import("Contexts.zig").deinitContexts(contexts, allocator);
        if (self.threads) |*threads| threads.deinit(allocator);

        // Free other interfaces
        if (self.debug_meta) |*debug_meta| debug_meta.deinit(allocator);
        if (self.sdk) |*sdk| sdk.deinit(allocator);
    }
};
