//
//  Logger.swift
//  AlgoTester
//
//  Created by Drew on 11/11/21.
//

import Foundation
import os.log
import UniformTypeIdentifiers

class Logger : NSObject, TextOutputStream {
  
  class func LOG_FUNC(_ obj : AnyObject? = nil,
                      file : NSString = #file,
                      function: String = #function) {
    var objAddress = ""
    if let obj = obj {
      objAddress = String(format:"%018p", unsafeBitCast(obj, to: Int.self))
    }
    os_log("%@.%@ %@", type:.info, file.lastPathComponent, function, objAddress)
  }
  
  class func LOG_ERR(_ message : String,
                     file : NSString = #file,
                     function : String = #function) {
    os_log("%@.%@: Error: %@", type: .error, file.lastPathComponent, function, message)
  }
  
  class func LOG_INFO(_ message : String,
                      file : NSString = #file,
                      function : String = #function) {
    os_log("%@.%@: Info: %@", type: .info, file.lastPathComponent, function, message)
  }
  
  static let log:  Logger = Logger()
  static let clock:Logger = Logger()
  private var startTime : DispatchTime = DispatchTime.now()
  var logFileHandle : FileHandle? = nil
  var logUrl : URL?
  var filename : String = ""
  var logID : String = ""
  
  override init() {} // we are sure, nobody else could create it

  func startNewLogWith(identifier:String, andDate dateTime:Date) {
    let docDirUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    startNewLogWith(identifier: identifier, date: dateTime, at: docDirUrl)
  }

  func startNewLogWith(identifier:String, date:Date, at directoryUrl:URL) {
    print("Starting new log")
    if let logFileHandle = self.logFileHandle {
      logFileHandle.synchronizeFile() //Flush out data that might be in RAM to disc
      logFileHandle.closeFile() //Close the file
      self.logFileHandle = nil
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-zzz"
    let dateString = formatter.string(from: date)
    if identifier == "" {
      filename = "\(dateString)\(logID).log"
      if logID.contains("perFrameForTraining") {
        filename = "\(logID).log"
      }
    } else {
      filename = "\(identifier)_\(dateString)\(logID).log"
      if logID.contains("perFrameForTraining") {
        filename = "\(identifier)\(logID).log"
      }
    }
    let logUrl = directoryUrl.appendingPathComponent(filename, conformingTo: .log)
    if !FileManager.default.fileExists(atPath: logUrl.path) {
      let res = FileManager.default.createFile(atPath: logUrl.path, contents: nil)
      if !res {
        print("error: could not create the log file '\(logUrl)'")
        return
      }
    }
    do {
      self.logFileHandle = try FileHandle(forWritingTo:logUrl)
    } catch {
      print("error: Could not create the log file handle at '\(logUrl)'. Error: \(error)")
      return
    }
    print("New log name is '\(logUrl)'")
    self.logUrl = logUrl
    if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
       let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
      self.write("App Version: \(appVersion) (\(buildVersion))\n")
    } else {
      self.write("App Version: unknown")
    }
  }

  func write(_ string: String) {
    if self.logFileHandle == nil {
      startNewLogWith(identifier: "", andDate: Date())
    }
    guard let logFileHandle = self.logFileHandle else {
      print("error: could not print \(string) to the log")
      return
    }
    var finalString = string
    if finalString[0] == "\"" && finalString[string.count-1] == "\"" {
      finalString.removeFirst()
      finalString.removeLast()
    }
    logFileHandle.write(finalString.data(using: .utf8)!)
  }
  
  func startMeasureClock() {
    startTime = DispatchTime.now()
  }
  
  func measureWith(message:String) {
    let nanoDiffTime = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
    let timeInterval = Double(nanoDiffTime) / 1_000_000_000
    print("\(message): \(timeInterval)")
  }
}
