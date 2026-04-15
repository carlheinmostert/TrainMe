"""
Animation Assembler

Compiles rendered frames into animations (Lottie, sprite sheets, or HTML viewers).
"""

import logging
import json
from typing import List, Optional
from pathlib import Path
from PIL import Image
import base64

from config import OUTPUT_DIR

logger = logging.getLogger(__name__)


class AnimationAssembler:
    """Assembles rendered frames into viewable animations."""

    def __init__(self):
        """Initialize the animation assembler."""
        pass

    def create_sprite_sheet(
        self,
        frames: List[Image.Image],
        output_path: Optional[Path] = None,
        frames_per_row: int = 3,
    ) -> Image.Image:
        """
        Create a sprite sheet from frames arranged in a grid.

        Args:
            frames: List of PIL Images
            output_path: Path to save sprite sheet (optional)
            frames_per_row: Number of frames per row in grid (default 3)

        Returns:
            PIL.Image: Combined sprite sheet
        """
        if not frames:
            logger.error("No frames provided")
            return None

        frame_width, frame_height = frames[0].size

        num_frames = len(frames)
        num_rows = (num_frames + frames_per_row - 1) // frames_per_row
        num_cols = min(frames_per_row, num_frames)

        sprite_width = num_cols * frame_width
        sprite_height = num_rows * frame_height

        # Create blank sprite sheet
        sprite_sheet = Image.new("RGB", (sprite_width, sprite_height), color="white")

        # Paste frames into grid
        for i, frame in enumerate(frames):
            row = i // frames_per_row
            col = i % frames_per_row
            x = col * frame_width
            y = row * frame_height
            sprite_sheet.paste(frame, (x, y))

        if output_path:
            sprite_sheet.save(output_path)
            logger.info(f"✓ Sprite sheet saved to {output_path}")
        else:
            logger.info(f"✓ Created sprite sheet ({sprite_width}x{sprite_height})")

        return sprite_sheet

    def create_html_viewer(
        self,
        frames: List[Image.Image],
        output_path: Optional[Path] = None,
    ) -> str:
        """
        Create an HTML viewer for stepping through frames.

        Args:
            frames: List of PIL Images
            output_path: Path to save HTML file (optional)

        Returns:
            str: HTML content
        """
        if not frames:
            logger.error("No frames provided")
            return ""

        # Convert frames to base64 data URLs
        frame_data_urls = []
        for i, frame in enumerate(frames):
            # Convert to RGB if necessary
            if frame.mode != "RGB":
                frame = frame.convert("RGB")

            # Save to bytes and encode
            import io

            buffer = io.BytesIO()
            frame.save(buffer, format="PNG")
            img_base64 = base64.b64encode(buffer.getvalue()).decode()
            data_url = f"data:image/png;base64,{img_base64}"
            frame_data_urls.append(data_url)

        # Create HTML
        html = f"""<!DOCTYPE html>
<html>
<head>
    <title>Exercise Animation Viewer</title>
    <style>
        body {{
            font-family: Arial, sans-serif;
            display: flex;
            flex-direction: column;
            align-items: center;
            padding: 20px;
            background-color: #f0f0f0;
        }}

        .container {{
            background-color: white;
            border-radius: 8px;
            padding: 20px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            max-width: 800px;
        }}

        h1 {{
            color: #333;
            margin-top: 0;
        }}

        #canvas {{
            border: 2px solid #ccc;
            display: block;
            margin: 20px auto;
            max-width: 100%;
            background-color: #f9f9f9;
        }}

        .controls {{
            display: flex;
            gap: 10px;
            justify-content: center;
            margin: 20px 0;
            flex-wrap: wrap;
        }}

        button {{
            padding: 10px 20px;
            font-size: 16px;
            background-color: #4CAF50;
            color: white;
            border: none;
            border-radius: 4px;
            cursor: pointer;
            transition: background-color 0.3s;
        }}

        button:hover {{
            background-color: #45a049;
        }}

        button:disabled {{
            background-color: #ccc;
            cursor: not-allowed;
        }}

        .info {{
            text-align: center;
            color: #666;
            font-size: 14px;
        }}

        .frame-counter {{
            font-weight: bold;
            color: #333;
        }}

        input[type="range"] {{
            width: 100%;
            margin: 10px 0;
        }}
    </style>
</head>
<body>
    <div class="container">
        <h1>Exercise Animation Viewer</h1>

        <img id="canvas" src="" alt="Frame" />

        <div class="controls">
            <button id="prevBtn">← Previous</button>
            <button id="playBtn">▶ Play</button>
            <button id="nextBtn">Next →</button>
            <button id="resetBtn">Reset</button>
        </div>

        <input type="range" id="frameSlider" min="0" max="0" value="0" />

        <div class="info">
            <p>Frame: <span class="frame-counter" id="frameCounter">1</span> / {len(frame_data_urls)}</p>
            <p>Speed: <select id="speedSelect">
                <option value="0.5">Slow (0.5x)</option>
                <option value="1" selected>Normal (1x)</option>
                <option value="2">Fast (2x)</option>
            </select></p>
        </div>
    </div>

    <script>
        const frames = {json.dumps(frame_data_urls)};
        let currentFrame = 0;
        let isPlaying = false;
        let animationSpeed = 500; // ms per frame
        let animationTimer = null;

        const canvas = document.getElementById('canvas');
        const prevBtn = document.getElementById('prevBtn');
        const playBtn = document.getElementById('playBtn');
        const nextBtn = document.getElementById('nextBtn');
        const resetBtn = document.getElementById('resetBtn');
        const frameSlider = document.getElementById('frameSlider');
        const frameCounter = document.getElementById('frameCounter');
        const speedSelect = document.getElementById('speedSelect');

        // Set slider max
        frameSlider.max = frames.length - 1;

        function updateFrame() {{
            canvas.src = frames[currentFrame];
            frameCounter.textContent = currentFrame + 1;
            frameSlider.value = currentFrame;
        }}

        function previousFrame() {{
            if (currentFrame > 0) {{
                currentFrame--;
                updateFrame();
            }}
        }}

        function nextFrame() {{
            if (currentFrame < frames.length - 1) {{
                currentFrame++;
                updateFrame();
            }} else if (isPlaying) {{
                // Loop back to start when playing
                currentFrame = 0;
                updateFrame();
            }}
        }}

        function togglePlay() {{
            isPlaying = !isPlaying;
            if (isPlaying) {{
                playBtn.textContent = '⏸ Pause';
                animate();
            }} else {{
                playBtn.textContent = '▶ Play';
                if (animationTimer) clearTimeout(animationTimer);
            }}
        }}

        function animate() {{
            if (!isPlaying) return;

            nextFrame();

            if (isPlaying && currentFrame < frames.length - 1) {{
                animationTimer = setTimeout(animate, animationSpeed);
            }} else if (isPlaying && currentFrame === frames.length - 1) {{
                // Loop
                currentFrame = 0;
                updateFrame();
                animationTimer = setTimeout(animate, animationSpeed);
            }}
        }}

        function reset() {{
            isPlaying = false;
            playBtn.textContent = '▶ Play';
            currentFrame = 0;
            if (animationTimer) clearTimeout(animationTimer);
            updateFrame();
        }}

        // Event listeners
        prevBtn.addEventListener('click', previousFrame);
        playBtn.addEventListener('click', togglePlay);
        nextBtn.addEventListener('click', nextFrame);
        resetBtn.addEventListener('click', reset);
        frameSlider.addEventListener('input', (e) => {{
            currentFrame = parseInt(e.target.value);
            updateFrame();
        }});
        speedSelect.addEventListener('change', (e) => {{
            const speedMultiplier = parseFloat(e.target.value);
            animationSpeed = 500 / speedMultiplier;
        }});

        // Initialize
        updateFrame();
    </script>
</body>
</html>
"""

        if output_path:
            output_path.write_text(html)
            logger.info(f"✓ HTML viewer saved to {output_path}")

        return html

    def create_lottie_animation(
        self,
        frames: List[Image.Image],
        duration_per_frame: float = 0.3,
        output_path: Optional[Path] = None,
    ) -> Optional[str]:
        """
        Create a simple Lottie JSON animation from frames.

        Note: This is a simplified Lottie creation. Full Lottie format support
        would require the lottie library or more complex JSON construction.

        Args:
            frames: List of PIL Images
            duration_per_frame: Duration per frame in seconds (default 0.3)
            output_path: Path to save Lottie JSON (optional)

        Returns:
            str: Lottie JSON string if successful, None otherwise
        """
        if not frames:
            logger.error("No frames provided")
            return None

        try:
            # Create a basic Lottie animation structure
            # This is simplified - real Lottie format is more complex
            lottie_data = {
                "v": "5.7.0",
                "fr": 30,  # Frame rate
                "ip": 0,
                "op": len(frames) * 10,
                "w": frames[0].width,
                "h": frames[0].height,
                "nm": "Exercise Animation",
                "ddd": 0,
                "assets": [],
                "layers": [],
                "markers": [],
            }

            # Create assets for each frame
            for i, frame in enumerate(frames):
                import io

                # Convert frame to PNG bytes
                buffer = io.BytesIO()
                if frame.mode != "RGB":
                    frame = frame.convert("RGB")
                frame.save(buffer, format="PNG")
                img_base64 = base64.b64encode(buffer.getvalue()).decode()

                asset = {
                    "id": f"image_{i}",
                    "w": frame.width,
                    "h": frame.height,
                    "u": "",
                    "p": f"data:image/png;base64,{img_base64}",
                    "e": 0,
                }
                lottie_data["assets"].append(asset)

            # Note: Full Lottie format requires proper layer and shape definitions
            # This is a placeholder that won't render properly in Lottie viewers
            # A production version would use the lottie library or full format

            json_str = json.dumps(lottie_data, indent=2)

            if output_path:
                output_path.write_text(json_str)
                logger.info(f"✓ Lottie animation saved to {output_path}")
                logger.warning("⚠ Simplified Lottie format - may not render in all players")

            return json_str

        except Exception as e:
            logger.error(f"Error creating Lottie: {e}")
            return None

    def assemble_animation(
        self,
        frames: List[Image.Image],
        exercise_name: str = "exercise",
        output_dir: Optional[Path] = None,
    ) -> dict:
        """
        Assemble frames into multiple formats.

        Args:
            frames: List of PIL Images
            exercise_name: Name of exercise for file naming
            output_dir: Directory to save outputs (default: OUTPUT_DIR)

        Returns:
            dict: Paths to generated files
        """
        if not output_dir:
            output_dir = OUTPUT_DIR

        output_dir.mkdir(parents=True, exist_ok=True)

        outputs = {}

        logger.info(f"\nAssembling animation from {len(frames)} frames...")

        # 1. Sprite sheet
        sprite_path = output_dir / f"{exercise_name}_spritesheet.png"
        self.create_sprite_sheet(frames, sprite_path)
        outputs["sprite_sheet"] = sprite_path

        # 2. HTML viewer
        html_path = output_dir / f"{exercise_name}_viewer.html"
        self.create_html_viewer(frames, html_path)
        outputs["html_viewer"] = html_path

        # 3. Lottie (simplified)
        lottie_path = output_dir / f"{exercise_name}_animation.json"
        self.create_lottie_animation(frames, output_path=lottie_path)
        outputs["lottie"] = lottie_path

        logger.info(f"✓ Animation assembled with {len(outputs)} formats")
        return outputs


def main():
    """Test the animation assembler."""
    from config import OUTPUT_DIR

    # Create test frames
    test_frames = []
    for i in range(6):
        img = Image.new("RGB", (512, 512), color=(200 + i * 5, 200 + i * 5, 200 + i * 5))
        # Add simple text to each frame
        from PIL import ImageDraw

        draw = ImageDraw.Draw(img)
        draw.text((10, 10), f"Frame {i + 1}", fill="black")
        test_frames.append(img)

    assembler = AnimationAssembler()
    outputs = assembler.assemble_animation(test_frames, "test_exercise", OUTPUT_DIR)

    logger.info(f"\nGenerated files:")
    for format_name, path in outputs.items():
        if path and path.exists():
            logger.info(f"  {format_name}: {path}")


if __name__ == "__main__":
    main()
