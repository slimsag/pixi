const std = @import("std");
const pixi = @import("pixi");
const zip = @import("zip");
const zstbi = @import("zstbi");
const zgpu = @import("zgpu");
const zgui = @import("zgui");

pub const Style = @import("style.zig");

pub const sidebar = @import("sidebar/sidebar.zig");
pub const explorer = @import("explorer/explorer.zig");
pub const artboard = @import("artboard/artboard.zig");

pub const popup_rename = @import("popups/rename.zig");
pub const popup_new_file = @import("popups/new_file.zig");

pub fn draw() void {
    sidebar.draw();
    explorer.draw();
    artboard.draw();

    popup_rename.draw();
    popup_new_file.draw();
}

pub fn setProjectFolder(path: [*:0]const u8) void {
    pixi.state.project_folder = path[0..std.mem.len(path) :0];
}

/// Returns true if a new file was created.
pub fn newFile(path: [:0]const u8) !bool {
    for (pixi.state.open_files.items) |file, i| {
        if (std.mem.eql(u8, file.path, path)) {
            // Free path since we aren't adding it to open files again.
            pixi.state.allocator.free(path);
            setActiveFile(i);
            return false;
        }
    }

    var internal: pixi.storage.Internal.Pixi = .{
        .path = path,
        .width = @intCast(u32, pixi.state.popups.new_file_tiles[0] * pixi.state.popups.new_file_tile_size[0]),
        .height = @intCast(u32, pixi.state.popups.new_file_tiles[1] * pixi.state.popups.new_file_tile_size[1]),
        .tile_width = @intCast(u32, pixi.state.popups.new_file_tile_size[0]),
        .tile_height = @intCast(u32, pixi.state.popups.new_file_tile_size[1]),
        .layers = std.ArrayList(pixi.storage.Internal.Layer).init(pixi.state.allocator),
        .sprites = std.ArrayList(pixi.storage.Internal.Sprite).init(pixi.state.allocator),
        .animations = std.ArrayList(pixi.storage.Internal.Animation).init(pixi.state.allocator),
        .flipbook_camera = .{ .position = .{ -@intToFloat(f32, pixi.state.popups.new_file_tile_size[0]) / 2.0, 0.0 } },
        .background_image = undefined,
        .background_image_data = undefined,
        .background_texture_handle = undefined,
        .background_texture_view_handle = undefined,
        .dirty = true,
    };

    try internal.createBackground(pixi.state.allocator);
    var layer = try internal.layers.addOne();

    const layer_texture = pixi.gfx.Texture.init(pixi.state.gctx, internal.width, internal.height, .{});

    layer.name = try std.fmt.allocPrintZ(pixi.state.allocator, "{s}", .{"Layer 0"});
    layer.texture_handle = layer_texture.handle;
    layer.texture_view_handle = layer_texture.view_handle;
    // TODO: Understand why this doesn't really work and `layer.image.data.ptr` is invalid
    layer.data = try std.heap.c_allocator.alloc(u8, internal.width * internal.height * 4);
    layer.image = pixi.gfx.createImage(layer.data, internal.width, internal.height);

    // Create sprites for all tiles.
    {
        const tiles = @intCast(usize, pixi.state.popups.new_file_tiles[0] * pixi.state.popups.new_file_tiles[1]);
        var i: usize = 0;
        while (i < tiles) : (i += 1) {
            var sprite: pixi.storage.Internal.Sprite = .{
                .name = zgui.formatZ("Sprite_{d}", .{i}),
                .index = i,
            };
            try internal.sprites.append(sprite);
        }
    }

    try pixi.state.open_files.insert(0, internal);
    pixi.editor.setActiveFile(0);

    return true;
}

/// Returns true if png was imported and new file created.
pub fn importPng(path: [:0]const u8) !bool {
    if (!std.mem.eql(u8, std.fs.path.extension(path[0..path.len]), ".png"))
        return false;

    var new_file_path = pixi.state.allocator.alloc(u8, path.len + 1) catch unreachable;
    _ = std.mem.replace(u8, path, ".png", ".pixi", new_file_path);

    std.log.debug("{s}", .{new_file_path});

    for (pixi.state.open_files.items) |file, i| {
        if (std.mem.eql(u8, file.path, new_file_path)) {
            // Free path since we aren't adding it to open files again.
            pixi.state.allocator.free(new_file_path);
            setActiveFile(i);
            return false;
        }
    }

    return true;
}

/// Returns true if a new file was opened.
pub fn openFile(path: [:0]const u8) !bool {
    if (!std.mem.eql(u8, std.fs.path.extension(path[0..path.len]), ".pixi"))
        return false;

    for (pixi.state.open_files.items) |file, i| {
        if (std.mem.eql(u8, file.path, path)) {
            // Free path since we aren't adding it to open files again.
            pixi.state.allocator.free(path);
            setActiveFile(i);
            return false;
        }
    }

    if (zip.zip_open(path.ptr, 0, 'r')) |pixi_file| {
        defer zip.zip_close(pixi_file);

        var buf: ?*anyopaque = null;
        var size: u64 = 0;
        _ = zip.zip_entry_open(pixi_file, "pixidata.json");
        _ = zip.zip_entry_read(pixi_file, &buf, &size);
        _ = zip.zip_entry_close(pixi_file);

        var content: []const u8 = @ptrCast([*]const u8, buf)[0..size];
        const options = std.json.ParseOptions{
            .allocator = pixi.state.allocator,
            .duplicate_field_behavior = .UseFirst,
            .ignore_unknown_fields = true,
            .allow_trailing_data = true,
        };

        var stream = std.json.TokenStream.init(content);
        const external = std.json.parse(pixi.storage.External.Pixi, &stream, options) catch unreachable;
        defer std.json.parseFree(pixi.storage.External.Pixi, external, options);

        var internal: pixi.storage.Internal.Pixi = .{
            .path = path,
            .width = external.width,
            .height = external.height,
            .tile_width = external.tileWidth,
            .tile_height = external.tileHeight,
            .layers = std.ArrayList(pixi.storage.Internal.Layer).init(pixi.state.allocator),
            .sprites = std.ArrayList(pixi.storage.Internal.Sprite).init(pixi.state.allocator),
            .animations = std.ArrayList(pixi.storage.Internal.Animation).init(pixi.state.allocator),
            .flipbook_camera = .{ .position = .{ -@intToFloat(f32, external.tileWidth) / 2.0, 0.0 } },
            .background_image = undefined,
            .background_image_data = undefined,
            .background_texture_handle = undefined,
            .background_texture_view_handle = undefined,
            .dirty = false,
        };

        try internal.createBackground(pixi.state.allocator);

        for (external.layers) |layer| {
            const layer_image_name = try std.fmt.allocPrintZ(pixi.state.allocator, "{s}.png", .{layer.name});
            defer pixi.state.allocator.free(layer_image_name);

            var img_buf: ?*anyopaque = null;
            var img_len: usize = 0;

            _ = zip.zip_entry_open(pixi_file, layer_image_name.ptr);
            _ = zip.zip_entry_read(pixi_file, &img_buf, &img_len);
            defer _ = zip.zip_entry_close(pixi_file);

            if (img_buf) |data| {
                var new_layer: pixi.storage.Internal.Layer = .{
                    .name = try pixi.state.allocator.dupeZ(u8, layer.name),
                    .texture_handle = undefined,
                    .texture_view_handle = undefined,
                    .image = undefined,
                    .data = undefined,
                };

                new_layer.texture_handle = pixi.state.gctx.createTexture(.{
                    .usage = .{ .texture_binding = true, .copy_dst = true },
                    .size = .{
                        .width = external.width,
                        .height = external.height,
                        .depth_or_array_layers = 1,
                    },
                    .format = zgpu.imageInfoToTextureFormat(4, 1, false),
                });

                new_layer.texture_view_handle = pixi.state.gctx.createTextureView(new_layer.texture_handle, .{});
                new_layer.data = try pixi.state.allocator.dupe(u8, @ptrCast([*]u8, data)[0..img_len]);
                new_layer.image = try zstbi.Image.initFromData(@ptrCast([*]u8, new_layer.data)[0..img_len], 4);

                pixi.state.gctx.queue.writeTexture(
                    .{ .texture = pixi.state.gctx.lookupResource(new_layer.texture_handle).? },
                    .{
                        .bytes_per_row = new_layer.image.bytes_per_row,
                        .rows_per_image = new_layer.image.height,
                    },
                    .{ .width = new_layer.image.width, .height = new_layer.image.height },
                    u8,
                    new_layer.image.data,
                );

                try internal.layers.append(new_layer);
            }
        }

        for (external.sprites) |sprite, i| {
            try internal.sprites.append(.{
                .name = try pixi.state.allocator.dupeZ(u8, sprite.name),
                .index = i,
                .origin_x = sprite.origin_x,
                .origin_y = sprite.origin_y,
            });
        }

        for (external.animations) |animation| {
            try internal.animations.append(.{
                .name = try pixi.state.allocator.dupeZ(u8, animation.name),
                .start = animation.start,
                .length = animation.length,
                .fps = animation.fps,
            });
        }

        try pixi.state.open_files.insert(0, internal);
        setActiveFile(0);
        return true;
    }

    pixi.state.allocator.free(path);
    return error.FailedToOpenFile;
}

pub fn setActiveFile(index: usize) void {
    if (index >= pixi.state.open_files.items.len) return;
    pixi.state.open_file_index = index;
}

pub fn getFileIndex(path: [:0]const u8) ?usize {
    for (pixi.state.open_files.items) |file, i| {
        if (std.mem.eql(u8, file.path, path))
            return i;
    }
    return null;
}

pub fn getFile(index: usize) ?*pixi.storage.Internal.Pixi {
    if (index >= pixi.state.open_files.items.len) return null;

    return &pixi.state.open_files.items[index];
}

pub fn closeFile(index: usize) !void {
    pixi.state.open_file_index = 0;
    var file = pixi.state.open_files.swapRemove(index);
    pixi.state.allocator.free(file.background_image_data);
    for (file.layers.items) |*layer| {
        pixi.state.gctx.releaseResource(layer.texture_handle);
        pixi.state.gctx.releaseResource(layer.texture_view_handle);
        pixi.state.gctx.releaseResource(file.background_texture_handle);
        pixi.state.gctx.releaseResource(file.background_texture_view_handle);
        pixi.state.allocator.free(layer.name);
        layer.image.deinit();
        pixi.state.allocator.free(layer.data);
    }
    for (file.sprites.items) |*sprite| {
        pixi.state.allocator.free(sprite.name);
    }
    for (file.animations.items) |*animation| {
        pixi.state.allocator.free(animation.name);
    }
    file.layers.deinit();
    file.sprites.deinit();
    file.animations.deinit();
    pixi.state.allocator.free(file.path);
}

pub fn deinit() void {
    for (pixi.state.open_files.items) |_| {
        try closeFile(0);
    }
    pixi.state.open_files.deinit();
}
