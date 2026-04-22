import AVFoundation
import Contacts
import CoreLocation
import CoreMotion
import EventKit
import Foundation
import MediaPlayer
import Observation
import Photos
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// Local persistence and authorization helpers for permission boundary experiments.

@MainActor
@Observable
final class PermissionLabResultStore {
  static let shared = PermissionLabResultStore()

  private(set) var results: [PermissionExperimentResult] = []
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let archiveURL: URL

  init() {
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    decoder.dateDecodingStrategy = .iso8601
    encoder.dateEncodingStrategy = .iso8601

    let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? URL.documentsDirectory
    let directory = baseURL.appending(path: "PermissionLab", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: nil
    )
    archiveURL = directory.appending(path: "results.json")
    load()
  }

  var latestResults: [PermissionType: PermissionExperimentResult] {
    var latest: [PermissionType: PermissionExperimentResult] = [:]
    for result in results { // results are sorted newest-first
      if latest[result.permissionType] == nil {
        latest[result.permissionType] = result
      }
    }
    return latest
  }

  func results(for type: PermissionType) -> [PermissionExperimentResult] {
    results.filter { $0.permissionType == type }
  }

  func previousResult(for type: PermissionType) -> PermissionExperimentResult? {
    let typed = results.filter { $0.permissionType == type }
    return typed.count >= 2 ? typed[1] : nil
  }

  func record(_ result: PermissionExperimentResult) {
    results.insert(result, at: 0)
    save()
  }

  func exportFiles() throws -> (jsonURL: URL, summaryURL: URL) {
    let exportDirectory = URL.documentsDirectory.appending(path: "PermissionLabExport", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: exportDirectory,
      withIntermediateDirectories: true,
      attributes: nil
    )

    let timestamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
    let jsonURL = exportDirectory.appending(path: "permission-lab-\(timestamp).json")
    let summaryURL = exportDirectory.appending(path: "permission-lab-\(timestamp).txt")

    let bundle = PermissionLabExportBundle(exportedAt: .now, results: results)
    let jsonData = try encoder.encode(bundle)
    try jsonData.write(to: jsonURL, options: .atomic)

    let summary = PermissionLabSummaryBuilder.makeSummary(from: results)
    guard let summaryData = summary.data(using: .utf8) else {
      throw CocoaError(.fileWriteUnknown)
    }
    try summaryData.write(to: summaryURL, options: .atomic)

    return (jsonURL, summaryURL)
  }

  private func load() {
    guard let data = try? Data(contentsOf: archiveURL) else { return }
    guard let bundle = try? decoder.decode(PermissionLabExportBundle.self, from: data) else { return }
    results = bundle.results.sorted { $0.timestamp > $1.timestamp }
  }

  private func save() {
    let bundle = PermissionLabExportBundle(exportedAt: .now, results: results)
    guard let data = try? encoder.encode(bundle) else { return }
    try? data.write(to: archiveURL, options: .atomic)
  }
}

enum PermissionLabSummaryBuilder {
  static func makeSummary(from results: [PermissionExperimentResult]) -> String {
    let header = [
      "权限边界实验室导出",
      "生成时间：\(Date.now.formatted(date: .abbreviated, time: .standard))",
      ""
    ]

    let blocks = results.sorted { $0.permissionType.title < $1.permissionType.title }.map { result in
      [
        "[\(result.permissionType.title)]",
        "授权状态：\(result.authorizationStatus)",
        "授权细分：\(result.authorizationSubstatus.joined(separator: ", ").nilIfEmpty ?? "无")",
        "触发动作：\(result.triggerAction)",
        "已获取字段：\(result.fieldsCollected.joined(separator: " | ").nilIfEmpty ?? "无")",
        "未获取字段：\(result.fieldsUnavailable.joined(separator: " | ").nilIfEmpty ?? "无")",
        "边界发现：\(result.boundaryFindings.joined(separator: " | ").nilIfEmpty ?? "无")",
        "风险等级：\(result.privacyRiskLevel.displayName)",
        "隐私影响：\(result.privacyImpactSummary)",
        "样例预览：\(result.rawSamplePreview)",
        ""
      ].joined(separator: "\n")
    }

    return (header + blocks).joined(separator: "\n")
  }
}

enum PermissionRiskAnalyzer {
  static func analyze(
    type: PermissionType,
    authorization: PermissionAuthorizationState,
    fieldsCollected: [String],
    fieldsUnavailable: [String],
    boundaryFindings: [String]
  ) -> (PermissionPrivacyRiskLevel, String) {
    let baseLevel: PermissionPrivacyRiskLevel = switch type {
    case .location, .contacts, .photos:
      .high
    case .camera, .microphone, .calendar, .reminders, .pasteboard, .files, .mediaLibrary:
      .medium
    case .notifications, .motion, .localNetwork:
      .low
    }

    let reduced = authorization.substatus.contains("limited")
      || authorization.substatus.contains("approximate")
      || authorization.substatus.contains("受限")
      || authorization.substatus.contains("模糊定位")
      || authorization.status == "denied"
      || authorization.status == "notDetermined"
      || authorization.status == "已拒绝"
      || authorization.status == "未决定"

    let level: PermissionPrivacyRiskLevel = {
      if authorization.status == "denied"
        || authorization.status == "notDetermined"
        || authorization.status == "已拒绝"
        || authorization.status == "未决定"
      {
        return .low
      }
      if reduced, baseLevel == .high {
        return .medium
      }
      return baseLevel
    }()

    let combinedRiskNote = switch type {
    case .photos:
      "若与定位或通讯录组合，媒体元数据可显著增强身份识别、出行轨迹和社交关系推断。"
    case .location:
      "若与照片、日历或通讯录组合，定位可暴露居住地、工作地、作息与社交活动规律。"
    case .contacts:
      "若与通知、剪贴板或定位组合，通讯录可支持社交关系图谱和上下文推断。"
    case .pasteboard:
      "若与应用内容或文件导入流程组合，剪贴板样本可能泄露瞬时口令、链接和用户意图。"
    case .camera:
      "若与照片或定位组合，拍摄内容可揭示地点、时间和活动场景。"
    case .microphone:
      "若与通讯录或定位组合，录音可暴露人物关系、生活规律和环境特征。"
    case .calendar:
      "若与定位和通讯录组合，日历事件可暴露日程安排和关系背景。"
    case .reminders:
      "若与文件或剪贴板组合，提醒事项可暴露任务、计划与兴趣偏好。"
    case .files:
      "若与剪贴板或媒体资料库组合，用户主动选择的文件可暴露工作模式与敏感文档上下文。"
    case .notifications:
      "若与通讯录或日历组合，通知状态仍可能支持行为画像分析。"
    case .motion:
      "若与定位组合，运动数据可强化通勤与活动模式推断。"
    case .mediaLibrary:
      "若与通讯录、文件或剪贴板组合，媒体偏好可增强兴趣画像。"
    case .localNetwork:
      "若与文件或定位组合，本地网络可见性可揭示家庭或办公环境特征。"
    }

    let boundarySummary = boundaryFindings.joined(separator: " ").nilIfEmpty
      ?? "系统边界仍然限制了部分数据。"
    let summary = "当前状态为“\(authorization.status)”，本次实验成功获取 \(fieldsCollected.count) 组字段，仍有 \(fieldsUnavailable.count) 组字段不可用。\(boundarySummary)\(combinedRiskNote)"

    return (level, summary)
  }
}

@MainActor
@Observable
final class PermissionBroker {
  static let shared = PermissionBroker()

  private let contactStore = CNContactStore()
  private let eventStore = EKEventStore()

  func authorizationState(for type: PermissionType) async -> PermissionAuthorizationState {
    switch type {
    case .photos:
      return photosAuthorizationState()
    case .camera:
      return cameraAuthorizationState()
    case .microphone:
      return microphoneAuthorizationState()
    case .location:
      return locationAuthorizationState()
    case .contacts:
      return contactsAuthorizationState()
    case .calendar:
      return calendarAuthorizationState()
    case .reminders:
      return remindersAuthorizationState()
    case .notifications:
      return await notificationsAuthorizationState()
    case .pasteboard:
      return .init(
        status: "需要前台用户操作",
        substatus: [],
        notes: ["剪贴板没有传统的授权开关。不同读取路径下，iOS 可能弹出粘贴确认提示。"]
      )
    case .localNetwork:
      return .init(
        status: "未触发",
        substatus: [],
        notes: ["本地网络没有统一的状态 API，通常只能在实际发起发现时间接观察提示行为。"]
      )
    case .files:
      return .init(
        status: "需要用户选择文件",
        substatus: [],
        notes: ["只有在用户主动选择文件后，文档元数据才会对 App 可见。"]
      )
    case .motion:
      return motionAuthorizationState()
    case .mediaLibrary:
      return mediaLibraryAuthorizationState()
    }
  }

  func requestAuthorization(for type: PermissionType) async -> PermissionAuthorizationState {
    switch type {
    case .photos:
      _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
      return photosAuthorizationState()
    case .camera:
      _ = await AVCaptureDevice.requestAccess(for: .video)
      return cameraAuthorizationState()
    case .microphone:
      _ = await requestMicrophoneAccess()
      return microphoneAuthorizationState()
    case .location:
      let coordinator = LocationExperimentCoordinator()
      return await coordinator.requestWhenInUseAuthorization()
    case .contacts:
      _ = try? await contactStore.requestAccess(for: .contacts)
      return contactsAuthorizationState()
    case .calendar:
      if #available(iOS 17.0, *) {
        _ = try? await eventStore.requestFullAccessToEvents()
      }
      return calendarAuthorizationState()
    case .reminders:
      if #available(iOS 17.0, *) {
        _ = try? await eventStore.requestFullAccessToReminders()
      }
      return remindersAuthorizationState()
    case .notifications:
      _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound, .provisional])
      return await notificationsAuthorizationState()
    case .mediaLibrary:
      let status = await withCheckedContinuation { continuation in
        MPMediaLibrary.requestAuthorization { authorizationStatus in
          continuation.resume(returning: authorizationStatus)
        }
      }
      let resolved = mediaLibraryAuthorizationState()
      return .init(status: resolved.status, substatus: resolved.substatus + ["请求结果=\(status.displayName)"], notes: resolved.notes)
    case .pasteboard, .localNetwork, .files, .motion:
      return await authorizationState(for: type)
    }
  }

  func requestLocationAlwaysAuthorization() async -> PermissionAuthorizationState {
    let coordinator = LocationExperimentCoordinator()
    return await coordinator.requestAlwaysAuthorization()
  }

  private func photosAuthorizationState() -> PermissionAuthorizationState {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    let substatus = status == .limited ? ["受限"] : (status == .authorized ? ["完全访问"] : [])
    return .init(status: status.displayName, substatus: substatus, notes: [])
  }

  private func cameraAuthorizationState() -> PermissionAuthorizationState {
    .init(status: AVCaptureDevice.authorizationStatus(for: .video).displayName, substatus: [], notes: [])
  }

  private func microphoneAuthorizationState() -> PermissionAuthorizationState {
    let permission = AVAudioSession.sharedInstance().recordPermission
    return .init(status: permission.displayName, substatus: [], notes: [])
  }

  private func locationAuthorizationState() -> PermissionAuthorizationState {
    let manager = CLLocationManager()
    let precision = manager.accuracyAuthorization == .reducedAccuracy ? "模糊定位" : "精确定位"
    return .init(
      status: CLLocationManager.authorizationStatus().displayName,
      substatus: [precision],
      notes: []
    )
  }

  private func contactsAuthorizationState() -> PermissionAuthorizationState {
    let status = CNContactStore.authorizationStatus(for: .contacts)
    let substatus: [String]
    if #available(iOS 18.0, *), status == .limited {
      substatus = ["受限"]
    } else if status == .authorized {
      substatus = ["完全访问"]
    } else {
      substatus = []
    }
    return .init(status: status.displayName, substatus: substatus, notes: [])
  }

  private func calendarAuthorizationState() -> PermissionAuthorizationState {
    if #available(iOS 17.0, *) {
      let status = EKEventStore.authorizationStatus(for: .event)
      return .init(status: status.displayName, substatus: [], notes: [])
    }
    return .unknown
  }

  private func remindersAuthorizationState() -> PermissionAuthorizationState {
    if #available(iOS 17.0, *) {
      let status = EKEventStore.authorizationStatus(for: .reminder)
      return .init(status: status.displayName, substatus: [], notes: [])
    }
    return .unknown
  }

  private func notificationsAuthorizationState() async -> PermissionAuthorizationState {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    var substatus = [
      "提醒=\(settings.alertSetting.displayName)",
      "角标=\(settings.badgeSetting.displayName)",
      "声音=\(settings.soundSetting.displayName)",
      "锁屏=\(settings.lockScreenSetting.displayName)",
      "通知中心=\(settings.notificationCenterSetting.displayName)",
      "严重警报=\(settings.criticalAlertSetting.displayName)",
      "预授权=\(settings.authorizationStatus == .provisional ? "开启" : "关闭")"
    ]
    if #available(iOS 15.0, *) {
      substatus.append("时效性=\(settings.timeSensitiveSetting.displayName)")
    }
    substatus.append("提醒样式=\(settings.alertStyle.displayName)")
    return .init(status: settings.authorizationStatus.displayName, substatus: substatus, notes: [])
  }

  private func motionAuthorizationState() -> PermissionAuthorizationState {
    let status = CMMotionActivityManager.authorizationStatus().displayName
    return .init(
      status: status,
      substatus: [],
      notes: ["运动权限通常需要结合查询行为判断，具体可用传感器会因设备硬件不同而变化。"]
    )
  }

  private func mediaLibraryAuthorizationState() -> PermissionAuthorizationState {
    .init(status: MPMediaLibrary.authorizationStatus().displayName, substatus: [], notes: [])
  }

  private func requestMicrophoneAccess() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }
}

extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}

extension PHAuthorizationStatus {
  var displayName: String {
    switch self {
    case .authorized: "已授权"
    case .limited: "受限授权"
    case .denied: "已拒绝"
    case .restricted: "受限制"
    case .notDetermined: "未决定"
    @unknown default: "未知"
    }
  }
}

extension AVAuthorizationStatus {
  var displayName: String {
    switch self {
    case .authorized: "已授权"
    case .denied: "已拒绝"
    case .restricted: "受限制"
    case .notDetermined: "未决定"
    @unknown default: "未知"
    }
  }
}

extension AVAudioSession.RecordPermission {
  var displayName: String {
    switch self {
    case .granted: "已授权"
    case .denied: "已拒绝"
    case .undetermined: "未决定"
    @unknown default: "未知"
    }
  }
}

extension CLAuthorizationStatus {
  var displayName: String {
    switch self {
    case .authorizedAlways: "始终允许"
    case .authorizedWhenInUse: "使用期间允许"
    case .denied: "已拒绝"
    case .notDetermined: "未决定"
    case .restricted: "受限制"
    @unknown default: "未知"
    }
  }
}

extension CNAuthorizationStatus {
  var displayName: String {
    switch self {
    case .authorized: "已授权"
    case .denied: "已拒绝"
    case .notDetermined: "未决定"
    case .restricted: "受限制"
    case .limited: "受限授权"
    @unknown default: "未知"
    }
  }
}

extension EKAuthorizationStatus {
  var displayName: String {
    switch self {
    case .fullAccess: "完全访问"
    case .writeOnly: "仅写入"
    case .authorized: "已授权"
    case .denied: "已拒绝"
    case .notDetermined: "未决定"
    case .restricted: "受限制"
    @unknown default: "未知"
    }
  }
}

extension UNAuthorizationStatus {
  var displayName: String {
    switch self {
    case .authorized: "已授权"
    case .denied: "已拒绝"
    case .ephemeral: "临时授权"
    case .notDetermined: "未决定"
    case .provisional: "预授权"
    @unknown default: "未知"
    }
  }
}

extension UNNotificationSetting {
  var displayName: String {
    switch self {
    case .disabled: "关闭"
    case .enabled: "开启"
    case .notSupported: "不支持"
    @unknown default: "未知"
    }
  }
}

extension MPMediaLibraryAuthorizationStatus {
  var displayName: String {
    switch self {
    case .authorized: "已授权"
    case .denied: "已拒绝"
    case .restricted: "受限制"
    case .notDetermined: "未决定"
    @unknown default: "未知"
    }
  }
}

extension CMAuthorizationStatus {
  var displayName: String {
    switch self {
    case .authorized: "已授权"
    case .denied: "已拒绝"
    case .notDetermined: "未决定"
    case .restricted: "受限制"
    @unknown default: "未知"
    }
  }
}

extension UNAlertStyle {
  var displayName: String {
    switch self {
    case .none: "无"
    case .banner: "横幅"
    case .alert: "提示框"
    @unknown default: "未知"
    }
  }
}

// MARK: - Static compliance auditor

enum StaticComplianceAuditor {
  static func runAudit() -> [StaticAuditItem] {
    let info = Bundle.main.infoDictionary ?? [:]
    var items: [StaticAuditItem] = []

    let usageKeys: [(key: String, recommendation: String)] = [
      ("NSCameraUsageDescription", "添加说明文本，说明相机访问目的，否则请求授权会崩溃。"),
      ("NSMicrophoneUsageDescription", "添加说明文本，说明麦克风访问目的。"),
      ("NSPhotoLibraryUsageDescription", "添加说明文本，说明相册读写目的。"),
      ("NSPhotoLibraryAddUsageDescription", "添加说明文本，说明写入相册目的（仅写入路径需要）。"),
      ("NSContactsUsageDescription", "添加说明文本，说明通讯录访问目的。"),
      ("NSCalendarsFullAccessUsageDescription", "iOS 17+ 完整日历访问需要此键。"),
      ("NSRemindersFullAccessUsageDescription", "iOS 17+ 完整提醒事项访问需要此键。"),
      ("NSLocationWhenInUseUsageDescription", "添加说明文本，说明使用期间定位目的。"),
      ("NSLocationAlwaysAndWhenInUseUsageDescription", "添加说明文本，说明始终定位目的（始终允许路径需要）。"),
      ("NSMotionUsageDescription", "添加说明文本，说明运动与传感器访问目的。"),
      ("NSAppleMusicUsageDescription", "添加说明文本，说明媒体资料库访问目的。"),
      ("NSLocalNetworkUsageDescription", "本地网络发现必须提供此键，否则系统不弹出授权提示。"),
    ]

    for (key, recommendation) in usageKeys {
      let value = info[key] as? String
      let status: StaticAuditItem.AuditStatus = (value != nil && !value!.isEmpty) ? .present : .missing
      items.append(StaticAuditItem(
        configKey: key,
        status: status,
        description: value ?? "（未找到此键）",
        recommendation: status == .present ? "已配置。" : recommendation
      ))
    }

    // Check NSBonjourServices
    let bonjourServices = info["NSBonjourServices"] as? [String]
    let bonjourStatus: StaticAuditItem.AuditStatus = (bonjourServices != nil && !bonjourServices!.isEmpty) ? .present : .missing
    items.append(StaticAuditItem(
      configKey: "NSBonjourServices",
      status: bonjourStatus,
      description: bonjourServices?.joined(separator: ", ") ?? "（未声明）",
      recommendation: bonjourStatus == .present
        ? "已声明 Bonjour 服务类型。"
        : "如需 Bonjour 发现，需在此数组中声明服务类型（如 _http._tcp）。"
    ))

    // Check UIBackgroundModes
    let bgModes = info["UIBackgroundModes"] as? [String] ?? []
    items.append(StaticAuditItem(
      configKey: "UIBackgroundModes",
      status: bgModes.isEmpty ? .notApplicable : .present,
      description: bgModes.isEmpty ? "（未声明后台模式）" : bgModes.joined(separator: ", "),
      recommendation: bgModes.isEmpty
        ? "当前无后台模式声明，仅使用前台权限功能时无需声明。"
        : "已声明的后台模式需与实际实现一致，多余声明会导致 App Review 拒绝。"
    ))

    // Consistency check: location background mode vs always usage description
    if bgModes.contains("location") {
      let alwaysDesc = info["NSLocationAlwaysAndWhenInUseUsageDescription"] as? String
      let consistent = alwaysDesc != nil && !alwaysDesc!.isEmpty
      items.append(StaticAuditItem(
        configKey: "NSLocationAlwaysAndWhenInUseUsageDescription（与 UIBackgroundModes=location 一致性）",
        status: consistent ? .present : .inconsistent,
        description: alwaysDesc ?? "（缺失）",
        recommendation: consistent
          ? "已配置，与 UIBackgroundModes = location 一致。"
          : "UIBackgroundModes 包含 location，但未声明 NSLocationAlwaysAndWhenInUseUsageDescription，可能导致运行时崩溃。"
      ))
    }

    return items
  }
}

// MARK: - LLM downstream export builder

enum PermissionLabLLMExportBuilder {
  static func makeBundle(from results: [PermissionExperimentResult]) -> LLMAnalysisBundle {
    let latest = latestByType(results)
    let allTypes = PermissionType.allCases

    let permissions = allTypes.map { type -> LLMAnalysisBundle.PermissionSummary in
      if let result = latest[type] {
        return .init(
          id: type.rawValue,
          displayName: type.title,
          authorizationStatus: result.authorizationStatus,
          authorizationDetail: result.authorizationSubstatus,
          experimentRun: true,
          triggerAction: result.triggerAction,
          collectedFields: result.fieldsCollected,
          blockedFields: result.fieldsUnavailable,
          boundaryFindings: result.boundaryFindings,
          dataSample: result.rawSamplePreview,
          riskLevel: result.privacyRiskLevel.rawValue,
          riskSummary: result.privacyImpactSummary,
          recordedAt: result.formattedTimestamp
        )
      } else {
        return .init(
          id: type.rawValue,
          displayName: type.title,
          authorizationStatus: "未执行实验",
          authorizationDetail: [],
          experimentRun: false,
          triggerAction: nil,
          collectedFields: [],
          blockedFields: [],
          boundaryFindings: [],
          dataSample: "",
          riskLevel: "unknown",
          riskSummary: "该权限尚未运行实验，无法评估实际数据可见范围。",
          recordedAt: nil
        )
      }
    }

    let combinedRisk = buildCombinedRisk(latest: latest)
    let analysisTask = buildAnalysisTask(latest: latest)
    let osVersion = results.first?.osVersion ?? ProcessInfo.processInfo.operatingSystemVersionString
    let deviceModel = results.first?.deviceModel

    let meta = LLMAnalysisBundle.Meta(
      purpose: "iOS 权限边界实验审计报告 — 用于 LLM 隐私风险分析与用户画像评估",
      disclaimer: "本报告中所有数据均由设备持有人在其设备上显式授权并手动触发采集，仅用于隐私研究与合规审计目的。报告不包含任何未经授权或后台静默采集的数据。",
      exportedAt: ISO8601DateFormatter().string(from: .now),
      osVersion: osVersion,
      deviceModel: deviceModel,
      permissionsAudited: allTypes.count,
      permissionsTested: latest.count
    )

    return LLMAnalysisBundle(
      meta: meta,
      permissions: permissions,
      combinedRisk: combinedRisk,
      analysisTask: analysisTask
    )
  }

  // MARK: - Private helpers

  private static func latestByType(_ results: [PermissionExperimentResult]) -> [PermissionType: PermissionExperimentResult] {
    var latest: [PermissionType: PermissionExperimentResult] = [:]
    for result in results where latest[result.permissionType] == nil {
      latest[result.permissionType] = result
    }
    return latest
  }

  private static func buildCombinedRisk(
    latest: [PermissionType: PermissionExperimentResult]
  ) -> LLMAnalysisBundle.CombinedRisk {
    let high = latest.values.filter { $0.privacyRiskLevel == .high }.map(\.permissionType.title)
    let medium = latest.values.filter { $0.privacyRiskLevel == .medium }.map(\.permissionType.title)

    var insights: [String] = []

    let hasLocation = latest[.location] != nil && !(latest[.location]!.fieldsCollected.isEmpty)
    let hasPhotos = latest[.photos] != nil && !(latest[.photos]!.fieldsCollected.isEmpty)
    let hasContacts = latest[.contacts] != nil && !(latest[.contacts]!.fieldsCollected.isEmpty)
    let hasCalendar = latest[.calendar] != nil && !(latest[.calendar]!.fieldsCollected.isEmpty)
    let hasPasteboard = latest[.pasteboard] != nil && !(latest[.pasteboard]!.fieldsCollected.isEmpty)
    let hasMicrophone = latest[.microphone] != nil && !(latest[.microphone]!.fieldsCollected.isEmpty)
    let hasFiles = latest[.files] != nil && !(latest[.files]!.fieldsCollected.isEmpty)

    if hasLocation && hasPhotos && hasContacts {
      insights.append("定位 + 照片 + 通讯录：可关联拍摄地点、出行轨迹与社交关系图谱，支撑高置信度身份画像与社交网络重建。")
    }
    if hasLocation && hasCalendar {
      insights.append("定位 + 日历：可将地理活动与时间结构关联，推断工作地、居住地、固定约会对象与生活规律。")
    }
    if hasContacts && hasCalendar {
      insights.append("通讯录 + 日历：可重建社交关系与日程的交集，识别频繁共事者、家庭成员及重要周期性事件。")
    }
    if hasPasteboard && (hasContacts || hasPhotos) {
      insights.append("剪贴板 + 通讯录/照片：剪贴板可暴露瞬时口令、链接、草稿文本，与稳定画像数据组合后可补充实时意图。")
    }
    if hasLocation && hasMicrophone {
      insights.append("定位 + 麦克风：可将声音环境（语言、背景噪声特征）与地理位置关联，增强场景识别能力。")
    }
    if hasFiles && hasPasteboard {
      insights.append("文件 + 剪贴板：用户主动操作的文件内容与剪贴板瞬时数据组合，可揭示工作模式与文档处理习惯。")
    }

    if insights.isEmpty {
      insights.append("当前已测试权限组合的跨权限交叉风险有限，建议运行更多实验后重新评估。")
    }

    let overallRisk: String
    if !high.isEmpty && high.count >= 2 {
      overallRisk = "high"
    } else if !high.isEmpty || medium.count >= 2 {
      overallRisk = "medium"
    } else {
      overallRisk = "low"
    }

    return LLMAnalysisBundle.CombinedRisk(
      highRiskPermissions: high,
      mediumRiskPermissions: medium,
      crossPermissionInsights: insights,
      overallRiskLevel: overallRisk
    )
  }

  private static func buildAnalysisTask(
    latest: [PermissionType: PermissionExperimentResult]
  ) -> LLMAnalysisBundle.AnalysisTask {
    let testedNames = latest.values.map(\.permissionType.title).sorted().joined(separator: "、")
    let systemPrompt = """
你是一位专业的 iOS 隐私安全研究员，擅长从移动端权限数据中分析用户画像风险。\
以下是一份通过 iOS 权限边界实验室工具收集的设备权限审计报告，\
所有数据均由设备持有人显式授权并在前台手动触发采集，用于隐私研究与合规审计目的。

已运行实验的权限模块：\(testedNames.isEmpty ? "暂无" : testedNames)。

请基于 permissions 数组中的 experimentRun=true 条目完成分析，\
对于 experimentRun=false 的权限，仅在组合分析中说明其缺失对整体评估的影响。\
请以结构化 Markdown 格式输出分析报告，各章节用 ## 标题划分。
"""

    let focusAreas = [
      "用户画像维度梳理：列出可从当前已授权权限组合推断的用户特征维度（地理活动规律、社交关系、兴趣偏好、作息习惯、身份特征等），说明每个维度的推断依据与置信度（高/中/低）",
      "高风险数据组合识别：指出 crossPermissionInsights 中风险最高的组合，解释为何组合后的画像能力超过各权限单独相加",
      "系统边界有效性评估：基于各权限的 blockedFields 和 boundaryFindings，评估 iOS 当前版本隐私保护机制对画像分析的实际阻断效果",
      "实际数据样本解读：结合 dataSample 中的真实采集值，具体说明已可见数据支撑哪些画像推断",
      "最小权限合规建议：若用户希望使用 App 核心功能同时最大化隐私保护，建议可安全拒绝或降级的权限项",
      "整体隐私风险评级：给出综合 low/medium/high 评级，并以 2-3 句话说明核心依据",
    ]

    return LLMAnalysisBundle.AnalysisTask(
      systemPrompt: systemPrompt,
      focusAreas: focusAreas,
      outputFormat: "结构化 Markdown，每个 focusArea 对应一个 ## 二级章节，重要数据点使用 **加粗** 或表格展示"
    )
  }
}

extension PermissionLabResultStore {
  /// Generate an LLM-ready analysis bundle from current results and write it to the
  /// export directory alongside the regular JSON/text exports.
  func exportLLMBundle() throws -> URL {
    let exportDirectory = URL.documentsDirectory.appending(path: "PermissionLabExport", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true, attributes: nil)

    let timestamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
    let url = exportDirectory.appending(path: "permission-lab-llm-\(timestamp).json")

    let bundle = PermissionLabLLMExportBuilder.makeBundle(from: results)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(bundle)
    try data.write(to: url, options: .atomic)
    return url
  }
}
