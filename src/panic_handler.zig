const std = @import("std");
const types = @import("types");
const sentry = @import("root.zig");
const stack_trace = @import("utils/stack_trace.zig");

// Top-level type aliases
const Event = types.Event;
const EventId = types.EventId;
const StackTrace = types.StackTrace;
const Level = types.Level;
const Exception = types.Exception;
const Frame = types.Frame;

pub fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    // If we can't get the allocator because the scope manager is not initialized,
    // we can't do anything, so we just return.
    if (scope.getAllocator()) |allocator| {
        handlePanic(allocator, msg, first_trace_addr);
    } else |_| {
        // We can't do anything if we have no allocator.
    }

    std.process.exit(1);
}

fn handlePanic(allocator: Allocator, msg: []const u8, first_trace_addr: ?usize) void {
    const sentry_event = createSentryEvent(allocator, msg, first_trace_addr);

    _ = sentry.captureEvent(sentry_event) catch |err| {
        std.debug.print("cannot capture event, {}\n", .{err});
    };
}

pub fn createSentryEvent(msg: []const u8, first_trace_addr: ?usize) Event {
    const stacktrace = stack_trace.collectStackTrace(allocator, first_trace_addr) catch |err| {
        std.debug.print("Warning: Failed to collect stack trace: {}\n", .{err});
        return createMinimalEvent(msg);
    };

    return createEventWithStacktrace(msg, stacktrace);
}

/// Create a Sentry event with the provided stacktrace
fn createEventWithStacktrace(msg: []const u8, stacktrace: StackTrace) Event {
    // Create exception
    const exception = Exception{
        .type = allocator.dupe(u8, "panic") catch "panic",
        .value = allocator.dupe(u8, msg) catch msg,
        .module = null,
        .thread_id = null,
        .stacktrace = stacktrace,
        .mechanism = null,
    };

    // Create the event
    return Event{
        .event_id = EventId.new(),
        .timestamp = @as(f64, @floatFromInt(std.time.timestamp())),
        .platform = "native",
        .level = Level.@"error",
        .exception = exception,
        .logger = allocator.dupe(u8, "panic_handler") catch "panic_handler",
    };
}

/// Create a minimal Sentry event without stacktrace (for critical memory situations)
fn createMinimalEvent(msg: []const u8) Event {
    // Create exception without stacktrace
    const exception = Exception{
        .type = "panic", // Use string literal to avoid allocation
        .value = msg, // Use original message to avoid allocation
        .module = null,
        .thread_id = null,
        .stacktrace = null, // No stacktrace due to memory constraints
        .mechanism = null,
    };

    // Create minimal event
    return Event{
        .event_id = EventId.new(),
        .timestamp = @as(f64, @floatFromInt(std.time.timestamp())),
        .platform = "native",
        .level = Level.@"error",
        .exception = exception,
        .logger = "panic_handler", // Use string literal to avoid allocation
    };
}

// Testable send callback plumbing
const SendCallback = *const fn (Event) void;
var send_callback: ?SendCallback = null;

fn setSendCallback(cb: SendCallback) void {
    send_callback = cb;
}

fn sendToSentry(event: Event) void {
    if (send_callback) |cb| cb(event);
}

// Helper for tests: same as panic_handler but without process exit
fn panic_handler_test_entry(allocator: Allocator, msg: []const u8, first_trace_addr: ?usize) void {
    const sentry_event = createSentryEvent(allocator, msg, first_trace_addr);
    sendToSentry(sentry_event);
}

test "panic_handler: send callback is invoked with created event" {
    const allocator = std.testing.allocator;

    // test-state globals and callback
    test_send_called = false;
    test_send_captured_msg = null;
    setSendCallback(testSendCb);

    const test_msg = "unit-test-message";
    var sentry_event = createSentryEvent(allocator, test_msg, @returnAddress());
    defer sentry_event.deinit(allocator);

    sendToSentry(sentry_event);

    try std.testing.expect(test_send_called);
    try std.testing.expect(test_send_captured_msg != null);
    try std.testing.expect(std.mem.eql(u8, test_send_captured_msg.?, test_msg));
}

// Dummy call chain to validate symbol extraction and stack capture
fn ph_test_one() !Event {
    return try ph_test_two();
}
fn ph_test_two() !Event {
    return try ph_test_three();
}
fn ph_test_three() !Event {
    return try ph_test_four();
}
fn ph_test_four() !Event {
    const allocator = std.testing.allocator;
    // Produce an event through a small call chain so that symbol names are available in frames
    const stacktrace = try stack_trace.collectStackTrace(allocator, @returnAddress());
    return createEventWithStacktrace("chain", stacktrace);
}

test "panic_handler: stacktrace has frames and instruction addresses" {
    const allocator = std.testing.allocator;
    var ev = try ph_test_one();
    defer ev.deinit(allocator);

    try std.testing.expect(ev.exception != null);
    const st = ev.exception.?.stacktrace.?;
    try std.testing.expect(st.frames.len > 0);
    for (st.frames) |f| {
        try std.testing.expect(f.instruction_addr != null);
    }
}

test "panic_handler: stacktrace captures dummy function names (skip without debug info)" {
    const builtin = @import("builtin");

    // Skip on Windows due to platform-specific debug info issues
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const debugInfo = std.debug.getSelfDebugInfo() catch null;
    if (debugInfo == null) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var ev = try ph_test_one();
    defer ev.deinit(allocator);

    const st = ev.exception.?.stacktrace.?;

    var have_one = false;
    var have_two = false;
    var have_three = false;
    for (st.frames) |f| {
        if (f.function) |fn_name| {
            if (std.mem.eql(u8, fn_name, "ph_test_one")) have_one = true;
            if (std.mem.eql(u8, fn_name, "ph_test_two")) have_two = true;
            if (std.mem.eql(u8, fn_name, "ph_test_three")) have_three = true;
        }
    }
    try std.testing.expect(have_one);
    try std.testing.expect(have_two);
    try std.testing.expect(have_three);
}

test "panic_handler: stacktrace works on Windows (addresses and basic symbols)" {
    const builtin = @import("builtin");

    // Only run on Windows
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const debugInfo = std.debug.getSelfDebugInfo() catch null;
    if (debugInfo == null) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var ev = try ph_test_one();
    defer ev.deinit(allocator);

    try std.testing.expect(ev.exception != null);
    const st = ev.exception.?.stacktrace.?;
    try std.testing.expect(st.frames.len > 0);

    // Verify we have instruction addresses (this should always work)
    for (st.frames) |f| {
        try std.testing.expect(f.instruction_addr != null);
    }

    // On Windows, function names might be formatted differently
    // Look for any frames that have function names (less strict than Unix test)
    var found_any_function_name = false;
    for (st.frames) |f| {
        if (f.function) |fn_name| {
            found_any_function_name = true;
            // Windows might prefix with "test." or format differently
            // Just verify we got some function information
            try std.testing.expect(fn_name.len > 0);
        }
    }

    // Windows should be able to extract at least some function names
    try std.testing.expect(found_any_function_name);
}

test "panic_handler: Windows function name format detection" {
    const builtin = @import("builtin");

    // Only run on Windows
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const debugInfo = std.debug.getSelfDebugInfo() catch null;
    if (debugInfo == null) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var ev = try ph_test_one();
    defer ev.deinit(allocator);

    const st = ev.exception.?.stacktrace.?;

    // Look for Windows-style function names (might be prefixed with "test.")
    var have_ph_test = false;
    for (st.frames) |f| {
        if (f.function) |fn_name| {
            // Windows might format as "test.ph_test_one" or just "ph_test_one"
            if (std.mem.indexOf(u8, fn_name, "ph_test")) |_| {
                have_ph_test = true;
            }
        }
    }

    // We should find at least one of our test functions
    try std.testing.expect(have_ph_test);
}

// Test-only globals and callback
var test_send_called: bool = false;
var test_send_captured_msg: ?[]const u8 = null;
fn testSendCb(ev: Event) void {
    test_send_called = true;
    if (ev.exception) |ex| test_send_captured_msg = ex.value;
}
