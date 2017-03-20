import Foundation

func enumFromAny<T>(_ ctor: (Int) -> T?, _ v: Any?) -> T? {
    if let n = v as? NSNumber {
        return ctor(n.intValue)
    } else {
        return nil
    }
}
