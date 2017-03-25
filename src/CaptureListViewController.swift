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
    @IBOutlet var captureButton: UIBarButtonItem!

    static weak var live: CaptureListViewController?

    let videoManager = VideoManager.shared
    
    var groups: [VideoManager.VideoGroup] {
        return videoManager.groupedVideos
    }

    override func viewDidLoad() {
        tableView.isUserInteractionEnabled = true

        super.viewDidLoad()
        tableView.dataSource = self
        tableView.delegate = self

        let infoButton = UIButton(type: .infoLight)
        infoButton.tintColor = .black
        infoButton.addTarget(self, action: #selector(handleInfoButtonTap), for: .primaryActionTriggered)
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: infoButton)
        
        _ = videoManager.register {
            self.tableView.reloadData()
        }

        CaptureListViewController.live = self
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    @objc func handleInfoButtonTap() {
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        let vc = storyboard.instantiateViewController(withIdentifier: "AboutViewController")
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    func tableView(_ tableView: UITableView, editActionsForRowAt indexPath: IndexPath) -> [UITableViewRowAction]? {
        let action = UITableViewRowAction(style: .destructive, title: "Delete") { [weak self] action, indexPath in
            guard let ss = self else { return }
            let model = ss.groups[indexPath.section].videos[indexPath.row]
            let ac = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
            ac.addAction(UIAlertAction(title: "Clear Marks", style: .destructive) { action in
                MarkDatabase.shared.delete(localIdentifier: model.asset.localIdentifier)
                tableView.setEditing(false, animated: true)
                tableView.reloadData()
            })
            ac.addAction(UIAlertAction(title: "Delete Video & Marks", style: .destructive) { action in
                guard let ss = self else { return }
                ss.deleteVideoAndMark(model)
                tableView.setEditing(false, animated: true)
            })
            ac.addAction(UIAlertAction(title: "Cancel", style: .cancel) { action in
                tableView.setEditing(false, animated: true)
            })

            ss.present(ac, animated: true, completion: nil)
        }
        return [action]
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        precondition(Thread.isMainThread)
        let model = self.groups[indexPath.section].videos[indexPath.row]
        presentMarkViewController(for: model) {
            tableView.deselectRow(at: indexPath, animated: true)
        }
    }

    func deleteVideoAndMark(_ model: VideoModel) {
        let localIdentifier = model.asset.localIdentifier
        try? PHPhotoLibrary.shared().performChangesAndWait {
            PHAssetChangeRequest.deleteAssets([model.asset] as NSArray)
        }
        MarkDatabase.shared.delete(localIdentifier: localIdentifier)
    }

    @IBAction
    func didClickCapture(_ sender: AnyObject?) {
        // Prevent double-taps.
        captureButton.isEnabled = false
        PHPhotoLibrary.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.captureButton.isEnabled = true
                switch status {
                case .notDetermined, .restricted, .denied:
                    let ac = UIAlertController(title: "Requires Photos access", message: "Give \"\(appName)\" access to Photos in Settings", preferredStyle: .alert)
                    ac.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
                    ac.addAction(UIAlertAction(title: "Settings", style: .default) { action in
                        UIApplication.shared.open(URL(string: UIApplicationOpenSettingsURLString)!)
                    })
                    self?.present(ac, animated: true, completion: nil)
                case .authorized:
                    let storyboard = UIStoryboard(name: "Main", bundle: nil)
                    let vc = storyboard.instantiateViewController(withIdentifier: "CaptureViewController") as! CaptureViewController
                    self?.present(vc, animated: true, completion: nil)
                }
            }
        }
    }

    func presentMarkViewController(for model: VideoModel, completion: @escaping () -> Void) {
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        let vc = storyboard.instantiateViewController(withIdentifier: "MarkViewController") as! MarkViewController
        vc.setModel(model)
        present(vc, animated: true, completion: completion)
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
