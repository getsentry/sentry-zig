const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Dsn = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    public_key: []const u8,
    secret_key: ?[]const u8,
    project_id: []const u8,
    path: []const u8,

    /// Parse a DSN string into its components
    pub fn parse(allocator: Allocator, dsn_string: []const u8) !Dsn {
        var dsn = dsn_string;

        const scheme_end = std.mem.indexOf(u8, dsn, "://") orelse return error.BadDsn;
        const scheme = dsn[0..scheme_end];
        if (!std.mem.eql(u8, scheme, "http") and !std.mem.eql(u8, scheme, "https")) {
            return error.BadDsn;
        }
        dsn = dsn[scheme_end + 3 ..];

        // Parse credentials (public_key:secret_key@)
        const at_pos = std.mem.indexOf(u8, dsn, "@") orelse return error.BadDsn;
        const auth_part = dsn[0..at_pos];

        var public_key: []const u8 = undefined;
        // backwards compatibility with old DSNs
        var secret_key: ?[]const u8 = null;

        if (std.mem.indexOf(u8, auth_part, ":")) |colon_pos| {
            public_key = auth_part[0..colon_pos];
            const secret = auth_part[colon_pos + 1 ..];
            if (secret.len > 0) {
                secret_key = secret;
            }
        } else {
            public_key = auth_part;
        }

        if (public_key.len == 0) {
            return error.BadDsn;
        }

        dsn = dsn[at_pos + 1 ..];

        // Parse host, port, path, and project_id
        // Not entirely sure about the path parsing
        const path_start = std.mem.indexOf(u8, dsn, "/") orelse return error.BadDsn;
        const host_port = dsn[0..path_start];

        var host: []const u8 = undefined;
        var port: u16 = undefined;

        if (std.mem.indexOf(u8, host_port, ":")) |colon_pos| {
            host = host_port[0..colon_pos];
            const port_str = host_port[colon_pos + 1 ..];
            port = std.fmt.parseInt(u16, port_str, 10) catch return error.BadDsn;
        } else {
            host = host_port;
            // Default ports
            port = if (std.mem.eql(u8, scheme, "https")) 443 else 80;
        }

        if (host.len == 0) {
            return error.BadDsn;
        }

        // Extract path and project_id
        const remaining = dsn[path_start..];
        const last_slash = std.mem.lastIndexOf(u8, remaining, "/") orelse return error.BadDsn;

        const path = remaining[0 .. last_slash + 1]; // Include trailing slash
        const project_id_str = remaining[last_slash + 1 ..];

        // Validate project_id is numeric
        _ = std.fmt.parseInt(u32, project_id_str, 10) catch return error.BadDsn;

        return Dsn{
            .scheme = try allocator.dupe(u8, scheme),
            .host = try allocator.dupe(u8, host),
            .port = port,
            .public_key = try allocator.dupe(u8, public_key),
            .secret_key = if (secret_key) |sk| try allocator.dupe(u8, sk) else null,
            .project_id = try allocator.dupe(u8, project_id_str),
            .path = try allocator.dupe(u8, path),
        };
    }

    pub fn getNetloc(self: *const Dsn, allocator: Allocator) ![]u8 {
        // Only include port if non-standard
        if ((std.mem.eql(u8, self.scheme, "http") and self.port == 80) or
            (std.mem.eql(u8, self.scheme, "https") and self.port == 443))
        {
            return allocator.dupe(u8, self.host);
        }
        return std.fmt.allocPrint(allocator, "{s}:{d}", .{ self.host, self.port });
    }

    pub fn toString(self: *const Dsn, allocator: Allocator) ![]u8 {
        const netloc = try self.getNetloc(allocator);
        defer allocator.free(netloc);

        if (self.secret_key) |sk| {
            return std.fmt.allocPrint(allocator, "{s}://{s}:{s}@{s}{s}{s}", .{
                self.scheme,
                self.public_key,
                sk,
                netloc,
                self.path,
                self.project_id,
            });
        } else {
            return std.fmt.allocPrint(allocator, "{s}://{s}@{s}{s}{s}", .{
                self.scheme,
                self.public_key,
                netloc,
                self.path,
                self.project_id,
            });
        }
    }

    /// Free all allocated memory
    pub fn deinit(self: *const Dsn, allocator: Allocator) void {
        allocator.free(self.scheme);
        allocator.free(self.host);
        allocator.free(self.public_key);
        if (self.secret_key) |sk| {
            allocator.free(sk);
        }
        allocator.free(self.project_id);
        allocator.free(self.path);
    }
};

test "DSN parsing - successful cases" {
    const allocator = std.testing.allocator;

    // Test basic DSN (most common format)
    {
        const dsn = try Dsn.parse(allocator, "https://public@sentry.example.com/1");
        defer dsn.deinit(allocator);

        try std.testing.expectEqualStrings("https", dsn.scheme);
        try std.testing.expectEqualStrings("sentry.example.com", dsn.host);
        try std.testing.expectEqual(@as(u16, 443), dsn.port);
        try std.testing.expectEqualStrings("public", dsn.public_key);
        try std.testing.expect(dsn.secret_key == null);
        try std.testing.expectEqualStrings("1", dsn.project_id);
        try std.testing.expectEqualStrings("/", dsn.path);

        // Test reconstructing the DSN
        const dsn_str = try dsn.toString(allocator);
        defer allocator.free(dsn_str);
        try std.testing.expectEqualStrings("https://public@sentry.example.com/1", dsn_str);
    }

    // Test DSN with secret key (backwards compatibility)
    {
        const dsn = try Dsn.parse(allocator, "http://public:secret@example.com:8080/path/42");
        defer dsn.deinit(allocator);

        try std.testing.expectEqualStrings("http", dsn.scheme);
        try std.testing.expectEqualStrings("example.com", dsn.host);
        try std.testing.expectEqual(@as(u16, 8080), dsn.port);
        try std.testing.expectEqualStrings("public", dsn.public_key);
        try std.testing.expectEqualStrings("secret", dsn.secret_key.?);
        try std.testing.expectEqualStrings("42", dsn.project_id);
        try std.testing.expectEqualStrings("/path/", dsn.path);

        const dsn_str = try dsn.toString(allocator);
        defer allocator.free(dsn_str);
        try std.testing.expectEqualStrings("http://public:secret@example.com:8080/path/42", dsn_str);
    }

    // Test real Sentry.io format
    {
        const dsn = try Dsn.parse(allocator, "https://abc123def456@o12345.ingest.sentry.io/6789");
        defer dsn.deinit(allocator);

        try std.testing.expectEqualStrings("https", dsn.scheme);
        try std.testing.expectEqualStrings("o12345.ingest.sentry.io", dsn.host);
        try std.testing.expectEqual(@as(u16, 443), dsn.port);
        try std.testing.expectEqualStrings("abc123def456", dsn.public_key);
        try std.testing.expect(dsn.secret_key == null);
        try std.testing.expectEqualStrings("6789", dsn.project_id);
        try std.testing.expectEqualStrings("/", dsn.path);
    }

    // Test getNetloc with default ports
    {
        const dsn_https = try Dsn.parse(allocator, "https://key@example.com/1");
        defer dsn_https.deinit(allocator);

        const netloc_https = try dsn_https.getNetloc(allocator);
        defer allocator.free(netloc_https);
        try std.testing.expectEqualStrings("example.com", netloc_https);

        const dsn_http = try Dsn.parse(allocator, "http://key@example.com/1");
        defer dsn_http.deinit(allocator);

        const netloc_http = try dsn_http.getNetloc(allocator);
        defer allocator.free(netloc_http);
        try std.testing.expectEqualStrings("example.com", netloc_http);
    }

    // Test getNetloc with custom port
    {
        const dsn = try Dsn.parse(allocator, "https://key@example.com:9000/1");
        defer dsn.deinit(allocator);

        const netloc = try dsn.getNetloc(allocator);
        defer allocator.free(netloc);
        try std.testing.expectEqualStrings("example.com:9000", netloc);
    }
}

test "DSN parsing - error cases" {
    const allocator = std.testing.allocator;

    // Wrong protocol
    try std.testing.expectError(error.BadDsn, Dsn.parse(allocator, "ftp://key@host/1"));

    // Missing public key
    try std.testing.expectError(error.BadDsn, Dsn.parse(allocator, "https://@host/1"));
    try std.testing.expectError(error.BadDsn, Dsn.parse(allocator, "https://:secret@host/1"));

    // Invalid project ID (non-numeric)
    try std.testing.expectError(error.BadDsn, Dsn.parse(allocator, "https://key@host/abc"));

    // Malformed DSNs
    try std.testing.expectError(error.BadDsn, Dsn.parse(allocator, "not a dsn"));
    try std.testing.expectError(error.BadDsn, Dsn.parse(allocator, "https://key@host")); // missing project
    try std.testing.expectError(error.BadDsn, Dsn.parse(allocator, "https://keyhost/1")); // missing @
}
