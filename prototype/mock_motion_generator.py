"""
Mock Motion Generator

Generates synthetic 3D motion data for testing the pipeline without HY-Motion.
Useful for validating architecture before integrating real motion generation.
"""

import logging
import numpy as np
from typing import List, Dict, Optional

logger = logging.getLogger(__name__)


class MockMotionGenerator:
    """Generates synthetic motion data for testing."""

    def __init__(self):
        """Initialize mock generator."""
        logger.info("✓ Mock Motion Generator initialized")

    def generate_motion(
        self,
        prompt: str,
        duration: int = 8,
        output_name: str = "motion"
    ) -> Optional[bytes]:
        """
        Generate synthetic 3D motion data.

        Args:
            prompt: Exercise description (ignored for mock, but logged)
            duration: Animation duration in seconds
            output_name: Name for output (ignored)

        Returns:
            bytes: Synthetic BVH-like data
        """
        logger.info(f"Generating synthetic motion: {prompt}")
        logger.info(f"Duration: {duration}s")

        # Generate synthetic motion data
        motion_frames = self.generate_synthetic_frames(duration)

        # Convert to BVH format (simplified)
        bvh_content = self._create_bvh_content(motion_frames)

        logger.info(f"✓ Generated synthetic motion ({len(bvh_content)} bytes)")
        return bvh_content

    def generate_synthetic_frames(self, duration: int, fps: int = 15) -> List[Dict]:
        """
        Generate synthetic motion frames.

        Args:
            duration: Duration in seconds
            fps: Frames per second

        Returns:
            list: List of frame dicts with synthetic joint data
        """
        num_frames = duration * fps
        frames = []

        for frame_idx in range(num_frames):
            # Progress through animation (0 to 1)
            progress = frame_idx / max(num_frames - 1, 1)

            # Simulate bicep curl:
            # - Start with arms down
            # - Curl up to ~90 degrees
            # - Back down

            # Create simple skeleton joint positions (simplified, not full BVH)
            # This will be parsed into the format expected by pose_extractor
            frame_data = {
                "raw_values": self._generate_frame_values(progress),
                "progress": progress,
            }
            frames.append(frame_data)

        logger.info(f"Generated {len(frames)} synthetic frames")
        return frames

    def _generate_frame_values(self, progress: float) -> List[float]:
        """
        Generate joint values for a single frame.

        Simulates a bicep curl motion using sinusoidal interpolation.

        Args:
            progress: Animation progress (0.0 to 1.0)

        Returns:
            list: Joint values (simplified skeleton)
        """
        # Simulate bicep curl with 20 joint values (simplified)
        values = []

        for joint_idx in range(20):
            if joint_idx == 0:
                # Root position (hips) - stationary
                values.append(0.0)
            elif joint_idx == 1:
                # Root Y (vertical) - slight bob
                values.append(np.sin(progress * np.pi) * 0.05)
            elif joint_idx == 2:
                # Root Z - no movement
                values.append(0.0)
            elif joint_idx in [6, 7, 8]:
                # Right arm: shoulder, elbow, wrist
                # Simulate curl: elbow bends up then back down
                if joint_idx == 8:  # Right elbow (the main curl)
                    # Bend angle: 0° → 90° → 0°
                    bend = np.sin(progress * np.pi) * 90.0
                    values.append(bend)
                else:
                    values.append(0.0)
            elif joint_idx in [12, 13, 14]:
                # Left arm: mirror the right side but slightly offset
                if joint_idx == 14:  # Left elbow
                    bend = np.sin((progress + 0.1) * np.pi) * 85.0
                    values.append(bend)
                else:
                    values.append(0.0)
            else:
                # Other joints: small variations for realism
                values.append(np.sin(progress * np.pi + joint_idx) * 2.0)

        return values

    def _create_bvh_content(self, frames: List[Dict]) -> bytes:
        """
        Create simplified BVH format content.

        Args:
            frames: List of frame dictionaries

        Returns:
            bytes: BVH file content
        """
        bvh_lines = [
            "HIERARCHY",
            "ROOT Hips",
            "{",
            "  OFFSET 0.0 0.0 0.0",
            "  CHANNELS 6 Xposition Yposition Zposition Xrotation Yrotation Zrotation",
            "  JOINT Chest",
            "  {",
            "    OFFSET 0.0 10.0 0.0",
            "    CHANNELS 3 Xrotation Yrotation Zrotation",
            "    JOINT RightShoulder { OFFSET 5.0 5.0 0.0 CHANNELS 3 Xrotation Yrotation Zrotation End Site { OFFSET 0.0 0.0 0.0 } }",
            "    JOINT RightElbow { OFFSET 10.0 0.0 0.0 CHANNELS 3 Xrotation Yrotation Zrotation End Site { OFFSET 0.0 0.0 0.0 } }",
            "    JOINT LeftShoulder { OFFSET -5.0 5.0 0.0 CHANNELS 3 Xrotation Yrotation Zrotation End Site { OFFSET 0.0 0.0 0.0 } }",
            "    JOINT LeftElbow { OFFSET -10.0 0.0 0.0 CHANNELS 3 Xrotation Yrotation Zrotation End Site { OFFSET 0.0 0.0 0.0 } }",
            "  }",
            "}",
            "MOTION",
            f"Frames: {len(frames)}",
            "Frame Time: 0.0666667",
        ]

        # Add frame data
        for frame in frames:
            frame_values = frame.get("raw_values", [])
            bvh_lines.append(" ".join([str(v) for v in frame_values]))

        bvh_content = "\n".join(bvh_lines)
        return bvh_content.encode("utf-8")

    def parse_bvh(self, bvh_content: bytes) -> List[Dict]:
        """
        Parse BVH content (same interface as HYMotionClient).

        Args:
            bvh_content: Raw BVH file content

        Returns:
            list: Parsed motion frames
        """
        try:
            bvh_text = bvh_content.decode("utf-8")
            lines = bvh_text.strip().split("\n")

            frames_data = []
            in_motion = False

            # Parse BVH
            for line in lines:
                if line.strip() == "MOTION":
                    in_motion = True
                    continue
                elif in_motion and line.strip().startswith("Frames:"):
                    frame_count = int(line.split(":")[1].strip())
                    logger.info(f"BVH contains {frame_count} frames")
                elif in_motion and line.strip().startswith("Frame Time:"):
                    frame_time = float(line.split(":")[1].strip())
                    logger.info(f"Frame time: {frame_time}s")
                elif in_motion and line.strip() and not line.startswith("Frame"):
                    values = [float(v) for v in line.split()]
                    frames_data.append({"raw_values": values})

            logger.info(f"✓ Parsed {len(frames_data)} frames")
            return frames_data

        except Exception as e:
            logger.error(f"Error parsing BVH: {e}")
            return []

    def generate_and_parse(
        self,
        prompt: str,
        duration: int = 8
    ) -> Optional[List[Dict]]:
        """
        End-to-end: generate and parse motion.

        Args:
            prompt: Exercise description
            duration: Animation duration in seconds

        Returns:
            list: Parsed motion frames
        """
        bvh_content = self.generate_motion(prompt, duration)
        if not bvh_content:
            return None

        motion_frames = self.parse_bvh(bvh_content)
        return motion_frames if motion_frames else None


def main():
    """Test mock motion generator."""
    generator = MockMotionGenerator()

    motion_data = generator.generate_and_parse(
        "Standing bicep curl with dumbbell",
        duration=8
    )

    if motion_data:
        logger.info(f"✓ Successfully generated {len(motion_data)} frames")
    else:
        logger.error("Failed to generate motion")


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
    )
    main()
