const std = @import("std");
const User = @import("types.zig").User;
const Breadcrumb = @import("types.zig").Breadcrumb;
const Level = @import("types.zig").Level;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const RwLock = std.Thread.RwLock;

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
