"""
Equipment Compositor

Overlays equipment SVG assets onto rendered figures based on skeleton joint positions.
"""

import logging
import math
from typing import Tuple, Optional, Dict
import numpy as np
from PIL import Image
from pathlib import Path

from config import ASSETS_DIR

logger = logging.getLogger(__name__)


class EquipmentCompositor:
    """Composites equipment SVG assets onto rendered exercise figures."""

    def __init__(self):
        """Initialize the equipment compositor."""
        self.equipment_assets = {}
        self._create_default_assets()

    def _create_default_assets(self):
        """Create default equipment SVG assets."""
        # Create a simple dumbbell SVG
        self._create_dumbbell_svg()

    def _create_dumbbell_svg(self):
        """Create a simple dumbbell SVG asset."""
        dumbbell_svg = """<?xml version="1.0" encoding="UTF-8"?>
<svg width="100" height="100" viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <!-- Left weight plate -->
  <circle cx="15" cy="50" r="12" fill="none" stroke="black" stroke-width="2"/>
  <!-- Handle -->
  <rect x="30" y="45" width="40" height="10" fill="none" stroke="black" stroke-width="2"/>
  <!-- Right weight plate -->
  <circle cx="85" cy="50" r="12" fill="none" stroke="black" stroke-width="2"/>
</svg>
"""
        asset_path = ASSETS_DIR / "dumbbell.svg"
        asset_path.write_text(dumbbell_svg)
        logger.info(f"Created dumbbell asset at {asset_path}")

    def get_hand_positions(
        self, joints_2d: np.ndarray
    ) -> Tuple[Tuple[float, float], Tuple[float, float]]:
        """
        Extract left and right hand positions from skeleton joints.

        In OpenPose 18-point format:
        - Joint 4: Right Wrist
        - Joint 7: Left Wrist

        Args:
            joints_2d: Array of shape (18, 2) with 2D joint positions

        Returns:
            tuple: ((left_hand_x, left_hand_y), (right_hand_x, right_hand_y))
        """
        left_hand = tuple(joints_2d[7]) if len(joints_2d) > 7 else (0, 0)
        right_hand = tuple(joints_2d[4]) if len(joints_2d) > 4 else (0, 0)

        return (left_hand, right_hand)

    def get_elbow_positions(
        self, joints_2d: np.ndarray
    ) -> Tuple[Tuple[float, float], Tuple[float, float]]:
        """
        Extract left and right elbow positions from skeleton joints.

        In OpenPose 18-point format:
        - Joint 3: Right Elbow
        - Joint 6: Left Elbow

        Args:
            joints_2d: Array of shape (18, 2) with 2D joint positions

        Returns:
            tuple: ((left_elbow_x, left_elbow_y), (right_elbow_x, right_elbow_y))
        """
        left_elbow = tuple(joints_2d[6]) if len(joints_2d) > 6 else (0, 0)
        right_elbow = tuple(joints_2d[3]) if len(joints_2d) > 3 else (0, 0)

        return (left_elbow, right_elbow)

    def position_dumbbell(
        self,
        left_hand: Tuple[float, float],
        right_hand: Tuple[float, float],
        dumbbell_size: int = 30,
    ) -> Dict:
        """
        Calculate position and rotation for a dumbbell held in hands.

        Args:
            left_hand: (x, y) position of left hand
            right_hand: (x, y) position of right hand
            dumbbell_size: Size of dumbbell in pixels (default 30)

        Returns:
            dict: Position info with 'x', 'y', 'rotation', 'width', 'height'
        """
        # For bicep curls, we'll position the dumbbell based on which hand is lower
        # This is a simplified approach - real implementation would be more sophisticated

        left_x, left_y = left_hand
        right_x, right_y = right_hand

        # Choose which hand to use for positioning
        # For a bicep curl, typically one hand holds the dumbbell
        if abs(left_x - right_x) > 20:  # Hands are spread out
            # Position between hands
            center_x = (left_x + right_x) / 2
            center_y = (left_y + right_y) / 2

            # Calculate angle between hands
            dx = right_x - left_x
            dy = right_y - left_y
            rotation = math.degrees(math.atan2(dy, dx))
        else:
            # Hands are close, position at hand
            center_x = (left_x + right_x) / 2
            center_y = (left_y + right_y) / 2
            rotation = 0

        return {
            "x": center_x,
            "y": center_y,
            "rotation": rotation,
            "width": dumbbell_size,
            "height": dumbbell_size * 0.4,  # Dumbbell aspect ratio
        }

    def composite_dumbbell_simple(
        self,
        figure_image: Image.Image,
        joints_2d: np.ndarray,
    ) -> Image.Image:
        """
        Draw a simple dumbbell shape on the figure image using PIL.

        This is a simplified version that draws a dumbbell without using SVG.

        Args:
            figure_image: PIL Image of the rendered figure
            joints_2d: Array of shape (18, 2) with 2D joint positions

        Returns:
            PIL.Image: Image with composited dumbbell
        """
        from PIL import ImageDraw

        # Get hand positions
        left_hand, right_hand = self.get_hand_positions(joints_2d)

        # Create a copy to draw on
        result = figure_image.copy()
        draw = ImageDraw.Draw(result)

        # Position dumbbell
        dumbbell_info = self.position_dumbbell(left_hand, right_hand)

        center_x = dumbbell_info["x"]
        center_y = dumbbell_info["y"]
        rotation = dumbbell_info["rotation"]
        dumbbell_size = dumbbell_info["width"]

        # Draw simplified dumbbell (two circles connected by a line)
        radius = dumbbell_size / 2

        # Calculate positions relative to center
        offset_x = dumbbell_size * 0.8
        offset_y = dumbbell_size * 0.2

        # Rotate offsets based on dumbbell rotation
        rad = math.radians(rotation)
        cos_r = math.cos(rad)
        sin_r = math.sin(rad)

        left_plate_x = center_x - offset_x * cos_r + offset_y * sin_r
        left_plate_y = center_y - offset_x * sin_r - offset_y * cos_r

        right_plate_x = center_x + offset_x * cos_r + offset_y * sin_r
        right_plate_y = center_y + offset_x * sin_r - offset_y * cos_r

        # Draw left weight plate
        draw.ellipse(
            [
                (left_plate_x - radius, left_plate_y - radius),
                (left_plate_x + radius, left_plate_y + radius),
            ],
            outline="black",
            width=2,
        )

        # Draw handle
        draw.line(
            [(left_plate_x + radius, left_plate_y), (right_plate_x - radius, right_plate_y)],
            fill="black",
            width=3,
        )

        # Draw right weight plate
        draw.ellipse(
            [
                (right_plate_x - radius, right_plate_y - radius),
                (right_plate_x + radius, right_plate_y + radius),
            ],
            outline="black",
            width=2,
        )

        logger.info(f"Composited dumbbell at ({center_x:.0f}, {center_y:.0f}), rotation={rotation:.1f}°")
        return result

    def composite_resistance_band(
        self,
        figure_image: Image.Image,
        joints_2d: np.ndarray,
        anchor_joint_1: int = 10,  # Right ankle
        anchor_joint_2: int = 4,   # Right wrist
    ) -> Image.Image:
        """
        Composite a resistance band between two anchor points (e.g., foot to hand).

        Args:
            figure_image: PIL Image of rendered figure
            joints_2d: Array of shape (18, 2) with 2D joint positions
            anchor_joint_1: Index of first anchor joint
            anchor_joint_2: Index of second anchor joint

        Returns:
            PIL.Image: Image with composited band
        """
        from PIL import ImageDraw

        result = figure_image.copy()
        draw = ImageDraw.Draw(result)

        if len(joints_2d) <= max(anchor_joint_1, anchor_joint_2):
            logger.warning("Not enough joints for band anchoring")
            return result

        # Get anchor points
        point_1 = tuple(joints_2d[anchor_joint_1])
        point_2 = tuple(joints_2d[anchor_joint_2])

        # Draw band as a thick line
        draw.line([point_1, point_2], fill="red", width=4)

        logger.info(f"Composited resistance band from joint {anchor_joint_1} to {anchor_joint_2}")
        return result

    def composite_equipment(
        self,
        figure_image: Image.Image,
        joints_2d: np.ndarray,
        equipment_type: str = "dumbbell",
    ) -> Image.Image:
        """
        Main method to composite equipment onto a figure image.

        Args:
            figure_image: PIL Image of rendered figure
            joints_2d: Array of shape (18, 2) with 2D joint positions
            equipment_type: Type of equipment ('dumbbell', 'band', etc.)

        Returns:
            PIL.Image: Image with composited equipment
        """
        if equipment_type == "dumbbell":
            return self.composite_dumbbell_simple(figure_image, joints_2d)
        elif equipment_type == "band":
            return self.composite_resistance_band(figure_image, joints_2d)
        else:
            logger.warning(f"Unknown equipment type: {equipment_type}")
            return figure_image


def main():
    """Test the equipment compositor."""
    from config import OUTPUT_DIR
    import numpy as np

    # Create a test image
    test_image = Image.new("RGB", (512, 512), color="white")

    # Create mock skeleton data
    mock_joints_2d = np.array([
        [256, 50],   # 0: Nose
        [256, 100],  # 1: Neck
        [220, 150],  # 2: RShoulder
        [200, 200],  # 3: RElbow
        [180, 250],  # 4: RWrist
        [290, 150],  # 5: LShoulder
        [310, 200],  # 6: LElbow
        [330, 250],  # 7: LWrist
        [230, 300],  # 8: RHip
        [230, 350],  # 9: RKnee
        [230, 450],  # 10: RAnkle
        [280, 300],  # 11: LHip
        [280, 350],  # 12: LKnee
        [280, 450],  # 13: LAnkle
        [240, 40],   # 14: REye
        [270, 40],   # 15: LEye
        [230, 20],   # 16: REar
        [280, 20],   # 17: LEar
    ])

    compositor = EquipmentCompositor()

    # Test dumbbell compositing
    dumbbell_result = compositor.composite_equipment(test_image, mock_joints_2d, "dumbbell")
    dumbbell_result.save(OUTPUT_DIR / "test_dumbbell.png")
    logger.info("✓ Test dumbbell output saved")

    # Test band compositing
    band_result = compositor.composite_equipment(test_image, mock_joints_2d, "band")
    band_result.save(OUTPUT_DIR / "test_band.png")
    logger.info("✓ Test band output saved")


if __name__ == "__main__":
    main()
