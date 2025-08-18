pub const DiscardReason = enum {
    queue_overflow,
    cache_overflow,
    ratelimit_backoff,
    network_error,
    sample_rate,
    before_send,
    event_processor,
    backpressure,

    pub fn toString(self: DiscardReason) []const u8 {
        return @tagName(self);
    }
};
