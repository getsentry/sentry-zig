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

    pub fn send(self: *HttpTransport) TransportResult {
        self.client.connect();
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
        .items = &[_]SentryEnvelopeItem{
            SentryEnvelopeItem{
                .header = SentryEnvelopeItemHeader{},
            },
        },
    });
    try std.testing.expectEqualStrings("{\"event_id\":{\"value\":\"24f9202c3c9f44deabef9ed3132b41e4\"}}\n", payload);
}
