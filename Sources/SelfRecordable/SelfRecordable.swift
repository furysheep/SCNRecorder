//
//  SelfRecordable.swift
//  SCNRecorder
//
//  Created by Vladislav Grigoryev on 30.12.2019.
//  Copyright © 2020 GORA Studio. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

import Foundation
import UIKit
import AVFoundation
import SceneKit
import ARKit
import Combine

struct FMP4WriterConfiguration {
  let segmentFileNamePrefix = "media"
  let indexFileName = "index.m3u8"
  let segmentDuration = 6
}

public enum SelfRecordableError: Swift.Error {
  case recorderNotInjected
  case videoRecordingAlreadyStarted
}

public protocol SelfRecordable: AnyObject {

  typealias Recorder = (BaseRecorder & Renderable)

  var recorder: Recorder? { get }

  var videoRecording: VideoRecording? { get set }

  func prepareForRecording()

  func injectRecorder()
}

extension SelfRecordable {

  func assertedRecorder(
    file: StaticString = #file,
    line: UInt = #line,
    function: StaticString = #function
  ) -> Recorder {
    assert(
      recorder != nil,
      "prepareForRecording() must be called before \(function)",
      file: file,
      line: line
    )
    return recorder!
  }
}

public extension SelfRecordable {

  func prepareForRecording() {
    guard recorder == nil else { return }
    injectRecorder()
    assert(recorder != nil)
  }
}

#if !targetEnvironment(simulator)

public extension SelfRecordable where Self: MetalRecordable {

  func prepareForRecording() {
    (recordableLayer as? CAMetalLayer)?.swizzle()

    guard recorder == nil else { return }
    injectRecorder()
    assert(recorder != nil)
  }
}

#endif // !targetEnvironment(simulator)

public extension SelfRecordable {

  @discardableResult
  func startVideoRecording(
    fileType: VideoSettings.FileType = .mov,
    size: CGSize? = nil,
    segmentation: Bool = false
  ) throws -> VideoRecording {
    try startVideoRecording(videoSettings: VideoSettings(fileType: fileType, size: size), segmentation: segmentation)
  }

  func capturePixelBuffers(
    handler: @escaping (CVPixelBuffer, CMTime) -> Void
  ) -> PixelBufferOutput {
    assertedRecorder().capturePixelBuffers(handler: handler)
  }

  @discardableResult
  func startVideoRecording(
    to url: URL,
    fileType: VideoSettings.FileType = .mov,
    size: CGSize? = nil
  ) throws -> VideoRecording {
    try startVideoRecording(to: url, videoSettings: VideoSettings(fileType: fileType, size: size))
  }

  @discardableResult
  func startVideoRecording(
    videoSettings: VideoSettings,
    audioSettings: AudioSettings = AudioSettings(),
    segmentation: Bool = false
  ) throws -> VideoRecording {
    return try startVideoRecording(
        to: FileManager.default.temporaryDirectory.appendingPathComponent(
        "\(UUID().uuidString).\(videoSettings.fileType.fileExtension)",
        isDirectory: false
      ),
      videoSettings: videoSettings,
      audioSettings: audioSettings,
      segmentation: segmentation
    )
  }

  @discardableResult
  func startVideoRecording(
    to url: URL,
    videoSettings: VideoSettings,
    audioSettings: AudioSettings = AudioSettings(),
    segmentation: Bool = false
  ) throws -> VideoRecording {
    guard videoRecording == nil else { throw SelfRecordableError.videoRecordingAlreadyStarted }

    let config = FMP4WriterConfiguration()
    var segmentGenerator: PassthroughSubject<Segment, Error>?

    let indexFileURL = URL(fileURLWithPath: config.indexFileName, isDirectory: false, relativeTo: url)
    if segmentation {
      var segmentAndIndexFileWriter: AnyCancellable?

      segmentGenerator = PassthroughSubject<Segment, Error>()

      // Generate an index file from a stream of Segments.
      let indexFileGenerator = segmentGenerator!.reduceToIndexFile(using: config)

      // Write each segment to disk.
      let segmentFileWriter = segmentGenerator!
          .tryMap { segment in
              let segmentFileName = segment.fileName(forPrefix: config.segmentFileNamePrefix)
              let segmentFileURL = URL(fileURLWithPath: segmentFileName, isDirectory: false, relativeTo: url)

              print("writing \(segment.data.count) bytes to \(segmentFileName)")
              try segment.data.write(to: segmentFileURL)
          }

      // Write the index file to disk.
      let indexFileWriter = indexFileGenerator
          .tryMap { finalIndexFile in

              print("writing index file to \(config.indexFileName)")
              try finalIndexFile.write(to: indexFileURL, atomically: false, encoding: .utf8)
          }

      // Collect the results of segment and index file writing.
      segmentAndIndexFileWriter = segmentFileWriter.merge(with: indexFileWriter)
          .sink(receiveCompletion: { completion in
              // Evaluate the result.
              switch completion {
              case .finished:
                  assert(segmentAndIndexFileWriter != nil)
                  print("Finished writing segment data")
              case .failure(let error):
                  switch error {
                  case let localizedError as LocalizedError:
                      print("Error: \(localizedError.errorDescription ?? String(describing: localizedError))")
                  default:
                      print("Error: \(error)")
                  }
              }
          }, receiveValue: {})
    }
    
    let videoRecording = try assertedRecorder().makeVideoRecording(
      to: url,
      videoSettings: videoSettings,
      audioSettings: audioSettings,
      subject: segmentGenerator
    )
    videoRecording.url = segmentGenerator != nil ? indexFileURL : url
    videoRecording.resume()

    self.videoRecording = videoRecording
    return videoRecording
  }

  func finishVideoRecording(completionHandler handler: @escaping (VideoRecording.Info) -> Void) {
    videoRecording?.finish { videoRecordingInfo in
      DispatchQueue.main.async { handler(videoRecordingInfo) }
    }
    videoRecording = nil
  }

  func cancelVideoRecording() {
    videoRecording?.cancel()
    videoRecording = nil
  }

  func takePhoto(
    scale: CGFloat = UIScreen.main.scale,
    orientation: UIImage.Orientation = .up,
    completionHandler handler: @escaping (UIImage) -> Void
  ) {
    assertedRecorder().takePhoto(scale: scale, orientation: orientation) { photo in
      DispatchQueue.main.async { handler(photo) }
    }
  }
}
