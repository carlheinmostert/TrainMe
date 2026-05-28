/**
 * homefit.studio — Shared dose / set formatting (web JS surface)
 * ==============================================================
 *
 * Single source of truth for the workout dose grammar that BOTH the
 * Interactive Workout Guide (lobby/deck, app.js + lobby.js) and the
 * Printable Workout Guide (handout.js) render. Before this module the
 * handout had its own parallel rep/hold logic (renderStatsHTML) that
 * could drift from the lobby's `buildDoseLine`; now both delegate here
 * so rep numbers + hold wording can never diverge (task 6 of the
 * artifact-consistency wave).
 *
 * Pure: no DOM, no IO, no module-level state. Exposed as
 * `window.HomefitDose`.
 *
 *   - HomefitDose.coerceSet(rawSet)        -> normalised set
 *   - HomefitDose.allSetsForSlide(slide)   -> normalised sets[] (>= 1)
 *   - HomefitDose.formatReps(playSets)     -> 'N × R reps' | 'R1/R2 reps' | ''
 *   - HomefitDose.formatHold(playSets)     -> 'Ns hold (per rep)' | ... | ''
 *   - HomefitDose.formatWeight(playSets)   -> '@ 15 kg' | '@ 12.5/15 kg' | ''
 *   - HomefitDose.formatWeightKg(kg)       -> '15 kg' | '12.5 kg' | 'Bodyweight'
 *   - HomefitDose.buildDoseLine(slide, opts)-> the joined ` · ` dose line
 *
 * `buildDoseLine` mirrors the lobby's composer (lobby.js buildDoseLine).
 * `opts.calculateDuration(slide)` is OPTIONAL — when supplied (lobby) a
 * trailing `~Xs` estimated-duration segment is appended; when omitted
 * (handout, which has no per-rep video timing context) it is skipped.
 *
 * Loaded via `<script src="dose_format.js">` BEFORE app.js / lobby.js /
 * handout.js. No inline scripts (CSP `script-src 'self'`).
 */
(function () {
  'use strict';

  function coerceSet(rawSet) {
    if (!rawSet) {
      return {
        reps: 10,
        hold_seconds: 0,
        hold_position: 'end_of_set',
        weight_kg: null,
        breather_seconds_after: 0,
      };
    }
    var rawHp = rawSet.hold_position;
    var holdPosition = (rawHp === 'per_rep' || rawHp === 'end_of_set' || rawHp === 'end_of_exercise')
      ? rawHp
      : 'end_of_set';
    return {
      reps: Math.max(1, Number(rawSet.reps) || 10),
      hold_seconds: Math.max(0, Number(rawSet.hold_seconds) || 0),
      hold_position: holdPosition,
      weight_kg: rawSet.weight_kg == null ? null : Number(rawSet.weight_kg),
      breather_seconds_after: Math.max(0, Number(rawSet.breather_seconds_after) || 0),
    };
  }

  // Every authored set on a slide, ignoring circuitRound. Always >= 1.
  function allSetsForSlide(slide) {
    if (!slide) return [coerceSet(null)];
    var raw = Array.isArray(slide.sets) ? slide.sets : [];
    if (raw.length === 0) return [coerceSet(null)];
    return raw.map(coerceSet);
  }

  function formatReps(playSets) {
    if (!Array.isArray(playSets) || !playSets.length) return '';
    var repsList = playSets.map(function (s) { return Number(s.reps) || 0; });
    var allSame = repsList.every(function (r) { return r === repsList[0]; });
    if (allSame) return playSets.length + ' × ' + repsList[0] + ' reps';
    return repsList.join('/') + ' reps';
  }

  function formatHold(playSets) {
    if (!Array.isArray(playSets) || !playSets.length) return '';
    var holds = playSets.map(function (s) { return Number(s.hold_seconds) || 0; });
    var allSame = holds.every(function (h) { return h === holds[0]; });
    if (!allSame) return '';
    var sec = holds[0];
    if (sec <= 0) return '';
    var mode = (playSets[0] && playSets[0].hold_position) || 'end_of_set';
    if (mode === 'per_rep') return sec + 's hold (per rep)';
    if (mode === 'end_of_exercise') return sec + 's hold (on last set rep)';
    return sec + 's hold (on last rep)';
  }

  function formatWeightKg(kg) {
    if (kg == null) return 'Bodyweight';
    var n = Number(kg);
    if (!Number.isFinite(n)) return 'Bodyweight';
    if (Number.isInteger(n)) return n + ' kg';
    var rounded = Math.round(n * 10) / 10;
    if (Number.isInteger(rounded)) return rounded + ' kg';
    return rounded.toFixed(1) + ' kg';
  }

  function formatWeight(playSets) {
    if (!Array.isArray(playSets) || playSets.length === 0) return '';
    var weights = playSets.map(function (s) { return s && s.weight_kg; });
    var allBodyweight = weights.every(function (w) { return w == null; });
    if (allBodyweight) return '';
    var uniform = weights.every(function (w) { return w === weights[0]; });
    if (uniform) return '@ ' + formatWeightKg(weights[0]);
    var seq = weights
      .map(function (w) { return w == null ? 'BW' : formatWeightKg(w).replace(' kg', ''); })
      .join('/');
    return '@ ' + seq + ' kg';
  }

  function formatDur(seconds) {
    var sec = Math.max(0, Math.round(seconds));
    if (sec < 60) return sec + 's';
    var m = Math.floor(sec / 60);
    var s = sec % 60;
    return m + ':' + String(s).padStart(2, '0');
  }

  // Per-rep video timing — mirrors app.js perRepSecondsForSlide. Videos
  // derive per-rep from video_duration_ms / video_reps_per_loop; everything
  // else (photos, missing timing) uses the 3s default.
  var SECONDS_PER_REP = 3;
  function perRepSecondsForSlide(slide) {
    if (!slide) return SECONDS_PER_REP;
    if (slide.media_type === 'video') {
      var durMs = Number(slide.video_duration_ms) || 0;
      var reps = Number(slide.video_reps_per_loop) || 1;
      if (durMs > 0 && reps > 0) return (durMs / 1000) / reps;
    }
    return SECONDS_PER_REP;
  }

  function perSetSeconds(set, slide, isLastSetInExercise) {
    var perRep = perRepSecondsForSlide(slide);
    var reps = Math.max(1, (set && set.reps) || 1);
    var hold = Math.max(0, (set && set.hold_seconds) || 0);
    var breather = Math.max(0, (set && set.breather_seconds_after) || 0);
    var holdPosition = (set && set.hold_position) || 'end_of_set';
    var holdTotal;
    if (holdPosition === 'per_rep') holdTotal = reps * hold;
    else if (holdPosition === 'end_of_exercise') holdTotal = isLastSetInExercise ? hold : 0;
    else holdTotal = hold;
    var phys = (reps * perRep) + holdTotal;
    return Math.max(1, Math.round(phys + breather));
  }

  /**
   * Whole-exercise estimated duration in seconds — mirrors app.js
   * calculateDuration for a non-unrolled (handout) slide. Sums per-set
   * durations across every authored set; the final set carries the
   * end_of_exercise hold. Rest slides return their rest_seconds (30s
   * fallback). This lets the Printable Workout Guide render the SAME
   * trailing `~Xs` dose segment the Interactive lobby shows, so the dose
   * lines read identically.
   */
  function calculateDuration(slide) {
    if (!slide) return 1;
    if (slide.media_type === 'rest') {
      var v = slide.rest_seconds;
      if (v == null || !Number.isFinite(Number(v)) || Number(v) <= 0) return 30;
      return Math.max(1, Math.round(Number(v)));
    }
    var playSets = allSetsForSlide(slide);
    var total = 0;
    for (var i = 0; i < playSets.length; i++) {
      var isLast = i === playSets.length - 1;
      total += perSetSeconds(playSets[i], slide, isLast);
    }
    return Math.max(1, total);
  }

  /**
   * Mirror of lobby.js buildDoseLine — single source so the handout and
   * the interactive lobby produce byte-identical dose lines.
   *
   * @param {object} slide
   * @param {object} [opts]
   * @param {function} [opts.calculateDuration]  optional (slide) -> seconds.
   *        When present a trailing `~Xs` segment is appended (lobby).
   *        When absent the duration segment is omitted (handout).
   * @returns {string}
   */
  function buildDoseLine(slide, opts) {
    opts = opts || {};
    if (!slide || slide.media_type === 'rest') return '';

    var isPhoto = slide.media_type === 'photo' || slide.media_type === 'image';
    var playSets = allSetsForSlide(slide);

    if (isPhoto) {
      var holdPhoto = formatHold(playSets);
      if (holdPhoto) return holdPhoto;
      return 'Reference position';
    }

    if (!playSets.length) return '';

    var breathersList = playSets.map(function (s) { return s.breather_seconds_after || 0; });
    var breathersUniform = breathersList.every(function (b) { return b === breathersList[0]; });

    var parts = [];
    var repsSeg = formatReps(playSets);
    if (repsSeg) parts.push(repsSeg);
    var holdSeg = formatHold(playSets);
    if (holdSeg) parts.push(holdSeg);
    var weightSeg = formatWeight(playSets);
    if (weightSeg) parts.push(weightSeg);
    if (breathersUniform && breathersList[0] > 0) {
      parts.push(breathersList[0] + 's rest');
    }
    if (typeof opts.calculateDuration === 'function') {
      var dur = opts.calculateDuration(slide) || 0;
      if (dur > 0) parts.push('~' + formatDur(dur));
    }
    return parts.join(' · ');
  }

  window.HomefitDose = Object.freeze({
    coerceSet: coerceSet,
    allSetsForSlide: allSetsForSlide,
    formatReps: formatReps,
    formatHold: formatHold,
    formatWeight: formatWeight,
    formatWeightKg: formatWeightKg,
    formatDur: formatDur,
    buildDoseLine: buildDoseLine,
    // Whole-exercise estimated duration (surfaces without app.js, i.e. the
    // handout). Mirrors app.js calculateDuration for a non-unrolled slide.
    calculateDuration: calculateDuration,
    perRepSecondsForSlide: perRepSecondsForSlide,
  });
})();
