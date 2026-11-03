# AutoMix

AutoMix overlaps the end of one track with the start of the next on a
second ("standby") libmpv deck. Code: `lib/features/automix/` and the
`Beat-aware AutoMix` section of `lib/features/player/playback_service.dart`.

## Pipeline

1. **Pair rules** (`player/mix_planner.dart`) — consecutive tracks of one
   album, live recordings and spoken word stay gapless; the overlap is
   capped to 16% of the shorter track.
2. **Analysis deck** (`automix/automix_analyzer.dart`) — a throwaway libmpv
   instance with `ao=pcm`, `untimed=yes`, mono s16 @ 11.025 kHz decodes
   the last 60 s of the playing track and the first 60 s of the next one
   (same URL + headers as playback, so addon, YouTube and local files all
   work). A minute decodes in well under a second; nothing reaches the
   sound card. Results are cached in `<temp>/lastwave/automix/`.
3. **Analysis** (`automix/audio_analysis.dart`, runs in an isolate) —
   spectral-flux onsets with the low band (kick/bass) weighted, tempo from
   the onset autocorrelation (refined at the 8th beat multiple), beat phase
   by comb filter then least-squares through the real onset peaks,
   downbeats from the accented low end, audible start/end at −40 dB from
   the peak. Confidence is how many σ the chosen beat phase stands above
   every other phase (noise ≲ 2.5σ, a steady groove ≳ 4σ).
4. **Plan** (`automix/beat_mix_planner.dart`) — tempi within ±6%
   (half/double time allowed) are beat-matched: a 32/16/8-beat overlap that
   ends at the outgoing track's last audible moment, starting on one of its
   downbeats, entering the incoming track on its first audible downbeat at
   `rate = outBPM / inBPM`. Otherwise a plain blend that still skips silent
   tails and intros.
5. **Run** — the incoming deck is opened at `cue − 3 s` and started muted
   3 s early. `BeatLock` samples both decks' mpv `time-pos` every 25 ms,
   averages over 0.5 s (mpv's clock moves in audio-buffer chunks, ±30 ms
   per reading) and corrects: a seek while still muted, otherwise speed
   nudges of at most ±3% (scaletempo keeps pitch). The fade follows the
   OUTGOING deck's clock, so stalls shift the mix instead of breaking it.
   After the hand-off the tempo glides back to normal over 8 s.

Beat matching is skipped while pitch shifting is on (it owns `speed`).

## Safety layer

Every AutoMix bug so far ended with the decks in a state nobody asked
for, so correctness does not rely on each code path cleaning up:

- **One owner for volume.** `state.volume` changes only in `setVolume()`;
  mpv volume events are never copied back (fade echoes once set the app
  to ~0% and the next mix faded songs to silence). Decks are set to
  `_fullDeckVolume` (100 when a DAC's hardware volume is in charge).
- **Watchdog** (`automix/mix_guard.dart`, 1 Hz). Outside a mix: the
  primary deck must be at full volume and normal speed, the standby deck
  silent. A stuck mix (> 40 s) is finished or aborted. A repair is
  applied only when seen twice in a row, so in-flight changes are never
  "fixed".
- **Stall guard.** If the incoming deck's clock stops for 3 s the mix
  backs out (the current song plays on); if the outgoing deck stalls the
  hand-off happens early.
- **Exceptions.** Mixer timer ticks and the hand-off run inside guards; an
  error ends in `_abortMixSafely()` with one audible deck at full level.
- **Fault budget** (`MixFaultBudget`). Each repair, stall, give-up or
  error is a fault. After 3 in a session beat-matching turns off (plain
  fades); after 6 overlap turns off (gapless).
- **Analysis deck.** Queued jobs the listener skipped past are dropped;
  4 failed decodes in a row turn analysis off for the session; a marker
  file around each native decode turns analysis off for one launch if the
  previous run died inside it; analyses (fresh or cached) with impossible
  values are rejected; every plan is checked by `BeatMixPlanner.isSafePlan`
  (finite, inside both tracks, ≤ max overlap, ≤ 6% tempo).

## Diagnostics

Exported session logs contain `automix analysed`, `automix beatplan`,
`automix start` and `automix handoff ... phase_err_ms=` lines, plus
`automix fault #n: ...` and `automix safety: ...` when the safety layer
acted.

## Tests

`test/automix_beat_test.dart`, `test/automix_planner_test.dart` and
`test/automix_robustness_test.dart` are pure Dart.
`test/automix_service_live_test.dart` runs the real `PlaybackService` on
two libmpv decks (mpv `null` output) through two hand-offs and fails if
the volume moves, the incoming song is not audible, a deck is left in the
wrong state, or the watchdog had to repair anything; it runs whenever
`libmpv.so.2` is installed. `test/automix_decode_live_test.dart` and
`test/automix_live_mix_test.dart` drive real libmpv decks and run only
when `libmpv.so.2` and fixture env vars are present:

    AUTOMIX_FIXTURE=a.flac AUTOMIX_FIXTURE_MS=150000 \
    AUTOMIX_FIXTURE_A=a.flac AUTOMIX_FIXTURE_B=b.m4a flutter test test/automix_*
