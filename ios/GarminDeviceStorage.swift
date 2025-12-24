import Foundation
import ConnectIQ

@objc(GarminDeviceStorage)
public class GarminDeviceStorage: NSObject {
    static var urlScheme = "retic"
    static var appId = "bd8df375-4ed5-4ff3-bcf4-b752426e1628"
    static var devicesListKey = "devicesListKey"

    // IMPORTANT: IQDevice objects are SESSION-BASED and cannot be persisted!
    // Only devices from the CURRENT session's parseDeviceSelectionResponse are valid.
    // This cache holds live IQDevice objects from the current app session only.
    private static var sessionDevices: [String: IQDevice] = [:]

    @objc
    public static func onDevicesReceived(open url: URL) {
        print("[Garmin] URL received: \(url.absoluteString)")
        print("[Garmin] URL scheme: \(url.scheme ?? "nil"), expected: \(urlScheme)")
        print("[Garmin] URL host: \(url.host ?? "nil")")
        print("[Garmin] URL path: \(url.path)")
        print("[Garmin] URL query: \(url.query ?? "nil")")

        // Check if this is the device selection response from GCM
        let isDeviceSelectResp = url.path == "/device-select-resp" ||
                                  url.host == "device-select-resp" ||
                                  (url.query?.contains("devices") ?? false)

        guard url.scheme == urlScheme && isDeviceSelectResp else {
            print("[Garmin] Not a device selection response, ignoring")
            return
        }

        print("[Garmin] Processing device selection response...")

        // Parse fresh IQDevice objects from GCM - these are the ONLY valid device references
        let devices = ConnectIQ.sharedInstance()?.parseDeviceSelectionResponse(from: url) as? [IQDevice]
        print("[Garmin] Parsed \(devices?.count ?? 0) fresh devices from GCM")

        var devicesToStore: [Data] = []
        
        // Clear previous session devices
        sessionDevices.removeAll()

        if let unwrappedDevices = devices {
            for device in unwrappedDevices {
                // Store device INFO for display (UUID, name, model) - NOT the IQDevice object
                let garminDevice = GarminDevice(id: device.uuid.uuidString, model: device.modelName, name: device.friendlyName)
                if let result = try? JSONEncoder().encode(garminDevice) {
                    devicesToStore.append(result)
                }

                // Cache the LIVE IQDevice object for this session only
                sessionDevices[device.uuid.uuidString] = device
                print("[Garmin] ✅ Fresh device cached: \(device.friendlyName ?? "Unknown") - \(device.uuid.uuidString)")
            }
        }

        // Persist only the display info (not IQDevice objects - they can't be restored)
        UserDefaults.standard.set(devicesToStore, forKey: devicesListKey)
        print("[Garmin] Stored \(sessionDevices.count) session devices")
    }

    // Get a LIVE IQDevice object - only works for current session devices
    @objc
    public static func getDevice(byId id: String) -> IQDevice? {
        if let device = sessionDevices[id] {
            print("[Garmin] ✅ Found live session device: \(id)")
            return device
        }
        
        // Device not in current session - user needs to re-pair via GCM
        print("[Garmin] ❌ Device \(id) not in current session - re-pairing required")
        return nil
    }
    
    // Check if we have live session devices
    @objc
    public static func hasSessionDevices() -> Bool {
        return !sessionDevices.isEmpty
    }

    static func getDevicesList(_ resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        let result = UserDefaults.standard.object(forKey: self.devicesListKey)
        let devicesList: NSMutableArray = []

        if let devices: [Data] = result as? [Data] {
            for device in devices {
                let decoded = try? JSONDecoder().decode(GarminDevice.self, from: device)
                if let unwrappedDevice = decoded {
                    let deviceObject: NSMutableDictionary = [:]
                    deviceObject["id"] = unwrappedDevice.id
                    deviceObject["name"] = unwrappedDevice.name
                    deviceObject["model"] = unwrappedDevice.model
                    
                    // Check if this device has a live session reference
                    let hasLiveSession = sessionDevices[unwrappedDevice.id] != nil
                    deviceObject["status"] = hasLiveSession ? "ONLINE" : "OFFLINE"
                    deviceObject["needsRepairing"] = !hasLiveSession
                    
                    devicesList.add(deviceObject)
                }
            }
        }

        resolve(devicesList)
    }
}
