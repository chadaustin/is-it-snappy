import UIKit
import AVFoundation

class CaptureVideoPreviewView: UIView {
    override open class var layerClass: AnyClass {
        return AVCaptureVideoPreviewLayer.self
    }

    override var layer: AVCaptureVideoPreviewLayer {
        return super.layer as! AVCaptureVideoPreviewLayer
    }

    var session: AVCaptureSession {
        get {
            return layer.session!
        }
        set {
            layer.session = newValue
        }
    }
}
