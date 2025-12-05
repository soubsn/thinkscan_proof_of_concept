//
//  CGRect-Extensions.swift
//  AlgoTester
//
//  Created by Drew Hosford on 1/11/23.
//  Copyright © 2023 Y Media Labs. All rights reserved.
//

import Foundation
import CoreGraphics

extension CGRect {
  func center() -> CGPoint {
    return CGPoint(
      x: Int(self.origin.x + size.width  / 2),
      y: Int(self.origin.y + size.height / 2)
    )
  }
  var asCSVStringRounded : String {
    get {
      return "\(self.integral.minX),\(self.integral.minY),\(self.integral.width),\(self.integral.height)"
    }
  }
  var asCSVString : String {
    get {
      return "\(self.minX),\(self.minY),\(self.width),\(self.height),"
    }
  }
}

