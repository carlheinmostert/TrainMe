"""
Stability AI ControlNet Renderer

Renders 2D illustrated figures from OpenPose skeleton images using
Stability AI's Control Sketch API (v2beta).
"""

import logging
import base64
import json
import io
import tempfile
from typing import Optional
import requests
from pathlib import Path
from PIL import Image

from config import STABILITY_API_KEY

logger = logging.getLogger(__name__)


class StabilityRenderer:
    """Renders illustrated figures using Stability AI Control Sketch API."""

    def __init__(self):
        """Initialize the Stability AI renderer."""
        self.api_key = STABILITY_API_KEY
        self.api_url = "https://api.stability.ai/v2beta/stable-image/control/sketch"

        if not self.api_key:
            logger.error("STABILITY_API_KEY not set")

    def render(self, skeleton_input, prompt: str) -> Optional[Image.Image]:
        """
        Generate illustrated figure from skeleton using Stability AI Control Sketch.

        Args:
            skeleton_input: Path to skeleton PNG or PIL Image object
            prompt: Text prompt for generation

        Returns:
            PIL Image if successful, None otherwise
        """
        try:
            # Prepare the image bytes
            if isinstance(skeleton_input, Image.Image):
                img_buf = io.BytesIO()
                skeleton_input.save(img_buf, format="PNG")
                img_buf.seek(0)
                image_data = img_buf
            else:
                image_data = open(str(skeleton_input), "rb")

            logger.info("Submitting Stability AI Control Sketch request...")
            logger.info(f"  Prompt: {prompt}")
            logger.info(f"  Endpoint: control/sketch")

            headers = {
                "Authorization": f"Bearer {self.api_key}",
                "Accept": "application/json",
            }

            # Build the enhanced prompt for fitness illustration
            full_prompt = (
                f"{prompt}, "
                "professional fitness illustration, "
                "clean 2D character, anatomically correct pose, "
                "solid white background, simple flat color style, "
                "full body view"
            )

            files = {
                "image": ("skeleton.png", image_data, "image/png"),
            }

            data = {
                "prompt": full_prompt,
                "control_strength": 0.65,
                "negative_prompt": (
                    "skeleton, stick figure, wireframe, "
                    "low quality, blurry, distorted limbs, "
                    "extra limbs, text, watermark"
                ),
                "output_format": "png",
            }

            response = requests.post(
                self.api_url,
                headers=headers,
                files=files,
                data=data,
                timeout=90,
            )

            # Close file handle if we opened one
            if not isinstance(skeleton_input, Image.Image):
                image_data.close()

            if response.status_code == 200:
                result = response.json()
                if "image" in result:
                    img_bytes = base64.b64decode(result["image"])
                    img = Image.open(io.BytesIO(img_bytes))
                    logger.info(
                        f"✓ Generated illustration ({img.size[0]}x{img.size[1]})"
                    )
                    return img
                else:
                    logger.error(f"No image in response: {list(result.keys())}")
                    return None
            else:
                logger.error(
                    f"Stability AI error {response.status_code}: {response.text[:300]}"
                )
                return None

        except Exception as e:
            logger.error(f"Rendering error: {e}")
            import traceback
            traceback.print_exc()
            return None

    def render_batch(self, skeleton_images: list, prompt: str) -> list:
        """
        Render multiple skeleton images.

        Args:
            skeleton_images: List of (frame_index, skeleton_image) tuples or paths
            prompt: Text prompt for generation

        Returns:
            list: List of PIL Images
        """
        rendered = []
        for i, item in enumerate(skeleton_images):
            # Handle both tuples (frame_idx, image) and plain paths
            if isinstance(item, tuple):
                frame_idx, skeleton = item
            else:
                skeleton = item

            logger.info(f"Rendering {i + 1}/{len(skeleton_images)}...")
            img = self.render(skeleton, prompt)
            if img:
                rendered.append(img)
            else:
                logger.warning(f"Failed to render frame {i + 1}")
        return rendered


def main():
    """Test Stability AI renderer."""
    renderer = StabilityRenderer()

    # Test with a skeleton image
    test_skeleton = Path(__file__).parent / "output" / "skeleton_0000.png"

    if test_skeleton.exists():
        logger.info("Testing Stability AI renderer...")
        result = renderer.render(
            str(test_skeleton),
            "Standing bicep curl with dumbbell",
        )
        if result:
            out_path = Path(__file__).parent / "output" / "stability_test.png"
            result.save(out_path)
            logger.info(f"✓ Test complete — saved to {out_path}")
        else:
            logger.error("✗ Test failed")
    else:
        logger.error(f"Test skeleton not found: {test_skeleton}")


if __name__ == "__main__":
    import sys

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    )
    main()
