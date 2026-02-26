#version 430 core

layout(local_size_x = 16, local_size_y = 16) in;

layout(rgba32f, binding = 0) readonly uniform image2D src_image;
layout(rgba32f, binding = 1) writeonly uniform image2D dst_image;

layout(std430, binding = 2) readonly buffer Centroids {
    float data[];
} centroids;

uniform uint count;

void main() {
    ivec2 coords = ivec2(gl_GlobalInvocationID.xy);
    ivec2 dim = imageSize(src_image);

    if (coords.x >= dim.x || coords.y >= dim.y)
        return;

    vec2 coords_norm = vec2(coords) / vec2(dim);
    vec4 pixel = imageLoad(src_image, coords);

    vec4 best_pixel = vec4(0, 0, 0, 0);
    float best_dist_sq = 10;

    for (uint c = 0; c < 2 * count; c += 2) {
        float cx = centroids.data[c + 0];
        float cy = centroids.data[c + 1];
        ivec2 c_coords = ivec2(vec2(cx, cy) * dim);
        vec4 src_pixel = imageLoad(src_image, c_coords);
        float dx = coords_norm.x - cx;
        float dy = coords_norm.y - cy;
        float dr = pixel.r - src_pixel.r;
        float dg = pixel.g - src_pixel.g;
        float db = pixel.b - src_pixel.b;

        float dist_sq = dx * dx + dy * dy + dr * dr + dg * dg + db * db;

        if (dist_sq < best_dist_sq) {
            best_dist_sq = dist_sq;
            best_pixel = src_pixel;
        }
    }

    imageStore(dst_image, coords, best_pixel);
}
