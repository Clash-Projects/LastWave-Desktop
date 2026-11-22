// Glassmorphism backdrop in one pass: the playing cover stretched over the
// window, colour-graded, tinted toward the theme, shaded, vignetted, given a
// top-left sheen and dithered. One shader instead of stacked gradient layers:
// every stacked 8-bit layer rounds on its own, and those roundings add up to
// visible bands. Here the maths stays in float until the single final write.
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;        // canvas size, logical px
uniform float uSaturation; // 1 = unchanged
uniform float uDim;        // brightness multiplier
uniform vec3 uVeil;        // theme page colour (linear 0..1 sRGB values)
uniform float uTint;       // how much of the veil sits over the cover
uniform float uLight;      // 1 = Pearl (pale wash), 0 = dark themes
uniform float uSheen;      // white added at the top-left corner
uniform float uZoom;       // >1 crops past the soft edges
uniform sampler2D uImage;  // pre-blurred square cover texture

out vec4 fragColor;

float hash(vec2 p) {
  vec3 q = fract(vec3(p.xyx) * 0.1031);
  q += dot(q, q.yzx + 33.33);
  return fract((q.x + q.y) * q.z);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = frag / uSize;

  // Cover-fit a square texture, then zoom in.
  float aspect = uSize.x / uSize.y;
  vec2 fit = aspect > 1.0 ? vec2(1.0, 1.0 / aspect) : vec2(aspect, 1.0);
  vec2 suv = (uv - 0.5) * fit / uZoom + 0.5;
  vec3 c = texture(uImage, suv).rgb;

  float gray = dot(c, vec3(0.2126, 0.7152, 0.0722));
  c = mix(vec3(gray), c, uSaturation) * uDim;

  if (uLight > 0.5) {
    // Pearl: a pale tint of the cover under the page colour.
    c = mix(c, uVeil, 0.74);
  } else {
    c = mix(c, uVeil, uTint);
    // Darker toward the dock, and a soft vignette.
    c *= 1.0 - mix(0.06, 0.40, uv.y);
    c *= 1.0 - smoothstep(0.25, 0.95, length(uv - 0.5)) * 0.18;
  }

  float s = clamp(1.0 - (uv.x + uv.y) / 1.2, 0.0, 1.0);
  c = mix(c, vec3(1.0), uSheen * s * s);

  // ±1.5 levels of noise: enough to break 8-bit steps, too faint to see.
  c += (hash(frag) - 0.5) * (1.5 / 255.0);
  fragColor = vec4(clamp(c, 0.0, 1.0), 1.0);
}
