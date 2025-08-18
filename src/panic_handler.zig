const std = @import("std");
// const Types = @import("Types.zig"); // Unused; remove when no longer needed
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
    // Create ArrayList to dynamically grow frames - no size limit!
    var frames_list = std.ArrayList(SentryFrame).init(allocator);

    // We'll create the event at the end after collecting frames
    var stack_iterator = std.debug.StackIterator.init(first_trace_addr, null);
    const debug_info = std.debug.getSelfDebugInfo() catch null;

    // Collect all frames dynamically - never fail due to buffer size!
    while (stack_iterator.next()) |return_address| {
        var frame = SentryFrame{
            .instruction_addr = std.fmt.allocPrint(allocator, "0x{x}", .{return_address}) catch null,
        };

        // Best-effort symbol extraction (kept as optional; addresses remain authoritative)
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

    // Convert to owned slice with robust error handling
    const frames: []SentryFrame = frames_list.toOwnedSlice() catch {
        // If toOwnedSlice fails, we need to clean up and provide a safe fallback
        std.debug.print("Warning: Failed to convert frames list to owned slice, attempting recovery...\n", .{});

        // First try to salvage any frames we collected
        const collected_frames = frames_list.items;

        // Always clean up the ArrayList to prevent memory leaks
        defer frames_list.deinit();

        if (collected_frames.len > 0) {
            // Try to allocate new memory and copy the frames
            if (allocator.alloc(SentryFrame, collected_frames.len)) |salvaged| {
                // Deep-copy strings inside frames that we allocated earlier
                // so that deinit on the new frames slice is safe
                var i: usize = 0;
                while (i < collected_frames.len) : (i += 1) {
                    const src = collected_frames[i];
                    var dst = SentryFrame{};
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
                // Now free previously allocated strings in the original frames
                // and then the backing arraylist memory
                i = 0;
                while (i < collected_frames.len) : (i += 1) {
                    const f = collected_frames[i];
                    if (f.filename) |p| allocator.free(p);
                    if (f.abs_path) |p| allocator.free(p);
                    if (f.function) |p| allocator.free(p);
                    if (f.instruction_addr) |p| allocator.free(p);
                }
                std.debug.print("Successfully salvaged {d} frames after allocation failure\n", .{collected_frames.len});
                return createEventWithFrames(msg, salvaged);
            } else |_| {
                std.debug.print("Failed to salvage {d} frames due to memory constraints\n", .{collected_frames.len});
            }
        }

        // Fallback: create an empty but valid slice that can be safely freed
        const empty_frames = allocator.alloc(SentryFrame, 0) catch {
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
fn createEventWithFrames(msg: []const u8, frames: []SentryFrame) SentryEvent {
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
    return SentryEvent{
        .event_id = Event.EventId.new(),
        .timestamp = @as(f64, @floatFromInt(std.time.timestamp())),
        .platform = "native",
        .level = Level.@"error",
        .exception = exception,
        .logger = allocator.dupe(u8, "panic_handler") catch "panic_handler",
    };
}

/// Create a minimal Sentry event without stacktrace (for critical memory situations)
fn createMinimalEvent(msg: []const u8) SentryEvent {
    // Create exception without stacktrace
    const exception = SentryException{
        .type = "panic", // Use string literal to avoid allocation
        .value = msg, // Use original message to avoid allocation
        .module = null,
        .thread_id = null,
        .stacktrace = null, // No stacktrace due to memory constraints
        .mechanism = null,
    };

    // Create minimal event
    return SentryEvent{
        .event_id = Event.EventId.new(),
        .timestamp = @as(f64, @floatFromInt(std.time.timestamp())),
        .platform = "native",
        .level = Level.@"error",
        .exception = exception,
        .logger = "panic_handler", // Use string literal to avoid allocation
    };
}

// Best-effort local symbol parsing as a non-fatal enhancement. If it fails,
// addresses still provide server-side symbolication.
fn extractSymbolInfoSentry(debug_info: *std.debug.SelfInfo, addr: usize, frame: *SentryFrame) void {
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

fn parseSymbolLineSentry(line: []const u8, frame: *SentryFrame) void {
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
