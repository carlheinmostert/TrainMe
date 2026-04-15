"""
Pose Extractor

Converts 3D motion data from BVH to 2D OpenPose skeleton format.
"""

import logging
from typing import Dict, List, Tuple, Optional
import numpy as np
from pathlib import Path
from PIL import Image, ImageDraw

logger = logging.getLogger(__name__)

# OpenPose 18-point skeleton connections
# Format: (joint_index, parent_index, joint_name)
OPENPOSE_SKELETON = [
    (0, -1, "Nose"),
    (1, 0, "Neck"),
    (2, 1, "RShoulder"),
    (3, 2, "RElbow"),
    (4, 3, "RWrist"),
    (5, 1, "LShoulder"),
    (6, 5, "LElbow"),
    (7, 6, "LWrist"),
    (8, 1, "RHip"),
    (9, 8, "RKnee"),
    (10, 9, "RAnkle"),
    (11, 1, "LHip"),
    (12, 11, "LKnee"),
    (13, 12, "LAnkle"),
    (14, 0, "REye"),
    (15, 0, "LEye"),
    (16, 14, "REar"),
    (17, 15, "LEar"),
]

# OpenPose skeleton connections (pairs of joint indices that are connected)
SKELETON_CONNECTIONS = [
    (0, 1),   # Nose to Neck
    (1, 2),   # Neck to RShoulder
    (2, 3),   # RShoulder to RElbow
    (3, 4),   # RElbow to RWrist
    (1, 5),   # Neck to LShoulder
    (5, 6),   # LShoulder to LElbow
    (6, 7),   # LElbow to LWrist
    (1, 8),   # Neck to RHip
    (8, 9),   # RHip to RKnee
    (9, 10),  # RKnee to RAnkle
    (1, 11),  # Neck to LHip
    (11, 12), # LHip to LKnee
    (12, 13), # LKnee to LAnkle
    (0, 14),  # Nose to REye
    (0, 15),  # Nose to LEye
    (14, 16), # REye to REar
    (15, 17), # LEye to LEar
]


class PoseExtractor:
    """Extracts poses from motion data and generates OpenPose skeleton images."""

    def __init__(self, skeleton_size: int = 512):
        """
        Initialize the pose extractor.

        Args:
            skeleton_size: Size of the output skeleton images (default 512x512)
        """
        self.skeleton_size = skeleton_size
        self.joint_radius = 4
        self.connection_width = 2

    def select_keyframes(
        self, motion_frames: List[Dict], num_frames: int = 6
    ) -> List[int]:
        """
        Select keyframes that represent distinct phases of the motion.

        Args:
            motion_frames: List of motion frames from parsed BVH
            num_frames: Number of keyframes to select (default 6)

        Returns:
            list: Indices of selected keyframes
        """
        total_frames = len(motion_frames)

        if total_frames <= num_frames:
            # If we have fewer frames than requested, use them all
            logger.warning(
                f"Only {total_frames} frames available, requested {num_frames}"
            )
            return list(range(total_frames))

        # Simple strategy: evenly distribute keyframes across the motion
        # More sophisticated approach could use velocity/acceleration peaks
        keyframe_indices = []
        step = total_frames // (num_frames - 1)

        for i in range(num_frames):
            if i == num_frames - 1:
                # Always include the last frame
                keyframe_indices.append(total_frames - 1)
            else:
                keyframe_indices.append(i * step)

        logger.info(f"Selected {len(keyframe_indices)} keyframes: {keyframe_indices}")
        return keyframe_indices

    def extract_joints_3d(self, motion_frame: Dict) -> np.ndarray:
        """
        Extract 3D joint positions from a motion frame.

        Args:
            motion_frame: A single frame from parsed BVH

        Returns:
            np.ndarray: Array of shape (18, 3) with 3D joint positions
        """
        # For now, use placeholder positions
        # In real usage, these would come from the BVH parsing
        raw_values = motion_frame.get("raw_values", [])

        # BVH typically has position + rotation for each joint
        # Create a dummy 18-joint skeleton in 3D space
        joints_3d = np.zeros((18, 3))

        # Simple heuristic: place joints based on array indices
        # This is a placeholder until we properly parse BVH structure
        if raw_values:
            # Map first 18*3=54 values to joints
            for i in range(min(18, len(raw_values) // 3)):
                joints_3d[i, 0] = raw_values[i * 3]
                joints_3d[i, 1] = raw_values[i * 3 + 1]
                joints_3d[i, 2] = raw_values[i * 3 + 2]

        return joints_3d

    def project_3d_to_2d(self, joints_3d: np.ndarray) -> np.ndarray:
        """
        Project 3D joint positions to 2D using orthographic projection.

        Args:
            joints_3d: Array of shape (18, 3) with 3D positions

        Returns:
            np.ndarray: Array of shape (18, 2) with 2D positions
        """
        # Orthographic projection: drop the Z coordinate
        joints_2d = joints_3d[:, :2].copy()

        # Normalize to image space (0 to skeleton_size)
        # Assume joints are in approximately -1 to 1 range
        joints_2d = joints_2d * (self.skeleton_size / 4) + (self.skeleton_size / 2)

        # Clamp to image bounds
        joints_2d = np.clip(joints_2d, 0, self.skeleton_size - 1)

        return joints_2d

    def render_skeleton_image(self, joints_2d: np.ndarray) -> Image.Image:
        """
        Render a 2D skeleton as an image.

        Args:
            joints_2d: Array of shape (18, 2) with 2D joint positions

        Returns:
            PIL.Image: Skeleton visualization image
        """
        # Create white background image
        image = Image.new("RGB", (self.skeleton_size, self.skeleton_size), color="white")
        draw = ImageDraw.Draw(image)

        # Draw connections (bones)
        for idx1, idx2 in SKELETON_CONNECTIONS:
            if idx1 < len(joints_2d) and idx2 < len(joints_2d):
                x1, y1 = joints_2d[idx1]
                x2, y2 = joints_2d[idx2]
                draw.line(
                    [(x1, y1), (x2, y2)],
                    fill="black",
                    width=self.connection_width
                )

        # Draw joints (as circles)
        for i, (x, y) in enumerate(joints_2d):
            # Draw filled circle for joint
            r = self.joint_radius
            draw.ellipse(
                [(x - r, y - r), (x + r, y + r)],
                fill="black",
                outline="black"
            )

        return image

    def extract_and_render_skeletons(
        self,
        motion_frames: List[Dict],
        keyframe_indices: List[int],
        output_dir: Optional[Path] = None,
    ) -> List[Tuple[int, Image.Image]]:
        """
        Extract keyframes and render them as OpenPose skeleton images.

        Args:
            motion_frames: List of motion frames
            keyframe_indices: Indices of frames to extract
            output_dir: Directory to save skeleton images (optional)

        Returns:
            list: List of (frame_index, Image) tuples
        """
        skeleton_images = []

        logger.info(f"Rendering {len(keyframe_indices)} skeleton images...")

        for frame_idx in keyframe_indices:
            if frame_idx >= len(motion_frames):
                logger.warning(f"Frame index {frame_idx} out of range")
                continue

            # Extract 3D joints
            joints_3d = self.extract_joints_3d(motion_frames[frame_idx])

            # Project to 2D
            joints_2d = self.project_3d_to_2d(joints_3d)

            # Render as image
            skeleton_image = self.render_skeleton_image(joints_2d)

            skeleton_images.append((frame_idx, skeleton_image))

            # Save to disk if output_dir specified
            if output_dir:
                output_path = output_dir / f"skeleton_{frame_idx:04d}.png"
                skeleton_image.save(output_path)
                logger.info(f"  Saved: {output_path}")

        logger.info(f"✓ Rendered {len(skeleton_images)} skeleton images")
        return skeleton_images


def main():
    """Test the pose extractor."""
    from config import OUTPUT_DIR

    # Create mock motion data
    mock_frames = [
        {"raw_values": [float(i) for i in range(54)]} for i in range(10)
    ]

    extractor = PoseExtractor()
    keyframe_indices = extractor.select_keyframes(mock_frames, num_frames=6)
    skeleton_images = extractor.extract_and_render_skeletons(
        mock_frames, keyframe_indices, OUTPUT_DIR
    )

    logger.info(f"✓ Generated {len(skeleton_images)} skeleton images")


if __name__ == "__main__":
    main()
