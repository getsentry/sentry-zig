const std = @import("std");
const types = @import("types");
const sentry = @import("root.zig");

// Top-level type aliases
const Event = types.Event;
const EventId = types.EventId;
const StackTrace = types.StackTrace;
const Level = types.Level;
const Exception = types.Exception;
const Frame = types.Frame;

/// TODO: Replace with allocator from the sentry client
const allocator = std.heap.page_allocator;

pub fn panic_handler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    std.log.debug("panic handler", .{});

    const sentry_event = createSentryEvent(msg, first_trace_addr);
    std.log.debug("created event", .{});

    _ = sentry.captureEvent(sentry_event);

    std.process.exit(1);
}

pub fn createSentryEvent(msg: []const u8, first_trace_addr: ?usize) Event {
    // Create ArrayList to dynamically grow frames - no size limit!
    var frames_list = std.ArrayList(Frame).init(allocator);

    // We'll create the event at the end after collecting frames
    var stack_iterator = std.debug.StackIterator.init(first_trace_addr, null);
    const debug_info = std.debug.getSelfDebugInfo() catch null;

    // Optionally include the first address as its own frame to ensure the current function is captured
    if (first_trace_addr) |addr| {
        var first_frame = Frame{
            .instruction_addr = std.fmt.allocPrint(allocator, "0x{x}", .{addr}) catch null,
        };
        if (debug_info) |di| {
            extractSymbolInfoSentry(di, addr, &first_frame);
        }
        frames_list.append(first_frame) catch |err| {
            first_frame.deinit(allocator);
            std.debug.print("Warning: Failed to add first frame due to memory: {}\n", .{err});
        };
    }

    // Collect all frames dynamically - never fail due to buffer size!
    while (stack_iterator.next()) |return_address| {
        var frame = Frame{
            .instruction_addr = std.fmt.allocPrint(allocator, "0x{x}", .{return_address}) catch null,
        };

        // Best-effort symbol extraction (kept as optional; addresses remain authoritative)
        if (debug_info) |di| {
            extractSymbolInfoSentry(di, return_address, &frame);
        }

        // Add frame to dynamic list - this should never fail unless out of memory
        frames_list.append(frame) catch |err| {
            // Free strings allocated in this frame since we failed to append it
            frame.deinit(allocator);
            // If we truly run out of memory, at least we have what we collected so far
            std.debug.print("Warning: Failed to add frame due to memory: {}\n", .{err});
            break;
        };
    }

    // Convert to owned slice with robust error handling
    const frames: []Frame = frames_list.toOwnedSlice() catch {
        // If toOwnedSlice fails, we need to clean up and provide a safe fallback
        std.debug.print("Warning: Failed to convert frames list to owned slice, attempting recovery...\n", .{});

        // First try to salvage any frames we collected
        var collected_frames = frames_list.items;

        // Always clean up the ArrayList to prevent memory leaks
        defer frames_list.deinit();

        if (collected_frames.len > 0) {
            // Try to allocate new memory and copy the frames
            if (allocator.alloc(Frame, collected_frames.len)) |salvaged| {
                // Deep-copy strings inside frames that we allocated earlier
                // so that deinit on the new frames slice is safe
                var i: usize = 0;
                while (i < collected_frames.len) : (i += 1) {
                    const src = collected_frames[i];
                    var dst = Frame{};
                    dst.filename = if (src.filename) |s| allocator.dupe(u8, s) catch null else null;
                    dst.abs_path = if (src.abs_path) |s| allocator.dupe(u8, s) catch null else null;
                    dst.function = if (src.function) |s| allocator.dupe(u8, s) catch null else null;
                    dst.instruction_addr = if (src.instruction_addr) |s| allocator.dupe(u8, s) catch null else null;
                    dst.module = if (src.module) |s| allocator.dupe(u8, s) catch null else null;
                    dst.symbol = if (src.symbol) |s| allocator.dupe(u8, s) catch null else null;
                    dst.symbol_addr = if (src.symbol_addr) |s| allocator.dupe(u8, s) catch null else null;
                    dst.image_addr = if (src.image_addr) |s| allocator.dupe(u8, s) catch null else null;
                    dst.platform = if (src.platform) |s| allocator.dupe(u8, s) catch null else null;
                    dst.package = if (src.package) |s| allocator.dupe(u8, s) catch null else null;
                    dst.context_line = if (src.context_line) |s| allocator.dupe(u8, s) catch null else null;
                    dst.pre_context = null; // not used/populated here
                    dst.post_context = null; // not used/populated here
                    dst.vars = null; // not used
                    dst.in_app = src.in_app;
                    dst.lineno = src.lineno;
                    dst.colno = src.colno;
                    salvaged[i] = dst;
                }
                // Now free all allocated strings in the original frames
                // before releasing the backing ArrayList memory
                i = 0;
                while (i < collected_frames.len) : (i += 1) {
                    collected_frames[i].deinit(allocator);
                }
                std.debug.print("Successfully salvaged {d} frames after allocation failure\n", .{collected_frames.len});
                return createEventWithFrames(msg, salvaged);
            } else |_| {
                std.debug.print("Failed to salvage {d} frames due to memory constraints\n", .{collected_frames.len});
                // Ensure we free any strings allocated inside the collected frames
                var j: usize = 0;
                while (j < collected_frames.len) : (j += 1) {
                    collected_frames[j].deinit(allocator);
                }
            }
        }

        // Fallback: create an empty but valid slice that can be safely freed
        const empty_frames = allocator.alloc(Frame, 0) catch {
            // If we can't even allocate an empty slice, we have a critical memory issue
            // In this case, we'll create a minimal event without a stacktrace
            std.debug.print("CRITICAL: Cannot allocate memory for stacktrace - creating minimal event\n", .{});
            return createMinimalEvent(msg);
        };

        return createEventWithFrames(msg, empty_frames);
    };

    return createEventWithFrames(msg, frames);
}

/// Create a Sentry event with the provided frames
fn createEventWithFrames(msg: []const u8, frames: []Frame) Event {
    // Create stacktrace
    const stacktrace = StackTrace{
        .frames = frames,
        .registers = null,
    };

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

// Best-effort local symbol parsing as a non-fatal enhancement. If it fails,
// addresses still provide server-side symbolication.
fn extractSymbolInfoSentry(debug_info: *std.debug.SelfInfo, addr: usize, frame: *Frame) void {
    var temp_buffer: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&temp_buffer);
    const tty_config = std.io.tty.Config.no_color;
    std.debug.printSourceAtAddress(debug_info, fbs.writer(), addr, tty_config) catch return;

    const output = fbs.getWritten();
    if (output.len == 0) return;

    var lines = std.mem.splitScalar(u8, output, '\n');
    if (lines.next()) |first_line| {
        parseSymbolLineSentry(first_line, frame);
    }
}

fn parseSymbolLineSentry(line: []const u8, frame: *Frame) void {
    if (std.mem.indexOf(u8, line, ":")) |first_colon| {
        const file_part = line[0..first_colon];
        frame.filename = allocator.dupe(u8, file_part) catch null;
        frame.abs_path = allocator.dupe(u8, file_part) catch null;

        const rest = line[first_colon + 1 ..];
        if (std.mem.indexOf(u8, rest, ":")) |second_colon| {
            const line_str = rest[0..second_colon];
            frame.lineno = std.fmt.parseInt(u32, line_str, 10) catch null;

            const after_line = rest[second_colon + 1 ..];
            if (std.mem.indexOf(u8, after_line, ":")) |third_colon| {
                const col_str = after_line[0..third_colon];
                frame.colno = std.fmt.parseInt(u32, col_str, 10) catch null;

                const after_col = after_line[third_colon + 1 ..];
                if (std.mem.indexOf(u8, after_col, " in ")) |in_pos| {
                    const after_in = after_col[in_pos + 4 ..];
                    if (std.mem.indexOf(u8, after_in, " ")) |space_pos| {
                        const func_name = after_in[0..space_pos];
                        frame.function = allocator.dupe(u8, func_name) catch null;
                    } else {
                        // No trailing space; take the rest as function name
                        if (after_in.len > 0) {
                            frame.function = allocator.dupe(u8, after_in) catch null;
                        }
                    }
                }
            }
        }
    }
}

// Testable send callback plumbing
pub const SendCallback = *const fn (Event) void;
var send_callback: ?SendCallback = null;

pub fn setSendCallback(cb: SendCallback) void {
    send_callback = cb;
}

fn sendToSentry(event: Event) void {
    if (send_callback) |cb| cb(event);
}

// Helper for tests: same as panic_handler but without process exit
pub fn panic_handler_test_entry(msg: []const u8, first_trace_addr: ?usize) void {
    const sentry_event = createSentryEvent(msg, first_trace_addr);
    sendToSentry(sentry_event);
}

test "panic_handler: send callback is invoked with created event" {
    // test-state globals and callback
    test_send_called = false;
    test_send_captured_msg = null;
    setSendCallback(testSendCb);

    const test_msg = "unit-test-message";
    panic_handler_test_entry(test_msg, @returnAddress());

    try std.testing.expect(test_send_called);
    try std.testing.expect(test_send_captured_msg != null);
    try std.testing.expect(std.mem.eql(u8, test_send_captured_msg.?, test_msg));
}

// Dummy call chain to validate symbol extraction and stack capture
fn ph_test_one() !void {
    try ph_test_two();
}
fn ph_test_two() !void {
    try ph_test_three();
}
fn ph_test_three() !void {
    try ph_test_four();
}
fn ph_test_four() !void {
    const ev = createSentryEvent("chain", @returnAddress());
    // Validate we have frames and addresses
    try std.testing.expect(ev.exception != null);
    const st = ev.exception.?.stacktrace.?;
    try std.testing.expect(st.frames.len > 0);
    // Every frame should at least have an instruction address
    for (st.frames) |f| {
        try std.testing.expect(f.instruction_addr != null);
    }
    // Best-effort: function names should include our dummy functions (no line assertions)
    var have_one = false;
    var have_two = false;
    var have_three = false;
    var have_four = false;
    for (st.frames) |f| {
        if (f.function) |fn_name| {
            if (std.mem.eql(u8, fn_name, "ph_test_one")) have_one = true;
            if (std.mem.eql(u8, fn_name, "ph_test_two")) have_two = true;
            if (std.mem.eql(u8, fn_name, "ph_test_three")) have_three = true;
            if (std.mem.eql(u8, fn_name, "ph_test_four")) have_four = true;
        }
    }
    // Do not assert order or line numbers; only presence of at least three frames in chain
    try std.testing.expect(have_one and have_two and have_three);
}

test "panic_handler: stacktrace captures dummy function names (no line asserts)" {
    try ph_test_one();
}

// Test-only globals and callback
var test_send_called: bool = false;
var test_send_captured_msg: ?[]const u8 = null;
fn testSendCb(ev: Event) void {
    test_send_called = true;
    if (ev.exception) |ex| test_send_captured_msg = ex.value;
}
