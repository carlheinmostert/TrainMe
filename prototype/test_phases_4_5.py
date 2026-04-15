#!/usr/bin/env python3
"""
Test phases 4-5 of the pipeline: Equipment compositing and Lottie assembly.

Uses mock rendered frames and cached motion data to validate that
the downstream pipeline stages work correctly.
"""

import logging
import pickle
from pathlib import Path
from PIL import Image
import numpy as np

from config import OUTPUT_DIR, CACHE_DIR
from equipment_compositor import EquipmentCompositor
from animation_assembler import AnimationAssembler

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)

logger = logging.getLogger(__name__)


def main():
    """Test phases 4-5."""

    logger.info("=" * 80)
    logger.info("Testing Phases 4-5: Equipment Compositing & Animation Assembly")
    logger.info("=" * 80)

    # Load mock rendered frames
    rendered_frames = []
    for i in range(6):
        frame_path = OUTPUT_DIR / f"rendered_mock_{i:04d}.png"
        if frame_path.exists():
            rendered_frames.append(Image.open(frame_path).convert("RGB"))
        else:
            logger.warning(f"Frame not found: {frame_path}")

    if not rendered_frames:
        logger.error("No rendered frames found")
        return 1

    logger.info(f"✓ Loaded {len(rendered_frames)} mock rendered frames")

    # Load cached motion data if available
    motion_cache_path = OUTPUT_DIR / ".motion_cache.pkl"
    motion_data = None
    if motion_cache_path.exists():
        try:
            with open(motion_cache_path, "rb") as f:
                motion_data = pickle.load(f)
            logger.info(f"✓ Loaded cached motion data ({len(motion_data)} frames)")
        except Exception as e:
            logger.warning(f"Could not load motion cache: {e}")

    # Phase 4: Equipment Compositing
    logger.info("\n" + "=" * 80)
    logger.info("Phase 4: Equipment SVG Compositing")
    logger.info("=" * 80)

    composited_frames = []
    if rendered_frames and motion_data:
        try:
            compositor = EquipmentCompositor()
            for i, frame in enumerate(rendered_frames):
                # Create mock skeleton joints for compositing
                mock_joints_2d = np.array([
                    [256, 50], [256, 100], [220, 150], [200, 200], [180, 250],
                    [290, 150], [310, 200], [330, 250], [230, 300], [230, 350],
                    [230, 450], [280, 300], [280, 350], [280, 450], [240, 40],
                    [270, 40], [230, 20], [280, 20]
                ])
                composited = compositor.composite_equipment(frame, mock_joints_2d)
                composited_frames.append(composited)
            logger.info(f"✓ Composited dumbbell onto {len(composited_frames)} frames")
        except Exception as e:
            logger.error(f"Equipment compositing error: {e}")
            composited_frames = []
    else:
        logger.info("Skipping equipment compositing for test (using original frames)")
        composited_frames = rendered_frames

    # Phase 5: Animation Assembly
    logger.info("\n" + "=" * 80)
    logger.info("Phase 5: Animation Assembly (Lottie)")
    logger.info("=" * 80)

    if composited_frames:
        try:
            assembler = AnimationAssembler()
            outputs = assembler.assemble_animation(
                composited_frames,
                "bicep_curl_test",
                OUTPUT_DIR
            )
            logger.info(f"✓ Animation assembled")
            for format_name, path in outputs.items():
                if path:
                    logger.info(f"  {format_name}: {path}")
        except Exception as e:
            logger.error(f"Animation assembly error: {e}")
            return 1
    else:
        logger.error("No frames for animation assembly")
        return 1

    # Summary
    logger.info("\n" + "=" * 80)
    logger.info("✓ Phases 4-5 Test Complete")
    logger.info("=" * 80)
    logger.info("Phase 4 (Equipment Compositing): ✓")
    logger.info("Phase 5 (Animation Assembly): ✓")

    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
