import UIKit
import AVFoundation
import Photos

fileprivate struct Context {
    static var SessionRunning = 1

    static var FocusMode = 2
    static var ExposureMode = 3
    static var LensPosition = 5
    static var ExposureDuration = 6
    static var ISO = 7
    static var ExposureTargetOffset = 8
}

enum AVCamManualSetupResult {
    case success
    case cameraNotAuthorized
    case sessionConfigurationFailed
}

fileprivate let kExposureDurationPower: Float64 = 5; // Higher numbers will give the slider more sensitivity at shorter durations
fileprivate let kExposureMinimumDuration: Float64 = 1.0/1000; // Limit exposure duration to a useful range

extension AVCaptureVideoOrientation {
    var uiInterfaceOrientation: UIInterfaceOrientation {
        get {
            switch self {
            case .landscapeLeft: return .landscapeLeft
            case .landscapeRight: return .landscapeRight
            case .portrait: return .portrait
            case .portraitUpsideDown: return .portraitUpsideDown
            }
        }
    }

    init(ui: UIInterfaceOrientation) {
        switch ui {
        case .landscapeRight: self = .landscapeRight
        case .landscapeLeft: self = .landscapeLeft
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        default: self = .portrait
        }
    }

    init?(orientation:UIDeviceOrientation) {
        switch orientation {
        case .landscapeRight:       self = .landscapeLeft
        case .landscapeLeft:        self = .landscapeRight
        case .portrait:             self = .portrait
        case .portraitUpsideDown:   self = .portraitUpsideDown
        default:
            return nil
        }
    }
}

func enumFromAny<T>(_ ctor: (Int) -> T?, _ v: Any?) -> T? {
    if let n = v as? NSNumber {
        return ctor(n.intValue)
    } else {
        return nil
    }
}

extension AVCaptureDeviceFormat {
    var maxSupportedFrameRate: Double {
        var m: Double = 0
        for range in self.videoSupportedFrameRateRanges {
            let range = range as! AVFrameRateRange
            if range.maxFrameRate > m {
                m = range.maxFrameRate
            }
        }
        return m
    }
}

extension AVCaptureDevice {
    func setBestFormat() {
        let videoDevice = self
        var formats = videoDevice.formats as! [AVCaptureDeviceFormat]
        func formatPriority(_ format: AVCaptureDeviceFormat) -> Int {
            // frame rate is the most important factor
            // full vs. video dynamic range is the second
            let isFull = CMFormatDescriptionGetMediaSubType(format.formatDescription) & 0xFF == 102 // f
            // pack the sort key into an int because Swift doesn't have tuple comparison yet
            return Int(format.maxSupportedFrameRate) * 2 + (isFull ? 1 : 0)
        }
        formats.sort(by: { formatPriority($0) > formatPriority($1) })
        if let first = formats.first {
            if first.maxSupportedFrameRate > 60 {
                do {
                    try videoDevice.lockForConfiguration()
                    videoDevice.activeFormat = first
                    videoDevice.unlockForConfiguration()
                }
                catch let error {
                    NSLog("Could not set active format: \(error)")
                }
            }
        }
    }
}

class AAPLCameraViewController: UIViewController, AVCaptureFileOutputRecordingDelegate {

    @IBOutlet weak var previewView: CaptureVideoPreviewView!
    @IBOutlet weak var cameraUnavailableLabel: UILabel!
    @IBOutlet weak var resumeButton: UIButton!
    @IBOutlet weak var recordButton: UIButton!
    @IBOutlet weak var cameraButton: UIButton!

    var focusModes: [AVCaptureFocusMode]!
    @IBOutlet weak var manualHUDFocusView: UIView!
    @IBOutlet weak var focusModeControl: UISegmentedControl!
    @IBOutlet weak var lensPositionSlider: UISlider!
    @IBOutlet weak var lensPositionNameLabel: UILabel!
    @IBOutlet weak var lensPositionValueLabel: UILabel!

    var exposureModes: [AVCaptureExposureMode]!
    @IBOutlet weak var manualHUDExposureView: UIView!
    @IBOutlet weak var exposureModeControl: UISegmentedControl!
    @IBOutlet weak var exposureDurationSlider: UISlider!
    @IBOutlet weak var exposureDurationNameLabel: UILabel!
    @IBOutlet weak var exposureDurationValueLabel: UILabel!
    @IBOutlet weak var ISOSlider: UISlider!
    @IBOutlet weak var ISONameLabel: UILabel!
    @IBOutlet weak var ISOValueLabel: UILabel!
    @IBOutlet weak var exposureTargetBiasSlider: UISlider!
    @IBOutlet weak var exposureTargetBiasNameLabel: UILabel!
    @IBOutlet weak var exposureTargetBiasValueLabel: UILabel!
    @IBOutlet weak var exposureTargetOffsetSlider: UISlider!
    @IBOutlet weak var exposureTargetOffsetNameLabel: UILabel!
    @IBOutlet weak var exposureTargetOffsetValueLabel: UILabel!

    // Session management.
    var sessionQueue: DispatchQueue!
    var session: AVCaptureSession!
    var videoDeviceInput: AVCaptureDeviceInput!
    var videoDevice: AVCaptureDevice!
    var movieFileOutput: AVCaptureMovieFileOutput?

    // Utilities.
    var setupResult: AVCamManualSetupResult!
    var isSessionRunning: Bool!
    var backgroundRecordingID: UIBackgroundTaskIdentifier!

    override func viewDidLoad() {
        super.viewDidLoad()

        // Disable UI. The UI is enabled if and only if the session starts running.
        self.cameraButton.isEnabled = false
        self.recordButton.isEnabled = false

        self.manualHUDFocusView.isHidden = true
        self.manualHUDExposureView.isHidden = true

        // Create the AVCaptureSession.
        self.session = AVCaptureSession()

        // Setup the preview view.
        self.previewView.session = self.session

        // Communicate with the session and other session objects on this queue.
        self.sessionQueue = DispatchQueue(label: "session queue")

        self.setupResult = .success

        // Check video authorization status. Video access is required and audio access is optional.
        // If audio access is denied, audio is not recorded during movie recording.
        switch AVCaptureDevice.authorizationStatus(forMediaType: AVMediaTypeVideo) {
        case .authorized:
            // The user has previously granted access to the camera.
            break;
        case .notDetermined:
            // The user has not yet been presented with the option to grant video access.
            // We suspend the session queue to delay session setup until the access request has completed to avoid
            // asking the user for audio access if video access is denied.
            // Note that audio access will be implicitly requested when we create an AVCaptureDeviceInput for audio during session setup.
            self.sessionQueue.suspend()
            AVCaptureDevice.requestAccess(forMediaType: AVMediaTypeVideo) { granted in
                if !granted {
                    self.setupResult = .cameraNotAuthorized
                } else {
                    self.sessionQueue.resume()
                }
            }
            break;
        default:
            // The user has previously denied access.
            self.setupResult = .cameraNotAuthorized
            break;
        }

        // Setup the capture session.
        // In general it is not safe to mutate an AVCaptureSession or any of its inputs, outputs, or connections from multiple threads at the same time.
        // Why not do all of this on the main queue?
        // Because -[AVCaptureSession startRunning] is a blocking call which can take a long time. We dispatch session setup to the sessionQueue
        // so that the main queue isn't blocked, which keeps the UI responsive.
        self.sessionQueue.async {
            if self.setupResult != .success {
                return
            }

            self.backgroundRecordingID = UIBackgroundTaskInvalid

            let videoDevice = AAPLCameraViewController.device(withMediaType: AVMediaTypeVideo, preferringPosition: .back)!

            var videoDeviceInput: AVCaptureDeviceInput?
            do {
                videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
            }
            catch let error {
                NSLog("Could not create video device input: \(error)")
            }

            self.session.beginConfiguration()
            if let videoDeviceInput = videoDeviceInput, self.session.canAddInput(videoDeviceInput) {
                self.session.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput
                self.videoDevice = videoDevice

                videoDevice.setBestFormat()

                DispatchQueue.main.async {
                    // Why are we dispatching this to the main queue?
                    // Because AVCaptureVideoPreviewLayer is the backing layer for AAPLPreviewView and UIView
                    // can only be manipulated on the main thread.
                    // Note: As an exception to the above rule, it is not necessary to serialize video orientation changes
                    // on the AVCaptureVideoPreviewLayer’s connection with other session manipulation.

                    // Use the status bar orientation as the initial video orientation. Subsequent orientation changes are handled by
                    // -[viewWillTransitionToSize:withTransitionCoordinator:].
                    let statusBarOrientation = UIApplication.shared.statusBarOrientation
                    var initialVideoOrientation = AVCaptureVideoOrientation.portrait
                    if  statusBarOrientation != .unknown {
                        initialVideoOrientation = AVCaptureVideoOrientation(ui: statusBarOrientation)
                    }

                    let previewLayer = self.previewView.layer
                    previewLayer.connection.videoOrientation = initialVideoOrientation
                }
            } else {
                NSLog( "Could not add video device input to the session" );
                self.setupResult = .sessionConfigurationFailed
            }

            let movieFileOutput = AVCaptureMovieFileOutput()
            if self.session.canAddOutput(movieFileOutput) {
                self.session.addOutput(movieFileOutput)
                let connection: AVCaptureConnection = movieFileOutput.connection(withMediaType: AVMediaTypeVideo)
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
                self.movieFileOutput = movieFileOutput
            }
            else {
                NSLog("Could not add movie file output to the session")
                self.setupResult = .sessionConfigurationFailed
            }

            self.session.commitConfiguration()

            DispatchQueue.main.async {
                self.configureManualHUD()
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        self.sessionQueue.async {
            switch self.setupResult! {
            case .success:
				// Only setup observers and start the session running if setup succeeded.
                self.addObservers()
                self.session.startRunning()
				self.isSessionRunning = self.session.isRunning
				break
            case .cameraNotAuthorized:
                DispatchQueue.main.async {
                    let message = NSLocalizedString("AVCamManual doesn't have permission to use the camera, please change privacy settings", comment: "Alert message when the user has denied access to the camera")
                    let alertController = UIAlertController(title: "AVCamManual", message: message, preferredStyle: .alert)
                    let cancelAction = UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler:nil)
                    alertController.addAction(cancelAction)
                    // Provide quick access to Settings.
                    let settingsAction = UIAlertAction(title: NSLocalizedString("Settings", comment: "Alert button to open Settings"), style: .default) { action in
                        UIApplication.shared.openURL(URL(string: UIApplicationOpenSettingsURLString)!)
                    }
                    alertController.addAction(settingsAction)
                    self.present(alertController, animated: true, completion: nil)
				}
				break
            case .sessionConfigurationFailed:
                DispatchQueue.main.async {
                    let message = NSLocalizedString("Unable to capture media", comment: "Alert message when something goes wrong during capture session configuration")
                    let alertController = UIAlertController(title: "AVCamManual", message: message, preferredStyle: .alert)
                    let cancelAction = UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil)
                    alertController.addAction(cancelAction)
                    self.present(alertController, animated: true, completion: nil)
                }
                break;
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        self.sessionQueue.async {
            if self.setupResult == .success {
                self.session.stopRunning()
                self.removeObservers()
            }
        }

        super.viewDidDisappear(animated)
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }

    // MARK: Orientation

    override var shouldAutorotate: Bool {
        // Disable autorotation of the interface when recording is in progress.
        return !(self.movieFileOutput?.isRecording ?? false)
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .all
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        // Note that the app delegate controls the device orientation notifications required to use the device orientation.
        let deviceOrientation = UIDevice.current.orientation
        if UIDeviceOrientationIsPortrait( deviceOrientation ) || UIDeviceOrientationIsLandscape( deviceOrientation ) {
            let previewLayer = self.previewView.layer
            previewLayer.connection.videoOrientation = AVCaptureVideoOrientation(orientation: deviceOrientation)!
        }
    }

    // MARK: KVO and Notifications

    func addObservers() {
        self.addObserver(self, forKeyPath: "session.running", options: .new, context: &Context.SessionRunning)

        self.addObserver(self, forKeyPath: "videoDevice.focusMode", options: [.old, .new], context: &Context.FocusMode)
        self.addObserver(self, forKeyPath: "videoDevice.lensPosition", options: .new, context: &Context.LensPosition)
        self.addObserver(self, forKeyPath: "videoDevice.exposureMode", options: [.old, .new], context: &Context.ExposureMode)
        self.addObserver(self, forKeyPath: "videoDevice.exposureDuration", options: .new, context: &Context.ExposureDuration)
        self.addObserver(self, forKeyPath: "videoDevice.ISO", options: .new, context: &Context.ISO)
        self.addObserver(self, forKeyPath: "videoDevice.exposureTargetOffset", options: .new, context: &Context.ExposureTargetOffset)

        NotificationCenter.default.addObserver(self, selector: #selector(subjectAreaDidChange), name: NSNotification.Name.AVCaptureDeviceSubjectAreaDidChange, object:self.videoDevice)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError), name: NSNotification.Name.AVCaptureSessionRuntimeError, object:self.session)
        // A session can only run when the app is full screen. It will be interrupted in a multi-app layout, introduced in iOS 9,
        // see also the documentation of AVCaptureSessionInterruptionReason. Add observers to handle these session interruptions
        // and show a preview is paused message. See the documentation of AVCaptureSessionWasInterruptedNotification for other
        // interruption reasons.
        NotificationCenter.default.addObserver(self, selector: #selector(sessionWasInterrupted), name: NSNotification.Name.AVCaptureSessionWasInterrupted, object: self.session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded), name: NSNotification.Name.AVCaptureSessionInterruptionEnded,  object: self.session)
    }

    func removeObservers() {
        NotificationCenter.default.removeObserver(self)

        removeObserver(self, forKeyPath: "session.running", context: &Context.SessionRunning)

        removeObserver(self, forKeyPath: "videoDevice.focusMode", context: &Context.FocusMode)
        removeObserver(self, forKeyPath: "videoDevice.lensPosition", context: &Context.LensPosition)
        removeObserver(self, forKeyPath: "videoDevice.exposureMode", context: &Context.ExposureMode)
        removeObserver(self, forKeyPath: "videoDevice.exposureDuration", context: &Context.ExposureDuration)
        removeObserver(self, forKeyPath: "videoDevice.ISO", context: &Context.ISO)
        removeObserver(self, forKeyPath: "videoDevice.exposureTargetOffset", context: &Context.ExposureTargetOffset)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        let oldValue = change?[.oldKey]
        let newValue = change?[.newKey]

        if ( context == &Context.FocusMode ) {
            if !(newValue is NSNull) {
                let newMode = enumFromAny(AVCaptureFocusMode.init, newValue)!
                self.focusModeControl.selectedSegmentIndex = self.focusModes.index(of: newMode)!
                self.lensPositionSlider.isEnabled = newMode == .locked
            }
        }
        else if ( context == &Context.LensPosition ) {
            if !(newValue is NSNull) {
                let newLensPosition = newValue as! Float

                if ( self.videoDevice.focusMode != .locked ) {
                    self.lensPositionSlider.value = newLensPosition;
                }
                self.lensPositionValueLabel.text = String(format: "%.1f", newLensPosition)
            }
        }
        else if ( context == &Context.ExposureMode ) {
            if !(newValue is NSNull) {
                let newMode = enumFromAny(AVCaptureExposureMode.init, newValue)!

                self.exposureModeControl.selectedSegmentIndex = self.exposureModes.index(of: newMode)!
                self.exposureDurationSlider.isEnabled = ( newMode == .custom )
                self.ISOSlider.isEnabled = ( newMode == .custom )

                if let oldMode = enumFromAny(AVCaptureExposureMode.init, oldValue) {
                    /*
                     It’s important to understand the relationship between exposureDuration and the minimum frame rate as represented by activeVideoMaxFrameDuration.
                     In manual mode, if exposureDuration is set to a value that's greater than activeVideoMaxFrameDuration, then activeVideoMaxFrameDuration will
                     increase to match it, thus lowering the minimum frame rate. If exposureMode is then changed to automatic mode, the minimum frame rate will
                     remain lower than its default. If this is not the desired behavior, the min and max frameRates can be reset to their default values for the
                     current activeFormat by setting activeVideoMaxFrameDuration and activeVideoMinFrameDuration to kCMTimeInvalid.
                     */
                    if ( oldMode != newMode && oldMode == .custom ) {
                        if let _ = try? self.videoDevice.lockForConfiguration() {
                            self.videoDevice.activeVideoMaxFrameDuration = kCMTimeInvalid
                            self.videoDevice.activeVideoMinFrameDuration = kCMTimeInvalid
                            self.videoDevice.unlockForConfiguration()
                        }
                    }
                }
            }
        }
        else if ( context == &Context.ExposureDuration ) {
            if !(newValue is NSNull) {
                let newDurationSeconds = CMTimeGetSeconds(newValue as! CMTime)
                if self.videoDevice.exposureMode != .custom {
                    let minDurationSeconds = max( CMTimeGetSeconds( self.videoDevice.activeFormat.minExposureDuration ), kExposureMinimumDuration )
                    let maxDurationSeconds = CMTimeGetSeconds( self.videoDevice.activeFormat.maxExposureDuration )
                    // Map from duration to non-linear UI range 0-1
                    let p = ( newDurationSeconds - minDurationSeconds ) / ( maxDurationSeconds - minDurationSeconds ) // Scale to 0-1
                    self.exposureDurationSlider.value = Float(pow( p, 1 / kExposureDurationPower )) // Apply inverse power

                    if newDurationSeconds < 1 {
                        let digits = max( 0, 2 + floor( log10( newDurationSeconds ) ) );
                        self.exposureDurationValueLabel.text = String(format: "1/%.*f", digits, 1/newDurationSeconds)
                    }
                    else {
                        self.exposureDurationValueLabel.text = String(format: "%.2f", newDurationSeconds)
                    }
                }
            }
        }
        else if ( context == &Context.ISO ) {
            if !(newValue is NSNull) {
                let newISO = (newValue as! NSNumber).floatValue

                if self.videoDevice.exposureMode != .custom {
                    self.ISOSlider.value = newISO
                }
                self.ISOValueLabel.text = String(format: "%i", Int(newISO))
            }
        }
        else if ( context == &Context.ExposureTargetOffset ) {
            if !(newValue is NSNull) {
                let newExposureTargetOffset = (newValue as! NSNumber).floatValue

                self.exposureTargetOffsetSlider.value = newExposureTargetOffset
                self.exposureTargetOffsetValueLabel.text = String(format: "%.1f", newExposureTargetOffset)
            }
        }
        else if ( context == &Context.SessionRunning ) {
            var isRunning = false
            if !(newValue is NSNull) {
                isRunning = (newValue as! NSNumber).boolValue
            }

            DispatchQueue.main.async {
                self.cameraButton.isEnabled = isRunning && AVCaptureDevice.devices(withMediaType: AVMediaTypeVideo).count > 1
                self.recordButton.isEnabled = isRunning
            }
        }
        else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    func subjectAreaDidChange(_ notification: NSNotification) {
        let devicePoint = CGPoint(x: 0.5, y: 0.5)
        self.focusWithMode(.continuousAutoFocus, exposeWithMode: .continuousAutoExposure, atDevicePoint: devicePoint, monitorSubjectAreaChange: false)
    }

    func sessionRuntimeError(_ notification: NSNotification) {
        let error = notification.userInfo![AVCaptureSessionErrorKey] as! NSError
        NSLog("Capture session runtime error: \(error)")

        if error.code == AVError.mediaServicesWereReset.rawValue {
            self.sessionQueue.async {
                // If we aren't trying to resume the session running, then try to restart it since it must have been stopped due to an error. See also -[resumeInterruptedSession:].
                if self.isSessionRunning == .some(true) {
                    self.session.startRunning()
                    self.isSessionRunning = self.session.isRunning
                }
                else {
                    DispatchQueue.main.async {
                        self.resumeButton.isHidden = false
                    }
                }
            }
        } else {
            self.resumeButton.isHidden = false
        }
    }

    func sessionWasInterrupted(_ notification: NSNotification) {
        // In some scenarios we want to enable the user to resume the session running.
        // For example, if music playback is initiated via control center while using AVCamManual,
        // then the user can let AVCamManual resume the session running, which will stop music playback.
        // Note that stopping music playback in control center will not automatically resume the session running.
        // Also note that it is not always possible to resume, see -[resumeInterruptedSession:].

        // In iOS 9 and later, the userInfo dictionary contains information on why the session was interrupted.
        let reason = enumFromAny(AVCaptureSessionInterruptionReason.init, notification.userInfo?[AVCaptureSessionInterruptionReasonKey])!
        NSLog("Capture session was interrupted with reason \(reason)")

        if ( reason == .audioDeviceInUseByAnotherClient ||
            reason == .videoDeviceInUseByAnotherClient ) {
            // Simply fade-in a button to enable the user to try to resume the session running.
            self.resumeButton.isHidden = false
            self.resumeButton.alpha = 0.0
            UIView.animate(withDuration: 0.25, animations: {
                self.resumeButton.alpha = 1.0
            })
        }
        else if reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
            // Simply fade-in a label to inform the user that the camera is unavailable.
            self.cameraUnavailableLabel.isHidden = false
            self.cameraUnavailableLabel.alpha = 0.0
            UIView.animate(withDuration: 0.25, animations: {
                self.cameraUnavailableLabel.alpha = 1.0
            })
        }
    }

    func sessionInterruptionEnded(_ notification: NSNotification) {
        NSLog("Capture session interruption ended")

        if !self.resumeButton.isHidden {
            UIView.animate(withDuration: 0.25, animations: {
                self.resumeButton.alpha = 0.0
            }, completion: { finished in
                self.resumeButton.isHidden = true
            })
        }
        if !self.cameraUnavailableLabel.isHidden {
            UIView.animate(withDuration: 0.25, animations: {
                self.cameraUnavailableLabel.alpha = 0.0
            }, completion: { finished in
                self.cameraUnavailableLabel.isHidden = true
            })
        }
    }

    // MARK: Actions

    @IBAction
    func resumeInterruptedSession(_ sender: AnyObject?) {
        sessionQueue.async {
            // The session might fail to start running, e.g., if a phone or FaceTime call is still using audio or video.
            // A failure to start the session running will be communicated via a session runtime error notification.
            // To avoid repeatedly failing to start the session running, we only try to restart the session running in the
            // session runtime error handler if we aren't trying to resume the session running.
            self.session.startRunning()
            self.isSessionRunning = self.session.isRunning
            if !self.session.isRunning {
                DispatchQueue.main.async {
                    let message = NSLocalizedString("Unable to resume", comment: "Alert message when unable to resume the session running")
                    let alertController = UIAlertController(title: "AVCamManual", message: message, preferredStyle: .alert)
                    let cancelAction = UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil)
                    alertController.addAction(cancelAction)
                    self.present(alertController, animated: true, completion: nil)
                }
            }
            else {
                DispatchQueue.main.async {
                    self.resumeButton.isHidden = true
                }
            }
        }
    }

    @IBAction
    func toggleMovieRecording(_ sender: AnyObject?) {
        // Disable the Camera button until recording finishes, and disable the Record button until recording starts or finishes. See the
        // AVCaptureFileOutputRecordingDelegate methods.
        self.cameraButton.isEnabled = false
        self.recordButton.isEnabled = false

        self.sessionQueue.async {
            if let movieFileOutput = self.movieFileOutput, !movieFileOutput.isRecording {
                if UIDevice.current.isMultitaskingSupported {
                    // Setup background task. This is needed because the -[captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:]
                    // callback is not received until AVCamManual returns to the foreground unless you request background execution time.
                    // This also ensures that there will be time to write the file to the photo library when AVCamManual is backgrounded.
                    // To conclude this background execution, -endBackgroundTask is called in
                    // -[captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:] after the recorded file has been saved.
                    self.backgroundRecordingID = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
                }

                // Update the orientation on the movie file output video connection before starting recording.
                let movieConnection = movieFileOutput.connection(withMediaType: AVMediaTypeVideo)
                let previewLayer = self.previewView.layer 
                movieConnection?.videoOrientation = previewLayer.connection.videoOrientation;

                // Turn OFF flash for video recording.
                AAPLCameraViewController.setFlashMode(.off, forDevice: self.videoDevice)

                // Start recording to a temporary file.
                let outputFileName = ProcessInfo.processInfo.globallyUniqueString as NSString
                let outputFilePath = (NSTemporaryDirectory() as NSString).appendingPathComponent(outputFileName.appendingPathExtension("mov")!)
                movieFileOutput.startRecording(toOutputFileURL: NSURL.fileURL(withPath: outputFilePath), recordingDelegate: self)
            }
            else {
                self.movieFileOutput?.stopRecording()
            }
        }
    }

    @IBAction
    func cancelCameraRecord(_ sender: AnyObject?) {
        dismiss(animated: true, completion: nil)
    }

    @IBAction
    func changeCamera(_ sender: AnyObject?) {
        self.cameraButton.isEnabled = false
        self.recordButton.isEnabled = false

        self.sessionQueue.async {
            var preferredPosition = AVCaptureDevicePosition.unspecified

            switch self.videoDevice.position {
            case .unspecified: fallthrough
            case .front:
                preferredPosition = .back;
                break;
            case .back:
                preferredPosition = .front;
                break;
            }

            let newVideoDevice = AAPLCameraViewController.device(withMediaType: AVMediaTypeVideo, preferringPosition: preferredPosition)
            let newVideoDeviceInput = try? AVCaptureDeviceInput(device: newVideoDevice)

            self.session.beginConfiguration()

            // Remove the existing device input first, since using the front and back camera simultaneously is not supported.
            self.session.removeInput(self.videoDeviceInput)
            if self.session.canAddInput(newVideoDeviceInput) {
                NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVCaptureDeviceSubjectAreaDidChange, object: self.videoDevice)
                NotificationCenter.default.addObserver(self, selector: #selector(self.subjectAreaDidChange), name: NSNotification.Name.AVCaptureDeviceSubjectAreaDidChange, object: newVideoDevice)

                self.session.addInput(newVideoDeviceInput)
                self.videoDeviceInput = newVideoDeviceInput
                self.videoDevice = newVideoDevice
            }
            else {
                self.session.addInput(self.videoDeviceInput)
            }

            if let connection = self.movieFileOutput?.connection(withMediaType: AVMediaTypeVideo) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
            }

            self.session.commitConfiguration()

            DispatchQueue.main.async {
                self.cameraButton.isEnabled = true
                self.recordButton.isEnabled = true

                self.configureManualHUD()
            }
        }
    }

    @IBAction
    func focusAndExposeTap(_ gestureRecognizer: UIGestureRecognizer) {
        if self.videoDevice.focusMode != .locked && self.videoDevice.exposureMode != .custom {
            let devicePoint = self.previewView.layer.captureDevicePointOfInterest(for: gestureRecognizer.location(in: gestureRecognizer.view))
            self.focusWithMode(.continuousAutoFocus, exposeWithMode: .continuousAutoExposure, atDevicePoint: devicePoint, monitorSubjectAreaChange: true)
        }
    }

    @IBAction
    func changeManualHUD(_ sender: AnyObject?) {
        let control = sender as! UISegmentedControl

        self.manualHUDFocusView.isHidden = ( control.selectedSegmentIndex != 1 )
        self.manualHUDExposureView.isHidden = ( control.selectedSegmentIndex != 2 )
    }

    @IBAction
    func changeFocusMode(_ sender: AnyObject?) {
        let control = sender as! UISegmentedControl
        let mode = self.focusModes[control.selectedSegmentIndex]

        do {
            try self.videoDevice.lockForConfiguration()
            if self.videoDevice.isFocusModeSupported(mode) {
                self.videoDevice.focusMode = mode
            } else {
                //NSLog("Focus mode %@ is not supported. Focus mode is %@.", [self stringFromFocusMode:mode], [self stringFromFocusMode:self.videoDevice.focusMode] );
                self.focusModeControl.selectedSegmentIndex = self.focusModes.index(of: self.videoDevice.focusMode)!
            }
            self.videoDevice.unlockForConfiguration()
        }
        catch let error {
            NSLog("Could not lock device for configuration: \(error)")
        }
    }

    @IBAction
    func changeExposureMode(_ sender: AnyObject?) {
        let control = sender as! UISegmentedControl
        let mode = self.exposureModes[control.selectedSegmentIndex]

        do {
            try self.videoDevice.lockForConfiguration()
            if self.videoDevice.isExposureModeSupported(mode) {
                self.videoDevice.exposureMode = mode;
            } else {
                NSLog("Exposure mode \(stringFromExposureMode(mode)) is not supported. Exposure mode is \(stringFromExposureMode(videoDevice.exposureMode)).")
            }
            videoDevice.unlockForConfiguration()
        }
        catch let error {
            NSLog("Could not lock device for configuration: \(error)")
        }
    }

    @IBAction
    func changeLensPosition(_ sender: AnyObject?) {
        let control = sender as! UISlider
        do {
            try videoDevice.lockForConfiguration()
            videoDevice.setFocusModeLockedWithLensPosition(control.value, completionHandler: nil)
            videoDevice.unlockForConfiguration()
        }
        catch let error {
            NSLog("Could not lock device for configuration: \(error)")
        }
    }

    @IBAction
    func changeExposureDuration(_ sender: AnyObject?) {
        let control = sender as! UISlider

        let p = pow( Double(control.value), kExposureDurationPower ); // Apply power function to expand slider's low-end range
        let minDurationSeconds = max( CMTimeGetSeconds( self.videoDevice.activeFormat.minExposureDuration ), kExposureMinimumDuration );
        let maxDurationSeconds = CMTimeGetSeconds( self.videoDevice.activeFormat.maxExposureDuration );
        let newDurationSeconds = p * ( maxDurationSeconds - minDurationSeconds ) + minDurationSeconds; // Scale from 0-1 slider range to actual duration

        if ( self.videoDevice.exposureMode == .custom ) {
            if ( newDurationSeconds < 1 ) {
                let digits = max( 0, 2 + floor( log10( newDurationSeconds ) ) );
                self.exposureDurationValueLabel.text = String(format: "1/%.*f", digits, 1/newDurationSeconds)
            }
            else {
                self.exposureDurationValueLabel.text = String(format: "%.2f", newDurationSeconds)
            }
        }

        do {
            try videoDevice.lockForConfiguration()
            videoDevice.setExposureModeCustomWithDuration(CMTimeMakeWithSeconds(newDurationSeconds, 1000*1000*1000), iso: AVCaptureISOCurrent, completionHandler: nil)
            videoDevice.unlockForConfiguration()
        }
        catch let error {
            NSLog("Could not lock device for configuration: \(error)")
        }
    }

    @IBAction
    func changeISO(_ sender: AnyObject?) {
        let control = sender as! UISlider

        do {
            try self.videoDevice.lockForConfiguration()
            videoDevice.setExposureModeCustomWithDuration(AVCaptureExposureDurationCurrent, iso: control.value, completionHandler: nil)
            videoDevice.unlockForConfiguration()
        }
        catch let error {
            NSLog("Could not lock device for configuration: \(error)")
        }
    }

    @IBAction
    func changeExposureTargetBias(_ sender: AnyObject?) {
        let control = sender as! UISlider

        do {
            try videoDevice.lockForConfiguration()
            videoDevice.setExposureTargetBias(control.value, completionHandler: nil)
            videoDevice.unlockForConfiguration()
            self.exposureTargetBiasValueLabel.text = String(format: "%.1f", control.value)
        }
        catch let error {
            NSLog("Could not lock device for configuration: \(error)")
        }
    }

    @IBAction
    func sliderTouchBegan(_ sender: AnyObject?) {
        let slider = sender as! UISlider
        self.setSlider(slider, highlightColor: UIColor(red:0.0, green:122.0/255.0, blue:1.0, alpha:1.0))
    }

    @IBAction
    func sliderTouchEnded(_ sender: AnyObject?) {
        let slider = sender as! UISlider
        self.setSlider(slider, highlightColor: UIColor.yellow)
    }

    // MARK: UI

    func configureManualHUD() {
        // Manual focus controls
        self.focusModes = [.continuousAutoFocus, .locked]

        self.focusModeControl.isEnabled = self.videoDevice != nil
        if let videoDevice = self.videoDevice {
            self.focusModeControl.selectedSegmentIndex = self.focusModes.index(of: videoDevice.focusMode)!
            for mode in self.focusModes {
                self.focusModeControl.setEnabled(videoDevice.isFocusModeSupported(mode), forSegmentAt: self.focusModes.index(of: mode)!)
            }
        }

        self.lensPositionSlider.minimumValue = 0.0
        self.lensPositionSlider.maximumValue = 1.0
        self.lensPositionSlider.isEnabled = self.videoDevice?.focusMode == .some(.locked)

        // Manual exposure controls
        self.exposureModes = [.continuousAutoExposure, .locked, .custom]

        self.exposureModeControl.isEnabled = self.videoDevice != nil
        if let videoDevice = self.videoDevice {
            self.exposureModeControl.selectedSegmentIndex = self.exposureModes.index(of: videoDevice.exposureMode)!
            for mode in self.exposureModes {
                self.exposureModeControl.setEnabled(videoDevice.isExposureModeSupported(mode), forSegmentAt: self.exposureModes.index(of: mode)!)
            }
        }

        // Use 0-1 as the slider range and do a non-linear mapping from the slider value to the actual device exposure duration
        self.exposureDurationSlider.minimumValue = 0
        self.exposureDurationSlider.maximumValue = 1
        self.exposureDurationSlider.isEnabled = self.videoDevice?.exposureMode == .some(.custom)

        self.ISOSlider.minimumValue = self.videoDevice?.activeFormat.minISO ?? 0
        self.ISOSlider.maximumValue = self.videoDevice?.activeFormat.maxISO ?? 1
        self.ISOSlider.isEnabled = self.videoDevice?.exposureMode == .some(.custom)

        self.exposureTargetBiasSlider.minimumValue = self.videoDevice?.minExposureTargetBias ?? 0
        self.exposureTargetBiasSlider.maximumValue = self.videoDevice?.maxExposureTargetBias ?? 1
        self.exposureTargetBiasSlider.isEnabled = self.videoDevice != nil

        self.exposureTargetOffsetSlider.minimumValue = self.videoDevice?.minExposureTargetBias ?? 0
        self.exposureTargetOffsetSlider.maximumValue = self.videoDevice?.maxExposureTargetBias ?? 1
        self.exposureTargetOffsetSlider.isEnabled = false
    }

    func setSlider(_ slider: UISlider, highlightColor color: UIColor) {
        slider.tintColor = color

        if ( slider == self.lensPositionSlider ) {
            self.lensPositionNameLabel.textColor = slider.tintColor
            self.lensPositionValueLabel.textColor = slider.tintColor
        }
        else if ( slider == self.exposureDurationSlider ) {
            self.exposureDurationNameLabel.textColor = slider.tintColor
            self.exposureDurationValueLabel.textColor = slider.tintColor
        }
        else if ( slider == self.ISOSlider ) {
            self.ISONameLabel.textColor = slider.tintColor
            self.ISOValueLabel.textColor = slider.tintColor
        }
        else if ( slider == self.exposureTargetBiasSlider ) {
            self.exposureTargetBiasNameLabel.textColor = slider.tintColor
            self.exposureTargetBiasValueLabel.textColor = slider.tintColor
        }
    }

    // MARK: File Output Recording Delegate

    func capture(_ captureOutput: AVCaptureFileOutput, didStartRecordingToOutputFileAt fileURL: URL, fromConnections connections: [Any]) {
        // Enable the Record button to let the user stop the recording.
        DispatchQueue.main.async {
            self.recordButton.isEnabled = true
            self.recordButton.setTitle(NSLocalizedString("Stop", comment: "Recording button stop title"), for: .normal)
        }
    }

    func capture(
        _ captureOutput: AVCaptureFileOutput!,
        didFinishRecordingToOutputFileAt outputFileURL: URL!,
        fromConnections connections: [Any]!, error: Error!
    ) {
        // Note that currentBackgroundRecordingID is used to end the background task associated with this recording.
        // This allows a new recording to be started, associated with a new UIBackgroundTaskIdentifier, once the movie file output's isRecording property
        // is back to NO — which happens sometime after this method returns.
        // Note: Since we use a unique file path for each recording, a new recording will not overwrite a recording currently being saved.
        let currentBackgroundRecordingID = self.backgroundRecordingID
        self.backgroundRecordingID = UIBackgroundTaskInvalid

        let cleanup = {
            try? FileManager.default.removeItem(at: outputFileURL)
            if currentBackgroundRecordingID != UIBackgroundTaskInvalid {
                UIApplication.shared.endBackgroundTask(currentBackgroundRecordingID!)
            }
        }

        var success = true

        if error != nil {
            let error = error as NSError
            NSLog("Movie file finishing error: \(error)")
            success = (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as! NSNumber).boolValue
        }

        if success {
            VideoManager.getAlbum { assetCollection in
                // Check authorization status.
                PHPhotoLibrary.requestAuthorization { status in
                    if status == .authorized {
                        // Save the movie file to the photo library and cleanup.
                        PHPhotoLibrary.shared().performChanges({
                            // In iOS 9 and later, it's possible to move the file into the photo library without duplicating the file data.
                            // This avoids using double the disk space during save, which can make a difference on devices with limited free disk space.
                            let options = PHAssetResourceCreationOptions()
                            options.shouldMoveFile = true
                            let changeRequest = PHAssetCreationRequest.forAsset()
                            changeRequest.addResource(with: .video, fileURL: outputFileURL, options: options)
                            let placeholder = changeRequest.placeholderForCreatedAsset
                            let albumChangeRequest = PHAssetCollectionChangeRequest(for: assetCollection)
                            albumChangeRequest!.addAssets([placeholder!] as NSArray)
                        }) { success, error in
                            if !success {
                                NSLog("Could not save movie to photo library: \(error)")
                            }
                            cleanup()
                        }
                    } else {
                        cleanup()
                    }
                }
            }
        } else {
            cleanup()
        }

        // Enable the Camera and Record buttons to let the user switch camera and start another recording.
        DispatchQueue.main.async {
            // Only enable the ability to change camera if the device has more than one camera.
            self.cameraButton.isEnabled = AVCaptureDevice.devices(withMediaType: AVMediaTypeVideo).count > 1
            self.recordButton.isEnabled = true
            self.recordButton.setTitle(NSLocalizedString("Record", comment: "Recording button record title"), for: .normal)
        }
    }

    // MARK: Device Configuration

    func focusWithMode(_ focusMode: AVCaptureFocusMode, exposeWithMode exposureMode: AVCaptureExposureMode, atDevicePoint point: CGPoint,  monitorSubjectAreaChange: Bool) {
        self.sessionQueue.async {
            let device = self.videoDevice!
            do {
                try device.lockForConfiguration()
            }
            catch let error {
                NSLog("Could not lock device for configuration: \(error)")
                return
            }

            // Setting (focus/exposure)PointOfInterest alone does not initiate a (focus/exposure) operation.
            // Call -set(Focus/Exposure)Mode: to apply the new point of interest.
            if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(focusMode) {
                device.focusPointOfInterest = point
                device.focusMode = focusMode
            }
            
            if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(exposureMode) {
                device.exposurePointOfInterest = point
                device.exposureMode = exposureMode
            }
            
            device.isSubjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
            device.unlockForConfiguration()
        }
    }

    class func setFlashMode(_ flashMode: AVCaptureFlashMode, forDevice device: AVCaptureDevice) {
        if device.hasFlash && device.isFlashModeSupported(flashMode) {
            do {
                try device.lockForConfiguration()
                device.flashMode = flashMode
                device.unlockForConfiguration()
            }
            catch let error {
                NSLog("Could not lock device for configuration: \(error)")
            }
        }
    }

    // MARK: Utilities

    static func device(withMediaType mediaType: String, preferringPosition position: AVCaptureDevicePosition) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.devices(withMediaType: mediaType) as? [AVCaptureDevice] ?? []
        return devices.first(where: { $0.position == position }) ?? devices.first
    }

    func stringFromFocusMode(focusMode: AVCaptureFocusMode) -> String {
        switch focusMode {
        case .locked:
            return "Locked"
        case .autoFocus:
            return "Auto"
        case .continuousAutoFocus:
            return "ContinuousAuto"
        }
    }

    func stringFromExposureMode(_ exposureMode: AVCaptureExposureMode) -> String {
        switch exposureMode {
        case .locked:
            return "Locked"
        case .autoExpose:
            return "Auto"
        case .continuousAutoExposure:
            return "ContinuousAuto"
        case .custom:
            return "Custom"
        }
    }

    func stringFromWhiteBalanceMode(_ whiteBalanceMode: AVCaptureWhiteBalanceMode) -> String {
        switch whiteBalanceMode {
        case .locked:
            return "Locked"
        case .autoWhiteBalance:
            return "Auto"
        case .continuousAutoWhiteBalance:
            return "ContinuousAuto"
        }
    }

    func normalizedGains(_ gains: AVCaptureWhiteBalanceGains) -> AVCaptureWhiteBalanceGains {
        var g = gains

        g.redGain = max(1.0, g.redGain)
        g.greenGain = max(1.0, g.greenGain)
        g.blueGain = max(1.0, g.blueGain)

        guard let videoDevice = videoDevice else {
            return g
        }

        g.redGain = min(videoDevice.maxWhiteBalanceGain, g.redGain)
        g.greenGain = min(videoDevice.maxWhiteBalanceGain, g.greenGain)
        g.blueGain = min(videoDevice.maxWhiteBalanceGain, g.blueGain)

        return g
    }
}
