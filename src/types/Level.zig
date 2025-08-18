/// Sentry breadcrumb types
/// Sentry severity levels
pub const Level = enum {
    debug,
    info,
    warning,
    @"error",
    fatal,

    pub fn toString(self: Level) []const u8 {
        return @tagName(self);
    }
};
