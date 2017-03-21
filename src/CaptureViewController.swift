import UIKit
import AVFoundation
import Photos

fileprivate struct Context {
    static var SessionRunning = 1

    static var FocusMode = 2
    static var LensPosition = 5
}

fileprivate struct UIBits {
    init(_ bits: UInt8) {
        focusToggleEnabled = (bits & 8) != 0
        toggleCameraEnabled = (bits & 4) != 0
        cancelEnabled = (bits & 2) != 0
        recordEnabled = (bits & 1) != 0
    }

    var focusToggleEnabled: Bool
    var toggleCameraEnabled: Bool
    var cancelEnabled: Bool
    var recordEnabled: Bool

    static var all = UIBits(0b1111)
    static var none = UIBits(0)
}

class CaptureViewController: UIViewController, AVCaptureFileOutputRecordingDelegate {

    enum State {
        case authorizingCapture
        case failedAuthorization

        case creatingSession
        case failedSessionCreation

        case switchingCameras

        case idle
        case recording
        case cancelling
        case finishing

        fileprivate var bits: UIBits {
            switch self {
            case .authorizingCapture: return .none
            case .failedAuthorization: return .none

            case .creatingSession: return .none
            case .failedSessionCreation: return .none

            case .switchingCameras: return .none

            case .idle: return .all
            case .recording: return UIBits(0b0011)
            case .cancelling: return .none
            case .finishing: return .none
            }
        }

        var isFailure: Bool? {
            switch self {
            case .authorizingCapture: return .none
            case .failedAuthorization: return true

            case .creatingSession: return .none
            case .failedSessionCreation: return true

            case .switchingCameras: return false

            case .idle: return false
            case .recording: return false
            case .cancelling: return false
            case .finishing: return false
            }
        }
    }

    @IBOutlet var previewView: CaptureVideoPreviewView!
    @IBOutlet var cameraUnavailableLabel: UILabel!
    @IBOutlet var loadingPanel: UIVisualEffectView!

    @IBOutlet var resumeButton: UIButton!
    @IBOutlet var cancelButton: UIButton!
    @IBOutlet var recordButton: UIButton!
    @IBOutlet var cameraButton: UIButton!
    @IBOutlet var focusToggleButton: UIButton!

    @IBOutlet var lensPositionSlider: UISlider!

    // MARK: Session management.

    // Communicate with the session and other session objects on this queue.
    var sessionQueue = DispatchQueue(label: "session queue")
    var session = AVCaptureSession()
    var videoDeviceInput: AVCaptureDeviceInput!
    var videoDevice: AVCaptureDevice!
    var movieFileOutput: AVCaptureMovieFileOutput?

    var currentState = State.authorizingCapture {
        didSet {
            precondition(Thread.isMainThread)
            updateUI(bits: currentState.bits)
        }
    }
    var isSessionRunning: Bool!
    var backgroundRecordingID: UIBackgroundTaskIdentifier!

    deinit {
        observing = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        self.focusToggleButton.isSelected = true
        self.lensPositionSlider.isHidden = true

        self.previewView.session = self.session

        // This has a side effect of disabling all the initial UI.
        self.currentState = .authorizingCapture

        // Check video authorization status. Video access is required and audio access is optional.
        // If audio access is denied, audio is not recorded during movie recording.
        switch AVCaptureDevice.authorizationStatus(forMediaType: AVMediaTypeVideo) {
        case .authorized:
            // The user has previously granted access to the camera.
            break
        case .notDetermined:
            // The user has not yet been presented with the option to grant video access.
            // We suspend the session queue to delay session setup until the access request has completed to avoid
            // asking the user for audio access if video access is denied.
            // Note that audio access will be implicitly requested when we create an AVCaptureDeviceInput for audio during session setup.
            self.sessionQueue.suspend()
            AVCaptureDevice.requestAccess(forMediaType: AVMediaTypeVideo) { granted in
                DispatchQueue.main.async {
                    if !granted {
                        self.currentState = .failedAuthorization
                    } else {
                        self.sessionQueue.resume()
                    }
                }
            }
            break
        default:
            // The user has previously denied access.
            self.currentState = .failedAuthorization
            break
        }

        // Setup the capture session.
        // In general it is not safe to mutate an AVCaptureSession or any of its inputs, outputs, or connections from multiple threads at the same time.
        // Why not do all of this on the main queue?
        // Because -[AVCaptureSession startRunning] is a blocking call which can take a long time. We dispatch session setup to the sessionQueue
        // so that the main queue isn't blocked, which keeps the UI responsive.
        self.sessionQueue.async {
            if self.currentState == .failedAuthorization {
                return
            }
            DispatchQueue.main.async {
                self.currentState = .creatingSession
            }

            self.backgroundRecordingID = UIBackgroundTaskInvalid

            let videoDevice = CaptureViewController.device(withMediaType: AVMediaTypeVideo, preferringPosition: .back)!

            self.session.beginConfiguration()
            defer {
                self.session.commitConfiguration()
            }

            guard let videoDeviceInput: AVCaptureDeviceInput = {
                do {
                    return try AVCaptureDeviceInput(device: videoDevice)
                }
                catch let error {
                    NSLog("Could not create video device input: \(error)")
                    return nil
                }
            }() else {
                DispatchQueue.main.async {
                    self.currentState = .failedSessionCreation
                }
                return
            }

            guard self.session.canAddInput(videoDeviceInput) else {
                NSLog("Could not add video device input to the session")
                DispatchQueue.main.async {
                    self.currentState = .failedSessionCreation
                }
                return
            }

            self.session.addInput(videoDeviceInput)
            self.videoDeviceInput = videoDeviceInput
            self.videoDevice = videoDevice

            videoDevice.setBestFormat()

            DispatchQueue.main.async {
                // Why are we dispatching this to the main queue?
                // Because AVCaptureVideoPreviewLayer is the backing layer for CaptureVideoPreviewView and UIView
                // can only be manipulated on the main thread.
                // Note: As an exception to the above rule, it is not necessary to serialize video orientation changes
                // on the AVCaptureVideoPreviewLayer’s connection with other session manipulation.

                // Use the status bar orientation as the initial video orientation. Subsequent orientation changes are handled by
                // -[viewWillTransitionToSize:withTransitionCoordinator:].
                let statusBarOrientation = UIApplication.shared.statusBarOrientation
                var initialVideoOrientation = AVCaptureVideoOrientation.portrait
                if  statusBarOrientation != .unknown {
                    initialVideoOrientation = AVCaptureVideoOrientation(interfaceOrientation: statusBarOrientation)
                }

                let previewLayer = self.previewView.layer
                previewLayer.connection.videoOrientation = initialVideoOrientation
            }

            let movieFileOutput = AVCaptureMovieFileOutput()
            guard self.session.canAddOutput(movieFileOutput) else {
                NSLog("Could not add movie file output to the session")
                DispatchQueue.main.async {
                    self.currentState = .failedSessionCreation
                }
                return
            }

            self.session.addOutput(movieFileOutput)
            let connection: AVCaptureConnection = movieFileOutput.connection(withMediaType: AVMediaTypeVideo)
            connection.preferredVideoStabilizationMode = .off // The less processing for this app, the better.
            self.movieFileOutput = movieFileOutput

            DispatchQueue.main.async {
                self.currentState = .idle
                self.configureManualHUD()
            }
        }
    }

    fileprivate func updateUI(bits: UIBits) {
        self.cancelButton.isEnabled = bits.cancelEnabled
        self.focusToggleButton.isEnabled = bits.focusToggleEnabled
        self.cameraButton.isEnabled = bits.toggleCameraEnabled
        self.recordButton.isEnabled = bits.recordEnabled
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        self.sessionQueue.async {
            switch self.currentState {
            case .failedAuthorization:
                DispatchQueue.main.async {
                    let message = NSLocalizedString("AVCamManual doesn't have permission to use the camera, please change privacy settings", comment: "Alert message when the user has denied access to the camera")
                    let alertController = UIAlertController(title: "AVCamManual", message: message, preferredStyle: .alert)
                    let cancelAction = UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler:nil)
                    alertController.addAction(cancelAction)
                    // Provide quick access to Settings.
                    let settingsAction = UIAlertAction(title: NSLocalizedString("Settings", comment: "Alert button to open Settings"), style: .default) { action in
                        let url = URL(string: UIApplicationOpenSettingsURLString)!
                        UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    }
                    alertController.addAction(settingsAction)
                    self.present(alertController, animated: true, completion: nil)
				}
            case .failedSessionCreation:
                DispatchQueue.main.async {
                    let message = NSLocalizedString("Unable to capture media", comment: "Alert message when something goes wrong during capture session configuration")
                    let alertController = UIAlertController(title: "AVCamManual", message: message, preferredStyle: .alert)
                    let cancelAction = UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil)
                    alertController.addAction(cancelAction)
                    self.present(alertController, animated: true, completion: nil)
                }
            default:
                precondition(self.currentState.isFailure != .some(true))
                // Only setup observers and start the session running if setup succeeded.
                self.observing = true
                self.session.startRunning()
                self.isSessionRunning = self.session.isRunning
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        self.sessionQueue.async {
            if self.currentState.isFailure == .some(false) {
                self.session.stopRunning()
                self.observing = false
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
        if UIDeviceOrientationIsPortrait(deviceOrientation) || UIDeviceOrientationIsLandscape(deviceOrientation) {
            let previewLayer = self.previewView.layer
            previewLayer.connection.videoOrientation = AVCaptureVideoOrientation(deviceOrientation: deviceOrientation)!
        }
    }

    // MARK: KVO and Notifications

    var observing: Bool = false {
        didSet {
            guard oldValue != observing else { return }
            if observing {
                _addObservers()
            } else {
                _removeObservers()
            }
        }
    }

    func _addObservers() {
        self.addObserver(self, forKeyPath: "session.running", options: .new, context: &Context.SessionRunning)

        self.addObserver(self, forKeyPath: "videoDevice.focusMode", options: [.old, .new], context: &Context.FocusMode)
        self.addObserver(self, forKeyPath: "videoDevice.lensPosition", options: .new, context: &Context.LensPosition)

        NotificationCenter.default.addObserver(self, selector: #selector(subjectAreaDidChange), name: NSNotification.Name.AVCaptureDeviceSubjectAreaDidChange, object: self.videoDevice)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError), name: NSNotification.Name.AVCaptureSessionRuntimeError, object: self.session)
        // A session can only run when the app is full screen. It will be interrupted in a multi-app layout, introduced in iOS 9,
        // see also the documentation of AVCaptureSessionInterruptionReason. Add observers to handle these session interruptions
        // and show a preview is paused message. See the documentation of AVCaptureSessionWasInterruptedNotification for other
        // interruption reasons.
        NotificationCenter.default.addObserver(self, selector: #selector(sessionWasInterrupted), name: NSNotification.Name.AVCaptureSessionWasInterrupted, object: self.session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded), name: NSNotification.Name.AVCaptureSessionInterruptionEnded,  object: self.session)
    }

    func _removeObservers() {
        NotificationCenter.default.removeObserver(self)

        removeObserver(self, forKeyPath: "session.running", context: &Context.SessionRunning)

        removeObserver(self, forKeyPath: "videoDevice.focusMode", context: &Context.FocusMode)
        removeObserver(self, forKeyPath: "videoDevice.lensPosition", context: &Context.LensPosition)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        let newValue = change?[.newKey]

        if context == &Context.FocusMode {
            //precondition(Thread.isMainThread)
            if let newMode = enumFromAny(AVCaptureFocusMode.init, newValue) {
                _ = newMode
                DispatchQueue.main.async { [weak self] in
                    guard let ss = self else { return }
                    let enabled = ss.isAutoFocusEnabled
                    ss.focusToggleButton.isSelected = enabled
                    ss.lensPositionSlider.isHidden = enabled
                }
            }
        }
        else if context == &Context.LensPosition {
            //precondition(Thread.isMainThread)
            if let newLensPosition = newValue as? Float {
                DispatchQueue.main.async { [weak self] in
                    guard let ss = self else { return }
                    if ss.videoDevice.focusMode != .locked {
                        ss.lensPositionSlider.value = newLensPosition
                    }
                }
            }
        }
        else if context == &Context.SessionRunning {
            // WARNING: does not run on main thread
            //dispatchPrecondition(condition: .onQueue(sessionQueue))
            
            let isRunning = (newValue as? NSNumber)?.boolValue ?? false

            DispatchQueue.main.async {
                let discoverySession = AVCaptureDeviceDiscoverySession(
                    deviceTypes: [.builtInWideAngleCamera],
                    mediaType: AVMediaTypeVideo,
                    position: .unspecified)
                let devices = discoverySession?.devices ?? []
                self.cameraButton.isEnabled = isRunning && devices.count > 1
                self.recordButton.isEnabled = isRunning
            }
        }
        else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    static var discoverySession: AVCaptureDeviceDiscoverySession {
        return AVCaptureDeviceDiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: AVMediaTypeVideo,
            position: .back)
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

        if reason == .audioDeviceInUseByAnotherClient ||
            reason == .videoDeviceInUseByAnotherClient {
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
            if let movieFileOutput = self.movieFileOutput,
                !movieFileOutput.isRecording {
                // Setup background task. This is needed because the -[captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:]
                // callback is not received until AVCamManual returns to the foreground unless you request background execution time.
                // This also ensures that there will be time to write the file to the photo library when AVCamManual is backgrounded.
                // To conclude this background execution, -endBackgroundTask is called in
                // -[captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:] after the recorded file has been saved.
                self.backgroundRecordingID = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)

                // Update the orientation on the movie file output video connection before starting recording.
                let movieConnection = movieFileOutput.connection(withMediaType: AVMediaTypeVideo)
                let previewLayer = self.previewView.layer 
                movieConnection?.videoOrientation = previewLayer.connection.videoOrientation

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
        //dismiss(animated: true, completion: nil)
        cancelButton.isEnabled = false
        recordButton.isEnabled = false
        loadingPanel.isHidden = false
        
        self.sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            if let tempFile = self?.movieFileOutput?.outputFileURL {
                try? FileManager.default.removeItem(at: tempFile)
            }
            DispatchQueue.main.async { [weak self] in
                self?.loadingPanel.isHidden = true
                self?.dismiss(animated: true, completion: nil)
            }
        }
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
                preferredPosition = .back
                break
            case .back:
                preferredPosition = .front
                break
            }

            let newVideoDevice = CaptureViewController.device(withMediaType: AVMediaTypeVideo, preferringPosition: preferredPosition)
            let newVideoDeviceInput = try? AVCaptureDeviceInput(device: newVideoDevice)

            self.session.beginConfiguration()

            // Remove the existing device input first, since using the front and back camera simultaneously is not supported.
            self.session.removeInput(self.videoDeviceInput)
            if self.session.canAddInput(newVideoDeviceInput) {
                NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVCaptureDeviceSubjectAreaDidChange, object: self.videoDevice)
                NotificationCenter.default.addObserver(self, selector: #selector(self.subjectAreaDidChange), name: NSNotification.Name.AVCaptureDeviceSubjectAreaDidChange, object: newVideoDevice)

                self.session.addInput(newVideoDeviceInput)
                self.videoDeviceInput = newVideoDeviceInput
                self.observing = false
                self.videoDevice = newVideoDevice
                self.observing = true
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
    func changeFocusMode(_ sender: AnyObject?) {
        let control = sender as! UIButton
        let mode = (!control.isSelected) ? AVCaptureFocusMode.continuousAutoFocus : .locked

        do {
            try self.videoDevice.lockForConfiguration()
            if self.videoDevice.isFocusModeSupported(mode) {
                self.videoDevice.focusMode = mode
            }
            self.videoDevice.unlockForConfiguration()
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

    // MARK: UI

    func configureManualHUD() {
        self.lensPositionSlider.minimumValue = 0.0
        self.lensPositionSlider.maximumValue = 1.0
        self.focusToggleButton.isSelected = isAutoFocusEnabled
        self.lensPositionSlider.isHidden = isAutoFocusEnabled
    }

    var isAutoFocusEnabled: Bool {
        if let videoDevice = videoDevice {
            if videoDevice.isFocusModeSupported(.continuousAutoFocus) {
                return videoDevice.focusMode == .continuousAutoFocus
            } else {
                return true
            }
        } else {
            return true
        }
    }

    // MARK: File Output Recording Delegate

    func capture(_ captureOutput: AVCaptureFileOutput, didStartRecordingToOutputFileAt fileURL: URL, fromConnections connections: [Any]) {
        // Enable the Record button to let the user stop the recording.
        DispatchQueue.main.async {
            self.recordButton.isEnabled = true
            self.recordButton.setTitle(NSLocalizedString("Done", comment: "Done recording video"), for: .normal)
        }
    }

    func capture(
        _ captureOutput: AVCaptureFileOutput!,
        didFinishRecordingToOutputFileAt outputFileURL: URL!,
        fromConnections connections: [Any]!,
        error: Error!
    ) {
        // Note that currentBackgroundRecordingID is used to end the background task associated with this recording.
        // This allows a new recording to be started, associated with a new UIBackgroundTaskIdentifier, once the movie file output's isRecording property
        // is back to NO — which happens sometime after this method returns.
        // Note: Since we use a unique file path for each recording, a new recording will not overwrite a recording currently being saved.
        let currentBackgroundRecordingID = self.backgroundRecordingID
        self.backgroundRecordingID = UIBackgroundTaskInvalid

        loadingPanel.isHidden = false

        func cleanup() {
            loadingPanel.isHidden = true
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
            var newLocalIdentifier: String?
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
                            let placeholder = changeRequest.placeholderForCreatedAsset!
                            newLocalIdentifier = placeholder.localIdentifier
                            let albumChangeRequest = PHAssetCollectionChangeRequest(for: assetCollection)
                            albumChangeRequest!.addAssets([placeholder] as NSArray)
                        }) { success, error in
                            if !success {
                                NSLog("Could not save movie to photo library: \(error)")
                            }
                            cleanup()

                            if let localIdentifier = newLocalIdentifier {
                                let results = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
                                if let firstAsset = results.firstObject {
                                    DispatchQueue.main.async {
                                        let model = VideoModel(asset: firstAsset)
                                        self.dismiss(animated: true, completion: nil)
                                        CaptureListViewController.live?.presentMarkViewController(for: model) {
                                        }
                                    }
                                }
                            }
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
            let devices = CaptureViewController.discoverySession.devices ?? []
            self.cameraButton.isEnabled = devices.count > 1
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
            defer {
                device.unlockForConfiguration()
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
        }
    }

    // MARK: Utilities

    static func device(withMediaType mediaType: String, preferringPosition position: AVCaptureDevicePosition) -> AVCaptureDevice? {
        let devices = AVCaptureDeviceDiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: AVMediaTypeVideo, position: .unspecified)?.devices ?? []
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
