//! Manual, opt-in checks for the HTTP client's real network boundary.
//!
//! `zig build http-live` is intentionally never a dependency of `test` or CI:
//! its result depends on DNS, the machine certificate store, and any configured
//! proxy. It checks that the transport accepts an ordinary trusted HTTPS
//! response and rejects the three independently-invalid badssl certificates.

const std = @import("std");
const emerald = @import("emerald");
const Http = emerald.Http;

pub fn main(init: std.process.Init) !void {
    var client: Http.Client = undefined;
    try client.init(std.heap.smp_allocator, init.minimal.environ);
    defer client.deinit();

    if (client.inner.http_proxy != null or client.inner.https_proxy != null) {
        std.debug.print("HTTP_PROXY or HTTPS_PROXY is active; requests use that proxy.\n", .{});
    } else {
        std.debug.print("No HTTP proxy is configured.\n", .{});
    }

    try expectStatus(&client, "https://example.com", 200);
    try expectProblem(&client, "https://expired.badssl.com", .certificate_failed);
    try expectProblem(&client, "https://self-signed.badssl.com", .certificate_failed);
    try expectProblem(&client, "https://wrong.host.badssl.com", .certificate_failed);
    try expectProblem(&client, "https://emerald-http-client-does-not-exist.invalid", .unknown_host);

    // The transport checks above identify the host failure. These run through
    // Emerald too, so the manual command also protects the actual HttpError
    // wording a program sees rather than only native Problem kinds.
    try expectHttpError(init, "https://expired.badssl.com", "could not verify the identity");
    try expectHttpError(init, "https://self-signed.badssl.com", "could not verify the identity");
    try expectHttpError(init, "https://wrong.host.badssl.com", "could not verify the identity");
    try expectHttpError(init, "https://emerald-http-client-does-not-exist.invalid", "could not find the server");
    std.debug.print("HTTP live checks passed.\n", .{});
}

fn expectStatus(client: *Http.Client, url: []const u8, wanted: u16) !void {
    var response = switch (client.request(url, .{})) {
        .response => |response| response,
        .problem => |problem| {
            std.debug.print("{s}: expected HTTP {d}, got {s}: {s}\n", .{ url, wanted, @tagName(problem.kind), problem.message });
            return error.UnexpectedHttpProblem;
        },
    };
    defer response.deinit(std.heap.smp_allocator);
    if (response.status != wanted) {
        std.debug.print("{s}: expected HTTP {d}, got {d} {s}\n", .{ url, wanted, response.status, response.reason });
        return error.UnexpectedHttpStatus;
    }
    std.debug.print("{s}: HTTP {d} OK\n", .{ url, response.status });
}

fn expectProblem(client: *Http.Client, url: []const u8, wanted: Http.Problem.Kind) !void {
    switch (client.request(url, .{})) {
        .problem => |problem| {
            if (problem.kind != wanted) {
                std.debug.print("{s}: expected {s}, got {s}: {s}\n", .{ url, @tagName(wanted), @tagName(problem.kind), problem.message });
                return error.UnexpectedHttpProblem;
            }
            std.debug.print("{s}: {s}\n", .{ url, @tagName(problem.kind) });
        },
        .response => |response| {
            var owned = response;
            defer owned.deinit(std.heap.smp_allocator);
            std.debug.print("{s}: expected {s}, got HTTP {d}\n", .{ url, @tagName(wanted), owned.status });
            return error.UnexpectedHttpSuccess;
        },
    }
}

fn expectHttpError(init: std.process.Init, url: []const u8, expected: []const u8) !void {
    const allocator = std.heap.smp_allocator;
    const text = try std.fmt.allocPrint(allocator, "const response = Http.get(\"{s}\")\n", .{url});
    defer allocator.free(text);
    var source = try emerald.Source.init(allocator, "http-live.em", text);
    defer source.deinit(allocator);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var input: std.Io.Reader = .fixed("");
    var report = try emerald.run(allocator, &source, .{
        .out = &output.writer,
        .in = &input,
        .environment = init.minimal.environ,
    });
    defer report.deinit();
    const failure = report.failure orelse {
        std.debug.print("{s}: expected HttpError containing `{s}`, but it ran successfully\n", .{ url, expected });
        return error.MissingHttpError;
    };
    if (std.mem.indexOf(u8, failure.message, expected) == null) {
        std.debug.print("{s}: expected HttpError containing `{s}`, got `{s}`\n", .{ url, expected, failure.message });
        return error.WrongHttpError;
    }
    std.debug.print("{s}: Emerald HttpError is clear\n", .{url});
}
