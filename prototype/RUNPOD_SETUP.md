# HY-Motion on RunPod Setup Guide

This guide walks you through setting up Tencent's HY-Motion 1.0 on RunPod for generating exercise animations.

## Why RunPod?

- **Pay-as-you-go:** $0.30-0.50/hour, no contracts
- **Easy setup:** Pre-configured GPU instances
- **Fast:** A100/H100 GPUs available
- **Developer-friendly:** Perfect for ML prototyping

## Step 1: Create RunPod Account

1. Go to https://www.runpod.io
2. Click "Sign Up"
3. Create account with email (or GitHub login)
4. Add payment method (they'll authorize a small test charge)

## Step 2: Launch a GPU Pod

1. Click **"Pods"** in the left sidebar
2. Click **"+ New Pod"**
3. **Select GPU:**
   - Recommended: **RTX 4090** (fast, affordable) ~$0.40/hour
   - Budget: **RTX 3090** (slower) ~$0.25/hour
   - Premium: **A100** (very fast) ~$1.00/hour
4. **Select template:** "PyTorch" or "CUDA"
5. **Set storage:** 50GB is plenty for this prototype
6. Click **"Connect"** (this launches the instance)

## Step 3: Connect to Your Pod

Once your pod is running, you have two options:

### Option A: Jupyter Notebook (Easier for testing)
1. Click the **"Jupyter Notebook"** button in the pod details
2. This opens a web-based Jupyter environment
3. Open a terminal in Jupyter (New → Terminal)

### Option B: SSH (For command-line control)
1. RunPod shows an SSH connection string like:
   ```
   ssh root@xyz.runpod.io -i /path/to/key
   ```
2. Copy and run this in your terminal
3. You'll be logged into the pod's terminal

**Note:** Jupyter is easier to start with. You can always SSH later.

## Step 4: Install HY-Motion

In the pod's terminal (Jupyter or SSH):

```bash
# Update system
apt update && apt upgrade -y

# Clone HY-Motion repo
git clone https://github.com/Tencent-Hunyuan/HY-Motion-1.0.git
cd HY-Motion-1.0

# Install dependencies
pip install -r requirements.txt

# Download the model weights (this takes a few minutes)
# The repo may have a script for this, or weights auto-download on first run
```

## Step 5: Test HY-Motion

```bash
# Run a quick test
python -m inference.py \
  --prompt "a person doing a standing bicep curl" \
  --output_dir ./outputs
```

You should see:
```
Loading model... 
Generating motion...
✓ Motion saved to outputs/motion.bvh
```

## Step 6: Connect Your Local Machine

Now we need to transfer motion files from RunPod to your local machine.

### Download files from RunPod:

```bash
# From your local terminal (not in RunPod):

# Copy a single file
scp -i /path/to/key root@xyz.runpod.io:/root/HY-Motion-1.0/outputs/motion.bvh ./

# Or copy entire outputs folder
scp -r -i /path/to/key root@xyz.runpod.io:/root/HY-Motion-1.0/outputs ./runpod_outputs
```

**For Jupyter (easier):** 
- Files are visible in Jupyter's file browser
- Right-click any file → Download

## Step 7: Update Your Prototype Config

Update `prototype/config.py`:

```python
# HY-Motion Configuration
HY_MOTION_ENABLED = True
HY_MOTION_MODE = "runpod"  # or "local" if you have a local GPU

# If running on RunPod:
HY_MOTION_RUNPOD_SSH = "ssh root@xyz.runpod.io -i /path/to/key"
HY_MOTION_REMOTE_DIR = "/root/HY-Motion-1.0"
HY_MOTION_OUTPUT_DIR = "/root/HY-Motion-1.0/outputs"

# If running locally:
# HY_MOTION_LOCAL_DIR = "/path/to/HY-Motion-1.0"
```

## Step 8: Run the Prototype

```bash
cd prototype
python main.py
```

The prototype will:
1. SSH into your RunPod instance
2. Run HY-Motion with your prompt
3. Download the BVH file to your local machine
4. Continue with pose extraction, rendering, etc.

## Cost Estimation

| Activity | GPU Time | Cost |
|----------|----------|------|
| Test HY-Motion | 5 min | $0.03 |
| Generate 10 exercises | 15 min | $0.10 |
| Generate 100 exercises | 2.5 hours | $1.00 |
| Full pipeline (100 exercises) | 3-4 hours | $1.50-2.00 |

## Troubleshooting

### "Connection timeout"
- Check your SSH key is correct
- Verify pod is still running (RunPod may auto-stop after idle time)
- Restart the pod

### "Out of memory"
- You need at least 24GB VRAM
- Try a larger GPU (A100 has 40GB)
- Or reduce motion generation duration

### "Model weights not found"
- First run auto-downloads weights (~5 min)
- Or manually download from HuggingFace (link in HY-Motion README)

### "BVH file is empty"
- Check the prompt is descriptive enough
- Try: "A person in standing position performing a slow controlled bicep curl with a dumbbell"

## Stopping Your Pod

**Important:** Stop your pod when not using it to avoid charges!

1. Go to https://www.runpod.io/console/pods
2. Find your pod
3. Click **"Stop"** (or "Terminate" if you won't use it again)

Even stopped pods may incur small storage charges, so **Terminate** if you're done for the day.

## Next Steps

Once HY-Motion is working:
1. Generate 6 keyframe motions for your test exercises
2. Run the full prototype pipeline (pose → ControlNet → equipment → animation)
3. Review the output and refine prompts if needed

## Questions?

- RunPod docs: https://www.runpod.io/docs
- HY-Motion repo: https://github.com/Tencent-Hunyuan/HY-Motion-1.0
- HY-Motion paper: https://arxiv.org/abs/2501.04588
