const std = @import("std");
const zstbi = @import("zstbi");
const pixi = @import("root");

const Packer = @This();

pub const Image = struct {
    width: usize,
    height: usize,
    pixels: [][4]u8,

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub const Sprite = struct {
    name: [:0]const u8,
    diffuse_image: Image,
    heightmap_image: ?Image = null,
    origin: [2]i32,

    pub fn deinit(self: *Sprite, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.diffuse_image.deinit(allocator);
        if (self.heightmap_image) |*image| {
            image.deinit(allocator);
        }
    }
};

frames: std.ArrayList(zstbi.Rect),
sprites: std.ArrayList(Sprite),
animations: std.ArrayList(pixi.storage.External.Animation),
id_counter: u32 = 0,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Packer {
    return .{
        .sprites = std.ArrayList(Sprite).init(allocator),
        .frames = std.ArrayList(zstbi.Rect).init(allocator),
        .animations = std.ArrayList(pixi.storage.External.Animation).init(allocator),
        .allocator = allocator,
    };
}

pub fn id(self: *Packer) u32 {
    const i = self.id_counter;
    self.id_counter += 1;
    return i;
}

pub fn deinit(self: *Packer) void {
    self.clearAndFree();
    self.sprites.deinit();
    self.frames.deinit();
    self.animations.deinit();
}

pub fn clearAndFree(self: *Packer) void {
    for (self.sprites) |*sprite| {
        sprite.deinit(self.allocator);
    }
    self.frames.clearAndFree();
    self.sprites.clearAndFree();
    self.animations.clearAndFree();
}

pub fn append(self: *Packer, file: *pixi.storage.Internal.Pixi) !void {
    for (file.layers.items, 0..) |*layer, layer_index| {
        _ = layer_index;
        const layer_width = @as(usize, @intCast(layer.texture.image.width));
        for (file.sprites.items, 0..) |sprite, sprite_index| {
            const tiles_wide = @divExact(file.width, file.tile_width);

            const column = @mod(@as(u32, @intCast(sprite_index)), tiles_wide);
            const row = @divTrunc(@as(u32, @intCast(sprite_index)), tiles_wide);

            const src_x = column * file.tile_width;
            const src_y = row * file.tile_height;

            const src_rect: [4]usize = .{ @as(usize, @intCast(src_x)), @as(usize, @intCast(src_y)), @as(usize, @intCast(file.tile_width)), @as(usize, @intCast(file.tile_height)) };

            if (reduce(layer, src_rect)) |reduced_rect| {
                const reduced_src_x = reduced_rect[0];
                const reduced_src_y = reduced_rect[1];
                const reduced_src_width = reduced_rect[2];
                const reduced_src_height = reduced_rect[3];

                const offset = .{ reduced_src_x - src_x, reduced_src_y - src_y };
                const src_pixels = @as([*][4]u8, @ptrCast(layer.texture.image.data.ptr))[0 .. layer.texture.image.data.len / 4];

                // Allocate pixels for reduced image
                var image: Image = .{
                    .width = reduced_src_width,
                    .height = reduced_src_height,
                    .pixels = try pixi.state.allocator.alloc([4]u8, reduced_src_width * reduced_src_height),
                };

                // Copy pixels to image
                {
                    var y: usize = reduced_src_y;
                    while (y < reduced_src_y + reduced_src_height) : (y += 1) {
                        const start = reduced_src_x + y * layer_width;
                        const src = src_pixels[start .. start + reduced_src_width];
                        const dst = image.pixels[(y - reduced_src_y) * image.width .. (y - reduced_src_y) * image.width + image.width];
                        @memcpy(dst, src);
                    }
                }

                try self.sprites.append(.{
                    .name = try std.fmt.allocPrintZ(self.allocator, "{s}_{s}", .{ sprite.name, layer.name }),
                    .diffuse_image = image,
                    .origin = .{ @as(i32, @intFromFloat(sprite.origin_x)) - @as(i32, @intCast(offset[0])), @as(i32, @intFromFloat(sprite.origin_y)) - @as(i32, @intCast(offset[1])) },
                });

                try self.frames.append(.{ .id = self.id(), .w = @as(c_ushort, @intCast(image.width)), .h = @as(c_ushort, @intCast(image.height)) });
            }
        }
    }
    var test_image = self.sprites.items[0].diffuse_image;
    var test_texture: pixi.gfx.Texture = try pixi.gfx.Texture.createEmpty(pixi.state.gctx, @as(u32, @intCast(test_image.width)), @as(u32, @intCast(test_image.height)), .{});
    var test_image_pixels = @as([*]u8, @ptrCast(test_image.pixels.ptr))[0..test_texture.image.data.len];
    @memcpy(test_texture.image.data, test_image_pixels);
    test_texture.update(pixi.state.gctx);
    pixi.state.test_texture = test_texture;
}

pub fn packAndClear(self: *Packer) !void {
    if (try self.packRects()) |size| {
        var atlas_texture = try pixi.gfx.Texture.createEmpty(pixi.state.gctx, size[0], size[1], .{});

        for (self.frames.items, self.sprites.items) |frame, sprite| {
            atlas_texture.blit(sprite.diffuse_image.pixels, frame.slice());
        }
        atlas_texture.update(pixi.state.gctx);

        if (pixi.state.atlas) |*atlas| {
            atlas.diffusemap.deinit(pixi.state.gctx);
            atlas.diffusemap = atlas_texture;
        } else {
            pixi.state.atlas = .{
                .diffusemap = atlas_texture,
            };
        }
    }
}

/// Takes a layer and a src rect and reduces the rect removing all fully transparent pixels
/// If the src rect doesn't contain any opaque pixels, returns null
pub fn reduce(layer: *pixi.storage.Internal.Layer, src: [4]usize) ?[4]usize {
    const pixels = @as([*][4]u8, @ptrCast(layer.texture.image.data.ptr))[0 .. layer.texture.image.data.len / 4];
    const layer_width = @as(usize, @intCast(layer.texture.image.width));

    const src_x = src[0];
    const src_y = src[1];
    const src_width = src[2];
    const src_height = src[3];

    var top = src_y;
    var bottom = src_y + src_height - 1;
    var left = src_x;
    var right = src_x + src_width - 1;

    top: {
        while (top < bottom) : (top += 1) {
            const start = left + top * layer_width;
            const row = pixels[start .. start + src_width];
            for (row) |pixel| {
                if (pixel[3] != 0) {
                    // if (top > src_y)
                    //     top -= 1;
                    break :top;
                }
            }
        }
    }
    if (top == bottom) return null;

    bottom: {
        while (bottom > top) : (bottom -= 1) {
            const start = left + bottom * layer_width;
            const row = pixels[start .. start + src_width];
            for (row) |pixel| {
                if (pixel[3] != 0) {
                    if (bottom < src_y + src_height)
                        bottom += 1;
                    break :bottom;
                }
            }
        }
    }

    const height = bottom - top;
    if (height == 0)
        return null;

    left: {
        while (left < right) : (left += 1) {
            var y = bottom;
            while (y > top) : (y -= 1) {
                if (pixels[left + y * layer_width][3] != 0) {
                    // if (left > src_x)
                    //     left -= 1;
                    break :left;
                }
            }
        }
    }

    right: {
        while (right > left) : (right -= 1) {
            var y = bottom;
            while (y > top) : (y -= 1) {
                if (pixels[right + y * layer_width][3] != 0) {
                    if (right < src_x + src_width)
                        right += 1;
                    break :right;
                }
            }
        }
    }

    const width = right - left;
    if (width == 0)
        return null;

    return .{
        left,
        top,
        width,
        height,
    };
}

pub fn packRects(self: *Packer) !?[2]u16 {
    if (self.frames.items.len == 0) return null;

    var ctx: zstbi.Context = undefined;
    const node_count = 4096 * 2;
    var nodes: [node_count]zstbi.Node = undefined;

    const texture_sizes = [_][2]u32{
        [_]u32{ 256, 256 },   [_]u32{ 512, 256 },   [_]u32{ 256, 512 },
        [_]u32{ 512, 512 },   [_]u32{ 1024, 512 },  [_]u32{ 512, 1024 },
        [_]u32{ 1024, 1024 }, [_]u32{ 2048, 1024 }, [_]u32{ 1024, 2048 },
        [_]u32{ 2048, 2048 }, [_]u32{ 4096, 2048 }, [_]u32{ 2048, 4096 },
        [_]u32{ 4096, 4096 }, [_]u32{ 8192, 4096 }, [_]u32{ 4096, 8192 },
    };

    for (texture_sizes) |tex_size| {
        zstbi.initTarget(&ctx, tex_size[0], tex_size[1], &nodes);
        zstbi.setupHeuristic(&ctx, zstbi.Heuristic.skyline_bl_sort_height);
        if (zstbi.packRects(&ctx, self.frames.items) == 1) {
            return .{ @as(u16, @intCast(tex_size[0])), @as(u16, @intCast(tex_size[1])) };
        }
    }

    return null;
}
