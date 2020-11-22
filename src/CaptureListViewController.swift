import UIKit
import Photos

class MyTableViewCell: UITableViewCell {
    var label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
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
        infoButton.tintColor = .label
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
                MarkDatabase.shared.delete(localIdentifier: model.uniqueID)
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

            let sourceView = tableView.cellForRow(at: indexPath) ?? tableView
            ac.popoverPresentationController?.permittedArrowDirections = .right
            ac.popoverPresentationController?.sourceView = sourceView
            ac.popoverPresentationController?.sourceRect = CGRect(x: sourceView.bounds.width, y: 0, width: 0, height: sourceView.bounds.height)
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
        let localIdentifier = model.uniqueID
        let phModel = model as! PHVideoModel
        try? PHPhotoLibrary.shared().performChangesAndWait {
            PHAssetChangeRequest.deleteAssets([phModel.asset] as NSArray)
        }
        MarkDatabase.shared.delete(localIdentifier: localIdentifier)
    }

    @IBAction
    func didClickCapture(_ sender: AnyObject?) {
        func showSettingsAlert(permission: String) {
            precondition(Thread.isMainThread)
            let ac = UIAlertController(title: "Requires \(permission) access", message: "Give \"\(appName)\" access to \(permission) in Settings", preferredStyle: .alert)
            ac.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
            ac.addAction(UIAlertAction(title: "Settings", style: .default) { action in
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            })
            self.present(ac, animated: true, completion: nil)
        }

        // Prevent double-taps.
        captureButton.isEnabled = false
        PHPhotoLibrary.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .notDetermined, .restricted, .denied:
                    self?.captureButton.isEnabled = true
                    showSettingsAlert(permission: "Photos")
                case .authorized:
                    fallthrough
                @unknown default:
                    AVCaptureDevice.requestAccess(for: AVMediaType.video) { granted in
                        DispatchQueue.main.async {
                            self?.captureButton.isEnabled = true
                            if !granted {
                                showSettingsAlert(permission: "Camera")
                            } else {
                                let storyboard = UIStoryboard(name: "Main", bundle: nil)
                                let vc = storyboard.instantiateViewController(withIdentifier: "CaptureViewController") as! CaptureViewController
                                vc.modalPresentationStyle = .overCurrentContext
                                self?.present(vc, animated: true, completion: nil)
                            }
                        }
                    }
                }
            }
        }
    }

    func presentMarkViewController(for model: VideoModel, completion: @escaping () -> Void) {
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        let vc = storyboard.instantiateViewController(withIdentifier: "MarkViewController") as! MarkViewController
        vc.setModel(model)
        vc.modalPresentationStyle = .overCurrentContext
        vc.didDismiss = { [weak self] in
            self?.tableView.reloadData()
        }
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
        
        let mark = MarkDatabase.shared.get(localIdentifier: model.uniqueID) ?? Mark()
        
        newCell.textLabel?.text = mark.displayLabel()
        newCell.detailTextLabel?.text = "\(df.string(from: model.creationDate!))"
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
