//
//  FoundationExtensions.swift
//  AlgoTester
//
//  Created by Drew on 11/11/21.
//

import Foundation

// Adapted from: https://stackoverflow.com/questions/24051314/precision-string-format-specifier-in-swift
extension Float {
    func string(_ fractionDigits : Int) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}

extension Double {
    func string(_ fractionDigits : Int) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}
