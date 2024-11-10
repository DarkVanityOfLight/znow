const std = @import("std");
const mem = std.mem;
const posix = std.posix;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;

const flakes = @import("flakes/flake.zig");
const snow = @import("snow.zig");

// zig fmt: off
const Context = struct { 
    shm: ?*wl.Shm,
    compositor: ?*wl.Compositor,
    layer_shell: ?*zwlr.LayerShellV1,
    outputs: std.ArrayList(*OutputInfo),
    alloc: std.mem.Allocator,
    running: *bool,
    display: *wl.Display,
};

const OutputInfo = struct {
    output: ?*wl.Output,
    pHeight: i32,
    pWidth: i32,
    name: []const u8,
    uname: u32,
    state: *State,
};

// zig fmt: on

const DoubleBuffer = struct {
    buffer1: *wl.Buffer,
    buffer2: *wl.Buffer,
    i: bool,
    memory1: []u32,
    memory2: []u32,
    fd: i32,
    total_size: u64,
    name: []u8,
    alloc: std.mem.Allocator,

    // FIXME: Check that width height are valid
    fn init(width: u32, height: u32, name: []const u8, shm: *wl.Shm, alloc: std.mem.Allocator) !*DoubleBuffer {
        // std.debug.print("{}x{}\n", .{ width, height });
        const stride: u64 = width * 4;
        const size = stride * height * 2;
        const fd = try posix.memfd_create(name, 0);
        try posix.ftruncate(fd, size);

        const data = blk: {
            const raw = try posix.mmap(
                null,
                @intCast(size),
                posix.PROT.READ | posix.PROT.WRITE,
                .{ .TYPE = .SHARED },
                fd,
                0,
            );
            break :blk std.mem.bytesAsSlice(u32, raw);
        };

        const pool = try shm.createPool(fd, @intCast(size));

        const buffer1 = try pool.createBuffer(0, @intCast(width), @intCast(height), @intCast(stride), wl.Shm.Format.argb8888);
        const buffer2 = try pool.createBuffer(@intCast(size / 2), @intCast(width), @intCast(height), @intCast(stride), wl.Shm.Format.argb8888);
        pool.destroy();

        var bufferName = try alloc.alloc(u8, name.len + "waysnow_".len);
        @memcpy(bufferName[0.."waysnow_".len], "waysnow_");
        @memcpy(bufferName["waysnow_".len .. "waysnow_".len + name.len], name);

        const db = try alloc.create(DoubleBuffer);

        // zig fmt: off
        db.* = DoubleBuffer{ 
            .buffer1 = buffer1,
            .buffer2 = buffer2,
            .memory1 = data[0..(size/(2 * 4))],
            .memory2 = data[(size / (2 * 4)) .. size / 4],
            .i = true,
            .fd = fd,
            .total_size = size,
            .alloc = alloc,
            .name = bufferName
        };
        // zig fmt: on
        return db;
    }

    fn current(self: *DoubleBuffer) *wl.Buffer {
        return if (self.i) {
            return self.buffer1;
        } else {
            return self.buffer2;
        };
    }

    fn next(self: *DoubleBuffer) *wl.Buffer {
        defer self.i = !self.i;
        return if (self.i) {
            return self.buffer1;
        } else {
            return self.buffer2;
        };
    }

    fn mem(self: *DoubleBuffer) []u32 {
        return if (self.i) {
            return self.memory1;
        } else {
            return self.memory2;
        };
    }

    fn deinit(self: *DoubleBuffer) void {
        self.buffer1.destroy();
        self.buffer2.destroy();
        // TODO: Is this required?
        const memory: []const u32 = self.memory1.ptr[0 .. self.memory1.len + self.memory2.len];
        const u8mem: []align(4096) const u8 = @alignCast(std.mem.bytesAsSlice(u8, memory));

        std.posix.munmap(u8mem);
        posix.close(self.fd);

        self.alloc.free(self.name);
        self.alloc.destroy(self);
    }
};

// zig fmt: off
const State = struct { 
    doubleBuffer: *DoubleBuffer,
    surface: *wl.Surface,
    flakes: snow.FlakeArray,
    alloc: std.mem.Allocator,
    missing_flakes: u32,
    running: *const bool,
    //callBackFunction: fn(cb: *wl.Callback, event: wl.Callback.Event, state: *State) void

    fn deinit(self: *State) void{
        self.doubleBuffer.destroy();
        self.flakes.deinit();
    }
};
// zig fmt: on

fn manageOutput(alloc: std.mem.Allocator, output: *const OutputInfo, context: *Context) !*State {
    const shm = context.shm orelse return error.NoWlShm;
    const compositor = context.compositor orelse return error.NoWlCompositor;
    const layer_shell = context.layer_shell orelse return error.NoLayerShell;

    var doubleBuffer = try DoubleBuffer.init(@intCast(output.pWidth), @intCast(output.pHeight), output.name, shm, alloc);
    @memset(doubleBuffer.mem(), 0x00000000);
    _ = doubleBuffer.next();
    @memset(doubleBuffer.mem(), 0x00000000);
    _ = doubleBuffer.next();

    const surface = try compositor.createSurface();
    surface.commit();

    // Make a layer surface
    const layer_surface: *zwlr.LayerSurfaceV1 = try layer_shell.getLayerSurface(surface, output.output, zwlr.LayerShellV1.Layer.bottom, "waysnow");
    layer_surface.setSize(1920, 1080);

    const running = try alloc.create(bool);
    running.* = true;

    // Listen for configure and kill calls
    layer_surface.setListener(*bool, layerSurfaceListener, running);
    surface.commit();
    if (context.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    // Need to attach buffer once to receive frame callbacks
    surface.attach(doubleBuffer.next(), 0, 0);

    // Init rendering via frame callback
    // zig fmt: off
    const state = try alloc.create(State);
    state.* = State{ 
        .doubleBuffer = doubleBuffer,
        .surface = surface,
        .flakes = try std.ArrayList(*flakes.Flake).initCapacity(alloc, 100),
        .alloc = alloc,
        .missing_flakes = 100,
        .running = running,
    };
    // zig fmt: on

    // This callback exists once after that it will get destroyed and another starts
    const callback = try surface.frame();
    callback.setListener(*State, frameCallback, state);

    surface.commit();

    return state;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    const display = try wl.Display.connect(null);
    const registry = try display.getRegistry();

    var running = true;

    // zig fmt: off
    var context = Context{ 
        .shm = null,
        .compositor = null,
        .layer_shell = null,
        // .outputs = &outputs,
        .alloc = alloc,
        .running = &running,
        .display = display,
        .outputs = try std.ArrayList(*OutputInfo).initCapacity(alloc, 5)
        };
    // zig fmt: on

    registry.setListener(*Context, registryListener, &context);

    // Blocking roundtrip call to get context
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    // Keep running
    while (running) {
        if (display.dispatch() != .SUCCESS) return error.Dispatchfailed;
    }

    running = true;
    if (display.dispatch() != .SUCCESS) return error.Dispatchfailed;

    _ = gpa.detectLeaks();
}

/// Listen to the registry events, to update collect what we need
fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *Context) void {
    // zig fmt: off
    switch (event) {
        .global => |global| {
            if (mem.orderZ(u8, global.interface, wl.Compositor.getInterface().name) == .eq) {
                context.compositor = registry.bind(global.name, wl.Compositor, 6) catch return;

            } else if (mem.orderZ(u8, global.interface, wl.Shm.getInterface().name) == .eq) {
                context.shm = registry.bind(global.name, wl.Shm, 1) catch return;

            } else if (mem.orderZ(u8, global.interface, zwlr.LayerShellV1.getInterface().name) == .eq) {
                context.layer_shell = registry.bind(global.name, zwlr.LayerShellV1, 4) catch return;

            } else if (mem.orderZ(u8, global.interface, wl.Output.getInterface().name) == .eq){
                const output : *wl.Output = registry.bind(global.name, wl.Output, 4) catch return;
                
                const output_info: *OutputInfo = context.alloc.create(OutputInfo) catch return;
                output_info.* = OutputInfo{
                    .output = output,
                    .pWidth = undefined,
                    .pHeight = undefined,
                    .name = undefined,
                    .uname = global.name,
                    .state = undefined,
                };
                

                output.setListener(*Context, outputListener, context);
                context.outputs.append(output_info) catch return;
            }
        },
        .global_remove => |global_remove|{
            std.debug.print("Deregistering output: {}\n", .{global_remove.name});
        },
    }
}

/// Listen to events of our layer surface
fn layerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, running: *bool) void {
    switch (event) {
        .configure => |configure| {
            layer_surface.setSize(1920, 1080);
            layer_surface.setAnchor(.{ .bottom = true, .left = true });
            layer_surface.ackConfigure(configure.serial);
        },

        .closed => {
            running.* = false;
        }

    }

}

fn outputListener(output: *wl.Output, event: wl.Output.Event, context: *Context) void {

    var outputInfo: *OutputInfo = undefined;
    for (context.outputs.items) |outputInfoIterated| {
        if (outputInfoIterated.output == output) {
            outputInfo = outputInfoIterated;
        }
    }

    if (outputInfo == undefined) { 
        std.debug.print("Received unmanaged output\n", .{});
        return;
    }

    // FIXME: Leaking alot of memory here
    switch (event) {
        .geometry => |geometry| {
            _ = geometry;
        },
        .mode => |geometry| {
            outputInfo.pHeight = geometry.height;
            outputInfo.pWidth = geometry.width;
        },

        .name => |name|{
            const n = context.alloc.alloc(u8, std.mem.len(name.name)) catch return;
            @memcpy(n, name.name);
            outputInfo.name = n;
        },

        .done => {
            if (!std.mem.eql(u8, outputInfo.name, undefined) and outputInfo.pWidth != undefined and outputInfo.pHeight != undefined and outputInfo.state != undefined){ 
                const state = manageOutput(context.alloc, outputInfo, context)
                    catch {std.debug.print("Failed to manage output\n", .{}); return;};
                outputInfo.state = state;
            }
        },

        else => {},
    }



}


fn frameCallback(cb: *wl.Callback, event: wl.Callback.Event, state: *State) void{
    switch(event){
        .done => {
            if(state.running.*){
                cb.destroy();

                // Do I own this now??
                const cbN = state.surface.frame() catch return;
                cbN.setListener(*State, frameCallback, state);

                const buffer = state.doubleBuffer.current();

                state.surface.attach(buffer, 0, 0);
                state.surface.damage(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
                state.surface.commit();

                // Get the next buffer to work on
                _ = state.doubleBuffer.next();

                const missing = snow.updateFlakes(&state.flakes, state.alloc) catch 0;
                const render_init_flakes = state.missing_flakes + missing;
                const missing_flakes = snow.spawnNewFlakes(&state.flakes, state.alloc, render_init_flakes) catch 0;
                state.missing_flakes = missing_flakes;
                snow.renderFlakes(&state.flakes, state.doubleBuffer.mem()) catch return;
            }
        }
    }
}
