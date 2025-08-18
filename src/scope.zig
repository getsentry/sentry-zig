const std = @import("std");
const User = @import("types.zig").User;
const Breadcrumb = @import("types.zig").Breadcrumb;
const BreadcrumbType = @import("types.zig").BreadcrumbType;
const Level = @import("types.zig").Level;
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
    pub fn fork(self: *const Scope, allocator: Allocator) !Scope {
        var new_scope = Scope.init(allocator);

        // Copy level
        new_scope.level = self.level;

        var tag_iterator = self.tags.iterator();
        while (tag_iterator.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const value = try allocator.dupe(u8, entry.value_ptr.*);
            try new_scope.tags.put(key, value);
        }

        if (self.user) |user| {
            new_scope.user = User{
                .id = if (user.id) |id| try allocator.dupe(u8, id) else null,
                .username = if (user.username) |username| try allocator.dupe(u8, username) else null,
                .email = if (user.email) |email| try allocator.dupe(u8, email) else null,
                .name = if (user.name) |name| try allocator.dupe(u8, name) else null,
                .ip_address = if (user.ip_address) |ip| try allocator.dupe(u8, ip) else null,
            };
        }

        if (self.fingerprint) |fp| {
            new_scope.fingerprint = ArrayList([]const u8).init(allocator);
            for (fp.items) |item| {
                const copied_item = try allocator.dupe(u8, item);
                try new_scope.fingerprint.?.append(copied_item);
            }
        }

        for (self.breadcrumbs.items) |crumb| {
            var new_crumb = Breadcrumb{
                .message = try allocator.dupe(u8, crumb.message),
                .type = crumb.type,
                .level = crumb.level,
                .category = if (crumb.category) |cat| try allocator.dupe(u8, cat) else null,
                .timestamp = crumb.timestamp,
                .data = null,
            };

            if (crumb.data) |data| {
                new_crumb.data = std.StringHashMap([]const u8).init(allocator);
                var data_iterator = data.iterator();
                while (data_iterator.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    const value = try allocator.dupe(u8, entry.value_ptr.*);
                    try new_crumb.data.?.put(key, value);
                }
            }

            try new_scope.breadcrumbs.append(new_crumb);
        }

        // Copy contexts
        var context_iterator = self.contexts.iterator();
        while (context_iterator.next()) |entry| {
            const context_key = try allocator.dupe(u8, entry.key_ptr.*);
            var new_context = std.StringHashMap([]const u8).init(allocator);

            var inner_iterator = entry.value_ptr.iterator();
            while (inner_iterator.next()) |inner_entry| {
                const key = try allocator.dupe(u8, inner_entry.key_ptr.*);
                const value = try allocator.dupe(u8, inner_entry.value_ptr.*);
                try new_context.put(key, value);
            }

            try new_scope.contexts.put(context_key, new_context);
        }

        return new_scope;
    }

    /// Set a tag
    pub fn setTag(self: *Scope, key: []const u8, value: []const u8) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        const owned_value = try self.allocator.dupe(u8, value);

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

        if (self.contexts.get(key)) |old_context| {
            var iterator = old_context.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
        }

        try self.contexts.put(owned_key, context_data);
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
            const cloned_user = User{
                .id = if (user.id) |id| try self.allocator.dupe(u8, id) else null,
                .username = if (user.username) |username| try self.allocator.dupe(u8, username) else null,
                .email = if (user.email) |email| try self.allocator.dupe(u8, email) else null,
                .name = if (user.name) |name| try self.allocator.dupe(u8, name) else null,
                .ip_address = if (user.ip_address) |ip| try self.allocator.dupe(u8, ip) else null,
            };
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

    /// Get the global scope
    pub fn getGlobalScope(allocator: Allocator) !*Scope {
        global_scope_mutex.lock();
        defer global_scope_mutex.unlock();

        if (global_scope == null) {
            const scope = try allocator.create(Scope);
            scope.* = Scope.init(allocator);
            global_scope = scope;
        }

        return global_scope.?;
    }

    /// Get the current thread's isolation scope
    pub fn getIsolationScope(allocator: Allocator) !*Scope {
        if (thread_isolation_scope == null) {
            // Create isolation scope by forking global scope
            const global = try Scope.getGlobalScope(allocator);
            const scope = try allocator.create(Scope);
            scope.* = try global.fork(allocator);
            thread_isolation_scope = scope;
        }

        return thread_isolation_scope.?;
    }

    /// Get the current thread's current scope
    pub fn getCurrentScope(allocator: Allocator) !*Scope {
        if (thread_current_scope == null) {
            const scope = try allocator.create(Scope);
            scope.* = Scope.init(allocator);
            thread_current_scope = scope;
        }

        return thread_current_scope.?;
    }

    /// Set a new isolation scope (replacing the current one)
    pub fn setIsolationScope(allocator: Allocator, new_scope: *Scope) void {
        if (thread_isolation_scope) |old_scope| {
            old_scope.deinit();
            allocator.destroy(old_scope);
        }
        thread_isolation_scope = new_scope;
    }

    /// Set a new current scope (replacing the current one)
    pub fn setCurrentScope(allocator: Allocator, new_scope: *Scope) void {
        if (thread_current_scope) |old_scope| {
            old_scope.deinit();
            allocator.destroy(old_scope);
        }
        thread_current_scope = new_scope;
    }
};

// Global scope (not thread-local, singleton)
pub var global_scope: ?*Scope = null;
pub var global_scope_mutex = Mutex{};

// Thread-local scopes
pub threadlocal var thread_isolation_scope: ?*Scope = null;
pub threadlocal var thread_current_scope: ?*Scope = null;

fn resetAllScopeState(allocator: std.mem.Allocator) void {
    global_scope_mutex.lock();
    defer global_scope_mutex.unlock();

    if (global_scope) |global| {
        global.deinit();
        allocator.destroy(global);
        global_scope = null;
    }

    if (thread_isolation_scope) |isolation| {
        isolation.deinit();
        allocator.destroy(isolation);
        thread_isolation_scope = null;
    }

    if (thread_current_scope) |current| {
        current.deinit();
        allocator.destroy(current);
        thread_current_scope = null;
    }
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
    var forked_scope = try original_scope.fork(allocator);
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

test "Scope - static scope method functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    resetAllScopeState(allocator);
    defer resetAllScopeState(allocator);

    _ = try Scope.getGlobalScope(allocator);
    _ = try Scope.getIsolationScope(allocator);
    _ = try Scope.getCurrentScope(allocator);

    const new_current = try allocator.create(Scope);
    new_current.* = Scope.init(allocator);
    try new_current.setTag("test", "current");
    Scope.setCurrentScope(allocator, new_current);

    const current = try Scope.getCurrentScope(allocator);
    try testing.expectEqualStrings("current", current.tags.get("test").?);
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

    var forked = try empty_scope.fork(allocator);
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

    var forked = try original.fork(allocator);
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
        defer {
            if (thread_current_scope) |current| {
                current.deinit();
                context.allocator.destroy(current);
                thread_current_scope = null;
            }
        }

        const current_scope = Scope.getCurrentScope(context.allocator) catch {
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

        current_scope.setTag(tag_key, tag_value) catch {
            context.results[context.thread_id] = false;
            return;
        };

        const retrieved = current_scope.tags.get(tag_key) orelse {
            context.results[context.thread_id] = false;
            return;
        };

        if (!std.mem.eql(u8, retrieved, tag_value)) {
            context.results[context.thread_id] = false;
            return;
        }

        context.results[context.thread_id] = true;
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
