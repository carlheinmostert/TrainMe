"""
ControlNet Renderer

Renders 2D illustrated figures from OpenPose skeleton images using
Replicate API with FLUX + ControlNet.
"""

import logging
import time
import base64
from typing import Optional
import requests
from pathlib import Path
from PIL import Image
from io import BytesIO

from config import REPLICATE_API_TOKEN, REPLICATE_API_URL, REPLICATE_CONTROLNET_MODEL

logger = logging.getLogger(__name__)


class ControlNetRenderer:
    """Renders illustrated figures using Replicate ControlNet API."""

    def __init__(self, model: str = REPLICATE_CONTROLNET_MODEL):
        """
        Initialize the ControlNet renderer.

        Args:
            model: Replicate model ID for ControlNet (default: xlabs-ai/flux-controlnet)
        """
        self.model = model
        self.api_token = REPLICATE_API_TOKEN
        self.api_url = REPLICATE_API_URL
        self.max_poll_attempts = 120  # 2 minutes with 1s intervals

        if not self.api_token:
            logger.error("REPLICATE_API_TOKEN not set")

    def encode_image_base64(self, image: Image.Image) -> str:
        """
        Convert PIL Image to base64-encoded data URL.

        Args:
            image: PIL Image object

        Returns:
            str: Data URL string
        """
        buffered = BytesIO()
        image.save(buffered, format="PNG")
        img_base64 = base64.b64encode(buffered.getvalue()).decode()
        return f"data:image/png;base64,{img_base64}"

    def submit_prediction(
        self,
        skeleton_image: Image.Image,
        prompt: str = "A fit person doing an exercise, illustrated style, anatomically correct, professional fitness illustration",
        control_strength: float = 0.8,
        guidance_scale: float = 7.5,
        steps: int = 28,
    ) -> Optional[str]:
        """
        Submit an image generation request to Replicate ControlNet.

        Args:
            skeleton_image: PIL Image of OpenPose skeleton
            prompt: Text prompt for FLUX
            control_strength: ControlNet conditioning strength (0.0 to 1.0)
            guidance_scale: Guidance scale for FLUX
            steps: Number of inference steps (default 28)

        Returns:
            str: Prediction ID if successful, None otherwise
        """
        try:
            # Encode skeleton image as base64 data URL
            control_image_b64 = self.encode_image_base64(skeleton_image)

            # Prepare request
            headers = {
                "Authorization": f"Token {self.api_token}",
                "Content-Type": "application/json",
            }

            # Build prediction input
            # Note: ControlNet model input format may vary, adjust based on actual Replicate API
            input_data = {
                "prompt": prompt,
                "control_image": control_image_b64,
                "control_type": "openpose",
                "control_strength": control_strength,
                "guidance_scale": guidance_scale,
                "steps": steps,
                "num_outputs": 1,
            }

            # Build prediction request
            prediction_request = {
                "version": self.model,  # May need to use full model version ID
                "input": input_data,
            }

            logger.info(f"Submitting ControlNet prediction...")
            logger.info(f"  Prompt: {prompt}")
            logger.info(f"  Control strength: {control_strength}")
            logger.info(f"  Guidance scale: {guidance_scale}")

            # Submit to Replicate
            predictions_url = f"{self.api_url}/predictions"
            response = requests.post(
                predictions_url,
                json=prediction_request,
                headers=headers,
                timeout=30,
            )

            if response.status_code == 201:
                prediction_data = response.json()
                prediction_id = prediction_data.get("id")
                logger.info(f"✓ Prediction submitted: {prediction_id}")
                return prediction_id
            else:
                logger.error(f"Prediction submission failed: {response.status_code}")
                logger.error(f"Response: {response.text}")
                return None

        except Exception as e:
            logger.error(f"Error submitting prediction: {e}")
            return None

    def poll_prediction(self, prediction_id: str) -> Optional[dict]:
        """
        Poll prediction status until completion.

        Args:
            prediction_id: The prediction ID

        Returns:
            dict: Prediction response if completed, None if failed or timeout
        """
        try:
            headers = {"Authorization": f"Token {self.api_token}"}

            for attempt in range(self.max_poll_attempts):
                prediction_url = f"{self.api_url}/predictions/{prediction_id}"
                response = requests.get(prediction_url, headers=headers, timeout=10)

                if response.status_code == 200:
                    prediction = response.json()
                    status = prediction.get("status")

                    logger.debug(f"Poll attempt {attempt + 1}: status={status}")

                    if status == "succeeded":
                        logger.info(f"✓ Prediction completed successfully")
                        return prediction
                    elif status == "failed":
                        logger.error(f"Prediction failed: {prediction.get('error')}")
                        return None
                    # else: "processing" or "starting", continue polling

                    time.sleep(1)
                else:
                    logger.warning(f"Poll request failed: {response.status_code}")
                    time.sleep(1)

            logger.error("Polling timeout")
            return None

        except Exception as e:
            logger.error(f"Error polling prediction: {e}")
            return None

    def download_image(self, output_url: str) -> Optional[Image.Image]:
        """
        Download generated image from output URL.

        Args:
            output_url: URL to the generated image

        Returns:
            PIL.Image: Generated image if successful, None otherwise
        """
        try:
            logger.info(f"Downloading generated image...")
            response = requests.get(output_url, timeout=30)

            if response.status_code == 200:
                image = Image.open(BytesIO(response.content))
                logger.info(f"✓ Image downloaded ({image.size})")
                return image
            else:
                logger.error(f"Image download failed: {response.status_code}")
                return None

        except Exception as e:
            logger.error(f"Error downloading image: {e}")
            return None

    def render(
        self,
        skeleton_image: Image.Image,
        prompt: str = "A fit person doing an exercise, illustrated style, anatomically correct, professional fitness illustration",
    ) -> Optional[Image.Image]:
        """
        End-to-end: submit prediction and wait for completion.

        Args:
            skeleton_image: OpenPose skeleton image
            prompt: Text prompt for image generation

        Returns:
            PIL.Image: Generated illustrated figure, or None if failed
        """
        prediction_id = self.submit_prediction(skeleton_image, prompt)
        if not prediction_id:
            return None

        prediction = self.poll_prediction(prediction_id)
        if not prediction:
            return None

        # Extract output image URL
        output = prediction.get("output")
        if not output or len(output) == 0:
            logger.error("No output in prediction response")
            return None

        output_url = output[0] if isinstance(output, list) else output
        image = self.download_image(output_url)

        return image


def main():
    """Test the ControlNet renderer."""
    from config import OUTPUT_DIR

    # Create a test skeleton image
    from PIL import Image, ImageDraw

    skeleton_image = Image.new("RGB", (512, 512), color="white")
    draw = ImageDraw.Draw(skeleton_image)

    # Draw a simple skeleton stick figure
    draw.ellipse([(250, 50), (270, 70)], fill="black")  # Head
    draw.line([(260, 70), (260, 150)], fill="black", width=2)  # Body
    draw.line([(260, 100), (200, 130)], fill="black", width=2)  # Left arm
    draw.line([(260, 100), (320, 130)], fill="black", width=2)  # Right arm
    draw.line([(260, 150), (220, 250)], fill="black", width=2)  # Left leg
    draw.line([(260, 150), (300, 250)], fill="black", width=2)  # Right leg

    renderer = ControlNetRenderer()

    # Test rendering
    prompt = "A person standing with arms slightly raised, illustrated style, professional fitness"
    rendered = renderer.render(skeleton_image, prompt)

    if rendered:
        output_path = OUTPUT_DIR / "controlnet_test_output.png"
        rendered.save(output_path)
        logger.info(f"✓ Test output saved to {output_path}")
    else:
        logger.error("Failed to render image")


if __name__ == "__main__":
    main()
