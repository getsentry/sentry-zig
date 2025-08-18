const std = @import("std");

const StackFrame = struct {
    addr: usize,
    function_name: ?[]const u8 = null,
    file_name: ?[]const u8 = null,
    line: ?u32 = null,
    column: ?u32 = null,
};

const CapturedStackTrace = struct {
    message: []const u8,
    frames: []StackFrame, // Dynamic slice
    debug_info_available: bool,
    allocator: std.mem.Allocator,
    
    // Method to create a built-in StackTrace for use with Zig's formatters
    pub fn toBuiltinStackTrace(self: CapturedStackTrace) std.builtin.StackTrace {
        // Dynamically allocate buffer for addresses based on actual frame count
        const addresses = self.allocator.alloc(usize, self.frames.len) catch {
            // Fallback to empty trace if allocation fails
            return std.builtin.StackTrace{
                .instruction_addresses = &[_]usize{},
                .index = 0,
            };
        };
        
        for (self.frames, 0..) |frame, i| {
            addresses[i] = frame.addr;
        }
        
        return std.builtin.StackTrace{
            .instruction_addresses = addresses,
            .index = self.frames.len,
        };
    }
    
    // Cleanup method
    pub fn deinit(self: *CapturedStackTrace) void {
        // Free the frames
        self.allocator.free(self.frames);
        
        // Free any dynamically allocated symbol strings
        for (self.frames) |frame| {
            if (frame.function_name) |func| {
                self.allocator.free(func);
            }
            if (frame.file_name) |file| {
                self.allocator.free(file);
            }
        }
        
        // Free the message if it was duplicated
        if (self.message.ptr != @as([*]const u8, @ptrCast(&self.message[0]))) {
            self.allocator.free(self.message);
        }
    }
};

pub fn panic_handler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    const captured_trace = captureStackTrace(msg, first_trace_addr);
    
    sendToSentry(captured_trace, first_trace_addr);
    
    std.process.exit(1);
}

fn captureStackTrace(msg: []const u8, first_trace_addr: ?usize) CapturedStackTrace {
    // Use GeneralPurposeAllocator for unlimited frame collection
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    // Check if debug info is available by trying to get it
    const debug_info = std.debug.getSelfDebugInfo() catch null;
    
    // Create ArrayList to dynamically grow frames - no size limit!
    var frames_list = std.ArrayList(StackFrame).init(allocator);
    
    var trace = CapturedStackTrace{
        .message = allocator.dupe(u8, msg) catch msg, // Store message copy
        .frames = undefined, // Will be set after collecting frames
        .debug_info_available = debug_info != null,
        .allocator = allocator,
    };
    
    var stack_iterator = std.debug.StackIterator.init(first_trace_addr, null);
    
    // Collect all frames dynamically - never fail due to buffer size!
    while (stack_iterator.next()) |return_address| {
        var frame = StackFrame{
            .addr = return_address,
        };
        
        // Try to extract symbol information if debug info is available
        if (debug_info) |di| {
            extractSymbolInfoDynamic(allocator, di, return_address, &frame);
        }
        
        // Add frame to dynamic list - this should never fail unless out of memory
        frames_list.append(frame) catch |err| {
            // If we truly run out of memory, at least we have what we collected so far
            std.debug.print("Warning: Failed to add frame due to memory: {}\n", .{err});
            break;
        };
    }
    
    // Convert to owned slice
    trace.frames = frames_list.toOwnedSlice() catch &[_]StackFrame{};
    
    return trace;
}

fn extractSymbolInfoDynamic(allocator: std.mem.Allocator, debug_info: *std.debug.SelfInfo, addr: usize, frame: *StackFrame) void {
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
        parseSymbolLineDynamic(allocator, first_line, frame);
    }
}

fn parseSymbolLineDynamic(allocator: std.mem.Allocator, line: []const u8, frame: *StackFrame) void {
    // Parse a line like: "/path/to/file.zig:13:5: 0x123456 in function_name (binary)"
    
    // Find the first colon to separate file from line number
    if (std.mem.indexOf(u8, line, ":")) |first_colon| {
        // Extract file name and store it dynamically
        const file_part = line[0..first_colon];
        frame.file_name = allocator.dupe(u8, file_part) catch null;
        
        // Parse the rest: "line:column: addr in function (binary)"
        const rest = line[first_colon + 1..];
        
        // Find the next colon for line number
        if (std.mem.indexOf(u8, rest, ":")) |second_colon| {
            const line_str = rest[0..second_colon];
            frame.line = std.fmt.parseInt(u32, line_str, 10) catch null;
            
            // Parse column if present
            const after_line = rest[second_colon + 1..];
            if (std.mem.indexOf(u8, after_line, ":")) |third_colon| {
                const col_str = after_line[0..third_colon];
                frame.column = std.fmt.parseInt(u32, col_str, 10) catch null;
                
                // Look for function name after " in "
                const after_col = after_line[third_colon + 1..];
                if (std.mem.indexOf(u8, after_col, " in ")) |in_pos| {
                    const after_in = after_col[in_pos + 4..];
                    if (std.mem.indexOf(u8, after_in, " ")) |space_pos| {
                        const func_name = after_in[0..space_pos];
                        frame.function_name = allocator.dupe(u8, func_name) catch null;
                    }
                }
            }
        }
    }
}

fn sendToSentry(trace: CapturedStackTrace, first_trace_addr: ?usize) void {
    _ = first_trace_addr; // Suppress unused parameter warning
    _ = trace; // Suppress unused parameter warning until implemented
}