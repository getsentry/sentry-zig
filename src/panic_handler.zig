const std = @import("std");
const types = @import("types");
const sentry = @import("root.zig");
const scope = @import("scope.zig");
const Allocator = std.mem.Allocator;

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

fn createSentryEvent(allocator: Allocator, msg: []const u8, first_trace_addr: ?usize) Event {
    // Create ArrayList to dynamically grow frames - no size limit!
    var frames_list = std.ArrayList(Frame).init(allocator);

    // We'll create the event at the end after collecting frames
    var stack_iterator = std.debug.StackIterator.init(first_trace_addr, null);
    const debug_info = std.debug.getSelfDebugInfo() catch null;

    // Get project root for frame categorization
    const project_root = getProjectRoot();
    defer if (project_root) |root| std.heap.page_allocator.free(root);

    // Optionally include the first address as its own frame to ensure the current function is captured
    if (first_trace_addr) |addr| {
        var first_frame = Frame{
            .instruction_addr = std.fmt.allocPrint(allocator, "0x{x}", .{addr}) catch null,
        };
        if (debug_info) |di| {
            extractSymbolInfoWithCategorization(allocator, di, addr, &first_frame, project_root);
        } else {
            // No debug info available, categorize based on limited information
            categorizeFrame(&first_frame, project_root);
        }

        // Only add frame if it's valid
        if (isValidFrame(&first_frame)) {
            frames_list.append(first_frame) catch |err| {
                first_frame.deinit(allocator);
                std.debug.print("Warning: Failed to add first frame due to memory: {}\n", .{err});
            };
        } else {
            first_frame.deinit(allocator);
            std.debug.print("Warning: Skipping invalid first frame\n", .{});
        }
    }

    // Collect all frames dynamically - never fail due to buffer size!
    while (stack_iterator.next()) |return_address| {
        var frame = Frame{
            .instruction_addr = std.fmt.allocPrint(allocator, "0x{x}", .{return_address}) catch null,
        };

        // Best-effort symbol extraction with categorization (kept as optional; addresses remain authoritative)
        if (debug_info) |di| {
            extractSymbolInfoWithCategorization(allocator, di, return_address, &frame, project_root);
        } else {
            // No debug info available, categorize based on limited information
            categorizeFrame(&frame, project_root);
        }

        // Only add frame if it's valid
        if (isValidFrame(&frame)) {
            frames_list.append(frame) catch |err| {
                // Free strings allocated in this frame since we failed to append it
                frame.deinit(allocator);
                // If we truly run out of memory, at least we have what we collected so far
                std.debug.print("Warning: Failed to add frame due to memory: {}\n", .{err});
                break;
            };
        } else {
            frame.deinit(allocator);
            // Skip invalid frames silently - they would just be "????" frames
        }
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
                return createEventWithFrames(allocator, msg, salvaged);
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

        return createEventWithFrames(allocator, msg, empty_frames);
    };

    return createEventWithFrames(allocator, msg, frames);
}

/// Create a Sentry event with the provided frames
fn createEventWithFrames(allocator: Allocator, msg: []const u8, frames: []Frame) Event {
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
fn extractSymbolInfoSentry(allocator: Allocator, debug_info: *std.debug.SelfInfo, addr: usize, frame: *Frame) void {
    var temp_buffer: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&temp_buffer);
    const tty_config = std.io.tty.Config.no_color;
    std.debug.printSourceAtAddress(debug_info, fbs.writer(), addr, tty_config) catch return;

    const output = fbs.getWritten();
    if (output.len == 0) return;

    var lines = std.mem.splitScalar(u8, output, '\n');
    if (lines.next()) |first_line| {
        parseSymbolLineSentry(allocator, first_line, frame);
    }
}

fn parseSymbolLineSentry(allocator: Allocator, line: []const u8, frame: *Frame) void {
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
                    // Handle both Unix and Windows formats
                    // Unix: "0x123 in function_name (file.zig)"
                    // Windows: "0x123 in function_name (test.exe.obj)"
                    // Complex: "0x123 in test.function: name with spaces (file.zig)"
                    var func_name = after_in;

                    // Remove the parenthetical module suffix like "(test.exe.obj)" or "(file.zig)"
                    if (std.mem.lastIndexOf(u8, func_name, " (")) |last_space_paren| {
                        func_name = func_name[0..last_space_paren];
                    }

                    func_name = std.mem.trim(u8, func_name, " \t\r\n");
                    if (func_name.len > 0) {
                        frame.function = allocator.dupe(u8, func_name) catch null;
                    }
                }
            }
        }
    }
}

// ===== FRAME DETECTION AND CATEGORIZATION SYSTEM =====

/// Get the project root directory for frame categorization
fn getProjectRoot() ?[]const u8 {
    // Try environment variable first
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "SENTRY_PROJECT_ROOT")) |root| {
        return root;
    } else |_| {}

    // Try to detect from current working directory
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.process.getCwd(&buf)) |cwd| {
        // Look for common project indicators
        const indicators = [_][]const u8{ "build.zig", "build.zig.zon", ".git", "src" };
        for (indicators) |indicator| {
            const indicator_path = std.fs.path.join(std.heap.page_allocator, &[_][]const u8{ cwd, indicator }) catch continue;
            defer std.heap.page_allocator.free(indicator_path);

            if (std.fs.accessAbsolute(indicator_path, .{})) {
                return std.heap.page_allocator.dupe(u8, cwd) catch null;
            } else |_| continue;
        }
    } else |_| {}

    return null;
}

/// Check if a frame is valid and contains meaningful information
fn isValidFrame(frame: *const Frame) bool {
    // Must have an instruction address
    if (frame.instruction_addr == null) return false;

    // If we have no symbol information at all, it might be corrupted
    if (frame.filename == null and frame.function == null and frame.abs_path == null) {
        // Check if instruction address looks valid (hex format)
        if (frame.instruction_addr) |addr_str| {
            if (addr_str.len < 3 or !std.mem.startsWith(u8, addr_str, "0x")) {
                return false;
            }
        }
        // Allow frames with only instruction addresses - they can be symbolicated server-side
        return true;
    }

    return true;
}

/// Check if a frame belongs to system/standard library code
fn isSystemFrame(filename: ?[]const u8, function: ?[]const u8) bool {
    if (filename) |file| {
        // Zig standard library
        if (std.mem.indexOf(u8, file, "/lib/zig/std/") != null) return true;
        if (std.mem.indexOf(u8, file, "\\lib\\zig\\std\\") != null) return true;

        // System libraries (Unix)
        if (std.mem.indexOf(u8, file, "/usr/lib/") != null) return true;
        if (std.mem.indexOf(u8, file, "/lib/") != null) return true;
        if (std.mem.indexOf(u8, file, "/lib64/") != null) return true;

        // System libraries (Windows)
        if (std.mem.indexOf(u8, file, "\\Windows\\System32\\") != null) return true;
        if (std.mem.indexOf(u8, file, "\\Windows\\SysWOW64\\") != null) return true;

        // Common system files
        if (std.mem.endsWith(u8, file, "libc.so") or std.mem.endsWith(u8, file, "libc.dylib")) return true;
        if (std.mem.endsWith(u8, file, "kernel32.dll") or std.mem.endsWith(u8, file, "ntdll.dll")) return true;
        if (std.mem.endsWith(u8, file, "libpthread.so") or std.mem.endsWith(u8, file, "libm.so")) return true;
    }

    if (function) |func| {
        // Known system function patterns
        const system_prefixes = [_][]const u8{ "__", "_start", "main.", "std.", "builtin.", "kernel32.", "ntdll.", "libc.", "pthread_" };

        for (system_prefixes) |prefix| {
            if (std.mem.startsWith(u8, func, prefix)) return true;
        }
    }

    return false;
}

/// Check if a frame belongs to application code
fn isApplicationFrame(filename: ?[]const u8, function: ?[]const u8, project_root: ?[]const u8) bool {
    // If it's a system frame, it's definitely not application code
    if (isSystemFrame(filename, function)) return false;

    if (project_root) |root| {
        if (filename) |file| {
            // Check if file is within project directory
            if (std.mem.startsWith(u8, file, root)) {
                return true;
            }

            // Handle relative paths - check if it looks like project code
            if (std.mem.indexOf(u8, file, "src/") != null or
                std.mem.indexOf(u8, file, "src\\") != null)
            {
                return true;
            }
        }
    }

    // If no project root, use heuristics
    if (filename) |file| {
        // Look for common application patterns
        if (std.mem.indexOf(u8, file, "src/") != null or
            std.mem.indexOf(u8, file, "src\\") != null or
            std.mem.endsWith(u8, file, ".zig"))
        {

            // But exclude if it's clearly system code
            if (std.mem.indexOf(u8, file, "/lib/zig/") == null and
                std.mem.indexOf(u8, file, "\\lib\\zig\\") == null)
            {
                return true;
            }
        }
    }

    if (function) |func| {
        // Application functions typically don't have system prefixes
        if (!std.mem.startsWith(u8, func, "__") and
            !std.mem.startsWith(u8, func, "_start") and
            !std.mem.startsWith(u8, func, "std.") and
            !std.mem.startsWith(u8, func, "builtin."))
        {
            return true;
        }
    }

    return false;
}

/// Categorize a frame and set the in_app field appropriately
fn categorizeFrame(frame: *Frame, project_root: ?[]const u8) void {
    if (!isValidFrame(frame)) {
        frame.in_app = false;
        return;
    }

    if (isApplicationFrame(frame.filename, frame.function, project_root)) {
        frame.in_app = true;
    } else {
        frame.in_app = false;
    }
}

/// Enhanced symbol extraction that also categorizes frames
fn extractSymbolInfoWithCategorization(allocator: Allocator, debug_info: *std.debug.SelfInfo, addr: usize, frame: *Frame, project_root: ?[]const u8) void {
    // First extract symbol information
    extractSymbolInfoSentry(allocator, debug_info, addr, frame);

    // Then categorize the frame
    categorizeFrame(frame, project_root);
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
    return createSentryEvent(allocator, "chain", @returnAddress());
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

// ===== FRAME DETECTION TESTS =====

test "frame detection: isValidFrame correctly validates frames" {
    var frame_valid = Frame{
        .instruction_addr = "0x1234567890abcdef",
        .filename = "src/main.zig",
        .function = "main",
    };
    try std.testing.expect(isValidFrame(&frame_valid));

    var frame_only_addr = Frame{
        .instruction_addr = "0x1234567890abcdef",
    };
    try std.testing.expect(isValidFrame(&frame_only_addr));

    var frame_invalid_addr = Frame{
        .instruction_addr = "invalid",
    };
    try std.testing.expect(!isValidFrame(&frame_invalid_addr));

    var frame_no_addr = Frame{
        .filename = "src/main.zig",
    };
    try std.testing.expect(!isValidFrame(&frame_no_addr));
}

test "frame detection: isSystemFrame correctly identifies system frames" {
    // Zig standard library
    try std.testing.expect(isSystemFrame("/lib/zig/std/debug.zig", null));
    try std.testing.expect(isSystemFrame("\\lib\\zig\\std\\debug.zig", null));

    // System libraries
    try std.testing.expect(isSystemFrame("/usr/lib/libc.so", null));
    try std.testing.expect(isSystemFrame("/lib/libpthread.so", null));
    try std.testing.expect(isSystemFrame("\\Windows\\System32\\kernel32.dll", null));

    // System functions
    try std.testing.expect(isSystemFrame(null, "__libc_start_main"));
    try std.testing.expect(isSystemFrame(null, "std.debug.print"));
    try std.testing.expect(isSystemFrame(null, "builtin.panic"));

    // Not system
    try std.testing.expect(!isSystemFrame("src/main.zig", null));
    try std.testing.expect(!isSystemFrame(null, "myFunction"));
}

test "frame detection: isApplicationFrame correctly identifies app frames" {
    const project_root = "/home/user/myproject";

    // Application frames
    try std.testing.expect(isApplicationFrame("/home/user/myproject/src/main.zig", null, project_root));
    try std.testing.expect(isApplicationFrame("src/main.zig", null, null));
    try std.testing.expect(isApplicationFrame("src/lib.zig", "myFunction", null));

    // Not application frames (system)
    try std.testing.expect(!isApplicationFrame("/lib/zig/std/debug.zig", null, project_root));
    try std.testing.expect(!isApplicationFrame(null, "std.debug.print", project_root));
    try std.testing.expect(!isApplicationFrame("/usr/lib/libc.so", null, project_root));
}

test "frame detection: categorizeFrame sets in_app correctly" {
    const allocator = std.testing.allocator;
    const project_root = "/home/user/myproject";

    // Application frame
    var app_frame = Frame{
        .instruction_addr = allocator.dupe(u8, "0x1234567890abcdef") catch unreachable,
        .filename = allocator.dupe(u8, "/home/user/myproject/src/main.zig") catch unreachable,
        .function = allocator.dupe(u8, "main") catch unreachable,
    };
    defer app_frame.deinit(allocator);

    categorizeFrame(&app_frame, project_root);
    try std.testing.expect(app_frame.in_app == true);

    // System frame
    var sys_frame = Frame{
        .instruction_addr = allocator.dupe(u8, "0x1234567890abcdef") catch unreachable,
        .filename = allocator.dupe(u8, "/lib/zig/std/debug.zig") catch unreachable,
        .function = allocator.dupe(u8, "std.debug.print") catch unreachable,
    };
    defer sys_frame.deinit(allocator);

    categorizeFrame(&sys_frame, project_root);
    try std.testing.expect(sys_frame.in_app == false);

    // Invalid frame
    var invalid_frame = Frame{
        .instruction_addr = null,
    };

    categorizeFrame(&invalid_frame, project_root);
    try std.testing.expect(invalid_frame.in_app == false);
}

test "frame detection: project root detection" {
    // This test verifies that project root detection works
    // Note: actual detection depends on file system, so we mainly test it doesn't crash
    const maybe_root = getProjectRoot();
    if (maybe_root) |root| {
        defer std.heap.page_allocator.free(root);
        try std.testing.expect(root.len > 0);
    }
}

test "frame detection: enhanced symbol extraction with categorization" {
    const allocator = std.testing.allocator;
    const debug_info = std.debug.getSelfDebugInfo() catch return error.SkipZigTest;
    const project_root = getProjectRoot();
    defer if (project_root) |root| std.heap.page_allocator.free(root);

    var frame = Frame{
        .instruction_addr = std.fmt.allocPrint(allocator, "0x{x}", .{@returnAddress()}) catch return error.SkipZigTest,
    };
    defer frame.deinit(allocator);

    extractSymbolInfoWithCategorization(allocator, debug_info, @returnAddress(), &frame, project_root);

    // Frame should be categorized
    try std.testing.expect(frame.in_app != null);

    // This test function should be considered application code
    if (frame.function) |func_name| {
        if (std.mem.indexOf(u8, func_name, "test")) |_| {
            try std.testing.expect(frame.in_app == true);
        }
    }
}

test "frame detection: end-to-end categorization in panic handler" {
    const allocator = std.testing.allocator;
    var event = createSentryEvent(allocator, "test message", @returnAddress());
    defer event.deinit(allocator);

    try std.testing.expect(event.exception != null);
    const stacktrace = event.exception.?.stacktrace;
    try std.testing.expect(stacktrace != null);
    try std.testing.expect(stacktrace.?.frames.len > 0);

    // Verify that frames are properly categorized
    var found_categorized_frame = false;
    var found_non_null_in_app = false;

    for (stacktrace.?.frames) |frame| {
        // All frames should have instruction addresses
        try std.testing.expect(frame.instruction_addr != null);

        // All frames should be categorized (in_app should not be null)
        if (frame.in_app != null) {
            found_categorized_frame = true;
            found_non_null_in_app = true;
        }

        // Print frame info for debugging (but don't fail on specific expectations)
        if (frame.function) |func_name| {
            std.debug.print("Frame: {s}, in_app: {?}\n", .{ func_name, frame.in_app });
        } else if (frame.filename) |filename| {
            std.debug.print("Frame: {s}, in_app: {?}\n", .{ filename, frame.in_app });
        }
    }

    // The important thing is that frames are being categorized
    try std.testing.expect(found_categorized_frame);
    try std.testing.expect(found_non_null_in_app);
}
