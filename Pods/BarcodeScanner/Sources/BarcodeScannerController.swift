import UIKit
import AVFoundation

// MARK: - Delegates

/// Delegate to handle the captured code.
public protocol BarcodeScannerCodeDelegate: class {
  func barcodeScanner(_ controller: BarcodeScannerController, didCaptureCode code: String, type: String)
}

/// Delegate to report errors.
public protocol BarcodeScannerErrorDelegate: class {
  func barcodeScanner(_ controller: BarcodeScannerController, didReceiveError error: Error)
}

/// Delegate to dismiss barcode scanner when the close button has been pressed.
public protocol BarcodeScannerDismissalDelegate: class {
  func barcodeScannerDidDismiss(_ controller: BarcodeScannerController)
}

// MARK: - Controller

/**
 Barcode scanner controller with 4 sates:
 - Scanning mode
 - Processing animation
 - Unauthorized mode
 - Not found error message
 */
open class BarcodeScannerController: UIViewController {

  /// Video capture device.
  lazy var captureDevice: AVCaptureDevice = AVCaptureDevice.defaultDevice(withMediaType: AVMediaTypeVideo)

  /// Capture session.
  lazy var captureSession: AVCaptureSession = AVCaptureSession()

  /// Header view with title and close button.
  lazy var headerView: HeaderView = HeaderView()

  /// Information view with description label.
  lazy var infoView: InfoView = InfoView()

  /// Button to change torch mode.
  lazy var flashButton: UIButton = { [unowned self] in
    let button = UIButton(type: .custom)
    button.addTarget(self, action: #selector(flashButtonDidPress), for: .touchUpInside)

    return button
    }()

  /// Animated focus view.
  lazy var focusView: UIView = {
    let view = UIView()
    view.layer.borderColor = UIColor.white.cgColor
    view.layer.borderWidth = 2
    view.layer.cornerRadius = 5
    view.layer.shadowColor = UIColor.white.cgColor
    view.layer.shadowRadius = 10.0
    view.layer.shadowOpacity = 0.9
    view.layer.shadowOffset = CGSize.zero
    view.layer.masksToBounds = false

    return view
  }()

  /// Button that opens settings to allow camera usage.
  lazy var settingsButton: UIButton = { [unowned self] in
    let button = UIButton(type: .system)
    let title = NSAttributedString(string: SettingsButton.text,
      attributes: [
        NSFontAttributeName : SettingsButton.font,
        NSForegroundColorAttributeName : SettingsButton.color,
      ])

    button.setAttributedTitle(title, for: UIControlState())
    button.sizeToFit()
    button.addTarget(self, action: #selector(settingsButtonDidPress), for: .touchUpInside)

    return button
    }()

  /// Video preview layer.
  var videoPreviewLayer: AVCaptureVideoPreviewLayer?

  /// The current controller's status mode.
  var status: Status = Status(state: .scanning) {
    didSet {
      let duration = status.animated &&
        (status.state == .processing
          || oldValue.state == .processing
          || oldValue.state == .notFound
        ) ? 0.5 : 0.0

      guard status.state != .notFound else {
        infoView.status = status

        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 2.0) {
          self.status = Status(state: .scanning)
        }

        return
      }

      let delayReset = oldValue.state == .processing || oldValue.state == .notFound

      if !delayReset {
        resetState()
      }

      UIView.animate(withDuration: duration,
        animations: {
          self.infoView.frame = self.infoFrame
          self.infoView.status = self.status
        },
        completion: { _ in
          if delayReset {
            self.resetState()
          }

          self.infoView.layer.removeAllAnimations()
          if self.status.state == .processing {
            self.infoView.animateLoading()
          }
      })
    }
  }
    
  public var barCodeFocusViewType: FocusViewType = .animated

  /// The current torch mode on the capture device.
  var torchMode: TorchMode = .off {
    didSet {
      guard captureDevice.hasFlash else { return }

      do {
        try captureDevice.lockForConfiguration()
        captureDevice.torchMode = torchMode.captureTorchMode
        captureDevice.unlockForConfiguration()
      } catch {}

      flashButton.setImage(torchMode.image, for: UIControlState())
    }
  }

  /// Calculated frame for the info view.
  var infoFrame: CGRect {
    let height = status.state != .processing ? 75 : view.bounds.height
    return CGRect(x: 0, y: view.bounds.height - height,
      width: view.bounds.width, height: height)
  }

  /// When the flag is set to `true` controller returns a captured code
  /// and waits for the next reset action.
  public var isOneTimeSearch = true

  /// Delegate to handle the captured code.
  public weak var codeDelegate: BarcodeScannerCodeDelegate?

  /// Delegate to report errors.
  public weak var errorDelegate: BarcodeScannerErrorDelegate?

  /// Delegate to dismiss barcode scanner when the close button has been pressed.
  public weak var dismissalDelegate: BarcodeScannerDismissalDelegate?

  /// Flag to lock session from capturing.
  var locked = false

  // MARK: - Initialization

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - View lifecycle

  open override func viewDidLoad() {
    super.viewDidLoad()

    videoPreviewLayer = AVCaptureVideoPreviewLayer(session: self.captureSession)
    videoPreviewLayer?.videoGravity = AVLayerVideoGravityResizeAspectFill

    view.backgroundColor = UIColor.black

    guard let videoPreviewLayer = videoPreviewLayer else {
      return
    }

    view.layer.addSublayer(videoPreviewLayer)

    [infoView, headerView, settingsButton, flashButton, focusView].forEach {
      view.addSubview($0)
      view.bringSubview(toFront: $0)
    }

    torchMode = .off
    focusView.isHidden = true
    headerView.delegate = self

    setupCamera()

    NotificationCenter.default.addObserver(
      self, selector: #selector(appWillEnterForeground),
      name: NSNotification.Name.UIApplicationWillEnterForeground,
      object: nil)
  }
  
  open override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    
    headerView.isHidden = !isBeingPresented
  }
  
  open override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    animateFocusView()
  }
  
  open override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
    super.viewWillTransition(to: size, with: coordinator)
    coordinator.animate(alongsideTransition: { (context) in
      self.setupFrame()
    }) { (context) in
      self.focusView.layer.removeAllAnimations()
      self.animateFocusView()
    }
  }

  /**
   `UIApplicationWillEnterForegroundNotification` action.
   */
  func appWillEnterForeground() {
    torchMode = .off
    animateFocusView()
  }

  // MARK: - Configuration

  /**
   Sets up camera and checks for camera permissions.
   */
  func setupCamera() {
    let authorizationStatus = AVCaptureDevice.authorizationStatus(forMediaType: AVMediaTypeVideo)

    if authorizationStatus == .authorized {
      setupSession()
      status = Status(state: .scanning)
    } else if authorizationStatus == .notDetermined {
      AVCaptureDevice.requestAccess(forMediaType: AVMediaTypeVideo,
        completionHandler: { (granted: Bool) -> Void in
          DispatchQueue.main.async {
            if granted {
              self.setupSession()
            }

            self.status = granted ? Status(state: .scanning) : Status(state: .unauthorized)
          }
      })
    } else {
      status = Status(state: .unauthorized)
    }
  }

  /**
   Sets up capture input, output and session.
   */
  func setupSession() {
    do {
      let input = try AVCaptureDeviceInput(device: captureDevice)
      captureSession.addInput(input)
    } catch {
      errorDelegate?.barcodeScanner(self, didReceiveError: error)
    }

    let output = AVCaptureMetadataOutput()
    captureSession.addOutput(output)
    output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
    output.metadataObjectTypes = metadata
    videoPreviewLayer?.session = captureSession

    view.setNeedsLayout()
  }

  // MARK: - Reset

  /**
   Shows error message and goes back to the scanning mode.

   - Parameter errorMessage: Error message that overrides the message from the config.
   */
  public func resetWithError(message: String? = nil) {
    status = Status(state: .notFound, text: message)
  }

  /**
   Resets the controller to the scanning mode.

   - Parameter animated: Flag to show scanner with or without animation.
   */
  public func reset(animated: Bool = true) {
    status = Status(state: .scanning, animated: animated)
  }

  /**
   Resets the current state.
   */
  func resetState() {
    let alpha: CGFloat = status.state == .scanning ? 1 : 0

    torchMode = .off
    locked = status.state == .processing && isOneTimeSearch

    status.state == .scanning
      ? captureSession.startRunning()
      : captureSession.stopRunning()

    focusView.alpha = alpha
    flashButton.alpha = alpha
    settingsButton.isHidden = status.state != .unauthorized
  }

  // MARK: - Layout
  func setupFrame() {
    headerView.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: 64)
    flashButton.frame = CGRect(x: view.frame.width - 50, y: 73, width: 37, height: 37)
    infoView.frame = infoFrame

    if let videoPreviewLayer = videoPreviewLayer {
      videoPreviewLayer.frame = view.layer.bounds
      if let connection = videoPreviewLayer.connection, connection.isVideoOrientationSupported {
        switch (UIApplication.shared.statusBarOrientation) {
        case .portrait: connection.videoOrientation = .portrait
        case .landscapeRight: connection.videoOrientation = .landscapeRight
        case .landscapeLeft: connection.videoOrientation = .landscapeLeft
        case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
        default: connection.videoOrientation = .portrait
        }
      }
    }

    if barCodeFocusViewType == .oneDimension {
        center(subview: focusView, inSize: CGSize(width: 280, height: 80))
    } else {
        center(subview: focusView, inSize: CGSize(width: 218, height: 150))
    }
    center(subview: settingsButton, inSize: CGSize(width: 150, height: 50))

    headerView.isHidden = !isBeingPresented
  }

  /**
   Sets a new size and center aligns subview's position.

   - Parameter subview: The subview.
   - Parameter size: A new size.
  */
  func center(subview: UIView, inSize size: CGSize) {
    subview.frame = CGRect(
      x: (view.frame.width - size.width) / 2,
      y: (view.frame.height - size.height) / 2,
      width: size.width,
      height: size.height)
  }

  // MARK: - Animations

  /**
   Simulates flash animation.

   - Parameter processing: Flag to set the current state to `.Processing`.
   */
  func animateFlash(whenProcessing: Bool = false) {
    let flashView = UIView(frame: view.bounds)
    flashView.backgroundColor = UIColor.white
    flashView.alpha = 1

    view.addSubview(flashView)
    view.bringSubview(toFront: flashView)

    UIView.animate(withDuration: 0.2,
      animations: {
        flashView.alpha = 0.0
      },
      completion: { _ in
        flashView.removeFromSuperview()

        if whenProcessing {
          self.status = Status(state: .processing)
        }
    })
  }

  /**
   Performs focus view animation.
   */
  func animateFocusView() {
    focusView.layer.removeAllAnimations()
    focusView.isHidden = false
    
    setupFrame()
    
    if barCodeFocusViewType == .animated {
        UIView.animate(withDuration: 1.0, delay:0,
              options: [.repeat, .autoreverse, .beginFromCurrentState],
              animations: {
                self.center(subview: self.focusView, inSize: CGSize(width: 280, height: 80))
              }, completion: nil)
        }
        view.setNeedsLayout()
  }

  // MARK: - Actions

  /**
   Opens setting to allow camera usage.
   */
  func settingsButtonDidPress() {
    DispatchQueue.main.async {
      if let settingsURL = URL(string: UIApplicationOpenSettingsURLString) {
        UIApplication.shared.openURL(settingsURL)
      }
    }
  }

  /**
   Sets the next torch mode.
   */
  func flashButtonDidPress() {
    torchMode = torchMode.next
  }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate

extension BarcodeScannerController: AVCaptureMetadataOutputObjectsDelegate {

  public func captureOutput(_ captureOutput: AVCaptureOutput!,
                            didOutputMetadataObjects metadataObjects: [Any]!,
                            from connection: AVCaptureConnection!) {
    guard !locked else { return }
    guard metadataObjects != nil && !metadataObjects.isEmpty else { return }

    guard
      let metadataObj = metadataObjects[0] as? AVMetadataMachineReadableCodeObject,
      var code = metadataObj.stringValue,
      metadata.contains(metadataObj.type)
      else { return }

    if isOneTimeSearch {
      locked = true
    }
    // See: https://stackoverflow.com/questions/22767584/ios7-barcode-scanner-api-adds-a-zero-to-upca-barcode-format
    if metadataObj.type == AVMetadataObjectTypeEAN13Code && code.hasPrefix("0"){
      let index = code.index(code.startIndex, offsetBy: 1)
      code = code.substring(from: index)
    }

    animateFlash(whenProcessing: isOneTimeSearch)
    codeDelegate?.barcodeScanner(self, didCaptureCode: code, type: metadataObj.type)
  }
}

// MARK: - HeaderViewDelegate

extension BarcodeScannerController: HeaderViewDelegate {

  func headerViewDidPressClose(_ headerView: HeaderView) {
    dismissalDelegate?.barcodeScannerDidDismiss(self)
  }
}
