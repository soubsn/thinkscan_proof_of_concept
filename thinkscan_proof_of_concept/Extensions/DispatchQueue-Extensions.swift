//
//  DispatchQueue-Extensions.swift
//  AlgoTester
//
//  Created by Drew Hosford on 8/23/23.
//  Copyright © 2023 Y Media Labs. All rights reserved.
//

import Foundation

protocol DispatchQueueTestable {
  func async(execute work: @escaping @convention(block) () -> Void)
}

extension DispatchQueue : DispatchQueueTestable {
  func async(execute work: @escaping @convention(block) () -> Void) {
    async(group:nil, qos: .unspecified, flags:[], execute: work)
  }
}
