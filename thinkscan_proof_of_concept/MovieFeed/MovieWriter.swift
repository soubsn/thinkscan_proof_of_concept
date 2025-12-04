
///
///  MovieWriter.swift
//

import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics
import AppKit
import CoreText
import UniformTypeIdentifiers

enum MovieWriterStatus {
  case readyToStart
  case readyToReceiveFrames
  case writingToDisc
}

class MovieWriter {
  var videoId : String = "unknown"  //Note: If this value is changed while in .readyToReceiveFrames or .writingToDisc, then the current video will be finished under it's previous name and the next video will contain the new videoId
  var videoSuffix : String = ""
  var shouldSkipVideoWriting : Bool = false
  var annotatedVideoShouldDisplayBoundingBoxes = true
  var videoFilePathShouldIncludeDate = true
  var isAnnotatedVideo  = true
  var movieTest = false
  private let framesPerSecond = 20
  private var frameIndex : Int = 0
  private var videoStartTime : Double = 0
  private var status : MovieWriterStatus = .readyToStart
  private var assetWriterInput : AVAssetWriterInput?
  private var assetWriterAdaptor : AVAssetWriterInputPixelBufferAdaptor?
  private var assetWriter : AVAssetWriter?
  private var lastVideoStartDateTime : Date = Date()

  //Set at initialization
  let saveDirectory : URL
  let frameSize : CGSize
  var colorSpace : CGColorSpace = CGColorSpaceCreateDeviceRGB()
  var bitmapInfo : UInt32 = CGImageAlphaInfo.noneSkipFirst.rawValue
  
  //Generated
  var videoFileUrl : URL?
  
  init(withSaveDirectory directory:URL, sourceBufferSize size:CGSize, andIdentifier videoIdentifier:String) {
    saveDirectory = directory
    frameSize = size
    videoId = videoIdentifier
    movieTest = false
  }
  
  func videoFilePathFor( andDate startTime:Date) -> URL {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-zzz"
    let dateString = formatter.string(from: startTime)
    var suffix = ""
    if videoSuffix != "" {
      suffix = "_\(videoSuffix)"
    }
		let movieName = "\(videoId)\(dateString)\(suffix).mp4"
    return saveDirectory.appendingPathComponent(movieName, conformingTo: .movie)
  }
  
  func startNewVideoWith(andDate startDateTime:Date) {
    if shouldSkipVideoWriting { return }
    lastVideoStartDateTime = startDateTime
    switch status {
    case .readyToStart:
      break
    case .readyToReceiveFrames:
      print("Attempting to start a new video before the current one is marked completed. Marking as complete video '\(self.videoFileUrl?.lastPathComponent ?? "")'")
      DispatchQueue.main.async { [weak self] in
        if let self = self {
          self.markCurrentVideoAsDoneAndSave()
        }
      }
    case .writingToDisc:
      print("error: attempted to start a new video before the previous video finished writing. Aborting")
      return
    }
    let videoFileUrl = videoFilePathFor(andDate:startDateTime)
    self.videoFileUrl = videoFileUrl
    print("Starting new video: \(videoFileUrl)")
    if FileManager.default.fileExists(atPath: videoFileUrl.path) {
      print("  File already exists. Attempting to remove")
      do {
        try FileManager.default.removeItem(at: videoFileUrl)
      } catch {
        print("error: Could not remove the previous video file. Error message: \(error.localizedDescription)")
      }
    }
    assetWriter = try? AVAssetWriter(outputURL: videoFileUrl, fileType: .mp4)
    guard let assetWriter = assetWriter else {
      print("error: The AVAssetWriter is nil")
      return
    }
    let videoSettings = [AVVideoCodecKey: AVVideoCodecType.h264,
                         AVVideoWidthKey: self.frameSize.width,
                        AVVideoHeightKey: self.frameSize.height] as [String : Any]
    //create a single video input
    assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    guard let assetWriterInput = assetWriterInput else {
      print("error: assetWriterInput is nil")
      return
    }
    let sourcePixelBufferAttributes = [String(kCVPixelBufferPixelFormatTypeKey) : kCMPixelFormat_32BGRA] as [String : Any]
    //create an adaptor for the pixel buffer
    assetWriterAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: assetWriterInput, sourcePixelBufferAttributes: sourcePixelBufferAttributes)
    //add the input to the asset writer
    assetWriter.add(assetWriterInput)
    //begin the session
    frameIndex = 0
    assetWriter.startWriting()
    assetWriter.startSession(atSourceTime: CMTime.zero)
    status = .readyToReceiveFrames
  }
  
  func addFrameToCurrentVideoWith(buffer pixelBuffer:CVPixelBuffer) {
    if shouldSkipVideoWriting { return }
    addFrameToCurrentVideoWith(buffer: pixelBuffer, andDrawDataFrom: nil)
  }
    
  func addFrameToCurrentVideoWith(buffer pixelBuffer:CVPixelBuffer, andDrawDataFrom frameResult:FrameResult?) {
    if shouldSkipVideoWriting { return }
    guard let assetWriterInput = assetWriterInput else {
      print("error: The assetWriterInput is nil")
      return
    }
    guard let assetWriterAdaptor = assetWriterAdaptor else {
      print("error: The assetWriterAdaptor is nil")
      return
    }
    if status != .readyToReceiveFrames {
      print("error: cannot add frames until a new video has been started. Please set the -eyeSide- or call -startNewVideoWith(eye:)-")
      return
    }
    var buffer = pixelBuffer
    if let frameResult = frameResult {
      drawFrameResult(frameResult, on: buffer)
    }
    if assetWriterInput.isReadyForMoreMediaData {
      let frameTime = CMTimeMake(value: Int64(frameIndex), timescale: Int32(framesPerSecond))
      //append the contents of the pixelBuffer at the correct time
      assetWriterAdaptor.append(buffer, withPresentationTime: frameTime)
      frameIndex += 1
    } else {
      print("error: assetWriterInput is not ready for more media. Skipping frame intended for index \(frameIndex)")
    }
  }
  
  func markCurrentVideoAsDoneAndSave(completion: (() -> Void)? = nil) {
    if shouldSkipVideoWriting { 
      completion?()
      return 
    }
    markCurrentVideoAsDoneAndSavePrivate(completion: completion)
  }
  
  private func markCurrentVideoAsDoneAndSavePrivate(completion: (() -> Void)? = nil) {
    
    if status != .readyToReceiveFrames {
      print("error: an attempt was made to save a video that has not been started")
      completion?()
      return
    }
    guard let assetWriterInput = assetWriterInput else {
      print("error: The assetWriterInput is nil")
      completion?()
      return
    }
    guard let assetWriter = assetWriter else {
      print("error: The assetWriterAdaptor is nil")
      completion?()
      return
    }
    status = .writingToDisc
    
    assetWriterInput.markAsFinished()
    print("Writing video '\(self.videoFileUrl?.lastPathComponent ?? "")' to disc")
    assetWriter.finishWriting { [weak self] in
      guard let self = self else {
        print("error: Finished writing video to disc and now self is nil.")
        completion?()
        return
      }
      self.status = .readyToStart
      print("Finished writing video '\(self.videoFileUrl?.lastPathComponent ?? "")' to disc")
      completion?()
    }
  }
  
    
  func drawFrameResult(_ frameResult: FrameResult, on pixelBuffer: CVPixelBuffer) {
      let cvLockFlag = CVPixelBufferLockFlags.init(rawValue: 0)
      let width = CVPixelBufferGetWidth(pixelBuffer)
      let height = CVPixelBufferGetHeight(pixelBuffer)
      guard
          CVPixelBufferLockBaseAddress(pixelBuffer, cvLockFlag) == kCVReturnSuccess,
          let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo)
      else {
          return
      }

      if frameIndex == 0 {
          videoStartTime = frameResult.startTime
      }

      var textHeight = CGFloat(context.height - 100)
      let elapsedSeconds = frameResult.startTime - videoStartTime

      let frameStr = "frame:\(frameResult.frameIndex)"
      draw(text: frameStr, at: CGPoint(x: 0, y: textHeight), in: context)
      textHeight -= 50

      let timeStr = "t:\(String(format: "%.2fs", elapsedSeconds))"
      draw(text: timeStr, at: CGPoint(x: 0, y: textHeight), in: context)

      if annotatedVideoShouldDisplayBoundingBoxes {
        frameResult.detectedObjects.forEach { object in
          // Use the bounding box on original coordinates
          draw(object: object, in: context, useOriginalCoordinates: true)
        }
      }

      _ = context.makeImage()
      CVPixelBufferUnlockBaseAddress(pixelBuffer, cvLockFlag)
  }
  
  func draw(object:DetectedObject, in context:CGContext, useOriginalCoordinates: Bool = false) {
    let bbox = useOriginalCoordinates ? object.boundingBoxOnOriginal : object.normalizedBbox
    var newRect = useOriginalCoordinates ? bbox : resize(rect: bbox, multiplier: context)
    draw(rect: newRect, with: object.color.cgColor, in: context)
    draw(text: object.label, at: newRect.origin, in: context)
  }
  
  func draw(rect:CGRect, with color:CGColor, in context:CGContext){
    context.setStrokeColor(color)
    context.setLineWidth(6)
    context.addRect(rect)
    context.drawPath(using: .stroke)
  }
  
  func draw(text:String, at point:CGPoint, in context:CGContext) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = NSLineBreakMode.byWordWrapping
    paragraph.alignment = .center // potentially this can be an input param too, but i guess in most use cases we want center align
    
    // Try to use Inter font, fallback to system font if not available
    let font = NSFont(name: "Inter-Regular", size: 30) ?? NSFont.systemFont(ofSize: 30, weight: .regular)
    let color = NSColor.white
    let attributedString = NSAttributedString(string: text,
                                              attributes: [NSAttributedString.Key.font: font,
                                                           NSAttributedString.Key.foregroundColor: color,
                                                           NSAttributedString.Key.paragraphStyle:paragraph])
    let line = CTLineCreateWithAttributedString(attributedString)
    context.textPosition = point
    CTLineDraw(line, context)
  }
  
  func resize(rect:CGRect, multiplier: CGContext) -> CGRect {
    return CGRectMake(rect.origin.x * CGFloat(multiplier.width), rect.origin.y * CGFloat(multiplier.height), rect.size.width * CGFloat(multiplier.width), rect.size.height * CGFloat(multiplier.height))
  }
  
}
