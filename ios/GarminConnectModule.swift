import Foundation
import SwiftUI
import Combine
import ConnectIQ
import Foundation

@objc(GarminConnectModule)
public class GarminConnectModule: NSObject, IQDeviceEventDelegate, IQAppMessageDelegate, IQUIOverrideDelegate {
    private let watchAppUuid = UUID(uuidString: AppConstants.APP_ID)
    private var connectedApp: IQApp? = nil

    private var emitter: RCTEventEmitter!

    @objc public func setEventEmitter(eventEmitter: RCTEventEmitter){
        self.emitter = eventEmitter
    }

    @objc public func initGarminSDK(urlScheme: NSString){
        ConnectIQ.sharedInstance().initialize(withUrlScheme: urlScheme as String, uiOverrideDelegate: nil)
        GarminDeviceStorage.urlScheme = urlScheme as String
        self.onSdkReady()
    }

    @objc public func destroy(){
        ConnectIQ.sharedInstance().unregister(forAllDeviceEvents: self)
        ConnectIQ.sharedInstance().unregister(forAllAppMessages: self)
    }


    @objc public func showDevicesList(){
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            ConnectIQ.sharedInstance().showDeviceSelection()
        }
    }

    @objc public func getDevicesList(_ resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) -> Void {
        GarminDeviceStorage.getDevicesList(resolve, reject: reject)
    }

    @objc(connectDevice:model:name:)
    public func connectDevice(id: String, model: String, name: String) {
        // Get LIVE IQDevice from current session - archived devices don't work!
        guard let device = GarminDeviceStorage.getDevice(byId: id) else {
            print("[Garmin] ❌ Device \(id) not in current session - needs re-pairing via GCM")
            // Emit status indicating re-pairing is needed
            let errorDevice: NSMutableDictionary = [:]
            errorDevice["name"] = name
            errorDevice["status"] = "OFFLINE"
            errorDevice["needsRepairing"] = true
            errorDevice["error"] = "Session expired. Tap to re-pair via Garmin Connect."
            self.emitter.sendEvent(withName: "onDeviceStatusChanged", body: errorDevice)
            return
        }

        print("[Garmin] ✅ Connecting to live session device: \(device.friendlyName ?? name)")

        ConnectIQ.sharedInstance().register(forDeviceEvents: device, delegate: self)

        // Query and emit the current device status immediately
        let currentStatus = ConnectIQ.sharedInstance().getDeviceStatus(device)
        let (statusStr, reason) = getStatus(status: currentStatus)
        print("[Garmin] Device \(name) status: \(statusStr) (\(reason))")
        self.onDeviceStatusChanged(device, status: statusStr, reason: reason)

        // If already connected, register for app messages
        if currentStatus == .connected {
            connectedApp = IQApp(uuid: watchAppUuid, store: nil, device: device)
            ConnectIQ.sharedInstance().register(forAppMessages: connectedApp, delegate: self)
            print("[Garmin] Registered for app messages with app UUID: \(AppConstants.APP_ID)")
        }
    }

    @objc public func sendMessage(_ message: String) {
        print("[Garmin] 📤 sendMessage called with: \(message)")
        
        guard let currentApp = connectedApp else {
            print("[Garmin] ❌ connectedApp is nil - is watch app open?")
            DispatchQueue.main.async {
                self.emitter.sendEvent(withName: "onError", body: "Watch app not connected. Open the app on your watch.")
            }
            return
        }
        
        print("[Garmin] 📤 Have connected app, parsing message...")
        
        var messageDict: [String: Any]
        
        if let data = message.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            messageDict = dict
        } else {
            messageDict = [
                "type": "DATA",
                "payload": ["text": message]
            ]
        }
        
        print("[Garmin] 📤 Sending message dict: \(messageDict)")
        
        // Use completion handler to catch any errors
        ConnectIQ.sharedInstance().sendMessage(messageDict, to: currentApp, progress: nil) { [weak self] (result: IQSendMessageResult) in
            let resultString = NSStringFromSendMessageResult(result)
            print("[Garmin] 📤 sendMessage completion: \(resultString)")
            
            if result == .success {
                print("[Garmin] ✅ Message sent successfully")
            } else {
                print("[Garmin] ❌ Message send failed: \(resultString)")
                DispatchQueue.main.async {
                    self?.emitter.sendEvent(withName: "onError", body: "Send failed: \(resultString)")
                }
            }
        }
    } 

    public func needsToInstallConnectMobile(){
        self.emitter.sendEvent(withName: "onInfo", body: "Garmin Connect app is required.")
    }

    func getStatus(status: IQDeviceStatus) -> (status: String, reason: String) {
        switch status {
            case .connected:
                return ("CONNECTED", "connected")
            case .notConnected:
                return ("ONLINE", "notConnected - watch reachable but app not open")
            case .bluetoothNotReady:
                return ("OFFLINE", "bluetoothNotReady - turn on Bluetooth")
            case .invalidDevice:
                return ("OFFLINE", "invalidDevice - re-pair required")
            case .notFound:
                return ("OFFLINE", "notFound - open Garmin Connect Mobile")
            @unknown default:
                return ("OFFLINE", "unknown")
        }
    }

    public func deviceStatusChanged(_ device: IQDevice!, status: IQDeviceStatus) {
        let (statusStr, reason) = getStatus(status: status)
        print("[Garmin] Device status callback: \(statusStr) (\(reason))")
        self.onDeviceStatusChanged(device, status: statusStr, reason: reason)
        switch status {
            case .connected:
                connectedApp = IQApp(uuid: watchAppUuid, store: nil, device: device)
                ConnectIQ.sharedInstance().register(forAppMessages: connectedApp, delegate: self)
            case .bluetoothNotReady, .invalidDevice, .notFound, .notConnected:
                ConnectIQ.sharedInstance().unregister(forAppMessages: connectedApp, delegate: self)
                connectedApp = nil
        }
    }

    public func receivedMessage(_ messages: Any!, from app: IQApp!) {
        // TEMPORARY: Just log and ignore to test if this is the crash source
        print("[Garmin] 📩 RECEIVED MESSAGE - IGNORING FOR DEBUG")
        print("[Garmin] 📩 Type: \(type(of: messages))")
        
        // Do nothing else - if app still crashes, it's not this function
    }
    
    private func processReceivedMessage(_ messages: Any!) throws {
        print("[Garmin] 📩 DEBUG: processReceivedMessage called")
        
        guard messages != nil else {
            print("[Garmin] ⚠️ DEBUG: messages is nil")
            return
        }
        
        if let messagesArray = messages as? [[String: Any]] {
            print("[Garmin] 📩 DEBUG: Processing as [[String: Any]] with \(messagesArray.count) items")
            for (index, message) in messagesArray.enumerated() {
                print("[Garmin] 📩 DEBUG: Processing item \(index)")
                self.processMessage(message)
            }
        } else if let messagesArray = messages as? [Any] {
            print("[Garmin] 📩 DEBUG: Processing as [Any] with \(messagesArray.count) items")
            for (index, message) in messagesArray.enumerated() {
                print("[Garmin] 📩 DEBUG: Processing item \(index), type: \(type(of: message))")
                if let dict = message as? [String: Any] {
                    self.processMessage(dict)
                } else {
                    self.emitSafeMessage(type: "RAW", payload: String(describing: message))
                }
            }
        } else if let message = messages as? [String: Any] {
            print("[Garmin] 📩 DEBUG: Processing as [String: Any]")
            self.processMessage(message)
        } else {
            print("[Garmin] ⚠️ DEBUG: Unknown format, wrapping as string")
            self.emitSafeMessage(type: "RAW", payload: String(describing: messages!))
        }
    }
    
    private func processMessage(_ body: [String: Any]) {
        print("[Garmin] 📨 DEBUG: processMessage with body: \(body)")
        
        let messageType = (body["type"] as? String) 
            ?? (body[AppConstants.KEY_MESSAGE_TYPE] as? String) 
            ?? "UNKNOWN"
        print("[Garmin] 📨 DEBUG: messageType = \(messageType)")
        
        // Convert payload to string safely
        var payloadString = ""
        
        if let payload = body["payload"] ?? body[AppConstants.KEY_MESSAGE_PAYLOAD] ?? body["data"] {
            print("[Garmin] 📨 DEBUG: payload type = \(type(of: payload))")
            
            if let dict = payload as? [String: Any] {
                if JSONSerialization.isValidJSONObject(dict),
                   let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
                   let str = String(data: data, encoding: .utf8) {
                    payloadString = str
                } else {
                    payloadString = String(describing: dict)
                }
            } else if let str = payload as? String {
                payloadString = str
            } else if let num = payload as? NSNumber {
                payloadString = num.stringValue
            } else {
                payloadString = String(describing: payload)
            }
        }
        
        print("[Garmin] 📨 DEBUG: payloadString = \(payloadString)")
        self.emitSafeMessage(type: messageType, payload: payloadString)
    }
    
    private func emitSafeMessage(type: String, payload: String) {
        print("[Garmin] 📤 DEBUG: emitSafeMessage type=\(type) payload=\(payload)")
        
        // Only use simple types that are guaranteed to be serializable
        let eventMessage: [String: String] = [
            "type": type,
            "payload": payload
        ]
        
        print("[Garmin] 📤 DEBUG: About to emit...")
        self.emitter.sendEvent(withName: "onMessage", body: eventMessage)
        print("[Garmin] 📤 DEBUG: Emit complete!")
    }

    func onSdkReady() {
        DispatchQueue.main.async {
            print("[Garmin] ✅ DEBUG: Emitting onSdkReady")
            self.emitter.sendEvent(withName: "onSdkReady", body: true)
        }
    }

    func onError(error: NSString) {
        DispatchQueue.main.async {
            self.emitter.sendEvent(withName: "onError", body: error)
        }
    }

    func onDeviceStatusChanged(_ device: IQDevice, status: String, reason: String) {
        let deviceObject: NSMutableDictionary = [:]
        deviceObject["name"] = device.friendlyName
        deviceObject["status"] = status
        deviceObject["reason"] = reason  // Why this status (for debugging)
        
        DispatchQueue.main.async {
            self.emitter.sendEvent(withName: "onDeviceStatusChanged", body: deviceObject)
        }
    }
}
