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

# API Configuration
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

    if not SAYMOTION_CLIENT_ID:
        missing.append("SAYMOTION_CLIENT_ID")
    if not SAYMOTION_CLIENT_SECRET:
        missing.append("SAYMOTION_CLIENT_SECRET")
    if not REPLICATE_API_TOKEN:
        missing.append("REPLICATE_API_TOKEN")

    if missing:
        raise ValueError(
            f"Missing environment variables: {', '.join(missing)}. "
            f"Please copy .env.example to .env and fill in your API credentials."
        )

    logger.info("Configuration validated successfully")

if __name__ == "__main__":
    print(f"Project root: {PROJECT_ROOT}")
    print(f"Assets dir: {ASSETS_DIR}")
    print(f"Output dir: {OUTPUT_DIR}")
    print(f"Cache dir: {CACHE_DIR}")
    print(f"Log level: {LOG_LEVEL}")
