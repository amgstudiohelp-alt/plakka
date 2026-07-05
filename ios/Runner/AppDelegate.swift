import Flutter
import AVFoundation
import Photos
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var webSessionChannel: FlutterMethodChannel?
  private var appUpdateChannel: FlutterMethodChannel?
  private var appPermissionsChannel: FlutterMethodChannel?
  private var webSessionStore: WebSessionStore?
  private let initialMediaPermissionsRequestedKey = "initial_media_permissions_requested"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerWebSessionChannel(with: engineBridge.applicationRegistrar.messenger())
    registerAppUpdateChannel(with: engineBridge.applicationRegistrar.messenger())
    registerAppPermissionsChannel(with: engineBridge.applicationRegistrar.messenger())
  }

  private func registerWebSessionChannel(with messenger: FlutterBinaryMessenger) {
    let store = WebSessionStore()
    let channel = FlutterMethodChannel(
      name: "com.uygaria.plakka/web_session",
      binaryMessenger: messenger
    )

    channel.setMethodCallHandler { call, result in
      store.handle(call, result: result)
    }

    webSessionStore = store
    webSessionChannel = channel
  }

  private func registerAppUpdateChannel(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.uygaria.plakka/app_update",
      binaryMessenger: messenger
    )

    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getInstalledVersion":
        result([
          "bundleId": Bundle.main.bundleIdentifier ?? "",
          "versionName": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
          "buildNumber": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
        ])
      case "openStorePage":
        let arguments = call.arguments as? [String: Any]
        let urlString = arguments?["url"] as? String ?? ""
        self.openStorePage(urlString, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    appUpdateChannel = channel
  }

  private func registerAppPermissionsChannel(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.uygaria.plakka/permissions",
      binaryMessenger: messenger
    )

    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "requestInitialMediaPermissions":
        self.requestInitialMediaPermissions(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    appPermissionsChannel = channel
  }

  private func openStorePage(_ urlString: String, result: @escaping FlutterResult) {
    guard let url = URL(string: urlString) else {
      result(false)
      return
    }

    DispatchQueue.main.async {
      UIApplication.shared.open(url, options: [:]) { success in
        result(success)
      }
    }
  }

  private func requestInitialMediaPermissions(result: @escaping FlutterResult) {
    let preferences = UserDefaults.standard
    if preferences.bool(forKey: initialMediaPermissionsRequestedKey) {
      result([
        "requested": false,
      ])
      return
    }

    requestCameraPermission { cameraStatus in
      self.requestPhotoLibraryPermission { photoLibraryStatus in
        preferences.set(true, forKey: self.initialMediaPermissionsRequestedKey)
        result([
          "requested": true,
          "camera": cameraStatus,
          "photoLibrary": photoLibraryStatus,
        ])
      }
    }
  }

  private func requestCameraPermission(completion: @escaping (String) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async {
          completion(granted ? "authorized" : "denied")
        }
      }
    case .authorized:
      completion("authorized")
    case .denied:
      completion("denied")
    case .restricted:
      completion("restricted")
    @unknown default:
      completion("unknown")
    }
  }

  private func requestPhotoLibraryPermission(completion: @escaping (String) -> Void) {
    if #available(iOS 14, *) {
      let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
      guard status == .notDetermined else {
        completion(photoLibraryStatusName(status))
        return
      }

      PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
        DispatchQueue.main.async {
          completion(self.photoLibraryStatusName(newStatus))
        }
      }
      return
    }

    let status = PHPhotoLibrary.authorizationStatus()
    guard status == .notDetermined else {
      completion(photoLibraryStatusName(status))
      return
    }

    PHPhotoLibrary.requestAuthorization { newStatus in
      DispatchQueue.main.async {
        completion(self.photoLibraryStatusName(newStatus))
      }
    }
  }

  private func photoLibraryStatusName(_ status: PHAuthorizationStatus) -> String {
    if #available(iOS 14, *), status == .limited {
      return "limited"
    }

    switch status {
    case .notDetermined:
      return "notDetermined"
    case .authorized:
      return "authorized"
    case .denied:
      return "denied"
    case .restricted:
      return "restricted"
    default:
      return "unknown"
    }
  }
}

private final class WebSessionStore {
  private let preferences = UserDefaults.standard
  private let cookieStore = WKWebsiteDataStore.default().httpCookieStore
  private let cookiesKey = "cookies"
  private let lastUrlKey = "last_url"
  private let notificationConsentKey = "notification_consent"
  private let supportedDomains = ["plakka.tr", "uygaria.com"]

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let url = call.arguments as? String ?? "https://uygaria.com/plakka.php"

    switch call.method {
    case "restoreCookies":
      restoreCookies(for: url, result: result)
    case "saveCookies":
      saveCookies(for: url, result: result)
    case "getNotificationConsent":
      getNotificationConsent(result: result)
    case "setNotificationConsent":
      let allowed = call.arguments as? Bool ?? false
      setNotificationConsent(allowed, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func restoreCookies(for url: String, result: @escaping FlutterResult) {
    let savedCookies = preferences.array(forKey: cookiesKey) as? [[String: Any]] ?? []
    let targetHosts = restoreTargetHosts(for: url)
    let cookies = savedCookies
      .compactMap(cookie(from:))
      .flatMap { cookie in cookiesForRestore(cookie, targetHosts: targetHosts) }

    if cookies.isEmpty {
      finish(result, false)
      return
    }

    let group = DispatchGroup()
    cookies.forEach { cookie in
      group.enter()
      cookieStore.setCookie(cookie) {
        group.leave()
      }
    }

    group.notify(queue: .main) {
      result(true)
    }
  }

  private func saveCookies(for url: String, result: @escaping FlutterResult) {
    if isLogoutUrl(url) {
      clearSavedCookies()
      finish(result, false)
      return
    }

    cookieStore.getAllCookies { [weak self] cookies in
      guard let self = self else {
        DispatchQueue.main.async {
          result(false)
        }
        return
      }

      let encodedCookies = cookies
        .filter { self.isSupportedCookie($0) }
        .compactMap { self.encodedCookie($0) }

      if encodedCookies.isEmpty {
        self.finish(result, self.hasSavedCookies)
        return
      }

      self.preferences.set(encodedCookies, forKey: self.cookiesKey)
      self.preferences.set(url, forKey: self.lastUrlKey)
      self.finish(result, true)
    }
  }

  private func clearSavedCookies() {
    preferences.removeObject(forKey: cookiesKey)
    preferences.removeObject(forKey: lastUrlKey)
  }

  private func getNotificationConsent(result: @escaping FlutterResult) {
    guard preferences.object(forKey: notificationConsentKey) != nil else {
      result(nil)
      return
    }

    result(preferences.bool(forKey: notificationConsentKey))
  }

  private func setNotificationConsent(_ allowed: Bool, result: @escaping FlutterResult) {
    preferences.set(allowed, forKey: notificationConsentKey)
    result(nil)
  }

  private var hasSavedCookies: Bool {
    guard let savedCookies = preferences.array(forKey: cookiesKey) as? [[String: Any]] else {
      return false
    }

    return !savedCookies.isEmpty
  }

  private func encodedCookie(_ cookie: HTTPCookie) -> [String: Any]? {
    guard let properties = cookie.properties else {
      return nil
    }

    var encoded: [String: Any] = [:]
    properties.forEach { key, value in
      if let plistValue = propertyListValue(value) {
        encoded[key.rawValue] = plistValue
      }
    }

    return encoded.isEmpty ? nil : encoded
  }

  private func cookie(from encoded: [String: Any]) -> HTTPCookie? {
    var properties: [HTTPCookiePropertyKey: Any] = [:]
    encoded.forEach { key, value in
      properties[HTTPCookiePropertyKey(rawValue: key)] = value
    }

    return HTTPCookie(properties: properties)
  }

  private func cookiesForRestore(_ cookie: HTTPCookie, targetHosts: [String]) -> [HTTPCookie] {
    let targetCookies = targetHosts.compactMap { copiedCookie(cookie, forHost: $0) }
    return [cookie] + targetCookies
  }

  private func copiedCookie(_ cookie: HTTPCookie, forHost host: String) -> HTTPCookie? {
    guard var properties = cookie.properties else {
      return nil
    }

    properties[.domain] = host
    properties[.path] = "/"
    return HTTPCookie(properties: properties)
  }

  private func propertyListValue(_ value: Any) -> Any? {
    switch value {
    case let value as String:
      return value
    case let value as Date:
      return value
    case let value as Bool:
      return value
    case let value as NSNumber:
      return value
    default:
      return nil
    }
  }

  private func isSupportedCookie(_ cookie: HTTPCookie) -> Bool {
    let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return supportedDomains.contains { domain == $0 || domain.hasSuffix(".\($0)") }
  }

  private func restoreTargetHosts(for url: String) -> [String] {
    var hosts: [String] = []
    appendHost(from: url, to: &hosts)

    if let lastUrl = preferences.string(forKey: lastUrlKey) {
      appendHost(from: lastUrl, to: &hosts)
    }

    return hosts
  }

  private func appendHost(from url: String, to hosts: inout [String]) {
    guard let host = URL(string: url)?.host?.lowercased(),
          !hosts.contains(host),
          supportedDomains.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else {
      return
    }

    hosts.append(host)
  }

  private func isLogoutUrl(_ url: String) -> Bool {
    let normalized = url.lowercased()
    return [
      "logout",
      "log_out",
      "signout",
      "sign_out",
      "cikis",
      "oturumkapat",
      "oturumu_kapat",
    ].contains { normalized.contains($0) }
  }

  private func finish(_ result: @escaping FlutterResult, _ value: Any) {
    DispatchQueue.main.async {
      result(value)
    }
  }
}
