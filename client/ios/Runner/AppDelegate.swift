import AVFoundation
import Flutter
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, UIDocumentPickerDelegate {
  private var localMediaChannel: FlutterMethodChannel?
  private let taskLock = NSLock()
  private var activeCancelPaths: [String: URL] = [:]
  private var activeProgressPaths: [String: URL] = [:]
  private var activeProgressTimers: [String: DispatchSourceTimer] = [:]
  private var activeConversionTimers: [String: DispatchSourceTimer] = [:]
  private var activeExporters: [String: AVAssetExportSession] = [:]
  private var activeTaskDirectories: [String: URL] = [:]
  private var finishingTaskIDs: Set<String> = []
  private var cancelledTaskIDs: Set<String> = []
  private var pendingDirectoryPickerResult: FlutterResult?
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
        "custom_save_directory": true,
        "format_conversion": true,
        "media_probe": true,
        "conversion_progress": true,
        "conversion_cancellation": true,
        "app_update_install": false,
        "conversion": [
          "input_extensions": [
            "mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav",
            "jpg", "jpeg", "png", "heic", "heif",
          ],
          "output_formats": ["mp4", "m4v", "mov", "m4a", "jpg", "jpeg", "png", "heic"],
          "quality_values": ["low", "medium", "high", "original"],
        ],
        "tools": [
          "resolve": true,
          "audio_extract": true,
          "compress": true,
          "format_conversion": true,
          "web_sniff": false,
          "direct_download": false,
          "magnet": false,
          "torrent": false,
          "metadata": true,
          "music_search": true,
        ],
        "unsupported_tools": [
          "magnet": "iPhone 安装包未内置 P2P 引擎；请在 Windows 端使用磁力下载。",
          "torrent": "iPhone 安装包未内置种子/P2P 引擎；请在 Windows 端使用。",
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
      guard let arguments = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "保存参数不正确", details: nil))
        return
      }
      saveMobileFile(arguments: arguments, result: result)
    case "pickSaveDirectory":
      presentDirectoryPicker(result: result)
    case "convertMedia":
      guard let arguments = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "转换参数不正确", details: nil))
        return
      }
      startMediaConversion(arguments: arguments, result: result)
    case "probeMedia":
      guard let arguments = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "媒体检测参数不正确", details: nil))
        return
      }
      probeMedia(arguments: arguments, result: result)
    case "cancelConversion":
      guard let arguments = call.arguments as? [String: Any],
            let processID = arguments["process_id"] as? String else {
        result(["cancelled": false])
        return
      }
      result(["cancelled": cancelConversion(processID: processID)])
    case "installAppUpdate":
      result(FlutterError(
        code: "APP_UPDATE_UNSUPPORTED",
        message: "iPhone 不能在应用内安装更新，请通过正式分发渠道更新",
        details: nil
      ))
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
      let activeIDs = Array(Set(activeCancelPaths.keys).union(activeTaskDirectories.keys))
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
        var requestArguments = (arguments as? [String: Any]) ?? [:]
        let saveDestination = (requestArguments["save_destination"] as? String) ?? "files"
        let mediaType = (requestArguments["media_type"] as? String) ?? "file"
        let customDestinationURI = requestArguments["custom_destination_uri"] as? String
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
            customDestinationURI: customDestinationURI,
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
            customDestinationURI: customDestinationURI,
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

  @discardableResult
  private func cancelConversion(processID: String) -> Bool {
    taskLock.lock()
    let exporter = activeExporters[processID]
    let hasActiveTask = exporter != nil || activeTaskDirectories[processID] != nil
    if hasActiveTask { cancelledTaskIDs.insert(processID) }
    taskLock.unlock()
    exporter?.cancelExport()
    return hasActiveTask
  }

  private func finishDownloadTask(processID: String) {
    taskLock.lock()
    if finishingTaskIDs.contains(processID) {
      taskLock.unlock()
      return
    }
    finishingTaskIDs.insert(processID)
    let timer = activeProgressTimers.removeValue(forKey: processID)
    let conversionTimer = activeConversionTimers.removeValue(forKey: processID)
    let progress = activeProgressPaths.removeValue(forKey: processID)
    let cancel = activeCancelPaths.removeValue(forKey: processID)
    let taskDirectory = activeTaskDirectories[processID]
    activeExporters.removeValue(forKey: processID)
    taskLock.unlock()
    timer?.cancel()
    conversionTimer?.cancel()
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
    status: String,
    downloadedBytes: Int64? = nil,
    totalBytes: Int64? = nil,
    speedBytesPerSecond: Double? = nil,
    averageSpeedBytesPerSecond: Double? = nil
  ) {
    DispatchQueue.main.async {
      self.localMediaChannel?.invokeMethod("downloadProgress", arguments: [
        "process_id": processID,
        "progress": min(100, max(0, progress)),
        "status": status,
        "downloaded_bytes": downloadedBytes.map { $0 as Any } ?? NSNull(),
        "total_bytes": totalBytes.map { $0 as Any } ?? NSNull(),
        "speed_bytes_per_second": speedBytesPerSecond.map { $0 as Any } ?? NSNull(),
        "average_speed_bytes_per_second": averageSpeedBytesPerSecond.map { $0 as Any } ?? NSNull(),
      ])
    }
  }

  private func mergeDownloadedMedia(
    videoPath: String,
    audioPath: String,
    outputPath: String,
    payload: [String: Any],
    saveDestination: String,
    customDestinationURI: String?,
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
            customDestinationURI: customDestinationURI,
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
    customDestinationURI: String?,
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
    if saveDestination == "custom" {
      do {
        guard let customDestinationURI else {
          throw shortError(code: 40, message: "请先选择保存目录")
        }
        let saved = try copyFileToCustomDirectory(
          fileURL,
          destinationIdentifier: customDestinationURI,
          payload: payload
        )
        try? FileManager.default.removeItem(at: fileURL)
        emitDownloadProgress(processID: processID, progress: 100, status: "下载完成")
        finishDownloadTask(processID: processID)
        DispatchQueue.main.async { result(saved) }
      } catch {
        finishDownloadTask(processID: processID)
        DispatchQueue.main.async {
          result(FlutterError(code: "LOCAL_MEDIA_ERROR", message: error.localizedDescription, details: nil))
        }
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
          message: self.conciseMessage(error, fallback: "保存到相册失败，请检查权限和文件格式"),
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
    guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
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

  private func shortError(code: Int, message: String) -> NSError {
    NSError(
      domain: "com.langbai.resolver",
      code: code,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }

  private func conciseMessage(_ error: Error, fallback: String) -> String {
    let value = error as NSError
    if value.domain == "com.langbai.resolver" {
      return String(value.localizedDescription.prefix(80))
    }
    return fallback
  }

  private func presentDirectoryPicker(result: @escaping FlutterResult) {
    guard pendingDirectoryPickerResult == nil else {
      result(FlutterError(code: "DIRECTORY_PICK_ACTIVE", message: "目录选择窗口已打开", details: nil))
      return
    }
    pendingDirectoryPickerResult = result
    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
    } else {
      picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
    }
    picker.delegate = self
    picker.allowsMultipleSelection = false
    guard let controller = window?.rootViewController else {
      pendingDirectoryPickerResult = nil
      result(FlutterError(code: "DIRECTORY_PICK_UNAVAILABLE", message: "系统目录选择器不可用", details: nil))
      return
    }
    controller.present(picker, animated: true)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let result = pendingDirectoryPickerResult else { return }
    pendingDirectoryPickerResult = nil
    guard let url = urls.first else {
      result(FlutterError(code: "DIRECTORY_PICK_CANCELLED", message: "未选择保存目录", details: nil))
      return
    }
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    do {
      let bookmark = try url.bookmarkData(
        options: .minimalBookmark,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      result([
        "uri": "bookmark:\(bookmark.base64EncodedString())",
        "name": url.lastPathComponent.isEmpty ? "自选目录" : url.lastPathComponent,
      ])
    } catch {
      result(FlutterError(code: "DIRECTORY_PERMISSION", message: "无法保留该目录的写入权限", details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard let result = pendingDirectoryPickerResult else { return }
    pendingDirectoryPickerResult = nil
    result(FlutterError(code: "DIRECTORY_PICK_CANCELLED", message: "未选择保存目录", details: nil))
  }

  private func resolveCustomDirectory(_ identifier: String) throws -> URL {
    guard identifier.hasPrefix("bookmark:"),
          let data = Data(base64Encoded: String(identifier.dropFirst("bookmark:".count))) else {
      throw shortError(code: 41, message: "自选目录地址无效")
    }
    var stale = false
    let url = try URL(
      resolvingBookmarkData: data,
      options: [.withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    )
    guard !stale else {
      throw shortError(code: 42, message: "自选目录权限已失效，请重新选择")
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
      throw shortError(code: 43, message: "自选目录不可用，请重新选择")
    }
    return url
  }

  private func copyFileToCustomDirectory(
    _ source: URL,
    destinationIdentifier: String,
    payload: [String: Any]
  ) throws -> [String: Any] {
    let directory = try resolveCustomDirectory(destinationIdentifier)
    let accessing = directory.startAccessingSecurityScopedResource()
    defer { if accessing { directory.stopAccessingSecurityScopedResource() } }
    let requestedName = (payload["filename"] as? String).flatMap {
      URL(fileURLWithPath: $0).lastPathComponent.isEmpty
        ? nil
        : URL(fileURLWithPath: $0).lastPathComponent
    } ?? source.lastPathComponent
    let destination = availableDestination(in: directory, filename: requestedName)
    do {
      try FileManager.default.copyItem(at: source, to: destination)
    } catch {
      throw shortError(code: 44, message: "无法写入自选目录")
    }
    var saved = payload
    saved["filename"] = destination.lastPathComponent
    saved["path"] = destination.path
    saved["message"] = "已保存到自选目录/\(destination.lastPathComponent)"
    return saved
  }

  private func copyFileToDocuments(
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
    let requestedName = (payload["filename"] as? String).flatMap {
      URL(fileURLWithPath: $0).lastPathComponent.isEmpty
        ? nil
        : URL(fileURLWithPath: $0).lastPathComponent
    } ?? source.lastPathComponent
    let destination = availableDestination(in: directory, filename: requestedName)
    try FileManager.default.copyItem(at: source, to: destination)
    var saved = payload
    saved["filename"] = destination.lastPathComponent
    saved["path"] = destination.path
    saved["message"] = "已保存到“文件”App/langbai解析/\(destination.lastPathComponent)"
    return saved
  }

  private func saveMobileFile(
    arguments: [String: Any],
    result: @escaping FlutterResult
  ) {
    guard let path = arguments["path"] as? String, !path.isEmpty else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "待保存文件不存在", details: nil))
      return
    }
    let source = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: source.path) else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "待保存文件不存在", details: nil))
      return
    }
    let destination = (arguments["save_destination"] as? String) ?? "files"
    let mediaType = (arguments["media_type"] as? String) ?? "file"
    let filename = (arguments["filename"] as? String) ?? source.lastPathComponent
    if destination == "gallery" {
      guard mediaType == "image" || mediaType == "video" else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "只有图片和视频可以保存到相册", details: nil))
        return
      }
      saveMediaToPhotos(fileURL: source, mediaType: mediaType) { error in
        if let error {
          result(FlutterError(
            code: "PHOTO_LIBRARY_ERROR",
            message: self.conciseMessage(error, fallback: "保存到相册失败，请检查权限和文件格式"),
            details: nil
          ))
        } else {
          result(["filename": filename, "message": "已保存到系统相册"])
        }
      }
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let payload: [String: Any] = ["filename": filename]
        let saved: [String: Any]
        if destination == "custom" {
          guard let identifier = arguments["custom_destination_uri"] as? String else {
            throw self.shortError(code: 40, message: "请先选择保存目录")
          }
          saved = try self.copyFileToCustomDirectory(
            source,
            destinationIdentifier: identifier,
            payload: payload
          )
        } else {
          saved = try self.copyFileToDocuments(source, payload: payload)
        }
        DispatchQueue.main.async { result(saved) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "LOCAL_MEDIA_ERROR",
            message: self.conciseMessage(error, fallback: "保存文件失败，请重新选择目录"),
            details: nil
          ))
        }
      }
    }
  }

  private func startMediaConversion(
    arguments: [String: Any],
    result: @escaping FlutterResult
  ) {
    let requestedID = arguments["process_id"] as? String
    let format = ((arguments["output_format"] as? String) ?? "")
      .lowercased()
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let quality = (arguments["quality"] as? String) ?? "high"
    guard ["low", "medium", "high", "original"].contains(quality) else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "转换质量参数不正确", details: nil))
      return
    }
    guard IOSConversion.outputFormats.contains(format) else {
      result(FlutterError(code: "CONVERSION_UNSUPPORTED", message: "iPhone 暂不支持转换为 \(format)", details: nil))
      return
    }
    let inputURL: URL
    if let path = arguments["input_path"] as? String, !path.isEmpty {
      inputURL = URL(fileURLWithPath: path)
    } else if let value = arguments["input_uri"] as? String,
              let url = URL(string: value), url.isFileURL {
      inputURL = url
    } else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "请选择待转换文件", details: nil))
      return
    }
    guard FileManager.default.fileExists(atPath: inputURL.path) else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "待转换文件不存在", details: nil))
      return
    }

    let task: (id: String, directory: URL)
    do {
      task = try reserveDownloadDirectory(requestedID: requestedID)
    } catch {
      result(FlutterError(code: "CONVERSION_ERROR", message: "无法创建转换任务", details: nil))
      return
    }
    let destination = (arguments["save_destination"] as? String) ?? "files"
    let customDestinationURI = arguments["custom_destination_uri"] as? String
    let inputExtension = inputURL.pathExtension.lowercased()
    let stem = inputURL.deletingPathExtension().lastPathComponent
      .replacingOccurrences(of: "[\\/:*?\"<>|\\r\\n]+", with: "_", options: .regularExpression)
      .prefix(140)
    let outputURL = task.directory.appendingPathComponent("\(stem).\(format)")

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        self.taskLock.lock()
        let wasCancelled = self.cancelledTaskIDs.contains(task.id)
        self.taskLock.unlock()
        if wasCancelled { throw self.shortError(code: 51, message: "转换已取消") }
        if IOSConversion.imageInputs.contains(inputExtension) {
          guard IOSConversion.imageOutputs.contains(format) else {
            throw self.shortError(code: 52, message: "图片不能转换为该格式")
          }
          self.emitConversionProgress(
            processID: task.id,
            progress: 0,
            status: "正在转换图片"
          )
          try self.convertImage(
            inputURL: inputURL,
            outputURL: outputURL,
            format: format,
            quality: quality
          )
          self.taskLock.lock()
          let cancelled = self.cancelledTaskIDs.contains(task.id)
          self.taskLock.unlock()
          if cancelled { throw self.shortError(code: 51, message: "转换已取消") }
          self.emitConversionProgress(
            processID: task.id,
            progress: 100,
            status: "转换完成"
          )
          self.finishConvertedMedia(
            outputURL: outputURL,
            format: format,
            saveDestination: destination,
            customDestinationURI: customDestinationURI,
            processID: task.id,
            result: result
          )
          return
        }
        try self.startAVConversion(
          inputURL: inputURL,
          outputURL: outputURL,
          format: format,
          quality: quality,
          saveDestination: destination,
          customDestinationURI: customDestinationURI,
          processID: task.id,
          result: result
        )
      } catch {
        try? FileManager.default.removeItem(at: outputURL)
        self.finishDownloadTask(processID: task.id)
        DispatchQueue.main.async {
          result(FlutterError(
            code: "CONVERSION_ERROR",
            message: self.conciseMessage(error, fallback: "格式转换失败，源文件可能不受支持"),
            details: nil
          ))
        }
      }
    }
  }

  private func probeMedia(
    arguments: [String: Any],
    result: @escaping FlutterResult
  ) {
    let inputURL: URL
    if let path = arguments["input_path"] as? String, !path.isEmpty {
      inputURL = URL(fileURLWithPath: path)
    } else if let value = arguments["input_uri"] as? String,
              let url = URL(string: value), url.isFileURL {
      inputURL = url
    } else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "请选择待检测文件", details: nil))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let attributes = try FileManager.default.attributesOfItem(atPath: inputURL.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
          throw self.shortError(code: 63, message: "待检测文件不存在")
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= self.maxDownloadBytes else {
          throw self.shortError(code: 64, message: "文件超过 8 GB 安全上限")
        }
        let ext = inputURL.pathExtension.lowercased()
        if IOSConversion.imageInputs.contains(ext) {
          guard let image = UIImage(contentsOfFile: inputURL.path) else {
            throw self.shortError(code: 65, message: "无法读取该图片格式")
          }
          let scale = image.scale > 0 ? image.scale : 1
          let payload: [String: Any] = [
            "filename": inputURL.lastPathComponent,
            "extension": ext,
            "mime_type": self.localMimeType(ext),
            "size_bytes": size,
            "duration_seconds": NSNull(),
            "width": Int(image.size.width * scale),
            "height": Int(image.size.height * scale),
            "has_video": false,
            "has_audio": false,
            "streams": [[
              "index": 0,
              "type": "image",
              "codec": ext,
              "width": Int(image.size.width * scale),
              "height": Int(image.size.height * scale),
              "sample_rate": NSNull(),
              "channels": NSNull(),
              "bitrate_bps": NSNull(),
            ]],
          ]
          DispatchQueue.main.async { result(payload) }
          return
        }

        let asset = AVURLAsset(url: inputURL)
        let videoTracks = asset.tracks(withMediaType: .video)
        let audioTracks = asset.tracks(withMediaType: .audio)
        var streams: [[String: Any]] = []
        var width: Int?
        var height: Int?
        for (index, track) in videoTracks.enumerated() {
          let transformed = track.naturalSize.applying(track.preferredTransform)
          let trackWidth = Int(abs(transformed.width))
          let trackHeight = Int(abs(transformed.height))
          if (trackWidth * trackHeight) > ((width ?? 0) * (height ?? 0)) {
            width = trackWidth
            height = trackHeight
          }
          streams.append([
            "index": index,
            "type": "video",
            "codec": self.trackCodec(track),
            "width": trackWidth,
            "height": trackHeight,
            "sample_rate": NSNull(),
            "channels": NSNull(),
            "bitrate_bps": track.estimatedDataRate > 0
              ? Int(track.estimatedDataRate) as Any
              : NSNull(),
          ])
        }
        for (offset, track) in audioTracks.enumerated() {
          streams.append([
            "index": videoTracks.count + offset,
            "type": "audio",
            "codec": self.trackCodec(track),
            "width": NSNull(),
            "height": NSNull(),
            "sample_rate": NSNull(),
            "channels": NSNull(),
            "bitrate_bps": track.estimatedDataRate > 0
              ? Int(track.estimatedDataRate) as Any
              : NSNull(),
          ])
        }
        let seconds = CMTimeGetSeconds(asset.duration)
        let payload: [String: Any] = [
          "filename": inputURL.lastPathComponent,
          "extension": ext,
          "mime_type": self.localMimeType(ext),
          "size_bytes": size,
          "duration_seconds": seconds.isFinite && seconds >= 0 ? seconds as Any : NSNull(),
          "width": width.map { $0 as Any } ?? NSNull(),
          "height": height.map { $0 as Any } ?? NSNull(),
          "has_video": !videoTracks.isEmpty,
          "has_audio": !audioTracks.isEmpty,
          "streams": streams,
        ]
        guard !streams.isEmpty else {
          throw self.shortError(code: 66, message: "未发现可读取的媒体流")
        }
        DispatchQueue.main.async { result(payload) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "MEDIA_PROBE_ERROR",
            message: self.conciseMessage(error, fallback: "无法读取媒体信息，文件可能已损坏"),
            details: nil
          ))
        }
      }
    }
  }

  private func trackCodec(_ track: AVAssetTrack) -> Any {
    guard let raw = track.formatDescriptions.first else { return NSNull() }
    let description = raw as! CMFormatDescription
    let value = CMFormatDescriptionGetMediaSubType(description)
    let bytes: [UInt8] = [
      UInt8((value >> 24) & 0xff),
      UInt8((value >> 16) & 0xff),
      UInt8((value >> 8) & 0xff),
      UInt8(value & 0xff),
    ]
    if let rawCodec = String(bytes: bytes, encoding: .ascii) {
      let codec = rawCodec.trimmingCharacters(in: .whitespacesAndNewlines)
      if !codec.isEmpty { return codec }
    }
    return NSNull()
  }

  private func localMimeType(_ ext: String) -> String {
    switch ext {
    case "mp4", "m4v": return "video/mp4"
    case "mov": return "video/quicktime"
    case "mp3": return "audio/mpeg"
    case "m4a", "aac": return "audio/mp4"
    case "wav": return "audio/wav"
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "heic", "heif": return "image/heic"
    default: return "application/octet-stream"
    }
  }

  private func convertImage(
    inputURL: URL,
    outputURL: URL,
    format: String,
    quality: String
  ) throws {
    guard let image = UIImage(contentsOfFile: inputURL.path) else {
      throw shortError(code: 53, message: "无法读取该图片格式")
    }
    let compression: CGFloat
    switch quality {
    case "low": compression = 0.55
    case "medium": compression = 0.75
    case "high": compression = 0.9
    default: compression = 1.0
    }
    try? FileManager.default.removeItem(at: outputURL)
    switch format {
    case "jpg", "jpeg":
      guard let data = image.jpegData(compressionQuality: compression) else {
        throw shortError(code: 54, message: "JPEG 转换失败")
      }
      try data.write(to: outputURL, options: .atomic)
    case "png":
      guard let data = image.pngData() else {
        throw shortError(code: 55, message: "PNG 转换失败")
      }
      try data.write(to: outputURL, options: .atomic)
    case "heic":
      guard let cgImage = image.cgImage,
            let destination = CGImageDestinationCreateWithURL(
              outputURL as CFURL,
              "public.heic" as CFString,
              1,
              nil
            ) else {
        throw shortError(code: 56, message: "此设备不支持写入 HEIC")
      }
      CGImageDestinationAddImage(
        destination,
        cgImage,
        [kCGImageDestinationLossyCompressionQuality: compression] as CFDictionary
      )
      guard CGImageDestinationFinalize(destination) else {
        throw shortError(code: 56, message: "HEIC 转换失败")
      }
    default:
      throw shortError(code: 52, message: "图片不能转换为该格式")
    }
    guard ((try? fileSize(of: outputURL)) ?? 0) > 0 else {
      throw shortError(code: 57, message: "图片转换没有生成文件")
    }
  }

  private func startAVConversion(
    inputURL: URL,
    outputURL: URL,
    format: String,
    quality: String,
    saveDestination: String,
    customDestinationURI: String?,
    processID: String,
    result: @escaping FlutterResult
  ) throws {
    let asset = AVURLAsset(url: inputURL)
    let hasVideo = !asset.tracks(withMediaType: .video).isEmpty
    let hasAudio = !asset.tracks(withMediaType: .audio).isEmpty
    let isAudioOutput = format == "m4a"
    if isAudioOutput && !hasAudio {
      throw shortError(code: 58, message: "源文件不包含可转换的音轨")
    }
    if !isAudioOutput && !hasVideo {
      throw shortError(code: 59, message: "该源文件不能转换为视频")
    }
    let preset: String
    if isAudioOutput {
      preset = AVAssetExportPresetAppleM4A
    } else {
      switch quality {
      case "low": preset = AVAssetExportPresetLowQuality
      case "medium": preset = AVAssetExportPresetMediumQuality
      case "original": preset = AVAssetExportPresetPassthrough
      default: preset = AVAssetExportPresetHighestQuality
      }
    }
    guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
      throw shortError(code: 60, message: "该编码无法在 iPhone 上转换")
    }
    let fileType: AVFileType
    switch format {
    case "mp4": fileType = .mp4
    case "m4v": fileType = .m4v
    case "mov": fileType = .mov
    case "m4a": fileType = .m4a
    default: throw shortError(code: 61, message: "该输出格式不受支持")
    }
    guard exporter.supportedFileTypes.contains(fileType) else {
      throw shortError(code: 62, message: "该源编码不能转换为 \(format.uppercased())")
    }
    try? FileManager.default.removeItem(at: outputURL)
    exporter.outputURL = outputURL
    exporter.outputFileType = fileType
    exporter.shouldOptimizeForNetworkUse = !isAudioOutput

    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    let startedAt = DispatchTime.now().uptimeNanoseconds
    var lastAt = startedAt
    var lastBytes: Int64 = 0
    timer.schedule(deadline: .now(), repeating: .milliseconds(250))
    timer.setEventHandler { [weak self, weak exporter] in
      guard let self, let exporter else { return }
      let now = DispatchTime.now().uptimeNanoseconds
      let bytes = (try? self.fileSize(of: outputURL)) ?? 0
      let sample = Double(now - lastAt) / 1_000_000_000
      let elapsed = Double(now - startedAt) / 1_000_000_000
      self.emitConversionProgress(
        processID: processID,
        progress: Double(exporter.progress) * 100,
        status: "正在转换",
        speedBytesPerSecond: sample > 0 ? Double(max(0, bytes - lastBytes)) / sample : nil,
        averageSpeedBytesPerSecond: elapsed > 0 ? Double(bytes) / elapsed : nil
      )
      lastAt = now
      lastBytes = bytes
    }

    taskLock.lock()
    if cancelledTaskIDs.contains(processID) {
      taskLock.unlock()
      throw shortError(code: 51, message: "转换已取消")
    }
    activeExporters[processID] = exporter
    activeConversionTimers[processID] = timer
    taskLock.unlock()
    timer.resume()
    exporter.exportAsynchronously {
      self.taskLock.lock()
      let activeTimer = self.activeConversionTimers.removeValue(forKey: processID)
      self.activeExporters.removeValue(forKey: processID)
      let cancelled = self.cancelledTaskIDs.contains(processID)
      self.taskLock.unlock()
      activeTimer?.cancel()
      if exporter.status == .completed && !cancelled {
        self.emitConversionProgress(
          processID: processID,
          progress: 100,
          status: "转换完成"
        )
        self.finishConvertedMedia(
          outputURL: outputURL,
          format: format,
          saveDestination: saveDestination,
          customDestinationURI: customDestinationURI,
          processID: processID,
          result: result
        )
      } else {
        try? FileManager.default.removeItem(at: outputURL)
        let message = cancelled || exporter.status == .cancelled
          ? "转换已取消"
          : "格式转换失败，源编码可能不受支持"
        self.finishDownloadTask(processID: processID)
        DispatchQueue.main.async {
          result(FlutterError(code: "CONVERSION_ERROR", message: message, details: nil))
        }
      }
    }
  }

  private func emitConversionProgress(
    processID: String,
    progress: Double,
    status: String,
    speedBytesPerSecond: Double? = nil,
    averageSpeedBytesPerSecond: Double? = nil
  ) {
    DispatchQueue.main.async {
      self.localMediaChannel?.invokeMethod("conversionProgress", arguments: [
        "process_id": processID,
        "progress": min(100, max(0, progress)),
        "status": status,
        "speed_bytes_per_second": speedBytesPerSecond.map { $0 as Any } ?? NSNull(),
        "average_speed_bytes_per_second": averageSpeedBytesPerSecond.map { $0 as Any } ?? NSNull(),
      ])
    }
  }

  private func finishConvertedMedia(
    outputURL: URL,
    format: String,
    saveDestination: String,
    customDestinationURI: String?,
    processID: String,
    result: @escaping FlutterResult
  ) {
    let mediaType: String
    if IOSConversion.imageOutputs.contains(format) {
      mediaType = "image"
    } else if format == "m4a" {
      mediaType = "audio"
    } else {
      mediaType = "video"
    }
    let payload: [String: Any] = [
      "process_id": processID,
      "filename": outputURL.lastPathComponent,
      "path": outputURL.path,
      "format": format,
    ]
    if saveDestination == "gallery" {
      guard mediaType == "image" || mediaType == "video" else {
        finishDownloadTask(processID: processID)
        DispatchQueue.main.async {
          result(FlutterError(code: "CONVERSION_ERROR", message: "音频不能保存到相册", details: nil))
        }
        return
      }
      saveMediaToPhotos(fileURL: outputURL, mediaType: mediaType) { error in
        defer { self.finishDownloadTask(processID: processID) }
        if let error {
          result(FlutterError(
            code: "CONVERSION_ERROR",
            message: self.conciseMessage(error, fallback: "保存到相册失败，请检查文件格式"),
            details: nil
          ))
        } else {
          try? FileManager.default.removeItem(at: outputURL)
          var saved = payload
          saved.removeValue(forKey: "path")
          saved["message"] = "已保存到系统相册"
          result(saved)
        }
      }
      return
    }
    do {
      let saved: [String: Any]
      if saveDestination == "custom" {
        guard let customDestinationURI else {
          throw shortError(code: 40, message: "请先选择保存目录")
        }
        saved = try copyFileToCustomDirectory(
          outputURL,
          destinationIdentifier: customDestinationURI,
          payload: payload
        )
        try? FileManager.default.removeItem(at: outputURL)
      } else {
        saved = try moveDownloadedFileToDocuments(outputURL, payload: payload)
      }
      finishDownloadTask(processID: processID)
      DispatchQueue.main.async { result(saved) }
    } catch {
      finishDownloadTask(processID: processID)
      DispatchQueue.main.async {
        result(FlutterError(
          code: "CONVERSION_ERROR",
          message: self.conciseMessage(error, fallback: "保存转换文件失败"),
          details: nil
        ))
      }
    }
  }

  private enum IOSConversion {
    static let imageInputs: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]
    static let imageOutputs: Set<String> = ["jpg", "jpeg", "png", "heic"]
    static let outputFormats: Set<String> = imageOutputs.union(["mp4", "m4v", "mov", "m4a"])
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
