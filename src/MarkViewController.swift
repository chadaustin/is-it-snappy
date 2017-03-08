import UIKit
import Photos

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
    var videoAsset: AVAsset!
    var playerItem: AVPlayerItem!
    var player: AVPlayer!

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

                if let urlAsset = sourceAsset as? AVURLAsset {
                    //Swift.print("URL asset \(urlAsset.url)")
                    ss.videoAsset = urlAsset
                } else if let composition = sourceAsset as? AVComposition {
                    let track = composition.tracks.first(where: { $0.mediaType == AVMediaTypeVideo })!

                    /*
                    let videoAsset = track.asset!
                    if let urlAsset = videoAsset as? AVURLAsset {
                        Swift.print("URL asset: \(urlAsset.url)")
                    }
                    */
                    
                    let newComposition = AVMutableComposition()
                    let mutableTrack = newComposition.addMutableTrack(withMediaType: AVMediaTypeVideo, preferredTrackID: track.trackID)
                    let timeRange = track.timeRange
                    //let timeRange = CMTimeRange(start: kCMTimeZero, duration: composition.duration)
                    mutableTrack.segments = [
                        AVCompositionTrackSegment(
                            url: track.segments[0].sourceURL!,
                            trackID: track.trackID,
                            sourceTimeRange: timeRange,
                            targetTimeRange: CMTimeRange(start: timeRange.start, duration: CMTimeMultiply(timeRange.duration, 4))),
                    ]
                    mutableTrack.preferredVolume = track.preferredVolume
                    mutableTrack.preferredTransform = track.preferredTransform
                    /*
                    if !mutableTrack.validateSegments(mutableTrack.segments) {
                        Swift.print("validateSegments failed")
                    }
     */
                    /*
                    for segment in track.segments {
                        //segment.timeMapping = CMTimeMapping(source: segment.timeMapping.source, target: segment.timeMapping.source)
                        mutableTrack.segments.append(segment)
                    }
                    mutableTrack.segments = track.segments
     */
                    _ = newComposition
                    ss.videoAsset = AVURLAsset(
                        url: track.segments[0].sourceURL!,
                        options: [AVURLAssetPreferPreciseDurationAndTimingKey: "true"])
                    
                } else {
                    ss.videoAsset = sourceAsset
                }

                // assert only one track?
                let track = ss.videoAsset.tracks[0]
                
                Swift.print("nominalFrameRate: \(track.nominalFrameRate)")
                Swift.print("minFrameDuration: \(track.minFrameDuration.seconds)")
                Swift.print("minFrameRate: \(1.0 / track.minFrameDuration.seconds)")

                ss.playerItem = AVPlayerItem(asset: ss.videoAsset)
                ss.player = AVPlayer(playerItem: ss.playerItem)
                ss.playerView.player = ss.player
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
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return false
    }

    @IBAction func pressDone(_ sender: UIButton?) {
        dismiss(animated: true)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
    
    var gestureStartTime: CMTime = kCMTimeZero
    var markedStartTime: CMTime = kCMTimeZero

    static func formatTime(_ time: CMTime) -> String {
        return String(format: "%.1f", time.seconds * 1000.0)
    }

    func handleGesture() {
        guard let player = playerView.player else {
            return
        }

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
        markedStartTime = playerView.player!.currentTime()
        updateLabel()
    }

    func updateLabel() {
        let player = playerView.player!
        let target = player.currentTime()
        let offset = target - markedStartTime

        let track = videoAsset.tracks[0]

        // TODO: better frameDuration calculation
        // For a reason I don't understand, minFrameDuration is wildly inaccurate.
        // Perhaps there's a final frame that is shorter than the nominal frame
        // duration.
        let frameDuration = 1.0 / Double(track.nominalFrameRate)
        let frameNumber = Int(offset.seconds / frameDuration)

        let time = Double(frameNumber) * frameDuration
        let timeStr = String(format: "%.1f", time * 1000.0) // ScrubberViewController.formatTime(offset)
        
        Swift.print("offset: \(target.seconds - time)")

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
