# Native iOS video pipeline via Flutter platform channel

Line-drawing conversion runs as native Swift through a Flutter platform channel (`VideoConverterChannel.swift`), not via OpenCV or Dart. OpenCV iOS `VideoCapture` cannot decode H.264 or HEVC; AVAssetReader/Writer + vImage handles both directly. OpenCV is still used for image-level operations inside the algorithm.
