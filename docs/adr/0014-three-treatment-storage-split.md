# Three-treatment storage split: public bucket for line, private bucket for color

Line-drawing files live in the public `media` bucket — the OG-friendly shareable URL needs unauthenticated read. Grayscale and original files live in the private `raw-archive` bucket and are served via short-lived signed URLs generated inside the `get_plan_full` RPC. Consent gates which signed URLs are returned, and treatment switching is free for the practice — both files are stored once; the client picks the rendering at playback time.
