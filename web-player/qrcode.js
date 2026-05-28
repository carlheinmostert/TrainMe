/**
 * homefit.studio — Minimal QR Code encoder (web JS surface)
 * =========================================================
 *
 * A dependency-free, byte-mode QR Code generator. Renders LOCALLY to an
 * SVG string or a canvas, so it is CSP-clean (`script-src 'self'`,
 * `img-src 'self' ... data:`) — no external QR image API (which would be
 * blocked by `img-src`), no third-party script.
 *
 * Used by the standard footer (handout + lobby) to encode the
 * practitioner referral link `https://manage.homefit.studio/r/{code}`.
 *
 * Scope: byte mode (UTF-8), error-correction level chosen by the caller
 * (default 'M'), automatic smallest-version selection up to version 10
 * (57x57 modules) — more than enough for a referral URL (~45 chars).
 *
 * This is a compact, self-contained implementation of the QR spec's
 * Reed-Solomon + matrix-placement steps. It is NOT a general-purpose
 * library (no kanji/numeric/alphanumeric optimisation, no version > 10)
 * — just enough to encode a short ASCII URL reliably.
 *
 * Exposed as `window.HomefitQR`:
 *   - HomefitQR.toSvg(text, opts)   -> SVG string (recommended; crisp,
 *                                       tiny, theme-able fill colours)
 *   - HomefitQR.toMatrix(text, opts)-> boolean[][] (true = dark module)
 *
 * No inline scripts. No external dependencies.
 */
(function () {
  'use strict';

  // ---- Galois field (GF(256)) tables for Reed-Solomon -------------------
  var EXP = new Array(512);
  var LOG = new Array(256);
  (function initGF() {
    var x = 1;
    for (var i = 0; i < 255; i++) {
      EXP[i] = x;
      LOG[x] = i;
      x <<= 1;
      if (x & 0x100) x ^= 0x11d; // primitive polynomial
    }
    for (var j = 255; j < 512; j++) EXP[j] = EXP[j - 255];
  })();

  function gfMul(a, b) {
    if (a === 0 || b === 0) return 0;
    return EXP[LOG[a] + LOG[b]];
  }

  // Multiply two GF(256) polynomials (coefficients, highest degree first).
  function polyMul(a, b) {
    var res = new Array(a.length + b.length - 1).fill(0);
    for (var i = 0; i < a.length; i++) {
      for (var j = 0; j < b.length; j++) {
        res[i + j] ^= gfMul(a[i], b[j]);
      }
    }
    return res;
  }

  // Generator polynomial for `degree` EC codewords:
  //   g(x) = (x - α^0)(x - α^1)...(x - α^(degree-1))
  // Returns `degree + 1` coefficients, highest degree first (leading 1).
  function rsGeneratorPoly(degree) {
    var poly = [1];
    for (var d = 0; d < degree; d++) {
      poly = polyMul(poly, [1, EXP[d]]);
    }
    return poly;
  }

  // Polynomial long division remainder — the EC codewords. `gen` has
  // `ecLen + 1` coefficients; the remainder is the last `ecLen`.
  function rsEncode(data, ecLen) {
    var gen = rsGeneratorPoly(ecLen);
    // Working buffer = data followed by ecLen zeros.
    var buf = data.slice().concat(new Array(ecLen).fill(0));
    for (var i = 0; i < data.length; i++) {
      var coef = buf[i];
      if (coef !== 0) {
        for (var j = 0; j < gen.length; j++) {
          buf[i + j] ^= gfMul(gen[j], coef);
        }
      }
    }
    return buf.slice(data.length);
  }

  // ---- Capacity tables (byte-mode data codewords) for versions 1..10 ----
  // Indexed by [version-1]. Values per EC level (L, M, Q, H) are the
  // number of DATA codewords (total minus EC). Source: ISO/IEC 18004.
  var EC_LEVELS = { L: 0, M: 1, Q: 2, H: 3 };

  // Total codewords per version (1..10).
  var TOTAL_CODEWORDS = [26, 44, 70, 100, 134, 172, 196, 242, 292, 346];

  // EC codewords per block + block counts per version & level.
  // Each entry: [ecPerBlock, numBlocksGroup1, dataPerBlockGroup1,
  //               numBlocksGroup2, dataPerBlockGroup2]
  // Versions 1..10 × levels L,M,Q,H.
  var EC_TABLE = {
    L: [
      [7, 1, 19, 0, 0], [10, 1, 34, 0, 0], [15, 1, 55, 0, 0],
      [20, 1, 80, 0, 0], [26, 1, 108, 0, 0], [18, 2, 68, 0, 0],
      [20, 2, 78, 0, 0], [24, 2, 97, 0, 0], [30, 2, 116, 0, 0],
      [18, 2, 68, 2, 69]
    ],
    M: [
      [10, 1, 16, 0, 0], [16, 1, 28, 0, 0], [26, 1, 44, 0, 0],
      [18, 2, 32, 0, 0], [24, 2, 43, 0, 0], [16, 4, 27, 0, 0],
      [18, 4, 31, 0, 0], [22, 2, 38, 2, 39], [22, 3, 36, 2, 37],
      [26, 4, 43, 1, 44]
    ],
    Q: [
      [13, 1, 13, 0, 0], [22, 1, 22, 0, 0], [18, 2, 17, 0, 0],
      [26, 2, 24, 0, 0], [18, 2, 15, 2, 16], [24, 4, 19, 0, 0],
      [18, 2, 14, 4, 15], [22, 4, 18, 2, 19], [20, 4, 16, 4, 17],
      [24, 6, 19, 2, 20]
    ],
    H: [
      [17, 1, 9, 0, 0], [28, 1, 16, 0, 0], [22, 2, 13, 0, 0],
      [16, 4, 9, 0, 0], [22, 2, 11, 2, 12], [28, 4, 15, 0, 0],
      [26, 4, 13, 1, 14], [26, 4, 14, 2, 15], [24, 4, 12, 4, 13],
      [28, 6, 15, 2, 16]
    ]
  };

  function dataCapacityCodewords(version, level) {
    var t = EC_TABLE[level][version - 1];
    return t[1] * t[2] + t[3] * t[4];
  }

  // ---- Bit buffer -------------------------------------------------------
  function BitBuffer() { this.bits = []; }
  BitBuffer.prototype.put = function (num, len) {
    for (var i = len - 1; i >= 0; i--) this.bits.push((num >>> i) & 1);
  };
  BitBuffer.prototype.length = function () { return this.bits.length; };

  // ---- Encode the text as byte-mode data codewords ----------------------
  function utf8Bytes(text) {
    var out = [];
    for (var i = 0; i < text.length; i++) {
      var c = text.charCodeAt(i);
      if (c < 0x80) {
        out.push(c);
      } else if (c < 0x800) {
        out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
      } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.length) {
        var hi = c, lo = text.charCodeAt(++i);
        var cp = 0x10000 + ((hi - 0xd800) << 10) + (lo - 0xdc00);
        out.push(
          0xf0 | (cp >> 18),
          0x80 | ((cp >> 12) & 0x3f),
          0x80 | ((cp >> 6) & 0x3f),
          0x80 | (cp & 0x3f)
        );
      } else {
        out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
      }
    }
    return out;
  }

  function chooseVersion(byteLen, level) {
    for (var v = 1; v <= 10; v++) {
      // Byte-mode header: 4-bit mode + char-count indicator (8 bits for
      // v1..9, 16 bits for v10+). Plus the data bytes themselves.
      var ccBits = v <= 9 ? 8 : 16;
      var headerBits = 4 + ccBits;
      var availBits = dataCapacityCodewords(v, level) * 8;
      if (headerBits + byteLen * 8 <= availBits) return v;
    }
    return -1; // too long for v<=10
  }

  function buildDataCodewords(text, version, level) {
    var bytes = utf8Bytes(text);
    var buf = new BitBuffer();
    buf.put(0x4, 4); // byte mode
    var ccBits = version <= 9 ? 8 : 16;
    buf.put(bytes.length, ccBits);
    for (var i = 0; i < bytes.length; i++) buf.put(bytes[i], 8);

    var capCodewords = dataCapacityCodewords(version, level);
    var capBits = capCodewords * 8;

    // Terminator (up to 4 zero bits).
    var term = Math.min(4, capBits - buf.length());
    buf.put(0, term);

    // Pad to a byte boundary.
    while (buf.length() % 8 !== 0) buf.bits.push(0);

    // Convert to codewords.
    var codewords = [];
    for (var b = 0; b < buf.bits.length; b += 8) {
      var byte = 0;
      for (var k = 0; k < 8; k++) byte = (byte << 1) | buf.bits[b + k];
      codewords.push(byte);
    }

    // Pad codewords with the alternating 0xEC / 0x11 pattern.
    var padToggle = true;
    while (codewords.length < capCodewords) {
      codewords.push(padToggle ? 0xec : 0x11);
      padToggle = !padToggle;
    }
    return codewords;
  }

  // Interleave data + EC codewords across blocks (QR spec).
  function buildFinalCodewords(dataCodewords, version, level) {
    var t = EC_TABLE[level][version - 1];
    var ecPerBlock = t[0];
    var g1 = t[1], d1 = t[2], g2 = t[3], d2 = t[4];

    var blocks = [];
    var pos = 0;
    var i;
    for (i = 0; i < g1; i++) {
      blocks.push(dataCodewords.slice(pos, pos + d1));
      pos += d1;
    }
    for (i = 0; i < g2; i++) {
      blocks.push(dataCodewords.slice(pos, pos + d2));
      pos += d2;
    }

    var ecBlocks = blocks.map(function (blk) { return rsEncode(blk, ecPerBlock); });

    var result = [];
    var maxData = Math.max(d1, d2);
    var col;
    for (col = 0; col < maxData; col++) {
      for (i = 0; i < blocks.length; i++) {
        if (col < blocks[i].length) result.push(blocks[i][col]);
      }
    }
    for (col = 0; col < ecPerBlock; col++) {
      for (i = 0; i < ecBlocks.length; i++) {
        result.push(ecBlocks[i][col]);
      }
    }
    return result;
  }

  // ---- Matrix placement -------------------------------------------------
  function makeMatrix(size) {
    var m = [];
    for (var r = 0; r < size; r++) {
      m.push(new Array(size).fill(null)); // null = unset, true/false = module
    }
    return m;
  }

  function placeFinderPattern(m, row, col) {
    for (var r = -1; r <= 7; r++) {
      for (var c = -1; c <= 7; c++) {
        var rr = row + r, cc = col + c;
        if (rr < 0 || rr >= m.length || cc < 0 || cc >= m.length) continue;
        var isBorder = (r >= 0 && r <= 6 && (c === 0 || c === 6))
          || (c >= 0 && c <= 6 && (r === 0 || r === 6));
        var isCenter = r >= 2 && r <= 4 && c >= 2 && c <= 4;
        m[rr][cc] = isBorder || isCenter;
      }
    }
  }

  // Alignment-pattern centre coordinates for versions 1..10.
  var ALIGN_POS = {
    1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30],
    6: [6, 34], 7: [6, 22, 38], 8: [6, 24, 42], 9: [6, 26, 46], 10: [6, 28, 50]
  };

  function placeAlignmentPatterns(m, version) {
    var pos = ALIGN_POS[version] || [];
    for (var i = 0; i < pos.length; i++) {
      for (var j = 0; j < pos.length; j++) {
        var r = pos[i], c = pos[j];
        // Skip the three finder corners.
        if ((r === 6 && c === 6)
          || (r === 6 && c === pos[pos.length - 1])
          || (r === pos[pos.length - 1] && c === 6)) continue;
        for (var dr = -2; dr <= 2; dr++) {
          for (var dc = -2; dc <= 2; dc++) {
            var v = Math.max(Math.abs(dr), Math.abs(dc));
            m[r + dr][c + dc] = (v === 0 || v === 2);
          }
        }
      }
    }
  }

  function placeTimingPatterns(m) {
    var size = m.length;
    for (var i = 8; i < size - 8; i++) {
      if (m[6][i] === null) m[6][i] = (i % 2 === 0);
      if (m[i][6] === null) m[i][6] = (i % 2 === 0);
    }
  }

  function reserveFormatAreas(m) {
    var size = m.length;
    var reserved = [];
    for (var r = 0; r < size; r++) reserved.push(new Array(size).fill(false));
    // Around the top-left finder + along row/col 8.
    var i;
    for (i = 0; i <= 8; i++) {
      reserved[8][i] = true;
      reserved[i][8] = true;
    }
    for (i = 0; i < 8; i++) {
      reserved[8][size - 1 - i] = true;
      reserved[size - 1 - i][8] = true;
    }
    // Dark module.
    reserved[size - 8][8] = true;
    return reserved;
  }

  function placeData(m, reserved, codewords) {
    var size = m.length;
    var bitIdx = 0;
    var totalBits = codewords.length * 8;
    var getBit = function (idx) {
      if (idx >= totalBits) return 0;
      var byte = codewords[idx >> 3];
      return (byte >> (7 - (idx & 7))) & 1;
    };
    var col = size - 1;
    var upward = true;
    while (col > 0) {
      if (col === 6) col--; // skip the vertical timing column
      for (var i = 0; i < size; i++) {
        var row = upward ? (size - 1 - i) : i;
        for (var c = 0; c < 2; c++) {
          var cc = col - c;
          if (m[row][cc] !== null || reserved[row][cc]) continue;
          m[row][cc] = getBit(bitIdx) === 1;
          bitIdx++;
        }
      }
      col -= 2;
      upward = !upward;
    }
  }

  // Mask functions 0..7.
  function maskFn(id, r, c) {
    switch (id) {
      case 0: return (r + c) % 2 === 0;
      case 1: return r % 2 === 0;
      case 2: return c % 3 === 0;
      case 3: return (r + c) % 3 === 0;
      case 4: return (Math.floor(r / 2) + Math.floor(c / 3)) % 2 === 0;
      case 5: return ((r * c) % 2) + ((r * c) % 3) === 0;
      case 6: return (((r * c) % 2) + ((r * c) % 3)) % 2 === 0;
      case 7: return (((r + c) % 2) + ((r * c) % 3)) % 2 === 0;
      default: return false;
    }
  }

  function applyMask(m, reserved, maskId) {
    var size = m.length;
    var out = [];
    for (var r = 0; r < size; r++) {
      out.push(m[r].slice());
      for (var c = 0; c < size; c++) {
        if (reserved[r][c]) continue;
        if (m[r][c] === null) continue;
        if (maskFn(maskId, r, c)) out[r][c] = !out[r][c];
      }
    }
    return out;
  }

  // BCH-encoded format-info bits per (ec level, mask).
  function formatBits(level, maskId) {
    var ecBits = { L: 1, M: 0, Q: 3, H: 2 }[level];
    var data = (ecBits << 3) | maskId;
    var rem = data;
    for (var i = 0; i < 10; i++) {
      rem = (rem << 1);
      if (rem & 0x400) rem ^= 0x537;
    }
    var bits = ((data << 10) | rem) ^ 0x5412;
    return bits & 0x7fff;
  }

  function placeFormatInfo(m, level, maskId) {
    var size = m.length;
    var bits = formatBits(level, maskId);
    var get = function (i) { return (bits >> i) & 1; };
    // Top-left vertical + horizontal.
    var i;
    for (i = 0; i <= 5; i++) m[i][8] = get(i) === 1;
    m[7][8] = get(6) === 1;
    m[8][8] = get(7) === 1;
    m[8][7] = get(8) === 1;
    for (i = 9; i <= 14; i++) m[8][14 - i] = get(i) === 1;
    // Bottom-left + top-right.
    for (i = 0; i <= 7; i++) m[size - 1 - i][8] = get(i) === 1;
    for (i = 8; i <= 14; i++) m[8][size - 15 + i] = get(i) === 1;
    // Dark module.
    m[size - 8][8] = true;
  }

  // Penalty score for mask selection.
  function penalty(m) {
    var size = m.length;
    var score = 0;
    var r, c, run, i;
    // Rule 1: runs of 5+ same colour.
    for (r = 0; r < size; r++) {
      run = 1;
      for (c = 1; c < size; c++) {
        if (m[r][c] === m[r][c - 1]) { run++; } else { if (run >= 5) score += 3 + (run - 5); run = 1; }
      }
      if (run >= 5) score += 3 + (run - 5);
    }
    for (c = 0; c < size; c++) {
      run = 1;
      for (r = 1; r < size; r++) {
        if (m[r][c] === m[r - 1][c]) { run++; } else { if (run >= 5) score += 3 + (run - 5); run = 1; }
      }
      if (run >= 5) score += 3 + (run - 5);
    }
    // Rule 2: 2x2 blocks.
    for (r = 0; r < size - 1; r++) {
      for (c = 0; c < size - 1; c++) {
        var v = m[r][c];
        if (v === m[r][c + 1] && v === m[r + 1][c] && v === m[r + 1][c + 1]) score += 3;
      }
    }
    // Rule 4: dark proportion.
    var dark = 0;
    for (r = 0; r < size; r++) for (c = 0; c < size; c++) if (m[r][c]) dark++;
    var pct = (dark * 100) / (size * size);
    var prev = Math.floor(Math.abs(pct - 50) / 5);
    score += prev * 10;
    return score;
  }

  // ---- Public: build the module matrix ----------------------------------
  function toMatrix(text, opts) {
    opts = opts || {};
    var level = opts.ecLevel && EC_LEVELS.hasOwnProperty(opts.ecLevel)
      ? opts.ecLevel : 'M';
    var bytes = utf8Bytes(text);
    var version = chooseVersion(bytes.length, level);
    if (version < 0) {
      throw new Error('HomefitQR: text too long for version <= 10');
    }
    var size = 17 + version * 4;
    var dataCw = buildDataCodewords(text, version, level);
    var finalCw = buildFinalCodewords(dataCw, version, level);

    var base = makeMatrix(size);
    placeFinderPattern(base, 0, 0);
    placeFinderPattern(base, 0, size - 7);
    placeFinderPattern(base, size - 7, 0);
    placeAlignmentPatterns(base, version);
    placeTimingPatterns(base);

    // Function-module map: EVERY non-data module the mask + data pass must
    // leave untouched — finder patterns + separators, timing, alignment,
    // dark module, AND the reserved format-info areas. After the pattern
    // placements above, any non-null cell IS a function module; the
    // format areas are still null at this point so we OR them in
    // explicitly. (The original bug masked finder patterns because only
    // the format areas were excluded.)
    var formatReserved = reserveFormatAreas(base);
    var funcMap = [];
    for (var fr = 0; fr < size; fr++) {
      funcMap.push(new Array(size).fill(false));
      for (var fc = 0; fc < size; fc++) {
        funcMap[fr][fc] = (base[fr][fc] !== null) || formatReserved[fr][fc];
      }
    }

    placeData(base, funcMap, finalCw);

    // Pick the lowest-penalty mask.
    var best = null, bestScore = Infinity, bestMask = 0;
    for (var maskId = 0; maskId < 8; maskId++) {
      var masked = applyMask(base, funcMap, maskId);
      // Fill format-info area with this mask before scoring.
      placeFormatInfo(masked, level, maskId);
      var score = penalty(masked);
      if (score < bestScore) { bestScore = score; best = masked; bestMask = maskId; }
    }
    // Normalise any leftover nulls (timing/finder gaps already set) to false.
    for (var r = 0; r < size; r++) {
      for (var c = 0; c < size; c++) {
        if (best[r][c] === null) best[r][c] = false;
      }
    }
    return best;
  }

  // ---- Public: render an SVG string -------------------------------------
  function toSvg(text, opts) {
    opts = opts || {};
    var matrix = toMatrix(text, opts);
    var size = matrix.length;
    var quiet = opts.quietZone == null ? 2 : opts.quietZone;
    var dim = size + quiet * 2;
    var dark = opts.dark || '#0f1117';
    var light = opts.light || '#ffffff';

    var rects = '';
    for (var r = 0; r < size; r++) {
      // Merge consecutive dark modules in a row into one rect to keep the
      // SVG small.
      var c = 0;
      while (c < size) {
        if (matrix[r][c]) {
          var start = c;
          while (c < size && matrix[r][c]) c++;
          rects += '<rect x="' + (quiet + start) + '" y="' + (quiet + r)
            + '" width="' + (c - start) + '" height="1" fill="' + dark + '"/>';
        } else {
          c++;
        }
      }
    }

    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + dim + ' ' + dim
      + '" shape-rendering="crispEdges" role="img" aria-label="QR code">'
      + '<rect width="' + dim + '" height="' + dim + '" fill="' + light + '"/>'
      + rects
      + '</svg>';
  }

  window.HomefitQR = Object.freeze({
    toSvg: toSvg,
    toMatrix: toMatrix,
  });
})();
