const std = @import("std");
const net = std.net;
const mem = std.mem;

const Request = @import("Request.zig");
const Response = @import("Response.zig");

const Server = @This();

listener: net.Server,
pool: *std.Thread.Pool,
allocator: std.mem.Allocator,

const Config = struct {
    addr: []const u8 = "127.0.0.1",
    port: u16,
    n_jobs: ?u32 = null,
};

pub fn init(allocator: mem.Allocator, config: Config) !Server {
    const address = try net.Address.resolveIp(config.addr, config.port);
    const listener = try address.listen(.{ .reuse_address = true });

    const pool = try allocator.create(std.Thread.Pool);
    errdefer allocator.destroy(pool);

    try pool.init(.{ .allocator = allocator, .n_jobs = config.n_jobs });
    return .{
        .listener = listener,
        .pool = pool,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Server) void {
    self.pool.deinit();
    self.allocator.destroy(self.pool);
    self.listener.deinit();
}

pub fn listen(self: *Server) !void {
    while (true) {
        const conn = try self.listener.accept();
        try self.pool.spawn(handleConn, .{ self.allocator, conn.stream });
    }
}

// TODO - create handle registering
fn handleConn(allocator: mem.Allocator, stream: net.Stream) void {
    defer stream.close();

    var request = Request.parse(allocator, stream) catch |err| {
        std.debug.print("Error parsing request: {s}\n", .{@errorName(err)});
        return;
    };
    defer request.deinit();

    const stdout = std.io.getStdOut().writer();

    stdout.print(
        \\Method: {s}
        \\Url: {s}
        \\Version: {s}
        \\Headers:
        \\
    ,
        .{
            @tagName(request.method),
            request.url,
            request.version,
        },
    ) catch {};

    var header_iter = request.headers.iterator();
    while (header_iter.next()) |entry| {
        stdout.print("  {s}: ", .{entry.key_ptr.*}) catch {};

        const header_len = entry.value_ptr.items.len;
        for (entry.value_ptr.items, 0..) |val, idx| {
            stdout.print("{s}", .{val}) catch {};
            if (idx < header_len - 1) {
                stdout.print(", ", .{}) catch {};
            }
        }

        stdout.print("\n", .{}) catch {};
    }

    const body = request.parseBody() catch |err| {
        std.debug.print("Error parsing body: {s}\n", .{@errorName(err)});
        return;
    };

    if (body.len > 0) {
        stdout.print("Body: {s}\n", .{body}) catch {};
    }

    var resp = Response.init(allocator);
    defer resp.deinit();

    resp.addHeader("Test-Header", "First") catch {};
    resp.addHeader("Test-Header", "Second") catch {};
    resp.body = "my little message";
    resp.status_code = .{ .code = 201, .msg = "Created" };

    resp.write(stream) catch |err| {
        std.debug.print("Error writing response: {s}\n", .{@errorName(err)});
        return;
    };
}
