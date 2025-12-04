//
//  TrackedItemsResult.swift
//  thinkscan_proof_of_concept
//
//  Created by Nicolas Soubry on 2025-12-03.
//

import CoreVideo
import Foundation

struct TrackedItemsSingle {
	var label: String
	var key: Int
	var start: Int
	var finish: Int
	var isComplete: Bool = false
	var speed: Double = 0.0
	var direction: String = ""
	var confidenceArray: [Double] = []
	var confidence: Double = 0.0
	var lastLocation: CGRect = .zero
	var movementHistoryX: [Double] = []  // Positive = right, Negative = left
	var movementHistoryY: [Double] = []  // Positive = up, Negative = down
	var totalMovementX: Double = 0.0
	var netMovementX: Double = 0.0
	var totalMovementY: Double = 0.0
	var netMovementY: Double = 0.0
	var distance: Double = 0.0
	var displacement: Double = 0.0
}

class TrackedItemsResult {
	var maxMissedFrames: Int = 0
	
	private var trackedItems: [TrackedItemsSingle] = []
	private let queue = DispatchQueue(label: "org.thinkscan.trackeditems", attributes: .concurrent)
	
	// Store frame results for video writing
	private var frameResultsForVideo: [FrameResult] = []
	private let frameResultsQueue = DispatchQueue(label: "org.thinkscan.frameresults", attributes: .concurrent)
	
	/// Clears all tracked items and frame results immediately (thread-safe).
	/// Call this before starting a new video/camera session to avoid reusing old boxes.
	func resetAll() {
		// Clear main tracked items
		queue.sync(flags: .barrier) {
			trackedItems.removeAll()
		}
		// Clear per-frame results used for video annotation
		frameResultsQueue.sync(flags: .barrier) {
			frameResultsForVideo.removeAll()
		}
	}
	
	/// Returns the number of tracked items (thread-safe)
	var count: Int {
		return queue.sync { trackedItems.count }
	}
	
	/// Thread-safe access to tracked items for reading
	func getTrackedItems() -> [TrackedItemsSingle] {
		return queue.sync { trackedItems }
	}
	
	/// Returns frame results for video annotation (thread-safe)
	func getFrameResults() -> [FrameResult] {
		return frameResultsQueue.sync { frameResultsForVideo }
	}
	
	/// Adds a frame result for video writing (thread-safe)
	func addFrameResultForVideo(_ frameResult: FrameResult) {
		frameResultsQueue.async(flags: .barrier) { [weak self] in
			self?.frameResultsForVideo.append(frameResult)
		}
	}
	
	/// Clears stored frame results (thread-safe) - call after video export completes
	func clearFrameResults() {
		frameResultsQueue.async(flags: .barrier) { [weak self] in
			self?.frameResultsForVideo.removeAll()
		}
	}
	
	func calculateMovementAndConfidence(){
		queue.async(flags: .barrier) { [weak self] in
			guard let self = self else { return }
			for index in self.trackedItems.indices {
				// Net movement: signed sum
				let netX = self.trackedItems[index].movementHistoryX.reduce(0, +)
				let netY = self.trackedItems[index].movementHistoryY.reduce(0, +)
				

				// Total movement: sum of absolute deltas
				let totalX = self.trackedItems[index].movementHistoryX.reduce(0) { $0 + abs($1) }
				let totalY = self.trackedItems[index].movementHistoryY.reduce(0) { $0 + abs($1) }

				self.trackedItems[index].netMovementX = netX
				self.trackedItems[index].netMovementY = netY
				self.trackedItems[index].totalMovementX = totalX
				self.trackedItems[index].totalMovementY = totalY

				// Displacement is the magnitude of net vector
				self.trackedItems[index].displacement = sqrt(pow(netX, 2) + pow(netY, 2))

				// Distance: use total movement (path length)
				self.trackedItems[index].distance = totalX + totalY

				// Speed: guard against divide-by-zero if start == finish
				let frameDelta = max(1, self.trackedItems[index].finish - self.trackedItems[index].start)
				let confidence = self.trackedItems[index].confidenceArray.reduce(0, +) / Double(frameDelta)
				self.trackedItems[index].confidence = confidence
				self.trackedItems[index].speed = self.trackedItems[index].distance / Double(frameDelta)
			}
		}
	}
	
	/// Synchronous version of calculateMovementAndConfidence for when you need to wait for completion
	func calculateMovementAndConfidenceSync(){
		queue.sync(flags: .barrier) {
			for index in self.trackedItems.indices {
				// Net movement: signed sum
				let netX = self.trackedItems[index].movementHistoryX.reduce(0, +)
				let netY = self.trackedItems[index].movementHistoryY.reduce(0, +)
				

				// Total movement: sum of absolute deltas
				let totalX = self.trackedItems[index].movementHistoryX.reduce(0) { $0 + abs($1) }
				let totalY = self.trackedItems[index].movementHistoryY.reduce(0) { $0 + abs($1) }

				self.trackedItems[index].netMovementX = netX
				self.trackedItems[index].netMovementY = netY
				self.trackedItems[index].totalMovementX = totalX
				self.trackedItems[index].totalMovementY = totalY

				// Displacement is the magnitude of net vector
				self.trackedItems[index].displacement = sqrt(pow(netX, 2) + pow(netY, 2))

				// Distance: use total movement (path length)
				self.trackedItems[index].distance = totalX + totalY

				// Speed: guard against divide-by-zero if start == finish
				let frameDelta = max(1, self.trackedItems[index].finish - self.trackedItems[index].start)
				let confidence = self.trackedItems[index].confidenceArray.reduce(0, +) / Double(frameDelta)
				self.trackedItems[index].confidence = confidence
				self.trackedItems[index].speed = self.trackedItems[index].distance / Double(frameDelta)
			}
		}
	}
	
	
	/// Adds a new tracked item to the collection (thread-safe)
	/// - Parameter analysis: The tracked item to add
	func addAnalysis(_ analysis: TrackedItemsSingle) {
		queue.async(flags: .barrier) { [weak self] in
			self?.trackedItems.append(analysis)
		}
	}
	
	/// Returns the next available key for items matching the given label (thread-safe)
	/// - Parameter label: The label to match against tracked items
	/// - Returns: The highest key + 1 if any items match; otherwise 1
	func highestKey(for label: String) -> Int {
		return queue.sync {
			return _highestKeyUnsafe(for: label)
		}
	}
	
	/// Internal version of highestKey that assumes the caller already holds the queue lock
	/// - Parameter label: The label to match against tracked items
	/// - Returns: The highest key + 1 if any items match; otherwise 1
	/// - Warning: This method is NOT thread-safe. Only call from within a queue.sync or queue.async block.
	private func _highestKeyUnsafe(for label: String) -> Int {
		let maxKey = trackedItems
			.filter { $0.label == label }
			.map { $0.key }
			.max()
		return (maxKey ?? 0) + 1
	}
	
	/// Creates a new tracked item from a detected object
	/// - Parameters:
	///   - detectedObject: The detected object to track
	///   - frameIndex: The frame index where the object was detected
	/// - Warning: This method assumes it's called from within a queue barrier context
	private func createTrackedItem(from detectedObject: DetectedObject, frameIndex: Int) {
		let newItem = TrackedItemsSingle(
			label: detectedObject.label,
			key: _highestKeyUnsafe(for: detectedObject.label),
			start: frameIndex,
			finish: frameIndex,
			isComplete: false,
			speed: 0.0,
			direction: "",
			confidence: Double(detectedObject.confidence),
			lastLocation: detectedObject.normalizedBbox,
			movementHistoryX: [],
			movementHistoryY: []
		)
		// Directly append to trackedItems since we're already in a barrier context
		trackedItems.append(newItem)
	}
	
	/// Updates tracked items based on detected objects from a frame result. (thread-safe)
	/// Creates new tracked items for objects that don't match any existing items.
	/// Marks items as complete if they haven't been detected in recent frames.
	/// - Parameter frameResult: The frame result containing detected objects
	func updateFromFrameResult(_ frameResult: FrameResult) {
		queue.async(flags: .barrier) { [weak self] in
			guard let self = self else { return }
			
			// Build a list of all possible matches with their distances
			var matches: [(detectedIndex: Int, trackedIndex: Int, distance: CGFloat)] = []
			
			for (detectedIndex, detectedObject) in frameResult.detectedObjects.enumerated() {
				let detectedCenter = CGPoint(
					x: detectedObject.normalizedBbox.midX,
					y: detectedObject.normalizedBbox.midY
				)
				
				// Find all tracked items with matching labels that are not complete
				let candidateIndices = self.trackedItems.enumerated().compactMap { index, item in
					if item.label == detectedObject.label && !item.isComplete && item.lastLocation != .zero {
						return index
					}
					return nil
				}
				
				// Calculate distances for all candidates
				for trackedIndex in candidateIndices {
					let trackedItem = self.trackedItems[trackedIndex]
					let lastCenter = CGPoint(
						x: trackedItem.lastLocation.midX,
						y: trackedItem.lastLocation.midY
					)
					
					let distance = self.distanceBetween(detectedCenter, lastCenter)
					
					// Check if distance is within acceptable range
					let averageWidth = (detectedObject.normalizedBbox.width + trackedItem.lastLocation.width) / 2.0
					if distance <= averageWidth {
						matches.append((detectedIndex, trackedIndex, distance))
					}
				}
			}
			
			// Sort matches by distance (closest first)
			matches.sort { $0.distance < $1.distance }
			
			// Track which detected objects and tracked items have been matched
			var matchedDetectedIndices = Set<Int>()
			var matchedTrackedIndices = Set<Int>()
			
			// Assign matches greedily (closest pairs first)
			for match in matches {
				// Skip if either object or tracked item is already matched
				if matchedDetectedIndices.contains(match.detectedIndex) ||
						matchedTrackedIndices.contains(match.trackedIndex) {
					continue
				}
				
				// Create the match
				let detectedObject = frameResult.detectedObjects[match.detectedIndex]
				self.updateTrackedItem(at: match.trackedIndex, with: detectedObject, frameIndex: frameResult.frameIndex)
				
				matchedDetectedIndices.insert(match.detectedIndex)
				matchedTrackedIndices.insert(match.trackedIndex)
			}
			
			// Create new tracked items for unmatched detected objects
			for (detectedIndex, detectedObject) in frameResult.detectedObjects.enumerated() {
				if !matchedDetectedIndices.contains(detectedIndex) {
					self.createTrackedItem(from: detectedObject, frameIndex: frameResult.frameIndex)
				}
			}
			
			// Mark items as complete if they haven't been seen recently
			self.markStaleItemsAsComplete(currentFrameIndex: frameResult.frameIndex)
		}
	}
	
	/// Marks tracked items as complete if they haven't been updated recently
	/// - Parameters:
	///   - currentFrameIndex: The current frame index
	private func markStaleItemsAsComplete(currentFrameIndex: Int) {
		for index in trackedItems.indices {
			// Skip already complete items
			guard !trackedItems[index].isComplete else { continue }
			
			let framesSinceLastSeen = currentFrameIndex - trackedItems[index].finish
			
			if framesSinceLastSeen > maxMissedFrames {
				trackedItems[index].isComplete = true
			}
		}
	}
	
	/// Updates a tracked item at the specified index with data from a detected object
	/// - Parameters:
	///   - index: The index of the tracked item to update
	///   - detectedObject: The detected object containing new data
	///   - frameIndex: The current frame index
	private func updateTrackedItem(at index: Int, with detectedObject: DetectedObject, frameIndex: Int) {
		let previousLocation = trackedItems[index].lastLocation
		let newLocation = detectedObject.normalizedBbox
		
		// Calculate movement deltas
		// X: Positive = right, Negative = left
		let deltaX = Double(newLocation.midX - previousLocation.midX)
		
		// Y: Positive = up, Negative = down (inverted because CGRect origin is top-left)
		let deltaY = Double(previousLocation.midY - newLocation.midY)
		
		// Add to movement history
		trackedItems[index].movementHistoryX.append(deltaX)
		trackedItems[index].movementHistoryY.append(deltaY)
		
		//        // Maintain max history length
		//        let maxLength = trackedItems[index].maxHistoryLength
		//        if trackedItems[index].movementHistoryX.count > maxLength {
		//            trackedItems[index].movementHistoryX.removeFirst()
		//        }
		//        if trackedItems[index].movementHistoryY.count > maxLength {
		//            trackedItems[index].movementHistoryY.removeFirst()
		//        }
		
		// Update with new detection data
		trackedItems[index].lastLocation = newLocation
		trackedItems[index].confidenceArray.append(Double(detectedObject.confidence))
		trackedItems[index].finish = frameIndex
	}
	
	/// Calculates the Euclidean distance between two points
	/// - Parameters:
	///   - p1: First point
	///   - p2: Second point
	/// - Returns: The distance between the points
	private func distanceBetween(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
		let dx = p2.x - p1.x
		let dy = p2.y - p1.y
		return sqrt(dx * dx + dy * dy)
	}
	
	/// Calculates the average velocity from movement history
	/// - Parameter item: The tracked item to analyze
	/// - Returns: A tuple containing (velocityX, velocityY, speed, direction) where direction is a string like "up-right"
	func calculateVelocity(for item: TrackedItemsSingle) -> (velocityX: Double, velocityY: Double, speed: Double, direction: String) {
		guard !item.movementHistoryX.isEmpty, !item.movementHistoryY.isEmpty else {
			return (0.0, 0.0, 0.0, "stationary")
		}
		
		// Calculate average velocities
		let avgVelocityX = item.movementHistoryX.reduce(0, +) / Double(item.movementHistoryX.count)
		let avgVelocityY = item.movementHistoryY.reduce(0, +) / Double(item.movementHistoryY.count)
		
		// Calculate overall speed (magnitude)
		let speed = sqrt(avgVelocityX * avgVelocityX + avgVelocityY * avgVelocityY)
		
		// Determine direction string
		let direction = getDirectionString(velocityX: avgVelocityX, velocityY: avgVelocityY, threshold: 0.001)
		
		return (avgVelocityX, avgVelocityY, speed, direction)
	}
	
	/// Converts velocity components to a human-readable direction string
	/// - Parameters:
	///   - velocityX: X component of velocity (positive = right, negative = left)
	///   - velocityY: Y component of velocity (positive = up, negative = down)
	///   - threshold: Minimum velocity to register movement in that direction
	/// - Returns: Direction string like "up", "down-right", "stationary", etc.
	private func getDirectionString(velocityX: Double, velocityY: Double, threshold: Double) -> String {
		let movingHorizontally = abs(velocityX) > threshold
		let movingVertically = abs(velocityY) > threshold
		
		if !movingHorizontally && !movingVertically {
			return "stationary"
		}
		
		var components: [String] = []
		
		if movingVertically {
			components.append(velocityY > 0 ? "up" : "down")
		}
		
		if movingHorizontally {
			components.append(velocityX > 0 ? "right" : "left")
		}
		
		return components.joined(separator: "-")
	}

    /// Builds a CSV string representing all tracked items. (thread-safe)
    /// - Parameters:
    ///   - includeHeader: Whether to include a header row.
    ///   - delimiter: The field delimiter to use. Defaults to comma.
    /// - Returns: A CSV-formatted string of the tracked items.
    func csvString(includeHeader: Bool = true, delimiter: String = ",") -> String {
        return queue.sync {
            var lines: [String] = []

            let headers = [
                "label","key","start","finish","isComplete","speed","direction","confidence",
                "lastX","lastY","lastWidth","lastHeight",
                "totalMovementX","netMovementX","totalMovementY","netMovementY",
                "distance","displacement",
                "movementHistoryX","movementHistoryY","confidenceArray"
            ]

            if includeHeader {
                lines.append(headers.joined(separator: delimiter))
            }

            let numberFormatter = NumberFormatter()
            numberFormatter.locale = Locale(identifier: "en_US_POSIX")
            numberFormatter.minimumFractionDigits = 0
            numberFormatter.maximumFractionDigits = 6
            numberFormatter.minimumIntegerDigits = 1

            func fmt(_ d: Double) -> String {
                numberFormatter.string(from: NSNumber(value: d)) ?? String(d)
            }

            for item in trackedItems {
                let lastX = Double(item.lastLocation.origin.x)
                let lastY = Double(item.lastLocation.origin.y)
                let lastW = Double(item.lastLocation.size.width)
                let lastH = Double(item.lastLocation.size.height)

                // Use a pipe to separate list values to avoid clashing with the CSV delimiter
                let historyX = item.movementHistoryX.map(fmt).joined(separator: "|")
                let historyY = item.movementHistoryY.map(fmt).joined(separator: "|")
                let confidences = item.confidenceArray.map(fmt).joined(separator: "|")

                let fields: [String] = [
                    csvEscape(item.label, delimiter: delimiter),
                    String(item.key),
                    String(item.start),
                    String(item.finish),
                    String(item.isComplete),
                    fmt(item.speed),
                    csvEscape(item.direction, delimiter: delimiter),
                    fmt(item.confidence),
                    fmt(lastX),
                    fmt(lastY),
                    fmt(lastW),
                    fmt(lastH),
                    fmt(item.totalMovementX),
                    fmt(item.netMovementX),
                    fmt(item.totalMovementY),
                    fmt(item.netMovementY),
                    fmt(item.distance),
                    fmt(item.displacement),
                    csvEscape(historyX, delimiter: delimiter),
                    csvEscape(historyY, delimiter: delimiter),
                    csvEscape(confidences, delimiter: delimiter)
                ]

                lines.append(fields.joined(separator: delimiter))
            }

            return lines.joined(separator: "\n")
        }
    }

    /// Writes the CSV for all tracked items to the given URL using UTF-8 encoding.
    /// - Parameters:
    ///   - url: Destination file URL.
    ///   - includeHeader: Whether to include a header row.
    ///   - delimiter: Field delimiter to use. Defaults to comma.
    /// - Returns: The URL that was written to.
    @discardableResult
    func writeCSV(to url: URL, includeHeader: Bool = true, delimiter: String = ",") throws -> URL {
        let csv = csvString(includeHeader: includeHeader, delimiter: delimiter)
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Escapes a value for safe inclusion in a CSV field.
    /// - Parameters:
    ///   - value: The raw field value.
    ///   - delimiter: The delimiter used in the CSV.
    /// - Returns: An escaped field value, quoted if necessary.
    private func csvEscape(_ value: String, delimiter: String) -> String {
        let needsQuotes = value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r")
        if needsQuotes {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        } else {
            return value
        }
    }
}

