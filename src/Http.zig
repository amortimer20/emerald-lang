//! Native HTTP transport for Emerald's future `Http` library.
//!
//! This module deliberately has no Emerald-facing surface yet.  It owns a
//! worker-backed Zig I/O instance because the interpreter's normal I/O is the
//! single-threaded global instance, which cannot run a request and deadline
//! concurrently or cancel either one.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Problem = struct {
    kind: Kind,
    message: []const u8,

    pub const Kind = enum {
        invalid_url,
        unsupported_scheme,
        connection_failed,
        timed_out,
        too_many_redirects,
        response_too_large,
        request_failed,
    };
};

pub const Method = enum { get, post };

pub const Options = struct {
    method: Method = .get,
    body: ?[]const u8 = null,
    headers: []const std.http.Header = &.{},
    timeout: std.Io.Duration = .fromSeconds(15),
    maximum_body_bytes: usize = 64 * 1024 * 1024,
};

pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: *Response, allocator: Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const Outcome = union(enum) {
    response: Response,
    problem: Problem,
};

/// A client has its own worker-backed I/O instance.  `global_single_threaded`
/// is intentionally unsuitable here: it documents that it supports neither
/// concurrency nor cancellation, both of which a whole-request deadline needs.
pub const Client = struct {
    allocator: Allocator,
    threaded: std.Io.Threaded,
    inner: std.http.Client,

    /// Initializes in place because `std.Io.Threaded.io()` retains a pointer
    /// to its owning `Threaded`; returning a copied `Threaded` would leave the
    /// HTTP client pointing at the old stack address.
    pub fn init(self: *Client, allocator: Allocator) void {
        self.allocator = allocator;
        self.threaded = std.Io.Threaded.init(allocator, .{});
        self.inner = .{ .allocator = allocator, .io = self.threaded.io() };
    }

    pub fn deinit(self: *Client) void {
        self.inner.deinit();
        self.threaded.deinit();
        self.* = undefined;
    }

    /// Performs one bounded request.  The request and monotonic deadline race
    /// on the worker I/O; `cancelDiscard` asks the losing operation to stop and
    /// waits for it before this function returns.
    pub fn request(self: *Client, url: []const u8, options: Options) Outcome {
        const Race = union(enum) { request: Outcome, deadline: u8 };
        var results: [2]Race = undefined;
        var race = std.Io.Select(Race).init(self.threaded.io(), &results);
        defer race.cancelDiscard();

        race.concurrent(.request, perform, .{ self, url, options }) catch {
            return .{ .problem = .{ .kind = .request_failed, .message = "the HTTP request could not be started" } };
        };
        race.concurrent(.deadline, wait, .{ self.threaded.io(), options.timeout }) catch {
            return .{ .problem = .{ .kind = .request_failed, .message = "the HTTP request deadline could not be started" } };
        };

        return switch (race.await() catch {
            return .{ .problem = .{ .kind = .request_failed, .message = "the HTTP request was interrupted" } };
        }) {
            .request => |outcome| outcome,
            .deadline => .{ .problem = .{ .kind = .timed_out, .message = "the HTTP request timed out" } },
        };
    }
};

fn wait(io: std.Io, duration: std.Io.Duration) u8 {
    std.Io.sleep(io, duration, .awake) catch {};
    return 0;
}

fn perform(client: *Client, url: []const u8, options: Options) Outcome {
    // A fixed writer makes the response limit a streaming bound, including
    // chunked and decompressed bodies, rather than an after-the-fact check.
    // The later public layer keeps the settled 64 MB default.
    const storage = client.allocator.alloc(u8, options.maximum_body_bytes) catch {
        return .{ .problem = .{ .kind = .request_failed, .message = "there is not enough memory for the HTTP response" } };
    };
    var output = std.Io.Writer.fixed(storage);

    const result = client.inner.fetch(.{
        .location = .{ .url = url },
        .method = switch (options.method) {
            .get => .GET,
            .post => .POST,
        },
        .payload = options.body,
        .extra_headers = options.headers,
        .response_writer = &output,
    }) catch |err| {
        client.allocator.free(storage);
        // `std.http.Client.fetch` intentionally collapses a response-writer
        // failure to `WriteFailed`; this writer can fail only at our limit.
        if (err == error.NoSpaceLeft or err == error.WriteFailed) {
            return .{ .problem = .{ .kind = .response_too_large, .message = "the HTTP response is larger than the allowed limit" } };
        }
        return .{ .problem = mapError(err) };
    };

    const body = client.allocator.realloc(storage, output.buffered().len) catch {
        client.allocator.free(storage);
        return .{ .problem = .{ .kind = .request_failed, .message = "the HTTP response could not be stored" } };
    };
    return .{ .response = .{ .status = @intFromEnum(result.status), .body = body } };
}

fn mapError(err: anyerror) Problem {
    return switch (err) {
        error.InvalidFormat, error.InvalidCharacter, error.InvalidEnd, error.InvalidPort, error.UnexpectedCharacter => .{ .kind = .invalid_url, .message = "the URL is not valid" },
        error.UnsupportedUriScheme => .{ .kind = .unsupported_scheme, .message = "the URL must use `http` or `https`" },
        error.TooManyHttpRedirects => .{ .kind = .too_many_redirects, .message = "the HTTP request followed too many redirects" },
        error.ConnectionRefused, error.ConnectionTimedOut, error.NetworkUnreachable, error.HostUnreachable, error.NameServerFailure => .{ .kind = .connection_failed, .message = "the HTTP server could not be reached" },
        error.Canceled => .{ .kind = .timed_out, .message = "the HTTP request timed out" },
        else => .{ .kind = .request_failed, .message = "the HTTP request failed" },
    };
}

test "the interpreter global I/O cannot support a deadline race" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const Result = union(enum) { done: u8 };
    var values: [1]Result = undefined;
    var select = std.Io.Select(Result).init(io, &values);
    try std.testing.expectError(error.ConcurrencyUnavailable, select.concurrent(.done, immediate, .{}));
}

fn immediate() u8 {
    return 0;
}

const TestServer = struct {
    io: std.Io.Threaded,
    listener: std.Io.net.Server,
    thread: std.Thread,
    allocator: Allocator,
    stopping: std.atomic.Value(bool) = .init(false),

    fn start(allocator: Allocator) !*TestServer {
        const server = try allocator.create(TestServer);
        errdefer allocator.destroy(server);
        server.io = std.Io.Threaded.init(allocator, .{});
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        server.listener = try address.listen(server.io.io(), .{});
        server.allocator = allocator;
        server.thread = try std.Thread.spawn(.{}, serve, .{server});
        return server;
    }

    fn deinit(server: *TestServer) void {
        server.stopping.store(true, .release);
        // Waking `accept` with an ordinary loopback connection is portable.
        // Closing its descriptor while another thread is accepting is not:
        // Zig's threaded I/O correctly diagnoses that as use-after-close.
        if (server.listener.socket.address.connect(std.Io.Threaded.global_single_threaded.io(), .{ .mode = .stream })) |stream| {
            stream.close(std.Io.Threaded.global_single_threaded.io());
        } else |_| {}
        server.thread.join();
        server.listener.deinit(server.io.io());
        server.io.deinit();
        server.allocator.destroy(server);
    }

    fn url(server: *const TestServer, allocator: Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ server.listener.socket.address.getPort(), path });
    }

    fn serve(server: *TestServer) void {
        const io = server.io.io();
        while (true) {
            var stream = server.listener.accept(io) catch break;
            defer stream.close(io);
            if (server.stopping.load(.acquire)) break;
            var input_buffer: [4096]u8 = undefined;
            var output_buffer: [4096]u8 = undefined;
            var input = stream.reader(io, &input_buffer);
            var output = stream.writer(io, &output_buffer);
            var http_server = std.http.Server.init(&input.interface, &output.interface);
            var request = http_server.receiveHead() catch continue;
            serveRequest(io, &request);
        }
    }

    fn serveRequest(io: std.Io, request: *std.http.Server.Request) void {
        if (std.mem.eql(u8, request.head.target, "/echo")) {
            const header_seen = std.mem.indexOf(u8, request.head_buffer, "x-test: yes") != null;
            const length: usize = @intCast(request.head.content_length orelse 0);
            var body: [128]u8 = undefined;
            if (length > body.len) {
                request.respond("body too large", .{ .status = .payload_too_large, .keep_alive = false }) catch {};
                return;
            }
            const reader = request.readerExpectNone(&.{});
            reader.readSliceAll(body[0..length]) catch return;
            if (request.head.method == .POST and header_seen) {
                request.respond(body[0..length], .{ .keep_alive = false }) catch {};
            } else {
                request.respond("echo mismatch", .{ .status = .bad_request, .keep_alive = false }) catch {};
            }
        } else if (std.mem.eql(u8, request.head.target, "/slow")) {
            std.Io.sleep(io, .fromMilliseconds(250), .awake) catch return;
            request.respond("too late", .{ .keep_alive = false }) catch {};
        } else if (std.mem.eql(u8, request.head.target, "/redirect")) {
            request.respond("", .{ .status = .found, .keep_alive = false, .extra_headers = &.{.{ .name = "location", .value = "/ok" }} }) catch {};
        } else if (std.mem.eql(u8, request.head.target, "/redirect-loop")) {
            request.respond("", .{ .status = .found, .keep_alive = false, .extra_headers = &.{.{ .name = "location", .value = "/redirect-loop" }} }) catch {};
        } else if (std.mem.eql(u8, request.head.target, "/chunked")) {
            request.respond("chunked body", .{ .keep_alive = false, .transfer_encoding = .chunked }) catch {};
        } else if (std.mem.eql(u8, request.head.target, "/gzip")) {
            request.respond("\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\xcb\x48\xcd\xc9\xc9\x07\x00\x86\xa6\x10\x36\x05\x00\x00\x00", .{ .keep_alive = false, .extra_headers = &.{.{ .name = "content-encoding", .value = "gzip" }} }) catch {};
        } else if (std.mem.eql(u8, request.head.target, "/binary")) {
            request.respond("\xff\x00\x7f", .{ .keep_alive = false }) catch {};
        } else if (std.mem.eql(u8, request.head.target, "/large")) {
            request.respond("0123456789012345678901234567890123456789", .{ .keep_alive = false }) catch {};
        } else if (std.mem.eql(u8, request.head.target, "/missing")) {
            request.respond("missing", .{ .status = .not_found, .keep_alive = false }) catch {};
        } else {
            request.respond("hello", .{ .keep_alive = false }) catch {};
        }
    }
};

test "local HTTP transport handles responses, redirects, limits, and deadlines" {
    const allocator = std.testing.allocator;
    const server = try TestServer.start(allocator);
    defer server.deinit();
    var client: Client = undefined;
    client.init(allocator);
    defer client.deinit();

    const ok_url = try server.url(allocator, "/ok");
    defer allocator.free(ok_url);
    var ok = switch (client.request(ok_url, .{})) {
        .response => |response| response,
        .problem => return std.testing.expect(false),
    };
    defer ok.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), ok.status);
    try std.testing.expectEqualStrings("hello", ok.body);

    const echo_url = try server.url(allocator, "/echo");
    defer allocator.free(echo_url);
    var echo = switch (client.request(echo_url, .{
        .method = .post,
        .body = "posted body",
        .headers = &.{.{ .name = "x-test", .value = "yes" }},
    })) {
        .response => |response| response,
        .problem => return std.testing.expect(false),
    };
    defer echo.deinit(allocator);
    try std.testing.expectEqualStrings("posted body", echo.body);

    const redirect_url = try server.url(allocator, "/redirect");
    defer allocator.free(redirect_url);
    var redirected = switch (client.request(redirect_url, .{})) {
        .response => |response| response,
        .problem => return std.testing.expect(false),
    };
    defer redirected.deinit(allocator);
    try std.testing.expectEqualStrings("hello", redirected.body);

    const loop_url = try server.url(allocator, "/redirect-loop");
    defer allocator.free(loop_url);
    switch (client.request(loop_url, .{})) {
        .problem => |problem| try std.testing.expectEqual(Problem.Kind.too_many_redirects, problem.kind),
        .response => |response| {
            var owned = response;
            defer owned.deinit(allocator);
            return std.testing.expect(false);
        },
    }

    const chunked_url = try server.url(allocator, "/chunked");
    defer allocator.free(chunked_url);
    var chunked = switch (client.request(chunked_url, .{})) {
        .response => |response| response,
        .problem => return std.testing.expect(false),
    };
    defer chunked.deinit(allocator);
    try std.testing.expectEqualStrings("chunked body", chunked.body);

    const gzip_url = try server.url(allocator, "/gzip");
    defer allocator.free(gzip_url);
    var gzip = switch (client.request(gzip_url, .{})) {
        .response => |response| response,
        .problem => return std.testing.expect(false),
    };
    defer gzip.deinit(allocator);
    try std.testing.expectEqualStrings("hello", gzip.body);

    const missing_url = try server.url(allocator, "/missing");
    defer allocator.free(missing_url);
    var missing = switch (client.request(missing_url, .{})) {
        .response => |response| response,
        .problem => return std.testing.expect(false),
    };
    defer missing.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 404), missing.status);

    const binary_url = try server.url(allocator, "/binary");
    defer allocator.free(binary_url);
    var binary = switch (client.request(binary_url, .{})) {
        .response => |response| response,
        .problem => return std.testing.expect(false),
    };
    defer binary.deinit(allocator);
    try std.testing.expectEqualSlices(u8, "\xff\x00\x7f", binary.body);

    const large_url = try server.url(allocator, "/large");
    defer allocator.free(large_url);
    switch (client.request(large_url, .{ .maximum_body_bytes = 8 })) {
        .problem => |problem| try std.testing.expectEqual(Problem.Kind.response_too_large, problem.kind),
        .response => |response| {
            var owned = response;
            defer owned.deinit(allocator);
            return std.testing.expect(false);
        },
    }

    const slow_url = try server.url(allocator, "/slow");
    defer allocator.free(slow_url);
    switch (client.request(slow_url, .{ .timeout = .fromMilliseconds(10) })) {
        .problem => |problem| try std.testing.expectEqual(Problem.Kind.timed_out, problem.kind),
        .response => |response| {
            var owned = response;
            defer owned.deinit(allocator);
            return std.testing.expect(false);
        },
    }
}
