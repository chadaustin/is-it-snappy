import AVFoundation
import UIKit

extension AVCaptureVideoOrientation {
    var interfaceOrientation: UIInterfaceOrientation {
        get {
            switch self {
            case .landscapeLeft: return .landscapeLeft
            case .landscapeRight: return .landscapeRight
            case .portrait: return .portrait
            case .portraitUpsideDown: return .portraitUpsideDown
            @unknown default: return .portrait
            }
        }
    }

    init(interfaceOrientation: UIInterfaceOrientation) {
        switch interfaceOrientation {
        case .landscapeRight: self = .landscapeRight
        case .landscapeLeft: self = .landscapeLeft
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        default: self = .portrait
        }
    }

    init?(deviceOrientation: UIDeviceOrientation) {
        switch deviceOrientation {
        case .landscapeRight:       self = .landscapeLeft
        case .landscapeLeft:        self = .landscapeRight
        case .portrait:             self = .portrait
        case .portraitUpsideDown:   self = .portraitUpsideDown
        default:
            return nil
        }
    }
}

extension AVCaptureDevice.Format {
    var maxSupportedFrameRate: Double {
        var m: Double = 0
        for range in self.videoSupportedFrameRateRanges {
            if range.maxFrameRate > m {
                m = range.maxFrameRate
            }
        }
        return m
    }
}

extension AVCaptureDevice {
    func setBestFormat() {
        let videoDevice = self
        var formats = videoDevice.formats 
        func formatPriority(_ format: AVCaptureDevice.Format) -> Int {
            // frame rate is the most important factor
            // full vs. video dynamic range is the second
            let isFull = CMFormatDescriptionGetMediaSubType(format.formatDescription) & 0xFF == 102 // f
            // pack the sort key into an int because Swift doesn't have tuple comparison yet
            return Int(format.maxSupportedFrameRate) * 2 + (isFull ? 1 : 0)
        }
        formats.sort(by: { formatPriority($0) > formatPriority($1) })
        if let first = formats.first {
            if first.maxSupportedFrameRate > 60 {
                do {
                    try videoDevice.lockForConfiguration()
                    videoDevice.activeFormat = first
                    videoDevice.unlockForConfiguration()
                }
                catch let error {
                    NSLog("Could not set active format: \(error)")
                }
            }
        }
    }
}
