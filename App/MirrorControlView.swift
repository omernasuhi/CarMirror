import ReplayKit
import SwiftUI
import UIKit

struct MirrorControlView: View {
    @ObservedObject private var state = MirrorState.shared
    @AppStorage(MirrorSettings.qualityKey, store: MirrorConfig.sharedDefaults)
    private var quality: MirrorQuality = .balanced
    @AppStorage(MirrorSettings.flipLandscapeKey, store: MirrorConfig.sharedDefaults)
    private var flipLandscape = false
    @State private var picker = BroadcastPicker()

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private var inAppMirroring: Binding<Bool> {
        Binding(
            get: { state.isInAppMirroring },
            set: { isOn in
                if isOn {
                    InAppMirror.shared.startOnPhoneWindow()
                } else {
                    InAppMirror.shared.stop()
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusRow("CarPlay", value: state.isCarPlayConnected ? "Bağlı" : "Bağlı değil", isOn: state.isCarPlayConnected)
                    statusRow("Ekran yayını", value: state.isBroadcasting ? "Aktif" : "Kapalı", isOn: state.isBroadcasting)
                    statusRow("Uygulama içi yansıtma", value: state.isInAppMirroring ? "Aktif" : "Kapalı", isOn: state.isInAppMirroring)
                }

                Section {
                    Button {
                        picker.present()
                    } label: {
                        Label(
                            state.isBroadcasting ? "Ekran Yayınını Durdur" : "Ekran Yayınını Başlat",
                            systemImage: state.isBroadcasting ? "stop.circle.fill" : "record.circle"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(state.isBroadcasting ? .red : .green)
                    .disabled(Self.isSimulator)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .background(BroadcastPickerHost(picker: picker).frame(width: 1, height: 1).opacity(0.01))
                } header: {
                    Text("Tüm iPhone ekranı")
                } footer: {
                    if Self.isSimulator {
                        Text("iOS simülatörü ekran yayınını desteklemez. Simülatörde aşağıdaki uygulama içi yansıtmayı kullanın.")
                    } else {
                        Text("Açılan pencerede CarMirror seçili olarak \"Start Broadcast\"a dokunun. Telefonda ne açarsanız araç ekranında görünür.")
                    }
                }

                Section {
                    Toggle("Uygulama içi yansıtma", isOn: inAppMirroring)
                } footer: {
                    Text("Yalnızca bu uygulamanın ekranını (Tarayıcı ve Demo sekmeleri dahil) yansıtır. Simülatörde CarPlay ekranında CarMirror açılınca kendiliğinden başlar.")
                }

                Section {
                    Picker("Görüntü kalitesi", selection: $quality) {
                        ForEach(MirrorQuality.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Toggle("Yatay görüntüyü ters çevir", isOn: $flipLandscape)
                } header: {
                    Text("Ayarlar")
                } footer: {
                    Text("Kalite ayarı ekran yayınında geçerlidir ve bir sonraki yayında uygulanır. Telefon yan çevrildiğinde araç ekranındaki görüntü baş aşağı görünüyorsa ters çevirme ayarını açın.")
                }

                Section {
                    step(1, "iPhone'u aracın CarPlay sistemine bağlayın.")
                    step(2, "Araç ekranında CarMirror uygulamasını açın.")
                    step(3, "Burada \"Ekran Yayınını Başlat\"a dokunup \"Start Broadcast\"e basın.")
                    step(4, "Artık telefonda açtığınız her şey araç ekranında görünür.")
                } header: {
                    Text("Nasıl kullanılır?")
                } footer: {
                    Text("DRM korumalı içerikler (ör. Netflix, Apple TV+) iOS tarafından ekran kaydına kapalıdır ve siyah görünür.")
                }

                Section {
                    Label("Araç hareket halindeyken video izlemeyin. Uygulamayı yalnızca park halindeyken kullanın.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
            .navigationTitle("CarMirror")
        }
    }

    private func statusRow(_ title: String, value: String, isOn: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Circle()
                .fill(isOn ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.green))
            Text(text)
        }
    }
}

/// Sistemin yayın penceresini ("Screen Broadcast" sayfası) açan
/// `RPSystemBroadcastPickerView`'u kendi düğmemizden tetikler.
final class BroadcastPicker {
    let view: RPSystemBroadcastPickerView = {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = MirrorConfig.broadcastExtensionBundleID
        picker.showsMicrophoneButton = false
        return picker
    }()

    func present() {
        guard let button = Self.findButton(in: view) else { return }
        button.sendActions(for: .allTouchEvents)
    }

    private static func findButton(in view: UIView) -> UIButton? {
        for subview in view.subviews {
            if let button = subview as? UIButton { return button }
            if let button = findButton(in: subview) { return button }
        }
        return nil
    }
}

/// Seçici görünümün pencere hiyerarşisinde bulunması için görünmez taşıyıcı.
struct BroadcastPickerHost: UIViewRepresentable {
    let picker: BroadcastPicker

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.isUserInteractionEnabled = false
        container.addSubview(picker.view)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
