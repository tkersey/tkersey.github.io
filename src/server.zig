const std = @import("std");

pub const ServeOptions = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    out_dir_path: []const u8 = "dist",
};

pub fn serve(base_dir: std.fs.Dir, options: ServeOptions) !void {
    const address = try std.net.Address.parseIp(options.host, options.port);
    var tcp_server = try address.listen(.{ .reuse_address = true });
    defer tcp_server.deinit();

    while (true) {
        const connection = try tcp_server.accept();
        handleConnection(base_dir, options.out_dir_path, connection) catch |err| {
            std.log.warn("serve: connection failed: {s}", .{@errorName(err)});
        };
    }
}

fn handleConnection(base_dir: std.fs.Dir, out_dir_path: []const u8, connection: std.net.Server.Connection) !void {
    defer connection.stream.close();

    var send_buffer: [4096]u8 = undefined;
    var recv_buffer: [4096]u8 = undefined;
    var connection_reader = connection.stream.reader(&recv_buffer);
    var connection_writer = connection.stream.writer(&send_buffer);
    var http_server: std.http.Server = .init(connection_reader.interface(), &connection_writer.interface);

    var out_dir = try base_dir.openDir(out_dir_path, .{});
    defer out_dir.close();

    while (true) {
        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };

        serveRequest(&request, out_dir) catch |err| {
            std.log.debug(
                "serve: {s} {s} failed: {s}",
                .{ @tagName(request.head.method), request.head.target, @errorName(err) },
            );
            return;
        };
    }
}

fn serveRequest(request: *std.http.Server.Request, out_dir: std.fs.Dir) !void {
    const max_file_size: u64 = 20 * 1024 * 1024;

    if (request.head.method != .GET and request.head.method != .HEAD) {
        const headers = [_]std.http.Header{
            .{ .name = "allow", .value = "GET, HEAD" },
            .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        };
        try request.respond("Method Not Allowed\n", .{
            .status = .method_not_allowed,
            .extra_headers = &headers,
        });
        return;
    }

    const path = normalizePath(request.head.target);
    if (!isSafeRelPath(path)) {
        try respondNotFound(request);
        return;
    }

    var file_path_buf: [1024]u8 = undefined;
    const file_path = file_path: {
        if (path.len == 0) break :file_path "index.html";
        if (std.mem.endsWith(u8, path, "/")) {
            break :file_path std.fmt.bufPrint(&file_path_buf, "{s}index.html", .{path}) catch {
                try respondNotFound(request);
                return;
            };
        }
        break :file_path path;
    };
    var file = out_dir.openFile(file_path, .{}) catch {
        try respondNotFound(request);
        return;
    };
    defer file.close();

    const file_stat = file.stat() catch {
        try respondNotFound(request);
        return;
    };
    if (file_stat.size > max_file_size) {
        const headers = [_]std.http.Header{
            .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        };
        try request.respond("File Too Large\n", .{
            .status = .payload_too_large,
            .extra_headers = &headers,
        });
        return;
    }

    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = contentTypeForPath(file_path) },
    };

    var body_buf: [4096]u8 = undefined;
    var body = try request.respondStreaming(&body_buf, .{
        .content_length = file_stat.size,
        .respond_options = .{
            .extra_headers = &headers,
        },
    });
    defer body.end() catch {};

    if (!body.isEliding()) {
        var read_buf: [8192]u8 = undefined;
        var file_reader_buf: [8192]u8 = undefined;
        var reader = file.reader(&file_reader_buf);

        while (true) {
            const n = try reader.interface.readSliceShort(&read_buf);
            if (n == 0) break;
            try body.writer.writeAll(read_buf[0..n]);
            if (n < read_buf.len) break;
        }
    }
}

fn respondNotFound(request: *std.http.Server.Request) !void {
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
    };
    try request.respond("Not Found\n", .{
        .status = .not_found,
        .extra_headers = &headers,
    });
}

fn normalizePath(target: []const u8) []const u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    var path = target[0..query_start];
    if (std.mem.startsWith(u8, path, "/")) path = path[1..];
    return path;
}

fn isSafeRelPath(path: []const u8) bool {
    if (path.len == 0) return true;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        if (std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) return false;
        if (std.mem.indexOfScalar(u8, segment, '\\') != null) return false;
        if (std.mem.indexOfScalar(u8, segment, 0) != null) return false;
    }
    return true;
}

fn contentTypeForPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".xml")) return "application/xml; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
    return "application/octet-stream";
}

test "normalizePath" {
    const testing = std.testing;

    try testing.expectEqualStrings("", normalizePath("/"));
    try testing.expectEqualStrings("index.html", normalizePath("/index.html"));
    try testing.expectEqualStrings("docs/", normalizePath("/docs/"));
    try testing.expectEqualStrings("docs/index.html", normalizePath("/docs/index.html"));
    try testing.expectEqualStrings("", normalizePath("/?x=1"));
}
