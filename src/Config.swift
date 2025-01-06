import Foundation

/// When true, does not require the real camera (not available in simulator) and
/// VideoManager returns fake data.
#if targetEnvironment(simulator)
let screenshotMode = true
#else
let screenshotMode = false
#endif

// TODO: switch to a uuid / local identifier
// The problem with that is we'd have to store the local identifier after running, which would get discarded
// when reinstalling the app.  So displayname is perhaps the best key for the album.  :/
let appName: String = Bundle.main.infoDictionary?["CFBundleDisplayName"]! as! String

let screenshotScaleAspectFill: Bool = true
