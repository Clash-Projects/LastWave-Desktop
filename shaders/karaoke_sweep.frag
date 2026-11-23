#include <flutter/runtime_effect.glsl>

// Uniform float index map (ALL spatial values MUST be in physical pixels = logical * dpr):
// 0, 1 : uOrigin   (vec2)  - quad top-left in physical px
// 2, 3 : uSize     (vec2)  - quad width, height in physical px
// 4    : uSweepX   (float) - current sweep X relative to uOrigin.x in physical px
// 5    : uActiveRow(float) - active wrapped row index (0.0, 1.0, 2.0...)
// 6    : uRowHeight(float) - height of 1 wrapped text row in physical px
// 7    : uFeather  (float) - soft sweep edge width in physical px (e.g. 24.0 * dpr)
// 8    : uDimAlpha (float) - unsung text alpha (e.g. 0.35)
// 9    : uEdgeFade (float) - viewport top/bottom edge fade multiplier (0.0..1.0)
// Sampler 0 : uTextImg     - pre-baked sharp white ui.Image of the line

uniform vec2 uOrigin;
uniform vec2 uSize;
uniform float uSweepX;
uniform float uActiveRow;
uniform float uRowHeight;
uniform float uFeather;
uniform float uDimAlpha;
uniform float uEdgeFade;
uniform sampler2D uTextImg;

out vec4 fragColor;

void main() {
  vec2 local = FlutterFragCoord().xy - uOrigin;
  vec2 uv = clamp(local / max(uSize, vec2(1.0)), 0.0, 1.0);
  vec4 tex = texture(uTextImg, uv);

  float row = floor(max(local.y, 0.0) / max(uRowHeight, 1.0));
  float lit = 0.0;

  if (row < uActiveRow) {
    lit = 1.0;
  } else if (row == uActiveRow) {
    lit = 1.0 - smoothstep(uSweepX - uFeather, uSweepX + uFeather, local.x);
  }

  float alpha = tex.a * mix(uDimAlpha, 1.0, lit) * uEdgeFade;
  // Premultiplied alpha output required by Flutter RuntimeEffect
  fragColor = vec4(tex.rgb * alpha, alpha);
}
