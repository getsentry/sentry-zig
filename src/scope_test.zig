const std = @import("std");
const testing = std.testing;
const scope = @import("scope.zig");

const Scope = scope.Scope;
const User = @import("types.zig").User;
const Breadcrumb = @import("types.zig").Breadcrumb;
const BreadcrumbType = @import("types.zig").BreadcrumbType;
const Level = @import("types.zig").Level;

const TEST_MAX_BREADCRUMBS = 100;

fn resetAllScopeState(allocator: std.mem.Allocator) void {
    scope.global_scope_mutex.lock();
    defer scope.global_scope_mutex.unlock();

    if (scope.global_scope) |global| {
        global.deinit();
        allocator.destroy(global);
        scope.global_scope = null;
    }

    if (scope.thread_isolation_scope) |isolation| {
        isolation.deinit();
        allocator.destroy(isolation);
        scope.thread_isolation_scope = null;
    }

    if (scope.thread_current_scope) |current| {
        current.deinit();
        allocator.destroy(current);
        scope.thread_current_scope = null;
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
    while (i <= TEST_MAX_BREADCRUMBS + 5) : (i += 1) {
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

    try testing.expect(test_scope.breadcrumbs.items.len == TEST_MAX_BREADCRUMBS);
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
            if (scope.thread_current_scope) |current| {
                current.deinit();
                context.allocator.destroy(current);
                scope.thread_current_scope = null;
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
