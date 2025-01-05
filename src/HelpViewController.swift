import UIKit
import WebKit

class HelpViewController: UIViewController {
    @IBOutlet var webView: WKWebView!

    override func viewDidLoad() {
        let path = Bundle.main.path(forResource: "help", ofType: "html")!
        let url = URL(fileURLWithPath: path)
        webView.loadFileURL(url, allowingReadAccessTo: url)
    }
}
