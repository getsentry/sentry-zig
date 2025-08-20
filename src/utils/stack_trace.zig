const std = @import("std");
const types = @import("types");
const Frame = types.Frame;
const StackTrace = types.StackTrace;

/// Collects stack trace frames from the given initial address.
/// Allocates memory for frames and returns a StackTrace.
pub fn collectStackTrace(allocator: std.mem.Allocator, first_trace_addr: ?usize) !StackTrace {
    var frames_list = std.ArrayList(Frame).init(allocator);
    errdefer {
        for (frames_list.items) |*frame| {
            frame.deinit(allocator);
        }
        frames_list.deinit();
    }

    const debug_info = std.debug.getSelfDebugInfo() catch null;
    var stack_iterator = std.debug.StackIterator.init(first_trace_addr, null);

    // Optionally include the first address as its own frame
    if (first_trace_addr) |addr| {
        var first_frame = Frame{
            .instruction_addr = try std.fmt.allocPrint(allocator, "0x{x}", .{addr}),
        };
        if (debug_info) |di| {
            extractSymbolInfo(allocator, di, addr, &first_frame);
        }
        try frames_list.append(first_frame);
    }

    // Collect all frames dynamically
    while (stack_iterator.next()) |return_address| {
        var frame = Frame{
            .instruction_addr = try std.fmt.allocPrint(allocator, "0x{x}", .{return_address}),
        };

        // Best-effort symbol extraction
        if (debug_info) |di| {
            extractSymbolInfo(allocator, di, return_address, &frame);
        }

        try frames_list.append(frame);
    }

    // Reverse the frames to match Sentry's expected order (inner -> outer)
    const frames = try frames_list.toOwnedSlice();
    std.mem.reverse(Frame, frames);

    return StackTrace{
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
            frame.deinit(allocator);
        }
        frames_list.deinit();
    }

    const debug_info = std.debug.getSelfDebugInfo() catch null;

    // Process addresses from the error trace
    for (trace.instruction_addresses[0..trace.index]) |addr| {
        var frame = Frame{
            .instruction_addr = try std.fmt.allocPrint(allocator, "0x{x}", .{addr}),
        };

        // Best-effort symbol extraction
        if (debug_info) |di| {
            extractSymbolInfo(allocator, di, addr, &frame);
        }

        try frames_list.append(frame);
    }

    if (frames_list.items.len == 0) return null;

    // Reverse the frames to match Sentry's expected order (inner -> outer)
    const frames = try frames_list.toOwnedSlice();
    std.mem.reverse(Frame, frames);

    return StackTrace{
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
    defer stacktrace.deinit(allocator);

    try std.testing.expect(stacktrace.frames.len > 0);
    for (stacktrace.frames) |frame| {
        try std.testing.expect(frame.instruction_addr != null);
    }
}

test "parseSymbolLine extracts file and line info" {
    const allocator = std.testing.allocator;

    var frame = Frame{};
    defer frame.deinit(allocator);

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
