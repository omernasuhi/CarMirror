import SwiftUI

/// Yansıtmanın canlı çalıştığını araç ekranında görmek için hareketli test ekranı.
struct DemoView: View {
    private static let barColors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple]

    var body: some View {
        TimelineView(.animation) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            VStack(spacing: 28) {
                Text("CARMIRROR DEMO")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))

                Text(Self.clockText(for: context.date))
                    .font(.system(size: 44, weight: .bold, design: .monospaced))

                ZStack {
                    RoundedRectangle(cornerRadius: 32)
                        .fill(AngularGradient(colors: Self.barColors + [.red], center: .center))
                        .frame(width: 180, height: 180)
                        .rotationEffect(.degrees(seconds.truncatingRemainder(dividingBy: 4) * 90))
                    Image(systemName: "car.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.white)
                }

                HStack(spacing: 0) {
                    ForEach(Self.barColors, id: \.self) { color in
                        color
                    }
                }
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Text("Bu ekran araç ekranında görünüyorsa yansıtma çalışıyor.")
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func clockText(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        return String(
            format: "%02d:%02d:%02d.%d",
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0,
            (parts.nanosecond ?? 0) / 100_000_000
        )
    }
}
