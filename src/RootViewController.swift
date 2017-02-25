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
    
    var groups: [VideoManager.VideoGroup] {
        return videoManager.groupedVideos
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
    
    func tableView(_ tableView: UITableView, editActionsForRowAt indexPath: IndexPath) -> [UITableViewRowAction]? {
        let action = UITableViewRowAction(style: .destructive, title: "Edit") { action, indexPath in
            // push the edit dialog
        }
        return [action]
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let model = self.groups[indexPath.section].videos[indexPath.row]
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        let vc = storyboard.instantiateViewController(withIdentifier: "ScrubberViewController") as! ScrubberViewController
        vc.setModel(model)
        present(vc, animated: true, completion: nil)
        //present(ScrubberViewController(model: model), animated: true, completion: nil)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // TODO: reuse cells?
        //tableView.dequeueReusableCell(withIdentifier: "identifier")

        let model = groups[indexPath.section].videos[indexPath.row]
        
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .short

        let newCell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        newCell.textLabel?.text = "--"
        newCell.detailTextLabel?.text = "\(df.string(from: model.asset.creationDate!))"
        return newCell
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        return groups.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return groups[section].videos.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .none
        return "\(df.string(from: groups[section].date))"
    }
}
