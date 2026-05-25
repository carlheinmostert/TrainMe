#!/usr/bin/env python3
"""Generate the Safe Mode v2 video bench HTML report.

Auto-discovers .mp4 / .mov files in samples/ (excluding any prior
output suffixed `_safe.mp4`), invokes the SafeModeBench CLI with the
provided embedding(s), parses the stdout report, and renders a
side-by-side HTML at the destination path.

Usage:
  generate_video_report.py \
    --bench /Users/chm/dev/TrainMe/.../tools/safe-mode-v2-bench \
    --embedding samples/embedding.bin \
    --output "/Users/chm/Desktop/Safe Mode Bench Report.html" \
    [--threshold 0.55] \
    [--out-dir /tmp/safe_mode_v2_video_bench]

If no .mp4 / .mov files exist under samples/, the report renders a
placeholder block explaining how to drop in test clips. This makes
the generator safe to run from CI on a clean checkout.

The HTML embeds <video> elements with `controls` + `playsinline` so
Carl can scrub each pair. Originals are linked from the samples/
directory; safe variants from the out-dir. Both paths are written as
absolute file:// URLs so the report works offline.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional


# Lines of interest emitted by `swift run SafeModeBench --video`.
# Each entry is (regex, attribute_name, type). Names match
# SafeModeV2VideoBenchReport fields where reasonable.
LINE_PATTERNS = [
    (re.compile(r"^frames:\s+(\d+).*avg face count\s+([\d.]+)"), "frames_avg", "frames_avg"),
    (re.compile(r"^dimensions:\s+(\d+)x(\d+)"), "dimensions", "dims"),
    (re.compile(r"^duration:\s+([\d.]+)s @ ([\d.]+)fps"), "duration_fps", "duration_fps"),
    (re.compile(r"^subjectIdentified:\s+(\d+)\s+/\s+(\d+)\s+\(([\d.]+)%\)"), "identified", "identified"),
    (re.compile(r"^reConfirmEvents:\s+(\d+)"), "re_confirm", "int"),
    (re.compile(r"^reSeedEvents:\s+(\d+)"), "re_seed", "int"),
    (re.compile(r"^trackerLossEvents:\s+(\d+)"), "tracker_loss", "int"),
    (re.compile(r"^avgSubjectCosSim:\s+([-\d.]+)"), "avg_cos_sim", "float"),
    (re.compile(r"^safeMissRate:\s+([\d.]+)"), "miss_rate", "float"),
    (re.compile(r"^wallMs:\s+(\d+)"), "wall_ms", "int"),
    (re.compile(r"^realtimeRatio:\s+([\d.]+)x"), "realtime_ratio", "float"),
]


def parse_bench_stdout(stdout: str) -> dict:
    """Pull the stats lines out of the bench stdout. Anything we can't
    parse stays None so the HTML renders 'n/a'."""
    out: dict = {}
    for line in stdout.splitlines():
        line_stripped = line.strip()
        for pattern, key, kind in LINE_PATTERNS:
            m = pattern.match(line_stripped)
            if not m:
                continue
            if kind == "int":
                out[key] = int(m.group(1))
            elif kind == "float":
                out[key] = float(m.group(1))
            elif kind == "frames_avg":
                out["frames"] = int(m.group(1))
                out["avg_face_count"] = float(m.group(2))
            elif kind == "dims":
                out["width"] = int(m.group(1))
                out["height"] = int(m.group(2))
            elif kind == "duration_fps":
                out["duration_s"] = float(m.group(1))
                out["fps"] = float(m.group(2))
            elif kind == "identified":
                out["identified_frames"] = int(m.group(1))
                out["identified_total"] = int(m.group(2))
                out["identified_pct"] = float(m.group(3))
            break
    return out


def run_bench(
    bench_dir: Path,
    video_path: Path,
    embedding_path: Optional[Path],
    embeddings_csv: Optional[str],
    out_path: Path,
    threshold: float,
    seeding_frames: int,
    reconfirm_interval_sec: float,
    tracker_confidence_floor: float,
    reseed_radius_frac: float,
) -> tuple[dict, str, str]:
    """Invoke the bench CLI on a single clip. Returns (stats, stdout, stderr)."""
    out_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "swift", "run", "SafeModeBench",
        "--video", str(video_path),
        "--threshold", str(threshold),
        "--seeding-frames", str(seeding_frames),
        "--reconfirm-interval-sec", str(reconfirm_interval_sec),
        "--tracker-confidence-floor", str(tracker_confidence_floor),
        "--reseed-radius-frac", str(reseed_radius_frac),
        "--output", str(out_path),
    ]
    if embeddings_csv:
        cmd += ["--embeddings", embeddings_csv]
    elif embedding_path:
        cmd += ["--embedding", str(embedding_path)]
    else:
        raise ValueError("one of embedding_path or embeddings_csv is required")

    proc = subprocess.run(
        cmd,
        cwd=str(bench_dir),
        capture_output=True,
        text=True,
        check=False,
    )
    stdout = proc.stdout or ""
    stderr = proc.stderr or ""
    if proc.returncode != 0:
        print(f"WARN: bench returned exit {proc.returncode} for {video_path.name}", file=sys.stderr)
        print(stderr, file=sys.stderr)
        return {}, stdout, stderr
    stats = parse_bench_stdout(stdout)
    stats["exit_code"] = proc.returncode
    return stats, stdout, stderr


def fmt_int(v) -> str:
    return "n/a" if v is None else str(v)


def fmt_float(v, digits: int = 3) -> str:
    if v is None:
        return "n/a"
    return f"{float(v):.{digits}f}"


def render_html(
    clips: list[dict],
    embedding_path: Optional[Path],
    embeddings_csv: Optional[str],
    threshold: float,
    seeding_frames: int,
    reconfirm_interval_sec: float,
    tracker_confidence_floor: float,
    reseed_radius_frac: float,
    output_path: Path,
) -> None:
    """Build the side-by-side report HTML.

    Each clip dict has keys: name, src_url, safe_url, stats, stdout, stderr.
    """
    rows = []
    for i, c in enumerate(clips, start=1):
        s = c.get("stats") or {}
        identified_frac = s.get("identified_pct")
        miss_rate = s.get("miss_rate")
        avg_cos = s.get("avg_cos_sim")
        realtime = s.get("realtime_ratio")
        stats_table = f"""
        <table class="stats">
          <tr><th>frames</th><td>{fmt_int(s.get("frames"))}</td>
              <th>dimensions</th><td>{fmt_int(s.get("width"))}x{fmt_int(s.get("height"))}</td></tr>
          <tr><th>duration</th><td>{fmt_float(s.get("duration_s"), 2)}s</td>
              <th>fps</th><td>{fmt_float(s.get("fps"), 2)}</td></tr>
          <tr><th>subject identified</th>
              <td>{fmt_int(s.get("identified_frames"))} / {fmt_int(s.get("identified_total"))} ({fmt_float(identified_frac, 1)}%)</td>
              <th>avg face count</th><td>{fmt_float(s.get("avg_face_count"), 2)}</td></tr>
          <tr><th>re-confirm events</th><td>{fmt_int(s.get("re_confirm"))}</td>
              <th>re-seed events</th><td>{fmt_int(s.get("re_seed"))}</td></tr>
          <tr><th>tracker-loss events</th><td>{fmt_int(s.get("tracker_loss"))}</td>
              <th>avg subject cosSim</th><td>{fmt_float(avg_cos, 4)}</td></tr>
          <tr><th>safe miss rate</th><td>{fmt_float(miss_rate, 4)}</td>
              <th>realtime ratio</th><td>{fmt_float(realtime, 2)}x</td></tr>
          <tr><th colspan="2">wall ms</th><td colspan="2">{fmt_int(s.get("wall_ms"))}</td></tr>
        </table>
        """
        row = f"""
        <section class="clip">
          <h2>{i}. {c["name"]}</h2>
          <div class="videos">
            <div class="video-pair">
              <h3>original</h3>
              <video src="{c["src_url"]}" controls preload="metadata" playsinline></video>
              <div class="path">{c["src_path"]}</div>
            </div>
            <div class="video-pair">
              <h3>safe variant</h3>
              <video src="{c["safe_url"]}" controls preload="metadata" playsinline></video>
              <div class="path">{c["safe_path"]}</div>
            </div>
          </div>
          {stats_table}
          <details>
            <summary>bench stdout</summary>
            <pre>{(c.get("stdout") or "").replace("<", "&lt;")}</pre>
          </details>
          {"<details><summary>bench stderr</summary><pre>" + (c.get("stderr") or "").replace("<", "&lt;") + "</pre></details>" if c.get("stderr") else ""}
        </section>
        """
        rows.append(row)

    if not clips:
        rows = [
            """
        <section class="empty">
          <h2>No clips found.</h2>
          <p>Drop test videos into <code>tools/safe-mode-v2-bench/samples/</code>
          (any <code>.mp4</code> or <code>.mov</code>) and re-run this script. Recommended
          scenarios per <code>docs/specs/2026-05-25-safe-mode-v2-video.md</code> &sect;7:</p>
          <ol>
            <li>Solo subject, no bystanders (baseline lock).</li>
            <li>Bystander walks past, closer to camera than subject.</li>
            <li>Subject crosses paths with a bystander.</li>
            <li>First-frame fail: subject's back to camera for 4s, then turns around.</li>
            <li>Mid-video occlusion: subject walks behind something for ~1s.</li>
          </ol>
          <p>Once samples are present, re-run with:</p>
          <pre>python3 tools/safe-mode-v2-bench/generate_video_report.py \\
  --bench tools/safe-mode-v2-bench \\
  --embedding tools/safe-mode-v2-bench/samples/embedding.bin \\
  --output "/Users/chm/Desktop/Safe Mode Bench Report.html"</pre>
        </section>
        """
        ]

    embedding_summary: str
    if embeddings_csv:
        items = embeddings_csv.split(",")
        embedding_summary = f"<code>--embeddings</code> ({len(items)} references): " + ", ".join(
            f"<code>{e}</code>" for e in items
        )
    elif embedding_path:
        embedding_summary = f"<code>--embedding</code>: <code>{embedding_path}</code>"
    else:
        embedding_summary = "<em>(none — placeholder report)</em>"

    html = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Safe Mode v2 Video Bench Report</title>
<style>
  :root {{
    --coral: #FF6B35;
    --bg: #0F1117;
    --surface: #161A22;
    --border: #2A2F3A;
    --text: #E5E7EB;
    --text-dim: #94A3B8;
    --sage: #86EFAC;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    background: var(--bg);
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    margin: 0;
    padding: 24px 32px;
    line-height: 1.5;
  }}
  h1 {{
    color: var(--coral);
    margin: 0 0 4px;
    font-weight: 700;
  }}
  h2 {{
    color: var(--coral);
    margin-top: 32px;
    font-weight: 600;
    border-bottom: 1px solid var(--border);
    padding-bottom: 8px;
  }}
  h3 {{
    color: var(--sage);
    font-size: 14px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    margin: 0 0 8px;
  }}
  .meta {{
    color: var(--text-dim);
    font-size: 13px;
    margin-bottom: 24px;
  }}
  .params {{
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 12px 16px;
    margin-bottom: 24px;
    font-size: 13px;
  }}
  .params dt {{ color: var(--text-dim); float: left; clear: left; width: 200px; }}
  .params dd {{ margin: 0 0 4px 200px; color: var(--text); }}
  .clip {{
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 16px 20px;
    margin-bottom: 24px;
  }}
  .empty {{
    background: var(--surface);
    border: 1px solid var(--coral);
    border-radius: 12px;
    padding: 24px;
  }}
  .empty h2 {{ border-bottom: none; padding-bottom: 0; margin-top: 0; }}
  .videos {{
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 16px;
    margin: 12px 0 16px;
  }}
  video {{
    width: 100%;
    border-radius: 6px;
    background: black;
    aspect-ratio: 16 / 9;
    object-fit: contain;
  }}
  .path {{
    font-family: monospace;
    font-size: 11px;
    color: var(--text-dim);
    margin-top: 4px;
    word-break: break-all;
  }}
  table.stats {{
    width: 100%;
    border-collapse: collapse;
    font-size: 13px;
  }}
  table.stats th, table.stats td {{
    border: 1px solid var(--border);
    padding: 6px 10px;
    text-align: left;
  }}
  table.stats th {{
    color: var(--text-dim);
    font-weight: 500;
    background: var(--bg);
    width: 25%;
  }}
  details {{
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 8px 12px;
    margin-top: 12px;
  }}
  details summary {{
    cursor: pointer;
    font-size: 12px;
    color: var(--text-dim);
  }}
  details pre {{
    font-size: 11px;
    overflow: auto;
    background: black;
    padding: 8px;
    border-radius: 4px;
    color: var(--sage);
  }}
  code {{
    background: var(--bg);
    border: 1px solid var(--border);
    padding: 1px 6px;
    border-radius: 3px;
    font-size: 12px;
  }}
  pre {{
    background: var(--bg);
    border: 1px solid var(--border);
    padding: 12px;
    border-radius: 6px;
    overflow: auto;
    font-size: 12px;
    line-height: 1.4;
  }}
</style>
</head>
<body>
  <h1>Safe Mode v2 video — bench report</h1>
  <div class="meta">
    Generated {time.strftime("%Y-%m-%d %H:%M:%S")}.
    Spec: <code>docs/specs/2026-05-25-safe-mode-v2-video.md</code>.
    Pipeline mirror: <code>tools/safe-mode-v2-bench/Sources/SafeModeBench/SafeModeV2VideoPipeline.swift</code>.
  </div>
  <div class="params">
    <dl>
      <dt>references</dt><dd>{embedding_summary}</dd>
      <dt>threshold (solo floor)</dt><dd>{threshold}</dd>
      <dt>seeding frames</dt><dd>{seeding_frames}</dd>
      <dt>re-confirm interval</dt><dd>{reconfirm_interval_sec}s</dd>
      <dt>tracker confidence floor</dt><dd>{tracker_confidence_floor}</dd>
      <dt>re-seed proximity radius</dt><dd>{reseed_radius_frac} of frame height</dd>
    </dl>
  </div>
  {''.join(rows)}
</body>
</html>
"""
    output_path.write_text(html, encoding="utf-8")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bench", required=True, help="Path to the safe-mode-v2-bench directory.")
    parser.add_argument("--embedding", help="Single reference embedding path (back-compat).")
    parser.add_argument("--embeddings", help="Comma-separated list of 1-8 reference embedding paths.")
    parser.add_argument("--output", required=True, help="HTML report destination.")
    parser.add_argument("--samples-dir", help="Override the samples directory (defaults to <bench>/samples).")
    parser.add_argument("--out-dir", default="/tmp/safe_mode_v2_video_bench", help="Where to write safe-variant mp4s.")
    parser.add_argument("--threshold", type=float, default=0.55)
    parser.add_argument("--seeding-frames", type=int, default=3)
    parser.add_argument("--reconfirm-interval-sec", type=float, default=2.0)
    parser.add_argument("--tracker-confidence-floor", type=float, default=0.5)
    parser.add_argument("--reseed-radius-frac", type=float, default=0.2)
    parser.add_argument(
        "--skip-bench", action="store_true",
        help="Skip running the bench; assume safe variants already exist in --out-dir. Use for re-rendering the report.",
    )
    args = parser.parse_args(argv)

    bench_dir = Path(args.bench).resolve()
    samples_dir = Path(args.samples_dir).resolve() if args.samples_dir else bench_dir / "samples"
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    output_path = Path(args.output).resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    if not samples_dir.is_dir():
        print(f"error: samples dir {samples_dir} does not exist", file=sys.stderr)
        return 2

    embedding_path: Optional[Path] = Path(args.embedding).resolve() if args.embedding else None
    embeddings_csv: Optional[str] = args.embeddings

    if embedding_path is None and embeddings_csv is None:
        # Empty-state placeholder report.
        render_html(
            clips=[],
            embedding_path=None,
            embeddings_csv=None,
            threshold=args.threshold,
            seeding_frames=args.seeding_frames,
            reconfirm_interval_sec=args.reconfirm_interval_sec,
            tracker_confidence_floor=args.tracker_confidence_floor,
            reseed_radius_frac=args.reseed_radius_frac,
            output_path=output_path,
        )
        print(f"Wrote placeholder report (no embedding) to {output_path}")
        return 0

    video_paths = sorted(
        [p for p in samples_dir.iterdir()
         if p.suffix.lower() in (".mp4", ".mov")
         and not p.name.endswith("_safe.mp4")
         and not p.name.endswith("_safe.mov")]
    )

    clips: list[dict] = []
    for video_path in video_paths:
        basename = video_path.stem
        safe_path = out_dir / f"{basename}_safe.mp4"
        print(f"Processing {video_path.name} -> {safe_path}")
        if args.skip_bench and safe_path.exists():
            stats, stdout, stderr = {}, "(skip-bench: stats not captured)", ""
        else:
            stats, stdout, stderr = run_bench(
                bench_dir=bench_dir,
                video_path=video_path,
                embedding_path=embedding_path,
                embeddings_csv=embeddings_csv,
                out_path=safe_path,
                threshold=args.threshold,
                seeding_frames=args.seeding_frames,
                reconfirm_interval_sec=args.reconfirm_interval_sec,
                tracker_confidence_floor=args.tracker_confidence_floor,
                reseed_radius_frac=args.reseed_radius_frac,
            )
        clips.append({
            "name": video_path.name,
            "src_path": str(video_path),
            "src_url": video_path.as_uri(),
            "safe_path": str(safe_path),
            "safe_url": safe_path.as_uri() if safe_path.exists() else "about:blank",
            "stats": stats,
            "stdout": stdout,
            "stderr": stderr,
        })

    render_html(
        clips=clips,
        embedding_path=embedding_path,
        embeddings_csv=embeddings_csv,
        threshold=args.threshold,
        seeding_frames=args.seeding_frames,
        reconfirm_interval_sec=args.reconfirm_interval_sec,
        tracker_confidence_floor=args.tracker_confidence_floor,
        reseed_radius_frac=args.reseed_radius_frac,
        output_path=output_path,
    )
    print(f"Wrote report to {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
