import UIKit

let homepageURL: URL = URL(string: "https://isitsnappy.com")!
let githubURL: URL = URL(string: "https://github.com/chadaustin/is-it-snappy")!
let twitterURL: URL = URL(string: "https://mastodon.gamedev.place/@chadaustin")!

class AboutViewController: UIViewController {
    @IBAction func handleBack() {
        dismiss(animated: true, completion: nil)
    }

    @IBAction func handleTapHomepage() {
        UIApplication.shared.open(homepageURL, options: convertToUIApplicationOpenExternalURLOptionsKeyDictionary([:]), completionHandler: nil)
    }

    @IBAction func handleTapGitHub() {
        UIApplication.shared.open(githubURL, options: convertToUIApplicationOpenExternalURLOptionsKeyDictionary([:]), completionHandler: nil)
    }

    @IBAction func handleTapTwitter() {
        UIApplication.shared.open(twitterURL, options: convertToUIApplicationOpenExternalURLOptionsKeyDictionary([:]), completionHandler: nil)
    }
}

// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertToUIApplicationOpenExternalURLOptionsKeyDictionary(_ input: [String: Any]) -> [UIApplication.OpenExternalURLOptionsKey: Any] {
	return Dictionary(uniqueKeysWithValues: input.map { key, value in (UIApplication.OpenExternalURLOptionsKey(rawValue: key), value)})
}
