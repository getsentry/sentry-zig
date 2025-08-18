const std = @import("std");
const Random = std.Random;
const Allocator = std.mem.Allocator;
const rand = std.crypto.random;

pub const UUID = struct {
    value: u128,

    const S = @This();
    pub fn new() S {
        return S{
            .value = rand.int(u128),
        };
    }
};
