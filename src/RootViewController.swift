import UIKit
import Photos

class MyTableViewCell: UITableViewCell {
    var label = UILabel()

    override init(style: UITableViewCellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(label)

        label.text = "Captured"
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var textLabel: UILabel? {
        return label
    }
}

class VideoModel {
    let asset: PHAsset

    init(asset: PHAsset) {
        self.asset = asset
    }
}

class RootViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    @IBOutlet var stackView: UIStackView!
    @IBOutlet var tableView: UITableView!

    let videoManager = VideoManager.shared
    
    var videos: [VideoModel] {
        return videoManager.videos
    }

    override func viewDidLoad() {
        tableView.isUserInteractionEnabled = true

        super.viewDidLoad()
        tableView.dataSource = self
        tableView.delegate = self
        
        _ = videoManager.register {
            self.tableView.reloadData()
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let model = self.videos[indexPath.row]
        present(ScrubberViewController(model: model), animated: true, completion: nil)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        tableView.dequeueReusableCell(withIdentifier: "identifier")

        let model = self.videos[indexPath.row]

        let newCell = UITableViewCell()
        newCell.textLabel?.text = "\(model.asset.creationDate!)"
        return newCell
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return videos.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return "Captures for a day 2"
    }
}
