const std = @import("std");

/// Contexts interface
pub const Contexts = std.StringHashMap(std.StringHashMap([]const u8));
