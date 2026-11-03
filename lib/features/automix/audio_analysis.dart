import 'dart:math' as math;
import 'dart:typed_data';

/// Rhythm and level facts about one window of a track (the tail of the
/// outgoing song or the head of the incoming one).
///
/// All times are seconds on the TRACK's own timeline (window offset
/// already added), so the planner never has to know which window a
/// number came from.
class TrackAnalysis {
  const TrackAnalysis({
    required this.windowStart,
    required this.windowEnd,
    required this.bpm,
    required this.confidence,
    required this.beats,
    required this.downbeats,
    required this.audibleStart,
    required this.contentEnd,
    required this.energyDb,
    this.energyHop = 0.5,
  });

  final double windowStart;
  final double windowEnd;

  /// 0 when no steady pulse was found.
  final double bpm;

  /// 0..1 — how clearly the beat grid stands out from the onset noise.
  final double confidence;

  /// Beat grid across the window (track seconds).
  final List<double> beats;

  /// Subset of [beats] judged to be bar starts ("the one").
  final List<double> downbeats;

  /// First moment with real signal (skips silent / near-silent intros).
  final double audibleStart;

  /// Last moment with real signal (ignores silent tails).
  final double contentEnd;

  /// RMS level in dBFS every [energyHop] seconds from [windowStart].
  final List<double> energyDb;
  final double energyHop;

  double get beatPeriod => bpm > 0 ? 60.0 / bpm : 0;

  bool get hasBeat => bpm > 0 && confidence >= 0.15 && beats.length >= 8;

  Map<String, Object?> toJson() => {
        'v': 1,
        'ws': windowStart,
        'we': windowEnd,
        'bpm': bpm,
        'conf': confidence,
        'beats': beats,
        'down': downbeats,
        'as': audibleStart,
        'ce': contentEnd,
        'e': energyDb,
        'eh': energyHop,
      };

  static TrackAnalysis? fromJson(Map<String, Object?> j) {
    try {
      if (j['v'] != 1) return null;
      List<double> dl(Object? o) =>
          (o as List).map((e) => (e as num).toDouble()).toList();
      return TrackAnalysis(
        windowStart: (j['ws'] as num).toDouble(),
        windowEnd: (j['we'] as num).toDouble(),
        bpm: (j['bpm'] as num).toDouble(),
        confidence: (j['conf'] as num).toDouble(),
        beats: dl(j['beats']),
        downbeats: dl(j['down']),
        audibleStart: (j['as'] as num).toDouble(),
        contentEnd: (j['ce'] as num).toDouble(),
        energyDb: dl(j['e']),
        energyHop: (j['eh'] as num).toDouble(),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Input for [analyzePcm] — a plain record so it can cross an isolate.
class PcmWindow {
  const PcmWindow(this.samples, this.sampleRate, this.offsetSeconds);

  /// Mono signed 16-bit PCM.
  final Int16List samples;
  final int sampleRate;
  final double offsetSeconds;
}

/// Top-level so it can run in `compute()`.
TrackAnalysis analyzePcmWindow(PcmWindow w) =>
    analyzePcm(w.samples, w.sampleRate, offsetSeconds: w.offsetSeconds);

const int _fftSize = 512;
const int _hop = 128;

/// Tempo, beat grid, downbeats and audible bounds of a mono PCM window.
///
/// Onset strength is log-magnitude spectral flux; tempo is the
/// autocorrelation peak of that envelope (with harmonics, weighted
/// toward 120 BPM); the grid is the best comb phase, then refined by a
/// least-squares fit through the real onset peaks so a small tempo
/// error does not drift across a 60s window.
TrackAnalysis analyzePcm(Int16List pcm, int sampleRate,
    {double offsetSeconds = 0}) {
  final windowEnd = offsetSeconds + pcm.length / sampleRate;
  final fps = sampleRate / _hop;
  final nFrames =
      pcm.length < _fftSize ? 0 : 1 + (pcm.length - _fftSize) ~/ _hop;

  // ---- levels -----------------------------------------------------------
  final energyHop = 0.5;
  final eLen = math.max(1, (pcm.length / (sampleRate * energyHop)).ceil());
  final energyDb = List<double>.filled(eLen, -120);
  final eWin = (sampleRate * energyHop).round();
  for (var i = 0; i < eLen; i++) {
    final s = i * eWin;
    final e = math.min(pcm.length, s + eWin);
    if (e <= s) break;
    var acc = 0.0;
    for (var k = s; k < e; k++) {
      final v = pcm[k] / 32768.0;
      acc += v * v;
    }
    final rms = math.sqrt(acc / (e - s));
    energyDb[i] = rms <= 1e-6 ? -120 : 20 * math.log(rms) / math.ln10;
  }
  final (audibleStart, contentEnd) =
      _audibleBounds(pcm, sampleRate, offsetSeconds);

  if (nFrames < fps * 8) {
    return TrackAnalysis(
      windowStart: offsetSeconds,
      windowEnd: windowEnd,
      bpm: 0,
      confidence: 0,
      beats: const [],
      downbeats: const [],
      audibleStart: audibleStart,
      contentEnd: contentEnd,
      energyDb: energyDb,
      energyHop: energyHop,
    );
  }

  // ---- onset envelope (spectral flux) -----------------------------------
  final window = Float64List(_fftSize);
  for (var i = 0; i < _fftSize; i++) {
    window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (_fftSize - 1));
  }
  final half = _fftSize ~/ 2;
  final lowBins = math.max(2, (150 / (sampleRate / _fftSize)).floor());
  final re = Float64List(_fftSize);
  final im = Float64List(_fftSize);
  var prev = Float64List(half);
  var cur = Float64List(half);
  final flux = Float64List(nFrames);
  final lowFlux = Float64List(nFrames);
  for (var f = 0; f < nFrames; f++) {
    final base = f * _hop;
    for (var i = 0; i < _fftSize; i++) {
      re[i] = pcm[base + i] / 32768.0 * window[i];
      im[i] = 0;
    }
    _fft(re, im);
    var sum = 0.0;
    var low = 0.0;
    for (var b = 1; b < half; b++) {
      final mag = math.sqrt(re[b] * re[b] + im[b] * im[b]);
      final v = math.log(1 + 100 * mag);
      cur[b] = v;
      final d = v - prev[b];
      if (d > 0) {
        sum += d;
        if (b <= lowBins) low += d;
      }
    }
    flux[f] = f == 0 ? 0 : sum;
    lowFlux[f] = f == 0 ? 0 : low;
    final t = prev;
    prev = cur;
    cur = t;
  }
  final fullOnset = _detrend(flux, (fps * 0.4).round());
  final lowOnset = _detrend(lowFlux, (fps * 0.4).round());
  // Beats live in the low end (kick, bass); broadband flux alone locks
  // just as happily onto off-beat hi-hats. Blend the two, each scaled to
  // its own mean, with the low band dominant.
  final onset = Float64List(fullOnset.length);
  {
    var mf = 0.0, ml = 0.0;
    for (var i = 0; i < fullOnset.length; i++) {
      mf += fullOnset[i];
      ml += lowOnset[i];
    }
    mf = mf <= 1e-12 ? 1 : mf / fullOnset.length;
    ml = ml <= 1e-12 ? 0 : ml / lowOnset.length;
    for (var i = 0; i < onset.length; i++) {
      onset[i] = fullOnset[i] / mf + (ml > 0 ? 2.5 * lowOnset[i] / ml : 0);
    }
  }

  // ---- tempo ------------------------------------------------------------
  final minLag = (fps * 60 / 200).floor();
  final maxLag = math.min(onset.length ~/ 3, (fps * 60 / 60).ceil());
  if (maxLag <= minLag + 2) {
    return _noBeat(offsetSeconds, windowEnd, audibleStart, contentEnd,
        energyDb, energyHop);
  }
  final acf = Float64List(math.max(maxLag * 4 + 2, onset.length ~/ 2));
  final acfLen = math.min(acf.length, onset.length - 1);
  var zero = 0.0;
  for (var t = 0; t < onset.length; t++) {
    zero += onset[t] * onset[t];
  }
  if (zero <= 1e-12) {
    return _noBeat(offsetSeconds, windowEnd, audibleStart, contentEnd,
        energyDb, energyHop);
  }
  for (var lag = 1; lag < acfLen; lag++) {
    var s = 0.0;
    for (var t = 0; t + lag < onset.length; t++) {
      s += onset[t] * onset[t + lag];
    }
    acf[lag] = s / zero;
  }
  double acfAt(double lag) {
    final i = lag.floor();
    if (i < 1 || i + 1 >= acfLen) return 0;
    final fr = lag - i;
    return acf[i] * (1 - fr) + acf[i + 1] * fr;
  }

  // Score every lag: autocorrelation plus its harmonics, with a mild
  // prior toward 120 BPM. Keep the strongest few local peaks: rival
  // readings of one groove (3:4, 2:3) score within a few percent of each
  // other, so the winner is picked on how well its grid holds, below.
  final scores = Float64List(maxLag + 2);
  for (var lag = minLag; lag <= maxLag; lag++) {
    final bpm = 60 * fps / lag;
    final lg = math.log(bpm / 120) / math.ln2;
    final prior = math.exp(-0.5 * (lg / 0.8) * (lg / 0.8));
    scores[lag] = (acf[lag] +
            0.5 * acfAt(lag * 2.0) +
            0.33 * acfAt(lag * 3.0) +
            0.25 * acfAt(lag * 4.0)) *
        (0.5 + prior);
  }
  final peaks = <int>[];
  for (var lag = minLag + 1; lag < maxLag; lag++) {
    if (scores[lag] >= scores[lag - 1] && scores[lag] > scores[lag + 1]) {
      peaks.add(lag);
    }
  }
  peaks.sort((x, y) => scores[y].compareTo(scores[x]));
  final candidates = <int>[];
  for (final l in peaks) {
    if (candidates.any((c) => (c - l).abs() <= c * 0.04)) continue;
    if (scores[l] < scores[peaks.first] * 0.6) break;
    candidates.add(l);
    if (candidates.length == 3) break;
  }
  if (candidates.isEmpty) {
    return _noBeat(offsetSeconds, windowEnd, audibleStart, contentEnd,
        energyDb, energyHop);
  }

  _Grid? best;
  for (final lag in candidates) {
    final g = _fitGrid(onset, acf, acfLen, lag);
    if (g == null) continue;
    // Stability decides; the autocorrelation score breaks near-ties.
    final rank = g.stability + 0.1 * scores[lag] / scores[candidates.first];
    if (best == null || rank > best.rank) {
      best = g..rank = rank;
    }
  }
  if (best == null) {
    return _noBeat(offsetSeconds, windowEnd, audibleStart, contentEnd,
        energyDb, energyHop);
  }
  final period = best.period;
  final phase = best.phase;
  // A steady grid on which onsets clearly pile up. Noise reaches an
  // onset contrast of ~1.4 at most; real grooves sit at 2-15.
  final confidence =
      (best.stability * ((best.contrast - 1.5) / 1.5).clamp(0.0, 1.0))
          .toDouble();

  double sampleAt(Float64List x, double pos) => _sampleAt(x, pos);

  // ---- grid, downbeats ---------------------------------------------------
  final beats = <double>[];
  final beatFrames = <double>[];
  for (var p = phase; p < onset.length; p += period) {
    beatFrames.add(p);
    // Frame f covers samples [f*hop, f*hop+fft); its onset is centred.
    beats.add(offsetSeconds + (p * _hop + _fftSize / 2) / sampleRate);
  }
  final barScore = List<double>.filled(4, 0);
  for (var i = 0; i < beatFrames.length; i++) {
    barScore[i % 4] += sampleAt(lowOnset, beatFrames[i]) +
        0.1 * sampleAt(fullOnset, beatFrames[i]);
  }
  var bar = 0;
  for (var i = 1; i < 4; i++) {
    if (barScore[i] > barScore[bar]) bar = i;
  }
  final downbeats = <double>[
    for (var i = bar; i < beats.length; i += 4) beats[i],
  ];

  return TrackAnalysis(
    windowStart: offsetSeconds,
    windowEnd: windowEnd,
    bpm: 60 * fps / period,
    confidence: confidence,
    beats: beats,
    downbeats: downbeats,
    audibleStart: audibleStart,
    contentEnd: contentEnd,
    energyDb: energyDb,
    energyHop: energyHop,
  );
}

double _sampleAt(Float64List x, double pos) {
  final i = pos.floor();
  if (i < 0 || i + 1 >= x.length) return 0;
  final fr = pos - i;
  return x[i] * (1 - fr) + x[i + 1] * fr;
}

class _Grid {
  _Grid(this.period, this.phase, this.stability, this.contrast);
  final double period;
  final double phase;
  final double contrast;

  /// 0..1 — share of ~15 s sections that independently land on this grid.
  final double stability;
  double rank = 0;
}

/// Best comb phase for [period] over frames [from, to).
double _bestPhase(Float64List onset, double period, int from, int to) {
  var best = 0.0;
  var bestScore = -1e9;
  for (var ph = 0.0; ph < period; ph += 0.5) {
    var s = 0.0;
    var n = 0;
    final start = from + ((ph - from) % period + period) % period;
    for (var p = start; p < to; p += period) {
      s += _sampleAt(onset, p);
      n++;
    }
    if (n > 0 && s / n > bestScore) {
      bestScore = s / n;
      best = start % period;
    }
  }
  return best;
}

/// Refines a tempo candidate into a grid and measures how steady it is.
_Grid? _fitGrid(Float64List onset, Float64List acf, int acfLen, int lag) {
  var period = lag.toDouble();
  if (lag > 1 && lag + 1 < acfLen) {
    final a = acf[lag - 1], b = acf[lag], c = acf[lag + 1];
    final den = a - 2 * b + c;
    if (den.abs() > 1e-12) {
      final shift = 0.5 * (a - c) / den;
      if (shift.abs() < 1) period += shift;
    }
  }
  // A peak at k·period pins the period k times more precisely.
  for (final mult in const [8, 4, 2]) {
    final c = (period * mult).round();
    if (c + 4 >= acfLen) continue;
    var bi = c;
    for (var i = c - 3; i <= c + 3; i++) {
      if (acf[i] > acf[bi]) bi = i;
    }
    var peak = bi.toDouble();
    final a = acf[bi - 1], b = acf[bi], cc = acf[bi + 1];
    final den = a - 2 * b + cc;
    if (den.abs() > 1e-12) {
      final shift = 0.5 * (a - cc) / den;
      if (shift.abs() < 1) peak += shift;
    }
    final refined = peak / mult;
    if ((refined - period).abs() < period * 0.03) period = refined;
    break;
  }

  var phase = _bestPhase(onset, period, 0, onset.length);

  // Least squares through the real onset peaks near each predicted beat.
  final sorted = List<double>.of(onset)..sort();
  final floor = sorted[(sorted.length * 0.6).floor()];
  for (var pass = 0; pass < 3; pass++) {
    final ks = <double>[];
    final ts = <double>[];
    final radius = math.max(1, (period * (pass == 0 ? 0.2 : 0.12)).round());
    var k = 0;
    for (var p = phase; p < onset.length; p += period, k++) {
      final c = p.round();
      var bi = -1;
      var bv = floor;
      for (var i = c - radius; i <= c + radius; i++) {
        if (i <= 0 || i + 1 >= onset.length) continue;
        final v = onset[i];
        if (v > bv && v >= onset[i - 1] && v >= onset[i + 1]) {
          bv = v;
          bi = i;
        }
      }
      if (bi >= 0) {
        ks.add(k.toDouble());
        ts.add(bi.toDouble());
      }
    }
    if (ks.length < 8) break;
    final n = ks.length;
    final mk = ks.reduce((a, b) => a + b) / n;
    final mt = ts.reduce((a, b) => a + b) / n;
    var sxy = 0.0, sxx = 0.0;
    for (var i = 0; i < n; i++) {
      sxy += (ks[i] - mk) * (ts[i] - mt);
      sxx += (ks[i] - mk) * (ks[i] - mk);
    }
    if (sxx <= 0) break;
    final slope = sxy / sxx;
    if ((slope - period).abs() >= period * 0.04) break;
    period = slope;
    phase = mt - slope * mk;
    phase = (phase % period + period) % period;
  }

  // Stability: split into ~10 s sections and find each section's own
  // best phase for this period. A real groove puts (nearly) all sections
  // on one phase whatever else is in the mix; on noise the phases scatter,
  // so ≥4 of 6 agreeing by chance is rare.
  const sectionFrames = 861; // ≈10 s at 86 frames/s
  final sections = math.max(1, onset.length ~/ sectionFrames);
  final len = onset.length ~/ sections;
  if (len < period * 6) return null;
  final phases = <double>[
    for (var s = 0; s < sections; s++)
      _bestPhase(onset, period, s * len,
          s == sections - 1 ? onset.length : (s + 1) * len),
  ];
  var agree = 0;
  for (final c in phases) {
    var n = 0;
    for (final q in phases) {
      var d = (q - c).abs() % period;
      if (d > period / 2) d = period - d;
      if (d <= period * 0.06) n++;
    }
    agree = math.max(agree, n);
  }
  final share = agree / sections;
  final stability = sections < 4
      ? (share >= 1 ? 0.5 : 0.0)
      : ((share - 0.4) / 0.6).clamp(0.0, 1.0).toDouble();
  // How much onset energy sits on the grid points (vs. the average).
  var on = 0.0;
  var cnt = 0;
  for (var p = phase; p < onset.length; p += period) {
    on += _sampleAt(onset, p);
    cnt++;
  }
  var mean = 0.0;
  for (final v in onset) {
    mean += v;
  }
  mean /= onset.length;
  final contrast = mean <= 1e-12 || cnt == 0 ? 0.0 : (on / cnt) / mean;
  return _Grid(period, phase, stability, contrast);
}

TrackAnalysis _noBeat(double ws, double we, double as, double ce,
        List<double> e, double eh) =>
    TrackAnalysis(
      windowStart: ws,
      windowEnd: we,
      bpm: 0,
      confidence: 0,
      beats: const [],
      downbeats: const [],
      audibleStart: as,
      contentEnd: ce,
      energyDb: e,
      energyHop: eh,
    );

/// First / last 50 ms block above (loudest block − 40 dB), floored at
/// −55 dBFS, so tape hiss and reverb tails do not count as music.
(double, double) _audibleBounds(Int16List pcm, int sr, double offset) {
  final block = math.max(1, sr ~/ 20);
  final n = pcm.length ~/ block;
  if (n == 0) return (offset, offset);
  final db = List<double>.filled(n, -120);
  var peak = -120.0;
  for (var b = 0; b < n; b++) {
    var acc = 0.0;
    for (var i = b * block; i < (b + 1) * block; i++) {
      final v = pcm[i] / 32768.0;
      acc += v * v;
    }
    final rms = math.sqrt(acc / block);
    db[b] = rms <= 1e-6 ? -120 : 20 * math.log(rms) / math.ln10;
    if (db[b] > peak) peak = db[b];
  }
  final thr = math.max(peak - 40, -55);
  var first = 0;
  while (first < n && db[first] < thr) {
    first++;
  }
  var last = n - 1;
  while (last > first && db[last] < thr) {
    last--;
  }
  if (first >= n) return (offset, offset + pcm.length / sr);
  return (offset + first * block / sr, offset + (last + 1) * block / sr);
}

/// Subtract a moving average and half-wave rectify.
Float64List _detrend(Float64List x, int win) {
  final out = Float64List(x.length);
  if (x.isEmpty) return out;
  final w = math.max(1, win);
  var acc = 0.0;
  final pre = Float64List(x.length + 1);
  for (var i = 0; i < x.length; i++) {
    acc += x[i];
    pre[i + 1] = acc;
  }
  for (var i = 0; i < x.length; i++) {
    final a = math.max(0, i - w);
    final b = math.min(x.length, i + w + 1);
    final avg = (pre[b] - pre[a]) / (b - a);
    final v = x[i] - avg;
    out[i] = v > 0 ? v : 0;
  }
  return out;
}

/// In-place iterative radix-2 FFT.
void _fft(Float64List re, Float64List im) {
  final n = re.length;
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; (j & bit) != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      final ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final ang = -2 * math.pi / len;
    final wr = math.cos(ang), wi = math.sin(ang);
    for (var i = 0; i < n; i += len) {
      var cr = 1.0, ci = 0.0;
      for (var j = 0; j < len ~/ 2; j++) {
        final ar = re[i + j], ai = im[i + j];
        final br = re[i + j + len ~/ 2], bi = im[i + j + len ~/ 2];
        final tr = br * cr - bi * ci;
        final ti = br * ci + bi * cr;
        re[i + j] = ar + tr;
        im[i + j] = ai + ti;
        re[i + j + len ~/ 2] = ar - tr;
        im[i + j + len ~/ 2] = ai - ti;
        final ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = ncr;
      }
    }
  }
}
