// Re-export all types from the types module
pub const BreadcrumbType = @import("types/BreadcrumbType.zig").BreadcrumbType;
pub const Level = @import("types/Level.zig").Level;
pub const User = @import("types/User.zig").User;
pub const Breadcrumb = @import("types/Breadcrumb.zig").Breadcrumb;
pub const Dsn = @import("types/Dsn.zig").Dsn;
pub const TransportResult = @import("types/TransportResult.zig").TransportResult;
pub const SentryOptions = @import("types/SentryOptions.zig").SentryOptions;
pub const SamplingContext = @import("types/SentryOptions.zig").SamplingContext;
pub const SentryEnvelope = @import("types/SentryEnvelope.zig").SentryEnvelope;
pub const SentryEnvelopeItem = @import("types/SentryEnvelopeItem.zig").SentryEnvelopeItem;
pub const SentryEnvelopeHeader = @import("types/SentryEnvelopeHeader.zig").SentryEnvelopeHeader;
pub const SentryEnvelopeItemHeader = @import("types/SentryEnvelopeItemHeader.zig").SentryEnvelopeItemHeader;
pub const SentryItemType = @import("types/SentryItemType.zig").SentryItemType;
pub const Event = @import("types/Event.zig").Event;
pub const EventId = @import("types/Event.zig").EventId;
pub const StackTrace = @import("types/Event.zig").StackTrace;
pub const Exception = @import("types/Event.zig").Exception;
pub const Frame = @import("types/Event.zig").Frame;
pub const Breadcrumbs = @import("types/Event.zig").Breadcrumbs;
pub const Message = @import("types/Event.zig").Message;
pub const SDK = @import("types/Event.zig").SDK;
pub const SDKPackage = @import("types/Event.zig").SDKPackage;
pub const Contexts = @import("types/Contexts.zig").Contexts;

// Tracing types
pub const TraceId = @import("types/TraceId.zig").TraceId;
pub const SpanId = @import("types/SpanId.zig").SpanId;
pub const PropagationContext = @import("types/PropagationContext.zig").PropagationContext;

// Unified span types
pub const Span = @import("types/Span.zig").Span;
pub const Sampled = @import("types/Span.zig").Sampled;
pub const SpanStatus = @import("types/Span.zig").SpanStatus;
pub const SpanOrigin = @import("types/Span.zig").SpanOrigin;
pub const TransactionSource = @import("types/Span.zig").TransactionSource;

// Trace context for header parsing utility
pub const TraceContext = @import("types/TraceContext.zig").TraceContext;
