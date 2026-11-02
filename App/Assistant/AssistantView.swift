import SwiftUI

/// Asistan ekranı. Telefonda sekme olarak, CarPlay'de pencerenin kendisi olarak gösterilir.
@MainActor
struct AssistantView: View {
    let surface: AssistantEngine.Surface

    @ObservedObject private var engine: AssistantEngine
    @ObservedObject private var settings: AssistantSettings
    @ObservedObject private var navigation: NavigationEngine
    @State private var showsSettings = false
    @State private var showsComposer = false
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    init(surface: AssistantEngine.Surface, engine: AssistantEngine, settings: AssistantSettings) {
        self.surface = surface
        self.engine = engine
        self.settings = settings
        navigation = engine.navigation
    }

    private var isCar: Bool { surface == .car }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let landscape = size.width > size.height * 1.15
            ZStack {
                if navigation.isActive && landscape {
                    navigationLayout(size: size)
                } else {
                    AssistantBackdrop(tint: tint)
                    if landscape {
                        landscapeLayout(size: size)
                    } else {
                        portraitLayout(size: size)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea(isCar ? .all : [])
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear { engine.surfaceDidAppear(surface) }
        .onDisappear { engine.surfaceDidDisappear(surface) }
        .sheet(isPresented: $showsSettings) {
            AssistantSettingsView(settings: settings, engine: engine)
        }
    }

    // MARK: - Yerleşimler

    private func landscapeLayout(size: CGSize) -> some View {
        let unit = size.height / 240
        return HStack(spacing: 0) {
            core(diameter: size.height * 0.78)
                .frame(width: size.height * 0.92)
            VStack(alignment: .leading, spacing: 6 * unit) {
                header(unit: unit)
                captions(unit: unit, maxLines: 5)
                Spacer(minLength: 0)
                Text(hint)
                    .font(.system(size: 9 * unit, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.trailing, 14 * unit)
            .padding(.vertical, 14 * unit)
        }
    }

    /// Navigasyon sırasında araç ekranı: harita tam ekran, asistan sağ altta küçük.
    /// CarPlay'in manevra kartı sol üstte, varış paneli sol altta görünür.
    private func navigationLayout(size: CGSize) -> some View {
        let unit = size.height / 240
        return ZStack(alignment: .bottomTrailing) {
            NavigationMapView(navigation: navigation)
                .ignoresSafeArea()
            if NavigationEngine.drawsOwnManeuverCards {
                ManeuverCards(navigation: navigation, unit: unit)
            }
            VStack(alignment: .trailing, spacing: 6 * unit) {
                core(diameter: size.height * 0.34)
                    .background(Circle().fill(Color.black.opacity(0.45)).padding(-6 * unit))
                NavigationStatusLine(navigation: navigation, unit: unit)
                if !assistantLine.isEmpty {
                    Text(assistantLine)
                        .font(.system(size: 10.5 * unit, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, 10 * unit)
                        .padding(.vertical, 6 * unit)
                        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10 * unit))
                        .frame(maxWidth: size.width * 0.5, alignment: .trailing)
                }
            }
            .padding(12 * unit)
        }
    }

    private func portraitLayout(size: CGSize) -> some View {
        let unit = min(size.width, 430) / 390
        let orbDiameter = navigation.isActive
            ? min(size.width * 0.42, size.height * 0.2)
            : min(size.width * 0.72, size.height * 0.38)
        return VStack(spacing: 0) {
            header(unit: unit * 1.5)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 18 * unit)
            if navigation.isActive {
                NavigationMapView(navigation: navigation)
                    .frame(height: size.height * 0.32)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(alignment: .bottomLeading) {
                        NavigationStatusLine(navigation: navigation, unit: unit * 1.2)
                            .padding(10)
                    }
                    .padding(.horizontal, 16 * unit)
                    .padding(.top, 12 * unit)
            }
            Spacer(minLength: 8)
            core(diameter: orbDiameter)
            Text(hint)
                .font(.system(size: 13 * unit, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 10 * unit)
            Spacer(minLength: 8)
            captions(unit: unit * 1.5, maxLines: 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24 * unit)
            if showsComposer {
                composer(unit: unit)
                    .padding(.horizontal, 20 * unit)
                    .padding(.top, 10 * unit)
            }
            controls(unit: unit)
                .padding(.vertical, 16 * unit)
        }
    }

    // MARK: - Parçalar

    private func core(diameter: CGFloat) -> some View {
        AssistantCoreView(state: engine.state, level: engine.level, tint: tint)
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .onTapGesture { engine.toggleListening() }
            .accessibilityLabel("Asistan")
            .accessibilityHint("Konuşmak için dokunun")
    }

    private func header(unit: CGFloat) -> some View {
        VStack(alignment: isCar ? .leading : .center, spacing: 3 * unit) {
            Text(settings.effectiveAssistantName.uppercased(with: Locale(identifier: "tr")))
                .font(.system(size: 17 * unit, weight: .semibold, design: .rounded))
                .tracking(4 * unit)
                .foregroundStyle(.white)
            HStack(spacing: 5 * unit) {
                Circle()
                    .fill(tint)
                    .frame(width: 5 * unit, height: 5 * unit)
                    .shadow(color: tint, radius: 3 * unit)
                Text(statusLabel)
                    .font(.system(size: 9.5 * unit, weight: .semibold, design: .rounded))
                    .tracking(1.5 * unit)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute())
                    .font(.system(size: 9.5 * unit, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
    }

    private func captions(unit: CGFloat, maxLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 6 * unit) {
            if let user = lastUserLine {
                Text(user)
                    .font(.system(size: 10.5 * unit, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
            }
            if !assistantLine.isEmpty {
                Text(assistantLine)
                    .font(.system(size: 12.5 * unit, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(maxLines)
                    .animation(.easeOut(duration: 0.2), value: assistantLine)
            }
            if let message = engine.statusMessage {
                Text(message)
                    .font(.system(size: 9 * unit, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.45))
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func controls(unit: CGFloat) -> some View {
        HStack(spacing: 36 * unit) {
            Button {
                showsSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 20 * unit))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 48 * unit, height: 48 * unit)
            }
            .accessibilityLabel("Ayarlar")

            Button {
                engine.toggleListening()
            } label: {
                ZStack {
                    Circle()
                        .fill(tint.opacity(engine.state == .listening ? 0.9 : 0.18))
                        .frame(width: 70 * unit, height: 70 * unit)
                        .shadow(color: tint.opacity(0.6), radius: engine.state == .listening ? 14 : 4)
                    Image(systemName: engine.state == .listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 26 * unit, weight: .semibold))
                        .foregroundStyle(engine.state == .listening ? .black : tint)
                }
            }
            .accessibilityLabel(engine.state == .listening ? "Dinlemeyi durdur" : "Konuş")

            Button {
                showsComposer.toggle()
                composerFocused = showsComposer
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 20 * unit))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 48 * unit, height: 48 * unit)
            }
            .accessibilityLabel("Yazarak sor")
        }
    }

    private func composer(unit: CGFloat) -> some View {
        HStack(spacing: 10 * unit) {
            TextField("Yazın… (ör. Kadıköy'e gidelim)", text: $draft)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 14 * unit)
                .padding(.vertical, 10 * unit)
                .background(Color.white.opacity(0.08), in: Capsule())
                .foregroundStyle(.white)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30 * unit))
                    .foregroundStyle(tint)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Gönder")
        }
    }

    private func send() {
        let text = draft
        draft = ""
        engine.submit(text: text)
    }

    // MARK: - Türetilmiş metinler

    private var tint: Color { AssistantPalette.tint(for: engine.state) }

    private var statusLabel: String {
        switch engine.state {
        case .idle: return settings.isAIConfigured ? "HAZIR" : "ANAHTAR YOK"
        case .greeting, .speaking: return "KONUŞUYOR"
        case .listening: return "DİNLİYORUM"
        case .thinking: return "DÜŞÜNÜYORUM"
        }
    }

    private var hint: String {
        if engine.isDemoMode { return "Demo modu" }
        switch engine.state {
        case .listening: return "Durdurmak için dokunun"
        case .speaking, .greeting: return "Sözünü kesmek için dokunun"
        case .thinking: return "Cevap hazırlanıyor…"
        case .idle: return "Konuşmak için dokunun"
        }
    }

    private var lastUserLine: String? {
        if engine.state == .listening {
            return engine.transcript.isEmpty ? "…" : engine.transcript
        }
        return engine.entries.last(where: { $0.role == .user })?.text
    }

    private var assistantLine: String {
        if engine.state == .listening { return "" }
        if !engine.reply.isEmpty { return engine.reply }
        return engine.entries.last(where: { $0.role == .assistant })?.text ?? ""
    }
}

enum AssistantPalette {
    static func tint(for state: AssistantEngine.State) -> Color {
        switch state {
        case .idle: return Color(red: 0.35, green: 0.78, blue: 0.95)
        case .listening: return Color(red: 0.25, green: 0.88, blue: 1.0)
        case .thinking: return Color(red: 0.68, green: 0.58, blue: 1.0)
        case .speaking, .greeting: return Color(red: 1.0, green: 0.78, blue: 0.38)
        }
    }
}

/// Koyu lacivert zemin, hafif ızgara ve kenarlarda vinyet.
struct AssistantBackdrop: View {
    var tint: Color

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color(red: 0.04, green: 0.09, blue: 0.16), Color.black],
                center: .center,
                startRadius: 0,
                endRadius: 600
            )
            Canvas { context, size in
                let step: CGFloat = 28
                var grid = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                    x += step
                }
                var y: CGFloat = 0
                while y <= size.height {
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    y += step
                }
                context.stroke(grid, with: .color(tint.opacity(0.06)), lineWidth: 0.5)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: tint)
    }
}

/// Ortadaki canlı çekirdek: dönen halkalar, sese tepki veren çubuklar ve parlayan merkez.
struct AssistantCoreView: View {
    var state: AssistantEngine.State
    var level: Float
    var tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                draw(in: context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func draw(in context: GraphicsContext, size: CGSize, time t: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        let activity = Double(min(1, max(0, level)))
        let isSpeaking = state == .speaking || state == .greeting
        let isListening = state == .listening
        let isThinking = state == .thinking

        // Parlama
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: radius * 0.16))
            let pulse = isSpeaking ? 0.05 * (1 + sin(t * 6)) : 0
            let glowRadius = radius * CGFloat(0.5 + 0.12 * activity + pulse)
            layer.fill(Path(ellipseIn: Self.rect(center, glowRadius)), with: .color(tint.opacity(0.4)))
        }

        // Dış halka ve kadran çizgileri
        let outer = radius * 0.96
        var ticks = Path()
        for index in 0..<72 {
            let angle = Double(index) / 72 * 2 * .pi + t * 0.08
            let inner = index % 6 == 0 ? outer * 0.92 : outer * 0.962
            ticks.move(to: Self.point(center, inner, angle))
            ticks.addLine(to: Self.point(center, outer, angle))
        }
        context.stroke(ticks, with: .color(tint.opacity(0.5)), lineWidth: max(1, radius * 0.008))
        context.stroke(Path(ellipseIn: Self.rect(center, outer)), with: .color(tint.opacity(0.2)), lineWidth: 1)

        // Ters yönde dönen üç yay
        let arcRadius = radius * 0.84
        let arcSpeed = isThinking ? 1.8 : 0.35
        for index in 0..<3 {
            let start = -t * arcSpeed + Double(index) * 2 * .pi / 3
            var arc = Path()
            arc.addArc(center: center, radius: arcRadius, startAngle: .radians(start), endAngle: .radians(start + 0.9), clockwise: false)
            context.stroke(arc, with: .color(tint.opacity(0.9)), style: StrokeStyle(lineWidth: max(1.5, radius * 0.02), lineCap: .round))
        }

        // Sese tepki veren çubuklar
        let barCount = 64
        let innerRadius = radius * 0.5
        let maxLength = radius * 0.24
        var bars = Path()
        for index in 0..<barCount {
            let angle = Double(index) / Double(barCount) * 2 * .pi - .pi / 2
            let i = Double(index)
            let wave: Double
            if isSpeaking {
                let envelope = max(activity, 0.35 + 0.35 * sin(t * 3.1 + i * 0.2))
                wave = 0.3 + 0.7 * abs(sin(t * 7 + i * 0.55)) * (0.4 + 0.6 * envelope)
            } else if isListening {
                wave = 0.15 + activity * (0.55 + 0.45 * abs(sin(i * 0.9 + t * 4)))
            } else if isThinking {
                wave = 0.2 + 0.2 * abs(sin(t * 5 + i * 0.3))
            } else {
                wave = 0.12 + 0.06 * sin(t * 1.5 + i * 0.4)
            }
            let length = maxLength * CGFloat(min(1, max(0, wave)))
            bars.move(to: Self.point(center, innerRadius, angle))
            bars.addLine(to: Self.point(center, innerRadius + length, angle))
        }
        context.stroke(bars, with: .color(tint.opacity(0.85)), style: StrokeStyle(lineWidth: max(1.5, radius * 0.022), lineCap: .round))

        // Merkez
        let breathe = 1 + 0.03 * sin(t * 2) + 0.12 * activity * (isListening ? 1 : 0.5)
        let coreRadius = radius * 0.36 * CGFloat(breathe)
        let gradient = Gradient(colors: [Color.white.opacity(0.95), tint, tint.opacity(0.05)])
        context.fill(
            Path(ellipseIn: Self.rect(center, coreRadius)),
            with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: coreRadius)
        )
        context.stroke(Path(ellipseIn: Self.rect(center, coreRadius)), with: .color(Color.white.opacity(0.6)), lineWidth: max(1, radius * 0.01))
    }

    private static func point(_ center: CGPoint, _ radius: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
    }

    private static func rect(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}

/// Simülatörde CarPlay'in kendi manevra kartı yerine çizilen kart ve varış paneli.
struct ManeuverCards: View {
    @ObservedObject var navigation: NavigationEngine
    var unit: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * unit) {
            if let maneuver = navigation.upcomingManeuver {
                HStack(spacing: 8 * unit) {
                    Image(systemName: ManeuverCards.symbol(for: maneuver.instruction))
                        .font(.system(size: 22 * unit, weight: .bold))
                    VStack(alignment: .leading, spacing: 2 * unit) {
                        Text(NavigationFormat.distance(maneuver.distance))
                            .font(.system(size: 16 * unit, weight: .bold, design: .rounded))
                        Text(maneuver.instruction)
                            .font(.system(size: 11 * unit, weight: .semibold, design: .rounded))
                            .lineLimit(2)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12 * unit)
                .padding(.vertical, 8 * unit)
                .background(Color(red: 0.1, green: 0.45, blue: 0.95), in: RoundedRectangle(cornerRadius: 14 * unit))
                .frame(maxWidth: 190 * unit, alignment: .leading)
            }
            Spacer()
            if let progress = navigation.progress {
                HStack(spacing: 14 * unit) {
                    estimate(NavigationFormat.clock(progress.eta), "varış")
                    estimate(NavigationFormat.duration(progress.remainingTime), "kalan")
                    estimate(NavigationFormat.distance(progress.remainingDistance), "mesafe")
                }
                .padding(.horizontal, 12 * unit)
                .padding(.vertical, 8 * unit)
                .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14 * unit))
            }
        }
        .padding(12 * unit)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func estimate(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1 * unit) {
            Text(value)
                .font(.system(size: 12 * unit, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 8 * unit, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    static func symbol(for instructions: String) -> String {
        let text = instructions.lowercased()
        if text.contains("u-turn") || text.contains("u dönüşü") { return "arrow.uturn.left" }
        if text.contains("right") || text.contains("sağ") { return "arrow.turn.up.right" }
        if text.contains("left") || text.contains("sol") { return "arrow.turn.up.left" }
        if text.contains("hedef") || text.contains("arrive") || text.contains("destination") { return "flag.checkered" }
        return "arrow.up"
    }
}
