import AVFoundation
import Flutter
import Photos
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var localMediaChannel: FlutterMethodChannel?
  private let taskLock = NSLock()
  private var activeCancelPaths: [String: URL] = [:]
  private var activeProgressPaths: [String: URL] = [:]
  private var activeProgressTimers: [String: DispatchSourceTimer] = [:]
  private var activeExporters: [String: AVAssetExportSession] = [:]
  private var activeTaskDirectories: [String: URL] = [:]
  private var finishingTaskIDs: Set<String> = []
  private var cancelledTaskIDs: Set<String> = []
  private let maxDownloadBytes: Int64 = 8 * 1024 * 1024 * 1024

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
    case "getCapabilities":
      let capabilities: [String: Any] = [
        "platform": "ios",
        "local_resolver": true,
        "engine_update": false,
        "download_progress": true,
        "download_cancellation": true,
        "background_download": false,
        "save_to_files": true,
        "save_to_gallery": true,
        "tools": [
          "resolve": true,
          "audio_extract": false,
          "compress": false,
          "web_sniff": false,
          "direct_download": false,
          "magnet": false,
          "torrent": false,
          "metadata": false,
          "music_search": true,
        ],
      ]
      result(capabilities)
    case "resolve":
      runPython(function: "resolve", arguments: call.arguments, result: result)
    case "download":
      guard var arguments = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "下载参数不正确", details: nil))
        return
      }
      do {
        let task = try reserveDownloadDirectory(
          requestedID: arguments["process_id"] as? String
        )
        arguments["process_id"] = task.id
        arguments["output_dir"] = task.directory.path
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
      result(FlutterError(
        code: "ENGINE_UPDATE_UNSUPPORTED",
        message: "iOS 解析引擎随应用版本更新，当前不支持在应用内单独更新",
        details: nil
      ))
    case "cancelDownload":
      guard let arguments = call.arguments as? [String: Any],
            let processID = arguments["process_id"] as? String else {
        result(["cancelled": false])
        return
      }
      result(["cancelled": cancelDownload(processID: processID)])
    case "clearSession":
      taskLock.lock()
      let activeIDs = Array(activeCancelPaths.keys)
      taskLock.unlock()
      activeIDs.forEach { _ = cancelDownload(processID: $0) }
      runPython(function: "clear_session", arguments: [:], result: result)
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
      var processID: String?
      do {
        var requestArguments = arguments as? [String: Any] ?? [:]
        let saveDestination = requestArguments["save_destination"] as? String ?? "files"
        let mediaType = requestArguments["media_type"] as? String ?? "file"
        if function == "download" {
          let candidate = requestArguments["process_id"] as? String
          let taskID: String
          if let candidate, !candidate.isEmpty {
            taskID = candidate
          } else {
            taskID = UUID().uuidString
          }
          processID = taskID
          let paths = try self.prepareDownloadTask(processID: taskID)
          requestArguments["process_id"] = taskID
          requestArguments["progress_path"] = paths.progress.path
          requestArguments["cancel_path"] = paths.cancel.path
        }
        let data = try JSONSerialization.data(withJSONObject: requestArguments)
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
           let outputPath = payload["path"] as? String,
           let processID {
          self.mergeDownloadedMedia(
            videoPath: videoPath,
            audioPath: audioPath,
            outputPath: outputPath,
            payload: payload,
            saveDestination: saveDestination,
            mediaType: mediaType,
            processID: processID,
            result: result
          )
          return
        }
        if function == "download",
           let payload = decoded as? [String: Any],
           let processID {
          self.finishDownloadedMedia(
            payload: payload,
            saveDestination: saveDestination,
            mediaType: mediaType,
            processID: processID,
            result: result
          )
          return
        }
        DispatchQueue.main.async { result(decoded) }
      } catch {
        if let processID {
          self.finishDownloadTask(processID: processID)
        }
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

  private func prepareDownloadTask(processID: String) throws -> (progress: URL, cancel: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("langbai-native-tasks", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let safeID = processID.replacingOccurrences(
      of: "[^A-Za-z0-9_-]",
      with: "_",
      options: .regularExpression
    )
    let progress = directory.appendingPathComponent("\(safeID).progress.json")
    let cancel = directory.appendingPathComponent("\(safeID).cancel")
    try? FileManager.default.removeItem(at: progress)
    try? FileManager.default.removeItem(at: cancel)

    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now(), repeating: .milliseconds(300))
    timer.setEventHandler { [weak self] in
      guard let self,
            let data = try? Data(contentsOf: progress),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return
      }
      var message = payload
      message["process_id"] = processID
      DispatchQueue.main.async {
        self.localMediaChannel?.invokeMethod("downloadProgress", arguments: message)
      }
    }
    taskLock.lock()
    activeCancelPaths[processID] = cancel
    activeProgressPaths[processID] = progress
    activeProgressTimers[processID] = timer
    let wasAlreadyCancelled = cancelledTaskIDs.contains(processID)
    taskLock.unlock()
    if wasAlreadyCancelled {
      _ = FileManager.default.createFile(atPath: cancel.path, contents: Data("cancel".utf8))
    }
    timer.resume()
    return (progress, cancel)
  }

  private func reserveDownloadDirectory(
    requestedID: String?
  ) throws -> (id: String, directory: URL) {
    let cleaned = (requestedID ?? "").replacingOccurrences(
      of: "[^A-Za-z0-9_-]",
      with: "",
      options: .regularExpression
    )
    let processID = cleaned.isEmpty ? UUID().uuidString : String(cleaned.prefix(64))
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("langbai-native-downloads", isDirectory: true)
    let directory = base.appendingPathComponent(processID, isDirectory: true)
    taskLock.lock()
    if activeTaskDirectories[processID] != nil {
      taskLock.unlock()
      throw NSError(
        domain: "com.langbai.resolver",
        code: 8,
        userInfo: [NSLocalizedDescriptionKey: "同一下载任务已在运行"]
      )
    }
    activeTaskDirectories[processID] = directory
    taskLock.unlock()
    do {
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: directory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return (processID, directory)
    } catch {
      taskLock.lock()
      activeTaskDirectories.removeValue(forKey: processID)
      taskLock.unlock()
      throw error
    }
  }

  @discardableResult
  private func cancelDownload(processID: String) -> Bool {
    taskLock.lock()
    let cancelPath = activeCancelPaths[processID]
    let exporter = activeExporters[processID]
    let hasActiveTask = cancelPath != nil
      || exporter != nil
      || activeTaskDirectories[processID] != nil
    if hasActiveTask { cancelledTaskIDs.insert(processID) }
    taskLock.unlock()
    guard hasActiveTask else { return false }
    if let cancelPath {
      _ = FileManager.default.createFile(
        atPath: cancelPath.path,
        contents: Data("cancel".utf8)
      )
    }
    exporter?.cancelExport()
    return true
  }

  private func finishDownloadTask(processID: String) {
    taskLock.lock()
    if finishingTaskIDs.contains(processID) {
      taskLock.unlock()
      return
    }
    finishingTaskIDs.insert(processID)
    let timer = activeProgressTimers.removeValue(forKey: processID)
    let progress = activeProgressPaths.removeValue(forKey: processID)
    let cancel = activeCancelPaths.removeValue(forKey: processID)
    let taskDirectory = activeTaskDirectories[processID]
    activeExporters.removeValue(forKey: processID)
    taskLock.unlock()
    timer?.cancel()
    if let progress { try? FileManager.default.removeItem(at: progress) }
    if let cancel { try? FileManager.default.removeItem(at: cancel) }
    if let taskDirectory { try? FileManager.default.removeItem(at: taskDirectory) }
    taskLock.lock()
    if activeTaskDirectories[processID] == taskDirectory {
      activeTaskDirectories.removeValue(forKey: processID)
    }
    cancelledTaskIDs.remove(processID)
    finishingTaskIDs.remove(processID)
    taskLock.unlock()
  }

  private func emitDownloadProgress(
    processID: String,
    progress: Double,
    status: String
  ) {
    DispatchQueue.main.async {
      self.localMediaChannel?.invokeMethod("downloadProgress", arguments: [
        "process_id": processID,
        "progress": min(100, max(0, progress)),
        "status": status,
      ])
    }
  }

  private func mergeDownloadedMedia(
    videoPath: String,
    audioPath: String,
    outputPath: String,
    payload: [String: Any],
    saveDestination: String,
    mediaType: String,
    processID: String,
    result: @escaping FlutterResult
  ) {
    let videoURL = URL(fileURLWithPath: videoPath)
    let audioURL = URL(fileURLWithPath: audioPath)
    let outputURL = URL(fileURLWithPath: outputPath)
    do {
      taskLock.lock()
      let cancelPath = activeCancelPaths[processID]
      taskLock.unlock()
      if let cancelPath, FileManager.default.fileExists(atPath: cancelPath.path) {
        throw NSError(
          domain: "com.langbai.resolver",
          code: 9,
          userInfo: [NSLocalizedDescriptionKey: "下载已取消"]
        )
      }
      _ = try validatedTaskFile(path: videoPath, processID: processID)
      _ = try validatedTaskFile(path: audioPath, processID: processID)
      let videoBytes = try fileSize(of: videoURL)
      let audioBytes = try fileSize(of: audioURL)
      guard videoBytes <= maxDownloadBytes - audioBytes else {
        throw NSError(
          domain: "com.langbai.resolver",
          code: 28,
          userInfo: [NSLocalizedDescriptionKey: "音画合并后的文件预计超过 8 GB 安全上限"]
        )
      }
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
      emitDownloadProgress(processID: processID, progress: 92, status: "正在合并音画")
      taskLock.lock()
      activeExporters[processID] = exporter
      if cancelledTaskIDs.contains(processID) {
        taskLock.unlock()
        exporter.cancelExport()
        throw NSError(
          domain: "com.langbai.resolver",
          code: 9,
          userInfo: [NSLocalizedDescriptionKey: "下载已取消"]
        )
      }
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
            processID: processID,
            result: result
          )
        } else {
          try? FileManager.default.removeItem(at: outputURL)
          let message = exporter.status == .cancelled
            ? "下载已取消"
            : exporter.error?.localizedDescription ?? "iOS 合并B站最高画质失败"
          self.finishDownloadTask(processID: processID)
          DispatchQueue.main.async {
            result(FlutterError(code: "LOCAL_MEDIA_ERROR", message: message, details: nil))
          }
        }
      }
      taskLock.unlock()
    } catch {
      try? FileManager.default.removeItem(at: videoURL)
      try? FileManager.default.removeItem(at: audioURL)
      try? FileManager.default.removeItem(at: outputURL)
      finishDownloadTask(processID: processID)
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
    processID: String,
    result: @escaping FlutterResult
  ) {
    guard let path = payload["path"] as? String else {
      finishDownloadTask(processID: processID)
      DispatchQueue.main.async {
        result(FlutterError(
          code: "LOCAL_MEDIA_ERROR",
          message: "下载结果缺少文件路径",
          details: nil
        ))
      }
      return
    }
    let fileURL: URL
    do {
      fileURL = try validatedTaskFile(path: path, processID: processID)
    } catch {
      finishDownloadTask(processID: processID)
      DispatchQueue.main.async {
        result(FlutterError(
          code: "LOCAL_MEDIA_ERROR",
          message: error.localizedDescription,
          details: nil
        ))
      }
      return
    }
    guard saveDestination == "gallery" else {
      do {
        let saved = try moveDownloadedFileToDocuments(fileURL, payload: payload)
        emitDownloadProgress(processID: processID, progress: 100, status: "下载完成")
        finishDownloadTask(processID: processID)
        DispatchQueue.main.async { result(saved) }
      } catch {
        finishDownloadTask(processID: processID)
        DispatchQueue.main.async {
          result(FlutterError(
            code: "LOCAL_MEDIA_ERROR",
            message: error.localizedDescription,
            details: nil
          ))
        }
      }
      return
    }
    guard mediaType == "image" || mediaType == "video",
          !path.isEmpty else {
      DispatchQueue.main.async {
        self.finishDownloadTask(processID: processID)
        result(FlutterError(
          code: "PHOTO_LIBRARY_ERROR",
          message: "该资源不能保存到相册",
          details: nil
        ))
      }
      return
    }
    saveMediaToPhotos(fileURL: fileURL, mediaType: mediaType) { error in
      if let error {
        self.finishDownloadTask(processID: processID)
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
      self.emitDownloadProgress(processID: processID, progress: 100, status: "下载完成")
      self.finishDownloadTask(processID: processID)
      result(saved)
    }
  }

  private func validatedTaskFile(path: String, processID: String) throws -> URL {
    taskLock.lock()
    let taskDirectory = activeTaskDirectories[processID]
    taskLock.unlock()
    guard let taskDirectory else {
      throw NSError(
        domain: "com.langbai.resolver",
        code: 24,
        userInfo: [NSLocalizedDescriptionKey: "下载任务目录已失效"]
      )
    }
    let fileURL = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    let directoryURL = taskDirectory.standardizedFileURL.resolvingSymlinksInPath()
    guard fileURL.path.hasPrefix(directoryURL.path + "/") else {
      throw NSError(
        domain: "com.langbai.resolver",
        code: 25,
        userInfo: [NSLocalizedDescriptionKey: "下载结果路径不安全"]
      )
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw NSError(
        domain: "com.langbai.resolver",
        code: 26,
        userInfo: [NSLocalizedDescriptionKey: "下载结果不是普通文件"]
      )
    }
    let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    guard fileSize <= maxDownloadBytes else {
      throw NSError(
        domain: "com.langbai.resolver",
        code: 27,
        userInfo: [NSLocalizedDescriptionKey: "最终文件超过 8 GB 安全上限"]
      )
    }
    return fileURL
  }

  private func fileSize(of fileURL: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    return (attributes[.size] as? NSNumber)?.int64Value ?? 0
  }

  private func moveDownloadedFileToDocuments(
    _ source: URL,
    payload: [String: Any]
  ) throws -> [String: Any] {
    let documents = try FileManager.default.url(
      for: .documentDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = documents.appendingPathComponent("langbai解析", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = availableDestination(
      in: directory,
      filename: source.lastPathComponent
    )
    try FileManager.default.moveItem(at: source, to: destination)
    var saved = payload
    saved["filename"] = destination.lastPathComponent
    saved["path"] = destination.path
    saved["message"] = "已保存到“文件”App/langbai解析/\(destination.lastPathComponent)"
    return saved
  }

  private func availableDestination(in directory: URL, filename: String) -> URL {
    let manager = FileManager.default
    let initial = directory.appendingPathComponent(filename)
    if !manager.fileExists(atPath: initial.path) { return initial }
    let source = URL(fileURLWithPath: filename)
    let stem = source.deletingPathExtension().lastPathComponent
    let extensionName = source.pathExtension
    for index in 2..<10_000 {
      let suffix = extensionName.isEmpty ? "" : ".\(extensionName)"
      let candidate = directory.appendingPathComponent("\(stem) (\(index))\(suffix)")
      if !manager.fileExists(atPath: candidate.path) { return candidate }
    }
    return directory.appendingPathComponent("\(UUID().uuidString)-\(filename)")
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
