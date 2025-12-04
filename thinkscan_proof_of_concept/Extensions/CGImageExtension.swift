//
//  CGImageExtension.swift
//  AlgoTester
//
//  Created by Nicolas Soubry on 2023-12-11.
//  Copyright © 2023 Y Media Labs. All rights reserved.
//

import Foundation
import CoreGraphics

extension CGImage {
    func flipped(horizontally: Bool, vertically: Bool) -> CGImage? {
        let width = self.width
        let height = self.height
        let bitsPerComponent = self.bitsPerComponent
        let bytesPerRow = self.bytesPerRow
        let colorSpace = self.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = self.bitmapInfo

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        var transform = CGAffineTransform.identity

        if horizontally {
            transform = transform.scaledBy(x: -1, y: 1)
            transform = transform.translatedBy(x: CGFloat(-width), y: 0)
        }

        if vertically {
            transform = transform.scaledBy(x: 1, y: -1)
            transform = transform.translatedBy(x: 0, y: CGFloat(-height))
        }

        context.concatenate(transform)
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))

        return context.makeImage()
    }
}
