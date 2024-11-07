const std = @import("std");

const way2 = @import("way2");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var client = way2.Client.init(gpa.allocator());
    try client.connect();
    defer client.disconnect();

    var window = way2.Window.init(&client);
    try window.open(
        .{ 800, 600 },
        .{},
    );
    defer window.close();

    var shade: u8 = 0;
    while (true) {
        shade = @addWithOverflow(shade, 1)[0];
        @memset(window.surface().buffer, .{ .rgba = .{
            .a = 255,
            .r = shade,
            .g = 0,
            .b = 0,
        } });

        try window.present();

        try client.listen();
    }
}
