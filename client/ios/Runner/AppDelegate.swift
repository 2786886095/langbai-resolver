import AVFoundation
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
        if function == "download",
           let payload = decoded as? [String: Any],
           let videoPath = payload["merge_video_path"] as? String,
           let audioPath = payload["merge_audio_path"] as? String,
           let outputPath = payload["path"] as? String {
          self.mergeDownloadedMedia(
            videoPath: videoPath,
            audioPath: audioPath,
            outputPath: outputPath,
            payload: payload,
            result: result
          )
          return
        }
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

  private func mergeDownloadedMedia(
    videoPath: String,
    audioPath: String,
    outputPath: String,
    payload: [String: Any],
    result: @escaping FlutterResult
  ) {
    let videoURL = URL(fileURLWithPath: videoPath)
    let audioURL = URL(fileURLWithPath: audioPath)
    let outputURL = URL(fileURLWithPath: outputPath)
    do {
      let videoAsset = AVURLAsset(url: videoURL)
      let audioAsset = AVURLAsset(url: audioURL)
      guard let sourceVideo = videoAsset.tracks(withMediaType: .video).first,
            let sourceAudio = audioAsset.tracks(withMediaType: .audio).first else {
        throw NSError(
          domain: "com.langbai.resolver",
          code: 10,
          userInfo: [NSLocalizedDescriptionKey: "B站音画流不完整，无法合并"]
        )
      }
      let composition = AVMutableComposition()
      guard let targetVideo = composition.addMutableTrack(
        withMediaType: .video,
        preferredTrackID: kCMPersistentTrackID_Invalid
      ), let targetAudio = composition.addMutableTrack(
        withMediaType: .audio,
        preferredTrackID: kCMPersistentTrackID_Invalid
      ) else {
        throw NSError(
          domain: "com.langbai.resolver",
          code: 11,
          userInfo: [NSLocalizedDescriptionKey: "无法创建 iOS 音画合并任务"]
        )
      }
      let duration = videoAsset.duration
      let audioDuration = CMTimeCompare(audioAsset.duration, duration) < 0
        ? audioAsset.duration
        : duration
      try targetVideo.insertTimeRange(
        CMTimeRange(start: .zero, duration: duration),
        of: sourceVideo,
        at: .zero
      )
      try targetAudio.insertTimeRange(
        CMTimeRange(start: .zero, duration: audioDuration),
        of: sourceAudio,
        at: .zero
      )
      targetVideo.preferredTransform = sourceVideo.preferredTransform
      try? FileManager.default.removeItem(at: outputURL)
      guard let exporter = AVAssetExportSession(
        asset: composition,
        presetName: AVAssetExportPresetPassthrough
      ) else {
        throw NSError(
          domain: "com.langbai.resolver",
          code: 12,
          userInfo: [NSLocalizedDescriptionKey: "iOS 不支持该B站视频编码的无损合并"]
        )
      }
      exporter.outputURL = outputURL
      exporter.outputFileType = .mp4
      exporter.shouldOptimizeForNetworkUse = true
      exporter.exportAsynchronously {
        defer {
          try? FileManager.default.removeItem(at: videoURL)
          try? FileManager.default.removeItem(at: audioURL)
        }
        if exporter.status == .completed {
          var cleaned = payload
          cleaned.removeValue(forKey: "merge_video_path")
          cleaned.removeValue(forKey: "merge_audio_path")
          DispatchQueue.main.async { result(cleaned) }
        } else {
          let message = exporter.error?.localizedDescription ?? "iOS 合并B站最高画质失败"
          DispatchQueue.main.async {
            result(FlutterError(code: "LOCAL_MEDIA_ERROR", message: message, details: nil))
          }
        }
      }
    } catch {
      try? FileManager.default.removeItem(at: videoURL)
      try? FileManager.default.removeItem(at: audioURL)
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
