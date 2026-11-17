import Foundation

/// Body zoom levels. The sidebar is native and is deliberately unaffected.
struct ZoomStore {

    static let defaultsKey = "QdownPageZoom"
    static let steps: [Double] = [0.5, 0.67, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var zoom: Double {
        get {
            let stored = defaults.double(forKey: Self.defaultsKey)
            guard stored > 0 else { return 1.0 }
            return min(max(stored, 0.5), 2.5)
        }
        set {
            defaults.set(min(max(newValue, 0.5), 2.5), forKey: Self.defaultsKey)
        }
    }

    func increased() -> Double {
        let current = zoom
        return Self.steps.first(where: { $0 > current + 0.001 }) ?? Self.steps.last ?? 2.5
    }

    func decreased() -> Double {
        let current = zoom
        return Self.steps.last(where: { $0 < current - 0.001 }) ?? Self.steps.first ?? 0.5
    }

    mutating func reset() {
        zoom = 1.0
    }
}
