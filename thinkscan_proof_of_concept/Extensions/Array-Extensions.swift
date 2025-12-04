//
//  Array-Extensions.swift
//  AlgoTester
//
//  Created by Drew Hosford on 1/11/23.
//  Copyright © 2023 Y Media Labs. All rights reserved.
//

import Foundation
import Accelerate

extension Array where Element: FloatingPoint {
    
  
  /// The mean average of the items in the collection.
    
    var mean: Element { return reduce(Element(0), +) / Element(count) }
    
    /// The unbiased sample standard deviation. Is `nil` if there are insufficient number of items in the collection.
    
    var stdev: Element? {
        guard count > 1 else { return nil }
        
        return sqrt(sumSquaredDeviations() / Element(count - 1))
    }
    
    /// The population standard deviation. Is `nil` if there are insufficient number of items in the collection.
    
    var stdevp: Element? {
        guard count > 0 else { return nil }
        
        return sqrt(sumSquaredDeviations() / Element(count))
    }
    
    /// Calculate the sum of the squares of the differences of the values from the mean
    ///
    /// A calculation common for both sample and population standard deviations.
    ///
    /// - calculate mean
    /// - calculate deviation of each value from that mean
    /// - square that
    /// - sum all of those squares
    
    private func sumSquaredDeviations() -> Element {
        let average = mean
        return map {
            let difference = $0 - average
            return difference * difference
        }.reduce(Element(0), +)
    }
}
extension Array where Element: Equatable {

    func indexes(ofItemsNotEqualTo item: Element) -> [Int]  {
        return enumerated().compactMap { $0.element != item ? $0.offset : nil }
    }
    func indexes(ofItemsEqualTo item: Element) -> [Int]  {
        return enumerated().compactMap { $0.element == item ? $0.offset : nil }
    }
    func splitIntoEqualChunksRandomized(_ numberOfChunks: Int) -> [[Element]] {
        var tempArray = self
        tempArray.shuffle()
        let chunkSize = Int(ceil(Double(count) / Double(numberOfChunks)))
        return stride(from: 0, to: count, by: chunkSize).map {
            Array(tempArray[$0..<Swift.min($0 + chunkSize, count)])
        }
    }
}
extension Array where Element: BinaryInteger {
    var checkValue: Double? { return map { Double(exactly: $0)! }.checkValue}
    var mean: Double? { return map { Double(exactly: $0)! }.mean }
    var stdev: Double? { return map { Double(exactly: $0)! }.stdev }
    var stdevp: Double? { return map { Double(exactly: $0)! }.stdevp }
}


extension Array where Element == Double {
  var checkValue: Element {
    
    return mathValue()
  }
  
  private func mathValue() -> Element {
    let values = map {
      if $0 > 0.05 {
        return 1
      } else if $0 < -0.05 {
        return -1
      } else {
        return 0
      }
    }.reduce(0,+)
    if values > 0 {
      return 1
    } else if values < 0{
      return -1
    } else {
      return 0
    }
  }
  func fastMean() -> Double {
    return vDSP.mean(self)
  }
  func maximum() -> Double {
    return vDSP.maximum(self)
  }
  func minimum() -> Double {
    return vDSP.minimum(self)
  }
  func meanSquare() -> Double {
    return vDSP.meanSquare(self)
  }
  func meanMagniture() -> Double {
    return vDSP.meanMagnitude(self)
  }
  func rootMeanSquare() -> Double {
    return vDSP.rootMeanSquare(self)
  }
  func standartDeviation() -> Double{
    return(sqrt(vDSP.sumOfSquares(self)/Double(count)))
  }
  func weightedMean(splits: Double) -> Double {
    if count == 0 {
      return Double(0)
    }
    let size = Double(count)
    var values: Double = 0
    var divider: Double = 0
    let splitsNumber = size / splits
    let splitsMultiplier = 100.0 / splits
    let splitsValues = Array(stride(from: splitsNumber, through: size, by: splitsNumber))
    let splitsMultiplierValues = Array(stride(from: splitsMultiplier, through: 100.0, by: splitsMultiplier))
    let splitsValuesRounded = splitsValues.map { Int(round($0)) }
    var counter = 0
    
    withUnsafeBufferPointer { bufferPointer in
      let dataPointer = bufferPointer.baseAddress!
      
      for i in 0..<count {
        if i + 1 > splitsValuesRounded[counter] {
          counter += 1
        }
        values += dataPointer[i] * splitsMultiplierValues[counter]
        divider += splitsMultiplierValues[counter]
      }
    }
    
    return values / divider
  }
}


import Metal

final class MetalHelper {
    static let shared = MetalHelper()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
    }
}

import Accelerate
import Metal
import MetalPerformanceShaders

extension Array where Element == Float {
    func upsample(
        initialSize: (width: Int, height: Int),
        targetSize: (width: Int, height: Int)? = nil,
        scale: Int? = nil,
        maskThreshold: Float
    ) -> [UInt8] {
        let initialWidth = initialSize.width
        let initialHeight = initialSize.height

        guard let metal = MetalHelper.shared else { return [] }

        let inputArray: [UInt8] = self.map { UInt8(clamping: Int($0 * 255)) }

        guard let newSize = targetSize ?? (scale.map { (initialWidth * $0, initialHeight * $0) }) else {
            return inputArray
        }

        let newWidth = newSize.0
        let newHeight = newSize.1

        guard initialWidth != newWidth || initialHeight != newHeight else {
            let thresholdValue = UInt8(clamping: Int(maskThreshold * 255))
            let grayscaleArray: [UInt8] = inputArray.map { $0 > thresholdValue ? 255 : 0 }
            return grayscaleArray
        }

        func createTexture(from array: [UInt8], width: Int, height: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor()
            descriptor.pixelFormat = .r8Unorm
            descriptor.width = width
            descriptor.height = height
            descriptor.usage = [.shaderRead, .shaderWrite]

            guard let texture = metal.device.makeTexture(descriptor: descriptor) else { return nil }

            let region = MTLRegionMake2D(0, 0, width, height)
            texture.replace(region: region, mipmapLevel: 0, withBytes: array, bytesPerRow: width)

            return texture
        }

        func readTextureData(texture: MTLTexture) -> [UInt8] {
            let byteCount = texture.width * texture.height
            var outputArray = [UInt8](repeating: 0, count: byteCount)
            let region = MTLRegionMake2D(0, 0, texture.width, texture.height)
            texture.getBytes(&outputArray, bytesPerRow: texture.width, from: region, mipmapLevel: 0)
            return outputArray
        }

        guard let inputTexture = createTexture(from: inputArray, width: initialWidth, height: initialHeight),
              let outputTexture = createTexture(from: [UInt8](repeating: 0, count: newWidth * newHeight), width: newWidth, height: newHeight),
              let commandBuffer = metal.commandQueue.makeCommandBuffer() else {
            return inputArray
        }

        let bilinear = MPSImageBilinearScale(device: metal.device)
        bilinear.encode(commandBuffer: commandBuffer, sourceTexture: inputTexture, destinationTexture: outputTexture)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let result = readTextureData(texture: outputTexture)
        let thresholdValue = UInt8(clamping: Int(maskThreshold * 255))

        let grayscaleArray: [UInt8] = result.map { $0 > thresholdValue ? 255 : 0 }
        return grayscaleArray
    }
}

extension Array {
    public subscript(
        index: Int,
        default defaultValue: @autoclosure () -> Element?
    ) -> Element? {
        guard index >= 0, index < endIndex else {
            return defaultValue()
        }

        return self[index]
    }
}

