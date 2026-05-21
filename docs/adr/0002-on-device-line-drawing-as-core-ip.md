# On-device line-drawing pipeline as the core IP

All visual conversion runs on the device (iOS Swift + AVFoundation + vImage). No exercise footage leaves the phone unless the practitioner publishes, and the published variant is the de-identified line drawing.

## Considered Options

Cloud AI style transfer via Stability AI, Kling O1, and SayMotion was considered and rejected for MVP: API costs, latency, privacy concerns, and the fact that the trainer's iPhone already has enough silicon to do the work. AI style transfer is parked as a premium-tier future.
