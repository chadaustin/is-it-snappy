import UIKit

let homepageURL: URL = URL(string: "https://isitsnappy.com")!
let githubURL: URL = URL(string: "https://github.com/chadaustin/is-it-snappy")!
let twitterURL: URL = URL(string: "https://mastodon.gamedev.place/@chadaustin")!

class AboutViewController: UIViewController {
    @IBAction func handleBack() {
        dismiss(animated: true, completion: nil)
    }

    @IBAction func handleTapHomepage() {
        UIApplication.shared.open(homepageURL, options: [:], completionHandler: nil)
    }

    @IBAction func handleTapGitHub() {
        UIApplication.shared.open(githubURL, options: [:], completionHandler: nil)
    }

    @IBAction func handleTapTwitter() {
        UIApplication.shared.open(twitterURL, options: [:], completionHandler: nil)
    }
}
