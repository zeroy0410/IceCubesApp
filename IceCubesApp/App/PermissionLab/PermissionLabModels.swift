import Foundation
import Observation
import SwiftUI

// Permission boundary experiment models. All experiment results are local-only and
// intentionally designed for explicit, foreground user-triggered testing.

enum PermissionType: String, CaseIterable, Codable, Identifiable, Hashable {
  case photos
  case camera
  case microphone
  case location
  case contacts
  case calendar
  case reminders
  case notifications
  case pasteboard
  case localNetwork
  case files
  case motion
  case mediaLibrary

  var id: String { rawValue }

  var title: String {
    switch self {
    case .photos: "照片"
    case .camera: "相机"
    case .microphone: "麦克风"
    case .location: "定位"
    case .contacts: "通讯录"
    case .calendar: "日历"
    case .reminders: "提醒事项"
    case .notifications: "通知"
    case .pasteboard: "剪贴板"
    case .localNetwork: "本地网络"
    case .files: "文件"
    case .motion: "运动与传感器"
    case .mediaLibrary: "媒体资料库"
    }
  }

  var iconName: String {
    switch self {
    case .photos: "photo.on.rectangle"
    case .camera: "camera"
    case .microphone: "mic"
    case .location: "location"
    case .contacts: "person.2"
    case .calendar: "calendar"
    case .reminders: "checklist"
    case .notifications: "bell.badge"
    case .pasteboard: "doc.on.clipboard"
    case .localNetwork: "network"
    case .files: "folder"
    case .motion: "figure.walk.motion"
    case .mediaLibrary: "music.note.list"
    }
  }

  var shortDescription: String {
    switch self {
    case .photos:
      "比较系统选择器最小权限路径与 PhotoKit 相册授权路径。"
    case .camera:
      "在用户可见拍摄后检查可获得的图像与元数据。"
    case .microphone:
      "录制前台音频样本并检查文件元数据。"
    case .location:
      "比较单次定位、持续定位与精确/模糊定位边界。"
    case .contacts:
      "检查显式授权后哪些联系人字段真正可读。"
    case .calendar:
      "在显式授权后检查日历事件字段可见性。"
    case .reminders:
      "在显式授权后检查提醒事项字段可见性。"
    case .notifications:
      "检查通知授权粒度与提醒选项状态。"
    case .pasteboard:
      "比较直接读取、显式点击读取与系统粘贴控件路径。"
    case .localNetwork:
      "记录本地网络提示行为与可见边界。"
    case .files:
      "检查用户主动选择文件后可见的元数据。"
    case .motion:
      "检查运动能力与前台短时传感器样本。"
    case .mediaLibrary:
      "检查媒体资料库授权后的可见范围。"
    }
  }

  static var primaryModules: [PermissionType] {
    [.photos, .location, .contacts, .pasteboard]
  }
}

enum PermissionPrivacyRiskLevel: String, Codable, CaseIterable {
  case low
  case medium
  case high

  var displayName: String {
    switch self {
    case .low: "低"
    case .medium: "中"
    case .high: "高"
    }
  }

  var tint: Color {
    switch self {
    case .low: .green
    case .medium: .orange
    case .high: .red
    }
  }
}

struct PermissionAuthorizationState: Codable, Equatable, Sendable {
  var status: String
  var substatus: [String]
  var notes: [String]

  static let unknown = PermissionAuthorizationState(status: "unknown", substatus: [], notes: [])
}

struct PermissionExperimentResult: Codable, Identifiable, Hashable, Sendable {
  let id: UUID
  let permissionType: PermissionType
  let osVersion: String
  let deviceModel: String?
  let authorizationStatus: String
  let authorizationSubstatus: [String]
  let triggerAction: String
  let timestamp: Date
  let fieldsCollected: [String]
  let fieldsUnavailable: [String]
  let boundaryFindings: [String]
  let privacyRiskLevel: PermissionPrivacyRiskLevel
  let privacyImpactSummary: String
  let rawSamplePreview: String
  let notes: [String]

  init(
    id: UUID = UUID(),
    permissionType: PermissionType,
    authorizationStatus: String,
    authorizationSubstatus: [String],
    triggerAction: String,
    fieldsCollected: [String],
    fieldsUnavailable: [String],
    boundaryFindings: [String],
    privacyRiskLevel: PermissionPrivacyRiskLevel,
    privacyImpactSummary: String,
    rawSamplePreview: String,
    notes: [String]
  ) {
    self.id = id
    self.permissionType = permissionType
    self.osVersion = "\(ProcessInfo.processInfo.operatingSystemVersionString)"
    self.deviceModel = DeviceMetadata.currentModelIdentifier
    self.authorizationStatus = authorizationStatus
    self.authorizationSubstatus = authorizationSubstatus
    self.triggerAction = triggerAction
    self.timestamp = .now
    self.fieldsCollected = fieldsCollected
    self.fieldsUnavailable = fieldsUnavailable
    self.boundaryFindings = boundaryFindings
    self.privacyRiskLevel = privacyRiskLevel
    self.privacyImpactSummary = privacyImpactSummary
    self.rawSamplePreview = rawSamplePreview
    self.notes = notes
  }
}

struct PermissionLabExportBundle: Codable {
  let exportedAt: Date
  let results: [PermissionExperimentResult]
}

// MARK: - LLM downstream analysis export

/// Structured bundle designed for consumption by a downstream LLM tasked with
/// user-profile risk analysis. All data is user-triggered and locally collected.
struct LLMAnalysisBundle: Codable {
  struct Meta: Codable {
    let purpose: String
    let disclaimer: String
    let exportedAt: String
    let osVersion: String
    let deviceModel: String?
    let permissionsAudited: Int
    let permissionsTested: Int
  }

  struct PermissionSummary: Codable {
    let id: String
    let displayName: String
    let authorizationStatus: String
    let authorizationDetail: [String]
    let experimentRun: Bool
    let triggerAction: String?
    let collectedFields: [String]
    let blockedFields: [String]
    let boundaryFindings: [String]
    let dataSample: String
    let riskLevel: String
    let riskSummary: String
    let recordedAt: String?
  }

  struct CombinedRisk: Codable {
    let highRiskPermissions: [String]
    let mediumRiskPermissions: [String]
    let crossPermissionInsights: [String]
    let overallRiskLevel: String
  }

  struct AnalysisTask: Codable {
    let systemPrompt: String
    let focusAreas: [String]
    let outputFormat: String
  }

  let meta: Meta
  let permissions: [PermissionSummary]
  let combinedRisk: CombinedRisk
  let analysisTask: AnalysisTask
}

// MARK: - Static compliance audit models

struct StaticAuditItem: Identifiable {
  enum AuditStatus {
    case present
    case missing
    case inconsistent
    case notApplicable

    var displayName: String {
      switch self {
      case .present: "已配置"
      case .missing: "缺失"
      case .inconsistent: "不一致"
      case .notApplicable: "不适用"
      }
    }

    var tint: Color {
      switch self {
      case .present: .green
      case .missing: .red
      case .inconsistent: .orange
      case .notApplicable: .secondary
      }
    }

    var systemImage: String {
      switch self {
      case .present: "checkmark.circle.fill"
      case .missing: "xmark.circle.fill"
      case .inconsistent: "exclamationmark.triangle.fill"
      case .notApplicable: "minus.circle"
      }
    }
  }

  var id: String { configKey }
  let configKey: String
  let status: AuditStatus
  let description: String
  let recommendation: String
}

// MARK: - Background capability matrix model

struct BackgroundCapabilityEntry: Identifiable {
  var id: String { permissionType.rawValue }
  let permissionType: PermissionType
  let foregroundAvailability: String
  let backgroundAvailability: String
  let requiredDeclarations: [String]
  let userVisibleIndicators: [String]
  let simulatorLimitations: [String]
}

extension BackgroundCapabilityEntry {
  // swiftlint:disable:next function_body_length
  static var allEntries: [BackgroundCapabilityEntry] {
    [
      BackgroundCapabilityEntry(
        permissionType: .location,
        foregroundAvailability: "精确/模糊坐标均可请求；单次 requestLocation 或持续 startUpdatingLocation",
        backgroundAvailability: "仅授予「始终允许」时可持续后台定位；「使用期间」只支持有限延续（几秒内）；需声明 location 后台模式",
        requiredDeclarations: [
          "NSLocationWhenInUseUsageDescription",
          "NSLocationAlwaysAndWhenInUseUsageDescription（始终允许时）",
          "UIBackgroundModes = location（后台持续定位时）"
        ],
        userVisibleIndicators: ["状态栏蓝色定位箭头（前台使用中）", "状态栏空心定位箭头（最近/后台使用）", "控制中心位置图标"],
        simulatorLimitations: ["模拟器使用 Xcode 配置的模拟坐标", "后台延续行为与真机有差异"]
      ),
      BackgroundCapabilityEntry(
        permissionType: .photos,
        foregroundAvailability: "系统选择器（无需完整授权）或 PhotoKit 完整/受限授权均可用",
        backgroundAvailability: "后台无法主动访问相册；PhotoKit 请求需在前台完成",
        requiredDeclarations: [
          "NSPhotoLibraryUsageDescription（完整读写授权）",
          "NSPhotoLibraryAddUsageDescription（仅写入）"
        ],
        userVisibleIndicators: ["PHPickerViewController 系统选择器界面", "受限模式时系统提示用户更改所选相册"],
        simulatorLimitations: ["模拟器相册预加载有限图片", "EXIF/GPS 元数据可能不完整"]
      ),
      BackgroundCapabilityEntry(
        permissionType: .camera,
        foregroundAvailability: "需要授权后才可访问；UIImagePickerController 或 AVCaptureSession",
        backgroundAvailability: "iOS 禁止后台访问相机；进入后台时捕获会话自动中断",
        requiredDeclarations: ["NSCameraUsageDescription"],
        userVisibleIndicators: ["状态栏绿色相机指示器（前台录制中）", "系统锁定画面上的相机指示"],
        simulatorLimitations: ["模拟器不支持相机硬件；isSourceTypeAvailable(.camera) 返回 false"]
      ),
      BackgroundCapabilityEntry(
        permissionType: .microphone,
        foregroundAvailability: "需要授权；AVAudioSession 录音可在前台运行",
        backgroundAvailability: "需声明 audio 后台模式才可后台录音；否则进入后台时录音中断",
        requiredDeclarations: [
          "NSMicrophoneUsageDescription",
          "UIBackgroundModes = audio（后台录音时）"
        ],
        userVisibleIndicators: ["状态栏橙色麦克风指示器（前台录音中）", "iOS 14+ 录音时显示隐私指示器"],
        simulatorLimitations: ["模拟器支持麦克风（需接入宿主机麦克风）"]
      ),
      BackgroundCapabilityEntry(
        permissionType: .contacts,
        foregroundAvailability: "iOS 18+ 支持受限授权；完整授权可枚举所有联系人",
        backgroundAvailability: "后台无法主动请求通讯录；已有授权可继续读取（无法触发新系统提示）",
        requiredDeclarations: ["NSContactsUsageDescription"],
        userVisibleIndicators: ["首次请求时系统授权提示"],
        simulatorLimitations: ["模拟器通讯录为空，需手动添加测试联系人"]
      ),
      BackgroundCapabilityEntry(
        permissionType: .calendar,
        foregroundAvailability: "iOS 17+ 分为完整访问与仅写入；可读取/写入事件",
        backgroundAvailability: "后台无法触发授权提示；已授权数据可在后台读取（需显式后台任务支持）",
        requiredDeclarations: [
          "NSCalendarsFullAccessUsageDescription（iOS 17+）",
          "NSCalendarsUsageDescription（iOS 16 及以下）"
        ],
        userVisibleIndicators: ["首次请求时系统授权提示"],
        simulatorLimitations: ["模拟器日历默认为空，需手动添加测试事件"]
      ),
      BackgroundCapabilityEntry(
        permissionType: .reminders,
        foregroundAvailability: "iOS 17+ 分为完整访问；可读取/写入提醒事项",
        backgroundAvailability: "类似日历；后台无法触发提示",
        requiredDeclarations: [
          "NSRemindersFullAccessUsageDescription（iOS 17+）",
          "NSRemindersUsageDescription（iOS 16 及以下）"
        ],
        userVisibleIndicators: ["首次请求时系统授权提示"],
        simulatorLimitations: ["模拟器提醒事项默认为空"]
      ),
      BackgroundCapabilityEntry(
        permissionType: .notifications,
        foregroundAvailability: "可请求 alert/badge/sound/provisional 授权；调度本地通知",
        backgroundAvailability: "可接收远程推送（需服务端）；本地通知由系统在指定时间触发；不依赖后台执行权限",
        requiredDeclarations: [
          "UIBackgroundModes = remote-notification（远程推送时）"
        ],
        userVisibleIndicators: ["通知横幅/提示/锁屏通知（取决于设置）", "角标数字", "通知中心条目"],
        simulatorLimitations: ["模拟器支持本地通知；远程推送需真机或推送模拟器"]
      ),
      BackgroundCapabilityEntry(
        permissionType: .pasteboard,
        foregroundAvailability: "直接读取可能触发系统粘贴确认（iOS 16+）；PasteButton 是无提示路径",
        backgroundAvailability: "后台无法读取剪贴板（系统限制）",
        requiredDeclarations: ["无（无需 usage description）"],
        userVisibleIndicators: ["iOS 16+ 程序直接访问时出现系统粘贴确认提示"],
        simulatorLimitations: ["模拟器与宿主机共享剪贴板"]
      ),
      BackgroundCapabilityEntry(
        permissionType: .localNetwork,
        foregroundAvailability: "触发本地网络发现时弹出系统提示；无统一授权状态 API",
        backgroundAvailability: "后台无法触发本地网络提示；已有连接可能持续（依赖具体实现）",
        requiredDeclarations: [
          "NSLocalNetworkUsageDescription",
          "NSBonjourServices（Bonjour 服务类型声明）"
        ],
        userVisibleIndicators: ["首次触发时系统「允许在本地网络中查找设备」提示"],
        simulatorLimitations: ["模拟器本地网络发现行为与真机不一致，建议真机验证"]
      ),
      BackgroundCapabilityEntry(
        permissionType: .files,
        foregroundAvailability: "仅通过用户主动选择文件（UIDocumentPickerViewController）才能访问",
        backgroundAvailability: "后台无法弹出文件选择器；已获 security-scoped URL 可在后台有限使用",
        requiredDeclarations: ["无（无需 usage description）"],
        userVisibleIndicators: ["系统文件选择器界面由用户显式发起"],
        simulatorLimitations: ["模拟器文件选择器功能正常"]
      ),
      BackgroundCapabilityEntry(
        permissionType: .motion,
        foregroundAvailability: "CMMotionActivityManager / CMPedometer / CMMotionManager 均可在前台使用",
        backgroundAvailability: "CMPedometer 可在后台记录步数（无需后台模式声明）；实时加速度计/陀螺仪在后台中断",
        requiredDeclarations: ["NSMotionUsageDescription"],
        userVisibleIndicators: ["首次访问时系统授权提示"],
        simulatorLimitations: ["模拟器不含运动硬件；CMMotionActivityManager 返回空数据"]
      ),
      BackgroundCapabilityEntry(
        permissionType: .mediaLibrary,
        foregroundAvailability: "授权后可枚举歌曲、播放列表和艺术家元数据",
        backgroundAvailability: "后台无法请求授权；已授权内容可后台读取",
        requiredDeclarations: ["NSAppleMusicUsageDescription"],
        userVisibleIndicators: ["首次访问时系统授权提示"],
        simulatorLimitations: ["模拟器媒体资料库为空"]
      ),
    ]
  }
}

enum PermissionLabDestination: Hashable {
  case module(PermissionType)
  case results(PermissionType)
  case overview
  case export
  case riskGuide
}

enum DeviceMetadata {
  static var currentModelIdentifier: String? {
    var systemInfo = utsname()
    uname(&systemInfo)
    let values = Mirror(reflecting: systemInfo.machine).children
    let identifier = values.reduce(into: "") { partialResult, element in
      guard let value = element.value as? Int8, value != 0 else { return }
      partialResult.append(Character(UnicodeScalar(UInt8(value))))
    }
    return identifier.isEmpty ? nil : identifier
  }
}

extension PermissionExperimentResult {
  var formattedTimestamp: String {
    timestamp.formatted(date: .abbreviated, time: .standard)
  }
}
