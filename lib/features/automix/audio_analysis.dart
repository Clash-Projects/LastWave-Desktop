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

  var bestLag = 0;
  var bestScore = -1e9;
  for (var lag = minLag; lag <= maxLag; lag++) {
    final bpm = 60 * fps / lag;
    final lg = math.log(bpm / 120) / math.ln2;
    final prior = math.exp(-0.5 * (lg / 0.8) * (lg / 0.8));
    final s = (acf[lag] +
            0.5 * acfAt(lag * 2.0) +
            0.33 * acfAt(lag * 3.0) +
            0.25 * acfAt(lag * 4.0)) *
        (0.5 + prior);
    if (s > bestScore) {
      bestScore = s;
      bestLag = lag;
    }
  }
  // Parabolic refinement of the peak.
  var period = bestLag.toDouble();
  if (bestLag > 1 && bestLag + 1 < acfLen) {
    final a = acf[bestLag - 1], b = acf[bestLag], c = acf[bestLag + 1];
    final den = a - 2 * b + c;
    if (den.abs() > 1e-12) {
      final shift = 0.5 * (a - c) / den;
      if (shift.abs() < 1) period += shift;
    }
  }

  // A peak at k·period pins the period k times more precisely than the
  // first peak does: 0.25% error is ~140ms of drift across a 60s window.
  for (final mult in const [8, 4, 2]) {
    final centre = period * mult;
    final c = centre.round();
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

  // ---- phase (comb) -----------------------------------------------------
  double sampleAt(Float64List x, double pos) {
    final i = pos.floor();
    if (i < 0 || i + 1 >= x.length) return 0;
    final fr = pos - i;
    return x[i] * (1 - fr) + x[i + 1] * fr;
  }

  var bestPhase = 0.0;
  var bestPhaseScore = -1e9;
  for (var ph = 0.0; ph < period; ph += 0.5) {
    var s = 0.0;
    for (var p = ph; p < onset.length; p += period) {
      s += sampleAt(onset, p);
    }
    if (s > bestPhaseScore) {
      bestPhaseScore = s;
      bestPhase = ph;
    }
  }

  // ---- refine grid through real peaks (least squares, iterated) --------
  final sorted = List<double>.of(onset)..sort();
  final floor = sorted[(sorted.length * 0.6).floor()];
  var phase = bestPhase;
  var fitCount = 0;
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
    fitCount = ks.length;
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
    while (phase < 0) {
      phase += period;
    }
    while (phase >= period) {
      phase -= period;
    }
  }

  // ---- confidence ---------------------------------------------------------
  // How far the chosen phase stands out from every other phase of the
  // same period. A best-of-many pick on noise lands ~2-3σ above the
  // rest; a real groove sits far higher. The fit share (beats that found
  // a real onset peak) guards against one loud stretch carrying it.
  final phaseScores = <double>[];
  double combAt(double ph) {
    var c = 0.0;
    var n = 0;
    for (var p = ph; p < onset.length; p += period) {
      c += sampleAt(onset, p);
      n++;
    }
    return n == 0 ? 0 : c / n;
  }

  for (var ph = 0.0; ph < period; ph += 0.5) {
    phaseScores.add(combAt(ph));
  }
  var pm = 0.0;
  for (final v in phaseScores) {
    pm += v;
  }
  pm /= phaseScores.length;
  var pv = 0.0;
  for (final v in phaseScores) {
    pv += (v - pm) * (v - pm);
  }
  final psd = math.sqrt(pv / phaseScores.length);
  final z = psd <= 1e-12 ? 0.0 : (combAt(phase) - pm) / psd;
  var onCount = 0;
  for (var p = phase; p < onset.length; p += period) {
    onCount++;
  }
  final fitShare = fitCount / math.max(1, onCount);
  final confidence = (((z - 3.0) / 3.0).clamp(0.0, 1.0) *
          (0.5 + 0.5 * fitShare.clamp(0.0, 1.0)))
      .toDouble();

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
