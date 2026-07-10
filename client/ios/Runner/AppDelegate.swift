import AVFoundation
import Flutter
import Photos
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
    case "saveMobileFile":
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "保存参数不正确", details: nil))
        return
      }
      let mediaType = arguments["media_type"] as? String ?? "file"
      guard mediaType == "image" || mediaType == "video" else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "只有图片和视频可以保存到相册", details: nil))
        return
      }
      let filename = arguments["filename"] as? String
        ?? URL(fileURLWithPath: path).lastPathComponent
      saveMediaToPhotos(
        fileURL: URL(fileURLWithPath: path),
        mediaType: mediaType
      ) { error in
        if let error {
          result(FlutterError(code: "PHOTO_LIBRARY_ERROR", message: error.localizedDescription, details: nil))
        } else {
          result([
            "filename": filename,
            "message": "已保存到系统相册",
          ])
        }
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
        let requestArguments = object as? [String: Any]
        let saveDestination = requestArguments?["save_destination"] as? String ?? "files"
        let mediaType = requestArguments?["media_type"] as? String ?? "file"
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
            saveDestination: saveDestination,
            mediaType: mediaType,
            result: result
          )
          return
        }
        if function == "download", let payload = decoded as? [String: Any] {
          self.finishDownloadedMedia(
            payload: payload,
            saveDestination: saveDestination,
            mediaType: mediaType,
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
    saveDestination: String,
    mediaType: String,
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
          self.finishDownloadedMedia(
            payload: cleaned,
            saveDestination: saveDestination,
            mediaType: mediaType,
            result: result
          )
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

  private func finishDownloadedMedia(
    payload: [String: Any],
    saveDestination: String,
    mediaType: String,
    result: @escaping FlutterResult
  ) {
    guard saveDestination == "gallery" else {
      DispatchQueue.main.async { result(payload) }
      return
    }
    guard mediaType == "image" || mediaType == "video",
          let path = payload["path"] as? String else {
      DispatchQueue.main.async {
        result(FlutterError(
          code: "PHOTO_LIBRARY_ERROR",
          message: "该资源不能保存到相册",
          details: nil
        ))
      }
      return
    }
    let fileURL = URL(fileURLWithPath: path)
    saveMediaToPhotos(fileURL: fileURL, mediaType: mediaType) { error in
      if let error {
        result(FlutterError(
          code: "PHOTO_LIBRARY_ERROR",
          message: error.localizedDescription,
          details: nil
        ))
        return
      }
      try? FileManager.default.removeItem(at: fileURL)
      var saved = payload
      saved.removeValue(forKey: "path")
      saved["message"] = "已保存到系统相册"
      result(saved)
    }
  }

  private func saveMediaToPhotos(
    fileURL: URL,
    mediaType: String,
    completion: @escaping (Error?) -> Void
  ) {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      DispatchQueue.main.async {
        completion(NSError(
          domain: "com.langbai.resolver",
          code: 20,
          userInfo: [NSLocalizedDescriptionKey: "待保存的媒体文件不存在"]
        ))
      }
      return
    }

    let save = {
      PHPhotoLibrary.shared().performChanges {
        if mediaType == "video" {
          PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
        } else {
          PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
        }
      } completionHandler: { success, error in
        DispatchQueue.main.async {
          if success {
            completion(nil)
          } else {
            completion(error ?? NSError(
              domain: "com.langbai.resolver",
              code: 21,
              userInfo: [NSLocalizedDescriptionKey: "系统相册不支持该媒体格式"]
            ))
          }
        }
      }
    }

    let handleAuthorization: (PHAuthorizationStatus) -> Void = { status in
      if status == .authorized {
        save()
        return
      }
      if #available(iOS 14, *), status == .limited {
        save()
        return
      }
      if status == .denied || status == .restricted {
        DispatchQueue.main.async {
          completion(NSError(
            domain: "com.langbai.resolver",
            code: 22,
            userInfo: [NSLocalizedDescriptionKey: "没有相册权限，请在系统设置中允许添加照片"]
          ))
        }
        return
      }
      DispatchQueue.main.async {
        completion(NSError(
          domain: "com.langbai.resolver",
          code: 23,
          userInfo: [NSLocalizedDescriptionKey: "无法获得系统相册权限"]
        ))
      }
    }

    if #available(iOS 14, *) {
      PHPhotoLibrary.requestAuthorization(for: .addOnly, handler: handleAuthorization)
    } else {
      PHPhotoLibrary.requestAuthorization(handleAuthorization)
    }
  }
}
