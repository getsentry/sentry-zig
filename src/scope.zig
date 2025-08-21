const std = @import("std");
const types = @import("types");

// Top-level type aliases
const User = types.User;
const Breadcrumb = types.Breadcrumb;
const BreadcrumbType = types.BreadcrumbType;
const Level = types.Level;
const Event = types.Event;
const EventId = @import("types").EventId;
const Contexts = types.Contexts;
const TraceId = types.TraceId;
const SpanId = types.SpanId;
const PropagationContext = types.PropagationContext;
const Span = types.Span;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const RwLock = std.Thread.RwLock;
const testing = std.testing;
const SentryClient = @import("client.zig").SentryClient;

pub const ScopeType = enum {
    isolation,
    current,
    global,
};

/// Core scope structure containing contextual data
pub const Scope = struct {
    allocator: Allocator,
    level: Level,
    tags: std.StringHashMap([]const u8),
    user: ?User,
    fingerprint: ?ArrayList([]const u8),
    breadcrumbs: ArrayList(Breadcrumb),
    contexts: std.StringHashMap(std.StringHashMap([]const u8)),
    client: ?*SentryClient,

    // Tracing context
    propagation_context: PropagationContext,
    span: ?*anyopaque = null,

    const MAX_BREADCRUMBS = 100;

    pub fn init(allocator: Allocator) Scope {
        return Scope{
            .allocator = allocator,
            .level = Level.info,
            .tags = std.StringHashMap([]const u8).init(allocator),
            .user = null,
            .fingerprint = null,
            .breadcrumbs = ArrayList(Breadcrumb).init(allocator),
            .contexts = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
            .client = null,
            .propagation_context = PropagationContext.generate(),
            .span = null,
        };
    }

    pub fn deinit(self: *Scope) void {
        var tag_iterator = self.tags.iterator();
        while (tag_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.tags.deinit();

        if (self.user) |*user| {
            user.deinit();
        }

        if (self.fingerprint) |*fp| {
            for (fp.items) |item| {
                self.allocator.free(item);
            }
            fp.deinit();
        }

        for (self.breadcrumbs.items) |*crumb| {
            crumb.deinit(self.allocator);
        }
        self.breadcrumbs.deinit();

        var context_iterator = self.contexts.iterator();
        while (context_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var inner_iterator = entry.value_ptr.iterator();
            while (inner_iterator.next()) |inner_entry| {
                self.allocator.free(inner_entry.key_ptr.*);
                self.allocator.free(inner_entry.value_ptr.*);
            }
            entry.value_ptr.deinit();
        }
        self.contexts.deinit();
    }

    /// Fork a scope
    pub fn fork(self: *const Scope) !Scope {
        var new_scope = Scope.init(self.allocator);

        new_scope.level = self.level;

        var tag_iterator = self.tags.iterator();
        while (tag_iterator.next()) |entry| {
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            const value = try self.allocator.dupe(u8, entry.value_ptr.*);
            try new_scope.tags.put(key, value);
        }

        if (self.user) |user| {
            new_scope.user = try user.clone(self.allocator);
        }

        if (self.fingerprint) |fp| {
            new_scope.fingerprint = ArrayList([]const u8).init(self.allocator);
            for (fp.items) |item| {
                const copied_item = try self.allocator.dupe(u8, item);
                try new_scope.fingerprint.?.append(copied_item);
            }
        }

        for (self.breadcrumbs.items) |crumb| {
            var new_crumb = Breadcrumb{
                .message = try self.allocator.dupe(u8, crumb.message),
                .type = crumb.type,
                .level = crumb.level,
                .category = if (crumb.category) |cat| try self.allocator.dupe(u8, cat) else null,
                .timestamp = crumb.timestamp,
                .data = null,
            };

            if (crumb.data) |data| {
                new_crumb.data = std.StringHashMap([]const u8).init(self.allocator);
                var data_iterator = data.iterator();
                while (data_iterator.next()) |entry| {
                    const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                    const value = try self.allocator.dupe(u8, entry.value_ptr.*);
                    try new_crumb.data.?.put(key, value);
                }
            }

            try new_scope.breadcrumbs.append(new_crumb);
        }

        var context_iterator = self.contexts.iterator();
        while (context_iterator.next()) |entry| {
            const context_key = try self.allocator.dupe(u8, entry.key_ptr.*);
            var new_context = std.StringHashMap([]const u8).init(self.allocator);

            var inner_iterator = entry.value_ptr.iterator();
            while (inner_iterator.next()) |inner_entry| {
                const key = try self.allocator.dupe(u8, inner_entry.key_ptr.*);
                const value = try self.allocator.dupe(u8, inner_entry.value_ptr.*);
                try new_context.put(key, value);
            }

            try new_scope.contexts.put(context_key, new_context);
        }

        new_scope.propagation_context = self.propagation_context.clone();

        return new_scope;
    }

    /// Set a tag
    pub fn setTag(self: *Scope, key: []const u8, value: []const u8) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        if (self.tags.fetchRemove(key)) |old_entry| {
            self.allocator.free(old_entry.key);
            self.allocator.free(old_entry.value);
        }

        try self.tags.put(owned_key, owned_value);
    }

    /// Clear all set tags
    pub fn removeTags(self: *Scope) void {
        var tag_iterator = self.tags.iterator();
        while (tag_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.tags.clearRetainingCapacity();
    }

    /// Set user information
    pub fn setUser(self: *Scope, user: User) void {
        if (self.user) |*old_user| {
            old_user.deinit();
        }
        self.user = user;
    }

    /// Set fingerprint (clones all strings)
    pub fn setFingerprint(self: *Scope, fingerprint_items: []const []const u8) !void {
        // Clean up existing fingerprint
        if (self.fingerprint) |*fp| {
            for (fp.items) |item| {
                self.allocator.free(item);
            }
            fp.deinit();
        }

        // Create new fingerprint with cloned strings
        self.fingerprint = ArrayList([]const u8).init(self.allocator);
        for (fingerprint_items) |item| {
            const cloned_item = try self.allocator.dupe(u8, item);
            try self.fingerprint.?.append(cloned_item);
        }
    }

    /// Add a breadcrumb
    pub fn addBreadcrumb(self: *Scope, breadcrumb: Breadcrumb) !void {
        if (self.breadcrumbs.items.len >= MAX_BREADCRUMBS) {
            var oldest = self.breadcrumbs.orderedRemove(0);
            oldest.deinit(self.allocator);
        }

        var cloned_breadcrumb = Breadcrumb{
            .message = try self.allocator.dupe(u8, breadcrumb.message),
            .type = breadcrumb.type,
            .level = breadcrumb.level,
            .category = if (breadcrumb.category) |cat| try self.allocator.dupe(u8, cat) else null,
            .timestamp = breadcrumb.timestamp,
            .data = null,
        };

        if (breadcrumb.data) |data| {
            cloned_breadcrumb.data = std.StringHashMap([]const u8).init(self.allocator);
            var data_iterator = data.iterator();
            while (data_iterator.next()) |entry| {
                const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                const value = try self.allocator.dupe(u8, entry.value_ptr.*);
                try cloned_breadcrumb.data.?.put(key, value);
            }
        }

        try self.breadcrumbs.append(cloned_breadcrumb);
    }

    /// Clear all breadcrumbs
    pub fn clearBreadcrumbs(self: *Scope) void {
        for (self.breadcrumbs.items) |*crumb| {
            crumb.deinit(self.allocator);
        }
        self.breadcrumbs.clearRetainingCapacity();
    }

    /// Set context data
    pub fn setContext(self: *Scope, key: []const u8, context_data: std.StringHashMap([]const u8)) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        if (self.contexts.fetchRemove(key)) |old_entry| {
            self.allocator.free(old_entry.key);
            var old_value = old_entry.value;
            var iterator = old_value.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            old_value.deinit();
        }

        var cloned_context = std.StringHashMap([]const u8).init(self.allocator);
        var context_iterator = context_data.iterator();
        while (context_iterator.next()) |entry| {
            const cloned_key = try self.allocator.dupe(u8, entry.key_ptr.*);
            const cloned_value = try self.allocator.dupe(u8, entry.value_ptr.*);
            try cloned_context.put(cloned_key, cloned_value);
        }

        try self.contexts.put(owned_key, cloned_context);
    }

    fn applyToEvent(self: *const Scope, event: *Event) !void {
        self.applyLevelToEvent(event);
        try self.applyTagsToEvent(event);
        try self.applyUserToEvent(event);
        try self.applyFingerprintToEvent(event);
        try self.applyBreadcrumbsToEvent(event);
        try self.applyContextsToEvent(event);
        self.applyTracingToEvent(event);
    }

    fn applyLevelToEvent(self: *const Scope, event: *Event) void {
        if (event.level == null and self.level != .info) {
            event.level = self.level;
        }
    }

    fn applyTagsToEvent(self: *const Scope, event: *Event) !void {
        if (self.tags.count() == 0) return;

        if (event.tags == null) {
            event.tags = std.StringHashMap([]const u8).init(self.allocator);
        }

        var tag_iterator = self.tags.iterator();
        while (tag_iterator.next()) |entry| {
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            const value = try self.allocator.dupe(u8, entry.value_ptr.*);
            try event.tags.?.put(key, value);
        }
    }

    fn applyUserToEvent(self: *const Scope, event: *Event) !void {
        if (event.user == null and self.user != null) {
            event.user = try self.user.?.clone(self.allocator);
        }
    }

    fn applyFingerprintToEvent(self: *const Scope, event: *Event) !void {
        if (event.fingerprint == null and self.fingerprint != null) {
            var fingerprint = try self.allocator.alloc([]const u8, self.fingerprint.?.items.len);
            for (self.fingerprint.?.items, 0..) |fp, i| {
                fingerprint[i] = try self.allocator.dupe(u8, fp);
            }
            event.fingerprint = fingerprint;
        }
    }

    fn applyBreadcrumbsToEvent(self: *const Scope, event: *Event) !void {
        if (self.breadcrumbs.items.len == 0) return;

        const Breadcrumbs = types.Breadcrumbs;
        const existing_count = if (event.breadcrumbs) |b| b.values.len else 0;
        const total_count = existing_count + self.breadcrumbs.items.len;

        var all_breadcrumbs = try self.allocator.alloc(Breadcrumb, total_count);

        if (event.breadcrumbs) |existing| {
            for (existing.values, 0..) |crumb, i| {
                all_breadcrumbs[i] = crumb;
            }

            self.allocator.free(existing.values);
        }

        for (self.breadcrumbs.items, existing_count..) |crumb, i| {
            var cloned_crumb = Breadcrumb{
                .message = try self.allocator.dupe(u8, crumb.message),
                .type = crumb.type,
                .level = crumb.level,
                .category = if (crumb.category) |cat| try self.allocator.dupe(u8, cat) else null,
                .timestamp = crumb.timestamp,
                .data = null,
            };

            if (crumb.data) |data| {
                cloned_crumb.data = std.StringHashMap([]const u8).init(self.allocator);
                var data_iterator = data.iterator();
                while (data_iterator.next()) |entry| {
                    const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                    const value = try self.allocator.dupe(u8, entry.value_ptr.*);
                    try cloned_crumb.data.?.put(key, value);
                }
            }

            all_breadcrumbs[i] = cloned_crumb;
        }

        event.breadcrumbs = Breadcrumbs{ .values = all_breadcrumbs };
    }

    fn applyContextsToEvent(self: *const Scope, event: *Event) !void {
        if (self.contexts.count() == 0) return;

        if (event.contexts == null) {
            event.contexts = Contexts.init(self.allocator);
        }

        var context_iterator = self.contexts.iterator();
        while (context_iterator.next()) |entry| {
            // Check if this context already exists in the event
            if (event.contexts.?.contains(entry.key_ptr.*)) {
                continue; // Event contexts take precedence
            }

            const context_key = try self.allocator.dupe(u8, entry.key_ptr.*);
            var context_data = std.StringHashMap([]const u8).init(self.allocator);

            var inner_iterator = entry.value_ptr.iterator();
            while (inner_iterator.next()) |inner_entry| {
                const key = try self.allocator.dupe(u8, inner_entry.key_ptr.*);
                const value = try self.allocator.dupe(u8, inner_entry.value_ptr.*);
                try context_data.put(key, value);
            }

            try event.contexts.?.put(context_key, context_data);
        }
    }

    fn applyTracingToEvent(self: *const Scope, event: *Event) void {
        // Apply tracing context if event doesn't already have it
        if (event.trace_id == null) {
            event.trace_id = self.propagation_context.trace_id;
        }
        if (event.span_id == null) {
            event.span_id = self.propagation_context.span_id;
        }
        if (event.parent_span_id == null) {
            event.parent_span_id = self.propagation_context.parent_span_id;
        }
    }

    /// Set trace context (equivalent to sentry_set_trace in Native SDK)
    pub fn setTrace(self: *Scope, trace_id: TraceId, span_id: SpanId, parent_span_id: ?SpanId) void {
        self.propagation_context.updateFromTrace(trace_id, span_id, parent_span_id);
    }

    /// Get the current propagation context
    pub fn getPropagationContext(self: *const Scope) PropagationContext {
        return self.propagation_context.clone();
    }

    /// Merge another scope into this one (other scope takes precedence)
    pub fn merge(self: *Scope, other: *const Scope) !void {
        // Merge level (other scope takes precedence)
        self.level = other.level;

        // Merge tags
        var tag_iterator = other.tags.iterator();
        while (tag_iterator.next()) |entry| {
            try self.setTag(entry.key_ptr.*, entry.value_ptr.*);
        }

        // Override user if other has one
        if (other.user) |user| {
            const cloned_user = try user.clone(self.allocator);
            self.setUser(cloned_user);
        }

        // Merge breadcrumbs
        for (other.breadcrumbs.items) |crumb| {
            var cloned_crumb = Breadcrumb{
                .message = try self.allocator.dupe(u8, crumb.message),
                .type = crumb.type,
                .level = crumb.level,
                .category = if (crumb.category) |cat| try self.allocator.dupe(u8, cat) else null,
                .timestamp = crumb.timestamp,
                .data = null,
            };

            if (crumb.data) |data| {
                cloned_crumb.data = std.StringHashMap([]const u8).init(self.allocator);
                var data_iterator = data.iterator();
                while (data_iterator.next()) |entry| {
                    const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                    const value = try self.allocator.dupe(u8, entry.value_ptr.*);
                    try cloned_crumb.data.?.put(key, value);
                }
            }

            try self.addBreadcrumb(cloned_crumb);
        }

        // Merge propagation context (other scope takes precedence)
        self.propagation_context = other.propagation_context.clone();
    }

    pub fn bindClient(self: *Scope, client: *SentryClient) void {
        self.client = client;
    }

    /// Set the current span or transaction on this scope
    pub fn setSpan(self: *Scope, span_or_transaction: ?*anyopaque) void {
        self.span = span_or_transaction;
    }

    /// Get the current span or transaction from this scope
    pub fn getSpan(self: *const Scope) ?*anyopaque {
        return self.span;
    }

    /// Generate sentry-trace header from current span/transaction
    pub fn traceHeaders(self: *const Scope, allocator: std.mem.Allocator) !?[]u8 {
        if (self.span) |span_ptr| {
            // Use the active span's trace information
            const span: *Span = @ptrCast(@alignCast(span_ptr));
            return try span.toSentryTrace(allocator);
        }

        // Fall back to propagation context if no active span
        const trace_hex = self.propagation_context.trace_id.toHexFixed();
        const span_hex = self.propagation_context.span_id.toHexFixed();
        return try std.fmt.allocPrint(allocator, "{s}-{s}", .{ trace_hex, span_hex });
    }
};

var global_scope: ?*Scope = null;
var global_scope_mutex = Mutex{};

threadlocal var thread_isolation_scope: ?*Scope = null;
threadlocal var thread_current_scope_stack: ?*ArrayList(*Scope) = null;

const ScopeManager = struct {
    allocator: Allocator,

    fn init(allocator: Allocator) ScopeManager {
        return .{
            .allocator = allocator,
        };
    }

    fn deinit(self: *ScopeManager) void {
        _ = self;
    }

    fn getGlobalScope(self: *ScopeManager) !*Scope {
        global_scope_mutex.lock();
        defer global_scope_mutex.unlock();

        if (global_scope == null) {
            const scope = try self.allocator.create(Scope);
            scope.* = Scope.init(self.allocator);
            global_scope = scope;
        }

        return global_scope.?;
    }

    fn getIsolationScope(self: *ScopeManager) !*Scope {
        if (thread_isolation_scope == null) {
            const scope = try self.allocator.create(Scope);
            scope.* = Scope.init(self.allocator);
            thread_isolation_scope = scope;
        }

        return thread_isolation_scope.?;
    }

    fn getCurrentScopeStack(self: *ScopeManager) !*ArrayList(*Scope) {
        if (thread_current_scope_stack == null) {
            const stack = try self.allocator.create(ArrayList(*Scope));
            stack.* = ArrayList(*Scope).init(self.allocator);
            thread_current_scope_stack = stack;
        }
        return thread_current_scope_stack.?;
    }

    fn getCurrentScope(self: *ScopeManager) !*Scope {
        const stack = try self.getCurrentScopeStack();
        if (stack.items.len > 0) {
            return stack.items[stack.items.len - 1];
        }

        return self.getIsolationScope();
    }

    fn withScope(self: *ScopeManager, callback: anytype) !void {
        const current = try self.getCurrentScope();
        const new_scope = try self.allocator.create(Scope);
        new_scope.* = try current.fork();
        defer {
            new_scope.deinit();
            self.allocator.destroy(new_scope);
        }

        const stack = try self.getCurrentScopeStack();
        try stack.append(new_scope);
        defer _ = stack.pop();

        try callback(new_scope);
    }

    fn withIsolationScope(self: *ScopeManager, callback: anytype) !void {
        const previous = thread_isolation_scope;
        defer thread_isolation_scope = previous;

        const new_scope = try self.allocator.create(Scope);
        new_scope.* = Scope.init(self.allocator);
        defer {
            new_scope.deinit();
            self.allocator.destroy(new_scope);
        }

        thread_isolation_scope = new_scope;
        try callback(new_scope);
    }

    fn configureScope(self: *ScopeManager, callback: anytype) !void {
        const scope = try self.getIsolationScope();
        try callback(scope);
    }
};

var g_scope_manager: ?ScopeManager = null;

pub fn initScopeManager(allocator: Allocator) !void {
    g_scope_manager = ScopeManager.init(allocator);
}

pub fn getAllocator() !Allocator {
    if (g_scope_manager) |*manager| {
        return manager.allocator;
    }
    return error.ScopeManagerNotInitialized;
}

pub fn getGlobalScope() !*Scope {
    if (g_scope_manager) |*manager| {
        return manager.getGlobalScope();
    }
    return error.ScopeManagerNotInitialized;
}

pub fn getIsolationScope() !*Scope {
    if (g_scope_manager) |*manager| {
        return manager.getIsolationScope();
    }
    return error.ScopeManagerNotInitialized;
}

pub fn getCurrentScope() !*Scope {
    if (g_scope_manager) |*manager| {
        return manager.getCurrentScope();
    }
    return error.ScopeManagerNotInitialized;
}

pub fn withScope(callback: anytype) !void {
    if (g_scope_manager) |*manager| {
        return manager.withScope(callback);
    }
    return error.ScopeManagerNotInitialized;
}

pub fn withIsolationScope(callback: anytype) !void {
    if (g_scope_manager) |*manager| {
        return manager.withIsolationScope(callback);
    }
    return error.ScopeManagerNotInitialized;
}

pub fn configureScope(callback: anytype) !void {
    if (g_scope_manager) |*manager| {
        return manager.configureScope(callback);
    }
    return error.ScopeManagerNotInitialized;
}

pub fn setTag(key: []const u8, value: []const u8) !void {
    const scope = try getIsolationScope();
    try scope.setTag(key, value);
}

pub fn setUser(user: User) !void {
    const scope = try getIsolationScope();
    scope.setUser(user);
}

pub fn setLevel(level: Level) !void {
    const scope = try getIsolationScope();
    scope.level = level;
}

pub fn setContext(key: []const u8, context_data: std.StringHashMap([]const u8)) !void {
    const scope = try getIsolationScope();
    try scope.setContext(key, context_data);
}

pub fn addBreadcrumb(breadcrumb: Breadcrumb) !void {
    const scope = try getIsolationScope();
    try scope.addBreadcrumb(breadcrumb);
}

/// Set trace context (equivalent to sentry_set_trace in Native SDK)
pub fn setTrace(trace_id: TraceId, span_id: SpanId, parent_span_id: ?SpanId) !void {
    const scope = try getIsolationScope();
    scope.setTrace(trace_id, span_id, parent_span_id);
}

/// Get the current propagation context
pub fn getPropagationContext() !PropagationContext {
    const scope = try getIsolationScope();
    return scope.getPropagationContext();
}

// Convenience function to set the client on the global scope
pub fn setClient(client: *SentryClient) void {
    if (getGlobalScope() catch null) |scope| {
        scope.bindClient(client);
    } else {
        std.log.err("Failed to get global scope for setting client", .{});
    }
}

// Convenience function to get the client
pub fn getClient() ?*SentryClient {
    const scope_getters = .{ getCurrentScope, getIsolationScope, getGlobalScope };
    inline for (scope_getters) |getter| {
        if (getter() catch null) |scope| {
            if (scope.client) |client| {
                return client;
            }
        }
    }
    return null;
}

pub fn captureEvent(event: Event) !?EventId {
    const scope_getters = .{ getCurrentScope, getIsolationScope, getGlobalScope };
    var client: ?*SentryClient = null;
    var event_copy = event;

    inline for (scope_getters) |getter| {
        if (getter() catch null) |scope| {
            try scope.applyToEvent(&event_copy);
            if (scope.client) |scopeClient| {
                client = scopeClient;
            }
        }
    }

    if (client) |c| {
        if (try c.captureEvent(event_copy)) |event_id_bytes| {
            return EventId{ .value = event_id_bytes };
        }
    }

    return null;
}

// Used for tests
fn resetAllScopeState(allocator: std.mem.Allocator) void {
    global_scope_mutex.lock();
    defer global_scope_mutex.unlock();

    if (global_scope) |scope| {
        scope.deinit();
        allocator.destroy(scope);
        global_scope = null;
    }

    if (thread_isolation_scope) |scope| {
        scope.deinit();
        allocator.destroy(scope);
        thread_isolation_scope = null;
    }

    if (thread_current_scope_stack) |stack| {
        for (stack.items) |scope| {
            scope.deinit();
            allocator.destroy(scope);
        }
        stack.deinit();
        allocator.destroy(stack);
        thread_current_scope_stack = null;
    }

    g_scope_manager = null;
}

test "Scope - comprehensive API testing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    resetAllScopeState(allocator);
    defer resetAllScopeState(allocator);

    try initScopeManager(allocator);

    try setLevel(Level.warning);
    const isolation_scope = try getIsolationScope();
    try testing.expect(isolation_scope.level == Level.warning);

    try setTag("environment", "test");
    try setTag("version", "1.0.0");
    try testing.expectEqualStrings("test", isolation_scope.tags.get("environment").?);
    try testing.expectEqualStrings("1.0.0", isolation_scope.tags.get("version").?);

    const test_user = User{
        .id = "123",
        .username = "testuser",
        .email = "test@example.com",
        .name = "Test User",
    };
    try setUser(test_user);
    try testing.expect(isolation_scope.user != null);
    try testing.expectEqualStrings("123", isolation_scope.user.?.id.?);
    try testing.expectEqualStrings("testuser", isolation_scope.user.?.username.?);
    try testing.expectEqualStrings("test@example.com", isolation_scope.user.?.email.?);
    try testing.expectEqualStrings("Test User", isolation_scope.user.?.name.?);

    var device_context = std.StringHashMap([]const u8).init(allocator);
    defer device_context.deinit(); // Clean up the original HashMap
    try device_context.put("name", "iPhone");
    try device_context.put("model", "iPhone 12");
    try device_context.put("os", "iOS 15.0");
    try setContext("device", device_context);
    try testing.expect(isolation_scope.contexts.count() == 1);
    const stored_context = isolation_scope.contexts.get("device").?;
    try testing.expectEqualStrings("iPhone", stored_context.get("name").?);
    try testing.expectEqualStrings("iPhone 12", stored_context.get("model").?);
    try testing.expectEqualStrings("iOS 15.0", stored_context.get("os").?);

    try addBreadcrumb(Breadcrumb{
        .message = "User clicked button",
        .type = BreadcrumbType.user,
        .level = Level.info,
        .category = "ui",
        .timestamp = std.time.timestamp(),
        .data = null,
    });
    try addBreadcrumb(Breadcrumb{
        .message = "API call made",
        .type = BreadcrumbType.http,
        .level = Level.debug,
        .category = "api",
        .timestamp = std.time.timestamp(),
        .data = null,
    });
    try testing.expect(isolation_scope.breadcrumbs.items.len == 2);
    try testing.expectEqualStrings("User clicked button", isolation_scope.breadcrumbs.items[0].message);
    try testing.expect(isolation_scope.breadcrumbs.items[0].type == BreadcrumbType.user);
    try testing.expectEqualStrings("API call made", isolation_scope.breadcrumbs.items[1].message);
    try testing.expect(isolation_scope.breadcrumbs.items[1].type == BreadcrumbType.http);

    const global_scope_ref = try getGlobalScope();
    const current_scope = try getCurrentScope();

    try testing.expect(current_scope == isolation_scope);
    try testing.expect(global_scope_ref != isolation_scope);
    try testing.expect(global_scope_ref.level == Level.info);
    try testing.expect(global_scope_ref.tags.count() == 0);
    try testing.expect(global_scope_ref.user == null);
}

test "Scope - breadcrumb limit enforcement" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_scope = Scope.init(allocator);
    defer test_scope.deinit();

    var i: usize = 0;
    while (i <= Scope.MAX_BREADCRUMBS + 5) : (i += 1) {
        const message = try std.fmt.allocPrint(allocator, "Breadcrumb {}", .{i});
        defer allocator.free(message);

        const breadcrumb = Breadcrumb{
            .message = message,
            .type = BreadcrumbType.default,
            .level = Level.info,
            .category = null,
            .timestamp = std.time.timestamp(),
            .data = null,
        };
        try test_scope.addBreadcrumb(breadcrumb);
    }

    try testing.expect(test_scope.breadcrumbs.items.len == Scope.MAX_BREADCRUMBS);
    try testing.expectEqualStrings("Breadcrumb 6", test_scope.breadcrumbs.items[0].message);
}

test "Scope - fork with all data types" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var original = Scope.init(allocator);
    defer original.deinit();

    try original.setTag("env", "test");
    original.level = Level.warning;

    const user = User{
        .id = "123",
        .username = "testuser",
        .email = "test@example.com",
        .name = "Test User",
        .ip_address = "192.168.1.1",
    };
    original.setUser(user);

    try original.setFingerprint(&[_][]const u8{ "fp1", "fp2" });

    var data = std.StringHashMap([]const u8).init(allocator);
    defer data.deinit(); // Clean up original HashMap
    try data.put("key1", "value1");

    const breadcrumb = Breadcrumb{
        .message = "Test breadcrumb",
        .type = BreadcrumbType.navigation,
        .level = Level.info,
        .category = "test",
        .timestamp = std.time.timestamp(),
        .data = data,
    };
    try original.addBreadcrumb(breadcrumb);

    var context = std.StringHashMap([]const u8).init(allocator);
    defer context.deinit(); // Clean up original HashMap
    try context.put("platform", "linux");
    try original.setContext("os", context);

    var forked = try original.fork();
    defer forked.deinit();

    try testing.expect(forked.level == Level.warning);
    try testing.expectEqualStrings("test", forked.tags.get("env").?);

    try testing.expect(forked.user != null);
    try testing.expectEqualStrings("123", forked.user.?.id.?);
    try testing.expectEqualStrings("testuser", forked.user.?.username.?);
    try testing.expectEqualStrings("test@example.com", forked.user.?.email.?);
    try testing.expectEqualStrings("Test User", forked.user.?.name.?);
    try testing.expectEqualStrings("192.168.1.1", forked.user.?.ip_address.?);

    try testing.expect(forked.fingerprint != null);
    try testing.expect(forked.fingerprint.?.items.len == 2);
    try testing.expectEqualStrings("fp1", forked.fingerprint.?.items[0]);
    try testing.expectEqualStrings("fp2", forked.fingerprint.?.items[1]);

    try testing.expect(forked.breadcrumbs.items.len == 1);
    try testing.expectEqualStrings("Test breadcrumb", forked.breadcrumbs.items[0].message);
    try testing.expect(forked.breadcrumbs.items[0].data != null);
    try testing.expectEqualStrings("value1", forked.breadcrumbs.items[0].data.?.get("key1").?);

    try testing.expect(forked.contexts.count() == 1);
    const forked_context = forked.contexts.get("os").?;
    try testing.expectEqualStrings("linux", forked_context.get("platform").?);

    try forked.setTag("forked_only", "value");
    try testing.expect(original.tags.get("forked_only") == null);
}

const ThreadTestContext = struct {
    allocator: std.mem.Allocator,
    thread_id: u32,
    thread_count: u32,
    results: []bool,

    fn threadFunction(context: ThreadTestContext) void {
        const tag_key = std.fmt.allocPrint(context.allocator, "thread_{}", .{context.thread_id}) catch {
            context.results[context.thread_id] = false;
            return;
        };
        defer context.allocator.free(tag_key);

        const tag_value = std.fmt.allocPrint(context.allocator, "value_{}", .{context.thread_id}) catch {
            context.results[context.thread_id] = false;
            return;
        };
        defer context.allocator.free(tag_value);

        setTag(tag_key, tag_value) catch {
            context.results[context.thread_id] = false;
            return;
        };

        const isolation_scope = getIsolationScope() catch {
            context.results[context.thread_id] = false;
            return;
        };

        const retrieved = isolation_scope.tags.get(tag_key) orelse {
            context.results[context.thread_id] = false;
            return;
        };

        if (!std.mem.eql(u8, retrieved, tag_value)) {
            context.results[context.thread_id] = false;
            return;
        }

        // Verify thread isolation: other threads' tags should not be visible
        var other_thread: u32 = 0;
        while (other_thread < context.thread_count) : (other_thread += 1) {
            if (other_thread == context.thread_id) continue;

            const other_tag_key = std.fmt.allocPrint(context.allocator, "thread_{}", .{other_thread}) catch {
                context.results[context.thread_id] = false;
                return;
            };
            defer context.allocator.free(other_tag_key);

            if (isolation_scope.tags.get(other_tag_key) != null) {
                context.results[context.thread_id] = false;
                return;
            }
        }

        if (isolation_scope.tags.count() != 1) {
            context.results[context.thread_id] = false;
            return;
        }

        context.results[context.thread_id] = true;

        if (thread_isolation_scope) |scope| {
            scope.deinit();
            context.allocator.destroy(scope);
            thread_isolation_scope = null;
        }
        if (thread_current_scope_stack) |stack| {
            for (stack.items) |scope| {
                scope.deinit();
                context.allocator.destroy(scope);
            }
            stack.deinit();
            context.allocator.destroy(stack);
            thread_current_scope_stack = null;
        }
    }
};

test "Scope - thread safety verification" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    resetAllScopeState(allocator);
    defer resetAllScopeState(allocator);

    try initScopeManager(allocator);

    const thread_count = 4;
    var threads: [thread_count]std.Thread = undefined;
    var results = [_]bool{false} ** thread_count;

    for (0..thread_count) |i| {
        const context = ThreadTestContext{
            .allocator = allocator,
            .thread_id = @intCast(i),
            .thread_count = thread_count,
            .results = &results,
        };

        threads[i] = try std.Thread.spawn(.{}, ThreadTestContext.threadFunction, .{context});
    }

    for (0..thread_count) |i| {
        threads[i].join();
        try testing.expect(results[i]);
    }
}

test "Scope - withScope workflow and restoration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    resetAllScopeState(allocator);
    defer resetAllScopeState(allocator);

    try initScopeManager(allocator);

    try setLevel(Level.@"error");
    try setTag("base_tag", "base_value");
    try setUser(User{
        .id = "original_user",
        .username = "original",
        .email = null,
        .name = null,
        .ip_address = null,
    });

    const original_isolation_scope = try getIsolationScope();

    try testing.expect(original_isolation_scope.level == Level.@"error");
    try testing.expectEqualStrings("base_value", original_isolation_scope.tags.get("base_tag").?);
    try testing.expectEqualStrings("original_user", original_isolation_scope.user.?.id.?);

    try withScope(struct {
        fn callback(scope: *Scope) !void {
            const current_scope_in_callback = getCurrentScope() catch unreachable;
            try testing.expect(current_scope_in_callback == scope);

            const isolation_scope_in_callback = getIsolationScope() catch unreachable;
            try testing.expect(current_scope_in_callback != isolation_scope_in_callback);

            try testing.expect(scope.level == Level.@"error");
            try testing.expectEqualStrings("base_value", scope.tags.get("base_tag").?);
            try testing.expectEqualStrings("original_user", scope.user.?.id.?);

            try scope.setTag("scoped_tag", "scoped_value");
            scope.level = Level.debug;
            scope.setUser(User{
                .id = "scoped_user",
                .username = "scoped",
                .email = null,
                .name = null,
                .ip_address = null,
            });

            try testing.expect(scope.level == Level.debug);
            try testing.expectEqualStrings("scoped_value", scope.tags.get("scoped_tag").?);
            try testing.expectEqualStrings("scoped_user", scope.user.?.id.?);
            try testing.expectEqualStrings("base_value", scope.tags.get("base_tag").?);
        }
    }.callback);

    const current_after_withScope = try getCurrentScope();
    try testing.expect(current_after_withScope == original_isolation_scope);

    try testing.expect(original_isolation_scope.level == Level.@"error");
    try testing.expectEqualStrings("base_value", original_isolation_scope.tags.get("base_tag").?);
    try testing.expectEqualStrings("original_user", original_isolation_scope.user.?.id.?);
    try testing.expect(original_isolation_scope.tags.get("scoped_tag") == null);

    try withScope(struct {
        fn outerCallback(outer_scope: *Scope) !void {
            try outer_scope.setTag("outer_tag", "outer_value");

            try withScope(struct {
                fn innerCallback(inner_scope: *Scope) !void {
                    try testing.expectEqualStrings("outer_value", inner_scope.tags.get("outer_tag").?);
                    try testing.expectEqualStrings("base_value", inner_scope.tags.get("base_tag").?);

                    try inner_scope.setTag("inner_tag", "inner_value");
                    try testing.expectEqualStrings("inner_value", inner_scope.tags.get("inner_tag").?);
                }
            }.innerCallback);

            try testing.expect(outer_scope.tags.get("inner_tag") == null);
            try testing.expectEqualStrings("outer_value", outer_scope.tags.get("outer_tag").?);
        }
    }.outerCallback);

    const final_current = try getCurrentScope();
    try testing.expect(final_current == original_isolation_scope);
    try testing.expect(original_isolation_scope.tags.get("outer_tag") == null);
    try testing.expect(original_isolation_scope.tags.get("inner_tag") == null);
    try testing.expectEqualStrings("base_value", original_isolation_scope.tags.get("base_tag").?);
}
