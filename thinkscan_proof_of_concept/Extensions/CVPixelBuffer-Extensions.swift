//
//  CVPixelBuffer-Extensions.swift
//  AlgoTester
//
//  Created by Spect on 5/30/23.
//  Copyright © 2023 Y Media Labs. All rights reserved.
//

import Foundation
import Accelerate
import CoreImage
import CoreGraphics   // ⬅️ Needed for CGImage

extension CVPixelBuffer {

  // Reuse a single CIContext for performance
  private static let sharedCIContext = CIContext(options: nil)

  /// Convert this CVPixelBuffer into a CGImage.
  func toCGImage() -> CGImage? {
    let ciImage = CIImage(cvPixelBuffer: self)
    let width = CVPixelBufferGetWidth(self)
    let height = CVPixelBufferGetHeight(self)
    let rect = CGRect(x: 0, y: 0, width: width, height: height)

    return CVPixelBuffer.sharedCIContext.createCGImage(ciImage, from: rect)
  }

  func rotate180ToCopy() -> CVPixelBuffer? {
    let ciImage = CIImage(cvPixelBuffer: self)
    //Create an affine transformation that rotates around the center of the image
    let center = CGPointMake(ciImage.extent.width / 2, ciImage.extent.height / 2)
    let rotateAroundCenterAffine = CGAffineTransform(translationX: center.x, y: center.y)
      .rotated(by: CGFloat.pi)
      .translatedBy(x: -center.x, y: -center.y)
    let rotatedCIImage = ciImage.transformed(by: rotateAroundCenterAffine)
    let attributes = CVPixelBufferCopyCreationAttributes(self)
    let width = CVPixelBufferGetWidth(self)
    let height = CVPixelBufferGetHeight(self)
    //Create a new CVPixelBuffer to hold the rotated image
    var rotatedPixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault,
                        width,
                        height,
                        kCVPixelFormatType_32BGRA,
                        attributes,
                        &rotatedPixelBuffer)

    let cvLockFlag = CVPixelBufferLockFlags.init(rawValue: 0)
    guard let rotatedPixelBuffer = rotatedPixelBuffer,
          CVPixelBufferLockBaseAddress(rotatedPixelBuffer, cvLockFlag) == kCVReturnSuccess else {
      print("error: pixelbuffer did not create")
      return nil
    }
    let context = CIContext()
    context.render(rotatedCIImage,
                   to: rotatedPixelBuffer)
    CVPixelBufferUnlockBaseAddress(rotatedPixelBuffer, cvLockFlag)
    return rotatedPixelBuffer
  }

  func deepCopy() -> CVPixelBuffer? {
    //We copy the memory using mempcy, because using CVPixelBufferCreateWithBytes does not copy the data, but rather references it again
    let cvLockFlag = CVPixelBufferLockFlags.init(rawValue: 0)
    guard CVPixelBufferLockBaseAddress(self, cvLockFlag) == kCVReturnSuccess else {
      print("error: could not lock the pixelBuffer")
      return nil
    }
    //Allocate new memory for the copy
    let width = CVPixelBufferGetWidth(self)
    let height = CVPixelBufferGetHeight(self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(self)
    var attributes = CVPixelBufferCopyCreationAttributes(self)
    attributes = [
      kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
      kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
    ] as CFDictionary
    var pixelBufferCopy : CVPixelBuffer? = nil
    guard CVPixelBufferCreate(kCFAllocatorDefault,
                              width,
                              height,
                              kCVPixelFormatType_32BGRA,
                              attributes,
                              &pixelBufferCopy) == kCVReturnSuccess else {
      print("error: could not allocated the pixelBuffer")
      return nil
    }
    guard let pixelBufferCopy = pixelBufferCopy,
          CVPixelBufferLockBaseAddress(pixelBufferCopy, cvLockFlag) == kCVReturnSuccess else {
      print("error: could not lock the pixelBufferCopy")
      return nil
    }
    guard let pixelBufferBaseAddress     = CVPixelBufferGetBaseAddress(self),
          let pixelBufferCopyBaseAddress = CVPixelBufferGetBaseAddress(pixelBufferCopy) else {
      print("error: could not get the base addresses of the pixel buffers")
      return nil
    }
    // We use memcpy to copy the raw data as it does a true deep copy
    memcpy(pixelBufferCopyBaseAddress, pixelBufferBaseAddress, height * bytesPerRow);
    CVPixelBufferUnlockBaseAddress(self, cvLockFlag)
    CVPixelBufferUnlockBaseAddress(pixelBufferCopy, cvLockFlag)
    return pixelBufferCopy
  }
}
