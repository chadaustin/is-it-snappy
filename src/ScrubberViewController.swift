import UIKit
import Photos

class ScrubberViewController: UIViewController {
    let model: VideoModel
    let playerView = PlayerView()
    let gestureRecognizer = UIPanGestureRecognizer()
    
    init(model: VideoModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        
        let options: PHVideoRequestOptions? = nil
        PHImageManager.default().requestAVAsset(
            forVideo: model.asset,
            options: options
        ) { [weak self] sourceAsset, audioMix, info in
            let player: AVPlayer
            if let urlAsset = sourceAsset as? AVURLAsset {
                Swift.print("URL asset \(urlAsset.url)")
                player = .init(playerItem: AVPlayerItem(asset: sourceAsset!))
            } else if let composition = sourceAsset as? AVComposition {
                
                let track = composition.tracks.first(where: { $0.mediaType == AVMediaTypeVideo })!
                let videoAsset = track.asset!
               
                if let urlAsset = videoAsset as? AVURLAsset {
                    Swift.print("URL asset: \(urlAsset.url)")
                }
                
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
                let plainAsset = AVURLAsset(url: track.segments[0].sourceURL!)
                player = .init(playerItem: AVPlayerItem(asset: plainAsset))
                Swift.print(track.timeRange)
                
            } else {
                player = .init(playerItem: AVPlayerItem(asset: sourceAsset!))
            }
            self?.playerView.player = player
            //player.play()
        }
    }

    required init(coder: NSCoder) {
        fatalError("ScrubberViewController")
    }
    
    override func loadView() {
        view = playerView
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        
        view.addGestureRecognizer(gestureRecognizer)
        
        gestureRecognizer.addTarget(self, action: #selector(handleGesture))
        
    }
    
    var gestureStartTime: CMTime = kCMTimeZero

    func handleGesture() {
        guard let player = playerView.player else {
            return
        }
        if gestureRecognizer.state == .began {
            gestureStartTime = player.currentTime()
        }
        
        var x = -gestureRecognizer.translation(in: view).x
        x /= 200
        
        let minimum = kCMTimeZero
        let maximum = player.currentItem!.duration
        
        let target = gestureStartTime + CMTimeMakeWithSeconds(Float64(x), maximum.timescale)

        Swift.print("+ seeking to \(target)")
        player.seek(
            to: target,
            toleranceBefore: kCMTimeZero,
            toleranceAfter: kCMTimeZero
        ) { finished in
            if finished {
                Swift.print("seek finished \(player.currentTime())")
                let frameDuration = player.currentItem!.asset.tracks[0].minFrameDuration
                let frameNumber = (target.value * Int64(frameDuration.timescale)) /
                    (Int64(target.timescale) * frameDuration.value);

                Swift.print("frame number \(frameNumber)")
            } else {
                Swift.print("seek failed")
            }
        }
        print("x = \(x) out of \(view.bounds.width)")
        print("  \(gestureRecognizer.state.rawValue)")
    }
    
    // TODO: AVPlayerItem.duration
    // TODO: step(byCount:) ??
    // TODO: seek(to: CMTime)
    // try seek(to: CMTime, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler)
    // currentTime()
   
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
