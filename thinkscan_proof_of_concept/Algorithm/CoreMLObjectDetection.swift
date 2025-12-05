/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Contains the object recognition view controller for the Breakfast Finder.
*/

import AVFoundation
import Vision
import AppKit

protocol CoreMLObjectDetectionDelegate : AnyObject {
  func didFinishAnalyzingFrame(results : [VNRecognizedObjectObservation])
}

struct DetectedObject {
    var label = ""
    var normalizedBbox = CGRect.zero
    var boundingBoxSquare = CGRect.zero
    var boundingBoxOnOriginal = CGRect.zero
    var confidence = Float()
    var location = CGPoint.zero
    var timeElapsed = Double(0)
    var color = NSColor.red
    var wasFound = false

    // Add a method to create a new instance with updated properties
    func copy(
        label: String? = nil,
        normalizedBbox: CGRect? = nil,
        boundingBox: CGRect? = nil,
        confidence: Float? = nil,
        location: CGPoint? = nil,
        timeElapsed: Double? = nil,
        color: NSColor? = nil,
        wasFound: Bool? = nil,
    ) -> DetectedObject {
        return DetectedObject(
            label: label ?? self.label,
            normalizedBbox: normalizedBbox ?? self.normalizedBbox,
            boundingBoxSquare: boundingBox ?? self.boundingBoxSquare,
            confidence: confidence ?? self.confidence,
            location: location ?? self.location,
            timeElapsed: timeElapsed ?? self.timeElapsed,
            color: color ?? self.color,
            wasFound: wasFound ?? self.wasFound,
        )
    }
}

class CoreMLObjectDetection {
  var model : VNCoreMLModel?
  var request : VNCoreMLRequest?
  var modelNew : VNCoreMLModel?
  var requestNew : VNCoreMLRequest?
  var bufferSize: CGSize = .zero
  var rootLayer: CALayer! = nil
//  let isAnalyzing : AtomicVariable<Bool> = AtomicVariable(initialValue: false)
  var detectionOverlay: CALayer! = nil
  weak var delegate : CoreMLObjectDetectionDelegate?
  var frameCount: Int = 0
  var latestResults : [VNRecognizedObjectObservation]
  
  init(with resource:String) {
    do {
      guard let urlPath = Bundle.main.url(forResource: resource, withExtension: "mlmodelc") else {
        throw NSError(domain: "info", code: -1, userInfo: nil)
      }
      let model = try VNCoreMLModel(for: MLModel(contentsOf: urlPath))
      let request = VNCoreMLRequest(model: model)
      request.imageCropAndScaleOption = .centerCrop
      self.model = model
      self.request = request
    } catch {
        fatalError("Unable to initialize the Object Detection model")
    }
    latestResults = []
  }
  
  ///This bbox is returned with the origin in the upper left of the image (just like how UIView's expect the box to be)
  func bboxFor(object: VNRecognizedObjectObservation, onViewWith size:CGSize) -> CGRect {
    let b = object.boundingBox
    let x = b.origin.x * size.width
    let y = (1.0 - b.origin.y - b.size.height) * size.height
    let w = b.size.width * size.width
    let h = b.size.height * size.height
    return CGRect(x: x, y: y, width: w, height: h)
  }

  /// Converts a normalized Vision rect (origin at bottom-left) to a top-left–origin view rect of the given size.
  /// - Parameters:
  ///   - normalizedRect: A CGRect in normalized coordinates returned by Vision (0..1, origin at bottom-left).
  ///   - viewSize: The destination view size in points/pixels.
  /// - Returns: A CGRect in the view's top-left coordinate space.
  func rectFromNormalizedVision(_ normalizedRect: CGRect, inViewOfSize viewSize: CGSize) -> CGRect {
      let x = normalizedRect.origin.x * viewSize.width
      let y = (1.0 - normalizedRect.origin.y - normalizedRect.size.height) * viewSize.height
      let w = normalizedRect.size.width * viewSize.width
      let h = normalizedRect.size.height * viewSize.height
      return CGRect(x: x, y: y, width: w, height: h)
  }
  
  func bboxForResult(at index:Int, onViewWith size:CGSize) -> CGRect {
    if index >= latestResults.count {
      return CGRectZero
    }
    let object = latestResults[index]
    return bboxFor(object: object, onViewWith: size)
  }
  
  func identifierForResult(at index:Int) -> String {
    if index >= latestResults.count {
      print("error: index invalid. Could not obtain result for index \(index)")
      return ""
    }
    return latestResults[index].labels[0].identifier
  }
  
  func confidenceForResult(at index:Int) -> Float {
    if index >= latestResults.count {
      print("error: index invalid. Could not obtain confidence for index \(index)")
      return 0
    }
    return latestResults[index].labels[0].confidence
  }
  
  func latestDetectedObjects(onViewWith size:CGSize) -> [DetectedObject] {
    var detectedObjects = Array<DetectedObject>()
    for object in latestResults {
      var detected = DetectedObject()
      detected.boundingBoxSquare = bboxFor(object: object, onViewWith: size)
      detected.location = detected.boundingBoxSquare.center()
      detected.confidence = object.labels[0].confidence
      detected.label = object.labels[0].identifier
      detectedObjects.append(detected)
    }
    return detectedObjects
  }
  
  func analyze(frame : CVPixelBuffer) -> [VNRecognizedObjectObservation]{
    guard let request = self.request else {
//      Logger.LOG_ERR("Request is nil")
      return []
    }
    let handler = VNImageRequestHandler(cvPixelBuffer: frame, options: [:])
    do {
      try handler.perform([request])
    } catch {
//      Logger.LOG_ERR("Failed to perform classification.\n\(error.localizedDescription)")
    }
    latestResults = request.results! as! [VNRecognizedObjectObservation]
    return latestResults
  }
  
  func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let xDist = a.x - b.x
    let yDist = a.y - b.y
    return CGFloat(sqrt(xDist * xDist + yDist * yDist))
  }

  func displacementCalculator(x : Array<Double>, y: Array<Double>, number: Double) -> CGPoint {
    let idx = x.indexes(ofItemsEqualTo: number)
    if Float(idx.count)/Float(x.count) > 0.5 {
      return CGPoint(x: number, y: number)
    }
    let xClean = x
      .enumerated()
      .filter { !idx.contains($0.offset) }
      .map { $0.element }
    let yClean = y
      .enumerated()
      .filter { !idx.contains($0.offset) }
      .map { $0.element }
    let xAverage = xClean.fastMean()
    let yAverage = yClean.fastMean()
    return CGPoint(x: xAverage, y: yAverage)
  }
}

