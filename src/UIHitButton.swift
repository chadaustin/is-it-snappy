import Foundation
import UIKit

class UIHitButton: UIButton {
    var hitInsets = UIEdgeInsets()
   
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        return
            point.x >= bounds.minX - hitInsets.left &&
            point.x <= bounds.maxX + hitInsets.right &&
            point.y >= bounds.minY - hitInsets.top &&
            point.y <= bounds.maxY + hitInsets.bottom
    }
}
