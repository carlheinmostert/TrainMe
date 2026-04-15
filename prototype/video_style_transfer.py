"""
Video Style Transfer — Single-step video filter

Takes a raw exercise video and produces a clean, stylized version
using Kling O1 video-to-video on fal.ai.

Usage:
    python video_style_transfer.py <input_video_url_or_path> [--style illustration|clean|anime]
"""

import os
import sys
import time
import logging
import requests
import json
from pathlib import Path

logger = logging.getLogger(__name__)

FAL_KEY = os.getenv("FAL_KEY", "")
FAL_ENDPOINT = "https://queue.fal.run/fal-ai/kling-video/o1/video-to-video/edit"

STYLE_PROMPTS = {
    "clean": (
        "Transform this into a clean, professional fitness demonstration video. "
        "Bright studio lighting, clean white background, "
        "neat athletic clothing, high production quality. "
        "Preserve the exact exercise movement and form."
    ),
    "illustration": (
        "Transform this into a clean 2D illustrated fitness animation. "
        "Simple flat colors, white background, "
        "professional exercise illustration style. "
        "Preserve the exact exercise movement and form."
    ),
    "anime": (
        "Transform this into anime-style fitness animation. "
        "Clean lines, vibrant colors, white background, "
        "athletic character design. "
        "Preserve the exact exercise movement and form."
    ),
}


def submit_video(video_url: str, style: str = "clean") -> dict:
    """
    Submit a video for style transfer.

    Args:
        video_url: Public URL to the input video (mp4/mov, 3-10s, max 200MB)
        style: One of 'clean', 'illustration', 'anime'

    Returns:
        dict with request_id and status
    """
    if not FAL_KEY:
        raise ValueError("FAL_KEY not set. Get one at https://fal.ai/dashboard/keys")

    prompt = STYLE_PROMPTS.get(style, STYLE_PROMPTS["clean"])

    headers = {
        "Authorization": f"Key {FAL_KEY}",
        "Content-Type": "application/json",
    }

    payload = {
        "prompt": prompt,
        "video_url": video_url,
    }

    logger.info(f"Submitting video for style transfer...")
    logger.info(f"  Video: {video_url}")
    logger.info(f"  Style: {style}")
    logger.info(f"  Endpoint: {FAL_ENDPOINT}")

    response = requests.post(
        FAL_ENDPOINT,
        headers=headers,
        json=payload,
        timeout=30,
    )

    if response.status_code == 200:
        result = response.json()
        request_id = result.get("request_id")
        logger.info(f"  ✓ Submitted, request_id: {request_id}")
        return result
    else:
        logger.error(f"  Error {response.status_code}: {response.text[:300]}")
        raise RuntimeError(f"Submit failed: {response.status_code}")


def poll_result(request_id: str, max_wait: int = 300) -> dict:
    """
    Poll for the result of a style transfer job.

    Args:
        request_id: The request ID from submit_video
        max_wait: Max seconds to wait

    Returns:
        dict with video output URL
    """
    status_url = f"https://queue.fal.run/fal-ai/kling-video/o1/video-to-video/edit/requests/{request_id}/status"
    result_url = f"https://queue.fal.run/fal-ai/kling-video/o1/video-to-video/edit/requests/{request_id}"

    headers = {"Authorization": f"Key {FAL_KEY}"}

    start = time.time()
    while time.time() - start < max_wait:
        resp = requests.get(status_url, headers=headers, timeout=10)
        if resp.status_code == 200:
            status_data = resp.json()
            status = status_data.get("status", "unknown")
            elapsed = int(time.time() - start)
            logger.info(f"  Status ({elapsed}s): {status}")

            if status == "COMPLETED":
                # Fetch the result
                result_resp = requests.get(result_url, headers=headers, timeout=30)
                if result_resp.status_code == 200:
                    return result_resp.json()
                else:
                    logger.error(f"  Result fetch error: {result_resp.status_code}")
                    return None
            elif status in ("FAILED", "CANCELLED"):
                logger.error(f"  Job failed: {status_data}")
                return None
        else:
            logger.warning(f"  Status check error: {resp.status_code}")

        time.sleep(5)

    logger.error(f"  Timeout after {max_wait}s")
    return None


def download_video(url: str, output_path: str) -> str:
    """Download the styled video."""
    logger.info(f"  Downloading styled video...")
    resp = requests.get(url, timeout=120)
    if resp.status_code == 200:
        with open(output_path, "wb") as f:
            f.write(resp.content)
        logger.info(f"  ✓ Saved to {output_path} ({len(resp.content)} bytes)")
        return output_path
    else:
        logger.error(f"  Download failed: {resp.status_code}")
        return None


def style_transfer(video_url: str, style: str = "clean", output_path: str = None) -> str:
    """
    End-to-end: submit video, wait for result, download.

    Args:
        video_url: Public URL to input video
        style: Style preset name
        output_path: Where to save the output (default: output/styled_video.mp4)

    Returns:
        Path to the styled video file
    """
    if output_path is None:
        output_path = str(Path(__file__).parent / "output" / f"styled_{style}.mp4")

    # Submit
    submit_result = submit_video(video_url, style)
    request_id = submit_result.get("request_id")
    if not request_id:
        logger.error("No request_id returned")
        return None

    # Poll
    logger.info("Waiting for style transfer to complete...")
    result = poll_result(request_id)
    if not result:
        return None

    # Download
    video_data = result.get("video", {})
    video_output_url = video_data.get("url")
    if not video_output_url:
        logger.error(f"No video URL in result: {result}")
        return None

    return download_video(video_output_url, output_path)


def main():
    """CLI entry point."""
    import argparse

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    )

    parser = argparse.ArgumentParser(description="Video style transfer for exercise videos")
    parser.add_argument("video", help="Public URL to input video (mp4, 3-10s)")
    parser.add_argument("--style", default="clean", choices=["clean", "illustration", "anime"],
                        help="Style preset (default: clean)")
    parser.add_argument("--output", default=None, help="Output file path")
    args = parser.parse_args()

    result = style_transfer(args.video, args.style, args.output)
    if result:
        print(f"\n✓ Styled video saved to: {result}")
    else:
        print("\n✗ Style transfer failed")
        sys.exit(1)


if __name__ == "__main__":
    main()
