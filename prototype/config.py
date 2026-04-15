"""
Configuration module for the animation pipeline prototype.
Loads environment variables and defines API endpoints.
"""

import os
import logging
from pathlib import Path
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

# Motion Generation Configuration
# Choose which service to use: "hy_motion" (recommended), "saymotion", or "mock" (for local testing)
MOTION_SERVICE = os.getenv("MOTION_SERVICE", "hy_motion")

# HY-Motion Configuration (Tencent, open-source, free)
HY_MOTION_MODE = os.getenv("HY_MOTION_MODE", "runpod")  # "runpod" or "local"
HY_MOTION_RUNPOD_SSH = os.getenv("HY_MOTION_RUNPOD_SSH", "")
# Example: "ssh root@xyz.runpod.io -i ~/.ssh/runpod_key"

# SayMotion Configuration (DeepMotion API) - DEPRECATED
SAYMOTION_CLIENT_ID = os.getenv("SAYMOTION_CLIENT_ID", "")
SAYMOTION_CLIENT_SECRET = os.getenv("SAYMOTION_CLIENT_SECRET", "")
SAYMOTION_BASE_URL = "https://api.deepmotion.com"
SAYMOTION_AUTH_ENDPOINT = f"{SAYMOTION_BASE_URL}/account/v1/auth"
SAYMOTION_MOTION_ENDPOINT = f"{SAYMOTION_BASE_URL}/job/v1/process/text2motion"
SAYMOTION_STATUS_ENDPOINT = f"{SAYMOTION_BASE_URL}/job/v1/status"
SAYMOTION_DOWNLOAD_ENDPOINT = f"{SAYMOTION_BASE_URL}/job/v1/download"

REPLICATE_API_TOKEN = os.getenv("REPLICATE_API_TOKEN", "")
REPLICATE_API_URL = "https://api.replicate.com/v1"
REPLICATE_CONTROLNET_MODEL = "xlabs-ai/flux-controlnet"

# Stability AI API
STABILITY_API_KEY = os.getenv("STABILITY_API_KEY", "")
STABILITY_API_URL = "https://api.stability.ai/v2beta"

# Paths
PROJECT_ROOT = Path(__file__).parent.absolute()
ASSETS_DIR = PROJECT_ROOT / "assets"
OUTPUT_DIR = PROJECT_ROOT / "output"
CACHE_DIR = PROJECT_ROOT / ".cache"

# Ensure output directories exist
ASSETS_DIR.mkdir(parents=True, exist_ok=True)
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
CACHE_DIR.mkdir(parents=True, exist_ok=True)

# Logging Configuration
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL),
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)

logger = logging.getLogger(__name__)

# Validate required credentials
def validate_config():
    """Validate that all required API credentials are set."""
    missing = []

    # Check motion service configuration
    if MOTION_SERVICE == "hy_motion":
        if HY_MOTION_MODE == "runpod" and not HY_MOTION_RUNPOD_SSH:
            missing.append("HY_MOTION_RUNPOD_SSH (for RunPod mode)")
        logger.info(f"Using HY-Motion ({HY_MOTION_MODE} mode)")
    elif MOTION_SERVICE == "saymotion":
        if not SAYMOTION_CLIENT_ID:
            missing.append("SAYMOTION_CLIENT_ID")
        if not SAYMOTION_CLIENT_SECRET:
            missing.append("SAYMOTION_CLIENT_SECRET")
        logger.info("Using SayMotion API")
    elif MOTION_SERVICE == "mock":
        logger.info("Using Mock motion generator (local testing only)")
    else:
        missing.append("MOTION_SERVICE (must be 'hy_motion', 'saymotion', or 'mock')")

    # Check Replicate token (not needed for preview-only or mock testing)
    if MOTION_SERVICE != "mock" and not REPLICATE_API_TOKEN:
        missing.append("REPLICATE_API_TOKEN (optional for preview-only mode)")

    if missing:
        raise ValueError(
            f"Missing configuration: {', '.join(missing)}. "
            f"Please update .env with required values."
        )

    logger.info("Configuration validated successfully")

if __name__ == "__main__":
    print(f"Project root: {PROJECT_ROOT}")
    print(f"Assets dir: {ASSETS_DIR}")
    print(f"Output dir: {OUTPUT_DIR}")
    print(f"Cache dir: {CACHE_DIR}")
    print(f"Log level: {LOG_LEVEL}")
