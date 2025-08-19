const std = @import("std");
const types = @import("types");

// Top-level type aliases
const User = types.User;
const Breadcrumb = types.Breadcrumb;
const BreadcrumbType = types.BreadcrumbType;
const Level = types.Level;
const Event = types.Event.Event;
const Contexts = types.Contexts.Contexts;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const RwLock = std.Thread.RwLock;
const testing = std.testing;

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

    const MAX_BREADCRUMBS = 100;

    pub fn init(allocator: Allocator) Scope {
        return Scope{
            .allocator = allocator,
            .level = Level.info, // Default level
            .tags = std.StringHashMap([]const u8).init(allocator),
            .user = null,
            .fingerprint = null,
            .breadcrumbs = ArrayList(Breadcrumb).init(allocator),
            .contexts = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
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
            user.deinit(self.allocator);
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

        // Copy level
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

        // Copy contexts
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
            old_user.deinit(self.allocator);
        }
        self.user = user;
    }

    /// Add a breadcrumb
    pub fn addBreadcrumb(self: *Scope, breadcrumb: Breadcrumb) !void {
        if (self.breadcrumbs.items.len >= MAX_BREADCRUMBS) {
            var oldest = self.breadcrumbs.orderedRemove(0);
            oldest.deinit(self.allocator);
        }

        try self.breadcrumbs.append(breadcrumb);
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

        try self.contexts.put(owned_key, context_data);
    }

    /// Apply scope data to an event (similar to Python's apply_to_event)
    pub fn applyToEvent(self: *const Scope, event: *Event.Event, allocator: Allocator) !void {
        self.applyLevelToEvent(event);
        try self.applyTagsToEvent(event, allocator);
        try self.applyUserToEvent(event, allocator);
        try self.applyFingerprintToEvent(event, allocator);
        try self.applyBreadcrumbsToEvent(event, allocator);
        try self.applyContextsToEvent(event, allocator);
    }

    fn applyLevelToEvent(self: *const Scope, event: *Event.Event) void {
        if (event.level == null and self.level != .info) {
            event.level = self.level;
        }
    }

    fn applyTagsToEvent(self: *const Scope, event: *Event.Event, allocator: Allocator) !void {
        if (self.tags.count() == 0) return;

        if (event.tags == null) {
            event.tags = std.StringHashMap([]const u8).init(allocator);
        }

        var tag_iterator = self.tags.iterator();
        while (tag_iterator.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const value = try allocator.dupe(u8, entry.value_ptr.*);
            try event.tags.?.put(key, value);
        }
    }

    fn applyUserToEvent(self: *const Scope, event: *Event.Event, allocator: Allocator) !void {
        if (event.user == null and self.user != null) {
            event.user = try self.user.?.clone(allocator);
        }
    }

    fn applyFingerprintToEvent(self: *const Scope, event: *Event.Event, allocator: Allocator) !void {
        if (event.fingerprint == null and self.fingerprint != null) {
            var fingerprint = try allocator.alloc([]const u8, self.fingerprint.?.items.len);
            for (self.fingerprint.?.items, 0..) |fp, i| {
                fingerprint[i] = try allocator.dupe(u8, fp);
            }
            event.fingerprint = fingerprint;
        }
    }

    fn applyBreadcrumbsToEvent(self: *const Scope, event: *Event.Event, allocator: Allocator) !void {
        if (self.breadcrumbs.items.len == 0) return;

        const Breadcrumbs = Event.Breadcrumbs;
        const existing_count = if (event.breadcrumbs) |b| b.values.len else 0;
        const total_count = existing_count + self.breadcrumbs.items.len;

        var all_breadcrumbs = try allocator.alloc(Breadcrumb, total_count);

        // Copy existing breadcrumbs if any
        if (event.breadcrumbs) |existing| {
            for (existing.values, 0..) |crumb, i| {
                all_breadcrumbs[i] = crumb;
            }
            // Free the old array but not the breadcrumbs themselves
            allocator.free(existing.values);
        }

        // Add scope breadcrumbs
        for (self.breadcrumbs.items, existing_count..) |crumb, i| {
            // Clone the breadcrumb
            var cloned_crumb = Breadcrumb{
                .message = try allocator.dupe(u8, crumb.message),
                .type = crumb.type,
                .level = crumb.level,
                .category = if (crumb.category) |cat| try allocator.dupe(u8, cat) else null,
                .timestamp = crumb.timestamp,
                .data = null,
            };

            if (crumb.data) |data| {
                cloned_crumb.data = std.StringHashMap([]const u8).init(allocator);
                var data_iterator = data.iterator();
                while (data_iterator.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    const value = try allocator.dupe(u8, entry.value_ptr.*);
                    try cloned_crumb.data.?.put(key, value);
                }
            }

            all_breadcrumbs[i] = cloned_crumb;
        }

        event.breadcrumbs = Breadcrumbs{ .values = all_breadcrumbs };
    }

    fn applyContextsToEvent(self: *const Scope, event: *Event.Event, allocator: Allocator) !void {
        if (self.contexts.count() == 0) return;

        if (event.contexts == null) {
            event.contexts = Contexts.Contexts.init(allocator);
        }

        var context_iterator = self.contexts.iterator();
        while (context_iterator.next()) |entry| {
            // Check if this context already exists in the event
            if (event.contexts.?.contains(entry.key_ptr.*)) {
                continue; // Event contexts take precedence
            }

            const context_key = try allocator.dupe(u8, entry.key_ptr.*);
            var context_data = std.StringHashMap([]const u8).init(allocator);

            var inner_iterator = entry.value_ptr.iterator();
            while (inner_iterator.next()) |inner_entry| {
                const key = try allocator.dupe(u8, inner_entry.key_ptr.*);
                const value = try allocator.dupe(u8, inner_entry.value_ptr.*);
                try context_data.put(key, value);
            }

            try event.contexts.?.put(context_key, context_data);
        }
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
    }
};

// Global scope (not thread-local, singleton)
var global_scope: ?*Scope = null;
var global_scope_mutex = Mutex{};

// Thread-local scopes
threadlocal var thread_isolation_scope: ?*Scope = null;
threadlocal var thread_current_scope_stack: ?*ArrayList(*Scope) = null;

/// Scope manager for handling the three scope types (internal implementation)
const ScopeManager = struct {
    allocator: Allocator,

    fn init(allocator: Allocator) ScopeManager {
        return .{
            .allocator = allocator,
        };
    }

    fn deinit(self: *ScopeManager) void {
        _ = self;
        // Cleanup is handled by individual scopes
    }

    /// Get the global scope
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

    /// Get the current thread's isolation scope
    fn getIsolationScope(self: *ScopeManager) !*Scope {
        if (thread_isolation_scope == null) {
            // Create new isolation scope if none exists
            const scope = try self.allocator.create(Scope);
            scope.* = Scope.init(self.allocator);
            thread_isolation_scope = scope;
        }

        return thread_isolation_scope.?;
    }

    /// Get the current scope stack for this thread
    fn getCurrentScopeStack(self: *ScopeManager) !*ArrayList(*Scope) {
        if (thread_current_scope_stack == null) {
            const stack = try self.allocator.create(ArrayList(*Scope));
            stack.* = ArrayList(*Scope).init(self.allocator);
            thread_current_scope_stack = stack;
        }
        return thread_current_scope_stack.?;
    }

    /// Get the current thread's current scope
    fn getCurrentScope(self: *ScopeManager) !*Scope {
        const stack = try self.getCurrentScopeStack();
        if (stack.items.len > 0) {
            return stack.items[stack.items.len - 1];
        }

        // Return isolation scope if no current scope
        return self.getIsolationScope();
    }

    /// Execute a callback with a new current scope
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

    /// Execute a callback with a new isolation scope
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

    /// Configure the current isolation scope
    fn configureScope(self: *ScopeManager, callback: anytype) !void {
        const scope = try self.getIsolationScope();
        try callback(scope);
    }
};

// Global scope manager instance
var g_scope_manager: ?ScopeManager = null;

/// Initialize the global scope manager
pub fn initScopeManager(allocator: Allocator) !void {
    g_scope_manager = ScopeManager.init(allocator);
}

/// Get the global scope
pub fn getGlobalScope() !*Scope {
    if (g_scope_manager) |*manager| {
        return manager.getGlobalScope();
    }
    return error.ScopeManagerNotInitialized;
}

/// Get the isolation scope
pub fn getIsolationScope() !*Scope {
    if (g_scope_manager) |*manager| {
        return manager.getIsolationScope();
    }
    return error.ScopeManagerNotInitialized;
}

/// Get the current scope
pub fn getCurrentScope() !*Scope {
    if (g_scope_manager) |*manager| {
        return manager.getCurrentScope();
    }
    return error.ScopeManagerNotInitialized;
}

/// Execute a callback with a new current scope
pub fn withScope(callback: anytype) !void {
    if (g_scope_manager) |*manager| {
        return manager.withScope(callback);
    }
    return error.ScopeManagerNotInitialized;
}

/// Execute a callback with a new isolation scope
pub fn withIsolationScope(callback: anytype) !void {
    if (g_scope_manager) |*manager| {
        return manager.withIsolationScope(callback);
    }
    return error.ScopeManagerNotInitialized;
}

/// Configure the current isolation scope
pub fn configureScope(callback: anytype) !void {
    if (g_scope_manager) |*manager| {
        return manager.configureScope(callback);
    }
    return error.ScopeManagerNotInitialized;
}

// Convenience functions that write to isolation scope
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

pub fn addBreadcrumb(breadcrumb: Breadcrumb) !void {
    const scope = try getIsolationScope();
    try scope.addBreadcrumb(breadcrumb);
}

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

test "Scope - basic initialization and cleanup" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_scope = Scope.init(allocator);
    defer test_scope.deinit();

    try testing.expect(test_scope.level == Level.info);
    try testing.expect(test_scope.user == null);
    try testing.expect(test_scope.fingerprint == null);
    try testing.expect(test_scope.tags.count() == 0);
    try testing.expect(test_scope.breadcrumbs.items.len == 0);
    try testing.expect(test_scope.contexts.count() == 0);
}

test "Scope - tag management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_scope = Scope.init(allocator);
    defer test_scope.deinit();

    try test_scope.setTag("environment", "test");
    try test_scope.setTag("version", "1.0.0");

    try testing.expect(test_scope.tags.count() == 2);
    try testing.expectEqualStrings("test", test_scope.tags.get("environment").?);
    try testing.expectEqualStrings("1.0.0", test_scope.tags.get("version").?);

    try test_scope.setTag("environment", "production");
    try testing.expect(test_scope.tags.count() == 2);
    try testing.expectEqualStrings("production", test_scope.tags.get("environment").?);

    test_scope.removeTags();
    try testing.expect(test_scope.tags.count() == 0);
}

test "Scope - user management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_scope = Scope.init(allocator);
    defer test_scope.deinit();

    const test_user = User{
        .id = try allocator.dupe(u8, "123"),
        .username = try allocator.dupe(u8, "testuser"),
        .email = try allocator.dupe(u8, "test@example.com"),
        .name = try allocator.dupe(u8, "Test User"),
        .ip_address = try allocator.dupe(u8, "127.0.0.1"),
    };

    test_scope.setUser(test_user);
    try testing.expect(test_scope.user != null);
    try testing.expectEqualStrings("123", test_scope.user.?.id.?);
    try testing.expectEqualStrings("testuser", test_scope.user.?.username.?);
    try testing.expectEqualStrings("test@example.com", test_scope.user.?.email.?);

    const new_user = User{
        .id = try allocator.dupe(u8, "456"),
        .username = try allocator.dupe(u8, "newuser"),
        .email = null,
        .name = null,
        .ip_address = null,
    };

    test_scope.setUser(new_user);
    try testing.expectEqualStrings("456", test_scope.user.?.id.?);
    try testing.expectEqualStrings("newuser", test_scope.user.?.username.?);
    try testing.expect(test_scope.user.?.email == null);
}

test "Scope - breadcrumb management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_scope = Scope.init(allocator);
    defer test_scope.deinit();

    const breadcrumb1 = Breadcrumb{
        .message = try allocator.dupe(u8, "User clicked button"),
        .type = BreadcrumbType.user,
        .level = Level.info,
        .category = try allocator.dupe(u8, "ui"),
        .timestamp = std.time.timestamp(),
        .data = null,
    };

    try test_scope.addBreadcrumb(breadcrumb1);
    try testing.expect(test_scope.breadcrumbs.items.len == 1);
    try testing.expectEqualStrings("User clicked button", test_scope.breadcrumbs.items[0].message);

    var data = std.StringHashMap([]const u8).init(allocator);
    try data.put(try allocator.dupe(u8, "button_id"), try allocator.dupe(u8, "submit"));
    try data.put(try allocator.dupe(u8, "page"), try allocator.dupe(u8, "login"));

    const breadcrumb2 = Breadcrumb{
        .message = try allocator.dupe(u8, "Form submitted"),
        .type = BreadcrumbType.user,
        .level = Level.info,
        .category = try allocator.dupe(u8, "form"),
        .timestamp = std.time.timestamp(),
        .data = data,
    };

    try test_scope.addBreadcrumb(breadcrumb2);
    try testing.expect(test_scope.breadcrumbs.items.len == 2);

    test_scope.clearBreadcrumbs();
    try testing.expect(test_scope.breadcrumbs.items.len == 0);
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

test "Scope - context management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_scope = Scope.init(allocator);
    defer test_scope.deinit();

    var device_context = std.StringHashMap([]const u8).init(allocator);
    try device_context.put(try allocator.dupe(u8, "name"), try allocator.dupe(u8, "iPhone"));
    try device_context.put(try allocator.dupe(u8, "model"), try allocator.dupe(u8, "iPhone 12"));
    try device_context.put(try allocator.dupe(u8, "os"), try allocator.dupe(u8, "iOS 15.0"));

    try test_scope.setContext("device", device_context);
    try testing.expect(test_scope.contexts.count() == 1);

    const stored_context = test_scope.contexts.get("device").?;
    try testing.expectEqualStrings("iPhone", stored_context.get("name").?);
    try testing.expectEqualStrings("iPhone 12", stored_context.get("model").?);
    try testing.expectEqualStrings("iOS 15.0", stored_context.get("os").?);
}

test "Scope - fork functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var original_scope = Scope.init(allocator);
    defer original_scope.deinit();

    // Set up original scope
    try original_scope.setTag("environment", "test");
    try original_scope.setTag("version", "1.0.0");

    const user = User{
        .id = try allocator.dupe(u8, "123"),
        .username = try allocator.dupe(u8, "testuser"),
        .email = null,
        .name = null,
        .ip_address = null,
    };
    original_scope.setUser(user);

    const breadcrumb = Breadcrumb{
        .message = try allocator.dupe(u8, "Original breadcrumb"),
        .type = BreadcrumbType.default,
        .level = Level.info,
        .category = null,
        .timestamp = std.time.timestamp(),
        .data = null,
    };
    try original_scope.addBreadcrumb(breadcrumb);

    // Fork the scope
    var forked_scope = try original_scope.fork();
    defer forked_scope.deinit();

    // Test that forked scope has the same data
    try testing.expect(forked_scope.tags.count() == 2);
    try testing.expectEqualStrings("test", forked_scope.tags.get("environment").?);
    try testing.expectEqualStrings("1.0.0", forked_scope.tags.get("version").?);

    try testing.expect(forked_scope.user != null);
    try testing.expectEqualStrings("123", forked_scope.user.?.id.?);
    try testing.expectEqualStrings("testuser", forked_scope.user.?.username.?);

    try testing.expect(forked_scope.breadcrumbs.items.len == 1);
    try testing.expectEqualStrings("Original breadcrumb", forked_scope.breadcrumbs.items[0].message);

    // Test that modifying forked scope doesn't affect original
    try forked_scope.setTag("new_tag", "new_value");
    try testing.expect(original_scope.tags.get("new_tag") == null);
    try testing.expect(forked_scope.tags.get("new_tag") != null);
}

test "Scope - merge functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var target_scope = Scope.init(allocator);
    defer target_scope.deinit();

    var source_scope = Scope.init(allocator);
    defer source_scope.deinit();

    // Set up target scope
    try target_scope.setTag("existing", "value1");
    try target_scope.setTag("shared", "original");

    // Set up source scope
    try source_scope.setTag("new", "value2");
    try source_scope.setTag("shared", "overridden"); // This should override target

    const user = User{
        .id = try allocator.dupe(u8, "456"),
        .username = try allocator.dupe(u8, "sourceuser"),
        .email = null,
        .name = null,
        .ip_address = null,
    };
    source_scope.setUser(user);

    const breadcrumb = Breadcrumb{
        .message = try allocator.dupe(u8, "Source breadcrumb"),
        .type = BreadcrumbType.default,
        .level = Level.warning,
        .category = null,
        .timestamp = std.time.timestamp(),
        .data = null,
    };
    try source_scope.addBreadcrumb(breadcrumb);

    // Merge source into target
    try target_scope.merge(&source_scope);

    // Test merged results
    try testing.expect(target_scope.tags.count() == 3);
    try testing.expectEqualStrings("value1", target_scope.tags.get("existing").?);
    try testing.expectEqualStrings("value2", target_scope.tags.get("new").?);
    try testing.expectEqualStrings("overridden", target_scope.tags.get("shared").?);

    try testing.expect(target_scope.user != null);
    try testing.expectEqualStrings("456", target_scope.user.?.id.?);
    try testing.expectEqualStrings("sourceuser", target_scope.user.?.username.?);

    try testing.expect(target_scope.breadcrumbs.items.len == 1);
    try testing.expectEqualStrings("Source breadcrumb", target_scope.breadcrumbs.items[0].message);
}

test "Scope - scope manager functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    resetAllScopeState(allocator);
    defer resetAllScopeState(allocator);

    // Initialize scope manager
    try initScopeManager(allocator);

    // Test getting scopes
    const global = try getGlobalScope();
    const isolation = try getIsolationScope();
    const current = try getCurrentScope();

    // Test that current scope is initially the same as isolation scope
    try testing.expect(current == isolation);

    // Test setting tags on different scopes
    try global.setTag("global_tag", "global_value");
    try isolation.setTag("isolation_tag", "isolation_value");

    // Test withScope
    try withScope(struct {
        fn callback(scope: *Scope) !void {
            try scope.setTag("current_tag", "current_value");

            // Verify we can see isolation tags but not modify them
            try testing.expect(scope.tags.get("current_tag") != null);
            try testing.expectEqualStrings("current_value", scope.tags.get("current_tag").?);
        }
    }.callback);

    // Verify tag is not present outside withScope
    const after_current = try getCurrentScope();
    try testing.expect(after_current.tags.get("current_tag") == null);

    // Test convenience functions
    try setTag("convenience_tag", "convenience_value");
    const user = User{
        .id = try allocator.dupe(u8, "convenience_user"),
        .username = null,
        .email = null,
        .name = null,
        .ip_address = null,
    };
    try setUser(user);
    try setLevel(Level.warning);

    // Verify they wrote to isolation scope
    const iso = try getIsolationScope();
    try testing.expectEqualStrings("convenience_value", iso.tags.get("convenience_tag").?);
    try testing.expect(iso.user != null);
    try testing.expectEqualStrings("convenience_user", iso.user.?.id.?);
    try testing.expect(iso.level == Level.warning);
}

test "Scope - level management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_scope = Scope.init(allocator);
    defer test_scope.deinit();

    try testing.expect(test_scope.level == Level.info);

    test_scope.level = Level.debug;
    try testing.expect(test_scope.level == Level.debug);

    test_scope.level = Level.warning;
    try testing.expect(test_scope.level == Level.warning);

    test_scope.level = Level.@"error";
    try testing.expect(test_scope.level == Level.@"error");

    test_scope.level = Level.fatal;
    try testing.expect(test_scope.level == Level.fatal);
}

test "Scope - fingerprint management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_scope = Scope.init(allocator);
    defer test_scope.deinit();

    try testing.expect(test_scope.fingerprint == null);

    test_scope.fingerprint = std.ArrayList([]const u8).init(allocator);
    try test_scope.fingerprint.?.append(try allocator.dupe(u8, "fingerprint1"));
    try test_scope.fingerprint.?.append(try allocator.dupe(u8, "fingerprint2"));

    try testing.expect(test_scope.fingerprint.?.items.len == 2);
    try testing.expectEqualStrings("fingerprint1", test_scope.fingerprint.?.items[0]);
    try testing.expectEqualStrings("fingerprint2", test_scope.fingerprint.?.items[1]);
}

test "Scope - empty scope operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var empty_scope = Scope.init(allocator);
    defer empty_scope.deinit();

    empty_scope.removeTags();
    empty_scope.clearBreadcrumbs();

    var forked = try empty_scope.fork();
    defer forked.deinit();

    try testing.expect(forked.tags.count() == 0);
    try testing.expect(forked.breadcrumbs.items.len == 0);
    try testing.expect(forked.user == null);
}

test "Scope - memory management edge cases" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_scope = Scope.init(allocator);
    defer test_scope.deinit();

    try test_scope.setTag("key", "value1");
    try test_scope.setTag("key", "value2");
    try test_scope.setTag("key", "value3");

    try testing.expectEqualStrings("value3", test_scope.tags.get("key").?);
    try testing.expect(test_scope.tags.count() == 1);
}

test "Scope - merge with empty and null fields" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var target_scope = Scope.init(allocator);
    defer target_scope.deinit();

    var empty_scope = Scope.init(allocator);
    defer empty_scope.deinit();

    try target_scope.merge(&empty_scope);

    try testing.expect(target_scope.tags.count() == 0);
    try testing.expect(target_scope.user == null);
    try testing.expect(target_scope.breadcrumbs.items.len == 0);
}

test "Scope - complex fork with all data types" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var original = Scope.init(allocator);
    defer original.deinit();

    try original.setTag("env", "test");
    original.level = Level.warning;

    const user = User{
        .id = try allocator.dupe(u8, "123"),
        .username = try allocator.dupe(u8, "testuser"),
        .email = try allocator.dupe(u8, "test@example.com"),
        .name = try allocator.dupe(u8, "Test User"),
        .ip_address = try allocator.dupe(u8, "192.168.1.1"),
    };
    original.setUser(user);

    original.fingerprint = std.ArrayList([]const u8).init(allocator);
    try original.fingerprint.?.append(try allocator.dupe(u8, "fp1"));
    try original.fingerprint.?.append(try allocator.dupe(u8, "fp2"));

    var data = std.StringHashMap([]const u8).init(allocator);
    try data.put(try allocator.dupe(u8, "key1"), try allocator.dupe(u8, "value1"));

    const breadcrumb = Breadcrumb{
        .message = try allocator.dupe(u8, "Test breadcrumb"),
        .type = BreadcrumbType.navigation,
        .level = Level.info,
        .category = try allocator.dupe(u8, "test"),
        .timestamp = std.time.timestamp(),
        .data = data,
    };
    try original.addBreadcrumb(breadcrumb);

    var context = std.StringHashMap([]const u8).init(allocator);
    try context.put(try allocator.dupe(u8, "platform"), try allocator.dupe(u8, "linux"));
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
    results: []bool,

    fn threadFunction(context: ThreadTestContext) void {
        // Create a local scope manager for this thread
        var manager = ScopeManager.init(context.allocator);

        // Get isolation scope and set thread-specific data
        const isolation_scope = manager.getIsolationScope() catch {
            context.results[context.thread_id] = false;
            return;
        };

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

        isolation_scope.setTag(tag_key, tag_value) catch {
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

        context.results[context.thread_id] = true;

        // Clean up thread-local state
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

    const thread_count = 4;
    var threads: [thread_count]std.Thread = undefined;
    var results = [_]bool{false} ** thread_count;

    for (0..thread_count) |i| {
        const context = ThreadTestContext{
            .allocator = allocator,
            .thread_id = @intCast(i),
            .results = &results,
        };

        threads[i] = try std.Thread.spawn(.{}, ThreadTestContext.threadFunction, .{context});
    }

    for (0..thread_count) |i| {
        threads[i].join();
        try testing.expect(results[i]);
    }
}
