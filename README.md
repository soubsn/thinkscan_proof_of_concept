# ThinkScan Video Processor

A macOS application for real-time object detection and tracking using CoreML and YOLO models. Process videos or live camera feeds to detect and track objects with annotated output.

## Features

- **Video Processing**: Load and process video files with object detection
- **Live Camera Feed**: Real-time object detection from your Mac's camera
- **Object Detection**: Uses YOLO11 models (nano and large variants) for accurate detection
- **Object Tracking**: Tracks detected objects across frames with confidence scoring
- **Annotated Video Export**: Save processed videos with bounding boxes and labels
- **Statistics Export**: Export detailed tracking data and statistics to CSV format
- **Modern SwiftUI Interface**: Clean, intuitive macOS interface with progress tracking

## Requirements

- macOS 13.0 or later
- Xcode 15.0 or later
- Swift 5.9 or later
- Mac with Apple Silicon or Intel processor

## Installation

1. Clone the repository:
```bash
git clone https://github.com/soubsn/thinkscan_proof_of_concept.git
cd thinkscan_proof_of_concept
```

2. Open the project in Xcode:
```bash
open thinkscan_proof_of_concept.xcodeproj
```

3. Build and run the project (⌘R)

## Usage

### Processing a Video

1. Click "Select Video" to choose a video file
2. The application will automatically begin processing
3. Monitor progress through the progress bar
4. When complete, click "Save Video" to export the annotated video
5. Click "Save Stats" to export tracking data as CSV

### Using Live Camera

1. Click "Start Camera" to begin live processing
2. The camera will display real-time object detection
3. Click "Stop Camera" when finished
4. Export video and statistics as desired

### Canceling Processing

Click the "Cancel" button in the top-right corner at any time to stop processing and reset the application.

## Project Structure

```
thinkscan_proof_of_concept/
├── Algorithm/
│   ├── CoreMLObjectDetection.swift    # Object detection using CoreML
│   ├── FeedAlgorithmProcessor.swift   # Frame processing logic
│   ├── FrameResult.swift              # Individual frame detection results
│   ├── TrackedItemsResult.swift       # Multi-frame tracking results
│   ├── Config.swift                   # Application configuration
│   └── yolo11*.mlpackage/             # YOLO11 ML models
├── MovieFeed/
│   ├── MovieFeedManager.swift         # Video file processing
│   ├── MovieWriter.swift              # Annotated video export
│   └── Logger.swift                   # Logging utilities
├── Extensions/
│   ├── CGRect-Extensions.swift        # Geometry helpers
│   ├── CVPixelBuffer-Extensions.swift # Image buffer utilities
│   └── ...                            # Other extensions
├── CameraFeedManager.swift            # Live camera capture
├── ContentView.swift                  # Main UI
└── thinkscan_proof_of_conceptApp.swift # App entry point
```

## Configuration

Key settings can be adjusted in `Algorithm/Config.swift`:

- **Detection Confidence Threshold**: Minimum confidence for object detection (default: 0.6)
- **Model Selection**: Choose between YOLO11n (nano) or YOLO11l (large)
- **Processing Quality**: Adjust QoS settings for performance tuning
- **Ensemble Threshold**: Configure frame grouping for tracking

## Technical Details

### Object Detection

The application uses Vision framework with YOLO11 CoreML models for object detection. Two model variants are included:

- **yolo11n**: Nano model - faster, lower accuracy
- **yolo11l**: Large model - slower, higher accuracy

### Video Processing Pipeline

1. Video frames are decoded from input
2. Each frame is processed through the ML model
3. Detections are tracked across frames
4. Results are aggregated for ensemble decisions
5. Annotated frames are written to output video

### Thread Safety

The application uses multiple queues for optimal performance:
- Main thread: UI updates
- Video writing queue: Background video encoding
- Processing queues: ML inference and frame processing

## Output Format

### Annotated Video
- Format: MP4
- Contains original video with overlaid bounding boxes
- Color-coded by object confidence

### Statistics CSV
- Frame-by-frame tracking data
- Object positions and movements
- Confidence scores
- Displacement calculations

## License

See LICENSE folder for licensing information.

## Acknowledgments

- YOLO models from Ultralytics
- Built with SwiftUI and Apple's Vision framework
- CoreML for on-device machine learning
