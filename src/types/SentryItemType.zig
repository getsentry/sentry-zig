pub const SentryItemType = enum {
    session,
    event,
    user_report,
    attachment,
    transaction,
    profile,
    profile_chunk,
    client_report,
    replay_recording,
    replay_video,
    check_in,
    feedback,
    log,
    __unknown__,

    pub fn toString(self: SentryItemType) []const u8 {
        return @tagName(self);
    }
};
