import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import Combine
import AppKit

// MARK: - Processing State
enum ProcessingState {
	case idle
	case processing
	case completed
	case cancelled
	case savingVideo
}

// MARK: - Input Source
enum InputSource {
	case video
	case camera
}

// MARK: - VideoProcessingViewModel
class FeedProcessingViewModel: ObservableObject, MovieFeedManagerDelegate, CameraFeedManagerDelegate {
	// MARK: - MovieFeedManagerDelegate (may be called from background threads)
	
	func didReceiveNextMovieBuffer(_ pixelBuffer: CVPixelBuffer?) {
		if cancelRequested { return }
		
		guard let pixelBuffer = pixelBuffer else {
			print("error: pixelBuffer is nil")
			Task { @MainActor in
				self.finish(ProcessingState.completed)
			}
			return
		}
		guard let feedAlgorithmProcessor = feedAlgorithmProcessor, let movieManager = movieManager else {
			print("error: navAlgorithm or movieManager are nil")
			Task { @MainActor in
				self.finish(ProcessingState.completed)
			}
			return
		}
		
		feedAlgorithmProcessor.runAlgorithm(pixelBuffer: pixelBuffer, isMoviePlaybackBuffer: true)
		
		// Safely read frame numbers (these are atomic operations)
		let currentFrameNum = movieManager.frameNum
		let totalFrames = movieManager.totalFrames
		
		if currentFrameNum % frameCountPerAlgorithmCall == 0 {
			feedAlgorithmProcessor.executeCombinedProcessing()
		}
		
		// Update progress on main thread
		Task { @MainActor in
			self.currentFrame = Int(currentFrameNum)
			self.progress = Double(currentFrameNum) / Double(totalFrames)
		}
		
		if currentFrameNum >= totalFrames {
			feedAlgorithmProcessor.executeCombinedProcessing()
			Task { @MainActor in
				self.didFinishMovie()
			}
		} else {
			movieManager.getNextFrame()
		}
	}
	
	func didEncounterError(_ error: String) {
		print("movieManager encountered an error: \(error)")
		Task { @MainActor in
			self.finish(ProcessingState.cancelled)
		}
	}
	
	func didFinishMovie() {
		print("movieManager time over for video")
		// The calculation will be done when saving stats
		// Set processedVideoURL to enable the save button
		Task { @MainActor in
			self.processedVideoURL = self.selectedVideoURL // Placeholder to enable save button
		}
		finish(ProcessingState.completed)
	}
	
	func didFinishLoadingMovie() {
		if cancelRequested { return }
		// Now it's safe to start processing frames
		guard let movieManager = movieManager else { return }
		
		// Update UI with total frames on main thread
		let totalFrames = Int(movieManager.totalFrames)
		let fps = movieManager.fps
		
		Task { @MainActor in
			self.totalFrames = totalFrames
			self.frameCountPerAlgorithmCall = Int64(Double(fps) * Config.Processing.ensembleThresholdTime)
			movieManager.getNextFrame()
		}
	}
	
	func didGet(colorSpace: CGColorSpace, bitmapInfo: UInt32) {}
	
	// MARK: - CameraFeedManagerDelegate (may be called from background threads)
	
	func didReceiveCameraBuffer(_ pixelBuffer: CVPixelBuffer?) {
		if cancelRequested { return }
		guard let pixelBuffer = pixelBuffer else {
			print("error: camera pixelBuffer is nil")
			return
		}
		guard let feedAlgorithmProcessor = feedAlgorithmProcessor else {
			print("error: videoAlgorithmProcessor is nil")
			return
		}
		
		feedAlgorithmProcessor.runAlgorithm(pixelBuffer: pixelBuffer, isMoviePlaybackBuffer: false)
		
		// Update frame count for camera on main thread
		Task { @MainActor in
			self.currentFrame += 1
			
			// Execute combined processing periodically (e.g., every 30 frames for real-time feedback)
			if self.currentFrame % 30 == 0 {
				feedAlgorithmProcessor.executeCombinedProcessing()
			}
		}
	}
	
	func didEncounterCameraError(_ error: String) {
		print("cameraManager encountered an error: \(error)")
		Task { @MainActor in
			self.errorMessage = error
			self.isCameraRunning = false
			self.processingState = .idle
			self.stopCamera()
		}
	}
	
	func didStartCamera() {
		print("Camera started successfully")
		Task { @MainActor in
			self.isCameraRunning = true
			self.processingState = .processing
			self.inputSource = .camera
			self.currentFrame = 0
			self.totalFrames = 0 // Camera has no predefined total
		}
	}
	
	func didStopCamera() {
		print("Camera stopped")
		Task { @MainActor in
			self.isCameraRunning = false
			self.processingState = .completed
		}
	}
	
	// MARK: - Published Properties (Main Actor)
	@MainActor @Published var selectedVideoURL: URL?
	@MainActor @Published var processingState: ProcessingState = .idle
	@MainActor @Published var inputSource: InputSource = .video
	@MainActor @Published var progress: Double = 0.0
	@MainActor @Published var currentFrame: Int = 0
	@MainActor @Published var totalFrames: Int = 0
	@MainActor @Published var errorMessage: String?
	@MainActor @Published var processedVideoURL: URL?
	@MainActor @Published var statsData: Data?
	@MainActor @Published var isCameraRunning: Bool = false
	
	// MARK: - Private Properties (accessed from various threads, handle with care)
	var movieManager: MovieFeedManager?
	var cameraManager: CameraFeedManager?
	var feedAlgorithmProcessor: FeedAlgorithmProcessor?
	var frameCountPerAlgorithmCall: Int64 = 1
	private var feedProcessor: ((URL, URL, @escaping (_ currentFrame: Int, _ totalFrames: Int) -> Void) async throws -> Void)?
	
	// Video writing properties
	private var originalPixelBuffers: [CVPixelBuffer] = []
	private let videoWritingQueue = DispatchQueue(label: "org.thinkscan.videowriting", qos: .utility)
	private var movieWriter: MovieWriter?
	private var cancelRequested: Bool = false
	
	init() {
		self.feedAlgorithmProcessor = FeedAlgorithmProcessor()
		self.movieManager = MovieFeedManager()
		self.cameraManager = CameraFeedManager()
	}
	
	func didReceiveOriginalMovieBuffer(_ originalPixelBuffer: CVPixelBuffer?) {
		// Store the original pixel buffer for video writing in background
		guard let originalPixelBuffer = originalPixelBuffer else { return }
		
		// Add to buffer queue for background video writing
		videoWritingQueue.async { [weak self] in
			guard let self = self else { return }
			self.originalPixelBuffers.append(originalPixelBuffer)
		}
	}
	
	// MARK: - User-Facing Methods (Main Actor)
	
	@MainActor
	func selectVideo() {
		let panel = NSOpenPanel()
		panel.allowsMultipleSelection = false
		panel.canChooseDirectories = false
		panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
		panel.message = "Select a video file to process"
		
		panel.begin { [weak self] response in
			guard let self = self else { return }
			if response == .OK, let url = panel.url {
				self.selectedVideoURL = url
				self.inputSource = .video
				self.startProcessing()
			}
		}
	}
	
	@MainActor
	func startCamera() {
	    cancelRequested = false
		feedAlgorithmProcessor?.trackedItems.resetAll()

	    // Ensure a camera manager exists
	    if cameraManager == nil {
	        cameraManager = CameraFeedManager()
	    }

	    self.inputSource = .camera
	    processingState = .processing
	    progress = 0.0
	    currentFrame = 0
	    totalFrames = 0
	    errorMessage = nil

	    cameraManager?.delegate = self
	    cameraManager?.startCamera()

	    // Clear any previous video buffers
	    videoWritingQueue.async { [weak self] in
	        self?.originalPixelBuffers.removeAll()
	    }
	}
	
	@MainActor
	func stopCamera() {
		guard let cameraManager = cameraManager else { return }
		cameraManager.stopCamera()
	}
	
	@MainActor
	func startProcessing() {
	    guard let videoURL = selectedVideoURL else { return }

	    cancelRequested = false
		feedAlgorithmProcessor?.trackedItems.resetAll()

	    processingState = .processing
	    progress = 0.0
	    currentFrame = 0
	    errorMessage = nil

	    // Ensure a movie manager exists
	    if movieManager == nil {
	        movieManager = MovieFeedManager()
	    }

	    // Set delegate and load video - getNextFrame() will be called from didFinishLoadingMovie()
	    movieManager?.delegate = self
	    movieManager?.loadVideoWith(videoUrl: videoURL)

	    // Clear any previous video buffers
	    videoWritingQueue.async { [weak self] in
	        self?.originalPixelBuffers.removeAll()
	    }
	}
	
	@MainActor
	func finish(_ finished: ProcessingState) {
		self.processingState = finished
		// Keep feedAlgorithmProcessor alive so we can export stats after completion
		// Only clean up the movie manager
		self.movieManager = nil
	}
	
	// TODO: Replace this with your actual video processing logic
	private func simulateVideoProcessing() async {
		for frame in 1...totalFrames {
			try? await Task.sleep(for: .milliseconds(10)) // Simulate frame processing
			await MainActor.run {
				self.currentFrame = frame
				self.progress = Double(frame) / Double(self.totalFrames)
			}
		}
		
		// Simulate processed video and stats
		processedVideoURL = selectedVideoURL // Replace with actual processed video URL
		
		// Create sample stats data
		let stats = """
				Video Processing Stats
				----------------------
				Original Video: \(selectedVideoURL?.lastPathComponent ?? "Unknown")
				Total Frames: \(totalFrames)
				Processing Date: \(Date().formatted())
				"""
		statsData = stats.data(using: .utf8)
	}
	
	@MainActor
	func saveProcessedVideo() {
		cancelRequested = false
		
		guard let feedAlgorithmProcessor = feedAlgorithmProcessor else {
			self.errorMessage = "No video data available to save"
			return
		}
		
		let savePanel = NSSavePanel()
		savePanel.allowedContentTypes = [.movie, .mpeg4Movie]
		savePanel.nameFieldStringValue = "processed_" + (selectedVideoURL?.deletingPathExtension().lastPathComponent ?? "video") + ".mp4"
		savePanel.message = "Save processed video with annotations"
		
		savePanel.begin { [weak self] response in
			guard let self = self else { return }
			
			if response == .OK, let destinationURL = savePanel.url {
				// Update state to show we're saving
				Task { @MainActor in
					self.processingState = .savingVideo
					self.errorMessage = nil
				}
				
				// Process video on background queue
				self.videoWritingQueue.async {
					// Get frame results from tracked items
					let frameResults = feedAlgorithmProcessor.trackedItems.getFrameResults()
					
					guard !frameResults.isEmpty else {
						DispatchQueue.main.async {
							self.errorMessage = "No frame data available for annotation"
							self.processingState = .completed
						}
						return
					}
					
					// Thread-safe copy of pixel buffers
					let pixelBuffers = self.originalPixelBuffers
					
					guard let firstBuffer = pixelBuffers.first else {
						DispatchQueue.main.async {
							self.errorMessage = "No pixel buffers available"
							self.processingState = .completed
						}
						return
					}
					
					let width = CVPixelBufferGetWidth(firstBuffer)
					let height = CVPixelBufferGetHeight(firstBuffer)
					let frameSize = CGSize(width: width, height: height)
					
					// Write to a temporary directory we fully control
					let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
					let writer = MovieWriter(
						withSaveDirectory: tempDir,
						sourceBufferSize: frameSize,
						andIdentifier: UUID().uuidString
					)
					writer.annotatedVideoShouldDisplayBoundingBoxes = true
					writer.isAnnotatedVideo = true
					writer.videoFilePathShouldIncludeDate = false
					
					// Start video writing
					writer.startNewVideoWith(andDate: Date())
					
					// Write frames with annotations
					let bufferCount = min(pixelBuffers.count, frameResults.count)
					
					print("Writing \(bufferCount) frames to annotated video (temp)...")
					
					for i in 0..<bufferCount {
						if self.cancelRequested { break }
						let buffer = pixelBuffers[i]
						let frameResult = frameResults[i]
						
						// Add frame with annotations
						writer.addFrameToCurrentVideoWith(buffer: buffer, andDrawDataFrom: frameResult)
						
						// Log progress periodically
						if i % 30 == 0 || i == bufferCount - 1 {
							print("Written frame \(i + 1)/\(bufferCount)")
						}
					}
					
					// Mark video as complete and wait for it to finish writing
					writer.markCurrentVideoAsDoneAndSave { [weak self] in
						guard let self = self else { return }
						
						// Now that writing is complete, move/replace into the exact user-chosen URL
						guard let tempURL = writer.videoFileUrl else {
							DispatchQueue.main.async {
								self.errorMessage = "Video writer failed to generate output file"
								self.processingState = .completed
							}
							return
						}

						if self.cancelRequested {
							// Remove temporary file if it exists and reset UI state
							try? FileManager.default.removeItem(at: tempURL)
							self.feedAlgorithmProcessor?.trackedItems.clearFrameResults()
							DispatchQueue.main.async {
								self.processingState = .idle
								self.errorMessage = nil
							}
							return
						}
						
						// Optionally access security-scoped URL
						let needsAccess = destinationURL.startAccessingSecurityScopedResource()
						defer { if needsAccess { destinationURL.stopAccessingSecurityScopedResource() } }
						
						do {
							// Ensure destination directory exists
							try FileManager.default.createDirectory(
								at: destinationURL.deletingLastPathComponent(),
								withIntermediateDirectories: true
							)
							
							// If a file already exists at the destination, replace it atomically; otherwise move
							if FileManager.default.fileExists(atPath: destinationURL.path) {
								_ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL)
							} else {
								try FileManager.default.moveItem(at: tempURL, to: destinationURL)
							}
							
							DispatchQueue.main.async {
								self.processedVideoURL = destinationURL
								self.errorMessage = nil
								self.processingState = .completed
								self.feedAlgorithmProcessor?.trackedItems.clearFrameResults()
								print("Annotated video saved successfully to: \(destinationURL.path)")
							}
						} catch {
							DispatchQueue.main.async {
								self.errorMessage = "Failed to save video: \(error.localizedDescription)"
								self.processingState = .completed
							}
						}
					}
				}
			}
		}
	}
	
	
	@MainActor
	func saveStats() {
		guard let feedAlgorithmProcessor = feedAlgorithmProcessor else {
			self.errorMessage = "No processing data available"
			return
		}
		
		let savePanel = NSSavePanel()
		savePanel.allowedContentTypes = [.commaSeparatedText, .plainText]
		savePanel.nameFieldStringValue = (selectedVideoURL?.deletingPathExtension().lastPathComponent ?? "video") + "_stats.csv"
		savePanel.message = "Save processing statistics"
		
		savePanel.begin { [weak self] response in
			guard let self = self else { return }
			
			if response == .OK, let destinationURL = savePanel.url {
				// Perform the calculation and file writing on a background queue
				DispatchQueue.global(qos: .userInitiated).async {
					// Calculate final movement and confidence (synchronous to ensure completion)
					feedAlgorithmProcessor.trackedItems.calculateMovementAndConfidenceSync()
					
					// Generate CSV data from trackedItems (this is thread-safe)
					let csvString = feedAlgorithmProcessor.trackedItems.csvString(includeHeader: true, delimiter: ",")
					let itemCount = feedAlgorithmProcessor.trackedItems.count
					
					do {
						// Write to file
						try csvString.write(to: destinationURL, atomically: true, encoding: .utf8)
						
						// Update UI on main thread
						DispatchQueue.main.async {
							print("Stats saved successfully to: \(destinationURL.path)")
							print("Exported \(itemCount) tracked items")
						}
					} catch {
						DispatchQueue.main.async {
							self.errorMessage = "Failed to save stats: \(error.localizedDescription)"
						}
					}
				}
			}
		}
	}
	
	@MainActor
	func reset() {
		// Stop camera if running
		if isCameraRunning {
			stopCamera()
		}
		
		// Clear delegates and cancel ongoing work
		movieManager?.delegate = nil
		cameraManager?.delegate = nil
		movieWriter = nil
		
		selectedVideoURL = nil
		processingState = .idle
		progress = 0.0
		currentFrame = 0
		totalFrames = 0
		errorMessage = nil
		processedVideoURL = nil
		statsData = nil
		isCameraRunning = false
		
		// Clear video writing data on background queue
		videoWritingQueue.async { [weak self] in
			self?.originalPixelBuffers.removeAll()
		}
		
		// Reinitialize the feed algorithm processor to clear old data
		feedAlgorithmProcessor = FeedAlgorithmProcessor()
	}
	
	@MainActor
	func cancelAndReset() {
		// Signal cancellation and perform a full reset
		cancelRequested = true
		reset()
	}
	
	// MARK: - Injection
	func setVideoProcessor(_ processor: @escaping (URL, URL, @escaping (_ currentFrame: Int, _ totalFrames: Int) -> Void) async throws -> Void) {
		self.feedProcessor = processor
	}
}

// MARK: - ContentView
struct ContentView: View {
	@StateObject private var viewModel = FeedProcessingViewModel()
	
	var body: some View {
		GeometryReader { geo in
			ZStack(alignment: .topTrailing) {
				if viewModel.processingState == .processing || viewModel.processingState == .savingVideo {
					Button(action: {
						viewModel.cancelAndReset()
					}) {
						Label("Cancel", systemImage: "xmark.circle.fill")
					}
					.buttonStyle(.borderedProminent)
					.tint(.red)
					.padding()
				}
				
				ScrollView {
					VStack(spacing: 24) {
						// Logo that scales with available width while preserving aspect ratio
						Image("transparent")
							.resizable()
							.scaledToFit()
							.frame(maxWidth: 250)
							.accessibilityLabel("App logo")
							.padding(.top, 32)
						
						Spacer()
						
						// Main content area
						VStack(spacing: 20) {
							// Video selection and camera buttons (shown when no processing or processing is complete)
							if viewModel.processingState == .idle || viewModel.processingState == .completed {
								HStack(spacing: 16) {
									// Video Selection Button
									Button(action: {
										viewModel.selectVideo()
									}) {
										VStack(spacing: 12) {
											Image(systemName: "video.badge.plus")
												.font(.system(size: 48))
												.foregroundColor(.white)
											Text("Select Video")
												.font(.headline)
												.foregroundColor(.white)
										}
										.frame(maxWidth: .infinity)
										.frame(height: 150)
										.background(
											LinearGradient(
												colors: [
													Color(red: 18.0/255.0, green: 48.0/255.0, blue: 188.0/255.0).opacity(0.6),
													Color(red: 18.0/255.0, green: 48.0/255.0, blue: 188.0/255.0).opacity(0.6)
												],
												startPoint: .topLeading,
												endPoint: .bottomTrailing
											)
										)
										.cornerRadius(16)
									}
									.buttonStyle(.plain)
									
									// Camera Button
									Button(action: {
										if viewModel.isCameraRunning {
											viewModel.stopCamera()
										} else {
											viewModel.startCamera()
										}
									}) {
										VStack(spacing: 12) {
											Image(systemName: viewModel.isCameraRunning ? "camera.fill" : "camera")
												.font(.system(size: 48))
												.foregroundColor(.white)
											Text(viewModel.isCameraRunning ? "Stop Camera" : "Start Camera")
												.font(.headline)
												.foregroundColor(.white)
										}
										.frame(maxWidth: .infinity)
										.frame(height: 150)
										.background(
											LinearGradient(
												colors: [
													Color(red: 18.0/255.0, green: 48.0/255.0, blue: 188.0/255.0).opacity(viewModel.isCameraRunning ? 0.8 : 0.6),
													Color(red: 18.0/255.0, green: 48.0/255.0, blue: 188.0/255.0).opacity(viewModel.isCameraRunning ? 0.8 : 0.6)
												],
												startPoint: .topLeading,
												endPoint: .bottomTrailing
											)
										)
										.cornerRadius(16)
									}
									.buttonStyle(.plain)
								}
							}
							
							// Selected video info
							if let videoURL = viewModel.selectedVideoURL {
								HStack {
									Image(systemName: "film")
										.foregroundColor(.blue)
									Text(videoURL.lastPathComponent)
										.font(.subheadline)
										.foregroundColor(.white)
										.lineLimit(1)
										.truncationMode(.middle)
								}
								.padding()
								.frame(maxWidth: .infinity)
								.background(Color.white.opacity(0.1))
								.cornerRadius(12)
								.overlay(
									RoundedRectangle(cornerRadius: 12)
										.stroke(Color.white.opacity(0.2), lineWidth: 1)
								)
							}
							
							// Processing status and progress
							if viewModel.processingState == .processing {
								VStack(spacing: 16) {
									if viewModel.inputSource == .video {
										ProgressView(value: viewModel.progress, total: 1.0) {
											Text("Processing Video...")
												.font(.headline)
												.foregroundColor(.white)
										} currentValueLabel: {
											HStack {
												Text("\(viewModel.currentFrame) / \(viewModel.totalFrames) frames")
													.font(.caption)
													.foregroundColor(.white.opacity(0.7))
												Spacer()
												Text("\(Int(viewModel.progress * 100))%")
													.font(.caption)
													.foregroundColor(.white.opacity(0.7))
											}
										}
										.progressViewStyle(.linear)
										.tint(.blue)
										.frame(maxWidth: 400)
									} else {
										// Camera mode - show frame count and stop button
										VStack(spacing: 12) {
											HStack {
												Image(systemName: "camera.fill")
													.foregroundColor(.green)
													.font(.title)
												Text("Camera Active")
													.font(.headline)
													.foregroundColor(.white)
											}
											
											Text("Frames processed: \(viewModel.currentFrame)")
												.font(.caption)
												.foregroundColor(.white.opacity(0.7))
											
											Button(action: {
												viewModel.stopCamera()
											}) {
												Label("Stop Camera", systemImage: "stop.circle.fill")
													.frame(maxWidth: .infinity)
											}
											.buttonStyle(.borderedProminent)
											.controlSize(.large)
											.tint(.red)
										}
									}
								}
								.padding()
								.frame(maxWidth: .infinity)
								.background(Color.white.opacity(0.1))
								.cornerRadius(16)
								.overlay(
									RoundedRectangle(cornerRadius: 16)
										.stroke(viewModel.inputSource == .camera ? Color.green.opacity(0.3) : Color.blue.opacity(0.3), lineWidth: 1)
								)
							}
							
							// Completion message and save buttons
							if viewModel.processingState == .completed {
								VStack(spacing: 16) {
									HStack {
										Image(systemName: "checkmark.circle.fill")
											.foregroundColor(.green)
											.font(.title)
										Text("Processing Complete!")
											.font(.headline)
											.foregroundColor(.white)
									}
									
									HStack(spacing: 16) {
										Button(action: {
											viewModel.saveProcessedVideo()
										}) {
											Label("Save Video", systemImage: "square.and.arrow.down")
												.frame(maxWidth: .infinity)
										}
										.buttonStyle(.borderedProminent)
										.controlSize(.large)
										.tint(.blue)
										
										Button(action: {
											viewModel.saveStats()
										}) {
											Label("Save Stats", systemImage: "chart.bar.doc.horizontal")
												.frame(maxWidth: .infinity)
										}
										.buttonStyle(.bordered)
										.controlSize(.large)
										.tint(.white)
									}
								}
								.padding()
								.frame(maxWidth: .infinity)
								.background(Color.green.opacity(0.2))
								.cornerRadius(16)
								.overlay(
									RoundedRectangle(cornerRadius: 16)
										.stroke(Color.green.opacity(0.3), lineWidth: 1)
								)
							}
							
							// Saving video state
							if viewModel.processingState == .savingVideo {
								VStack(spacing: 16) {
									HStack {
										ProgressView()
											.scaleEffect(1.2)
											.tint(.blue)
										Text("Generating annotated video...")
											.font(.headline)
											.foregroundColor(.white)
									}
									
									Text("Please wait while the video is being written to disk.")
										.font(.caption)
										.foregroundColor(.white.opacity(0.7))
										.multilineTextAlignment(.center)
								}
								.padding()
								.frame(maxWidth: .infinity)
								.background(Color.blue.opacity(0.2))
								.cornerRadius(16)
								.overlay(
									RoundedRectangle(cornerRadius: 16)
										.stroke(Color.blue.opacity(0.3), lineWidth: 1)
								)
							}
							
							// Error message
							if let errorMessage = viewModel.errorMessage {
								HStack {
									Image(systemName: "exclamationmark.triangle.fill")
										.foregroundColor(.red)
									Text(errorMessage)
										.font(.subheadline)
										.foregroundColor(.white)
								}
								.padding()
								.frame(maxWidth: .infinity)
								.background(Color.red.opacity(0.2))
								.cornerRadius(12)
								.overlay(
									RoundedRectangle(cornerRadius: 12)
										.stroke(Color.red.opacity(0.3), lineWidth: 1)
								)
							}
						}
						.frame(maxWidth: 600)
						
						Spacer()
					}
					.padding(.horizontal, 24)
					.padding(.bottom, 32)
					.frame(minHeight: geo.size.height, alignment: .top)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
		}
		.frame(minWidth: 600, minHeight: 600)
		.background(
			LinearGradient(
				colors: [
					Color(red: 18.0/255.0, green: 48.0/255.0, blue: 188.0/255.0),
					Color(red: 18.0/255.0, green: 48.0/255.0, blue: 188.0/255.0),
				],
				startPoint: .leading,
				endPoint: .trailing
			).ignoresSafeArea()
		)
		.background(WindowAccessor { window in
			window?.minSize = NSSize(width: 600, height: 400)
			window?.title = "ThinkScan Video Processor"
		})
	}
}

// MARK: - WindowAccessor
struct WindowAccessor: NSViewRepresentable {
	let callback: (NSWindow?) -> Void
	func makeNSView(context: Context) -> NSView {
		let view = NSView()
		DispatchQueue.main.async {
			self.callback(view.window)
		}
		return view
	}
	func updateNSView(_ nsView: NSView, context: Context) { }
}

#Preview {
	ContentView()
}

