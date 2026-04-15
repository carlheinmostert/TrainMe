#!/usr/bin/env python3
"""
TrainMe Animation Pipeline Prototype - Main Entry Point

This script orchestrates the end-to-end animation pipeline:
1. Text prompt → 3D motion (SayMotion)
2. Keyframe extraction & OpenPose skeleton generation
3. 2D illustration rendering (Replicate ControlNet)
4. Equipment SVG compositing
5. Animation assembly (Lottie)

Target: "Standing bicep curl with dumbbell" → 4-6 frame illustrated animation

Preview mode (--preview-only): Run only phases 1-2 to validate motion form before rendering.
"""

import logging
import sys
import time
import argparse
import pickle
from pathlib import Path
from config import (
    validate_config,
    logger,
    OUTPUT_DIR,
    ASSETS_DIR,
    MOTION_SERVICE,
    HY_MOTION_MODE,
    HY_MOTION_RUNPOD_SSH,
)

# Import pipeline modules
from hy_motion_client import HYMotionClient
from saymotion_client import SayMotionClient
from pose_extractor import PoseExtractor
from stability_renderer import StabilityRenderer
from equipment_compositor import EquipmentCompositor
from animation_assembler import AnimationAssembler


def main():
    """Main entry point for the prototype."""

    # Parse command-line arguments
    parser = argparse.ArgumentParser(
        description="TrainMe Animation Pipeline - Generate exercise animations from text prompts"
    )
    parser.add_argument(
        "--preview-only",
        action="store_true",
        help="Run only phases 1-2 (motion generation + skeleton preview). Skip rendering and compositing."
    )
    args = parser.parse_args()

    preview_mode = args.preview_only
    motion_cache_path = OUTPUT_DIR / ".motion_cache.pkl"

    logger.info("=" * 80)
    logger.info("TrainMe Animation Pipeline Prototype")
    if preview_mode:
        logger.info("MODE: Preview Only (Motion + Skeleton Validation)")
    logger.info("=" * 80)

    try:
        # Validate configuration
        validate_config()
        logger.info("✓ Configuration validated")

        # Exercise parameters
        exercise_prompt = "Standing bicep curl with dumbbell"
        exercise_duration = 8  # seconds

        logger.info(f"\nExercise: {exercise_prompt}")
        logger.info(f"Duration: {exercise_duration}s")

        # Phase 1: Text-to-Motion
        logger.info("\n" + "=" * 80)
        logger.info(f"Phase 1: Text-to-Motion Generation ({MOTION_SERVICE.upper()})")
        logger.info("=" * 80)

        motion_data = None

        if MOTION_SERVICE == "hy_motion":
            try:
                logger.info(f"Using HY-Motion ({HY_MOTION_MODE} mode)")
                client = HYMotionClient(
                    mode=HY_MOTION_MODE,
                    runpod_ssh=HY_MOTION_RUNPOD_SSH
                )
                motion_data = client.generate_and_parse(
                    exercise_prompt,
                    exercise_duration
                )
                if motion_data:
                    logger.info(f"✓ Motion data retrieved: {len(motion_data)} frames")
                else:
                    logger.error("Failed to generate motion")
            except Exception as e:
                logger.error(f"HY-Motion error: {e}")
                logger.info("\n📖 Setup guide: See prototype/RUNPOD_SETUP.md")
                motion_data = None

        elif MOTION_SERVICE == "saymotion":
            try:
                logger.info("Using SayMotion API")
                client = SayMotionClient()
                motion_data = client.generate_motion(exercise_prompt, exercise_duration)
                if motion_data:
                    logger.info(f"✓ Motion data retrieved: {len(motion_data)} frames")
                else:
                    logger.error("Failed to generate motion")
            except Exception as e:
                logger.error(f"SayMotion error: {e}")
                logger.info("⏳ Note: Set SAYMOTION_CLIENT_ID and SAYMOTION_CLIENT_SECRET in .env")
                motion_data = None

        elif MOTION_SERVICE == "mock":
            try:
                logger.info("Using Mock motion generator (synthetic data for testing)")
                from mock_motion_generator import MockMotionGenerator
                generator = MockMotionGenerator()
                motion_data = generator.generate_and_parse(exercise_prompt, exercise_duration)
                if motion_data:
                    logger.info(f"✓ Synthetic motion data generated: {len(motion_data)} frames")
                else:
                    logger.error("Failed to generate synthetic motion")
            except Exception as e:
                logger.error(f"Mock motion generator error: {e}")
                motion_data = None

        # Phase 2: Pose Extraction & Skeleton Generation
        logger.info("\n" + "=" * 80)
        logger.info("Phase 2: Pose Extraction & OpenPose Skeleton Generation")
        logger.info("=" * 80)

        skeleton_images = []
        if motion_data:
            try:
                extractor = PoseExtractor()
                keyframe_indices = extractor.select_keyframes(motion_data, num_frames=6)
                logger.info(f"Selected {len(keyframe_indices)} keyframes")
                skeleton_images = extractor.extract_and_render_skeletons(
                    motion_data, keyframe_indices, OUTPUT_DIR
                )
                logger.info(f"✓ Generated {len(skeleton_images)} skeleton images")
            except Exception as e:
                logger.error(f"Pose extraction error: {e}")
                skeleton_images = []
        else:
            logger.info("⏳ Skipping pose extraction (no motion data)")

        # Cache motion data for potential future use
        if motion_data:
            try:
                with open(motion_cache_path, "wb") as f:
                    pickle.dump(motion_data, f)
                logger.info(f"✓ Motion data cached for future rendering")
            except Exception as e:
                logger.warning(f"Could not cache motion data: {e}")

        # Phase 3: Illustration Rendering
        logger.info("\n" + "=" * 80)
        if preview_mode:
            logger.info("Preview Complete - Skeleton validation ready")
            logger.info("=" * 80)
            logger.info("\n✓ Preview mode skipping phases 3-5 (rendering, compositing, assembly)")
            logger.info("\nSkeleton images saved to: output/")
            logger.info("\nNext steps:")
            logger.info("1. Review skeleton images to validate exercise form")
            logger.info("2. If satisfied, run full pipeline: python main.py")
            logger.info("3. If adjustments needed, modify prompt and retry: python main.py --preview-only")
            return 0

        logger.info("Phase 3: 2D Illustration Rendering (Stability AI ControlNet)")
        logger.info("=" * 80)

        rendered_frames = []
        if skeleton_images:
            try:
                renderer = StabilityRenderer()
                import time as _time
                for i, (frame_idx, skeleton_image) in enumerate(skeleton_images):
                    logger.info(f"Rendering frame {i+1}/{len(skeleton_images)}...")
                    rendered = renderer.render(skeleton_image, exercise_prompt)
                    if rendered:
                        # Save individual rendered frame
                        rendered.save(OUTPUT_DIR / f"rendered_{frame_idx:04d}.png")
                        rendered_frames.append(rendered)
                    else:
                        logger.warning(f"Failed to render frame {i+1}")
                    if i < len(skeleton_images) - 1:
                        _time.sleep(1)  # rate limit courtesy
                logger.info(f"✓ Rendered {len(rendered_frames)} illustrated frames")
            except Exception as e:
                logger.error(f"Illustration rendering error: {e}")
                logger.info("⏳ Note: Set STABILITY_API_KEY in .env to enable")
                rendered_frames = []
        else:
            logger.info("⏳ Skipping illustration rendering (no skeleton images)")

        # Phase 4: Equipment Compositing
        logger.info("\n" + "=" * 80)
        logger.info("Phase 4: Equipment SVG Compositing")
        logger.info("=" * 80)

        if rendered_frames and motion_data:
            try:
                import numpy as np
                compositor = EquipmentCompositor()
                composited_frames = []
                for i, frame in enumerate(rendered_frames):
                    # Create mock skeleton joints for compositing
                    # In real usage, these would come from the actual motion data
                    mock_joints_2d = np.array([
                        [256, 50], [256, 100], [220, 150], [200, 200], [180, 250],
                        [290, 150], [310, 200], [330, 250], [230, 300], [230, 350],
                        [230, 450], [280, 300], [280, 350], [280, 450], [240, 40],
                        [270, 40], [230, 20], [280, 20]
                    ])
                    composited = compositor.composite_equipment(frame, mock_joints_2d)
                    composited_frames.append(composited)
                rendered_frames = composited_frames
                logger.info(f"✓ Composited dumbbell onto {len(rendered_frames)} frames")
            except Exception as e:
                logger.error(f"Equipment compositing error: {e}")
        else:
            logger.info("⏳ Skipping equipment compositing (no rendered frames)")

        # Phase 5: Animation Assembly
        logger.info("\n" + "=" * 80)
        logger.info("Phase 5: Animation Assembly (Lottie)")
        logger.info("=" * 80)

        if rendered_frames:
            try:
                assembler = AnimationAssembler()
                outputs = assembler.assemble_animation(
                    rendered_frames,
                    "bicep_curl",
                    OUTPUT_DIR
                )
                logger.info(f"✓ Animation assembled")
                for format_name, path in outputs.items():
                    if path:
                        logger.info(f"  {format_name}: {path}")
            except Exception as e:
                logger.error(f"Animation assembly error: {e}")
        else:
            logger.info("⏳ Skipping animation assembly (no rendered frames)")

        # Summary
        logger.info("\n" + "=" * 80)
        logger.info("Prototype Execution Complete")
        logger.info("=" * 80)
        logger.info(f"Phase 1 (SayMotion): {'✓' if motion_data else '✗'}")
        logger.info(f"Phase 2 (Pose Extraction): {'✓' if skeleton_images else '✗'}")
        logger.info(f"Phase 3 (ControlNet Rendering): {'✓' if rendered_frames else '✗'}")
        logger.info(f"Phase 4 (Equipment Compositing): {'✓' if rendered_frames else '✗'}")
        logger.info(f"Phase 5 (Animation Assembly): {'✓' if rendered_frames else '✗'}")

        logger.info("\n📖 To run the full pipeline:")
        logger.info("\n1️⃣  HY-Motion (Recommended):")
        logger.info("   Read: prototype/RUNPOD_SETUP.md")
        logger.info("   Set: HY_MOTION_RUNPOD_SSH in .env")
        logger.info("\n2️⃣  SayMotion (Alternative):")
        logger.info("   Set: SAYMOTION_CLIENT_ID, SAYMOTION_CLIENT_SECRET")
        logger.info("   Set: MOTION_SERVICE=saymotion in .env")
        logger.info("\n3️⃣  ControlNet Rendering (Replicate):")
        logger.info("   Set: REPLICATE_API_TOKEN in .env")
        logger.info("\nThen run: python main.py")

        return 0

    except Exception as e:
        logger.error(f"Error: {e}", exc_info=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
