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

## Diagnostics

Exported session logs contain `automix analysed`, `automix beatplan`,
`automix start` and `automix handoff ... phase_err_ms=` lines.

## Tests

`test/automix_beat_test.dart` and `test/automix_planner_test.dart` are pure
Dart. `test/automix_decode_live_test.dart` and
`test/automix_live_mix_test.dart` drive real libmpv decks and run only
when `libmpv.so.2` and fixture env vars are present:

    AUTOMIX_FIXTURE=a.flac AUTOMIX_FIXTURE_MS=150000 \
    AUTOMIX_FIXTURE_A=a.flac AUTOMIX_FIXTURE_B=b.m4a flutter test test/automix_*
