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
