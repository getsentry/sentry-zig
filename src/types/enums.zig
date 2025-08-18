/// Sentry breadcrumb types
pub const BreadcrumbType = enum {
    default,
    debug,
    @"error",
    info,
    navigation,
    http,
    query,
    ui,
    user,

    pub fn toString(self: BreadcrumbType) []const u8 {
        return @tagName(self);
    }
};

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
