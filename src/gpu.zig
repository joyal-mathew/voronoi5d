const voronoi = @import("voronoi.zig");
const rl = @import("c.zig").rl;

const cast = voronoi.cast;

const GlHandle = u32;

pub const Voronoi = struct {
    const SHADER_CODE = @embedFile("shader");

    const SRC_TEXTURE_INDEX = 0;
    const DST_TEXTURE_INDEX = 1;
    const SHADER_BUFFER_INDEX = 2;
    const INIT_CENTROID_CAP = 16;

    src_texture: rl.Texture,
    dst_texture: rl.Texture,
    centroid_cap: u32,
    ssbo: GlHandle,
    shader: GlHandle,
    program: GlHandle,
    count: GlHandle,

    fn check_gl(id: anytype) void {
        if (id == 0)
            @panic("OpenGL Error");
    }

    pub fn init(image: rl.Image) !Voronoi {
        const src_texture = rl.LoadTextureFromImage(image);
        check_gl(src_texture.id);
        const dst_texture: rl.Texture2D = .{
            .id = rl.rlLoadTexture(null, src_texture.width, src_texture.height, src_texture.format, src_texture.mipmaps),
            .width = src_texture.width,
            .height = src_texture.height,
            .mipmaps = src_texture.mipmaps,
            .format = src_texture.format,
        };
        check_gl(dst_texture.id);

        rl.rlBindImageTexture(src_texture.id, SRC_TEXTURE_INDEX, src_texture.format, true);
        rl.rlBindImageTexture(dst_texture.id, DST_TEXTURE_INDEX, dst_texture.format, false);

        const ssbo = rl.rlLoadShaderBuffer(@intCast(INIT_CENTROID_CAP * @sizeOf(voronoi.Centroid)), null, rl.RL_DYNAMIC_DRAW);
        check_gl(ssbo);
        rl.rlBindShaderBuffer(ssbo, SHADER_BUFFER_INDEX);

        const shader = rl.rlCompileShader(SHADER_CODE, rl.RL_COMPUTE_SHADER);
        check_gl(shader);
        const program = rl.rlLoadComputeShaderProgram(shader);
        check_gl(program);

        const count = rl.rlGetLocationUniform(program, "count");
        check_gl(count);

        return .{
            .src_texture = src_texture,
            .dst_texture = dst_texture,
            .centroid_cap = INIT_CENTROID_CAP,
            .ssbo = ssbo,
            .shader = shader,
            .program = program,
            .count = @bitCast(count),
        };
    }

    pub fn update(self: *Voronoi, centroids: []voronoi.Centroid) void {
        if (centroids.len > self.centroid_cap)
            @panic("TODO");

        const len: u32 = @intCast(centroids.len);

        rl.rlUpdateShaderBuffer(self.ssbo, centroids.ptr, @intCast(len * @sizeOf(voronoi.Centroid)), 0);
        rl.rlEnableShader(self.program);
        rl.rlSetUniform(@bitCast(self.count), &len, rl.RL_SHADER_UNIFORM_UINT, 1);
        rl.rlComputeShaderDispatch(@intCast(@divTrunc(self.src_texture.width + 15, 16)), @intCast(@divTrunc(self.src_texture.height + 15, 16)), 1);
        rl.glMemoryBarrier(rl.GL_SHADER_IMAGE_ACCESS_BARRIER_BIT | rl.GL_BUFFER_UPDATE_BARRIER_BIT);
    }

    pub fn getTexture(self: Voronoi) rl.Texture2D {
        return self.dst_texture;
    }

    pub fn deinit(self: Voronoi) void {
        rl.rlUnloadTexture(self.src_texture.id);
        rl.rlUnloadTexture(self.dst_texture.id);
        rl.rlUnloadShaderBuffer(self.ssbo);
        rl.rlUnloadShaderProgram(self.shader);
        rl.rlUnloadShaderProgram(self.program);
    }
};
