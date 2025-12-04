//
//  FileManager-Extensions.swift
//  AlgoTester
//
//  Created by Drew Hosford on 8/30/23.
//  Copyright © 2023 Y Media Labs. All rights reserved.
//

import Foundation

extension FileManager {
  func getDocumentsSubdirectoryCreatingIfNecessary(_ subdirectory:String) throws -> URL? {
    let docDir = self.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let fullPath = docDir.appendingPathComponent(subdirectory)
    if !FileManager.default.fileExists(atPath: fullPath.path) {
      try FileManager.default.createDirectory(at: fullPath, withIntermediateDirectories: true)
    }
    return fullPath
  }

  func getContentsRecursivelyOf(dirUrl:URL, contents:[URL]) throws -> [URL] {
    if !dirUrl.hasDirectoryPath {
      return contents
    }
    var updatedContents = contents
    do {
      let dirContents = try self.contentsOfDirectory(at: dirUrl,
                                                     includingPropertiesForKeys: nil,
                                                     options: [])
      for pathUrl in dirContents {
        if pathUrl.lastPathComponent == ".DS_Store" {
          continue
        }
        if pathUrl.hasDirectoryPath {
          updatedContents = try getContentsRecursivelyOf(dirUrl: pathUrl, contents: updatedContents)
          continue
        }
        updatedContents.append(pathUrl)
      }
    }
    return updatedContents
  }
  
  func getContentsOf(dirUrl: URL, filteringWith keywords:[String]) -> [URL] {
    var filteredFileUrls : [URL] = []
    var fileUrls : [URL] = []
    do {
      fileUrls = try self.getContentsRecursivelyOf(dirUrl: dirUrl, contents: [])
    } catch {
      print("error: Encoutered error searching for files in '\(dirUrl)': '\(error)'")
      return []
    }
    if keywords.count == 0 {
      return fileUrls
    }
    for fileUrl in fileUrls {
      let searchable = fileUrl.path.replacingOccurrences(of: dirUrl.path, with: "")
      var keywordWasFound = false
      for keyword in keywords {
        if searchable.contains(keyword) {
          keywordWasFound = true
          break
        }
      }
      if keywordWasFound {
        filteredFileUrls.append(fileUrl)
      }
    }
    return filteredFileUrls
  }

  func rename(_ fromUrl:URL, to toUrl:URL) throws {
    if self.fileExists(atPath: toUrl.path) {
      try self.removeItem(at: toUrl)
    }
    try self.moveItem(at: fromUrl, to: toUrl)
  }
}
