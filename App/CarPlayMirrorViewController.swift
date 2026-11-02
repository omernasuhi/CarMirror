import AVFoundation
import ImageIO
import SwiftUI
import UIKit

/// CarPlay penceresinin kök görünümü: yansıtma varken telefon ekranının
/// görüntüsünü, yokken asistan ekranını gösterir.
final class CarPlayMirrorViewController: UIViewController {
    let sink: DisplayLayerSink
    let displayView: MirrorDisplayView
    let assistantHost: UIHostingController<AssistantView>
    private(set) var isShowingStream = false
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
        assistantHost = UIHostingController(rootView: AssistantView(surface: .car, engine: .shared, settings: .shared))
        fillsScreen = MirrorSettings.fillsCarScreen
        super.init(nibName: nil, bundle: nil)

        sink.onStreamActiveChange = { [weak self] isActive in
            self?.setStreamVisible(isActive)
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

        displayView.isHidden = true
        attachAssistant()

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

    /// Yayın gelince asistan görünümü gizlenmez, hiyerarşiden çıkarılır: SwiftUI,
    /// `isHidden` ile gizlenen bir barındırma görünümünü güncellemeyi bırakır ve
    /// yeniden gösterildiğinde her zaman sürdürmez (CarPlay ekranı donuk kalıyordu).
    /// Pencereye geri eklenen görünüm ise güncel durumla yeniden çizilir.
    private func setStreamVisible(_ visible: Bool) {
        isShowingStream = visible
        displayView.isHidden = !visible
        if visible {
            detachAssistant()
            AssistantEngine.shared.surfaceDidDisappear(.car)
        } else {
            attachAssistant()
            AssistantEngine.shared.surfaceDidAppear(.car)
        }
    }

    /// Asistan görünümü pencere hiyerarşisinde mi?
    var isAssistantAttached: Bool { assistantHost.parent != nil }

    private func attachAssistant() {
        guard assistantHost.parent == nil else { return }
        addChild(assistantHost)
        assistantHost.view.frame = view.bounds
        assistantHost.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        assistantHost.view.backgroundColor = .black
        view.addSubview(assistantHost.view)
        assistantHost.didMove(toParent: self)
    }

    private func detachAssistant() {
        guard assistantHost.parent != nil else { return }
        assistantHost.willMove(toParent: nil)
        assistantHost.view.removeFromSuperview()
        assistantHost.removeFromParent()
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
