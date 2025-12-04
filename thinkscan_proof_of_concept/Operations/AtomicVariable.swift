//
//  AtomicInteger.swift
//  AlgoTester
//
//  Created by Drew on 11/11/21.
//

import Foundation

class AtomicVariable<SomeType> {
    private let queue = DispatchQueue(label: "com.thinkscan.thinkscan_proof_of_concept.AtomicVariableQueue") //Static var means the same queue will be used for all atomic variables
    private var _value : SomeType
    var value: SomeType {
        get {
            return _value
        }
        set (newValue) {
            queue.sync {
                _value = newValue
            }
        }
    }
    
    init(initialValue : SomeType) {
        _value = initialValue
    }
}
