import UIKit
import AVFoundation

class PlayerView: UIView {
    override open class var layerClass: AnyClass {
        return AVPlayerLayer.self
    }
    
    override var layer: AVPlayerLayer {
        return super.layer as! AVPlayerLayer
    }
    
    var player: AVPlayer? {
        get {
            return layer.player
        }
        set {
            layer.player = newValue
        }
    }
}
