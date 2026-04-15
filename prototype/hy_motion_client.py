"""
HY-Motion Client

Handles text-to-motion generation using Tencent's HY-Motion 1.0.
Supports both local GPU and remote RunPod execution.
"""

import logging
import subprocess
import os
import tempfile
import json
import base64
from typing import List, Optional, Dict
from pathlib import Path
import time

from config import OUTPUT_DIR, CACHE_DIR

logger = logging.getLogger(__name__)


class HYMotionClient:
    """Client for Tencent HY-Motion 1.0 text-to-motion generation."""

    def __init__(self, mode: str = "runpod", runpod_ssh: Optional[str] = None):
        """
        Initialize HY-Motion client.

        Args:
            mode: "runpod" for remote execution, "local" for local GPU
            runpod_ssh: SSH connection string if using RunPod
                       (e.g., "ssh root@xyz.runpod.io -i /path/to/key")
        """
        self.mode = mode
        self.runpod_ssh = runpod_ssh
        self.remote_dir = "/HY-Motion-1.0"
        self.remote_model_path = "/HY-Motion-1.0/ckpts/tencent/HY-Motion-1.0"
        self.remote_input_dir = "/tmp/hy_motion_input"
        self.remote_output_dir = "/tmp/hy_motion_output"
        self.local_output_dir = OUTPUT_DIR / "hy_motion_outputs"
        self.local_output_dir.mkdir(parents=True, exist_ok=True)

        if mode == "runpod" and not runpod_ssh:
            logger.error("RunPod mode requires runpod_ssh parameter")
            raise ValueError("RunPod SSH connection string required")

        self._verify_setup()

    def _verify_setup(self):
        """Verify HY-Motion is available in the configured mode."""
        if self.mode == "local":
            # Check if HY-Motion is installed locally
            try:
                result = subprocess.run(
                    ["python", "-c", "import hy_motion"],
                    capture_output=True,
                    timeout=5
                )
                if result.returncode != 0:
                    logger.warning(
                        "HY-Motion not found locally. "
                        "Install from https://github.com/Tencent-Hunyuan/HY-Motion-1.0"
                    )
            except Exception as e:
                logger.warning(f"Could not verify local HY-Motion: {e}")

        elif self.mode == "runpod":
            # Test SSH connection and verify HY-Motion installation
            try:
                result = subprocess.run(
                    f"{self.runpod_ssh} 'ls -d /HY-Motion-1.0'",
                    shell=True,
                    capture_output=True,
                    timeout=10,
                    text=True
                )
                if result.returncode == 0:
                    logger.info("✓ RunPod connection verified")
                    logger.info("✓ HY-Motion-1.0 directory found")
                else:
                    logger.error(f"HY-Motion not found on RunPod: {result.stderr}")
            except Exception as e:
                logger.error(f"RunPod SSH error: {e}")

    def _run_remote(self, command: str) -> str:
        """
        Execute command on RunPod via SSH.

        Args:
            command: Command to run on remote pod

        Returns:
            str: Command output
        """
        full_cmd = f"{self.runpod_ssh} '{command}'"
        logger.debug(f"Running remote: {command}")

        try:
            result = subprocess.run(
                full_cmd,
                shell=True,
                capture_output=True,
                timeout=600,  # 10 min timeout
                text=True
            )

            if result.returncode != 0:
                logger.error(f"Remote error: {result.stderr}")
                return None

            return result.stdout

        except subprocess.TimeoutExpired:
            logger.error("Remote command timed out")
            return None
        except Exception as e:
            logger.error(f"Remote execution error: {e}")
            return None

    def _run_local(self, command: str) -> str:
        """
        Execute command locally on GPU machine.

        Args:
            command: Command to run

        Returns:
            str: Command output
        """
        logger.debug(f"Running locally: {command}")

        try:
            result = subprocess.run(
                command,
                shell=True,
                capture_output=True,
                timeout=600,  # 10 min timeout
                text=True
            )

            if result.returncode != 0:
                logger.error(f"Local error: {result.stderr}")
                return None

            return result.stdout

        except subprocess.TimeoutExpired:
            logger.error("Local command timed out")
            return None
        except Exception as e:
            logger.error(f"Local execution error: {e}")
            return None

    def generate_motion(
        self,
        prompt: str,
        duration: int = 8,
        output_name: str = "motion"
    ) -> Optional[bytes]:
        """
        Generate 3D motion from text prompt.

        Args:
            prompt: Exercise description (e.g., "Standing bicep curl with dumbbell")
            duration: Animation duration in seconds (default 8)
            output_name: Name for output BVH file (default "motion")

        Returns:
            bytes: BVH file content if successful, None otherwise
        """
        logger.info(f"Generating motion: {prompt}")
        logger.info(f"Duration: {duration}s")

        # Create temporary input file with the prompt
        input_filename = f"{output_name}_input.txt"

        if self.mode == "runpod":
            # Create input text file on RunPod using base64 encoding (avoids quoting issues)
            input_content = f"{prompt}|{duration}"
            encoded_content = base64.b64encode(input_content.encode()).decode()

            cmd = (
                f"mkdir -p {self.remote_input_dir} {self.remote_output_dir} && "
                f"echo {encoded_content} | base64 -d > {self.remote_input_dir}/{input_filename}"
            )
            result = self._run_remote(cmd)
            if not result:
                logger.error("Failed to create input file on RunPod")
                return None

            logger.debug(f"✓ Input file created: {input_filename}")

            # Run local_infer.py on RunPod
            cmd = (
                f"cd {self.remote_dir} && "
                f"python local_infer.py "
                f"--model_path {self.remote_model_path} "
                f"--input_text_dir {self.remote_input_dir} "
                f"--output_dir {self.remote_output_dir} "
                f"--disable_rewrite "
                f"--disable_duration_est"
            )
            logger.info("Submitting to RunPod...")
            output = self._run_remote(cmd)

            if not output:
                logger.error("Motion generation failed")
                return None

            logger.info("Motion generation completed")

            # Download BVH file from RunPod
            try:
                remote_bvh_path = f"{self.remote_output_dir}/{output_name}_0.bvh"
                local_bvh_path = self.local_output_dir / f"{output_name}.bvh"

                # Download via SCP
                remote_spec = self.runpod_ssh.replace("ssh ", "").replace(" -i", " -i")
                scp_cmd = f"scp -i ~/.ssh/runpod_key {remote_spec}:{remote_bvh_path} {local_bvh_path}"
                logger.info(f"Downloading BVH file...")

                result = subprocess.run(
                    scp_cmd,
                    shell=True,
                    capture_output=True,
                    timeout=30
                )

                if result.returncode != 0:
                    logger.error(f"SCP download failed: {result.stderr.decode()}")
                    return None

                # Read local file
                with open(local_bvh_path, "rb") as f:
                    bvh_content = f.read()

                logger.info(f"✓ BVH downloaded ({len(bvh_content)} bytes)")
                return bvh_content

            except Exception as e:
                logger.error(f"Download error: {e}")
                return None

        else:
            # Local mode
            logger.error("Local mode not yet implemented for this interface")
            return None

    def parse_bvh(self, bvh_content: bytes) -> List[Dict]:
        """
        Parse BVH file and extract joint positions per frame.

        Args:
            bvh_content: Raw BVH file content

        Returns:
            list: List of frame dicts with joint positions
        """
        try:
            bvh_text = bvh_content.decode("utf-8")
            lines = bvh_text.strip().split("\n")

            frames_data = []
            in_motion = False

            # Parse BVH header and motion data
            for line in lines:
                if line.strip() == "MOTION":
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

    def generate_and_parse(
        self,
        prompt: str,
        duration: int = 8
    ) -> Optional[List[Dict]]:
        """
        End-to-end: generate motion and parse BVH.

        Args:
            prompt: Exercise description
            duration: Animation duration in seconds

        Returns:
            list: Parsed motion frames, or None if failed
        """
        bvh_content = self.generate_motion(prompt, duration)
        if not bvh_content:
            return None

        motion_frames = self.parse_bvh(bvh_content)
        return motion_frames if motion_frames else None


def main():
    """Test HY-Motion client."""
    import os

    # Get RunPod SSH string from environment or prompt
    runpod_ssh = os.getenv("HY_MOTION_RUNPOD_SSH")
    if not runpod_ssh:
        print("\nTo test with RunPod, set HY_MOTION_RUNPOD_SSH environment variable:")
        print("  export HY_MOTION_RUNPOD_SSH='ssh root@xyz.runpod.io -i /path/to/key'")
        print("\nOr edit config.py to use local mode if you have a local GPU")
        return

    # Test with RunPod
    client = HYMotionClient(mode="runpod", runpod_ssh=runpod_ssh)

    motion_data = client.generate_and_parse(
        "Standing bicep curl with dumbbell",
        duration=8
    )

    if motion_data:
        logger.info(f"✓ Successfully generated motion with {len(motion_data)} frames")
    else:
        logger.error("Failed to generate motion")


if __name__ == "__main__":
    main()
