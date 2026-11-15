import UIKit
import AVKit
import AVFoundation

enum PiPTheme: String, CaseIterable {
    case classicDark = "经典黑底白字"
    case neonGreen = "黑底荧光绿"
    case sakuraPink = "深灰底樱花粉"
    case deepBlue = "深海蓝底金字"
    
    var bgColor: UIColor {
        switch self {
        case .classicDark, .neonGreen: return UIColor(white: 0.05, alpha: 0.92)
        case .sakuraPink: return UIColor(red: 0.15, green: 0.12, blue: 0.16, alpha: 0.95)
        case .deepBlue: return UIColor(red: 0.05, green: 0.10, blue: 0.22, alpha: 0.95)
        }
    }
    
    var textColor: UIColor {
        switch self {
        case .classicDark: return .white
        case .neonGreen: return UIColor(red: 0.2, green: 1.0, blue: 0.4, alpha: 1.0)
        case .sakuraPink: return UIColor(red: 1.0, green: 0.72, blue: 0.82, alpha: 1.0)
        case .deepBlue: return UIColor(red: 1.0, green: 0.88, blue: 0.4, alpha: 1.0)
        }
    }
}

class PiPSubtitleManager: NSObject, ObservableObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    static let shared = PiPSubtitleManager()
    
    @Published var isPiPActive = false
    
    let displayLayer = AVSampleBufferDisplayLayer()
    private var pipController: AVPictureInPictureController?
    private var refreshTimer: Timer?
    
    private var currentOriginal: String = "等待语音输入..."
    private var currentTranslated: String = "启动引擎后，点击开启画中画即可悬浮显示字幕"
    
    var fontSize: CGFloat = 36.0
    var showBilingual: Bool = true
    var theme: PiPTheme = .classicDark

    func setupPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        if pipController != nil { return }
        
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
        
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        pipController = AVPictureInPictureController(contentSource: contentSource)
        pipController?.delegate = self
        if #available(iOS 14.2, *) {
            pipController?.canStartPictureInPictureAutomaticallyFromInline = true
        }
        
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.renderCurrentFrame()
        }
        renderCurrentFrame()
    }

    func togglePiP() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else {
            pip.startPictureInPicture()
        }
    }

    func updateSubtitle(original: String, translated: String) {
        if !original.isEmpty { self.currentOriginal = original }
        if !translated.isEmpty { self.currentTranslated = translated }
        renderCurrentFrame()
    }

    func renderCurrentFrame() {
        let size = CGSize(width: 880, height: 210)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        let image = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            theme.bgColor.setFill()
            ctx.fill(rect)
            
            let borderPath = UIBezierPath(rect: rect.insetBy(dx: 2, dy: 2))
            borderPath.lineWidth = 3
            theme.textColor.withAlphaComponent(0.3).setStroke()
            borderPath.stroke()
            
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            paragraphStyle.lineBreakMode = .byTruncatingHead
            
            if showBilingual {
                let origAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: max(20, fontSize * 0.58), weight: .medium),
                    .foregroundColor: UIColor.lightGray,
                    .paragraphStyle: paragraphStyle
                ]
                let origRect = CGRect(x: 28, y: 18, width: size.width - 56, height: 42)
                currentOriginal.draw(in: origRect, withAttributes: origAttrs)
                
                let transParagraph = NSMutableParagraphStyle()
                transParagraph.alignment = .center
                transParagraph.lineBreakMode = .byWordWrapping
                
                let transAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                    .foregroundColor: theme.textColor,
                    .paragraphStyle: transParagraph
                ]
                let transRect = CGRect(x: 28, y: 66, width: size.width - 56, height: size.height - 78)
                currentTranslated.draw(in: transRect, withAttributes: transAttrs)
            } else {
                let transParagraph = NSMutableParagraphStyle()
                transParagraph.alignment = .center
                transParagraph.lineBreakMode = .byWordWrapping
                
                let transAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: fontSize + 4, weight: .bold),
                    .foregroundColor: theme.textColor,
                    .paragraphStyle: transParagraph
                ]
                let transRect = CGRect(x: 28, y: 32, width: size.width - 56, height: size.height - 64)
                currentTranslated.draw(in: transRect, withAttributes: transAttrs)
            }
        }
        
        if let sampleBuffer = createSampleBuffer(from: image) {
            if displayLayer.status == .failed { displayLayer.flush() }
            displayLayer.enqueue(sampleBuffer)
        }
    }
    
    private func createSampleBuffer(from image: UIImage) -> CMSampleBuffer? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        guard let buffer = pixelBuffer else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        )
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        
        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &formatDesc)
        guard let format = formatDesc else { return nil }
        
        var timing = CMSampleTimingInfo(
            duration: CMTimeMake(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        if let sbuf = sampleBuffer,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async { self.isPiPActive = true }
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async { self.isPiPActive = false }
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { return false }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) { completionHandler() }
}
    
