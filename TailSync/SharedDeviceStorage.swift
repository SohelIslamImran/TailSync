import Foundation

enum SharedDeviceStorage {
    static let devicesKey = "taildropDevices"
    static let appGroupID = Bundle.main.object(forInfoDictionaryKey: "TailSyncAppGroupIdentifier") as? String ?? ""

    static var defaults: UserDefaults {
        guard !appGroupID.isEmpty else { return .standard }
        return UserDefaults(suiteName: appGroupID) ?? .standard
    }

    static func loadDevices(fallback: [TaildropDevice]) -> [TaildropDevice] {
        let stores = [defaults, UserDefaults.standard]
        for store in stores {
            guard let data = store.data(forKey: devicesKey),
                  let decoded = try? JSONDecoder().decode([TaildropDevice].self, from: data),
                  !decoded.isEmpty else {
                continue
            }
            return decoded
        }
        return fallback
    }

    static func saveDevices(_ devices: [TaildropDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        defaults.set(data, forKey: devicesKey)
        UserDefaults.standard.set(data, forKey: devicesKey)
    }
}
