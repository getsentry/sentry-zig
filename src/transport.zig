const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const SentryOptions = @import("types").SentryOptions;
const SentryEnvelope = @import("types").SentryEnvelope;
const TransportResult = @import("types").TransportResult;
const SentryEnvelopeItem = @import("types").SentryEnvelopeItem;
const SentryEnvelopeHeader = @import("types").SentryEnvelopeHeader;
const SentryEnvelopeItemHeader = @import("types").SentryEnvelopeItemHeader;
const EventId = @import("types").EventId;
const Event = @import("types").Event;
const User = @import("types").User;
const Breadcrumb = @import("types").Breadcrumb;
const Breadcrumbs = @import("types").Breadcrumbs;
const BreadcrumbType = @import("types").BreadcrumbType;
const Level = @import("types").Level;
const Message = @import("types").Message;
const test_utils = @import("utils/test_utils.zig");

pub const HttpTransport = struct {
    client: std.http.Client,
    options: SentryOptions,
    allocator: Allocator,

    pub fn init(allocator: Allocator, options: SentryOptions) HttpTransport {
        const transport = HttpTransport{
            .client = std.http.Client{
                .allocator = allocator,
            },
            .options = options,
            .allocator = allocator,
        };

        return transport;
    }

    pub fn send(self: *HttpTransport, envelope: SentryEnvelope) !TransportResult {
        const payload = try self.envelopeToPayload(envelope);
        defer self.allocator.free(payload);

        // Check if DSN is configured
        const dsn = self.options.dsn orelse {
            return TransportResult{ .response_code = 0 };
        };

        // Construct the Sentry envelope endpoint URL
        const netloc = dsn.getNetloc(self.allocator) catch {
            return TransportResult{ .response_code = 0 };
        };
        defer self.allocator.free(netloc);

        const endpoint_url = std.fmt.allocPrint(self.allocator, "{s}://{s}/api/{s}/envelope/", .{
            dsn.scheme,
            netloc,
            dsn.project_id,
        }) catch {
            return TransportResult{ .response_code = 0 };
        };
        defer self.allocator.free(endpoint_url);

        // Parse the URL and make the HTTP request
        const uri = std.Uri.parse(endpoint_url) catch {
            return TransportResult{ .response_code = 0 };
        };

        // Construct the auth header
        const auth_header = std.fmt.allocPrint(self.allocator, "Sentry sentry_version=7,sentry_key={s},sentry_client=sentry-zig/0.1.0", .{
            dsn.public_key,
        }) catch {
            return TransportResult{ .response_code = 0 };
        };
        defer self.allocator.free(auth_header);

        // Create Content-Length header value
        const content_length = std.fmt.allocPrint(self.allocator, "{d}", .{payload.len}) catch {
            return TransportResult{ .response_code = 0 };
        };
        defer self.allocator.free(content_length);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/x-sentry-envelope" },
            .{ .name = "Content-Length", .value = content_length },
            .{ .name = "X-Sentry-Auth", .value = auth_header },
        };

        var response_body = std.ArrayList(u8).init(self.allocator);
        defer response_body.deinit();

        const result = self.client.fetch(std.http.Client.FetchOptions{
            .location = std.http.Client.FetchOptions.Location{
                .uri = uri,
            },
            .method = .POST,
            .extra_headers = &headers,
            .payload = payload,
            .response_storage = .{ .dynamic = &response_body },
        }) catch {
            return TransportResult{ .response_code = 0 };
        };
        std.log.debug("sending payload {s}", .{payload});

        return TransportResult{ .response_code = @intCast(@intFromEnum(result.status)) };
    }

    pub fn envelopeToPayload(self: *HttpTransport, envelope: SentryEnvelope) ![]u8 {
        var list = std.ArrayList(u8).init(self.allocator);
        errdefer list.deinit();

        try std.json.stringify(envelope.header, std.json.StringifyOptions{}, list.writer());
        try list.append('\n');

        for (envelope.items, 0..) |item, i| {
            try std.json.stringify(item.header, std.json.StringifyOptions{}, list.writer());
            try list.append('\n');
            // Add the actual item data
            try list.appendSlice(item.data);
            // Only add newline if not the last item
            if (i < envelope.items.len - 1) {
                try list.append('\n');
            }
        }

        const result = try list.toOwnedSlice();
        return result;
    }

    pub fn envelopeFromEvent(self: *HttpTransport, event: Event) !SentryEnvelopeItem {
        var list = std.ArrayList(u8).init(self.allocator);
        errdefer list.deinit();

        try std.json.stringify(event, .{}, list.writer());

        const data = try list.toOwnedSlice();
        return SentryEnvelopeItem{
            .header = .{
                .type = .event,
                .length = @intCast(data.len), // Use actual data length, not buffer length
            },
            .data = data,
        };
    }
};

test "Envelope - Serialize empty envelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var transport = HttpTransport.init(allocator, SentryOptions{});

    const cstr: [*:0]const u8 = "24f9202c3c9f44deabef9ed3132b41e4";
    var event_id: [32]u8 = undefined;
    @memcpy(event_id[0..32], cstr[0..32]);

    const payload = try transport.envelopeToPayload(SentryEnvelope{
        .header = SentryEnvelopeHeader{
            .event_id = EventId{
                .value = event_id,
            },
        },
        .items = &[_]SentryEnvelopeItem{},
    });
    defer allocator.free(payload);
    try std.testing.expectEqualStrings("{\"event_id\":\"24f9202c3c9f44deabef9ed3132b41e4\"}\n", payload);
}

test "Envelope - Serialize event-id header" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var transport = HttpTransport.init(allocator, SentryOptions{});

    const cstr: [*:0]const u8 = "24f9202c3c9f44deabef9ed3132b41e4";
    var event_id: [32]u8 = undefined;
    @memcpy(event_id[0..32], cstr[0..32]);

    const payload = try transport.envelopeToPayload(SentryEnvelope{
        .header = SentryEnvelopeHeader{
            .event_id = EventId{
                .value = event_id,
            },
        },
        .items = &[_]SentryEnvelopeItem{},
    });
    defer allocator.free(payload);
    try std.testing.expectEqualStrings("{\"event_id\":\"24f9202c3c9f44deabef9ed3132b41e4\"}\n", payload);
}

test "Envelope - Serialize envelope with empty event" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cstr: [*:0]const u8 = "24f9202c3c9f44deabef9ed3132b41e4";
    var event_id: [32]u8 = undefined;
    @memcpy(event_id[0..32], cstr[0..32]);

    var item_buf = [_]SentryEnvelopeItem{
        .{
            .header = .{
                .type = .event,
                .length = 0,
            },
            .data = "",
        },
    };

    var transport = HttpTransport.init(allocator, SentryOptions{});

    const payload = try transport.envelopeToPayload(SentryEnvelope{
        .header = SentryEnvelopeHeader{
            .event_id = EventId{
                .value = event_id,
            },
        },
        .items = item_buf[0..],
    });
    defer allocator.free(payload);
    try std.testing.expectEqualStrings("{\"event_id\":\"24f9202c3c9f44deabef9ed3132b41e4\"}\n{\"type\":\"event\",\"length\":0}\n", payload);
}

test "Envelope - Serialize full envelope item from event" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var event = try test_utils.createFullTestEvent(allocator);
    defer event.deinit(allocator);

    // Override dynamic fields with fixed values for predictable testing
    event.event_id = EventId{ .value = "24f9202c3c9f44deabef9ed3132b41e4".* };
    event.timestamp = 1640995200.0; // Fixed timestamp: Jan 1, 2022

    // Also fix breadcrumb timestamp for predictable testing
    if (event.breadcrumbs) |*breadcrumbs| {
        for (breadcrumbs.values) |*breadcrumb| {
            breadcrumb.timestamp = 1640995200; // Fixed timestamp: Jan 1, 2022
        }
    }

    var transport = HttpTransport.init(allocator, SentryOptions{});
    const json_result = try transport.envelopeFromEvent(event);
    defer allocator.free(json_result.data);
    const json_string = json_result.data;

    // Construct expected JSON string - based on actual output, null fields are omitted
    const expected_json =
        \\{"event_id":"24f9202c3c9f44deabef9ed3132b41e4","timestamp":1.6409952e9,"platform":"native","level":"error","logger":"test-logger","transaction":"test-transaction","server_name":"test-server","release":"1.0.0","dist":"1","environment":"test","fingerprint":["custom","fingerprint"],"tags":{"environment":"test","version":"1.0.0"},"modules":{"mymodule":"1.0.0"},"message":{"message":"Test error message","formatted":"Test error message"},"breadcrumbs":{"values":[{"message":"HTTP Request","type":"http","level":"info","timestamp":1640995200,"category":"http","data":{"url":"/api/test","method":"GET"}}]},"user":{"id":"123","username":"testuser","email":"test@example.com","name":"Test User","ip_address":"192.168.1.1"}}
    ;

    try testing.expectEqualStrings(expected_json, json_string);
}
