import Foundation

struct AppConstants {
    static let KEY_MESSAGE_TYPE = "KEY_MESSAGE_TYPE"
    static let KEY_MESSAGE_PAYLOAD = "KEY_MESSAGE_PAYLOAD"
    static let MESSAGE_PAYLOAD = "MESSAGE_PAYLOAD"

    static let MESSAGE_TYPE_CURRENT_ANGLE = "MESSAGE_TYPE_CURRENT_ANGLE"
    static let MESSAGE_TYPE_MAX_ANGLE = "MESSAGE_TYPE_MAX_ANGLE"

    // Set at runtime via GarminConnectModule.initGarminSDK()
    static var APP_ID: String = ""

    static let STATUS_ONLINE = "ONLINE"
    static let STATUS_OFFLINE = "OFFLINE"
}