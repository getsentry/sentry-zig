const std = @import("std");
const types = @import("types");
const sentry_build = @import("sentry_build");
const Frame = types.Frame;
const StackTrace = types.StackTrace;

/// Collects stack trace frames from the given initial address.
/// Allocates memory for frames and returns a StackTrace.
pub fn collectStackTrace(allocator: std.mem.Allocator, first_trace_addr: ?usize) !StackTrace {
    var frames_list = std.ArrayList(Frame).init(allocator);
    errdefer {
        for (frames_list.items) |*frame| {
            frame.deinit();
        }
        frames_list.deinit();
    }

    const debug_info = std.debug.getSelfDebugInfo() catch null;
    var stack_iterator = std.debug.StackIterator.init(first_trace_addr, null);

    const project_root = getProjectRoot(allocator);
    defer if (project_root) |root| allocator.free(root);

    // Optionally include the first address as its own frame
    if (first_trace_addr) |addr| {
        var first_frame = Frame{
            .allocator = allocator,
            .instruction_addr = try std.fmt.allocPrint(allocator, "0x{x}", .{addr}),
        };
        if (debug_info) |di| {
            extractSymbolInfoWithCategorization(allocator, di, addr, &first_frame, project_root);
        } else {
            categorizeFrame(&first_frame, project_root);
        }

        if (isValidFrame(&first_frame) and !isPanicHandlerFrame(first_frame.filename, first_frame.function)) {
            try frames_list.append(first_frame);
        } else {
            first_frame.deinit();
        }
    }

    // Collect all frames dynamically
    while (stack_iterator.next()) |return_address| {
        var frame = Frame{
            .allocator = allocator,
            .instruction_addr = try std.fmt.allocPrint(allocator, "0x{x}", .{return_address}),
        };

        // Best-effort symbol extraction with categorization
        if (debug_info) |di| {
            extractSymbolInfoWithCategorization(allocator, di, return_address, &frame, project_root);
        } else {
            categorizeFrame(&frame, project_root);
        }

        // Validate and filter frames
        if (isValidFrame(&frame) and !isPanicHandlerFrame(frame.filename, frame.function)) {
            try frames_list.append(frame);
        } else {
            frame.deinit();
        }
    }

    // Reverse the frames to match Sentry's expected order (inner -> outer)
    const frames = try frames_list.toOwnedSlice();
    std.mem.reverse(Frame, frames);

    return StackTrace{
        .allocator = allocator,
        .frames = frames,
        .registers = null,
    };
}

/// Collects stack trace from an error's return trace if available.
pub fn collectErrorTrace(allocator: std.mem.Allocator, err_trace: ?*std.builtin.StackTrace) !?StackTrace {
    const trace = err_trace orelse return null;

    var frames_list = std.ArrayList(Frame).init(allocator);
    errdefer {
        for (frames_list.items) |*frame| {
            frame.deinit();
        }
        frames_list.deinit();
    }

    const debug_info = std.debug.getSelfDebugInfo() catch null;

    const project_root = getProjectRoot(allocator);
    defer if (project_root) |root| allocator.free(root);

    // Process addresses from the error trace
    for (trace.instruction_addresses[0..trace.index]) |addr| {
        var frame = Frame{
            .allocator = allocator,
            .instruction_addr = try std.fmt.allocPrint(allocator, "0x{x}", .{addr}),
        };

        // Best-effort symbol extraction with categorization
        if (debug_info) |di| {
            extractSymbolInfoWithCategorization(allocator, di, addr, &frame, project_root);
        } else {
            categorizeFrame(&frame, project_root);
        }

        // Validate and filter frames
        if (isValidFrame(&frame) and !isPanicHandlerFrame(frame.filename, frame.function)) {
            try frames_list.append(frame);
        } else {
            frame.deinit();
        }
    }

    if (frames_list.items.len == 0) return null;

    // Reverse the frames to match Sentry's expected order (inner -> outer)
    const frames = try frames_list.toOwnedSlice();
    std.mem.reverse(Frame, frames);

    return StackTrace{
        .allocator = allocator,
        .frames = frames,
        .registers = null,
    };
}

/// Best-effort local symbol parsing as a non-fatal enhancement. If it fails,
/// addresses still provide server-side symbolication.
fn extractSymbolInfo(allocator: std.mem.Allocator, debug_info: *std.debug.SelfInfo, addr: usize, frame: *Frame) void {
    var temp_buffer: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&temp_buffer);
    const tty_config = std.io.tty.Config.no_color;
    std.debug.printSourceAtAddress(debug_info, fbs.writer(), addr, tty_config) catch return;

    const output = fbs.getWritten();
    if (output.len == 0) return;

    var lines = std.mem.splitScalar(u8, output, '\n');
    if (lines.next()) |first_line| {
        parseSymbolLine(allocator, first_line, frame);
    }
}

fn parseSymbolLine(allocator: std.mem.Allocator, line: []const u8, frame: *Frame) void {
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

test "collectStackTrace creates frames with addresses" {
    const allocator = std.testing.allocator;

    var stacktrace = try collectStackTrace(allocator, @returnAddress());
    defer stacktrace.deinit();

    try std.testing.expect(stacktrace.frames.len > 0);
    for (stacktrace.frames) |frame| {
        try std.testing.expect(frame.instruction_addr != null);
    }
}

fn getProjectRoot(allocator: std.mem.Allocator) ?[]const u8 {
    // Build-time injected project root is the sole source of truth
    if (sentry_build.sentry_project_root.len != 0) {
        return allocator.dupe(u8, sentry_build.sentry_project_root) catch null;
    }
    return null;
}

/// Check if a frame is valid and contains meaningful information
fn isValidFrame(frame: *const Frame) bool {
    // Must have an instruction address
    if (frame.instruction_addr == null) return false;

    // Check if instruction address looks valid (hex format and not null pointer)
    if (frame.instruction_addr) |addr_str| {
        if (addr_str.len < 3 or !std.mem.startsWith(u8, addr_str, "0x")) {
            return false;
        }
        // Reject null pointer addresses
        if (std.mem.eql(u8, addr_str, "0x0")) {
            return false;
        }
    }

    // Reject frames with "???" values - these are corrupted/unknown
    if (frame.filename) |filename| {
        if (std.mem.eql(u8, filename, "???")) return false;
    }
    if (frame.function) |function| {
        if (std.mem.eql(u8, function, "???")) return false;
    }
    if (frame.abs_path) |abs_path| {
        if (std.mem.eql(u8, abs_path, "???")) return false;
    }

    return true;
}

/// Check if a frame belongs to panic handler infrastructure that should be filtered out
fn isPanicHandlerFrame(filename: ?[]const u8, function: ?[]const u8) bool {
    if (filename) |file| {
        // If it's from panic_handler.zig, check if it's an internal function
        if (std.mem.indexOf(u8, file, "panic_handler.zig") != null) {

            // Only filter out if it's clearly an infrastructure function
            if (function) |func| {
                if (std.mem.eql(u8, func, "panicHandler") or
                    std.mem.eql(u8, func, "handlePanic") or
                    std.mem.eql(u8, func, "createSentryEvent") or
                    std.mem.eql(u8, func, "createEventWithFrames") or
                    std.mem.eql(u8, func, "createMinimalEvent")) return true;
            }
        }
    }

    return false;
}

/// Best effort to determine if a frame belongs to system/standard library code.
///
/// It will check if the stacktrace is from common places of the standard library.
/// If it's in a non standard library place, it may produce false positives.
fn isSystemFrame(filename: ?[]const u8, function: ?[]const u8) bool {
    _ = function; // unused in build-root classification
    if (filename) |file| {
        const root = sentry_build.sentry_project_root;
        if (root.len > 0) {
            if (std.mem.startsWith(u8, file, root)) return false; // in-app
            return true; // outside app root => treat as system/library
        }
    }
    // Without a build root, conservatively treat as system
    return true;
}

/// Best effort to determine if a frame belongs to application code.
///
/// This is a heuristic based on the filename and function name.
/// It is not perfect and may result in false positives.
///
/// The project_root is used to determine if the frame is in the project.
/// If it is not in the project, it is not application code.
fn isApplicationFrame(filename: ?[]const u8, function: ?[]const u8, project_root: ?[]const u8) bool {
    // Reject unknown/corrupted frames with "???" values
    if (filename) |file| {
        if (std.mem.eql(u8, file, "???")) return false;
    }
    if (function) |func| {
        if (std.mem.eql(u8, func, "???")) return false;
    }

    // Build-root based classification only
    if (project_root) |root| {
        if (filename) |file| {
            if (std.mem.startsWith(u8, file, root)) return true;
        }
        // Optional: if abs_path exists, could check it here as well
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
fn extractSymbolInfoWithCategorization(allocator: std.mem.Allocator, debug_info: *std.debug.SelfInfo, addr: usize, frame: *Frame, project_root: ?[]const u8) void {
    // First extract symbol information
    extractSymbolInfo(allocator, debug_info, addr, frame);

    // Then categorize the frame
    categorizeFrame(frame, project_root);
}

test "parseSymbolLine extracts file and line info" {
    const allocator = std.testing.allocator;

    var frame = Frame{
        .allocator = allocator,
    };
    defer frame.deinit();

    const test_line = "src/main.zig:42:13: 0x123456 in main (test.exe)";
    parseSymbolLine(allocator, test_line, &frame);

    try std.testing.expect(frame.filename != null);
    try std.testing.expectEqualStrings("src/main.zig", frame.filename.?);
    try std.testing.expect(frame.lineno != null);
    try std.testing.expectEqual(@as(u32, 42), frame.lineno.?);
    try std.testing.expect(frame.colno != null);
    try std.testing.expectEqual(@as(u32, 13), frame.colno.?);
    try std.testing.expect(frame.function != null);
    try std.testing.expectEqualStrings("main", frame.function.?);
}
