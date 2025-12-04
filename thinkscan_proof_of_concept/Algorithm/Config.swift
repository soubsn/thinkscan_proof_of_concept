// Config.swift
// Centralized configuration for the project
// Create typed namespaces for different areas: app, vision, processing, logging, storage.

import Foundation
import CoreGraphics
import UniformTypeIdentifiers

public enum Config {
    // App-wide flags and metadata
    public enum App {
        public static let isDebugLoggingEnabled: Bool = true
        public static let defaultTimeout: TimeInterval = 10
        public static let maxConcurrentOperations: Int = 2
    }

    // Vision / ML related configuration
    public enum Vision {
        // Default image size used when none is provided
        public static let defaultImageSize: CGSize = CGSize(width: 1080, height: 1920)

        // Model names / identifiers
        public static let defaultObjectDetectionModelName: String = "yolo11l"

        // Confidence thresholds
        public static let detectionConfidenceThreshold: Float = 0.6
        public static let iouThreshold: Float = 0.5

        // Maximum number of detections to keep (0 = unlimited)
        public static let maxDetections: Int = 0
    }

    // Processing queues and performance tuning
    public enum Processing {
        public static let inferenceQueueLabel: String = "com.example.app.inference"
        public static let captureQueueLabel: String = "com.example.app.capture"

        // QoS / concurrency hints
        public static let inferenceQueueQoS: DispatchQoS = .userInitiated
        public static let captureQueueQoS: DispatchQoS = .userInitiated
      
      // Number of frames before ensemble decision
        public static let ensembleThresholdTime: Double = 1000000
    }

    // Logging configuration
    public enum Logging {
        public static let perFrameLogID: String = "_perFrame"
        public static let performanceLogID: String = "_performance"
    }

    // File system / storage configuration
    public enum Storage {
        // Subdirectory names inside the app's documents directory
        public static let detectionsFolderName: String = "Detections"
        public static let framesFolderName: String = "Frames"

        // Whether to create directories on first use
        public static let autoCreateDirectories: Bool = true

        // Helper to resolve Documents directory URL
        public static var documentsDirectory: URL {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }

        // Convenience resolved URLs
        public static var detectionsDirectory: URL {
            documentsDirectory.appendingPathComponent(detectionsFolderName, conformingTo: .directory)
        }

        public static var framesDirectory: URL {
            documentsDirectory.appendingPathComponent(framesFolderName, conformingTo: .directory)
        }
    }
}

// MARK: - Optional helpers

public enum ConfigHelpers {
    // Ensure storage directories exist when needed
    @discardableResult
    public static func ensureStorageDirectoriesExist() throws -> Bool {
        guard Config.Storage.autoCreateDirectories else { return false }
        let fm = FileManager.default
        var createdAny = false
        for url in [Config.Storage.detectionsDirectory, Config.Storage.framesDirectory] {
            if !fm.fileExists(atPath: url.path) {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                createdAny = true
            }
        }
        return createdAny
    }
}

