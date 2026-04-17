"""Streamlit UI for the homefit.studio filter workbench.

Run it with::

    cd tools/filter-workbench
    streamlit run workbench_ui.py

The page is structured so Carl can sit down, pick a published plan,
flick through exercise videos, and tweak filter parameters with live
feedback that matches what his clients see on the web player
(body-crisp + equipment-dimmed two-zone render).

Three panels:

- **Sidebar** — published plan dropdown, video-exercise dropdown, frame
  slider (0..29 across the clip).
- **Main, top** — filter-algorithm dropdown reading from the
  :data:`filters.FILTERS` registry + dynamically-generated sliders from
  the selected filter's ``params_schema``, plus the universal
  segmentation toggle and background-dim slider.
- **Main, middle** — side-by-side original / filtered preview.
- **Main, bottom** — "Copy parameters" button that dumps a Dart snippet
  ready to paste into ``app/lib/config.dart``.

All heavy work (Supabase fetch, video download, frame extract) is
cached by Streamlit's built-in decorators so slider tweaks re-render
in milliseconds.
"""

from __future__ import annotations

import traceback
from pathlib import Path
from typing import Any

import cv2
import numpy as np
import streamlit as st

from filters import FILTERS, BaseFilter, ParamSpec, filter_by_name
import segmentation
import supabase_client
from frame_extractor import ExtractedFrame, extract_frames

PAGE_TITLE = "homefit.studio — Filter Workbench"
ACCENT = "#FF6B35"  # coral orange brand accent
DEFAULT_FRAME_COUNT = 30


# ---------------------------------------------------------------------------
# Cached data loaders
# ---------------------------------------------------------------------------


@st.cache_data(show_spinner="Fetching published plans from Supabase…")
def load_plans() -> list[supabase_client.Plan]:
    return supabase_client.fetch_published_plans()


@st.cache_data(show_spinner="Downloading video…")
def load_video(exercise_id: str, media_url: str) -> str:
    exercise = supabase_client.Exercise(
        id=exercise_id,
        plan_id="",
        name=None,
        media_url=media_url,
        media_type="video",
        position=0,
    )
    return str(supabase_client.download_video(exercise))


@st.cache_data(show_spinner="Extracting frames…")
def load_frames(video_path: str, exercise_id: str, count: int) -> list[dict[str, Any]]:
    frames = extract_frames(Path(video_path), exercise_id, count=count)
    # Dataclasses don't serialise through Streamlit's cache cleanly,
    # so convert to plain dicts.
    return [
        {"index": f.index, "source_frame": f.source_frame, "path": str(f.path)}
        for f in frames
    ]


# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------


def _force_odd(value: int) -> int:
    value = max(1, int(value))
    return value if value % 2 == 1 else value + 1


def render_param_widget(
    name: str, spec: ParamSpec, key_prefix: str
) -> Any:
    """Render a Streamlit widget for a single :class:`ParamSpec`."""
    key = f"{key_prefix}:{name}"
    label = name.replace("_", " ").title()
    help_text = spec.description or None

    if spec.kind == "bool":
        return st.checkbox(label, value=bool(spec.default), key=key, help=help_text)

    if spec.kind == "float":
        return st.slider(
            label,
            min_value=float(spec.min),
            max_value=float(spec.max),
            value=float(spec.default),
            step=float(spec.step),
            key=key,
            help=help_text,
        )

    # default: integer slider
    value = st.slider(
        label,
        min_value=int(spec.min),
        max_value=int(spec.max),
        value=int(spec.default),
        step=int(spec.step),
        key=key,
        help=help_text,
    )
    if spec.odd_only:
        return _force_odd(int(value))
    return int(value)


def dart_snippet(filter_obj: BaseFilter, params: dict[str, Any]) -> str:
    """Format current params as a Dart snippet for app/lib/config.dart.

    Only emits keys that map onto production AppConfig fields. For the
    pencil-sketch filter that's ``blur_kernel`` / ``threshold_block`` /
    ``contrast_low``. Other filters fall back to a generic comment
    block.
    """
    dart_map = {
        "blur_kernel": "blurKernel",
        "threshold_block": "thresholdBlock",
        "contrast_low": "contrastLow",
    }
    lines = [f"// Filter: {filter_obj.name}"]
    shipped = False
    for py_name, dart_name in dart_map.items():
        if py_name in params:
            lines.append(f"static const int {dart_name} = {int(params[py_name])};")
            shipped = True
    if not shipped:
        lines.append("// (no production mapping for these params yet)")
        for k, v in params.items():
            lines.append(f"// {k}: {v!r}")
    return "\n".join(lines)


def to_rgb(bgr: np.ndarray) -> np.ndarray:
    return cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)


def gray_to_rgb(gray: np.ndarray) -> np.ndarray:
    return cv2.cvtColor(gray, cv2.COLOR_GRAY2RGB)


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------


def main() -> None:
    st.set_page_config(
        page_title=PAGE_TITLE,
        page_icon="•",
        layout="wide",
    )

    st.markdown(
        f"""
        <style>
        .accent {{ color: {ACCENT}; }}
        .plan-id {{ opacity: 0.55; font-size: 0.75em; }}
        </style>
        """,
        unsafe_allow_html=True,
    )
    st.title(PAGE_TITLE)
    st.caption(
        "Tune on-device line-drawing filters against real published "
        "exercise clips. Body stays crisp, background dims — matches the "
        "on-device two-zone render."
    )

    # ---- Sidebar: data source ------------------------------------------
    st.sidebar.header("Source")
    try:
        plans = load_plans()
    except Exception as exc:  # noqa: BLE001 - show any error to the user
        st.sidebar.error(f"Failed to fetch plans: {exc}")
        st.stop()
        return

    plans_with_video = [p for p in plans if p.video_exercises()]
    if not plans_with_video:
        st.sidebar.warning("No published plans with video exercises found.")
        st.stop()
        return

    plan_labels = {p.id: p.label for p in plans_with_video}
    selected_plan_id = st.sidebar.selectbox(
        "Published plan",
        options=[p.id for p in plans_with_video],
        format_func=lambda pid: plan_labels[pid],
    )
    selected_plan = next(p for p in plans_with_video if p.id == selected_plan_id)
    st.sidebar.markdown(
        f"<div class='plan-id'>{selected_plan.id}</div>",
        unsafe_allow_html=True,
    )

    video_exercises = selected_plan.video_exercises()
    exercise_labels = {
        e.id: f"#{e.position + 1} · {e.name or '(unnamed)'}" for e in video_exercises
    }
    selected_exercise_id = st.sidebar.selectbox(
        "Video exercise",
        options=[e.id for e in video_exercises],
        format_func=lambda eid: exercise_labels[eid],
    )
    selected_exercise = next(e for e in video_exercises if e.id == selected_exercise_id)

    # Pull + cache the video, then extract frames.
    try:
        video_path = load_video(selected_exercise.id, selected_exercise.media_url or "")
        frames_raw = load_frames(
            video_path, selected_exercise.id, DEFAULT_FRAME_COUNT
        )
    except Exception as exc:  # noqa: BLE001
        st.sidebar.error(f"Failed to load video/frames: {exc}")
        st.stop()
        return

    frames = [
        ExtractedFrame(
            index=f["index"],
            source_frame=f["source_frame"],
            path=Path(f["path"]),
        )
        for f in frames_raw
    ]

    frame_idx = st.sidebar.slider(
        "Frame",
        min_value=0,
        max_value=len(frames) - 1,
        value=len(frames) // 2,
        step=1,
        help=f"{len(frames)} evenly-spaced frames across the clip.",
    )
    current_frame = frames[frame_idx]

    # ---- Main: filter selection + sliders -----------------------------
    st.subheader("Filter")
    filter_names = [f.name for f in FILTERS]
    selected_filter_name = st.selectbox("Algorithm", options=filter_names)
    selected_filter = filter_by_name(selected_filter_name)
    if selected_filter.description:
        st.caption(selected_filter.description)

    col_params, col_seg = st.columns([2, 1])
    with col_params:
        st.markdown("**Filter parameters**")
        params: dict[str, Any] = {}
        for name, spec in selected_filter.params_schema.items():
            params[name] = render_param_widget(
                name, spec, key_prefix=f"filter:{selected_filter.name}"
            )
    with col_seg:
        st.markdown("**Segmentation (two-zone render)**")
        use_seg = st.checkbox(
            "Use segmentation",
            value=True,
            help=(
                "Mirrors the on-device render: body pixels full strength, "
                "background dimmed."
            ),
        )
        background_strength = st.slider(
            "Background dim strength",
            min_value=0.0,
            max_value=1.0,
            value=0.35,
            step=0.05,
            help=(
                "0.0 = solid white background, 1.0 = no dimming. "
                "0.35 matches the on-device default."
            ),
        )

    # ---- Run pipeline on the selected frame ---------------------------
    bgr = cv2.imread(str(current_frame.path), cv2.IMREAD_COLOR)
    if bgr is None:
        st.error(f"Failed to read cached frame: {current_frame.path}")
        st.stop()
        return
    rgb = to_rgb(bgr)
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)

    try:
        filtered_gray = selected_filter.apply(gray, params)
    except Exception as exc:  # noqa: BLE001
        st.error(f"Filter failed: {exc}")
        st.text(traceback.format_exc())
        st.stop()
        return

    if use_seg:
        try:
            mask = segmentation.get_mask(rgb)
            output_gray = segmentation.composite_two_zone(
                filtered_gray, mask, background_strength=background_strength
            )
        except RuntimeError as exc:
            st.warning(
                f"Segmentation unavailable: {exc}. Falling back to raw filter output."
            )
            output_gray = filtered_gray
        except Exception as exc:  # noqa: BLE001
            st.error(f"Segmentation failed: {exc}")
            st.text(traceback.format_exc())
            output_gray = filtered_gray
    else:
        output_gray = filtered_gray

    # ---- Side-by-side preview -----------------------------------------
    st.markdown("---")
    left, right = st.columns(2)
    with left:
        st.markdown("**Original**")
        st.image(rgb, width="stretch")
    with right:
        caption = "**Filtered** (two-zone)" if use_seg else "**Filtered** (raw)"
        st.markdown(caption)
        st.image(gray_to_rgb(output_gray), width="stretch")

    # ---- Copy parameters ----------------------------------------------
    st.markdown("---")
    snippet = dart_snippet(selected_filter, params)
    st.markdown("**Copy parameters for `app/lib/config.dart`**")
    st.code(snippet, language="dart")
    st.caption(
        "Streamlit does not expose a native clipboard API — select the "
        "snippet above and copy (Cmd+C)."
    )


if __name__ == "__main__":
    main()
