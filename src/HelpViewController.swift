import UIKit
import WebKit

class HelpViewController: UIViewController {
    let webView = WKWebView()

    override func loadView() {
        view = webView
    }

    override func viewWillAppear(_ animated: Bool) {
        let path = Bundle.main.path(forResource: "help", ofType: "html")!
        let url = URL(fileURLWithPath: path)
        webView.loadFileURL(url, allowingReadAccessTo: url)
    }
}
