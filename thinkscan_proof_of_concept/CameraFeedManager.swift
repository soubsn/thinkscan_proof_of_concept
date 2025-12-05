//
//  CameraFeedManager.swift
//  ThinkScan Video Processor
//
//  Created on 2025-12-03.
//

import Foundation
import AVFoundation
import AppKit

protocol CameraFeedManagerDelegate: AnyObject {
    /// Delivers the pixel buffer from the camera feed
    func didReceiveCameraBuffer(_ pixelBuffer: CVPixelBuffer?)
    /// Delivers the original unpadded pixel buffer for saving/annotation
    func didReceiveOriginalCameraBuffer(_ originalPixelBuffer: CVPixelBuffer?)
    func didEncounterCameraError(_ error: String)
    func didStartCamera()
    func didStopCamera()
}

class CameraFeedManager: NSObject {
    private let sessionQueue = DispatchQueue(label: "org.thinkscan.thinkscan_proof_of_concept.cameraqueue")
    weak var delegate: CameraFeedManagerDelegate?
    
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    var isRunning: Bool {
        return captureSession?.isRunning ?? false
    }
    
    var frameCount: Int64 = 0
    
    override init() {
        super.init()
    }
    
    deinit {
        stopCamera()
    }
    
    // MARK: - Camera Setup
    // Note: setupCameraSync() is defined inline with startCameraSession() below
    
    // MARK: - Camera Control
    
    func startCamera() {
        // Check authorization status first
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        
        switch authStatus {
        case .notDetermined:
            // Request permission
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.startCameraSession()
                } else {
                    DispatchQueue.main.async {
                        self?.delegate?.didEncounterCameraError("Camera access denied. Please grant permission in System Settings.")
                    }
                }
            }
        case .restricted, .denied:
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didEncounterCameraError("Camera access is restricted or denied. Please grant permission in System Settings > Privacy & Security > Camera.")
            }
        case .authorized:
            startCameraSession()
        @unknown default:
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didEncounterCameraError("Unknown camera authorization status")
            }
        }
    }
    
    private func startCameraSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Setup camera synchronously on the sessionQueue if needed
            if self.captureSession == nil {
                self.setupCameraSync()
            }
            
            guard let session = self.captureSession else {
                DispatchQueue.main.async {
                    self.delegate?.didEncounterCameraError("Capture session not initialized")
                }
                return
            }
            
            if !session.isRunning {
                self.frameCount = 0
                session.startRunning()
                DispatchQueue.main.async {
                    self.delegate?.didStartCamera()
                }
                print("Camera started successfully")
            }
        }
    }
    
    // Synchronous setup that must be called on sessionQueue
    private func setupCameraSync() {
        let session = AVCaptureSession()
        session.beginConfiguration()
        
        // Set session preset for high quality
        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        
        // Get default video device (built-in camera)
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        
        guard let videoDevice = discoverySession.devices.first else {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.delegate?.didEncounterCameraError("No camera device found")
            }
            return
        }
        
        // Configure device for optimal settings
        do {
            try videoDevice.lockForConfiguration()
            
            // Set a specific format if needed to avoid compatibility issues
            if let format = videoDevice.formats.first(where: { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dimensions.width == 1280 && dimensions.height == 720
            }) {
                videoDevice.activeFormat = format
            }
            
            videoDevice.unlockForConfiguration()
        } catch {
            print("Warning: Could not configure device settings: \(error.localizedDescription)")
            // Continue anyway - this is not critical
        }
        
        // Create input from device
        do {
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            } else {
                session.commitConfiguration()
                DispatchQueue.main.async {
                    self.delegate?.didEncounterCameraError("Could not add video input to session")
                }
                return
            }
        } catch {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.delegate?.didEncounterCameraError("Could not create video input: \(error.localizedDescription)")
            }
            return
        }
        
        // Create video output
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: self.sessionQueue)
        
        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.delegate?.didEncounterCameraError("Could not add video output to session")
            }
            return
        }
        
        session.commitConfiguration()
        
        self.captureSession = session
        self.videoOutput = output
    }
    
    func stopCamera() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            if let session = self.captureSession, session.isRunning {
                session.stopRunning()
                DispatchQueue.main.async {
                    self.delegate?.didStopCamera()
                }
                print("Camera stopped. Total frames processed: \(self.frameCount)")
            }
        }
    }
    
    // MARK: - Preview Layer
    
    func createPreviewLayer() -> AVCaptureVideoPreviewLayer? {
        guard let session = captureSession else { return nil }
        
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        self.previewLayer = layer
        
        return layer
    }
    
    // MARK: - Pixel Buffer Processing
    
    private func processPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        // Get the dimensions of the input pixel buffer
        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        
        // Determine square canvas size (max of width/height)
        let side = max(srcWidth, srcHeight)
        
        // If already square, return the original
        if srcWidth == srcHeight {
            return pixelBuffer
        }
        
        // Compute padding values
        let padLeft = (side - srcWidth) / 2
        let padRight = side - srcWidth - padLeft
        let padTop = (side - srcHeight) / 2
        let padBottom = side - srcHeight - padTop
        
        // Create a CVPixelBuffer for the square canvas
        let attrs: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!
        ] as CFDictionary
        
        var pxbuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, attrs, &pxbuffer) == kCVReturnSuccess,
              let outputBuffer = pxbuffer else {
            print("Could not allocate output CVPixelBuffer.")
            return nil
        }
        
        let cvLockFlag = CVPixelBufferLockFlags(rawValue: 0)
        
        // Lock both buffers
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            print("error: could not lock input pixel buffer")
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        guard CVPixelBufferLockBaseAddress(outputBuffer, cvLockFlag) == kCVReturnSuccess else {
            print("error: could not lock output pixel buffer")
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(outputBuffer, cvLockFlag) }
        
        guard let outputBaseAddress = CVPixelBufferGetBaseAddress(outputBuffer) else {
            print("error: could not get base address for output pixel buffer")
            return nil
        }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)
        
        // Create color space and bitmap info
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        
        // Create a CGContext backed by the output pixel buffer
        guard let context = CGContext(data: outputBaseAddress,
                                      width: side,
                                      height: side,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo) else {
            print("error: Could not create a new context")
            return nil
        }
        
        // Fill with padding color (114,114,114) in sRGB
        let pad: CGFloat = 114.0 / 255.0
        context.setFillColor(red: pad, green: pad, blue: pad, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        
        // Create CGImage from input pixel buffer
        guard let inputImage = createCGImage(from: pixelBuffer) else {
            print("error: Could not create CGImage from input pixel buffer")
            return nil
        }
        
        // Draw the input image centered on the square canvas
        let drawX = padLeft
        let drawY = padTop
        context.draw(inputImage, in: CGRect(x: drawX, y: drawY, width: srcWidth, height: srcHeight))
        
        // Attach padding and size metadata
        let paddingInfo: NSDictionary = [
            "padLeft": padLeft,
            "padRight": padRight,
            "padTop": padTop,
            "padBottom": padBottom,
            "srcWidth": srcWidth,
            "srcHeight": srcHeight,
            "side": side
        ]
        CVBufferSetAttachment(outputBuffer, "com.ymedialabs.padding" as CFString, paddingInfo, .shouldPropagate)
        CVBufferSetAttachment(outputBuffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        
        return outputBuffer
    }
    
    private func createCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return cgImage
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraFeedManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("error: could not get pixel buffer from sample buffer")
            return
        }
        
        frameCount += 1
        
        // Keep original (un-padded) buffer for saving
        let originalBuffer = pixelBuffer
        
        // Process the pixel buffer (add padding to make it square)
        let processedBuffer = processPixelBuffer(pixelBuffer)
        
        // Deliver both buffers to delegate on the main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.didReceiveOriginalCameraBuffer(originalBuffer)
            self.delegate?.didReceiveCameraBuffer(processedBuffer)
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        print("Dropped frame")
    }
}
