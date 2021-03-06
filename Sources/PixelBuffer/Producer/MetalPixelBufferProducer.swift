//
//  MetalPixelBufferProducer.swift
//  SCNRecorder
//
//  Created by Vladislav Grigoryev on 11/03/2019.
//  Copyright © 2020 GORA Studio. https://gora.studio
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
import AVFoundation

#if !targetEnvironment(simulator)

final class MetalPixelBufferProducer {

  enum Error: Swift.Error {

    case noSurface
  }

  var size: CGSize { recordableLayer.drawableSize }

  var videoColorProperties: [String: String]? { recordableLayer.pixelFormat.videoColorProperties }

  var recommendedPixelBufferAttributes: [String: Any] {
    var attributes: [String: Any] = [
      kCVPixelBufferWidthKey as String: Int(recordableLayer.drawableSize.width),
      kCVPixelBufferHeightKey as String: Int(recordableLayer.drawableSize.height),
      kCVPixelBufferPixelFormatTypeKey as String: recordableLayer.pixelFormat.pixelFormatType,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]

    if let iccData = recordableLayer.pixelFormat.iccData {
      attributes[kCVBufferPropagatedAttachmentsKey as String] = [
        kCVImageBufferICCProfileKey: iccData
      ]
    }

    return attributes
  }

  let recordableLayer: RecordableLayer

  let queue: DispatchQueue

  lazy var context = CIContext(mtlDevice: recordableLayer.device ?? MTLCreateSystemDefaultDevice()!)

  init(recordableLayer: RecordableLayer, queue: DispatchQueue) {
    self.recordableLayer = recordableLayer
    self.queue = queue
  }

  func produce(handler: @escaping (CVPixelBuffer) -> Void) throws {
    guard let surface = recordableLayer.lastIOSurface else { throw Error.noSurface }

    queue.async { [recommendedPixelBufferAttributes] in
      var unmanagedPixelBuffer: Unmanaged<CVPixelBuffer>?
      CVPixelBufferCreateWithIOSurface(
        nil,
        surface,
        recommendedPixelBufferAttributes as CFDictionary,
        &unmanagedPixelBuffer
      )

      guard let pixelBuffer = unmanagedPixelBuffer?.takeUnretainedValue() else { return }
      handler(pixelBuffer)
    }
  }
}

#endif // !targetEnvironment(simulator)
