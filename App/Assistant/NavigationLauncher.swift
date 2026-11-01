import Foundation
import UIKit

/// Apple Haritalar'ı rota veya arama ile açar. CarPlay bağlıyken Haritalar
/// araç ekranında da açılır.
enum NavigationLauncher {
    static func directionsURL(to destination: String) -> URL? {
        var components = URLComponents()
        components.scheme = "maps"
        components.host = ""
        components.queryItems = [
            URLQueryItem(name: "daddr", value: destination),
            URLQueryItem(name: "dirflg", value: "d"),
        ]
        return components.url
    }

    static func searchURL(for query: String) -> URL? {
        var components = URLComponents()
        components.scheme = "maps"
        components.host = ""
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }

    static func startDirections(to destination: String) {
        guard let url = directionsURL(to: destination) else { return }
        open(url)
    }

    static func searchPlaces(_ query: String) {
        guard let url = searchURL(for: query) else { return }
        open(url)
    }

    private static func open(_ url: URL) {
        DispatchQueue.main.async {
            UIApplication.shared.open(url)
        }
    }
}
