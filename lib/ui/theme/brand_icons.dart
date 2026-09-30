import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';

/// Real Telegram + Discord brand marks.
///
/// Fluent / Segoe has no brand glyphs, and Lucide deliberately ships no
/// brand icons — so `FluentIcons.send` (paper plane) and `FluentIcons.chat`
/// (speech bubble) look generic/wrong. These two widgets render the official
/// Simple Icons 24x24 fill paths with the current icon/text color, so they
/// match the surrounding title-bar + settings buttons at any theme.
///
/// No new dependency, no font, no build step: tiny SVG-path parser +
/// [CustomPaint]. Usage:
///
/// ```dart
/// IconTheme(
///   data: IconThemeData(color: fg, size: 15),
///   child: const TelegramIcon(),
/// )
/// ```
///
/// Or directly: `const TelegramIcon(size: 15, color: fg)`.
class TelegramIcon extends StatelessWidget {
  final double size;
  final Color? color;
  const TelegramIcon({super.key, this.size = 15, this.color});

  @override
  Widget build(BuildContext context) {
    final effective =
        color ??
        IconTheme.of(context).color ??
        DefaultTextStyle.of(context).style.color ??
        const Color(0xFF9A9A9A);
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _BrandPathPainter(_telegramPath, effective),
      ),
    );
  }
}

class DiscordIcon extends StatelessWidget {
  final double size;
  final Color? color;
  const DiscordIcon({super.key, this.size = 15, this.color});

  @override
  Widget build(BuildContext context) {
    final effective =
        color ??
        IconTheme.of(context).color ??
        DefaultTextStyle.of(context).style.color ??
        const Color(0xFF9A9A9A);
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _BrandPathPainter(_discordPath, effective),
      ),
    );
  }
}

class _BrandPathPainter extends CustomPainter {
  final Path Function() pathBuilder;
  final Color color;
  const _BrandPathPainter(this.pathBuilder, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final s = size.width / 24.0;
    canvas.save();
    canvas.scale(s);
    canvas.drawPath(
      pathBuilder(),
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BrandPathPainter old) =>
      old.color != color || old.pathBuilder != pathBuilder;
}

// ---------------------------------------------------------------------------
// Official Simple Icons paths (24x24 viewBox, fill).
// ---------------------------------------------------------------------------

const _kTelegramD =
    'M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z';

const _kDiscordD =
    'M20.317 4.3698a19.7913 19.7913 0 00-4.8851-1.5152.0741.0741 0 00-.0785.0371c-.211.3753-.4447.8648-.6083 1.2495-1.8447-.2762-3.68-.2762-5.4868 0-.1636-.3933-.4058-.8742-.6177-1.2495a.077.077 0 00-.0785-.037 19.7363 19.7363 0 00-4.8852 1.515.0699.0699 0 00-.0321.0277C.5334 9.0458-.319 13.5799.0992 18.0578a.0824.0824 0 00.0312.0561c2.0528 1.5076 4.0413 2.4228 5.9929 3.0294a.0777.0777 0 00.0842-.0276c.4616-.6304.8731-1.2952 1.226-1.9942a.076.076 0 00-.0416-.1057c-.6528-.2476-1.2743-.5495-1.8722-.8923a.077.077 0 01-.0076-.1277c.1258-.0943.2517-.1923.3718-.2914a.0743.0743 0 01.0776-.0105c3.9278 1.7933 8.18 1.7933 12.0614 0a.0739.0739 0 01.0785.0095c.1202.099.246.1981.3728.2924a.077.077 0 01-.0066.1276 12.2986 12.2986 0 01-1.873.8914.0766.0766 0 00-.0407.1067c.3604.698.7719 1.3628 1.225 1.9932a.076.076 0 00.0842.0286c1.961-.6067 3.9495-1.5219 6.0023-3.0294a.077.077 0 00.0313-.0552c.5004-5.177-.8382-9.6739-3.5485-13.6604a.061.061 0 00-.0312-.0286zM8.02 15.3312c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9555-2.4189 2.157-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.9555 2.4189-2.1569 2.4189zm7.9748 0c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9554-2.4189 2.1569-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.946 2.4189-2.1568 2.4189Z';

Path? _telegramCache;
Path? _discordCache;

Path _telegramPath() => _telegramCache ??= _parseSvgPath(_kTelegramD);
Path _discordPath() => _discordCache ??= _parseSvgPath(_kDiscordD);

// ---------------------------------------------------------------------------
// Minimal SVG path parser (M L H V C S Q T A Z, absolute + relative).
// Handles compact forms like `12-12`, `.0741.0741`, `00-4.88` (arc flags).
// ---------------------------------------------------------------------------

Path _parseSvgPath(String d) {
  final path = Path();
  var i = 0;
  final n = d.length;
  String? cmd;

  double cx = 0, cy = 0;
  double sx = 0, sy = 0;
  double prevCx2 = 0, prevCy2 = 0;
  double prevQx = 0, prevQy = 0;
  String prevCmd = '';

  bool isLetter(String ch) {
    final c = ch.codeUnitAt(0);
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
  }

  void skipSep() {
    while (i < n) {
      final ch = d[i];
      if (ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t' || ch == ',') {
        i++;
      } else {
        break;
      }
    }
  }

  double? readNumber() {
    skipSep();
    if (i >= n) return null;
    if (isLetter(d[i])) return null;
    final start = i;
    if (d[i] == '-' || d[i] == '+') i++;
    var hasDigits = false;
    var hasDot = false;
    var hasExp = false;
    while (i < n) {
      final ch = d[i];
      if (ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57) {
        hasDigits = true;
        i++;
      } else if (ch == '.' && !hasDot && !hasExp) {
        hasDot = true;
        i++;
      } else if ((ch == 'e' || ch == 'E') && !hasExp) {
        hasExp = true;
        i++;
        if (i < n && (d[i] == '-' || d[i] == '+')) i++;
      } else {
        break;
      }
    }
    if (!hasDigits || i == start) return null;
    return double.tryParse(d.substring(start, i));
  }

  int? readFlag() {
    skipSep();
    if (i >= n) return null;
    final ch = d[i];
    if (ch == '0' || ch == '1') {
      i++;
      return ch == '1' ? 1 : 0;
    }
    return null;
  }

  while (true) {
    skipSep();
    if (i >= n) break;
    if (isLetter(d[i])) {
      cmd = d[i];
      i++;
      if (cmd == 'Z' || cmd == 'z') {
        path.close();
        cx = sx;
        cy = sy;
        prevCmd = cmd;
        cmd = null;
        continue;
      }
    }
    if (cmd == null) break;

    switch (cmd) {
      case 'M':
      case 'm':
        {
          final isRel = cmd == 'm';
          final x = readNumber();
          final y = x == null ? null : readNumber();
          if (x == null || y == null) {
            cmd = null;
            break;
          }
          cx = isRel ? cx + x : x;
          cy = isRel ? cy + y : y;
          path.moveTo(cx, cy);
          sx = cx;
          sy = cy;
          prevCmd = cmd;
          // Subsequent implicit pairs are lineto.
          cmd = isRel ? 'l' : 'L';
          prevCx2 = cx;
          prevCy2 = cy;
          prevQx = cx;
          prevQy = cy;
        }
      case 'L':
      case 'l':
        {
          final isRel = cmd == 'l';
          var moved = false;
          while (true) {
            final save = i;
            final x = readNumber();
            final y = x == null ? null : readNumber();
            if (x == null || y == null) {
              i = save;
              break;
            }
            cx = isRel ? cx + x : x;
            cy = isRel ? cy + y : y;
            path.lineTo(cx, cy);
            moved = true;
          }
          if (!moved) {
            cmd = null;
          } else {
            prevCmd = cmd;
            prevCx2 = cx;
            prevCy2 = cy;
            prevQx = cx;
            prevQy = cy;
          }
        }
      case 'H':
      case 'h':
        {
          final isRel = cmd == 'h';
          var moved = false;
          while (true) {
            final save = i;
            final x = readNumber();
            if (x == null) {
              i = save;
              break;
            }
            cx = isRel ? cx + x : x;
            path.lineTo(cx, cy);
            moved = true;
          }
          if (!moved) {
            cmd = null;
          } else {
            prevCmd = cmd;
          }
        }
      case 'V':
      case 'v':
        {
          final isRel = cmd == 'v';
          var moved = false;
          while (true) {
            final save = i;
            final y = readNumber();
            if (y == null) {
              i = save;
              break;
            }
            cy = isRel ? cy + y : y;
            path.lineTo(cx, cy);
            moved = true;
          }
          if (!moved) {
            cmd = null;
          } else {
            prevCmd = cmd;
          }
        }
      case 'C':
      case 'c':
        {
          final isRel = cmd == 'c';
          var moved = false;
          while (true) {
            final save = i;
            final x1 = readNumber();
            final y1 = x1 == null ? null : readNumber();
            final x2 = y1 == null ? null : readNumber();
            final y2 = x2 == null ? null : readNumber();
            final x = y2 == null ? null : readNumber();
            final y = x == null ? null : readNumber();
            if (y == null) {
              i = save;
              break;
            }
            final ax1 = isRel ? cx + x1! : x1!;
            final ay1 = isRel ? cy + y1! : y1!;
            final ax2 = isRel ? cx + x2! : x2!;
            final ay2 = isRel ? cy + y2! : y2!;
            final ax = isRel ? cx + x! : x!;
            final ay = isRel ? cy + y : y;
            path.cubicTo(ax1, ay1, ax2, ay2, ax, ay);
            prevCx2 = ax2;
            prevCy2 = ay2;
            cx = ax;
            cy = ay;
            moved = true;
          }
          if (!moved) {
            cmd = null;
          } else {
            prevCmd = cmd;
            prevQx = cx;
            prevQy = cy;
          }
        }
      case 'S':
      case 's':
        {
          final isRel = cmd == 's';
          var moved = false;
          while (true) {
            final save = i;
            final x2 = readNumber();
            final y2 = x2 == null ? null : readNumber();
            final x = y2 == null ? null : readNumber();
            final y = x == null ? null : readNumber();
            if (y == null) {
              i = save;
              break;
            }
            double ax1, ay1;
            if (prevCmd == 'C' ||
                prevCmd == 'c' ||
                prevCmd == 'S' ||
                prevCmd == 's') {
              ax1 = 2 * cx - prevCx2;
              ay1 = 2 * cy - prevCy2;
            } else {
              ax1 = cx;
              ay1 = cy;
            }
            final ax2 = isRel ? cx + x2! : x2!;
            final ay2 = isRel ? cy + y2! : y2!;
            final ax = isRel ? cx + x! : x!;
            final ay = isRel ? cy + y : y;
            path.cubicTo(ax1, ay1, ax2, ay2, ax, ay);
            prevCx2 = ax2;
            prevCy2 = ay2;
            cx = ax;
            cy = ay;
            moved = true;
          }
          if (!moved) {
            cmd = null;
          } else {
            prevCmd = cmd;
            prevQx = cx;
            prevQy = cy;
          }
        }
      case 'Q':
      case 'q':
        {
          final isRel = cmd == 'q';
          var moved = false;
          while (true) {
            final save = i;
            final x1 = readNumber();
            final y1 = x1 == null ? null : readNumber();
            final x = y1 == null ? null : readNumber();
            final y = x == null ? null : readNumber();
            if (y == null) {
              i = save;
              break;
            }
            final ax1 = isRel ? cx + x1! : x1!;
            final ay1 = isRel ? cy + y1! : y1!;
            final ax = isRel ? cx + x! : x!;
            final ay = isRel ? cy + y : y;
            path.quadraticBezierTo(ax1, ay1, ax, ay);
            prevQx = ax1;
            prevQy = ay1;
            cx = ax;
            cy = ay;
            moved = true;
          }
          if (!moved) {
            cmd = null;
          } else {
            prevCmd = cmd;
            prevCx2 = cx;
            prevCy2 = cy;
          }
        }
      case 'T':
      case 't':
        {
          final isRel = cmd == 't';
          var moved = false;
          while (true) {
            final save = i;
            final x = readNumber();
            final y = x == null ? null : readNumber();
            if (y == null) {
              i = save;
              break;
            }
            double ax1, ay1;
            if (prevCmd == 'Q' ||
                prevCmd == 'q' ||
                prevCmd == 'T' ||
                prevCmd == 't') {
              ax1 = 2 * cx - prevQx;
              ay1 = 2 * cy - prevQy;
            } else {
              ax1 = cx;
              ay1 = cy;
            }
            final ax = isRel ? cx + x! : x!;
            final ay = isRel ? cy + y : y;
            path.quadraticBezierTo(ax1, ay1, ax, ay);
            prevQx = ax1;
            prevQy = ay1;
            cx = ax;
            cy = ay;
            moved = true;
          }
          if (!moved) {
            cmd = null;
          } else {
            prevCmd = cmd;
            prevCx2 = cx;
            prevCy2 = cy;
          }
        }
      case 'A':
      case 'a':
        {
          final isRel = cmd == 'a';
          var moved = false;
          while (true) {
            final save = i;
            final rx0 = readNumber();
            if (rx0 == null) {
              i = save;
              break;
            }
            final ry0 = readNumber();
            if (ry0 == null) {
              i = save;
              break;
            }
            final phi = readNumber();
            if (phi == null) {
              i = save;
              break;
            }
            final large = readFlag();
            if (large == null) {
              i = save;
              break;
            }
            final sweep = readFlag();
            if (sweep == null) {
              i = save;
              break;
            }
            final x = readNumber();
            final y = x == null ? null : readNumber();
            if (y == null) {
              i = save;
              break;
            }
            final ax = isRel ? cx + x! : x!;
            final ay = isRel ? cy + y : y;
            _arcTo(path, cx, cy, rx0.abs(), ry0.abs(), phi, large == 1,
                sweep == 1, ax, ay);
            cx = ax;
            cy = ay;
            moved = true;
          }
          if (!moved) {
            cmd = null;
          } else {
            prevCmd = cmd;
            prevCx2 = cx;
            prevCy2 = cy;
            prevQx = cx;
            prevQy = cy;
          }
        }
      default:
        cmd = null;
    }
  }
  return path;
}

void _arcTo(Path path, double x1, double y1, double rx, double ry,
    double phiDeg, bool largeArc, bool sweep, double x2, double y2) {
  if (x1 == x2 && y1 == y2) return;
  if (rx == 0 || ry == 0) {
    path.lineTo(x2, y2);
    return;
  }
  final phi = phiDeg * math.pi / 180.0;
  final cosPhi = math.cos(phi);
  final sinPhi = math.sin(phi);
  final dx = (x1 - x2) / 2;
  final dy = (y1 - y2) / 2;
  final x1p = cosPhi * dx + sinPhi * dy;
  final y1p = -sinPhi * dx + cosPhi * dy;

  var rxSq = rx * rx;
  var rySq = ry * ry;
  final x1pSq = x1p * x1p;
  final y1pSq = y1p * y1p;
  final lambda = x1pSq / rxSq + y1pSq / rySq;
  if (lambda > 1) {
    final s = math.sqrt(lambda);
    rx *= s;
    ry *= s;
    rxSq = rx * rx;
    rySq = ry * ry;
  }
  final num = rxSq * rySq - rxSq * y1pSq - rySq * x1pSq;
  final den = rxSq * y1pSq + rySq * x1pSq;
  double coef = 0;
  if (den != 0) {
    final v = num / den;
    coef = v <= 0 ? 0 : math.sqrt(v);
    if (largeArc == sweep) coef = -coef;
  }
  final cxp = coef * (rx * y1p / ry);
  final cyp = coef * (-ry * x1p / rx);
  final cx = cosPhi * cxp - sinPhi * cyp + (x1 + x2) / 2;
  final cy = sinPhi * cxp + cosPhi * cyp + (y1 + y2) / 2;

  double theta1 = _vecAngle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
  double dTheta = _vecAngle((x1p - cxp) / rx, (y1p - cyp) / ry,
      (-x1p - cxp) / rx, (-y1p - cyp) / ry);
  if (!sweep && dTheta > 0) dTheta -= 2 * math.pi;
  if (sweep && dTheta < 0) dTheta += 2 * math.pi;

  var segments = (dTheta.abs() / (math.pi / 2)).ceil();
  if (segments < 1) segments = 1;
  final delta = dTheta / segments;
  final alpha = 4 / 3 * math.tan(delta / 4);

  double t1 = theta1;
  for (var sIdx = 0; sIdx < segments; sIdx++) {
    final t2 = t1 + delta;
    final cosT1 = math.cos(t1);
    final sinT1 = math.sin(t1);
    final cosT2 = math.cos(t2);
    final sinT2 = math.sin(t2);

    // Endpoints in original coordinate system.
    final e1x = cx + rx * cosT1 * cosPhi - ry * sinT1 * sinPhi;
    final e1y = cy + rx * cosT1 * sinPhi + ry * sinT1 * cosPhi;
    final e2x = cx + rx * cosT2 * cosPhi - ry * sinT2 * sinPhi;
    final e2y = cy + rx * cosT2 * sinPhi + ry * sinT2 * cosPhi;

    // Derivatives.
    final d1x = -rx * sinT1 * cosPhi - ry * cosT1 * sinPhi;
    final d1y = -rx * sinT1 * sinPhi + ry * cosT1 * cosPhi;
    final d2x = -rx * sinT2 * cosPhi - ry * cosT2 * sinPhi;
    final d2y = -rx * sinT2 * sinPhi + ry * cosT2 * cosPhi;

    final c1x = e1x + alpha * d1x;
    final c1y = e1y + alpha * d1y;
    final c2x = e2x - alpha * d2x;
    final c2y = e2y - alpha * d2y;

    if (sIdx == 0 && pathHasNoCurrentPoint(path)) {
      path.moveTo(e1x, e1y);
    }
    // First segment must start exactly at current point; lineTo is a
    // no-op if already there and keeps continuity on float error.
    if (sIdx == 0) path.lineTo(e1x, e1y);
    path.cubicTo(c1x, c1y, c2x, c2y, e2x, e2y);
    t1 = t2;
  }
}

bool pathHasNoCurrentPoint(Path path) {
  // Path.getBounds() is empty for a fresh path; cheap continuity guard.
  // We still lineTo(e1) for continuity, so this only avoids a stray moveTo.
  try {
    final b = path.getBounds();
    return b.isEmpty;
  } catch (_) {
    return true;
  }
}

double _vecAngle(double ux, double uy, double vx, double vy) {
  final dot = ux * vx + uy * vy;
  final lu = math.sqrt(ux * ux + uy * uy);
  final lv = math.sqrt(vx * vx + vy * vy);
  if (lu == 0 || lv == 0) return 0;
  var c = dot / (lu * lv);
  c = c.clamp(-1.0, 1.0);
  final cross = ux * vy - uy * vx;
  final sign = cross < 0 ? -1.0 : 1.0;
  return sign * math.acos(c);
}
