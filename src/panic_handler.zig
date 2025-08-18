const std = @import("std");
const Types = @import("Types.zig");
const Event = @import("types/Event.zig");
const Level = @import("types/Level.zig").Level;

const SentryStackTrace = Event.StackTrace;
const SentryFrame = Event.Frame;
pub const SentryEvent = Event.Event;
const SentryException = Event.Exception;
const SentryMessage = Event.Message;

/// TODO: Replace with allocator from the sentry client
const allocator = std.heap.page_allocator;

pub fn panic_handler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    const sentry_event = createSentryEvent(msg, first_trace_addr);

    sendToSentry(sentry_event);

    std.process.exit(1);
}

pub fn createSentryEvent(msg: []const u8, first_trace_addr: ?usize) SentryEvent {
    // Check if debug info is available by trying to get it
    const debug_info = std.debug.getSelfDebugInfo() catch null;

    // Create ArrayList to dynamically grow frames - no size limit!
    var frames_list = std.ArrayList(SentryFrame).init(allocator);

    // We'll create the event at the end after collecting frames
    var stack_iterator = std.debug.StackIterator.init(first_trace_addr, null);

    // Collect all frames dynamically - never fail due to buffer size!
    while (stack_iterator.next()) |return_address| {
        var frame = SentryFrame{
            .instruction_addr = std.fmt.allocPrint(allocator, "0x{x}", .{return_address}) catch null,
        };

        // Try to extract symbol information if debug info is available
        if (debug_info) |di| {
            extractSymbolInfoSentry(di, return_address, &frame);
        }

        // Add frame to dynamic list - this should never fail unless out of memory
        frames_list.append(frame) catch |err| {
            // If we truly run out of memory, at least we have what we collected so far
            std.debug.print("Warning: Failed to add frame due to memory: {}\n", .{err});
            break;
        };
    }

    // Convert to owned slice
    const frames_slice = frames_list.toOwnedSlice() catch &[_]SentryFrame{};

    // Cast away const for the frames field (Sentry expects mutable slice)
    const frames: []SentryFrame = @constCast(frames_slice);

    // Create stacktrace
    const stacktrace = SentryStackTrace{
        .frames = frames,
        .registers = null,
    };

    // Create exception
    const exception = SentryException{
        .type = allocator.dupe(u8, "panic") catch "panic",
        .value = allocator.dupe(u8, msg) catch msg,
        .module = null,
        .thread_id = null,
        .stacktrace = stacktrace,
        .mechanism = null,
    };

    // Create the event
    const event = SentryEvent{
        .event_id = Event.EventId.new(),
        .timestamp = @as(f64, @floatFromInt(std.time.timestamp())),
        .platform = "native",
        .level = Level.@"error",
        .exception = exception,
        .logger = allocator.dupe(u8, "panic_handler") catch "panic_handler",
    };

    return event;
}

fn extractSymbolInfoSentry(debug_info: *std.debug.SelfInfo, addr: usize, frame: *SentryFrame) void {
    // Try to get symbol information - wrap in catch to prevent panics
    var temp_buffer: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&temp_buffer);

    // Try to capture the formatted output with no color
    const tty_config = std.io.tty.Config.no_color;
    std.debug.printSourceAtAddress(debug_info, fbs.writer(), addr, tty_config) catch return;

    const output = fbs.getWritten();
    if (output.len == 0) return;

    // Parse the output to extract individual components
    // Format is typically: "file:line:column: address in function (binary)"
    var lines = std.mem.splitScalar(u8, output, '\n');
    if (lines.next()) |first_line| {
        parseSymbolLineSentry(first_line, frame);
    }
}

fn parseSymbolLineSentry(line: []const u8, frame: *SentryFrame) void {
    // Parse a line like: "/path/to/file.zig:13:5: 0x123456 in function_name (binary)"

    // Find the first colon to separate file from line number
    if (std.mem.indexOf(u8, line, ":")) |first_colon| {
        // Extract file name and store it dynamically
        const file_part = line[0..first_colon];
        frame.filename = allocator.dupe(u8, file_part) catch null;
        frame.abs_path = allocator.dupe(u8, file_part) catch null;

        // Parse the rest: "line:column: addr in function (binary)"
        const rest = line[first_colon + 1 ..];

        // Find the next colon for line number
        if (std.mem.indexOf(u8, rest, ":")) |second_colon| {
            const line_str = rest[0..second_colon];
            frame.lineno = std.fmt.parseInt(u32, line_str, 10) catch null;

            // Parse column if present
            const after_line = rest[second_colon + 1 ..];
            if (std.mem.indexOf(u8, after_line, ":")) |third_colon| {
                const col_str = after_line[0..third_colon];
                frame.colno = std.fmt.parseInt(u32, col_str, 10) catch null;

                // Look for function name after " in "
                const after_col = after_line[third_colon + 1 ..];
                if (std.mem.indexOf(u8, after_col, " in ")) |in_pos| {
                    const after_in = after_col[in_pos + 4 ..];
                    if (std.mem.indexOf(u8, after_in, " ")) |space_pos| {
                        const func_name = after_in[0..space_pos];
                        frame.function = allocator.dupe(u8, func_name) catch null;
                    }
                }
            }
        }
    }
}

fn sendToSentry(event: SentryEvent) void {
    _ = event; // Suppress unused parameter warning until implemented
    // TODO: Implement actual sending to Sentry
}
