import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var localMediaChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    guard let controller = window?.rootViewController as? FlutterViewController else {
      return false
    }
    let channel = FlutterMethodChannel(
      name: "com.langbai.resolver/local_media",
      binaryMessenger: controller.binaryMessenger
    )
    localMediaChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleLocalMedia(call, result: result)
    }
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func handleLocalMedia(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(true)
    case "resolve":
      runPython(function: "resolve", arguments: call.arguments, result: result)
    case "download":
      guard var arguments = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "下载参数不正确", details: nil))
        return
      }
      do {
        let documents = try FileManager.default.url(
          for: .documentDirectory,
          in: .userDomainMask,
          appropriateFor: nil,
          create: true
        )
        let output = documents.appendingPathComponent("langbai解析", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        arguments["output_dir"] = output.path
        runPython(function: "download", arguments: arguments, result: result)
      } catch {
        result(FlutterError(code: "LOCAL_MEDIA_ERROR", message: error.localizedDescription, details: nil))
      }
    case "updateEngine":
      runPython(function: "version", arguments: [:], result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func runPython(
    function: String,
    arguments: Any?,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let object = arguments ?? [:]
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let json = String(data: data, encoding: .utf8) else {
          throw NSError(
            domain: "com.langbai.resolver",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "无法编码本地解析参数"]
          )
        }
        let runtime = LBPythonRuntime.shared()
        try runtime.initializeRuntime()
        let output = try runtime.callFunction(function, jsonArgument: json)
        guard let outputData = output.data(using: .utf8) else {
          throw NSError(
            domain: "com.langbai.resolver",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "iOS 本地解析器没有返回结果"]
          )
        }
        let decoded = try JSONSerialization.jsonObject(with: outputData)
        DispatchQueue.main.async { result(decoded) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "LOCAL_MEDIA_ERROR",
            message: error.localizedDescription,
            details: nil
          ))
        }
      }
    }
  }
}
