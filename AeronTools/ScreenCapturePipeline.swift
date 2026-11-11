import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreImage
import CoreGraphics
import AppKit

// MARK: - Real-Time ScreenCaptureKit JPEG Frame Pipeline

nonisolated final class ScreenCapturePipeline: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private(set) var targetDisplayID: CGDirectDisplayID
    private(set) var width: Int
    private(set) var height: Int
    private(set) var fps: Int

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.aeronlabs.idisplays.capture", qos: .userInteractive)
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false,
        .priorityRequestLow: false
    ])
    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()

    private let frameLock = NSLock()
    private var _jpegQuality: Double
    private var latestJPEGData: Data?
    private var latestCGImage: CGImage?
    private var frameCounter: UInt64 = 0
    private var lastFPSWindowStart: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var framesInWindow: Int = 0
    private(set) var measuredFPS: Double = 0
    private(set) var isCapturing: Bool = false

    /// Invoked immediately on `sampleQueue` whenever a new JPEG frame is encoded.
    var onEncodedFrame: (@Sendable (Data, UInt64) -> Void)?
    /// Returns `true` when the local macOS Settings window preview is visible and needs a `CGImage`.
    var shouldGeneratePreview: (@Sendable () -> Bool)?
    /// Invoked periodically (~0.75s) with telemetry and an optional downscaled preview `CGImage`.
    var onPreviewFrame: (@Sendable (CGImage?, Double, Int) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    var jpegQuality: Double {
        get {
            frameLock.lock()
            defer { frameLock.unlock() }
            return _jpegQuality
        }
        set {
            frameLock.lock()
            _jpegQuality = min(0.95, max(0.30, newValue))
            frameLock.unlock()
        }
    }

    init(
        targetDisplayID: CGDirectDisplayID,
        width: Int,
        height: Int,
        fps: Int,
        jpegQuality: Double
    ) {
        self.targetDisplayID = targetDisplayID
        self.width = width
        self.height = height
        self.fps = fps
        self._jpegQuality = min(0.95, max(0.30, jpegQuality))
        super.init()

        // Seed with an initial diagnostic test-pattern frame so browser clients immediately render
        // even before the first window movement or ScreenCaptureKit callback arrives.
        let initialPattern = Self.generateStandbyJPEG(width: width, height: height, displayID: targetDisplayID)
        self.latestJPEGData = initialPattern.jpeg
        self.latestCGImage = initialPattern.image
        self.frameCounter = 1
    }

    func latestFrame() -> (data: Data?, index: UInt64) {
        frameLock.lock()
        defer { frameLock.unlock() }
        return (latestJPEGData, frameCounter)
    }

    func start() async throws {
        // Virtual displays created via CGVirtualDisplay can take ~150-500ms to appear in SCShareableContent.
        var matchedDisplay: SCDisplay?
        for attempt in 1...12 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let exact = content.displays.first(where: { $0.displayID == targetDisplayID }) {
                matchedDisplay = exact
                break
            }
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 60_000_000)
        }

        guard let scDisplay = matchedDisplay else {
            throw NSError(
                domain: "ScreenCapturePipeline",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Display \(targetDisplayID) not found in SCShareableContent. Check Screen Recording permission."]
            )
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(10, min(60, fps))))
        // Hardware 4:2:0 bi-planar full-range YpCbCr cuts memory bandwidth by >60% vs 32BGRA
        // and feeds directly into hardware-accelerated JPEG compression.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.showsCursor = true
        config.queueDepth = 3

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await newStream.startCapture()

        self.stream = newStream
        self.isCapturing = true
    }

    func stop() async {
        isCapturing = false
        if let activeStream = stream {
            try? await activeStream.stopCapture()
        }
        stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        // Skip idle, blank, or suspended frames where WindowServer reports no screen changes.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let quality = self.jpegQuality

        guard let jpegData = ciContext.jpegRepresentation(
            of: ciImage,
            colorSpace: rgbColorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        ) else {
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        var shouldUpdateTelemetry = false
        var currentFPS: Double = 0
        let newIndex: UInt64

        frameLock.lock()
        latestJPEGData = jpegData
        frameCounter &+= 1
        newIndex = frameCounter
        framesInWindow += 1
        let elapsed = now - lastFPSWindowStart
        if elapsed >= 0.75 {
            measuredFPS = Double(framesInWindow) / elapsed
            currentFPS = measuredFPS
            framesInWindow = 0
            lastFPSWindowStart = now
            shouldUpdateTelemetry = true
        } else {
            currentFPS = measuredFPS
        }
        frameLock.unlock()

        // Wake any long-polling or MJPEG clients immediately without waiting for a poll timer.
        onEncodedFrame?(jpegData, newIndex)

        if shouldUpdateTelemetry {
            let byteCount = jpegData.count
            var previewCG: CGImage?
            if shouldGeneratePreview?() ?? false {
                let extent = ciImage.extent
                let maxPreviewWidth: CGFloat = 224.0
                let scaleFactor = extent.width > maxPreviewWidth ? (maxPreviewWidth / extent.width) : 1.0
                let thumbCI = scaleFactor < 1.0
                    ? ciImage.transformed(by: CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))
                    : ciImage
                previewCG = ciContext.createCGImage(thumbCI, from: thumbCI.extent)
                if let previewCG {
                    frameLock.lock()
                    latestCGImage = previewCG
                    frameLock.unlock()
                }
            }
            onPreviewFrame?(previewCG, currentFPS, byteCount)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isCapturing = false
        onError?(error.localizedDescription)
    }

    // MARK: - Standby / Diagnostic Frame Generator

    static func generateStandbyJPEG(
        width: Int,
        height: Int,
        displayID: CGDirectDisplayID
    ) -> (jpeg: Data?, image: CGImage?) {
        let w = max(640, min(1920, width))
        let h = max(400, min(1200, height))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return (nil, nil)
        }

        // Deep slate background
        ctx.setFillColor(CGColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Subtle alignment grid for Tesla / iPad viewport verification
        ctx.setStrokeColor(CGColor(red: 0.16, green: 0.22, blue: 0.32, alpha: 0.55))
        ctx.setLineWidth(1.0)
        let step = 80
        for x in stride(from: 0, to: w, by: step) {
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: h))
        }
        for y in stride(from: 0, to: h, by: step) {
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: w, y: y))
        }
        ctx.strokePath()

        // Border accent frame
        ctx.setStrokeColor(CGColor(red: 0.20, green: 0.58, blue: 0.98, alpha: 0.85))
        ctx.setLineWidth(4.0)
        ctx.stroke(CGRect(x: 12, y: 12, width: w - 24, height: h - 24))

        guard let cgImage = ctx.makeImage() else { return (nil, nil) }
        let ciImg = CIImage(cgImage: cgImage)
        let ciCtx = CIContext()
        let jpeg = ciCtx.jpegRepresentation(
            of: ciImg,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]
        )
        return (jpeg, cgImage)
    }
}
