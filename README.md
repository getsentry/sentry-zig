# 🚀 Sentry for Zig

_Bad software is everywhere, and we're tired of it. Sentry is on a mission to help developers write better software faster, so we can get back to enjoying technology. If you want to join us **[Check out our open positions](https://sentry.io/careers/)**._

[![Build Status](https://img.shields.io/badge/build-passing-green)](https://github.com/getsentry/sentry-zig)
[![Zig Version](https://img.shields.io/badge/zig-0.14.1+-blue)](https://ziglang.org)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Welcome to the official **Zig SDK** for [**Sentry**](https://sentry.io).

> **⚠️ Experimental SDK**: This SDK is currently experimental and not production-ready. It was developed during a Hackweek project and is intended for testing and feedback purposes.

## 📦 Getting Started

### Prerequisites

You need:
- A [Sentry account and project](https://sentry.io/signup/)
- Zig 0.14.1 or later

### Installation

Ensure your project has a `build.zig.zon` file, then:

```bash
# Add the dependency 
zig fetch --save https://github.com/getsentry/sentry-zig/archive/refs/heads/main.tar.gz
```

Then update your `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get the sentry-zig dependency
    const sentry_zig = b.dependency("sentry_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the sentry-zig module
    exe.root_module.addImport("sentry_zig", sentry_zig.module("sentry_zig"));
    
    b.installArtifact(exe);
}
```

### Basic Configuration

Here's a quick configuration example to get Sentry up and running:

```zig
const std = @import("std");
const sentry = @import("sentry_zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize Sentry - replace with your actual DSN
    const dsn = "https://your-dsn@o0.ingest.sentry.io/0000000000000000";
    
    const options = sentry.SentryOptions{
        .environment = "production",
        .release = "1.0.0",
        .debug = false,
        .sample_rate = 1.0,
        .send_default_pii = false,
    };

    var client = sentry.init(allocator, dsn, options) catch |err| {
        std.log.err("Failed to initialize Sentry: {}", .{err});
        return;
    };
    defer client.deinit();

    // Your application code here...
    std.log.info("Application started with Sentry monitoring", .{});
}
```

With this configuration, Sentry will monitor for exceptions and capture events.

### Quick Usage Examples

#### Capturing Messages

```zig
const std = @import("std");
const sentry = @import("sentry_zig");

// After initializing the client...

// Capture messages with different severity levels
_ = try sentry.captureMessage("Application started successfully", .info);
_ = try sentry.captureMessage("Warning: Low memory", .warning);
_ = try sentry.captureMessage("Critical error occurred", .@"error");
_ = try sentry.captureMessage("System failure - immediate attention required", .fatal);
```

#### Capturing Errors

```zig
const std = @import("std");
const sentry = @import("sentry_zig");

const MyError = error{
    FileNotFound,
    PermissionDenied,
    OutOfMemory,
};

fn riskyOperation() !void {
    return MyError.FileNotFound;
}

pub fn main() !void {
    // ... initialize sentry ...

    // Capture errors with automatic stack trace
    riskyOperation() catch |err| {
        std.debug.print("Caught error: {}\n", .{err});
        
        const event_id = try sentry.captureError(err);
        if (event_id) |id| {
            std.debug.print("Error sent to Sentry with ID: {s}\n", .{id.value});
        }
    };
}
```

#### Setting up Panic Handler

For automatic panic reporting, set up the Sentry panic handler:

```zig
const std = @import("std");
const sentry = @import("sentry_zig");

// Set up the panic handler to use Sentry's panic handler
pub const panic = std.debug.FullPanic(sentry.panicHandler);

pub fn main() !void {
    // ... initialize sentry ...

    // Any panic in your application will now be automatically sent to Sentry
    std.debug.panic("This will be captured by Sentry!");
}
```

## 🔧 Configuration Options

The `SentryOptions` struct supports various configuration options:

```zig
const options = sentry.SentryOptions{
    .environment = "production",      // Environment (e.g., "development", "staging", "production")
    .release = "1.2.3",              // Release version
    .debug = false,                  // Enable debug logging
    .sample_rate = 1.0,              // Sample rate (0.0 to 1.0)
    .send_default_pii = false,       // Whether to send personally identifiable information
};
```

## 🧩 Features

### Current Features
- ✅ **Event Capture**: Send custom events to Sentry
- ✅ **Message Capture**: Log messages with different severity levels
- ✅ **Error Capture**: Automatic error capture with stack traces
- ✅ **Panic Handler**: Automatic panic reporting
- ✅ **Release Tracking**: Track releases and environments
- ✅ **Debug Mode**: Detailed logging for troubleshooting
- ✅ **Configurable Sampling**: Control event sampling rates

### Upcoming Features
- 🔄 **Breadcrumbs**: Track user actions and application state
- 🔄 **User Context**: Attach user information to events  
- 🔄 **Custom Tags**: Add custom tags to events
- 🔄 **Performance Monitoring**: Track application performance
- 🔄 **Integrations**: Common Zig library integrations

## 📁 Examples

The repository includes several complete examples in the `examples/` directory:

- **`capture_message.zig`** - Demonstrates message capture with different severity levels
- **`capture_error.zig`** - Shows error capture with stack traces
- **`panic_handler.zig`** - Example of automatic panic reporting

Run examples using:

```bash
# Build and run the message capture example
zig build capture_message

# Build and run the error capture example  
zig build capture_error

# Build and run the panic handler example
zig build panic_handler
```

## 🏗️ Building from Source

```bash
# Clone the repository
git clone https://github.com/getsentry/sentry-zig.git
cd sentry-zig

# Build the library
zig build

# Run tests
zig build test

# Run examples
zig build capture_message
zig build capture_error
zig build panic_handler
```

## 🧪 Testing

This SDK is experimental. When testing:

1. Set up a test Sentry project (don't use production)
2. Enable debug mode to see detailed logging
3. Check your Sentry dashboard for captured events
4. Review the examples for best practices

## 🚧 Development Status

**Current Status**: Experimental / Hackweek Project

This SDK was built during a Sentry Hackweek and is not yet ready for production use. We're actively working on:

- Stabilizing the API
- Adding comprehensive tests
- Implementing missing features
- Performance optimizations
- Documentation improvements

## 🙌 Contributing

We welcome contributions! This is an experimental project and there's lots of room for improvement.

### Areas where we need help:
- 🐛 **Bug fixes** - Report issues or submit fixes
- ✨ **Features** - Implement missing Sentry features  
- 📚 **Documentation** - Improve docs and examples
- 🧪 **Testing** - Add tests and improve coverage
- 🔍 **Code Review** - Review PRs and provide feedback

### Getting Started:
1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## 🛟 Support

- 📖 **Documentation**: [docs.sentry.io](https://docs.sentry.io)
- 💬 **Discord**: [Sentry Community Discord](https://discord.gg/sentry)
- 🐦 **Twitter/X**: [@getsentry](https://twitter.com/getsentry)
- 📧 **Issues**: [GitHub Issues](https://github.com/getsentry/sentry-zig/issues)

## 📃 License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## 🔗 Resources

- [Sentry Documentation](https://docs.sentry.io) - Complete Sentry documentation
- [Zig Language](https://ziglang.org) - Learn about the Zig programming language
- [Sentry for Other Languages](https://docs.sentry.io/platforms/) - SDKs for other programming languages

## ⚠️ Disclaimer

This is an experimental SDK created during a Hackweek project. It is not officially supported by Sentry and should not be used in production environments without thorough testing and evaluation.

---

*Built with ❤️ during Sentry Hackweek*
