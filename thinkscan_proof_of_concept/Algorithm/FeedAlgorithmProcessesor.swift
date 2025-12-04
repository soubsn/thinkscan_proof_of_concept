//
//  videoAlgorithmProcessesor.swift
//  thinkscan_proof_of_concept
//
//  Created by Nicolas Soubry on 2025-11-27.
//

import CoreVideo
import Foundation

protocol NavigatorAlgorithmDelegate : AnyObject {
	func didAnalyzeFrameWith(_ frameResult:FrameResult)
}

class FeedAlgorithmProcessor: NSObject {
	weak var delegate : NavigatorAlgorithmDelegate?
	var objectDetectionOD: CoreMLObjectDetection?
	var localSaveDirectory : URL?
	var timeInternal1: Double = CFAbsoluteTimeGetCurrent()
	var timerInterval: Double = 0
	var frameCount: Int = 0
	var _imageSize: CGSize = CGSize(width: 1080, height: 1920)
	var frameResults: [FrameResult] = []
	public var trackedItems: TrackedItemsResult = TrackedItemsResult()
	private var inferenceQueue : DispatchQueueTestable = DispatchQueue(label: "org.thinkscan.thinkscan_proof_of_concept.inferencequeue", attributes: .concurrent)
	private var isInferenceQueueBusy = AtomicVariable<Bool>(initialValue: false)
	private var detectorPool: [CoreMLObjectDetection] = []
	private let detectorIndexQueue = DispatchQueue(label: "org.thinkscan.thinkscan_proof_of_concept.detectorindexqueue")
	private var nextDetectorIndex: Int = 0
	private let resultsQueue = DispatchQueue(label: "org.thinkscan.thinkscan_proof_of_concept.resultsqueue", attributes: .concurrent)
	private let indexQueue = DispatchQueue(label: "org.thinkscan.thinkscan_proof_of_concept.indexqueue")
	var maxConcurrentDetections: Int = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
	private var currentODModelName: String = Config.Vision.defaultObjectDetectionModelName
	
	static let shared = FeedAlgorithmProcessor()
	
	override init() {
		self.localSaveDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
		super.init()
		// Eager, non-blocking setup on the inference queue; guarded to set only once
		setODModel(with: Config.Vision.defaultObjectDetectionModelName)
	}
	
	deinit{}
	
	convenience init(inferenceQueue:DispatchQueueTestable) {
		self.init()
		self.inferenceQueue = inferenceQueue
		self.frameCount = 0
	}
	
	func setODModel(with name: String) {
		executeOnInferenceQueue { processor in
			// If already initialized, do nothing to avoid multiple instances
			guard processor.objectDetectionOD == nil else { return }
			let modelName = name.isEmpty ? Config.Vision.defaultObjectDetectionModelName : name
			let newDetector = CoreMLObjectDetection(with: modelName)
			processor.objectDetectionOD = newDetector
			processor.currentODModelName = modelName
			// Build a detector pool sized for expected concurrency
			processor.detectorPool = (0..<processor.maxConcurrentDetections).map { _ in
				CoreMLObjectDetection(with: modelName)
			}
		}
	}
	
	func executeOnMainThread(blockToExecute: @escaping (FeedAlgorithmProcessor) -> Void) {
		DispatchQueue.main.async { [weak self] in
			guard let self = self else {
				return
			}
			blockToExecute(self)
		}
	}
	
	func executeOnInferenceQueue(blockToExecute: @escaping (FeedAlgorithmProcessor) -> Void) {
		inferenceQueue.async { [weak self] in
			guard let self = self else {
				return
			}
			blockToExecute(self)
		}
	}
	
	private func nextFrameIndex() -> Int {
		return indexQueue.sync {
			frameCount += 1
			return frameCount
		}
	}
	
	private func acquireDetector() -> CoreMLObjectDetection? {
		if detectorPool.isEmpty { return objectDetectionOD }
		return detectorIndexQueue.sync {
			let detector = detectorPool[nextDetectorIndex % detectorPool.count]
			nextDetectorIndex += 1
			return detector
		}
	}
	
	private func ensureDetectorPoolSize(_ size: Int) {
		guard size > 0 else { return }
		if detectorPool.count < size {
			let needed = size - detectorPool.count
			for _ in 0..<needed {
				detectorPool.append(CoreMLObjectDetection(with: currentODModelName))
			}
		}
	}
	
	func runAlgorithm(pixelBuffer: CVPixelBuffer, isMoviePlaybackBuffer: Bool) {
		let timeInternal2 = CFAbsoluteTimeGetCurrent()
		timerInterval = timeInternal2 - timeInternal1
		timeInternal1 = timeInternal2
		if isMoviePlaybackBuffer {
			executeOnInferenceQueue { (self:FeedAlgorithmProcessor) in
				self.isInferenceQueueBusy.value = true
				let detector = self.acquireDetector()
				let result = self.detect(pixelBuffer: pixelBuffer, using: detector)
				self.resultsQueue.sync(flags: .barrier) {
					self.frameResults.append(result)
				}
				self.isInferenceQueueBusy.value = false
			}
		} else {
			guard !self.isInferenceQueueBusy.value else { return }
			executeOnInferenceQueue { (self:FeedAlgorithmProcessor) in
				self.isInferenceQueueBusy.value = true
				let detector = self.acquireDetector()
				let result = self.detect(pixelBuffer: pixelBuffer, using: detector)
				self.resultsQueue.sync(flags: .barrier) {
					self.frameResults.append(result)
				}
				self.isInferenceQueueBusy.value = false
			}
		}
	}
	
	func runAlgorithms(pixelBuffers: [CVPixelBuffer],
										 isMoviePlaybackBuffer: Bool,
										 maxConcurrent: Int? = nil,
										 completion: (() -> Void)? = nil) {
		let cpu = ProcessInfo.processInfo.activeProcessorCount
		let requested = max(1, maxConcurrent ?? self.maxConcurrentDetections)
		let n = max(1, min(requested, cpu))
		executeOnInferenceQueue { (processor: FeedAlgorithmProcessor) in
			processor.isInferenceQueueBusy.value = true
			processor.ensureDetectorPoolSize(n)
			DispatchQueue.concurrentPerform(iterations: n) { worker in
				let detector: CoreMLObjectDetection? = processor.detectorPool.isEmpty ? processor.objectDetectionOD : processor.detectorPool[worker % processor.detectorPool.count]
				var i = worker
				while i < pixelBuffers.count {
					let result = processor.detect(pixelBuffer: pixelBuffers[i], using: detector)
					processor.resultsQueue.sync(flags: .barrier) {
						processor.frameResults.append(result)
					}
					i += n
				}
			}
			processor.isInferenceQueueBusy.value = false
			if let completion = completion {
				processor.executeOnMainThread { _ in
					completion()
				}
			}
		}
	}
	
	func executeCombinedProcessing() {
		// Early exit if there are no results to process
		let hasResults = resultsQueue.sync { !self.frameResults.isEmpty }
		guard hasResults else { return }
		trackedItems.calculateMovementAndConfidence()
	}
	
	func detect(pixelBuffer: CVPixelBuffer, using detector: CoreMLObjectDetection?) -> FrameResult {
		let frameResult = FrameResult()
		frameResult.frameIndex = nextFrameIndex()
		if let attachment = CVBufferGetAttachment(pixelBuffer, "com.ymedialabs.padding" as CFString, nil)?.takeUnretainedValue() as? NSDictionary {
			frameResult.padLeft = attachment["padLeft"] as? Int ?? 0
			frameResult.padRight = attachment["padRight"] as? Int ?? 0
			frameResult.padTop = attachment["padTop"] as? Int ?? 0
			frameResult.padBottom = attachment["padBottom"] as? Int ?? 0
			frameResult.srcWidth = attachment["srcWidth"] as? Int ?? 0
			frameResult.srcHeight = attachment["srcHeight"] as? Int ?? 0
			frameResult.squareSide = attachment["side"] as? Int ?? 0
		}
		let startTime = CFAbsoluteTimeGetCurrent()
		guard let detectionResult = detector?.analyze(frame: pixelBuffer) else {
			frameResult.detectedObjects = []
			return frameResult
		}
		frameResult.updateDetections(from: detectionResult)
		frameResult.frameAnalysisTime = CFAbsoluteTimeGetCurrent() - startTime
		trackedItems.updateFromFrameResult(frameResult)
		
		// Store frame result for video annotation
		trackedItems.addFrameResultForVideo(frameResult)
		
		return frameResult
	}
}

