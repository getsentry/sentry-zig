const std = @import("std");
const Allocator = std.mem.Allocator;

const SentryOptions = @import("types").SentryOptions;
const SentryEnvelope = @import("types").SentryEnvelope;
const SentryEnvelopeHeader = @import("types").SentryEnvelopeHeader;
const SentryEnvelopeItem = @import("types").SentryEnvelopeItem;
const EventId = @import("types").EventId;
const Dsn = @import("types").Dsn;

pub fn main() !void {
    _ = @import("scope.zig");

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const HttpTransport = @import("transport.zig").HttpTransport;

    const cstr: [*:0]const u8 = "24f9202c3c9f44deabef9ed3132b41e4";
    var event_id: [32]u8 = undefined;
    @memcpy(event_id[0..32], cstr[0..32]);

    var transport = HttpTransport.init(arena, SentryOptions{
        .dsn = try Dsn.parse(
            arena,
            "https://7c8df91eb303287546fa8eb371154766@o447951.ingest.us.sentry.io/4509869908951040",
        ),
    });
    const status_code = try transport.send(SentryEnvelope{
        .header = SentryEnvelopeHeader{
            .event_id = EventId{
                .value = event_id,
            },
        },
        .items = &[_]SentryEnvelopeItem{},
    });
    std.log.debug("{}", .{status_code});
}
