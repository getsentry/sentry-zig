const std = @import("std");
const Allocator = std.mem.Allocator;

const SentryOptions = @import("types").SentryOptions;
const SentryEnvelope = @import("types").SentryEnvelope;
const TransportResult = @import("types").TransportResult;
const SentryEnvelopeItem = @import("types").SentryEnvelopeItem;
const SentryEnvelopeHeader = @import("types").SentryEnvelopeHeader;
const SentryEnvelopeItemHeader = @import("types").SentryEnvelopeItemHeader;
const EventId = @import("types").EventId;

pub const HttpTransport = struct {
    client: std.http.Client,
    options: SentryOptions,
    allocator: Allocator,

    pub fn init(allocator: Allocator, options: SentryOptions) HttpTransport {
        const transport = HttpTransport{
            .client = std.http.Client{ .allocator = allocator },
            .options = options,
            .allocator = allocator,
        };

        return transport;
    }

    pub fn send(self: *HttpTransport, envelope: SentryEnvelope) TransportResult {
        const payload = try self.envelopeToPayload(envelope);
        defer self.allocator.free(payload);

        // Check if DSN is configured
        const dsn = self.options.dsn orelse return TransportResult{ .response_code = 0 };

        // Construct the Sentry envelope endpoint URL
        const netloc = dsn.getNetloc(self.allocator) catch return TransportResult{ .response_code = 0 };
        defer self.allocator.free(netloc);

        const endpoint_url = std.fmt.allocPrint(self.allocator, "{s}://{s}/api/{s}/envelope/", .{
            dsn.scheme,
            netloc,
            dsn.project_id,
        }) catch return TransportResult{ .response_code = 0 };
        defer self.allocator.free(endpoint_url);

        // Parse the URL and make the HTTP request
        const uri = std.Uri.parse(endpoint_url) catch return TransportResult{ .response_code = 0 };

        var request = self.client.open(.POST, uri, .{
            .server_header_buffer = &[_]u8{0} ** 1024,
        }) catch return TransportResult{ .response_code = 0 };
        defer request.deinit();

        request.transfer_encoding = .{ .content_length = payload.len };
        request.send() catch return TransportResult{ .response_code = 0 };
        request.writeAll(payload) catch return TransportResult{ .response_code = 0 };
        request.finish() catch return TransportResult{ .response_code = 0 };
        request.wait() catch return TransportResult{ .response_code = 0 };

        return TransportResult{ .response_code = @intCast(@intFromEnum(request.response.status)) };
    }

    pub fn envelopeToPayload(envelope: SentryEnvelope) ![]u8 {
        var buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);

        var bufferedWriter = std.io.bufferedWriter(fbs.writer());

        try std.json.stringify(envelope.header, std.json.StringifyOptions{}, bufferedWriter.writer());
        _ = try bufferedWriter.write("\n");

        for (envelope.items) |item| {
            try std.json.stringify(item.header, std.json.StringifyOptions{}, bufferedWriter.writer());
            _ = try bufferedWriter.write("\n");
        }

        try bufferedWriter.flush();
        return fbs.getWritten();
    }
};

test "Envelope - Serialize empty envelope" {
    const cstr: [*:0]const u8 = "24f9202c3c9f44deabef9ed3132b41e4";
    var event_id: [32]u8 = undefined;
    @memcpy(event_id[0..32], cstr[0..32]);

    const payload = try HttpTransport.envelopeToPayload(SentryEnvelope{
        .header = SentryEnvelopeHeader{
            .event_id = EventId{
                .value = event_id,
            },
        },
        .items = &[_]SentryEnvelopeItem{},
    });
    try std.testing.expectEqualStrings("{\"event_id\":{\"value\":\"24f9202c3c9f44deabef9ed3132b41e4\"}}\n", payload);
}

test "Envelope - Serialize event-id header" {
    const cstr: [*:0]const u8 = "24f9202c3c9f44deabef9ed3132b41e4";
    var event_id: [32]u8 = undefined;
    @memcpy(event_id[0..32], cstr[0..32]);

    const payload = try HttpTransport.envelopeToPayload(SentryEnvelope{
        .header = SentryEnvelopeHeader{
            .event_id = EventId{
                .value = event_id,
            },
        },
        .items = &[_]SentryEnvelopeItem{},
    });
    try std.testing.expectEqualStrings("{\"event_id\":{\"value\":\"24f9202c3c9f44deabef9ed3132b41e4\"}}\n", payload);
}

test "Envelope - Serialize envelope with empty event" {
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

    const payload = try HttpTransport.envelopeToPayload(SentryEnvelope{
        .header = SentryEnvelopeHeader{
            .event_id = EventId{
                .value = event_id,
            },
        },
        .items = item_buf[0..],
    });
    try std.testing.expectEqualStrings("{\"event_id\":{\"value\":\"24f9202c3c9f44deabef9ed3132b41e4\"}}\n{\"type\":\"event\",\"length\":0,\"content_type\":null,\"file_name\":null,\"attachment_type\":null,\"platform\":null,\"item_count\":null}\n", payload);
}
