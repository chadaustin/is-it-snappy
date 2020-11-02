import UIKit
import UIKit.UIGestureRecognizerSubclass
import Photos

let tapEdgeWidth: CGFloat = 30

class PlayerInfo {
    init(sourceAsset: AVAsset) {
        videoAsset = PlayerInfo.getInnerAsset(sourceAsset)

        // TODO: check that the videoAsset has a video track
        let track = videoAsset.tracks[0]
        
        Swift.print("nominalFrameRate: \(track.nominalFrameRate)")
        Swift.print("minFrameDuration: \(track.minFrameDuration.seconds)")
        Swift.print("maxFrameRate: \(1.0 / track.minFrameDuration.seconds)")

        playerItem = AVPlayerItem(asset: videoAsset)
        player = AVPlayer(playerItem: playerItem)

        nominalFrameRate = track.nominalFrameRate

        // nil gets original sample data without overhead for decompression
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        // TODO: if this fails use the frame number estimation based on nominalFrameRate
        let reader = try! AVAssetReader(asset: videoAsset)
        output.alwaysCopiesSampleData = false // possibly prevents unnecessary copying?
        reader.add(output)
        reader.startReading()

        var times: [CMTime] = []
        while reader.status == .reading {
            if let sampleBuffer = output.copyNextSampleBuffer() {
                if CMSampleBufferIsValid(sampleBuffer) && 0 != CMSampleBufferGetTotalSampleSize(sampleBuffer) {
                    let frameTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
                    if frameTime.isValid {
                        times.append(frameTime)
                    }
                }
            }
        }

        frameTimes = times
    }

    let videoAsset: AVAsset
    let playerItem: AVPlayerItem
    let player: AVPlayer
    let nominalFrameRate: Float
    // there's probably a more compact encoding, but an hour of 240 fps video is only in the megabytes of metadata
    let frameTimes: [CMTime]

    func frameNumber(for time: CMTime) -> (Int, CMTime) {
        var previousFrameNumber = 0
        var previousFrameTime = CMTime.zero
        for (frameNumber, frameTime) in frameTimes.enumerated() {
            if time < frameTime {
                break
            }
            previousFrameNumber = frameNumber
            previousFrameTime = frameTime
        }
        return (previousFrameNumber, previousFrameTime)
        // TODO: binary search
        /*
        var lower = 0
        var upper = frameTimes.count

        while lower < upper {
            let midpoint = lower + (upper - lower) / 2
            if time < frameTimes[midpoint] {
                upper = midpoint
            } else {
                lower = midpoint
            }
        }
        return lower
         */
    }

    func frameNumber(for time: Double) -> (Int, CMTime) {
        let offset = 0.001 // 1 ms to give us some room, double->cmtime is imprecise
        let cmtime = CMTime(seconds: time + offset, preferredTimescale: 24000)
        return frameNumber(for: cmtime)
    }
    
    func timeFor(frame: Int) -> CMTime {
        if frame < 0 {
            return frameTimes.first ?? CMTime.zero
        }
        if frame >= frameTimes.count {
            return frameTimes.last ?? CMTime.zero
        }
        return frameTimes[frame]
    }

    static func getInnerAsset(_ sourceAsset: AVAsset) -> AVAsset {
        if let urlAsset = sourceAsset as? AVURLAsset {
            return urlAsset
        } else if let composition = sourceAsset as? AVComposition {
            // Bypass the composition's frame rate ramp.
            // TODO: check for video track and segment and source URL
            let track = composition.tracks.first(where: { $0.mediaType == AVMediaType.video })!
            return AVURLAsset(
                url: track.segments[0].sourceURL!,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: "true"])

        } else {
            return sourceAsset
        }
    }
}

class TapDownGestureRecognizer: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if self.state == .possible {
            self.state = .recognized
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        self.state = .failed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        self.state = .failed
    }
}

class MarkViewController: UIViewController, UIGestureRecognizerDelegate, UITextFieldDelegate {
    enum State {
        case loading
        case failed
        case idle
        case seeking
        case seekingWithPendingSeek(to: CMTime)
    }

    var state = State.loading

    var model: VideoModel!
    var playerInfo: PlayerInfo!

    var playerView: PlayerView {
        return view as! PlayerView
    }

    @IBOutlet var screenshotModeMarkImage: UIImageView!
    @IBOutlet var captureNameField: UITextField!
    @IBOutlet var markInputButton: UIButton!
    @IBOutlet var markOutputButton: UIButton!
    @IBOutlet var locationLabel: UILabel!
    
    let tapGestureRecognizer = TapDownGestureRecognizer()
    let panGestureRecognizer = UIPanGestureRecognizer()
   
    func setModel(_ model: VideoModel) {
        precondition(self.model == nil, "model can only be set once")
        self.model = model
        
        if screenshotMode {
            DispatchQueue.main.async {
                self.screenshotModeMarkImage.isHidden = false
                
                self.captureNameField.text = "MBP Device KB -- 95.8 ms"
                
                self.markInputButton.isEnabled = false
                self.markInputButton.setTitle("Mark Input\nframe 653", for: .normal)
                self.markInputButton.isEnabled = true

                self.markOutputButton.isEnabled = false
                self.markOutputButton.setTitle("Mark Output\nframe 676", for: .normal)
                self.markOutputButton.isEnabled = true
                
                self.locationLabel.text = "frame 677(+24)\n2821.2 ms"
            }
        } else {
            let options: PHVideoRequestOptions? = nil
            PHImageManager.default().requestAVAsset(
                forVideo: (model as! PHVideoModel).asset,
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
                    ss.updateInputButtonLabel()
                    ss.updateOutputButtonLabel()
                }
            }
        }
    }

    override func viewDidLoad() {
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addGestureRecognizer(tapGestureRecognizer)
        view.addGestureRecognizer(panGestureRecognizer)

        captureNameField.delegate = self
       
        tapGestureRecognizer.addTarget(self, action: #selector(handleGesture))
        tapGestureRecognizer.delegate = self
        
        panGestureRecognizer.addTarget(self, action: #selector(handleGesture))
        panGestureRecognizer.delegate = self

        setNeedsStatusBarAppearanceUpdate()
        
        updateCaptureName()
    }
    
    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        textField.text = getMark().name
        return true
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField.isFirstResponder {
            textField.resignFirstResponder()
            MarkDatabase.shared.setName(localIdentifier: model.uniqueID, name: textField.text ?? "")
        }
        updateCaptureName()
        return false
    }
    
    func updateCaptureName() {
        captureNameField.text = getMark().displayLabel("[name]")
    }
   
    func getMark() -> Mark {
        return MarkDatabase.shared.get(localIdentifier: model.uniqueID) ?? Mark()
    }

    @IBAction
    func pressDone(_ sender: UIButton?) {
        if captureNameField.isFirstResponder {
            dismissKeyboard()
        } else {
            dismiss(animated: true)
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .default
    }
    
    var gestureStartTime: CMTime = CMTime.zero

    static func formatTime(_ time: CMTime) -> String {
        return String(format: "%.1f", time.seconds * 1000.0)
    }
    
    func dismissKeyboard() {
        _ = textFieldShouldReturn(captureNameField)
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let loc = touch.location(in: view)
        guard view.hitTest(loc, with: nil) == view else {
            return false
        }
        
        let bounds = view.bounds
        let onEdge = (loc.x < bounds.minX + tapEdgeWidth) || (loc.x > bounds.maxX - tapEdgeWidth)
        if gestureRecognizer == tapGestureRecognizer {
            return onEdge
        } else if gestureRecognizer == panGestureRecognizer {
            return !onEdge
        } else {
            NSLog("unknown gesture recognizer")
            return false
        }
    }

    @objc func handleGesture(_ gestureRecognizer: UIGestureRecognizer) {
        guard let player = playerView.player else {
            return
        }
        dismissKeyboard()
        
        func aimAt(time target: CMTime) {
            switch state {
            case .loading, .failed:
                break
            case .idle:
                seek(to: target)
            case .seeking:
                state = .seekingWithPendingSeek(to: target)
            case .seekingWithPendingSeek(to: _):
                state = .seekingWithPendingSeek(to: target)
            }
        }

        if gestureRecognizer == tapGestureRecognizer {
            let currentTime = player.currentTime()
            let (currentFrame, _) = playerInfo.frameNumber(for: currentTime)

            let newTime: CMTime
            let loc = tapGestureRecognizer.location(in: view)
            if loc.x < view.bounds.midX {
                // one frame left
                newTime = playerInfo.timeFor(frame: currentFrame - 1)
            } else {
                // one frame right
                newTime = playerInfo.timeFor(frame: currentFrame + 1)
            }
            
            aimAt(time: newTime)
        } else if gestureRecognizer == panGestureRecognizer {
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

            var x = Double(-panGestureRecognizer.translation(in: view).x)
            //Swift.print("before: \(x) after: \(applyCurve(x))")
            x = applyCurve(x)

            let minimum = CMTime.zero
            let maximum = player.currentItem!.duration

            let target = min(maximum, max(minimum, gestureStartTime + CMTimeMakeWithSeconds(x, preferredTimescale: 240*100)))
            aimAt(time: target)
        }
    }

    func seek(to target: CMTime) {
        guard let player = playerView.player else {
            return
        }

        state = .seeking
        player.seek(
            to: target,
            toleranceBefore: CMTime.zero,
            toleranceAfter: CMTime.zero
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
            localIdentifier: model.uniqueID,
            input: currentFrameTime)
        updateCaptureName()
        updateLabel()
        updateInputButtonLabel()
    }
    
    @IBAction
    func handleMarkEndTime(_ sender: AnyObject?) {
        MarkDatabase.shared.setOutputTime(
            localIdentifier: model.uniqueID,
            output: currentFrameTime)
        updateCaptureName()
        updateLabel()
        updateOutputButtonLabel()
    }
    
    var currentFrameTime: Double {
        let currentTime = playerInfo.player.currentTime()
        let (_, frameTime) = playerInfo.frameNumber(for: currentTime)

        return frameTime.seconds
    }

    func updateLabel() {
        let target = playerInfo.player.currentTime()
        //let offset = target.seconds - (getMark().input ?? 0)
        
        // TODO: better frameDuration calculation
        // For a reason I don't understand, minFrameDuration is wildly inaccurate.
        // Perhaps there's a final frame that is shorter than the nominal frame
        // duration.
        //let frameDuration = 1.0 / Double(playerInfo.nominalFrameRate)
        //let frameNumber = Int(offset / frameDuration)
        let (frameNumber, time) = playerInfo.frameNumber(for: target)
        
        

        //let time = Double(frameNumber) / Double(playerInfo.nominalFrameRate)
        let timeStr = String(format: "%.1f", time.seconds * 1000.0) // ScrubberViewController.formatTime(offset)

        //Swift.print("target: \(target), offset: \(offset), time: \(time)")
        
        let frameOffset: String
        if let input = getMark().input {
            let inputFrame = playerInfo.frameNumber(for: input).0
            if frameNumber > inputFrame {
                frameOffset = "(+\(frameNumber - inputFrame))"
            } else {
                frameOffset = "(\(frameNumber - inputFrame))"
            }
        } else {
            frameOffset = ""
        }

        locationLabel.text = "frame \(frameNumber)\(frameOffset)\n\(timeStr) ms"
    }
    
    func updateInputButtonLabel() {
        let frame: String
        if let input = getMark().input {
            frame = "frame \(playerInfo.frameNumber(for: input).0)"
        } else {
            frame = "--"
        }
        markInputButton.isEnabled = false
        markInputButton.setTitle("Mark Input\n\(frame)", for: .normal)
        markInputButton.isEnabled = true
    }
    
    func updateOutputButtonLabel() {
        let frame: String
        if let output = getMark().output {
            frame = "frame \(playerInfo.frameNumber(for: output).0)"
        } else {
            frame = "--"
        }
        markOutputButton.isEnabled = false
        markOutputButton.setTitle("Mark Output\n\(frame)", for: .normal)
        markOutputButton.isEnabled = true
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
