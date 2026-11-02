import AVFoundation
import Combine
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
    private var refreshLink: CADisplayLink?
    private var refreshStart: DispatchWorkItem?
    private var refreshSubscriptions: [AnyCancellable] = []
    private var refreshScheduled = false
    private(set) var refreshTickCount = 0
    /// Simülatörde animasyon yenilemesi, CarPlay sahne kurulumunu yormamak için bu kadar gecikir.
    static let animationRefreshDelay: TimeInterval = 3

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

    deinit {
        refreshStart?.cancel()
        refreshLink?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true

        displayView.backgroundColor = .black
        displayView.displayLayer.videoGravity = fillsScreen ? .resizeAspectFill : .resizeAspect
        view.addSubview(displayView)

        // Görünüm yüklenmeden yayın başlamış olabilir; mevcut duruma göre kur.
        displayView.isHidden = !isShowingStream
        if !isShowingStream {
            attachAssistant()
        }

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
        startRefreshing()
    }

    private func detachAssistant() {
        guard assistantHost.parent != nil else { return }
        stopRefreshing()
        assistantHost.willMove(toParent: nil)
        assistantHost.view.removeFromSuperview()
        assistantHost.removeFromParent()
    }

    // MARK: - Araç ekranında SwiftUI'yi yenileme

    /// CarPlay penceresindeki SwiftUI görünümü ilk çizimden sonra kendiliğinden
    /// yenilenmiyor: SwiftUI çizimlerini pencerenin ekranına bağlı görüntü
    /// bağlantısıyla (display link) zamanlar ve simülatörün dış ekranında bu
    /// bağlantı tetiklenmiyor (gövde yeniden değerlendirilse bile ekran eski
    /// karede kalıyordu). Bu yüzden asistanın verisi değişince bir sonraki
    /// döngüde yerleşim istenir; SwiftUI bekleyen güncellemeyi o anda çizer.
    /// Simülatörde animasyonlar (orb, saat) için ayrıca düşük hızlı bir görüntü
    /// bağlantısı kullanılır; ana iş parçacığını yormamak için gecikmeli başlar.
    private func startRefreshing() {
        if refreshSubscriptions.isEmpty {
            let engine = AssistantEngine.shared
            let publishers: [AnyPublisher<Void, Never>] = [
                engine.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                engine.navigation.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                AssistantSettings.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            ]
            for publisher in publishers {
                publisher
                    .sink { [weak self] in self?.scheduleRefresh() }
                    .store(in: &refreshSubscriptions)
            }
        }
        #if targetEnvironment(simulator)
        guard refreshLink == nil, refreshStart == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.refreshStart != nil else { return }
            self.refreshStart = nil
            let link = CADisplayLink(target: RefreshTarget(controller: self), selector: #selector(RefreshTarget.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 15)
            link.add(to: .main, forMode: .common)
            self.refreshLink = link
        }
        refreshStart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.animationRefreshDelay, execute: work)
        #endif
    }

    func stopRefreshing() {
        refreshStart?.cancel()
        refreshStart = nil
        refreshLink?.invalidate()
        refreshLink = nil
        refreshSubscriptions.removeAll()
    }

    /// Bir döngüdeki veri değişikliklerini tek bir yerleşim geçişinde toplar;
    /// değişiklik işlendikten sonra çizer (objectWillChange değişimden önce gelir).
    private func scheduleRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.refreshScheduled else { return }
            self.refreshScheduled = true
            DispatchQueue.main.async {
                self.refreshScheduled = false
                self.refreshAssistant()
            }
        }
    }

    fileprivate func refreshAssistant() {
        guard assistantHost.parent != nil, assistantHost.view.window != nil else { return }
        refreshTickCount += 1
        assistantHost.view.setNeedsLayout()
        assistantHost.view.layoutIfNeeded()
    }

    /// CADisplayLink hedefini güçlü tutar; denetleyiciye zayıf başvuruyla döngü önlenir.
    private final class RefreshTarget: NSObject {
        weak var controller: CarPlayMirrorViewController?

        init(controller: CarPlayMirrorViewController) {
            self.controller = controller
        }

        @objc func tick() {
            controller?.refreshAssistant()
        }
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
