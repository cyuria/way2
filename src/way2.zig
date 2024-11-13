const std = @import("std");
const builtin = @import("builtin");

const endian = builtin.cpu.arch.endian();
const log = std.log.scoped(.way2);

const type2 = @import("type2");
const wl = @import("protocols");
const wayland = wl.wayland;
const xdg_shell = wl.xdg_shell;

/// Wayland wire protocol implementation/abstraction. Replaces libwayland
pub const Client = struct {
    // Known constant wayland IDs
    const wl_invalid = 0;
    const wl_display = 1;
    const wl_registry = 2;

    /// Manages the registration and deregistration of available global wayland
    /// objects.
    const Index = struct {
        /// Represents a single wayland global object.
        const Interface = struct {
            name: u32,
            string: wl.types.String,
            version: u32,
        };

        allocator: std.mem.Allocator,
        objects: std.StringHashMap(Interface),
        names: std.AutoHashMap(u32, []u8),

        fn init(allocator: std.mem.Allocator) Index {
            return .{
                .allocator = allocator,
                .objects = std.StringHashMap(Interface).init(allocator),
                .names = std.AutoHashMap(u32, []u8).init(allocator),
            };
        }

        fn deinit(self: *Index) void {
            var it = self.objects.iterator();
            while (it.next()) |object| {
                self.allocator.free(object.value_ptr.string);
            }
            self.objects.deinit();
            self.names.deinit();
        }

        /// Register the availability of a new global wayland object. Called as a
        /// wayland event handler
        fn bind(
            self: *Index,
            object: u32,
            opcode: wayland.registry.event,
            body: []const u8,
        ) void {
            std.debug.assert(object == 2);
            std.debug.assert(opcode == .global);
            const event = deserialiseStruct(wayland.registry.ev.global, body);
            const interface = self.allocator.dupe(u8, event.interface) catch @panic("Out of memory");
            const new: Interface = .{
                .name = event.name,
                .string = interface,
                .version = event.version,
            };
            log.debug(
                "Found global interface {} {s} v{}",
                .{ new.name, interface, new.version },
            );
            self.objects.putNoClobber(interface, new) catch @panic("Out of memory");
            self.names.putNoClobber(event.name, interface) catch @panic("Out of memory");
        }

        /// Removes a global wayland object. Called as a wayland event handler
        fn unbind(
            self: *Index,
            object: u32,
            opcode: wayland.registry.event,
            body: []const u8,
        ) void {
            std.debug.assert(object == 2);
            std.debug.assert(opcode == .global_remove);

            const event = deserialiseStruct(wayland.registry.ev.global_remove, body);

            const interface = self.names.get(event.name) orelse {
                log.err(
                    "Attempting to remove unknown global interface {}\n",
                    .{event.name},
                );
                return;
            };

            std.debug.assert(self.objects.remove(interface));
            std.debug.assert(self.names.remove(event.name));
            self.allocator.free(interface);
        }
    };

    allocator: std.mem.Allocator,
    socket: ?std.net.Stream,

    handlers: std.ArrayList(wl.Events),
    free: std.ArrayList(u32),

    globals: Index,

    pub fn init(allocator: std.mem.Allocator) Client {
        var self = Client{
            .allocator = allocator,
            .socket = null,
            .handlers = std.ArrayList(wl.Events).init(allocator),
            .free = std.ArrayList(u32).init(allocator),
            .globals = Index.init(allocator),
        };
        const inv = self.bind(.invalid);
        const dsp = self.bind(.wl_display);
        const reg = self.bind(.wl_registry);
        std.debug.assert(inv == 0);
        std.debug.assert(dsp == 1);
        std.debug.assert(reg == 2);
        return self;
    }

    pub fn deinit(self: *Client) void {
        if (self.socket) |socket| socket.close();
        self.globals.deinit();
        self.handlers.deinit();
        self.free.deinit();
    }

    /// Opens a connection to a wayland compositor
    pub fn connect(self: *Client) !void {
        if (std.posix.getenv("WAYLAND_SOCKET")) |socket| {
            const handle = std.fmt.parseInt(
                std.posix.socket_t,
                socket,
                10,
            );
            if (handle) |h| {
                self.socket = .{ .handle = h };
                return;
            } else |err| {
                log.err("Could not parse \"WAYLAND_SOCKET\" due to error {}", .{err});
            }
        }

        const display = std.posix.getenv("WAYLAND_DISPLAY") orelse "wayland-0";

        const path = if (display[0] == '/')
            std.mem.concat(self.allocator, u8, &.{
                display,
            }) catch @panic("Out of memory")
        else
            std.mem.concat(self.allocator, u8, &.{
                std.posix.getenv("XDG_RUNTIME_DIR") orelse {
                    return error.MissingEnv;
                },
                "/",
                display,
            }) catch @panic("Out of memory");
        defer self.allocator.free(path);

        log.info("Connecting to wayland on {s}", .{path});
        self.socket = std.net.connectUnixSocket(path) catch |err| switch (err) {
            error.PermissionDenied,
            error.AddressInUse,
            error.AddressNotAvailable,
            error.FileNotFound,
            error.NameTooLong,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.ConnectionRefused,
            error.ConnectionTimedOut,
            error.ConnectionResetByPeer,
            error.ConnectionPending,
            => |e| {
                log.err("Cannot open Wayland Socket \"{s}\" - {}", .{ path, e });
                return error.WaylandConnection;
            },
            error.SystemResources,
            => @panic("Out of system resources"),
            error.Unexpected,
            => @panic("Unexpected Error"),
            error.AddressFamilyNotSupported,
            error.ProtocolFamilyNotAvailable,
            error.ProtocolNotSupported,
            error.SocketTypeNotSupported,
            error.NetworkUnreachable,
            error.WouldBlock,
            => unreachable,
        };
        errdefer if (self.socket) |s| s.close();

        self.send(1, wayland.display.rq{ .get_registry = .{ .registry = wl_registry } }) catch {
            return error.WaylandConnection;
        };

        // Register default handlers
        self.setHandler(wl_registry, .wl_registry, .global, &self.globals, Index.bind);
        self.setHandler(wl_registry, .wl_registry, .global_remove, &self.globals, Index.unbind);
        self.setHandler(wl_display, .wl_display, .wl_error, @as(*void, undefined), Client.waylandError);
        self.setHandler(wl_display, .wl_display, .delete_id, self, Client.unbind);
    }

    /// Close the wayland connection
    pub fn disconnect(self: *Client) void {
        if (self.socket == null) {
            log.warn("Already disconnected", .{});
            return;
        }
        self.socket.?.close();
        self.socket = null;
    }

    /// Send a wayland message. Accepts an rq type defined in one of the
    /// wayland protocol files.
    pub fn send(
        self: *Client,
        object: u32,
        request: anytype,
    ) error{
        WaylandConnection,
        WaylandDisconnected,
    }!void {
        const body = switch (request) {
            inline else => |payload| serialiseStruct(self.allocator, payload),
        };
        defer self.allocator.free(body);
        std.debug.assert(8 + body.len <= std.math.maxInt(u16));
        std.debug.assert(body.len % 4 == 0);
        const header = extern struct {
            object: u32,
            code: u16,
            size: u16,
        }{
            .object = object,
            .code = @intFromEnum(request),
            .size = @intCast(8 + body.len),
        };
        const packet = std.mem.concat(self.allocator, u8, &.{
            std.mem.asBytes(&header),
            body,
        }) catch @panic("Out of memory");
        defer self.allocator.free(packet);
        std.debug.assert(packet.len == header.size);

        log.debug("Sending packet: {X:0>8}", .{
            std.mem.bytesAsSlice(u32, packet),
        });
        const size = self.socket.?.write(packet) catch |err| switch (err) {
            error.DiskQuota,
            error.FileTooBig,
            error.InputOutput,
            error.NoSpaceLeft,
            error.DeviceBusy,
            => |e| {
                log.warn("IO error {}", .{e});
                return error.WaylandConnection;
            },
            error.BrokenPipe,
            error.ConnectionResetByPeer,
            error.ProcessNotFound,
            => |e| {
                log.warn("Disconnected after error {}", .{e});
                self.disconnect();
                return error.WaylandDisconnected;
            },
            error.SystemResources,
            => @panic("Out of system resources"),
            error.Unexpected,
            => @panic("Unexpected error"),
            error.InvalidArgument,
            error.LockViolation,
            error.AccessDenied,
            error.OperationAborted,
            error.NotOpenForWriting,
            error.WouldBlock,
            => unreachable,
        };
        std.debug.assert(size == packet.len);

        self.listen() catch |err| log.err("listen err {}", .{err});
    }

    /// Send a wayland message with an attached file descripter
    pub fn sendFd(
        self: *Client,
        object: u32,
        request: anytype,
        fd: std.posix.fd_t,
    ) !void {
        const body = switch (request) {
            inline else => |payload| serialiseStruct(self.allocator, payload),
        };
        defer self.allocator.free(body);
        std.debug.assert(8 + body.len <= std.math.maxInt(u16));
        std.debug.assert(body.len % 4 == 0);
        const header = extern struct {
            object: u32,
            code: u16,
            size: u16,
        }{
            .object = object,
            .code = @intFromEnum(request),
            .size = @intCast(8 + body.len),
        };
        const packet = std.mem.concat(self.allocator, u8, &.{
            std.mem.asBytes(&header),
            body,
        }) catch @panic("Out of memory");
        defer self.allocator.free(packet);

        const iov = std.posix.iovec_const{
            .base = packet.ptr,
            .len = packet.len,
        };

        const cmsg = std.mem.asBytes(&Cmsg(@TypeOf(fd)){
            .level = std.posix.SOL.SOCKET,
            .type = 0x01,
            .data = fd,
        });

        const msghdr = std.posix.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = @ptrCast(&iov),
            .iovlen = 1,
            .control = cmsg.ptr,
            .controllen = cmsg.len,
            .flags = 0,
        };

        log.debug("Sending packet with fd {}: {X:0>8}", .{
            fd,
            std.mem.bytesAsSlice(u32, packet),
        });
        const bytes_sent = std.posix.sendmsg(
            self.socket.?.handle,
            &msghdr,
            0,
        ) catch |err| switch (err) {
            error.ConnectionResetByPeer,
            error.BrokenPipe,
            error.NetworkUnreachable,
            error.NetworkSubsystemFailed,
            error.SocketNotConnected,
            => |e| {
                log.warn("Wayland disconnected after error {}", .{e});
                self.disconnect();
                return error.WaylandDisconnected;
            },
            error.SystemResources,
            => @panic("Out of system resources"),
            error.Unexpected,
            => @panic("Unexpected error"),
            error.AccessDenied,
            error.FastOpenAlreadyInProgress,
            error.MessageTooBig,
            error.FileDescriptorNotASocket,
            error.SymLinkLoop,
            error.AddressFamilyNotSupported,
            error.NameTooLong,
            error.FileNotFound,
            error.NotDir,
            error.AddressNotAvailable,
            error.WouldBlock,
            => unreachable,
        };
        if (bytes_sent != iov.len) {
            log.err("Unable to send bytes to wayland compositor", .{});
            return error.WaylandConnection;
        }

        self.listen() catch |err| log.err("listen err {}", .{err});
    }

    /// Waits for, receives and handles a single wayland event
    pub fn recv(self: *Client) error{
        WaylandConnection,
        WaylandDisconnected,
        InvalidWaylandMessage,
    }!void {
        const reader = self.socket.?.reader();

        const header = reader.readStruct(extern struct {
            object: u32,
            opcode: u16,
            size: u16,
        }) catch |err| switch (err) {
            error.InputOutput,
            => {
                log.err("IO error", .{});
                return error.WaylandConnection;
            },
            error.OperationAborted,
            error.BrokenPipe,
            error.ConnectionResetByPeer,
            error.ConnectionTimedOut,
            error.SocketNotConnected,
            error.Canceled,
            error.ProcessNotFound,
            error.EndOfStream,
            => |e| {
                log.warn("Disconnected after error {}", .{e});
                self.disconnect();
                return error.WaylandDisconnected;
            },
            error.SystemResources,
            => @panic("Out of system resources"),
            error.Unexpected,
            => @panic("Unexpected Error"),
            error.WouldBlock,
            error.IsDir,
            error.NotOpenForReading,
            error.AccessDenied,
            error.LockViolation,
            => unreachable,
        };
        const body = self.allocator.alloc(
            u8,
            header.size - @sizeOf(@TypeOf(header)),
        ) catch @panic("Out of memory");
        defer self.allocator.free(body);
        const size = reader.read(body) catch |err| switch (err) {
            error.InputOutput,
            => {
                log.err("IO error", .{});
                return error.WaylandConnection;
            },
            error.OperationAborted,
            error.BrokenPipe,
            error.ConnectionResetByPeer,
            error.ConnectionTimedOut,
            error.SocketNotConnected,
            error.Canceled,
            error.ProcessNotFound,
            error.Unexpected,
            => |e| {
                log.warn("Disconnected after error {}", .{e});
                self.disconnect();
                return error.WaylandDisconnected;
            },
            error.SystemResources,
            => @panic("Out of system resources"),
            error.IsDir,
            error.NotOpenForReading,
            error.WouldBlock,
            error.AccessDenied,
            error.LockViolation,
            => unreachable,
        };

        if (size != body.len) {
            return error.InvalidWaylandMessage;
        }

        // Call the respective event handler
        // This is quite convoluted due to type requirements
        switch (self.handlers.items[header.object]) {
            .invalid => {},
            inline else => |handlers| blk: {
                // If this is true then @enumFromInt would panic anyway
                // Also handles empty event cases
                if (header.opcode >= handlers.values.len) return error.InvalidWaylandMessage;

                const handler = handlers.get(@enumFromInt(header.opcode));
                if (handler == null) break :blk;

                handler.?.call(handler.?.context, header.object, @enumFromInt(header.opcode), body);
            },
        }
    }

    /// Check for available events
    pub fn eventAvailable(self: *Client) bool {
        var descriptor = [_]std.posix.pollfd{.{
            .revents = 0,
            .events = std.posix.POLL.IN,
            .fd = self.socket.?.handle,
        }};
        const result = std.posix.poll(&descriptor, 0) catch |err| switch (err) {
            error.SystemResources => @panic("Out of system resources"),
            error.NetworkSubsystemFailed => @panic("Network Subsystem Failed"),
            error.Unexpected => @panic("Unexpected error"),
        };
        return result > 0;
    }

    /// Receives and handles all events until there are none remaining in the queue
    pub fn listen(
        self: *Client,
    ) !void {
        while (self.eventAvailable())
            try self.recv();
    }

    /// Creates handlers for a new wayland object with the given interface.
    /// Returns the new object id.
    pub fn bind(
        self: *Client,
        interface: wl.Interface,
    ) u32 {
        const object = createEventHandlers(interface);

        if (self.free.items.len > 0) {
            const id = self.free.pop();
            std.debug.assert(self.handlers.items[id] == .invalid);
            self.handlers.items[id] = object;
            return id;
        }

        const id = self.handlers.items.len;
        self.handlers.append(object) catch @panic("Out of memory");
        return @intCast(id);
    }

    /// Removes handlers for the given wayland object and frees the object for
    /// future use
    pub fn invalidate(self: *Client, object: u32) void {
        const interface = self.handlers.items[object];
        log.debug("Invalidating {}[{s}]", .{ object, @tagName(interface) });
        if (interface == .invalid) {
            log.warn("Attempted to invalidate invalid object", .{});
            return;
        }
        self.handlers.items[object] = createEventHandlers(.invalid);
    }

    /// Creates an object to store event handlers for the given interface
    fn createEventHandlers(interface: wl.Interface) wl.Events {
        return switch (interface) {
            inline else => |i| @unionInit(
                wl.Events,
                @tagName(i),
                // Manually inline the std.meta.FieldType call because
                // otherwise we need an eval branch quota of 2 million
                std.meta.fields(wl.Events)[@intFromEnum(i)].type.initFill(null),
            ),
        };
    }

    /// Client
    fn setHandler(
        self: *Client,
        object: u32,
        comptime interface: wl.Interface,
        opcode: wl.map.get(interface),
        context: anytype,
        call: *const fn (@TypeOf(context), u32, @TypeOf(opcode), []const u8) void,
    ) void {
        switch (self.handlers.items[object]) {
            interface => |*handlers| handlers.set(opcode, .{
                .context = context,
                .call = @ptrCast(call),
            }),
            else => unreachable,
        }
    }

    /// Frees a deleted wayland ID for future use. Called as a wayland event
    /// handler
    fn unbind(
        self: *Client,
        object: u32,
        opcode: wayland.display.event,
        body: []const u8,
    ) void {
        std.debug.assert(object == wl_display);
        std.debug.assert(opcode == .delete_id);
        const event = deserialiseStruct(wayland.display.ev.delete_id, body);
        self.free.append(event.id) catch log.warn("Unable to record freed object", .{});
    }

    /// Logs any wayland errors that occur.
    fn waylandError(
        _: *void,
        object: u32,
        opcode: wayland.display.event,
        body: []const u8,
    ) void {
        std.debug.assert(object == wl_display);
        std.debug.assert(opcode == .wl_error);
        const event = deserialiseStruct(wayland.display.ev.wl_error, body);
        log.err(
            "Wayland Error 0x{X} [{}] {s}",
            .{ event.code, event.object_id, event.message },
        );
    }
};

/// Manages a user facing window. Requires a connected wayland `Client`
pub const Window = struct {
    pub const FrameBuffer = struct {
        buf: *Buffer,
        surface: type2.Surface,

        pub fn init(buf: *Buffer, offset: u32, width: u32, height: u32) FrameBuffer {
            // Round up if the alignment isn't ideal
            const off = offset / @sizeOf(type2.Pixel);
            const self = FrameBuffer{
                .buf = buf,
                .surface = .{
                    .buffer = std.mem.bytesAsSlice(
                        type2.Pixel,
                        buf.pool,
                    )[off .. off + width * height],
                    .width = width,
                    .height = height,
                },
            };
            std.debug.assert(self.surface.buffer.len == self.surface.width * self.surface.height);
            return self;
        }
    };

    const FrameTime = struct {
        done: bool = false,
        time: u32 = undefined,
        fn ready(
            self: *FrameTime,
            _: u32,
            opcode: wayland.callback.event,
            body: []const u8,
        ) void {
            std.debug.assert(opcode == .done);
            const event = deserialiseStruct(wayland.callback.ev.done, body);
            self.time = event.callback_data;
            self.done = true;
        }
    };

    client: *Client,
    seat: Seat,
    role: union(enum) {
        xdg: struct {
            wm_base: u32 = 0,
            surface: u32 = 0,
            toplevel: u32 = 0,
        },
    } = .{ .xdg = .{} },
    wl: struct {
        surface: u32 = 0,
        compositor: u32 = 0,
        shm: u32 = 0,
        pool: u32 = 0,
        buffer: u32 = 0,
        frame_callback: u32 = 0,
    } = .{},
    buffer: Buffer = undefined,
    frame: struct {
        buffer: FrameBuffer = undefined,
        time: FrameTime = .{},
    } = .{},
    size: @Vector(2, u32) = undefined,

    /// Flags for opening a window based on a given shell protocol
    const OpenFlags = struct {
        role: union(enum) {
            xdg: struct {
                fullscreen: enum { fullscreen, windowed } = .windowed,
                state: enum { default, maximised, minimised } = .default,
                min_size: ?@Vector(2, u32) = null,
                max_size: ?@Vector(2, u32) = null,
                decorations: enum { clientside, serverside } = .clientside,
            },
            wlr_layer: struct {
                layer: enum { background, bottom, top, overlay } = .top,
                margin: ?struct { top: u32 = 0, right: u32 = 0, bottom: u32 = 0, left: u32 = 0 } = null,
                keyboard_interactivity: bool = true,
            },
            fullscreen: struct {},
            // plasma: struct {}, // TODO: add support for org_kde_plasma_shell
            // weston: struct {}, // TODO: add support for weston_desktop_shell
            // agl: struct {}, // TODO: add support for agl_shell
            // aura: struct {}, // TODO: add support for zaura_shell
            // gtk: struct {}, // TODO: add support for gtk_shell1
            // mir: struct {}, // TODO: add support for mir_shell_v1
        } = .{ .xdg = .{} },
    };

    pub fn init(
        client: *Client,
    ) Window {
        return .{
            .client = client,
            .seat = Seat.init(client),
        };
    }

    /// Opens a new wayland window
    pub fn open(
        self: *Window,
        size: @Vector(2, u32),
        options: OpenFlags,
    ) !void {
        self.size = size;
        self.buffer = try Buffer.init(@sizeOf(type2.Pixel));
        errdefer self.buffer.deinit();
        self.frame.buffer = FrameBuffer.init(&self.buffer, 0, 1, 1);

        while (!self.client.globals.objects.contains("wl_compositor")) {
            try self.client.listen();
        }

        log.debug("binding wl_compositor", .{});
        self.wl.compositor = self.client.bind(.wl_compositor);
        errdefer {
            self.client.invalidate(self.wl.compositor);
            self.wl.compositor = 0;
        }
        const wl_compositor = self.client.globals.objects.get("wl_compositor").?;
        self.client.send(Client.wl_registry, wayland.registry.rq{ .bind = .{
            .id = self.wl.compositor,
            .name = wl_compositor.name,
            .version = wl_compositor.version,
            .interface = wl_compositor.string,
        } }) catch |e| {
            self.client.free.append(self.wl.compositor) catch |err| {
                log.err("Error received while cleaning up {}", .{err});
            };
            self.wl.compositor = 0;
            return e;
        };

        log.debug("creating wl_surface", .{});
        self.wl.surface = self.client.bind(.wl_surface);
        errdefer {
            self.client.invalidate(self.wl.surface);
            self.wl.surface = 0;
        }
        try self.client.send(self.wl.compositor, wayland.compositor.rq{ .create_surface = .{
            .id = self.wl.surface,
        } });
        errdefer {
            self.client.send(self.wl.surface, wayland.surface.rq{ .destroy = .{} }) catch |err| {
                log.err("Error received while cleaning up {}", .{err});
            };
        }

        switch (options.role) {
            .xdg => {
                log.debug("binding xdg_wm_base", .{});
                self.role.xdg.wm_base = self.client.bind(.xdg_wm_base);
                errdefer {
                    self.client.invalidate(self.role.xdg.wm_base);
                    self.role.xdg.wm_base = 0;
                }
                const xdg_wm_base = self.client.globals.objects.get("xdg_wm_base") orelse {
                    // TODO: properly document and rename xdg not supported error
                    return error.Unsupported;
                };
                self.client.setHandler(
                    self.role.xdg.wm_base,
                    .xdg_wm_base,
                    .ping,
                    self.client,
                    pong,
                );
                try self.client.send(2, wayland.registry.rq{ .bind = .{
                    .id = self.role.xdg.wm_base,
                    .name = xdg_wm_base.name,
                    .version = xdg_wm_base.version,
                    .interface = xdg_wm_base.string,
                } });
                errdefer {
                    self.client.send(
                        self.role.xdg.wm_base,
                        xdg_shell.wm_base.rq{ .destroy = .{} },
                    ) catch |err| {
                        log.err("Error received while cleaning up {}", .{err});
                    };
                }

                log.debug("binding xdg_surface", .{});
                self.role.xdg.surface = self.client.bind(.xdg_surface);
                self.client.setHandler(
                    self.role.xdg.surface,
                    .xdg_surface,
                    .configure,
                    self,
                    xdgConfigure,
                );
                try self.client.send(self.role.xdg.wm_base, xdg_shell.wm_base.rq{
                    .get_xdg_surface = .{
                        .id = self.role.xdg.surface,
                        .surface = self.wl.surface,
                    },
                });

                log.debug("binding xdg_toplevel", .{});
                self.role.xdg.toplevel = self.client.bind(.xdg_toplevel);
                self.client.setHandler(
                    self.role.xdg.toplevel,
                    .xdg_toplevel,
                    .configure,
                    self,
                    toplevelConfigure,
                );
                try self.client.send(self.role.xdg.surface, xdg_shell.surface.rq{
                    .get_toplevel = .{ .id = self.role.xdg.toplevel },
                });
            },
            else => return error.Unimplemented,
        }

        log.debug("binding wl_shm", .{});
        self.wl.shm = self.client.bind(.wl_shm);
        errdefer {
            self.client.invalidate(self.wl.shm);
            self.wl.shm = 0;
        }
        const wl_shm = self.client.globals.objects.get("wl_shm") orelse {
            return error.UnsupportedCompositor;
        };
        try self.client.send(
            Client.wl_registry,
            wayland.registry.rq{ .bind = .{
                .id = self.wl.shm,
                .name = wl_shm.name,
                .version = wl_shm.version,
                .interface = wl_shm.string,
            } },
        );
        errdefer {
            self.client.send(
                self.wl.shm,
                wayland.shm.rq{ .release = .{} },
            ) catch |err| {
                log.err("Error received while cleaning up {}", .{err});
            };
        }

        log.debug("creating wl_shm_pool", .{});
        self.wl.pool = self.client.bind(.wl_shm_pool);
        try self.client.sendFd(self.wl.shm, wayland.shm.rq{ .create_pool = .{
            .id = self.wl.pool,
            .size = @intCast(self.buffer.pool.len),
        } }, self.buffer.shm);
        errdefer {
            self.client.send(
                self.wl.shm,
                wayland.shm.rq{ .release = .{} },
            ) catch |err| {
                log.err("Error received while cleaning up {}", .{err});
            };
        }

        log.debug("creating wl_buffer", .{});
        self.wl.buffer = self.client.bind(.wl_buffer);
        // TODO: correctly handle the wl_buffer::release event
        // self.client.handlers.items[self.wl.buffer].wl_buffer.set(.release, .{
        //     .context = null,
        //     .call = @ptrCast(),
        // });
        try self.client.send(self.wl.pool, wayland.shm_pool.rq{ .create_buffer = .{
            .id = self.wl.buffer,
            .offset = 0,
            .width = 1,
            .height = 1,
            .stride = @sizeOf(type2.Pixel),
            .format = wayland.shm.Format.argb8888,
        } });

        {
            const roundtrip_callback = self.client.bind(.wl_callback);
            var roundtrip_done = false;
            self.client.setHandler(roundtrip_callback, .wl_callback, .done, &roundtrip_done, roundTrip);
            try self.client.send(Client.wl_display, wayland.display.rq{
                .sync = .{ .callback = roundtrip_callback },
            });

            while (!roundtrip_done) try self.client.recv();
            self.client.invalidate(roundtrip_callback);
            try self.client.listen();
        }

        log.debug("committing wl_surface", .{});
        try self.client.send(self.wl.surface, wayland.surface.rq{
            .commit = .{},
        });

        try self.newFrame();

        try self.seat.setup();

        {
            const roundtrip_callback = self.client.bind(.wl_callback);
            var roundtrip_done = false;
            self.client.setHandler(roundtrip_callback, .wl_callback, .done, &roundtrip_done, roundTrip);
            try self.client.send(Client.wl_display, wayland.display.rq{
                .sync = .{ .callback = roundtrip_callback },
            });

            while (!roundtrip_done) try self.client.recv();
            self.client.invalidate(roundtrip_callback);
            try self.client.listen();
        }
    }

    /// Closes a wayland window
    pub fn close(self: *Window) void {
        // TODO: destroy wayland objects on Window.close()
        self.buffer.deinit();
    }

    pub fn damage(
        self: Window,
        region: @Vector(4, i32),
    ) void {
        // TODO: implement Window.damage()
        _ = self;
        _ = region;
    }

    pub fn present(
        self: *Window,
    ) !void {
        while (!self.frame.time.done) try self.client.recv();
        try self.client.listen();

        self.client.invalidate(self.wl.frame_callback);
        try self.newFrame();

        try self.client.send(self.wl.surface, wayland.surface.rq{
            .attach = .{ .buffer = self.wl.buffer, .x = 0, .y = 0 },
        });
        try self.client.send(self.wl.surface, wayland.surface.rq{
            .damage = .{
                .x = 0,
                .y = 0,
                .width = @intCast(self.frame.buffer.surface.width),
                .height = @intCast(self.frame.buffer.surface.height),
            },
        });
        try self.client.send(self.wl.surface, wayland.surface.rq{
            .commit = .{},
        });
    }

    pub fn surface(self: Window) type2.Surface {
        return self.frame.buffer.surface;
    }

    fn newFrame(self: *Window) !void {
        self.frame.time.done = false;
        self.wl.frame_callback = self.client.bind(.wl_callback);
        try self.client.send(self.wl.surface, wayland.surface.rq{
            .frame = .{ .callback = self.wl.frame_callback },
        });
        self.client.setHandler(self.wl.frame_callback, .wl_callback, .done, &self.frame.time, FrameTime.ready);
        try self.client.listen();
    }

    fn roundTrip(
        trigger: *bool,
        object: u32,
        opcode: wayland.callback.event,
        body: []const u8,
    ) void {
        std.debug.assert(opcode == .done);
        trigger.* = true;
        _ = object;
        _ = body;
    }

    /// Wayland event handler for the xdg_shell wm_base pong event
    fn pong(
        client: *Client,
        object: u32,
        opcode: xdg_shell.wm_base.event,
        body: []const u8,
    ) void {
        std.debug.assert(opcode == .ping);
        log.debug("pong!", .{});
        const ping = deserialiseStruct(xdg_shell.wm_base.ev.ping, body);
        client.send(object, xdg_shell.wm_base.rq{
            .pong = .{ .serial = ping.serial },
        }) catch log.err("unrecoverable wayland connection error", .{});
    }

    /// Wayland event handler for the xdg_shell xdg_surface configure event
    fn xdgConfigure(
        self: *Window,
        object: u32,
        opcode: xdg_shell.surface.event,
        body: []const u8,
    ) void {
        std.debug.assert(opcode == .configure);
        std.debug.assert(object == self.role.xdg.surface);
        const event = deserialiseStruct(xdg_shell.surface.ev.configure, body);
        log.debug("configure event received", .{});
        self.buffer.resize(self.size[0] * self.size[1] * @sizeOf(type2.Pixel)) catch {
            log.err("unrecoverable IO error encountered", .{});
        };

        self.frame.buffer = FrameBuffer.init(&self.buffer, 0, self.size[0], self.size[1]);
        self.client.invalidate(self.wl.frame_callback);
        self.newFrame() catch log.err("unrecoverable wayland connection error", .{});

        log.debug("pool {} frame_callback {}", .{ self.wl.pool, self.wl.frame_callback });

        self.client.send(self.wl.pool, wayland.shm_pool.rq{
            .resize = .{ .size = @intCast(self.buffer.pool.len) },
        }) catch log.err("unrecoverable wayland connection error", .{});

        self.client.send(self.wl.buffer, wayland.buffer.rq{ .destroy = .{} }) catch {
            log.err("unrecoverable wayland connection error", .{});
        };
        self.client.invalidate(self.wl.buffer);

        log.debug("creating wl_buffer", .{});
        self.wl.buffer = self.client.bind(.wl_buffer);
        self.client.send(self.wl.pool, wayland.shm_pool.rq{ .create_buffer = .{
            .id = self.wl.buffer,
            .offset = 0,
            .width = @intCast(self.frame.buffer.surface.width),
            .height = @intCast(self.frame.buffer.surface.height),
            .stride = @intCast(@sizeOf(type2.Pixel) * self.frame.buffer.surface.width),
            .format = wayland.shm.Format.argb8888,
        } }) catch log.err("unrecoverable wayland connection error", .{});

        log.debug("attaching wl_buffer to wl_surface", .{});
        self.client.send(self.wl.surface, wayland.surface.rq{
            .attach = .{ .buffer = self.wl.buffer, .x = 0, .y = 0 },
        }) catch log.err("unrecoverable wayland connection error", .{});

        log.debug("acknowledging xdg_surface configure event", .{});
        self.client.send(self.role.xdg.surface, xdg_shell.surface.rq{
            .ack_configure = .{ .serial = event.serial },
        }) catch log.err("unrecoverable wayland connection error", .{});

        self.client.send(
            self.wl.surface,
            wayland.surface.rq{ .commit = .{} },
        ) catch log.err("unrecoverable Wayland Connection Error", .{});
    }

    fn toplevelConfigure(
        self: *Window,
        object: u32,
        opcode: xdg_shell.toplevel.event,
        body: []const u8,
    ) void {
        std.debug.assert(opcode == .configure);
        std.debug.assert(object == self.role.xdg.toplevel);
        const event = deserialiseStruct(xdg_shell.toplevel.ev.configure, body);
        if (event.width != 0)
            self.size[0] = @intCast(event.width);
        if (event.height != 0)
            self.size[1] = @intCast(event.height);
        log.debug("Toplevel configure event received", .{});
        log.debug("new size width {} height {}", .{ self.size[0], self.size[1] });
    }
};

/// Bindings around posix memfd_create and mmap to manage a shared memory
/// buffer
pub const Buffer = struct {
    shm: std.posix.fd_t,
    pool: []align(std.mem.page_size) u8,
    pub fn init(size: usize) !Buffer {
        const shm = try createFile();
        errdefer std.posix.close(shm);
        const pool = try mapShm(shm, size);
        return .{ .shm = shm, .pool = pool };
    }

    pub fn deinit(self: *Buffer) void {
        if (self.pool.len > 0) std.posix.munmap(self.pool);
        std.posix.close(self.shm);
    }

    /// Create a unique file descriptor which can be used for shared memory
    fn createFile() !std.posix.fd_t {
        const tmpfilebase = "way2-buffer";
        const tmpfileext_len = 2 + 2 * @sizeOf(i32) + 2 * @sizeOf(i64);
        var buf: [tmpfilebase.len + tmpfileext_len]u8 = undefined;
        if ("memfd:".len + buf.len + 1 > std.posix.NAME_MAX) {
            @compileError("std.posix.NAME_MAX is not large enough to store tempfile");
        }
        // Use the process ID as well as the microsecond timestamp to
        // distinguish files. If somehow you manage to have two threads run
        // this function within the same microsecond, one will likely fail and
        // I don't care
        const filename = std.fmt.bufPrint(&buf, "{s}-{X}-{X}", .{
            tmpfilebase,
            @as(i32, @intCast(switch (builtin.os.tag) {
                .linux => std.os.linux.getpid(),
                .plan9 => std.os.plan9.getpid(),
                .windows => std.os.windows.GetCurrentProcessId(),
                else => if (builtin.link_libc) std.c.getpid() else 0,
            })),
            std.time.microTimestamp(),
        }) catch unreachable;
        return std.posix.memfd_create(filename, 0) catch |err| switch (err) {
            error.SystemFdQuotaExceeded,
            error.ProcessFdQuotaExceeded,
            => |e| return e,
            error.OutOfMemory,
            => @panic("Out of memory"),
            error.Unexpected,
            => @panic("Unexpected error"),
            error.NameTooLong,
            error.SystemOutdated,
            => unreachable,
        };
    }

    /// Resize and memory map a file descriptor for shared memory
    fn mapShm(shm: std.posix.fd_t, size: usize) ![]align(std.mem.page_size) u8 {
        std.debug.assert(size != 0);
        std.posix.ftruncate(shm, size) catch |err| switch (err) {
            error.InputOutput,
            => |e| {
                log.warn("IO error {}", .{e});
                return e;
            },
            error.FileTooBig,
            => @panic("Unable to create memory mapped file for buffer due to filesystem"),
            error.Unexpected,
            => @panic("Unexpected Error"),
            error.FileBusy,
            error.AccessDenied,
            => unreachable,
        };
        return std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            shm,
            0,
        ) catch |err| switch (err) {
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            => |e| return e,
            error.LockedMemoryLimitExceeded,
            error.OutOfMemory,
            => @panic("Out of memory"),
            error.MemoryMappingNotSupported,
            => @panic("Unable to create memory mapped file for buffer due to filesystem"),
            error.Unexpected,
            => @panic("Unexpected error"),
            error.AccessDenied,
            error.PermissionDenied,
            => unreachable,
        };
    }

    pub fn resize(self: *Buffer, size: usize) !void {
        std.posix.munmap(self.pool);
        self.pool = mapShm(self.shm, size) catch |err| switch (err) {
            error.InputOutput,
            => |e| return e,
            error.SystemFdQuotaExceeded,
            error.ProcessFdQuotaExceeded,
            => unreachable,
        };
    }
};

/// Manages an event queue and related input devices
pub const Seat = struct {
    allocator: std.mem.Allocator,
    client: *Client,
    seat: u32,
    keyboard: u32,
    pointer: u32,
    touch: u32,
    queue: std.DoublyLinkedList(Event),

    pub const Event = union(enum) {
        focus: struct {
            type: enum { keyboard, pointer, touch },
            event: enum { enter, leave },
        },
        key: struct {
            key: u32,
            state: wayland.keyboard.KeyState,
        },
        modifier: struct {
            depressed: u32,
            latched: u32,
            locked: u32,
            group: u32,
        },
        mouse_motion: struct {
            x: f64,
            y: f64,
        },
        close: struct {
            window: *Window,
        },
    };

    pub fn init(client: *Client) Seat {
        return .{
            .allocator = client.allocator,
            .client = client,
            .seat = 0,
            .keyboard = 0,
            .pointer = 0,
            .touch = 0,
            .queue = std.DoublyLinkedList(Event){},
        };
    }
    pub fn setup(self: *Seat) !void {
        self.seat = self.client.bind(.wl_seat);
        errdefer self.client.invalidate(self.seat);
        log.debug("binding wl_seat [{d}]", .{self.seat});
        const seat = self.client.globals.objects.get("wl_seat") orelse {
            return error.UnsupportedCompositor;
        };
        if (seat.version < 9) {
            return error.UnsupportedCompositor;
        }
        try self.client.send(
            Client.wl_registry,
            wayland.registry.rq{ .bind = .{
                .id = self.seat,
                .name = seat.name,
                .version = seat.version,
                .interface = seat.string,
            } },
        );
        errdefer {
            self.client.send(
                self.seat,
                wayland.seat.rq{ .release = .{} },
            ) catch |err| {
                log.err("Error received while cleaning up {}", .{err});
            };
        }
        self.client.setHandler(self.seat, .wl_seat, .capabilities, self, register);
    }

    pub fn poll(self: *Seat) ?Event {
        const node = self.queue.popFirst() orelse return null;
        defer self.allocator.destroy(node);
        return node.data;
    }

    fn register(
        self: *Seat,
        object: u32,
        opcode: wayland.seat.event,
        body: []const u8,
    ) void {
        std.debug.assert(object == self.seat);
        std.debug.assert(opcode == .capabilities);
        const event = deserialiseStruct(wayland.seat.ev.capabilities, body);
        log.debug(
            "seat capabilities found [keyboard {}] [pointer {}] [touch {}]",
            .{ event.capabilities.keyboard, event.capabilities.pointer, event.capabilities.touch },
        );
        if (self.keyboard == 0 and event.capabilities.keyboard) self.addKeyboard() catch {
            log.err("unrecoverable Wayland Connection Error", .{});
        };
        if (self.keyboard != 0 and !event.capabilities.keyboard) self.remKeyboard() catch {
            log.err("unrecoverable Wayland Connection Error", .{});
        };
        if (self.pointer == 0 and event.capabilities.pointer) self.addPointer() catch {
            log.err("unrecoverable Wayland Connection Error", .{});
        };
        if (self.pointer != 0 and !event.capabilities.pointer) self.remPointer() catch {
            log.err("unrecoverable Wayland Connection Error", .{});
        };
        if (self.touch == 0 and event.capabilities.touch) self.addTouch() catch {
            log.err("unrecoverable Wayland Connection Error", .{});
        };
        if (self.touch != 0 and !event.capabilities.touch) self.remTouch() catch {
            log.err("unrecoverable Wayland Connection Error", .{});
        };
    }

    fn addKeyboard(self: *Seat) !void {
        std.debug.assert(self.keyboard == 0);
        self.keyboard = self.client.bind(.wl_keyboard);
        errdefer {
            self.client.invalidate(self.keyboard);
            self.keyboard = 0;
        }
        try self.client.send(self.seat, wayland.seat.rq{
            .get_keyboard = .{ .id = self.keyboard },
        });
        //self.client.setHandler(self.keyboard, .wl_keyboard, .keymap, self, setKeymap);
        self.client.setHandler(self.keyboard, .wl_keyboard, .enter, self, kbdEvent);
        self.client.setHandler(self.keyboard, .wl_keyboard, .leave, self, kbdEvent);
        self.client.setHandler(self.keyboard, .wl_keyboard, .key, self, kbdEvent);
        self.client.setHandler(self.keyboard, .wl_keyboard, .modifiers, self, kbdEvent);
        self.client.setHandler(self.keyboard, .wl_keyboard, .repeat_info, self, kbdEvent);
    }

    fn remKeyboard(self: *Seat) !void {
        _ = &self;
    }

    fn addPointer(self: *Seat) !void {
        _ = &self;
    }

    fn remPointer(self: *Seat) !void {
        _ = &self;
    }

    fn addTouch(self: *Seat) !void {
        _ = &self;
    }

    fn remTouch(self: *Seat) !void {
        _ = &self;
    }

    fn kbdEvent(
        self: *Seat,
        object: u32,
        opcode: wayland.keyboard.event,
        body: []const u8,
    ) void {
        std.debug.assert(object == self.keyboard);
        const node = self.allocator.create(@TypeOf(self.queue).Node) catch @panic("Out of memory");
        switch (opcode) {
            .key => {
                const event = deserialiseStruct(wayland.keyboard.ev.key, body);
                node.data = .{ .key = .{
                    .key = event.key,
                    .state = event.state,
                } };
            },
            .keymap => unreachable,
            else => {
                log.info("keyboard {s}", .{@tagName(opcode)});
            },
        }
        self.queue.append(node);
    }
};

/// Create a Cmsg type to pass the given type as auxillary data for a unix socket message
fn Cmsg(comptime T: type) type {
    const padding_size = (@sizeOf(T) + @sizeOf(c_long) - 1) / @sizeOf(c_long) * @sizeOf(c_long);
    return extern struct {
        len: c_ulong = @sizeOf(@This()) - padding_size,
        level: c_int,
        type: c_int,
        data: T,
        _padding: [padding_size]u8 align(1) = [_]u8{0} ** padding_size,
    };
}

/// Serialises a struct into a buffer
fn serialiseStruct(allocator: std.mem.Allocator, payload: anytype) []u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    const writer = buffer.writer();
    inline for (std.meta.fields(@TypeOf(payload))) |field| {
        const component = @field(payload, field.name);
        switch (field.type) {
            wl.types.String => {
                const length = component.len + 1;
                const padding = (length + 3) / 4 * 4 - length;
                writer.writeInt(u32, @intCast(length), endian) catch @panic("Out of memory");
                writer.writeAll(std.mem.sliceAsBytes(component)) catch @panic("Out of memory");
                writer.writeByte(0) catch @panic("Out of memory");
                writer.writeByteNTimes(0, padding) catch @panic("Out of memory");
            },
            wl.types.Array => {
                writer.writeInt(u32, @intCast(component.len * 4), endian) catch @panic("Out of memory");
                writer.writeAll(std.mem.sliceAsBytes(component)) catch @panic("Out of memory");
            },
            i32, u32 => |T| {
                writer.writeInt(T, component, endian) catch @panic("Out of memory");
            },
            f64 => {
                const fixed: i32 = @intFromFloat(component * 256.0);
                writer.writeInt(@TypeOf(fixed), fixed, endian) catch @panic("Out of memory");
            },
            else => |T| {
                if (@bitSizeOf(T) != 32) {
                    @compileError("Cannot serialise unknown type " ++ @typeName(T));
                }
                writer.writeInt(u32, switch (@typeInfo(T)) {
                    .@"enum" => @intFromEnum(component),
                    .@"struct" => @bitCast(component),
                    else => @compileError("Cannot serialise unknown type " ++ @typeName(T)),
                }, endian) catch @panic("Out of memory");
            },
        }
    }
    return buffer.toOwnedSlice() catch @panic("Out of memory");
}

/// Deserialises a buffer into the provided type
fn deserialiseStruct(ResultType: type, buffer: []const u8) ResultType {
    var stream = std.io.fixedBufferStream(buffer);
    const reader = stream.reader();
    var args: ResultType = undefined;
    inline for (std.meta.fields(ResultType)) |field| {
        const component = &@field(args, field.name);
        switch (field.type) {
            wl.types.String => {
                const length = reader.readInt(u32, endian) catch unreachable;
                const padding = (length + 3) / 4 * 4 - length;
                component.len = length - 1; // account for null terminator
                component.ptr = stream.buffer[stream.pos..].ptr;
                stream.pos += length;
                stream.pos += padding;
                if (stream.pos > stream.buffer.len) @panic("Invalid message received");
            },
            wl.types.Array => {
                const length = reader.readInt(u32, endian) catch unreachable;
                component.* = @alignCast(std.mem.bytesAsSlice(
                    u32,
                    stream.buffer[stream.pos .. stream.pos + length],
                ));
                stream.pos += length;
                if (stream.pos > stream.buffer.len) @panic("Invalid message received");
            },
            i32, u32 => |T| component.* = reader.readInt(T, endian) catch unreachable,
            f64 => component.* = @as(f64, @floatFromInt(
                reader.readInt(i32, endian) catch unreachable,
            )) / 256.0,
            else => |T| {
                if (@bitSizeOf(T) != 32) {
                    @compileError("Cannot deserialise unknown type " ++ @typeName(T));
                }
                const bytes = reader.readInt(u32, endian) catch @panic("Out of memory");
                component.* = switch (@typeInfo(T)) {
                    .@"enum" => @enumFromInt(bytes),
                    .@"struct" => @bitCast(bytes),
                    else => @compileError("Cannot deserialise unknown type " ++ @typeName(T)),
                };
            },
        }
    }
    std.debug.assert(stream.pos == stream.buffer.len);
    return args;
}
