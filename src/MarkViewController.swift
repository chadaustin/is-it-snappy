import UIKit
import Photos

class PlayerInfo {
    init(sourceAsset: AVAsset) {
        videoAsset = PlayerInfo.getInnerAsset(sourceAsset)

        // TODO: check that the videoAsset has a video track
        let track = videoAsset.tracks[0]

        Swift.print("nominalFrameRate: \(track.nominalFrameRate)")
        Swift.print("minFrameDuration: \(track.minFrameDuration.seconds)")
        Swift.print("minFrameRate: \(1.0 / track.minFrameDuration.seconds)")

        playerItem = AVPlayerItem(asset: videoAsset)
        player = AVPlayer(playerItem: playerItem)

        nominalFrameRate = track.nominalFrameRate
    }

    let videoAsset: AVAsset
    let playerItem: AVPlayerItem
    let player: AVPlayer
    let nominalFrameRate: Float

    static func getInnerAsset(_ sourceAsset: AVAsset) -> AVAsset {
        if let urlAsset = sourceAsset as? AVURLAsset {
            return urlAsset
        } else if let composition = sourceAsset as? AVComposition {
            // Bypass the composition's frame rate ramp.
            // TODO: check for video track and segment and source URL
            let track = composition.tracks.first(where: { $0.mediaType == AVMediaTypeVideo })!
            return AVURLAsset(
                url: track.segments[0].sourceURL!,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: "true"])

        } else {
            return sourceAsset
        }
    }
}

class MarkViewController: UIViewController, UITextFieldDelegate {
    enum State {
        case loading
        case failed
        case idle
        case seeking(to: CMTime)
        case seekingWithPendingSeek(to: CMTime)
    }

    var state = State.loading

    var model: VideoModel!
    var playerInfo: PlayerInfo!

    var playerView: PlayerView {
        return view as! PlayerView
    }

    @IBOutlet var captureNameField: UITextField!
    @IBOutlet var markInputButton: UIButton!
    @IBOutlet var markOutputButton: UIButton!
    @IBOutlet var locationLabel: UILabel!
    
    let gestureRecognizer = UIPanGestureRecognizer()
   
    func setModel(_ model: VideoModel) {
        precondition(self.model == nil, "model can only be set once")
        self.model = model
        
        let options: PHVideoRequestOptions? = nil
        PHImageManager.default().requestAVAsset(
            forVideo: model.asset,
            options: options
        ) { [weak self] sourceAsset, audioMix, info in
            DispatchQueue.main.async {
                guard let ss = self else {
                    return
                }

                guard let sourceAsset = sourceAsset else {
                    fatalError("failed to load? show an error?")
                }

                ss.playerInfo = PlayerInfo(sourceAsset: sourceAsset)

                ss.playerView.player = ss.playerInfo.player
                ss.state = .idle
                ss.updateLabel()
            }
        }
    }

    override func viewDidLoad() {
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addGestureRecognizer(gestureRecognizer)

        captureNameField.delegate = self
        
        gestureRecognizer.addTarget(self, action: #selector(handleGesture))

        setNeedsStatusBarAppearanceUpdate()
        
        updateCaptureName()
    }
    
    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        textField.text = getMark()?.name
        return true
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField.isFirstResponder {
            textField.resignFirstResponder()
            MarkDatabase.shared.setName(localIdentifier: model.asset.localIdentifier, name: textField.text ?? "")
        }
        updateCaptureName()
        return false
    }
    
    func updateCaptureName() {
        let mark = getMark()
        let extra: String
        if let input = mark?.input, let output = mark?.output {
            extra = String(format: "%.1f", (output - input) * 1000.0)
        } else {
            extra = ""
        }
        captureNameField.text = "\(mark?.name ?? "[name]") -- \(extra)"
    }
   
    func getMark() -> Mark? {
        return MarkDatabase.shared.get(localIdentifier: model.asset.localIdentifier)
    }

    @IBAction
    func pressDone(_ sender: UIButton?) {
        dismissKeyboard()
        dismiss(animated: true)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
    
    var gestureStartTime: CMTime = kCMTimeZero

    static func formatTime(_ time: CMTime) -> String {
        return String(format: "%.1f", time.seconds * 1000.0)
    }
    
    func dismissKeyboard() {
        _ = textFieldShouldReturn(captureNameField)
    }

    func handleGesture() {
        guard let player = playerView.player else {
            return
        }

        dismissKeyboard()

        if gestureRecognizer.state == .began {
            gestureStartTime = player.currentTime()
        }

        func applyCurve(_ x: Double) -> Double {
            // at offset x, scrub velocity f(x) in seconds/point
            // iPhone = 320 points wide
            // f(x) = k * x^2
            // f'(x) = 2 * k * x
            //
            // f’(10) = 1/240
            // 1/240 = 2 * k * 10
            // k = (1/240)/20
            // k = 1/4800

            let k = 1 / 48000.0
            return (x < 0 ? -1 : 1) * k * pow(abs(x), 2.1)
        }

        var x = Double(-gestureRecognizer.translation(in: view).x)
        Swift.print("before: \(x) after: \(applyCurve(x))")
        x = applyCurve(x)

        let minimum = kCMTimeZero
        let maximum = player.currentItem!.duration

        let target = min(maximum, max(minimum, gestureStartTime + CMTimeMakeWithSeconds(x, 240*100)))

        switch state {
        case .loading, .failed:
            break
        case .idle:
            seek(to: target)
        case .seeking(to: let time):
            state = .seekingWithPendingSeek(to: time)
        case .seekingWithPendingSeek(to: _):
            state = .seekingWithPendingSeek(to: target)
        }
    }

    func seek(to target: CMTime) {
        guard let player = playerView.player else {
            return
        }

        state = .seeking(to: target)
        player.seek(
            to: target,
            toleranceBefore: kCMTimeZero,
            toleranceAfter: kCMTimeZero
        ) { [weak self] finished in
            guard let ss = self else {
                return
            }

            precondition(finished, "seeks always succeed right?")

            switch ss.state {
            case .seeking:
                ss.state = .idle
            case .seekingWithPendingSeek(to: let newTarget):
                ss.seek(to: newTarget)
            default:
                fatalError("Unexpected transition")
            }

            ss.updateLabel()
        }
    }

    @IBAction
    func handleMarkStartTime(_ sender: AnyObject?) {
        MarkDatabase.shared.setInputTime(
            localIdentifier: model.asset.localIdentifier,
            input: playerInfo.player.currentTime().seconds)
        updateCaptureName()
        updateLabel()
    }
    
    @IBAction
    func handleMarkEndTime(_ sender: AnyObject?) {
        MarkDatabase.shared.setOutputTime(
            localIdentifier: model.asset.localIdentifier,
            output: playerInfo.player.currentTime().seconds)
        updateCaptureName()
        updateLabel()
    }

    func updateLabel() {
        let player = playerView.player!
        let target = player.currentTime().seconds
        let offset = target - (getMark()?.input ?? 0)

        // TODO: better frameDuration calculation
        // For a reason I don't understand, minFrameDuration is wildly inaccurate.
        // Perhaps there's a final frame that is shorter than the nominal frame
        // duration.
        let frameDuration = 1.0 / Double(playerInfo.nominalFrameRate)
        let frameNumber = Int(offset / frameDuration)

        let time = Double(frameNumber) * frameDuration
        let timeStr = String(format: "%.1f", time * 1000.0) // ScrubberViewController.formatTime(offset)
        
        Swift.print("offset: \(target - time)")

        locationLabel.text = "frame \(frameNumber)\ntime \(timeStr)"
    }
    
    // TODO: AVPlayerItem.duration
    // TODO: step(byCount:) ??
    // TODO: seek(to: CMTime)
   
    // AVAsset
    //    providesPreciseDurationAndTiming
    
    // AVAssetTrack
    //    mediaType == AVMediaTypeVideo
    //    timeRange
    //    naturalTimeScale
    //    nominalFrameRate
    //    minFrameDuration
    //    segments
    //    canProvideSampleCursors
    //    makeSampleCursor
    
    // AVAssetTrackSegment
    
    
    // AVSampleCursor
    //    currentChunkInfo
    //    currentSampleDuration
    //    currentSampleSyncInfo
    //
    
}
