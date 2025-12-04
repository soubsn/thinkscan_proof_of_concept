//
//  MovieFeedManager.swift
//  AlgoTester
//
//  Created by Nicolas Soubry on 2023-01-18.
//  Copyright © 2023 Y Media Labs. All rights reserved.
//

import Foundation
import AVFoundation
import AppKit
import Accelerate

protocol MovieFeedManagerDelegate : AnyObject {
  
  /// Delivers the pixel buffer of the video selected.
  func didReceiveNextMovieBuffer(_ pixelBuffer: CVPixelBuffer?)
  /// Delivers the original unpadded pixel buffer for video writing
  func didReceiveOriginalMovieBuffer(_ originalPixelBuffer: CVPixelBuffer?)
  func didEncounterError(_ error:String)
  func didFinishMovie()
  func didFinishLoadingMovie()
  func didGet(colorSpace: CGColorSpace, bitmapInfo: UInt32)
}

enum MovieConfiguration {
  case success
  case failed
}

class MovieFeedManager {
  private let playbackQueue = DispatchQueue(label: "org.thinkscan.thinkscan_proof_of_concept.playbackqueue")
  weak var delegate: MovieFeedManagerDelegate?
  var videoAsset : AVAsset?
  var videoAssetUrl : URL?
  var videoPlayerAsset: AVPlayer?
  var videoName : String = ""
  var generator : AVAssetImageGenerator?
  var duration : Int64?
  var timescale : Int32?
  var actualTime : CMTime = CMTime.zero
  var fps : Int64 = 20
  var totalTime : Double = 0
  var frameNum : Int64 = 0
  var logicCount : Int64 = 0
  var logicWrong : Int64 = 0
  var totalFrames : Int64 = 0
  var timeOffsetIfError = CMTimeMake(value:0, timescale:0)
  var movieView: NSImageView?
  
  init() {
    //Logger.LOG_FUNC(self)
  }
  
  deinit {
   //Logger.LOG_FUNC(self)
  }
  
  func addMovieViewToView(_ view: NSView) {
    //Logger.LOG_FUNC()
    if movieView == nil {
      movieView = NSImageView()
    }
    if let movieView = movieView {
      movieView.frame = view.frame
      view.addSubview(movieView)
    }
  }
  
  func removeMovieViewFromSuperView() {
    //Logger.LOG_FUNC()
    if let movieView = movieView {
      movieView.removeFromSuperview()
    }
  }
  
  func pixelBufferFrom(cgImage: CGImage) -> (paddedBuffer: CVPixelBuffer?, originalBuffer: CVPixelBuffer?) {
    // Use the source CGImage's size
    let sourceImage = cgImage
    let srcWidth = sourceImage.width
    let srcHeight = sourceImage.height

    // Create color space and bitmap info for 32BGRA output
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    // MARK: - Create Original (Unpadded) Pixel Buffer
    let attrs: CFDictionary = [
      kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
      kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!
    ] as CFDictionary

    var originalPxBuffer: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, srcWidth, srcHeight, kCVPixelFormatType_32BGRA, attrs, &originalPxBuffer) == kCVReturnSuccess,
          let originalPixelBuffer = originalPxBuffer else {
      print("Could not allocate original CVPixelBuffer.")
      return (nil, nil)
    }

    let cvLockFlag = CVPixelBufferLockFlags(rawValue: 0)
    guard CVPixelBufferLockBaseAddress(originalPixelBuffer, cvLockFlag) == kCVReturnSuccess else {
      print("error: could not lock the original pxbuffer")
      return (nil, nil)
    }

    guard let originalBaseAddress = CVPixelBufferGetBaseAddress(originalPixelBuffer) else {
      CVPixelBufferUnlockBaseAddress(originalPixelBuffer, cvLockFlag)
      print("error: could not get base address for original pixel buffer")
      return (nil, nil)
    }

    let originalBytesPerRow = CVPixelBufferGetBytesPerRow(originalPixelBuffer)

    // Create context for original buffer
    guard let originalContext = CGContext(data: originalBaseAddress,
                                          width: srcWidth,
                                          height: srcHeight,
                                          bitsPerComponent: 8,
                                          bytesPerRow: originalBytesPerRow,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo) else {
      CVPixelBufferUnlockBaseAddress(originalPixelBuffer, cvLockFlag)
      print("error: Could not create context for original pixel buffer")
      return (nil, nil)
    }

    // Draw the source image directly onto the original buffer
    originalContext.draw(sourceImage, in: CGRect(x: 0, y: 0, width: srcWidth, height: srcHeight))
    CVPixelBufferUnlockBaseAddress(originalPixelBuffer, cvLockFlag)

    // Attach color space to original buffer
    CVBufferSetAttachment(originalPixelBuffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)

    // MARK: - Create Padded (Square) Pixel Buffer
    // Determine square canvas size (max of width/height)
    let side = max(srcWidth, srcHeight)

    // Compute padding values
    let padLeft = (side - srcWidth) / 2
    let padRight = side - srcWidth - padLeft
    let padTop = (side - srcHeight) / 2
    let padBottom = side - srcHeight - padTop

    var pxbuffer: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, attrs, &pxbuffer) == kCVReturnSuccess,
          let pixelBuffer = pxbuffer else {
      print("Could not allocate padded CVPixelBuffer.")
      return (nil, originalPixelBuffer)
    }

    guard CVPixelBufferLockBaseAddress(pixelBuffer, cvLockFlag) == kCVReturnSuccess else {
      print("error: could not lock the padded pxbuffer")
      return (nil, originalPixelBuffer)
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, cvLockFlag) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      print("error: could not get base address for padded pixel buffer")
      return (nil, originalPixelBuffer)
    }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

    // Create a CGContext backed by the padded pixel buffer
    guard let context = CGContext(data: baseAddress,
                                  width: side,
                                  height: side,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo) else {
      print("error: Could not create a new context for padded buffer")
      return (nil, originalPixelBuffer)
    }

    // Fill with padding color (114,114,114) in sRGB; convert to CGFloat 0..1
    let pad: CGFloat = 114.0 / 255.0
    context.setFillColor(red: pad, green: pad, blue: pad, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))

    // Compute draw rect to center the source image on the square canvas
    let drawX = padLeft
    let drawY = padTop

    // Core Graphics origin is bottom-left; if you need a specific orientation, you can adjust transforms here.
    // For now, draw as-is (no forced rotation). If rotation is needed, apply transforms similar to previous code.
    context.draw(sourceImage, in: CGRect(x: drawX, y: drawY, width: srcWidth, height: srcHeight))

    // Inform delegate of the output color space/bitmap info
    self.delegate?.didGet(colorSpace: colorSpace, bitmapInfo: UInt32(bitmapInfo))

    // Attach padding and size metadata to the pixel buffer for later retrieval
    let paddingInfo: NSDictionary = [
      "padLeft": padLeft,
      "padRight": padRight,
      "padTop": padTop,
      "padBottom": padBottom,
      "srcWidth": srcWidth,
      "srcHeight": srcHeight,
      "side": side
    ]
    CVBufferSetAttachment(pixelBuffer, "com.ymedialabs.padding" as CFString, paddingInfo, .shouldPropagate)
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)

    return (pixelBuffer, originalPixelBuffer)
  }
  
  func resizeImage(_ cgImage: CGImage, toHeight: CGFloat) -> CGImage? {
      let uiImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
      let aspectRatio = CGFloat(cgImage.width) / CGFloat(cgImage.height)
      let newWidth = toHeight * aspectRatio
      let newSize = CGSize(width: newWidth, height: toHeight)
      
      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(newSize.width), pixelsHigh: Int(newSize.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
      let newImage = NSImage(size: newSize)
      newImage.addRepresentation(rep!)
      newImage.lockFocus()
      uiImage.draw(in: CGRect(origin: .zero, size: newSize))
      newImage.unlockFocus()
      
      return newImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
  }
  
  func loadVideoWith(videoUrl: URL) {
    videoAssetUrl = videoUrl
    videoName = videoUrl.lastPathComponent
    let loadedVideoAsset = AVURLAsset(url: videoUrl)
    
    if #available(macOS 13.0, *) {
      Task { [weak self] in
        guard let self = self else { return }
        do {
          // Load both tracks and duration before proceeding
          _ = try await loadedVideoAsset.load(.tracks, .duration)
          print("video track loaded for \(self.videoName)")
          
          // Now that the asset is loaded, set it and configure the generator
          self.videoAsset = loadedVideoAsset
          self.configureGeneratorAndNotify(with: loadedVideoAsset)
          
        } catch {
          print("failed to load video track for '\(self.videoName)' with error \(error)")
          self.delegate?.didEncounterError("error: could not load video at '\(videoUrl)' - \(error.localizedDescription)")
        }
      }
    } else {
      let keys = ["tracks", "duration"]
      loadedVideoAsset.loadValuesAsynchronously(forKeys: keys) { [weak self] in
        guard let self = self else { return }
        var error: NSError? = nil
        let tracksStatus = loadedVideoAsset.statusOfValue(forKey: "tracks", error: &error)
        let durationStatus = loadedVideoAsset.statusOfValue(forKey: "duration", error: &error)
        
        guard tracksStatus == .loaded && durationStatus == .loaded else {
          print("failed to load video track for '\(self.videoName)' with error \(String(describing: error))")
          self.delegate?.didEncounterError("error: could not load video at '\(videoUrl)'")
          return
        }
        
        print("video track loaded for \(self.videoName)")
        self.videoAsset = loadedVideoAsset
        self.configureGeneratorAndNotify(with: loadedVideoAsset)
      }
    }
  }
  
  /// Configures the AVAssetImageGenerator and notifies the delegate that loading is complete.
  /// This should only be called after the asset's tracks and duration have been fully loaded.
  private func configureGeneratorAndNotify(with asset: AVURLAsset) {
    playbackQueue.async { [weak self] in
      guard let self = self else { return }
      
      self.generator = AVAssetImageGenerator(asset: asset)
      self.generator?.appliesPreferredTrackTransform = true
      self.generator?.requestedTimeToleranceAfter = CMTime.zero
      self.generator?.requestedTimeToleranceBefore = CMTime.zero
      
      // Use a local constant for duration to avoid repeated direct property access.
      // Duration was already loaded earlier via load(.duration).
      let duration: CMTime = asset.duration
      self.duration = duration.value
      self.timescale = duration.timescale
      self.totalTime = Double(duration.value) / Double(duration.timescale)
      
      self.frameNum = 1
      self.totalFrames = Int64(self.totalTime * Double(self.fps))
      self.timeOffsetIfError = CMTimeMake(value: 0, timescale: Int32(self.fps))
      
      if self.totalFrames == 0 {
        self.delegate?.didEncounterError("error: 0 total frames in video \(self.videoName)")
        return
      }
      self.delegate?.didFinishLoadingMovie()
    }
  }
  
  /// Resets the movie frame number to 1. After calling this method, call getNextFrame() to ensure that MovieFeedManager loads the first frame and therefore starts the movie all over again
  func restartMovie() {
    self.frameNum = 1
  }
  
  func getNextFrame() {
    playbackQueue.async { [weak self] in
      guard let self = self else {
        print("error: encountered nil self")
        return
      }
      Task {
        guard let generator = self.generator else {
          self.delegate?.didEncounterError("error: encountered nil generator")
          return
        }
        if self.frameNum >= self.totalFrames { //Force the video to start over
          self.delegate?.didFinishMovie()
          return
        }
        let frameTime = CMTimeMake(value: Int64(self.frameNum), timescale: Int32(self.fps))
        let timestamp = CMTimeAdd(frameTime, self.timeOffsetIfError)
        
        
        
        var cgImage : CGImage?
        do {
          if #available(iOS 16, *) {
            cgImage = try await generator.image(at: timestamp).image
          } else {
            cgImage = try generator.copyCGImage(at: timestamp, actualTime: &self.actualTime)
          }
        } catch {
          let error = error as NSError
          if error.code == -11832 {
            print("Skipping computed time \(self.frameNum - 1) for video \(self.videoName)")
            if abs(self.totalFrames - self.frameNum) < 2 { //handle errors where the last timestamp prediction is off by a little
              self.delegate?.didFinishMovie()
            } else {  // handle errors where the first timestamp prediction was off by a little
              self.timeOffsetIfError = timestamp
              self.frameNum += 1
              self.getNextFrame()
            }
          } else {
            self.delegate?.didEncounterError("Encountered error getting frame at time \(timestamp)\n\(error)")
          }
          return
        }
        guard let cgImage = cgImage else {
          self.delegate?.didEncounterError("  error: cgImage is nil at frame \(self.frameNum)")
          return
        }
        print("Analyzing frame (\(self.frameNum)/\(self.totalFrames)) in \(self.videoName)", terminator:"\r")
        self.frameNum += 1
        let (paddedBuffer, originalBuffer) = self.pixelBufferFrom(cgImage:cgImage)
        
        // Send original buffer first (for video writing)
        self.delegate?.didReceiveOriginalMovieBuffer(originalBuffer)
        // Then send padded buffer (for analysis)
        self.delegate?.didReceiveNextMovieBuffer(paddedBuffer)
        if let _ = self.movieView {
          DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let movieView = self.movieView,
                  movieView.superview != nil else { return }
            movieView.image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            movieView.needsDisplay = true
          }
        }
      }
    }
  }
}

