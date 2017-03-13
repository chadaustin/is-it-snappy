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

class CaptureListViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

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
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    func tableView(_ tableView: UITableView, editActionsForRowAt indexPath: IndexPath) -> [UITableViewRowAction]? {
        let action = UITableViewRowAction(style: .destructive, title: "Delete") { action, indexPath in
            let model = self.groups[indexPath.section].videos[indexPath.row]
            try? PHPhotoLibrary.shared().performChangesAndWait {
                PHAssetChangeRequest.deleteAssets([model.asset] as NSArray)
            }
        }
        return [action]
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        precondition(Thread.isMainThread)
        let model = self.groups[indexPath.section].videos[indexPath.row]
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        let vc = storyboard.instantiateViewController(withIdentifier: "MarkViewController") as! MarkViewController
        vc.setModel(model)
        present(vc, animated: true) {
            tableView.deselectRow(at: indexPath, animated: true)
        }
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
        
        let mark = MarkDatabase.shared.get(localIdentifier: model.asset.localIdentifier) ?? Mark()
        
        newCell.textLabel?.text = mark.displayLabel()
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
