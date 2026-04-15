#!/usr/bin/env python3
"""
Test helper: Generate mock rendered frames to test full pipeline completion.

This allows us to bypass phase 3 (ControlNet rendering) which requires
a paid Replicate account, and test phases 4-5 (equipment compositing
and Lottie assembly) to validate the complete pipeline.
"""

import logging
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import numpy as np

logger = logging.getLogger(__name__)


def create_mock_rendered_frames(output_dir: Path, num_frames: int = 6) -> list:
    """
    Create mock rendered frames from skeleton images.

    Adds simple coloring to skeleton images to simulate rendered figures.

    Args:
        output_dir: Directory containing skeleton_*.png files
        num_frames: Number of frames to create

    Returns:
        list: List of PIL Image objects (rendered frames)
    """
    rendered_frames = []

    for i in range(num_frames):
        skeleton_path = output_dir / f"skeleton_{i*24:04d}.png"
        if not skeleton_path.exists():
            logger.warning(f"Skeleton image not found: {skeleton_path}")
            continue

        # Load skeleton image
        skeleton_img = Image.open(skeleton_path).convert("RGB")
        width, height = skeleton_img.size

        # Create a rendered version by:
        # 1. Keep the skeleton lines (white/black)
        # 2. Add a gradient skin tone background
        # 3. Add simple coloring to simulate a figure

        rendered = Image.new("RGB", (width, height), color=(245, 240, 235))  # Skin tone bg

        # Convert skeleton to numpy array
        skeleton_array = np.array(skeleton_img)

        # Create a figure overlay - find white pixels (skeleton) and color them
        white_mask = np.all(skeleton_array > 200, axis=2)

        # Create rendered image
        rendered_array = np.array(rendered)

        # Apply skin tone with some shading
        rendered_array[~white_mask] = [220, 180, 160]  # Skin tone for body

        # Keep skeleton lines in dark color
        rendered_array[white_mask] = [50, 50, 50]  # Dark skeleton

        rendered = Image.fromarray(rendered_array.astype('uint8'), 'RGB')

        # Add frame number text
        draw = ImageDraw.Draw(rendered)
        try:
            # Try to use a default font with larger size
            font = ImageFont.load_default()
            text = f"Frame {i}"
            draw.text((10, 10), text, fill=(0, 0, 0), font=font)
        except Exception:
            pass

        rendered_frames.append(rendered)
        logger.info(f"Created mock rendered frame {i+1}/{num_frames}")

    return rendered_frames


def main():
    """Test creating mock rendered frames."""
    from config import OUTPUT_DIR

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
    )

    logger.info("Creating mock rendered frames for testing full pipeline...")

    rendered = create_mock_rendered_frames(OUTPUT_DIR, num_frames=6)

    logger.info(f"✓ Created {len(rendered)} mock rendered frames")

    # Save them to verify
    for i, frame in enumerate(rendered):
        path = OUTPUT_DIR / f"rendered_mock_{i:04d}.png"
        frame.save(path)
        logger.info(f"  Saved: {path}")


if __name__ == "__main__":
    main()
