import ActivityKit
import Flutter
import UIKit
import Foundation
import CryptoKit

@available(iOS 16.1, *)
class FlutterAlertConfig {
    let _title:String
    let _body:String
    let _sound:String?

    init(title:String, body:String, sound:String?) {
        _title = title;
        _body = body;
        _sound = sound;
    }

    func getAlertConfig() -> AlertConfiguration {
        return AlertConfiguration(title: LocalizedStringResource(stringLiteral: _title), body: LocalizedStringResource(stringLiteral: _body), sound: (_sound == nil) ? .default : AlertConfiguration.AlertSound.named(_sound!));
    }
}

public class LiveActivitiesPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, FlutterSceneLifeCycleDelegate {
    private enum ThNativeWidgetUpdateTokenEventType: String {
        case activityStarted = "activity_started"
        case tokenUpdated = "token_updated"
        case tokenReplay = "token_replay"
    }

    private var urlSchemeSink: FlutterEventSink?
    private var appGroupId: String?
    private var urlScheme: String?
    private var sharedDefault: UserDefaults?
    private var appLifecycleLiveActivityIds = [String]()
    private var activityEventSink: FlutterEventSink?
    private var pushToStartTokenEventSink: FlutterEventSink?
    private var thNativeWidgetUpdateTokenEventSink: FlutterEventSink?
    @MainActor private var monitoredActivityIds = Set<String>()
    @MainActor private var tokenObservedActivityIds = Set<String>()
    @MainActor private var pendingThNativeWidgetTokenEventTypes = [String: String]()
    @MainActor private var observingActivityLifecycle = false

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "live_activities", binaryMessenger: registrar.messenger())
        let urlSchemeChannel = FlutterEventChannel(name: "live_activities/url_scheme", binaryMessenger: registrar.messenger())
        let activityStatusChannel = FlutterEventChannel(name: "live_activities/activity_status", binaryMessenger: registrar.messenger())
        let pushToStartTokenUpdatesChannel = FlutterEventChannel(name: "live_activities/push_to_start_token_updates", binaryMessenger: registrar.messenger())
        let thNativeWidgetUpdateTokenChannel = FlutterEventChannel(name: "th_native_widget/live_activity_update_tokens", binaryMessenger: registrar.messenger())

        let instance = LiveActivitiesPlugin()

        registrar.addMethodCallDelegate(instance, channel: channel)
        urlSchemeChannel.setStreamHandler(instance)
        activityStatusChannel.setStreamHandler(instance)
        pushToStartTokenUpdatesChannel.setStreamHandler(instance)
        thNativeWidgetUpdateTokenChannel.setStreamHandler(instance)
        registrar.addApplicationDelegate(instance)
        registrar.addSceneDelegate(instance)
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        urlSchemeSink = nil
        activityEventSink = nil
        pushToStartTokenEventSink = nil
        thNativeWidgetUpdateTokenEventSink = nil
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        if let args = arguments as? String{
            if (args == "urlSchemeStream") {
                urlSchemeSink = events
            } else if (args == "activityUpdateStream") {
                activityEventSink = events
                emitCurrentActivityUpdateTokens()
                startObservingActivities()
            } else if (args == "pushToStartTokenUpdateStream") {
                pushToStartTokenEventSink = events
                startObservingPushToStartTokens()
            }
        } else {
            thNativeWidgetUpdateTokenEventSink = events
            emitCurrentThNativeWidgetUpdateTokens()
            startObservingActivities()
        }

        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        if let args = arguments as? String{
            if (args == "urlSchemeStream") {
                urlSchemeSink = nil
            } else if (args == "activityUpdateStream") {
                activityEventSink = nil
            } else if (args == "pushToStartTokenUpdateStream") {
                pushToStartTokenEventSink = nil
            }
        } else {
            thNativeWidgetUpdateTokenEventSink = nil
        }
        return nil
    }

    private func initializationGuard(result: @escaping FlutterResult) -> Bool {
        if self.appGroupId == nil || self.sharedDefault == nil {
            result(FlutterError(code: "NEED_INIT", message: "you need to run 'init()' first with app group id to create live activity", details: nil))
            return false
        }
        return true
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if (call.method == "openLiveActivitySettings") {
            guard let url = URL(string: UIApplication.openSettingsURLString) else {
                result(false)
                return
            }
            UIApplication.shared.open(url, options: [:]) { opened in
                result(opened)
            }
            return
        }

        if (call.method == "areActivitiesSupported") {
            guard #available(iOS 16.1, *), !ProcessInfo.processInfo.isiOSAppOnMac else {
                result(false)
                return
            }
            result(true)
            return
        }

        if (call.method == "areActivitiesEnabled") {
            guard #available(iOS 16.1, *), !ProcessInfo.processInfo.isiOSAppOnMac else {
                result(false)
                return
            }

            result(ActivityAuthorizationInfo().areActivitiesEnabled)
            return
        }

        if (call.method == "allowsPushStart") {
            guard #available(iOS 17.2, *), !ProcessInfo.processInfo.isiOSAppOnMac else {
                result(false)
                return
            }

            // This is iOS 17.2+ so push-to-start is supported
            result(true)
            return
        }

        if #available(iOS 16.1, *) {
            switch call.method {
            case "init":
                guard let args = call.arguments as? [String: Any] else {
                    return
                }

                self.urlScheme = args["urlScheme"] as? String;

                if let appGroupId = args["appGroupId"] as? String,
                   let sharedDefault = UserDefaults(suiteName: appGroupId) {
                    self.appGroupId = appGroupId
                    self.sharedDefault = sharedDefault
                    result(nil)
                } else {
                    result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'appGroupId' is valid", details: nil))
                }

                break
            case "createActivity":
                guard initializationGuard(result: result) else {
                    return
                }
                guard let args = call.arguments as? [String: Any] else {
                    result(FlutterError(code: "WRONG_ARGS", message: "Unknown data type in argument", details: nil))
                    return
                }

                if let data = args["data"] as? [String: Any], let activityId = args["activityId"] as? String? ?? nil {
                    let removeWhenAppIsKilled = args["removeWhenAppIsKilled"] as? Bool ?? false
                    let enableRemoteUpdates = args["enableRemoteUpdates"] as? Bool ?? true
                    let staleIn = args["staleIn"] as? Int? ?? nil
                    let activityTag = args["activityTag"] as? String
                    createActivity(data: data, removeWhenAppIsKilled: removeWhenAppIsKilled, enableRemoteUpdates: enableRemoteUpdates, staleIn: staleIn, activityId: activityId, activityTag: activityTag, result: result)
                } else {
                    result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'data' is valid", details: nil))
                }
                break
            case "updateActivity":
                guard initializationGuard(result: result) else {
                    return
                }
                guard let args = call.arguments as? [String: Any] else {
                    result(FlutterError(code: "WRONG_ARGS", message: "Unknown data type in argument", details: nil))
                    return
                }
                if let activityId = args["activityId"] as? String, let data = args["data"] as? [String: Any] {
                    let alertConfigMap = args["alertConfig"] as? [String:String?];
                    let alertTitle = alertConfigMap?["title"] as? String;
                    let alertBody = alertConfigMap?["body"] as? String;
                    let alertSound = alertConfigMap?["sound"] as? String;

                    let alertConfig = (alertTitle == nil || alertBody == nil) ? nil : FlutterAlertConfig(title: alertTitle!, body: alertBody!, sound: alertSound);

                    updateActivity(activityId: activityId, data: data, alertConfig: alertConfig, result: result)
                } else {
                    result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'activityId', 'data' are valid", details: nil))
                }
                break
            case "endActivity":
                guard let args = call.arguments as? [String: Any] else {
                    result(FlutterError(code: "WRONG_ARGS", message: "Unknown data type in argument", details: nil))
                    return
                }
                if let activityId = args["activityId"] as? String {
                    endActivity(activityId: activityId, result: result)
                } else {
                    result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'activityId' is valid", details: nil))
                }
                break
            case "getActivityState":
                guard let args = call.arguments as? [String: Any] else {
                    result(FlutterError(code: "WRONG_ARGS", message: "Unknown data type in argument", details: nil))
                    return
                }
                if let activityId = args["activityId"] as? String {
                    getActivityState(activityId: activityId, result: result)
                } else {
                    result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'activityId' is valid", details: nil))
                }
                break
            case "getPushToken":
                guard let args = call.arguments  as? [String: Any] else {
                    return
                }
                if let activityId = args["activityId"] as? String {
                    getPushToken(activityId: activityId, result: result)
                } else {
                    result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'activityId' is valid", details: nil))
                }
                break
            case "getAllActivitiesIds":
                getAllActivitiesIds(result: result)
                break
            case "getAllActivities":
                getAllActivities(result: result)
                break
            case "endAllActivities":
                endAllActivities(result: result)
                break
            case "createOrUpdateActivity":
                guard initializationGuard(result: result) else {
                    return
                }
                guard let args = call.arguments as? [String: Any] else {
                    result(FlutterError(code: "WRONG_ARGS", message: "Unknown data type in argument", details: nil))
                    return
                }

                if let data = args["data"] as? [String: Any], let activityId = args["activityId"] as? String {
                    let removeWhenAppIsKilled = args["removeWhenAppIsKilled"] as? Bool ?? false
                    let enableRemoteUpdates = args["enableRemoteUpdates"] as? Bool ?? true
                    let staleIn = args["staleIn"] as? Int? ?? nil
                    let activityTag = args["activityTag"] as? String
                    createOrUpdateActivity(data: data, activityId: activityId, activityTag: activityTag, removeWhenAppIsKilled: removeWhenAppIsKilled, enableRemoteUpdates: enableRemoteUpdates, staleIn: staleIn, result: result,)
                } else {
                    result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'data', 'activityId' is valid", details: nil))
                }
                break
            default:
                result(FlutterMethodNotImplemented)
            }
        } else {
            result(FlutterError(code: "WRONG_IOS_VERSION", message: "this version of iOS is not supported", details: nil))
        }
    }

    @available(iOS 16.1, *)
    func createActivity(data: [String: Any], removeWhenAppIsKilled: Bool, enableRemoteUpdates: Bool, staleIn: Int?, activityId: String? = nil, activityTag: String? = nil, result: @escaping FlutterResult) {
        guard let appGroupId = self.appGroupId,
              let sharedDefault = self.sharedDefault else {
            result(FlutterError(code: "NEED_INIT", message: "you need to run 'init()' first with app group id to create live activity", details: nil))
            return
        }

        let liveDeliveryAttributes: LiveActivitiesAppAttributes
        if let activityId = activityId {
            let uuid = uuid5(name: activityId)
            liveDeliveryAttributes = LiveActivitiesAppAttributes(
                id: uuid,
                bizId: activityTag ?? activityId,
                activityId: activityId
            )
        } else {
            liveDeliveryAttributes = LiveActivitiesAppAttributes(bizId: activityTag, activityId: activityId)
        }
        let initialContentState = LiveActivitiesAppAttributes.LiveDeliveryData(appGroupId: appGroupId)
        var deliveryActivity: Activity<LiveActivitiesAppAttributes>?
        let prefix = liveDeliveryAttributes.id

        for item in data {
            sharedDefault.set(item.value, forKey: "\(prefix)_\(item.key)")
        }

        if #available(iOS 16.2, *){
            let activityContent = ActivityContent(
                state: initialContentState,
                staleDate: staleIn != nil ? Calendar.current.date(byAdding: .minute, value: staleIn!, to: Date.now) : nil)
            do {
                deliveryActivity = try Activity.request(
                    attributes: liveDeliveryAttributes,
                    content: activityContent,
                    pushType: enableRemoteUpdates ? .token : nil)
            } catch (let error) {
                result(FlutterError(code: "LIVE_ACTIVITY_ERROR", message: "can't launch live activity", details: error.localizedDescription))
            }
        } else {
            do {
                deliveryActivity = try Activity<LiveActivitiesAppAttributes>.request(
                    attributes: liveDeliveryAttributes,
                    contentState: initialContentState,
                    pushType: enableRemoteUpdates ? .token : nil)

            } catch (let error) {
                result(FlutterError(code: "LIVE_ACTIVITY_ERROR", message: "can't launch live activity", details: error.localizedDescription))
            }
        }
        if (deliveryActivity != nil) {
            if removeWhenAppIsKilled {
                appLifecycleLiveActivityIds.append(deliveryActivity!.id)
            }
            Task { @MainActor in
                self.attachObserversIfNeeded(deliveryActivity!, initialTokenEventType: .tokenUpdated)
            }
            result(deliveryActivity!.id)
        }
    }

    @available(iOS 16.1, *)
    func updateActivity(activityId: String, data: [String: Any?], alertConfig: FlutterAlertConfig?, result: @escaping FlutterResult) {
        Task {
            guard let appGroupId = self.appGroupId,
                  let sharedDefault = self.sharedDefault else {
                result(FlutterError(code: "NEED_INIT", message: "you need to run 'init()' first with app group id to create live activity", details: nil))
                return
            }

            let activities = await MainActor.run { Activity<LiveActivitiesAppAttributes>.activities }
            guard let activity = findActivity(in: activities, activityId: activityId) else {
                result(FlutterError(code: "ACTIVITY_ERROR", message: "Activity not found", details: nil))
                return
            }

            let prefix = activity.attributes.id

            await MainActor.run {
                for (key, value) in data {
                    if let value = value, !(value is NSNull) {
                        sharedDefault.set(value, forKey: "\(prefix)_\(key)")
                    } else {
                        sharedDefault.removeObject(forKey: "\(prefix)_\(key)")
                    }
                }
            }

            let updatedStatus = LiveActivitiesAppAttributes.LiveDeliveryData(appGroupId: appGroupId)
            await activity.update(using: updatedStatus, alertConfiguration: alertConfig?.getAlertConfig())

            result(nil)
        }
    }

    @available(iOS 16.1, *)
    func createOrUpdateActivity(data: [String: Any], activityId: String, activityTag: String?, removeWhenAppIsKilled: Bool, enableRemoteUpdates: Bool, staleIn: Int?, result: @escaping FlutterResult) {
        Task {
            var activities: [Activity<LiveActivitiesAppAttributes>] = []
            for _ in 0..<3 { // Try up to 3 times
                activities = await MainActor.run { Activity<LiveActivitiesAppAttributes>.activities }
                if !activities.isEmpty {
                    break
                }
                try? await Task.sleep(for: .seconds(0.1))
            }

            let existingActivity = activities.first {
                self.matchesActivityId($0, activityId: activityId) && $0.activityState != .dismissed && $0.activityState != .ended
            }

            if let activityId = existingActivity?.id {
                updateActivity(activityId: activityId, data: data, alertConfig: nil, result: result)
            } else {
                createActivity(data: data, removeWhenAppIsKilled: removeWhenAppIsKilled, enableRemoteUpdates: enableRemoteUpdates, staleIn: staleIn, activityId: activityId, activityTag: activityTag, result: result)
            }
        }
    }

    @available(iOS 16.1, *)
    func getActivityState(activityId: String, result: @escaping FlutterResult) {
        Task {
            let matchingActivity = findActivity(
                in: Activity<LiveActivitiesAppAttributes>.activities,
                activityId: activityId
            )

            guard let activity = matchingActivity else {
                result(nil)
                return
            }

            let state = activityStateToString(activityState: activity.activityState)
            result(state)
        }
    }

    @available(iOS 16.1, *)
    func getPushToken(activityId: String, result: @escaping FlutterResult) {
        Task {
            let activities = await MainActor.run { Activity<LiveActivitiesAppAttributes>.activities }
            guard let activity = findActivity(in: activities, activityId: activityId),
                  let data = activity.pushToken else {
                result(nil)
                return
            }
            let pushToken = data.map { String(format: "%02x", $0) }.joined()
            result(pushToken)
        }
    }

    @available(iOS 16.1, *)
    func endActivity(activityId: String, result: @escaping FlutterResult) {
        appLifecycleLiveActivityIds.removeAll { $0 == activityId }
        Task {
            await endActivitiesWithId(activityIds: [activityId])
            result(nil)
        }
    }

    @available(iOS 16.1, *)
    func endAllActivities(result: @escaping FlutterResult) {
        Task {
            for activity in Activity<LiveActivitiesAppAttributes>.activities {
                await activity.end(dismissalPolicy: .immediate)
            }
            appLifecycleLiveActivityIds.removeAll()
            result(nil)
        }
    }

    private func startObservingPushToStartTokens() {
        if #available(iOS 17.2, *) {
            Task {
                for await data in Activity<LiveActivitiesAppAttributes>.pushToStartTokenUpdates {
                    let token = data.map { String(format: "%02x", $0) }.joined()

                    DispatchQueue.main.async {
                        self.pushToStartTokenEventSink?(token)
                    }
                }
            }
        }
    }

    private func startObservingActivities() {
        guard #available(iOS 16.1, *) else {
            return
        }

        Task {
            let existingActivities = await MainActor.run { Activity<LiveActivitiesAppAttributes>.activities }
            await MainActor.run {
                for activity in existingActivities {
                    self.attachObserversIfNeeded(activity, initialTokenEventType: .tokenReplay)
                }
            }
        }

        if #available(iOS 17.2, *) {
            Task {
                let shouldStart = await MainActor.run { () -> Bool in
                    if self.observingActivityLifecycle {
                        return false
                    }
                    self.observingActivityLifecycle = true
                    return true
                }

                guard shouldStart else {
                    return
                }

                for await activity in Activity<LiveActivitiesAppAttributes>.activityUpdates {
                    await MainActor.run {
                        self.attachObserversIfNeeded(activity, initialTokenEventType: .activityStarted)
                    }
                }
            }
        }
    }

    private func emitCurrentThNativeWidgetUpdateTokens() {
        guard #available(iOS 16.1, *) else {
            return
        }

        Task {
            let existingActivities = await MainActor.run { Activity<LiveActivitiesAppAttributes>.activities }
            for activity in existingActivities {
                let isAlreadyObserved = await MainActor.run { self.tokenObservedActivityIds.contains(activity.id) }
                guard isAlreadyObserved else {
                    continue
                }
                guard let data = activity.pushToken else {
                    continue
                }
                emitThNativeWidgetUpdateTokenEvent(activity: activity, tokenData: data, eventType: .tokenReplay)
            }
        }
    }

    private func emitCurrentActivityUpdateTokens() {
        guard #available(iOS 16.1, *) else {
            return
        }

        Task {
            let existingActivities = await MainActor.run { Activity<LiveActivitiesAppAttributes>.activities }
            for activity in existingActivities {
                let isAlreadyObserved = await MainActor.run { self.tokenObservedActivityIds.contains(activity.id) }
                guard isAlreadyObserved else {
                    continue
                }
                guard let data = activity.pushToken else {
                    continue
                }
                emitActivityUpdateTokenEvent(activity: activity, tokenData: data)
            }
        }
    }

    @available(iOS 16.1, *)
    func getAllActivitiesIds(result: @escaping FlutterResult) {
        var activitiesId: [String] = []
        for activity in Activity<LiveActivitiesAppAttributes>.activities {
            activitiesId.append(activity.id)
        }

        result(activitiesId)
    }

    @available(iOS 16.1, *)
    func getAllActivities(result: @escaping FlutterResult) {
        var activitiesState: [String: String] = [:] // Corrected here
        for activity in Activity<LiveActivitiesAppAttributes>.activities {
            activitiesState[activity.id] = activityStateToString(activityState: activity.activityState)
        }

        result(activitiesState)
    }

    @available(iOS 16.1, *)
    private func endActivitiesWithId(activityIds: [String]) async {
        for activity in Activity<LiveActivitiesAppAttributes>.activities {
            for id in activityIds {
                if matchesActivityId(activity, activityId: id) {
                    await activity.end(dismissalPolicy: .immediate)
                    break
                }
            }
        }
    }

    private func handleURL(_ url: URL) -> Bool {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        if components?.scheme == nil || components?.scheme != urlScheme { return false }

        var queryResult: Dictionary<String, Any> = Dictionary()

        queryResult["queryItems"] = components?.queryItems?.map({ (item) -> Dictionary<String, String> in
            var queryItemResult: Dictionary<String, String> = Dictionary()
            queryItemResult["name"] = item.name
            queryItemResult["value"] = item.value
            return queryItemResult
        })
        queryResult["scheme"] = components?.scheme
        queryResult["host"] = components?.host
        queryResult["path"] = components?.path
        queryResult["url"] = components?.url?.absoluteString

        urlSchemeSink?.self(queryResult)
        return true
    }

    @objc
    public func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        _ = handleURL(url)
    }

    public func applicationWillTerminate(_ application: UIApplication) {
        if #available(iOS 16.1, *) {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await self.endActivitiesWithId(activityIds: self.appLifecycleLiveActivityIds)
                semaphore.signal()
            }

            _ = semaphore.wait(timeout: .now() + 5.0)
        }
    }

    struct LiveActivitiesAppAttributes: ActivityAttributes, Identifiable, Codable {
        public typealias LiveDeliveryData = ContentState

        public struct ContentState: Codable, Hashable {
            var appGroupId: String?

            init(appGroupId: String? = nil) {
                self.appGroupId = appGroupId
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: DynamicCodingKeys.self)
                appGroupId = try container.decodeIfPresent(String.self, forKey: DynamicCodingKeys("appGroupId"))
            }
        }

        var id: UUID
        var bizId: String?
        var activityId: String?
        var rawAttributes: [String: FlutterJsonValue]

        init(id: UUID = UUID(), bizId: String? = nil, activityId: String? = nil, rawAttributes: [String: FlutterJsonValue] = [:]) {
            self.id = id
            self.bizId = bizId
            self.activityId = activityId
            self.rawAttributes = rawAttributes
            normalizeRawAttributes()
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKeys.self)
            var attributes = [String: FlutterJsonValue]()
            for key in container.allKeys {
                attributes[key.stringValue] = try? container.decode(FlutterJsonValue.self, forKey: key)
            }
            id = try container.decodeIfPresent(UUID.self, forKey: DynamicCodingKeys("id")) ?? UUID()
            bizId = try container.decodeIfPresent(String.self, forKey: DynamicCodingKeys("biz_id"))
                ?? container.decodeIfPresent(String.self, forKey: DynamicCodingKeys("bizId"))
            activityId = try container.decodeIfPresent(String.self, forKey: DynamicCodingKeys("activity_id"))
                ?? container.decodeIfPresent(String.self, forKey: DynamicCodingKeys("activityId"))
            rawAttributes = attributes
            normalizeRawAttributes()
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: DynamicCodingKeys.self)
            for (key, value) in rawAttributes {
                try container.encode(value, forKey: DynamicCodingKeys(key))
            }
            try container.encode(id, forKey: DynamicCodingKeys("id"))
            try container.encodeIfPresent(bizId, forKey: DynamicCodingKeys("biz_id"))
            try container.encodeIfPresent(activityId, forKey: DynamicCodingKeys("activity_id"))
        }

        var flutterAttributes: [String: Any] {
            rawAttributes.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = entry.value.flutterValue
            }
        }

        private mutating func normalizeRawAttributes() {
            rawAttributes["id"] = rawAttributes["id"] ?? .string(id.uuidString)
            if let bizId = bizId, !bizId.isEmpty {
                rawAttributes["biz_id"] = .string(bizId)
            }
            if let activityId = activityId, !activityId.isEmpty {
                rawAttributes["activity_id"] = .string(activityId)
            }
        }
    }

    enum FlutterJsonValue: Codable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case object([String: FlutterJsonValue])
        case array([FlutterJsonValue])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Int.self) {
                self = .int(value)
            } else if let value = try? container.decode(Double.self) {
                self = .double(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([String: FlutterJsonValue].self) {
                self = .object(value)
            } else if let value = try? container.decode([FlutterJsonValue].self) {
                self = .array(value)
            } else {
                self = .null
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value):
                try container.encode(value)
            case .int(let value):
                try container.encode(value)
            case .double(let value):
                try container.encode(value)
            case .bool(let value):
                try container.encode(value)
            case .object(let value):
                try container.encode(value)
            case .array(let value):
                try container.encode(value)
            case .null:
                try container.encodeNil()
            }
        }

        var flutterValue: Any {
            switch self {
            case .string(let value):
                return value
            case .int(let value):
                return value
            case .double(let value):
                return value
            case .bool(let value):
                return value
            case .object(let value):
                return value.reduce(into: [String: Any]()) { result, entry in
                    result[entry.key] = entry.value.flutterValue
                }
            case .array(let value):
                return value.map { $0.flutterValue }
            case .null:
                return NSNull()
            }
        }
    }

    struct DynamicCodingKeys: CodingKey {
        var stringValue: String
        var intValue: Int?

        init(_ stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            return nil
        }
    }

    @available(iOS 16.1, *)
    private func monitorLiveActivity<T : ActivityAttributes>(_ activity: Activity<T>) {
        Task {
            for await state in activity.activityStateUpdates {
                switch state {
                case .active:
                    await MainActor.run {
                        self.attachTokenObserverIfNeeded(activity, initialTokenEventType: .activityStarted)
                    }
                case .dismissed, .ended:
                    DispatchQueue.main.async {
                        var response: Dictionary<String, Any> = Dictionary()
                        response["activityId"] = activity.id
                        response["status"] = "ended"
                        self.activityEventSink?.self(response)
                    }
                case .stale:
                    DispatchQueue.main.async {
                        var response: Dictionary<String, Any> = Dictionary()
                        response["activityId"] = activity.id
                        response["status"] = "stale"
                        self.activityEventSink?.self(response)
                    }
                @unknown default:
                    DispatchQueue.main.async {
                        var response: Dictionary<String, Any> = Dictionary()
                        response["activityId"] = activity.id
                        response["status"] = "unknown"
                        self.activityEventSink?.self(response)
                    }
                }
            }
        }
    }

    @available(iOS 16.1, *)
    private func monitorTokenChanges<T: ActivityAttributes>(_ activity: Activity<T>) {
        Task {
            for await data in activity.pushTokenUpdates {
                emitActivityUpdateTokenEvent(activity: activity, tokenData: data)
                if let liveActivity = activity as? Activity<LiveActivitiesAppAttributes> {
                    let rawEventType = await MainActor.run {
                        self.pendingThNativeWidgetTokenEventTypes.removeValue(forKey: liveActivity.id)
                    } ?? ThNativeWidgetUpdateTokenEventType.tokenUpdated.rawValue
                    emitThNativeWidgetUpdateTokenEvent(activity: liveActivity, tokenData: data, eventType: rawEventType)
                }
            }
        }
    }

    @available(iOS 16.1, *)
    @MainActor private func attachObserversIfNeeded(
        _ activity: Activity<LiveActivitiesAppAttributes>,
        initialTokenEventType: ThNativeWidgetUpdateTokenEventType
    ) {
        if !monitoredActivityIds.contains(activity.id) {
            monitoredActivityIds.insert(activity.id)
            monitorLiveActivity(activity)
        }

        if activity.activityState == .active {
            attachTokenObserverIfNeeded(activity, initialTokenEventType: initialTokenEventType)
        }
    }

    @available(iOS 16.1, *)
    @MainActor private func attachTokenObserverIfNeeded<T: ActivityAttributes>(
        _ activity: Activity<T>,
        initialTokenEventType: ThNativeWidgetUpdateTokenEventType
    ) {
        if tokenObservedActivityIds.contains(activity.id) {
            return
        }

        tokenObservedActivityIds.insert(activity.id)
        let emittedCurrentToken = emitCurrentTokenIfPresent(activity, thNativeWidgetEventType: initialTokenEventType)
        if let liveActivity = activity as? Activity<LiveActivitiesAppAttributes>,
           initialTokenEventType == .activityStarted,
           !emittedCurrentToken {
            pendingThNativeWidgetTokenEventTypes[liveActivity.id] = initialTokenEventType.rawValue
        }
        monitorTokenChanges(activity)
    }

    @available(iOS 16.1, *)
    private func emitCurrentTokenIfPresent<T: ActivityAttributes>(
        _ activity: Activity<T>,
        thNativeWidgetEventType: ThNativeWidgetUpdateTokenEventType
    ) -> Bool {
        guard let data = activity.pushToken else {
            return false
        }

        let pushToken = data.map { String(format: "%02x", $0) }.joined()
        guard !pushToken.isEmpty else {
            return false
        }

        emitActivityUpdateTokenEvent(activity: activity, tokenData: data)
        if let liveActivity = activity as? Activity<LiveActivitiesAppAttributes> {
            emitThNativeWidgetUpdateTokenEvent(
                activity: liveActivity,
                tokenData: data,
                eventType: thNativeWidgetEventType
            )
        }
        return true
    }

    @available(iOS 16.1, *)
    private func emitActivityUpdateTokenEvent<T: ActivityAttributes>(activity: Activity<T>, tokenData: Data) {
        let pushToken = tokenData.map {String(format: "%02x", $0)}.joined()
        guard !pushToken.isEmpty else {
            return
        }

        DispatchQueue.main.async {
            var response: Dictionary<String, Any> = Dictionary()
            response["token"] = pushToken
            response["activityId"] = activity.id
            response["status"] = "active"
            self.activityEventSink?.self(response)
        }
    }

    @available(iOS 16.1, *)
    private func emitThNativeWidgetUpdateTokenEvent(
        activity: Activity<LiveActivitiesAppAttributes>,
        tokenData: Data,
        eventType: ThNativeWidgetUpdateTokenEventType
    ) {
        emitThNativeWidgetUpdateTokenEvent(activity: activity, tokenData: tokenData, eventType: eventType.rawValue)
    }

    @available(iOS 16.1, *)
    private func emitThNativeWidgetUpdateTokenEvent(
        activity: Activity<LiveActivitiesAppAttributes>,
        tokenData: Data,
        eventType: String
    ) {
        let updateToken = tokenData.map { String(format: "%02x", $0) }.joined()
        guard !updateToken.isEmpty else {
            return
        }

        DispatchQueue.main.async {
            var response: Dictionary<String, Any> = Dictionary()
            let attributes = activity.attributes.flutterAttributes
            response["update_token"] = updateToken
            response["event_type"] = eventType
            response["attributes"] = attributes
            response["activity_id"] = activity.attributes.activityId ?? activity.attributes.id.uuidString
            if let bizId = activity.attributes.bizId, !bizId.isEmpty {
                response["biz_id"] = bizId
            }
            self.thNativeWidgetUpdateTokenEventSink?.self(response)
        }
    }

    @available(iOS 16.1, *)
    private func activityStateToString(activityState: ActivityState) -> String {
        switch activityState {
        case .active:
            return "active"
        case .ended:
            return "ended"
        case .dismissed:
            return "dismissed"
        case .stale:
            return "stale"
        @unknown default:
            return "unknown"
        }
    }

    @available(iOS 16.1, *)
    private func findActivity(
        in activities: [Activity<LiveActivitiesAppAttributes>],
        activityId: String
    ) -> Activity<LiveActivitiesAppAttributes>? {
        activities.first {
            matchesActivityId($0, activityId: activityId)
        }
    }

    @available(iOS 16.1, *)
    private func matchesActivityId(_ activity: Activity<LiveActivitiesAppAttributes>, activityId: String) -> Bool {
        let normalizedActivityId = activityId.uppercased()
        return activity.id == activityId ||
            activity.attributes.activityId?.uppercased() == normalizedActivityId ||
            activity.attributes.id.uuidString.uppercased() == normalizedActivityId ||
            activity.attributes.id == uuid5(name: activityId)
    }

    private func uuid5(namespace: UUID = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!, name: String) -> UUID {
        // Convert namespace UUID to bytes
        var namespaceBytes = withUnsafeBytes(of: namespace.uuid) { Data($0) }

        // Append the name bytes (as UTF-8)
        let nameBytes = Data(name.utf8)
        namespaceBytes.append(nameBytes)

        // SHA1 hash
        let hash = Insecure.SHA1.hash(data: namespaceBytes)

        // Take the first 16 bytes
        var bytes = [UInt8](hash.prefix(16))

        // Set UUID version to 5 (0101)
        bytes[6] = (bytes[6] & 0x0F) | 0x50

        // Set UUID variant to RFC 4122 (10xx)
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        // Convert bytes to UUID
        let uuid = uuid_t(bytes[0], bytes[1], bytes[2], bytes[3],
                          bytes[4], bytes[5], bytes[6], bytes[7],
                          bytes[8], bytes[9], bytes[10], bytes[11],
                          bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: uuid)
    }

}
