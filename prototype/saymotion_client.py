"""
SayMotion API Client

Handles authentication and communication with DeepMotion's SayMotion API
for converting text descriptions to 3D human motion animations.
"""

import logging
import time
import base64
from typing import Dict, List, Optional
import requests

from config import (
    SAYMOTION_CLIENT_ID,
    SAYMOTION_CLIENT_SECRET,
    SAYMOTION_AUTH_ENDPOINT,
    SAYMOTION_MOTION_ENDPOINT,
    SAYMOTION_STATUS_ENDPOINT,
    SAYMOTION_DOWNLOAD_ENDPOINT,
    CACHE_DIR,
)

logger = logging.getLogger(__name__)


class SayMotionClient:
    """Client for the DeepMotion SayMotion API."""

    def __init__(self):
        """Initialize the SayMotion client."""
        self.client_id = SAYMOTION_CLIENT_ID
        self.client_secret = SAYMOTION_CLIENT_SECRET
        self.session_cookie = None
        self.authenticate()

    def authenticate(self) -> bool:
        """
        Authenticate with the SayMotion API using Basic Auth.

        Returns:
            bool: True if authentication successful, False otherwise
        """
        try:
            # Create Basic Auth header
            credentials = f"{self.client_id}:{self.client_secret}"
            encoded = base64.b64encode(credentials.encode()).decode()
            headers = {"Authorization": f"Basic {encoded}"}

            logger.info("Authenticating with SayMotion API...")
            response = requests.get(SAYMOTION_AUTH_ENDPOINT, headers=headers, timeout=10)

            if response.status_code == 200:
                # Extract session cookie from response
                if "dmsess" in response.cookies:
                    self.session_cookie = response.cookies["dmsess"]
                    logger.info("✓ Authentication successful")
                    return True
                else:
                    logger.warning("No session cookie in response, but status 200")
                    return True  # May still work without explicit cookie
            else:
                logger.error(f"Authentication failed: {response.status_code}")
                logger.error(f"Response: {response.text}")
                return False

        except Exception as e:
            logger.error(f"Authentication error: {e}")
            return False

    def submit_text_to_motion(
        self, prompt: str, duration: int = 8, num_variants: int = 1
    ) -> Optional[str]:
        """
        Submit a text-to-motion generation request.

        Args:
            prompt: Description of the exercise (e.g., "Standing bicep curl with dumbbell")
            duration: Animation duration in seconds (default 8)
            num_variants: Number of animation variants to generate (1-8, default 1)

        Returns:
            str: Request ID if successful, None otherwise
        """
        try:
            # Build request parameters
            params = [
                f"prompt={prompt}",
                "model=default",  # Use default character model
                f"requestedAnimationDuration={duration}",
                f"numVariant={min(max(num_variants, 1), 8)}",  # Clamp to 1-8
            ]

            data = {"params": params}

            headers = {}
            if self.session_cookie:
                headers["Cookie"] = f"dmsess={self.session_cookie}"

            logger.info(f"Submitting motion generation request: {prompt}")
            logger.info(f"  Duration: {duration}s, Variants: {num_variants}")

            response = requests.post(
                SAYMOTION_MOTION_ENDPOINT, json=data, headers=headers, timeout=30
            )

            if response.status_code == 200:
                result = response.json()
                request_id = result.get("rid")
                logger.info(f"✓ Request submitted with ID: {request_id}")
                return request_id
            else:
                logger.error(f"Request failed: {response.status_code}")
                logger.error(f"Response: {response.text}")
                return None

        except Exception as e:
            logger.error(f"Error submitting motion request: {e}")
            return None

    def poll_status(self, request_id: str, max_wait_seconds: int = 600) -> Optional[Dict]:
        """
        Poll the status of a motion generation request.

        Args:
            request_id: The request ID returned by submit_text_to_motion
            max_wait_seconds: Maximum time to wait for completion (default 600s = 10min)

        Returns:
            dict: Status response if available, None if polling timeout or error
        """
        try:
            start_time = time.time()
            poll_interval = 5  # seconds

            while time.time() - start_time < max_wait_seconds:
                headers = {}
                if self.session_cookie:
                    headers["Cookie"] = f"dmsess={self.session_cookie}"

                status_url = f"{SAYMOTION_STATUS_ENDPOINT}/{request_id}"
                response = requests.get(status_url, headers=headers, timeout=10)

                if response.status_code == 200:
                    status_data = response.json()
                    status = status_data.get("status", "unknown")

                    elapsed = int(time.time() - start_time)
                    logger.info(f"Status check ({elapsed}s): {status}")

                    if status == "completed":
                        logger.info(f"✓ Motion generation completed")
                        return status_data
                    elif status == "failed":
                        logger.error("Motion generation failed")
                        return None
                    # else: status is "processing", continue polling
                else:
                    logger.warning(f"Status check failed: {response.status_code}")

                time.sleep(poll_interval)

            logger.error(f"Polling timeout after {max_wait_seconds}s")
            return None

        except Exception as e:
            logger.error(f"Error polling status: {e}")
            return None

    def download_motion(self, request_id: str) -> Optional[bytes]:
        """
        Download the BVH motion file for a completed request.

        Args:
            request_id: The request ID

        Returns:
            bytes: BVH file content if successful, None otherwise
        """
        try:
            headers = {}
            if self.session_cookie:
                headers["Cookie"] = f"dmsess={self.session_cookie}"

            download_url = f"{SAYMOTION_DOWNLOAD_ENDPOINT}/{request_id}"
            logger.info(f"Downloading motion file...")

            response = requests.get(download_url, headers=headers, timeout=30)

            if response.status_code == 200:
                # The response is likely a JSON with file links, need to extract BVH URL
                try:
                    data = response.json()
                    # Look for BVH file in the response
                    # Structure may vary, but typically has variant and format info
                    logger.info(f"Download response: {data}")
                    # TODO: Parse actual BVH download link and fetch it
                    return response.content
                except:
                    # If not JSON, assume it's the BVH file directly
                    logger.info(f"✓ Motion file downloaded ({len(response.content)} bytes)")
                    return response.content
            else:
                logger.error(f"Download failed: {response.status_code}")
                return None

        except Exception as e:
            logger.error(f"Error downloading motion: {e}")
            return None

    def parse_bvh(self, bvh_content: bytes) -> List[Dict]:
        """
        Parse a BVH file and extract joint positions for each frame.

        Args:
            bvh_content: Raw BVH file content

        Returns:
            list: List of frame dicts, each containing joint positions
        """
        try:
            bvh_text = bvh_content.decode("utf-8")
            lines = bvh_text.strip().split("\n")

            frames_data = []
            in_motion = False
            joint_count = 0

            # Parse BVH header to determine number of joints
            for line in lines:
                if "End Site" in line:
                    joint_count += 1
                elif line.strip() == "MOTION":
                    in_motion = True
                    continue
                elif in_motion and line.strip().startswith("Frames:"):
                    frame_count = int(line.split(":")[1].strip())
                    logger.info(f"BVH file contains {frame_count} frames")
                elif in_motion and line.strip().startswith("Frame Time:"):
                    frame_time = float(line.split(":")[1].strip())
                    logger.info(f"Frame time: {frame_time}s")
                elif in_motion and line.strip() and not line.startswith("Frame"):
                    # This is a frame data line
                    values = [float(v) for v in line.split()]
                    frames_data.append({"raw_values": values})

            logger.info(f"✓ Parsed {len(frames_data)} frames from BVH file")
            return frames_data

        except Exception as e:
            logger.error(f"Error parsing BVH: {e}")
            return []

    def generate_motion(self, prompt: str, duration: int = 8) -> Optional[List[Dict]]:
        """
        End-to-end: submit motion request, wait for completion, and download results.

        Args:
            prompt: Exercise description
            duration: Animation duration in seconds

        Returns:
            list: Parsed motion frames, or None if failed
        """
        request_id = self.submit_text_to_motion(prompt, duration)
        if not request_id:
            return None

        status = self.poll_status(request_id)
        if not status:
            return None

        bvh_content = self.download_motion(request_id)
        if not bvh_content:
            return None

        motion_frames = self.parse_bvh(bvh_content)
        return motion_frames if motion_frames else None


def main():
    """Test the SayMotion client."""
    client = SayMotionClient()

    # Test with a simple prompt
    motion_data = client.generate_motion("Standing bicep curl with dumbbell", duration=8)

    if motion_data:
        logger.info(f"✓ Successfully generated motion with {len(motion_data)} frames")
    else:
        logger.error("Failed to generate motion")


if __name__ == "__main__":
    main()
