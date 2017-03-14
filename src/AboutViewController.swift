import UIKit

let githubURL: URL = URL(string: "https://github.com/chadaustin/is-it-snappy")!
let twitterURL: URL = URL(string: "https://twitter.com/chadaustin")!

class AboutViewController: UIViewController {
    @IBAction func handleBack() {
        dismiss(animated: true, completion: nil)
    }

    @IBAction func handleTapGitHub() {
        UIApplication.shared.open(githubURL, options: [:], completionHandler: nil)
    }

    @IBAction func handleTapTwitter() {
        UIApplication.shared.open(twitterURL, options: [:], completionHandler: nil)
    }
}
