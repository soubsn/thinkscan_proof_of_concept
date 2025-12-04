//
//  FrameResult.swift
//  AlgoTester
//
//  Created by Drew Hosford on 1/19/23.
//  Copyright © 2023 Y Media Labs. All rights reserved.
//

import Foundation
import Vision
import CoreGraphics
import Dispatch
import CoreMotion
import Accelerate
import QuartzCore

@_transparent @discardableResult public func measure(label: String? = nil, tests: Int = 1, printResults output: Bool = true, setup: @escaping () -> Void = { return }, _ block: @escaping () -> Void) -> Double {
    
    guard tests > 0 else { fatalError("Number of tests must be greater than 0") }
    
    var avgExecutionTime : CFAbsoluteTime = 0
    for _ in 1...tests {
        setup()
        let start = CFAbsoluteTimeGetCurrent()
        block()
        let end = CFAbsoluteTimeGetCurrent()
        avgExecutionTime += end - start
    }
    
    avgExecutionTime /= CFAbsoluteTime(tests)
    
    if output {
        let avgTimeStr = "\(avgExecutionTime)".replacingOccurrences(of: "e|E", with: " × 10^", options: .regularExpression, range: nil)
        
        if let label = label {
            print(label, "▿")
            print("\tExecution time: \(avgTimeStr)s")
            print("\tNumber of tests: \(tests)\n")
        } else {
            print("Execution time: \(avgTimeStr)s")
            print("Number of tests: \(tests)\n")
        }
    }
    
    return avgExecutionTime
}

struct Detection {
  var box: CGRect
  var originalBox: CGRect
  var score: Float
  var classId: Int
}




class FrameResult {
  // Stored properties representing the image geometry for this frame
  var frameIndex: Int = 0
  var frameAnalysisTime : TimeInterval = 0
  var startTime: TimeInterval = 0
  // Padding metadata (when input frames are padded to square)
  var padLeft: Int = 0
  var padRight: Int = 0
  var padTop: Int = 0
  var padBottom: Int = 0
  var srcWidth: Int = 0
  var srcHeight: Int = 0
  var squareSide: Int = 0

  // Detected objects for this frame
  var detectedObjects: [DetectedObject] = []
  
  init() {
		self.startTime = CACurrentMediaTime()
  }
  
  func distanceBetweenPoints(_ p1:CGPoint, _ p2:CGPoint) -> Double {
    let xDist = p2.x - p1.x
    let yDist = p2.y - p1.y
    return sqrt(xDist * xDist + yDist * yDist)
  }

  func getDetectedObjectFrom(_ result:VNRecognizedObjectObservation) -> DetectedObject {
    var detectedObj = DetectedObject()
    if result.labels[0].confidence < Config.Vision.detectionConfidenceThreshold {
      return detectedObj
    }
    var bboxOriginal = result.boundingBox
    detectedObj.normalizedBbox = bboxOriginal
    ///|result.boundingBox| gives coordinates with the origin in the lower left corner. Since OpenCV, UIView, and CVPixelBuffer all have the origin in the upper left corner, we reflect the bounding box across the middle of the image
    bboxOriginal.origin.y = 1 - (bboxOriginal.origin.y + bboxOriginal.height)
    detectedObj.boundingBoxSquare = VNImageRectForNormalizedRect(bboxOriginal, squareSide, squareSide)
    // Translate from padded square coordinates back to original image space (no width/height shrink)
    let translatedRect = CGRect(
      x: detectedObj.boundingBoxSquare.minX - CGFloat(padLeft),
      y: detectedObj.boundingBoxSquare.minY - CGFloat(padTop),
      width: detectedObj.boundingBoxSquare.width,
      height: detectedObj.boundingBoxSquare.height
    )
    
    // Clamp to original image bounds
    let maxX = CGFloat(srcWidth)
    let maxY = CGFloat(srcHeight)
    let clampedX = max(0, min(translatedRect.minX, maxX))
    let clampedY = max(0, min(translatedRect.minY, maxY))
    let clampedWidth = max(0, min(translatedRect.width, maxX - clampedX))
    let clampedHeight = max(0, min(translatedRect.height, maxY - clampedY))
    
    detectedObj.boundingBoxOnOriginal = CGRect(x: clampedX, y: clampedY, width: clampedWidth, height: clampedHeight)
    detectedObj.location = detectedObj.boundingBoxSquare.center()
    detectedObj.confidence = result.labels[0].confidence
    detectedObj.wasFound = true
    detectedObj.label = result.labels[0].identifier
    return detectedObj
  }

  /// Update the detectedObjects array from Vision results for this frame
  func updateDetections(from results: [VNRecognizedObjectObservation]) {
    detectedObjects = results.map { getDetectedObjectFrom($0) }
  }
}

