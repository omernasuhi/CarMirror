import AVFoundation
import ImageIO
import UIKit

/// CarPlay penceresinin kök görünümü: telefon ekranının görüntüsünü çizer.
final class CarPlayMirrorViewController: UIViewController {
    let sink: DisplayLayerSink
    let displayView: MirrorDisplayView
    let placeholderLabel = UILabel()
    private(set) var orientation: CGImagePropertyOrientation = .up

    var fillsScreen: Bool {
        didSet {
            MirrorSettings.fillsCarScreen = fillsScreen
            displayView.displayLayer.videoGravity = fillsScreen ? .resizeAspectFill : .resizeAspect
        }
    }

    init() {
        let display = MirrorDisplayView()
        displayView = display
        sink = DisplayLayerSink(renderer: display.displayLayer.sampleBufferRenderer)
        fillsScreen = MirrorSettings.fillsCarScreen
        super.init(nibName: nil, bundle: nil)

        sink.onStreamActiveChange = { [weak self] isActive in
            self?.placeholderLabel.isHidden = isActive
        }
        sink.onOrientationChange = { [weak self] orientation in
            self?.apply(orientation: orientation)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) kullanılmıyor")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true

        displayView.backgroundColor = .black
        displayView.displayLayer.videoGravity = fillsScreen ? .resizeAspectFill : .resizeAspect
        view.addSubview(displayView)

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.text = "iPhone'da CarMirror'ı açıp\nyansıtmayı başlatın"
        placeholderLabel.textColor = UIColor(white: 1, alpha: 0.75)
        placeholderLabel.font = .preferredFont(forTextStyle: .title3)
        placeholderLabel.textAlignment = .center
        placeholderLabel.numberOfLines = 0
        view.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Telefon yan çevrildiğinde ReplayKit kareleri yine dikey gönderir ve
        // yönü ayrıca bildirir; görüntüyü burada döndürüyoruz.
        let bounds = view.bounds
        let quarterTurn = Self.isQuarterTurn(orientation)
        displayView.transform = .identity
        displayView.bounds = CGRect(
            origin: .zero,
            size: quarterTurn ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        )
        displayView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        displayView.transform = CGAffineTransform(
            rotationAngle: Self.rotationAngle(for: orientation, flipLandscape: MirrorSettings.flipLandscape)
        )
    }

    func apply(orientation: CGImagePropertyOrientation) {
        self.orientation = orientation
        view.setNeedsLayout()
    }

    @objc private func settingsDidChange() {
        DispatchQueue.main.async { self.view.setNeedsLayout() }
    }

    // MARK: - Yön

    static func isQuarterTurn(_ orientation: CGImagePropertyOrientation) -> Bool {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored: return true
        default: return false
        }
    }

    /// `CGImagePropertyOrientation` (EXIF) anlamına göre görüntüyü dik göstermek
    /// için gereken dönüş. UIKit'te pozitif açı saat yönündedir.
    static func rotationAngle(for orientation: CGImagePropertyOrientation, flipLandscape: Bool) -> CGFloat {
        var angle: CGFloat
        switch orientation {
        case .down, .downMirrored: angle = .pi
        case .right, .rightMirrored: angle = .pi / 2
        case .left, .leftMirrored: angle = -.pi / 2
        default: angle = 0
        }
        if flipLandscape && isQuarterTurn(orientation) {
            angle += .pi
        }
        return angle
    }
}
