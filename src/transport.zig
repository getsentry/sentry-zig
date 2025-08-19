const std = @import("std");
const Allocator = std.mem.Allocator;

const SentryOptions = @import("types").SentryOptions;
const SentryEnvelope = @import("types").SentryEnvelope;
const TransportResult = @import("types").TransportResult;
const SentryEnvelopeItem = @import("types").SentryEnvelopeItem;
const SentryEnvelopeHeader = @import("types").SentryEnvelopeHeader;
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

    pub fn envelopeToPayload(envelope: SentryEnvelope) []u8 {
        var buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);

        var bufferedWriter = std.io.bufferedWriter(fbs.writer());

        std.json.stringify(envelope.header, std.json.StringifyOptions{}, bufferedWriter);
        bufferedWriter.write("\n");

        for (envelope.items) |item| {
            std.json.stringify(item.header, std.json.StringifyOptions{}, bufferedWriter);
            bufferedWriter.write("\n");
        }

        return bufferedWriter.flush();
    }
};

test "Envelope - Serialize empty envelope" {
    const payload = HttpTransport.envelopeToPayload(SentryEnvelope{
        .header = SentryEnvelopeHeader{ .event_id = EventId.new() },
        .items = &[_]SentryEnvelopeItem{},
    });
    try std.testing.expectEqualStrings(payload, "");
}

// test "Envelope - Serialize event-id header" {
//     const payload = HttpTransport.envelopeToPayload(SentryEnvelope{});
//     try std.testing.expectEqualStrings(payload, "");
// }
