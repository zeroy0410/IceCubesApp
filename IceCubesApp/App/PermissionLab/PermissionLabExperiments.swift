import AVFoundation
import Contacts
import CoreLocation
import CoreMotion
import EventKit
import Foundation
import ImageIO
import MediaPlayer
import Network
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

// Explicit, foreground-only experiment executors for each permission boundary test.

@MainActor
final class LocationExperimentCoordinator: NSObject, CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  private var authorizationContinuation: CheckedContinuation<PermissionAuthorizationState, Never>?
  private var singleLocationContinuation: CheckedContinuation<CLLocation?, Never>?
  private var continuousLocations: [CLLocation] = []
  private var continuousHandler: (([CLLocation]) -> Void)?

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBest
  }

  func currentAuthorizationState() -> PermissionAuthorizationState {
    let precision = manager.accuracyAuthorization == .reducedAccuracy ? "模糊定位" : "精确定位"
    return .init(
      status: manager.authorizationStatus.displayName,
      substatus: [precision],
      notes: []
    )
  }

  func requestWhenInUseAuthorization() async -> PermissionAuthorizationState {
    if manager.authorizationStatus != .notDetermined {
      return currentAuthorizationState()
    }

    return await withCheckedContinuation { continuation in
      authorizationContinuation = continuation
      manager.requestWhenInUseAuthorization()
    }
  }

  func requestAlwaysAuthorization() async -> PermissionAuthorizationState {
    if manager.authorizationStatus == .authorizedAlways {
      return currentAuthorizationState()
    }

    return await withCheckedContinuation { continuation in
      authorizationContinuation = continuation
      manager.requestAlwaysAuthorization()
    }
  }

  func requestSingleLocation() async -> CLLocation? {
    guard manager.authorizationStatus == .authorizedWhenInUse
      || manager.authorizationStatus == .authorizedAlways
    else {
      return nil
    }

    return await withCheckedContinuation { continuation in
      singleLocationContinuation = continuation
      manager.requestLocation()
    }
  }

  func startContinuousUpdates(handler: @escaping ([CLLocation]) -> Void) {
    guard manager.authorizationStatus == .authorizedWhenInUse
      || manager.authorizationStatus == .authorizedAlways
    else {
      handler([])
      return
    }

    continuousLocations = []
    continuousHandler = handler
    manager.startUpdatingLocation()
  }

  func stopContinuousUpdates() -> [CLLocation] {
    manager.stopUpdatingLocation()
    let captured = continuousLocations
    continuousLocations = []
    continuousHandler = nil
    return captured
  }

  func locationManagerDidChangeAuthorization(_: CLLocationManager) {
    guard let authorizationContinuation else { return }
    self.authorizationContinuation = nil
    authorizationContinuation.resume(returning: currentAuthorizationState())
  }

  func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    if let singleLocationContinuation {
      self.singleLocationContinuation = nil
      singleLocationContinuation.resume(returning: locations.last)
      return
    }

    guard !locations.isEmpty else { return }
    continuousLocations.append(contentsOf: locations)
    continuousHandler?(Array(continuousLocations.suffix(5)))
  }

  func locationManager(_: CLLocationManager, didFailWithError _: Error) {
    if let singleLocationContinuation {
      self.singleLocationContinuation = nil
      singleLocationContinuation.resume(returning: nil)
    }
  }
}

enum PermissionLabPhotoExperiment {
  static func buildPickerResult(from results: [PHPickerResult]) async -> PermissionExperimentResult {
    let authorization = await PermissionBroker.shared.authorizationState(for: .photos)
    guard let first = results.first else {
      let analysis = PermissionRiskAnalyzer.analyze(
        type: .photos,
        authorization: authorization,
        fieldsCollected: ["已选项目数量=0"],
        fieldsUnavailable: ["未选择任何资源"],
        boundaryFindings: ["系统选择器在用户明确选择媒体前，不会向 App 暴露任何相册内容。"]
      )
      return .init(
        permissionType: .photos,
        authorizationStatus: authorization.status,
        authorizationSubstatus: authorization.substatus,
        triggerAction: "系统选择器选择",
        fieldsCollected: ["已选项目数量=0"],
        fieldsUnavailable: ["未选择任何资源"],
        boundaryFindings: ["系统选择器在用户明确选择媒体前，不会向 App 暴露任何相册内容。"],
        privacyRiskLevel: analysis.0,
        privacyImpactSummary: analysis.1,
        rawSamplePreview: "未选择任何内容",
        notes: authorization.notes
      )
    }

    var collected = ["已选项目数量=\(results.count)"]
    var unavailable: [String] = []
    var findings = [
      "系统选择器路径只返回用户明确勾选的项目，避免了对整个相册的广泛枚举。"
    ]

    let provider = first.itemProvider
    let typeIdentifiers = provider.registeredTypeIdentifiers
    collected.append("已注册类型标识=\(typeIdentifiers.joined(separator: ", "))")

    if let suggestedName = provider.suggestedName {
      collected.append("建议文件名=\(suggestedName)")
    } else {
      unavailable.append("建议文件名")
    }

    if let assetIdentifier = first.assetIdentifier {
      collected.append("资源标识符=\(assetIdentifier)")
    } else {
      findings.append("当前选择器样本没有暴露可复用的 PhotoKit 资源标识符。")
    }

    if let copiedURL = try? await copyRepresentativeFile(from: provider) {
      let values = try? copiedURL.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isReadableKey])
      if let fileSize = values?.fileSize {
        collected.append("临时文件大小=\(fileSize) 字节")
      } else {
        unavailable.append("临时文件大小")
      }
      if let contentType = values?.contentType {
        collected.append("内容类型=\(contentType.identifier)")
      } else {
        unavailable.append("内容类型")
      }

      if let metadata = imageMetadata(for: copiedURL) {
        collected.append("元数据顶层键=\(metadata.keys.sorted().joined(separator: ", "))")
      } else {
        unavailable.append("图像元数据")
      }
    } else {
      unavailable.append("临时文件表示")
    }

    let preview = typeIdentifiers.first ?? "未暴露项目提供器类型"
    let analysis = PermissionRiskAnalyzer.analyze(
      type: .photos,
      authorization: authorization,
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings
    )

    return .init(
      permissionType: .photos,
      authorizationStatus: authorization.status,
      authorizationSubstatus: authorization.substatus,
      triggerAction: "系统选择器选择",
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings,
      privacyRiskLevel: analysis.0,
      privacyImpactSummary: analysis.1,
      rawSamplePreview: preview,
      notes: authorization.notes
    )
  }

  static func buildPhotoKitResult() async -> PermissionExperimentResult {
    let authorization = await PermissionBroker.shared.authorizationState(for: .photos)
    var collected: [String] = []
    var unavailable: [String] = []
    var findings: [String] = []

    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    guard status == .authorized || status == .limited else {
      findings.append("缺少 PhotoKit 读取授权时，App 无法枚举相册，也无法检查资源元数据。")
      let analysis = PermissionRiskAnalyzer.analyze(
        type: .photos,
        authorization: authorization,
        fieldsCollected: collected,
        fieldsUnavailable: ["资源数量", "文件名", "时间信息", "EXIF", "地理位置", "媒体标记"],
        boundaryFindings: findings
      )
      return .init(
        permissionType: .photos,
        authorizationStatus: authorization.status,
        authorizationSubstatus: authorization.substatus,
        triggerAction: "PhotoKit 枚举",
        fieldsCollected: collected,
        fieldsUnavailable: ["资源数量", "文件名", "时间信息", "EXIF", "地理位置", "媒体标记"],
        boundaryFindings: findings,
        privacyRiskLevel: analysis.0,
        privacyImpactSummary: analysis.1,
        rawSamplePreview: "没有 PhotoKit 访问权限",
        notes: authorization.notes
      )
    }

    let options = PHFetchOptions()
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    options.fetchLimit = 10
    let assets = PHAsset.fetchAssets(with: options)

    collected.append("可访问资源数量=\(assets.count)")
    findings.append(status == .limited
      ? "受限相册模式只允许枚举用户手动选中的那部分资源。"
      : "完整 PhotoKit 授权允许对可见相册进行更广泛的枚举。")

    if let first = assets.firstObject {
      let resources = PHAssetResource.assetResources(for: first)
      if let name = resources.first?.originalFilename {
        collected.append("首个资源.原始文件名=\(name)")
      } else {
        unavailable.append("首个资源.原始文件名")
      }

      if let creationDate = first.creationDate {
        collected.append("首个资源.创建时间=\(creationDate.formatted(date: .abbreviated, time: .shortened))")
      } else {
        unavailable.append("首个资源.创建时间")
      }

      if let modificationDate = first.modificationDate {
        collected.append("首个资源.修改时间=\(modificationDate.formatted(date: .abbreviated, time: .shortened))")
      } else {
        unavailable.append("首个资源.修改时间")
      }

      if let location = first.location {
        collected.append("首个资源.地理位置=\(location.coordinate.latitude),\(location.coordinate.longitude)")
      } else {
        unavailable.append("首个资源.地理位置")
      }

      collected.append("首个资源.媒体类型=\(first.mediaType.displayName)")
      collected.append("首个资源.Live Photo=\(first.mediaSubtypes.contains(.photoLive))")

      if let burstIdentifier = first.burstIdentifier {
        collected.append("首个资源.连拍标识=\(burstIdentifier)")
      } else {
        unavailable.append("首个资源.连拍标识")
      }

      if let metadata = await photoKitMetadata(for: first) {
        collected.append("首个资源.元数据键=\(metadata.keys.sorted().joined(separator: ", "))")
        let hasGPS = metadata["{GPS}"] != nil
        collected.append("首个资源.GPS 元数据=\(hasGPS)")
      } else {
        unavailable.append("首个资源.EXIF 元数据")
        findings.append("样本资源没有返回图像数据，这通常发生在原件仅存在于云端或系统未向当前请求暴露原始数据时。")
      }
    } else {
      unavailable.append("没有可访问的资源样本")
    }

    if status == .limited {
      findings.append("可修改受限相册的选择范围后重新运行，以观察可见资源集合如何变化。")
    }

    let preview = collected.prefix(4).joined(separator: "\n")
    let analysis = PermissionRiskAnalyzer.analyze(
      type: .photos,
      authorization: authorization,
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings
    )

    return .init(
      permissionType: .photos,
      authorizationStatus: authorization.status,
      authorizationSubstatus: authorization.substatus,
      triggerAction: "PhotoKit 枚举",
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings,
      privacyRiskLevel: analysis.0,
      privacyImpactSummary: analysis.1,
      rawSamplePreview: preview,
      notes: authorization.notes
    )
  }

  private static func copyRepresentativeFile(from provider: NSItemProvider) async throws -> URL {
    let typeIdentifier = provider.registeredTypeIdentifiers.first
      ?? UTType.image.identifier

    return try await withCheckedThrowingContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        guard let url else {
          continuation.resume(throwing: CocoaError(.fileNoSuchFile))
          return
        }
        let copyURL = URL.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
          if FileManager.default.fileExists(atPath: copyURL.path) {
            try FileManager.default.removeItem(at: copyURL)
          }
          try FileManager.default.copyItem(at: url, to: copyURL)
          continuation.resume(returning: copyURL)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private static func photoKitMetadata(for asset: PHAsset) async -> [String: Any]? {
    let options = PHImageRequestOptions()
    options.isNetworkAccessAllowed = false
    options.version = .current

    let data = await withCheckedContinuation { continuation in
      PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
        continuation.resume(returning: data)
      }
    }

    guard let data else { return nil }
    let imageSource = CGImageSourceCreateWithData(data as CFData, nil)
    guard let imageSource,
      let metadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]
    else {
      return nil
    }
    return metadata
  }

  private static func imageMetadata(for url: URL) -> [String: Any]? {
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
      let metadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]
    else {
      return nil
    }
    return metadata
  }
}

enum PermissionLabLocationExperiment {
  static func makeSingleLocationResult(location: CLLocation?, authorization: PermissionAuthorizationState) -> PermissionExperimentResult {
    var collected: [String] = []
    var unavailable: [String] = []
    var findings: [String] = []

    if let location {
      collected.append("纬度=\(location.coordinate.latitude)")
      collected.append("经度=\(location.coordinate.longitude)")
      collected.append("水平精度=\(location.horizontalAccuracy)m")
      collected.append("垂直精度=\(location.verticalAccuracy)m")
      collected.append("速度=\(location.speed)m/s")
      collected.append("航向=\(location.course)")
      collected.append("时间戳=\(location.timestamp.formatted(date: .abbreviated, time: .standard))")
      if authorization.substatus.contains("模糊定位") {
        findings.append("模糊定位仍会暴露区域级位置，但不会提供足够精细的精确坐标。")
      } else {
        findings.append("精确定位会暴露更具体的坐标以及速度、航向等移动相关元数据。")
      }
    } else {
      unavailable = ["纬度", "经度", "定位精度", "速度", "航向", "时间戳"]
      findings.append("没有收到定位样本，通常是因为缺少权限，或模拟器当前无法解析位置。")
    }

    let analysis = PermissionRiskAnalyzer.analyze(
      type: .location,
      authorization: authorization,
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings
    )

    return .init(
      permissionType: .location,
      authorizationStatus: authorization.status,
      authorizationSubstatus: authorization.substatus,
      triggerAction: "单次定位",
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings,
      privacyRiskLevel: analysis.0,
      privacyImpactSummary: analysis.1,
      rawSamplePreview: collected.joined(separator: "\n").nilIfEmpty ?? "没有定位样本",
      notes: authorization.notes
    )
  }

  static func makeContinuousLocationResult(
    locations: [CLLocation],
    authorization: PermissionAuthorizationState
  ) -> PermissionExperimentResult {
    var collected = ["样本数量=\(locations.count)"]
    var unavailable: [String] = []
    var findings = ["持续定位只会在当前前台实验页面处于活动状态时运行。"]

    if let first = locations.first, let last = locations.last {
      collected.append("起点=\(first.coordinate.latitude),\(first.coordinate.longitude)")
      collected.append("终点=\(last.coordinate.latitude),\(last.coordinate.longitude)")
      collected.append("最新水平精度=\(last.horizontalAccuracy)m")
      collected.append("最新速度=\(last.speed)m/s")
      collected.append("最新航向=\(last.course)")
      if authorization.substatus.contains("模糊定位") {
        findings.append("模糊定位会降低持续轨迹的空间粒度。")
      }
    } else {
      unavailable.append("持续定位样本")
      findings.append("采集窗口内没有收到前台定位更新。")
    }

    let analysis = PermissionRiskAnalyzer.analyze(
      type: .location,
      authorization: authorization,
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings
    )

    return .init(
      permissionType: .location,
      authorizationStatus: authorization.status,
      authorizationSubstatus: authorization.substatus,
      triggerAction: "前台持续定位",
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings,
      privacyRiskLevel: analysis.0,
      privacyImpactSummary: analysis.1,
      rawSamplePreview: collected.joined(separator: "\n"),
      notes: authorization.notes
    )
  }
}

enum PermissionLabContactsExperiment {
  static func run() async -> PermissionExperimentResult {
    let authorization = await PermissionBroker.shared.authorizationState(for: .contacts)
    var collected: [String] = []
    var unavailable: [String] = []
    var findings: [String] = []

    let status = CNContactStore.authorizationStatus(for: .contacts)
    guard status == .authorized || status == .limited else {
      let analysis = PermissionRiskAnalyzer.analyze(
        type: .contacts,
        authorization: authorization,
        fieldsCollected: [],
        fieldsUnavailable: ["姓名", "电话", "邮箱", "组织", "生日", "地址", "头像"],
        boundaryFindings: ["在用户明确授予通讯录权限前，这些联系人字段不会对 App 可见。"]
      )
      return .init(
        permissionType: .contacts,
        authorizationStatus: authorization.status,
        authorizationSubstatus: authorization.substatus,
        triggerAction: "通讯录读取",
        fieldsCollected: [],
        fieldsUnavailable: ["姓名", "电话", "邮箱", "组织", "生日", "地址", "头像", "备注"],
        boundaryFindings: ["在用户明确授予通讯录权限前，这些联系人字段不会对 App 可见。"],
        privacyRiskLevel: analysis.0,
        privacyImpactSummary: analysis.1,
        rawSamplePreview: "没有读取到联系人",
        notes: authorization.notes + ["本实验将联系人备注视为系统限制字段，不主动请求该字段。"]
      )
    }

    let store = CNContactStore()
    let keys: [CNKeyDescriptor] = [
      CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
      CNContactPhoneNumbersKey as CNKeyDescriptor,
      CNContactEmailAddressesKey as CNKeyDescriptor,
      CNContactOrganizationNameKey as CNKeyDescriptor,
      CNContactBirthdayKey as CNKeyDescriptor,
      CNContactPostalAddressesKey as CNKeyDescriptor,
      CNContactImageDataAvailableKey as CNKeyDescriptor,
    ]
    let request = CNContactFetchRequest(keysToFetch: keys)

    var sampleContacts: [CNContact] = []
    var fetchedCount = 0
    do {
      try store.enumerateContacts(with: request) { contact, stop in
        fetchedCount += 1
        if sampleContacts.count < 5 {
          sampleContacts.append(contact)
        }
        if fetchedCount >= 20 {
          stop.pointee = true
        }
      }
    } catch {
      findings.append("通讯录枚举失败：\(error.localizedDescription)")
    }

    collected.append("读取联系人数量=\(fetchedCount)")
    if let first = sampleContacts.first {
      let name = CNContactFormatter.string(from: first, style: .fullName) ?? "未命名"
      collected.append("样本.姓名=\(name)")
      collected.append("样本.电话数量=\(first.phoneNumbers.count)")
      collected.append("样本.邮箱数量=\(first.emailAddresses.count)")
      collected.append("样本.组织=\(first.organizationName.nilIfEmpty ?? "空")")
      collected.append("样本.有生日=\(first.birthday != nil)")
      collected.append("样本.地址数量=\(first.postalAddresses.count)")
      collected.append("样本.有头像=\(first.imageDataAvailable)")
    } else {
      unavailable.append("联系人样本")
    }

    unavailable.append("备注字段未主动请求，因为 iOS 通常会将其视为第三方受限字段")
    if #available(iOS 18.0, *), status == .limited {
      findings.append("受限通讯录只返回用户选中的联系人子集，而不是整个通讯录。")
    } else {
      findings.append("在已授权状态下，姓名、电话、邮箱和组织等字段足以暴露明显的关系图谱信号。")
    }

    let analysis = PermissionRiskAnalyzer.analyze(
      type: .contacts,
      authorization: authorization,
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings
    )

    return .init(
      permissionType: .contacts,
      authorizationStatus: authorization.status,
      authorizationSubstatus: authorization.substatus,
      triggerAction: "通讯录读取",
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings,
      privacyRiskLevel: analysis.0,
      privacyImpactSummary: analysis.1,
      rawSamplePreview: collected.joined(separator: "\n"),
      notes: authorization.notes
    )
  }
}

enum PermissionLabPasteboardExperiment {
  static func runProgrammaticRead(path: String) async -> PermissionExperimentResult {
    let authorization = await PermissionBroker.shared.authorizationState(for: .pasteboard)
    let pasteboard = UIPasteboard.general

    var collected: [String] = [
      "包含文本=\(pasteboard.hasStrings)",
      "包含 URL=\(pasteboard.hasURLs)",
      "包含图片=\(pasteboard.hasImages)",
      "项目数量=\(pasteboard.items.count)"
    ]
    var unavailable: [String] = []
    var findings = [
      "粘贴确认界面由 iOS 控制，公开 API 无法直接观察是否弹窗。"
    ]

    if let string = pasteboard.string {
      collected.append("文本预览=\(String(string.prefix(120)))")
    } else {
      unavailable.append("文本值")
    }

    if let url = pasteboard.url {
      collected.append("URL=\(url.absoluteString)")
    } else {
      unavailable.append("URL 值")
    }

    if let image = pasteboard.image {
      collected.append("图片尺寸=\(Int(image.size.width))x\(Int(image.size.height))")
    } else {
      unavailable.append("图片值")
    }

    if path == "programmaticRead" {
      findings.append("程序直接读取不依赖系统粘贴控件，本质上是直接访问当前剪贴板内容。")
    } else if path == "explicitButtonRead" {
      findings.append("这一路径依然属于程序读取，但触发方式变成了用户前台明确点击。")
    }

    let triggerAction = switch path {
    case "programmaticRead":
      "程序直接读取"
    case "explicitButtonRead":
      "显式按钮读取"
    default:
      path
    }

    let analysis = PermissionRiskAnalyzer.analyze(
      type: .pasteboard,
      authorization: authorization,
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings
    )

    return .init(
      permissionType: .pasteboard,
      authorizationStatus: authorization.status,
      authorizationSubstatus: authorization.substatus,
      triggerAction: triggerAction,
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings,
      privacyRiskLevel: analysis.0,
      privacyImpactSummary: analysis.1,
      rawSamplePreview: collected.joined(separator: "\n"),
      notes: authorization.notes
    )
  }

  static func runPasteButtonResult(providers: [NSItemProvider]) async -> PermissionExperimentResult {
    let authorization = await PermissionBroker.shared.authorizationState(for: .pasteboard)
    var collected = ["提供器数量=\(providers.count)"]
    var unavailable: [String] = []
    let findings = [
      "PasteButton 走的是系统推荐的显式粘贴交互路径。",
      "App 只能拿到用户通过系统粘贴流程明确确认的数据类型。"
    ]

    if let first = providers.first {
      collected.append("已注册类型=\(first.registeredTypeIdentifiers.joined(separator: ", "))")
      if let string = await loadString(from: first) {
        collected.append("文本预览=\(String(string.prefix(120)))")
      } else {
        unavailable.append("文本预览")
      }
    } else {
      unavailable.append("粘贴提供器")
    }

    let analysis = PermissionRiskAnalyzer.analyze(
      type: .pasteboard,
      authorization: authorization,
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings
    )

    return .init(
      permissionType: .pasteboard,
      authorizationStatus: authorization.status,
      authorizationSubstatus: authorization.substatus,
      triggerAction: "系统粘贴按钮",
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings,
      privacyRiskLevel: analysis.0,
      privacyImpactSummary: analysis.1,
      rawSamplePreview: collected.joined(separator: "\n"),
      notes: authorization.notes
    )
  }

  private static func loadString(from provider: NSItemProvider) async -> String? {
    guard provider.canLoadObject(ofClass: NSString.self) else { return nil }

    return await withCheckedContinuation { continuation in
      provider.loadObject(ofClass: NSString.self) { object, _ in
        continuation.resume(returning: object as? String)
      }
    }
  }
}

enum PermissionLabFilesExperiment {
  static func run(selectedURL: URL) async -> PermissionExperimentResult {
    let authorization = await PermissionBroker.shared.authorizationState(for: .files)

    var collected: [String] = []
    var unavailable: [String] = []
    var findings = ["只有在用户明确选择文件后，App 才能看到文档元数据。"]
    let didAccess = selectedURL.startAccessingSecurityScopedResource()
    defer {
      if didAccess {
        selectedURL.stopAccessingSecurityScopedResource()
      }
    }

    let values = try? selectedURL.resourceValues(forKeys: [.nameKey, .contentTypeKey, .fileSizeKey, .isReadableKey])
    collected.append("文件名=\(values?.name ?? selectedURL.lastPathComponent)")
    if let contentType = values?.contentType {
      collected.append("内容类型=\(contentType.identifier)")
    } else {
      unavailable.append("内容类型")
    }
    if let fileSize = values?.fileSize {
      collected.append("文件大小=\(fileSize) 字节")
    } else {
      unavailable.append("文件大小")
    }
    collected.append("安全作用域访问=\(didAccess)")
    collected.append("可见路径=\(selectedURL.path)")

    if let bookmarkData = try? selectedURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
      collected.append("书签数据大小=\(bookmarkData.count) 字节")
    } else {
      unavailable.append("书签数据")
    }

    findings.append("这里看到的路径通常是沙箱路径或文件提供者 URL，并不是完整、无限制的文件系统视图。")
    let analysis = PermissionRiskAnalyzer.analyze(
      type: .files,
      authorization: authorization,
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings
    )

    return .init(
      permissionType: .files,
      authorizationStatus: authorization.status,
      authorizationSubstatus: authorization.substatus,
      triggerAction: "文档选择器选择",
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings,
      privacyRiskLevel: analysis.0,
      privacyImpactSummary: analysis.1,
      rawSamplePreview: collected.joined(separator: "\n"),
      notes: authorization.notes
    )
  }
}

enum PermissionLabCameraExperiment {
  static func run(info: [UIImagePickerController.InfoKey: Any]) async -> PermissionExperimentResult {
    let authorization = await PermissionBroker.shared.authorizationState(for: .camera)
    var collected: [String] = []
    var unavailable: [String] = []
    var findings = ["不会进行隐藏拍摄；样本只会在用户可见交互后产生。"]

    if let image = info[.originalImage] as? UIImage {
      collected.append("图片尺寸=\(Int(image.size.width))x\(Int(image.size.height))")
    } else {
      unavailable.append("拍摄图像")
    }

    if let metadata = info[.mediaMetadata] as? [String: Any] {
      collected.append("元数据键=\(metadata.keys.sorted().joined(separator: ", "))")
    } else {
      unavailable.append("相机元数据")
      findings.append("UIImagePicker 在不同设备或模拟器上不一定会暴露全部拍摄元数据。")
    }

    let analysis = PermissionRiskAnalyzer.analyze(
      type: .camera,
      authorization: authorization,
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings
    )

    return .init(
      permissionType: .camera,
      authorizationStatus: authorization.status,
      authorizationSubstatus: authorization.substatus,
      triggerAction: "可见相机拍摄",
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings,
      privacyRiskLevel: analysis.0,
      privacyImpactSummary: analysis.1,
      rawSamplePreview: collected.joined(separator: "\n"),
      notes: authorization.notes
    )
  }
}

@MainActor
final class PermissionLabMicrophoneRecorder: NSObject, AVAudioRecorderDelegate {
  private var recorder: AVAudioRecorder?
  private(set) var outputURL: URL?

  func startRecording() throws {
    let directory = URL.documentsDirectory.appending(path: "PermissionLabAudio", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: nil
    )
    let outputURL = directory.appending(path: "\(UUID().uuidString).m4a")
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]
    let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
    recorder.delegate = self
    recorder.record()
    self.recorder = recorder
    self.outputURL = outputURL
  }

  func stopRecording() {
    recorder?.stop()
  }

  func buildResult() async -> PermissionExperimentResult {
    let authorization = await PermissionBroker.shared.authorizationState(for: .microphone)
    var collected: [String] = []
    var unavailable: [String] = []
    let findings = ["录音只会在用户明确点击录音按钮后开始。"]

    if let outputURL {
      let asset = AVURLAsset(url: outputURL)
      let duration = try? await asset.load(.duration)
      let durationSeconds = duration?.seconds ?? 0
      collected.append("文件路径=\(outputURL.path)")
      collected.append("时长=\(durationSeconds)s")
      if let settings = recorder?.settings {
        if let sampleRate = settings[AVSampleRateKey] {
          collected.append("采样率=\(sampleRate)")
        }
        if let format = settings[AVFormatIDKey] {
          collected.append("音频格式=\(format)")
        }
      } else {
        unavailable.append("录音设置")
      }
    } else {
      unavailable.append("音频文件")
    }

    let analysis = PermissionRiskAnalyzer.analyze(
      type: .microphone,
      authorization: authorization,
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings
    )

    return .init(
      permissionType: .microphone,
      authorizationStatus: authorization.status,
      authorizationSubstatus: authorization.substatus,
      triggerAction: "前台录音",
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings,
      privacyRiskLevel: analysis.0,
      privacyImpactSummary: analysis.1,
      rawSamplePreview: collected.joined(separator: "\n"),
      notes: authorization.notes
    )
  }
}

enum PermissionLabEventKitExperiment {
  static func run(for type: PermissionType) async -> PermissionExperimentResult {
    let authorization = await PermissionBroker.shared.authorizationState(for: type)
    let store = EKEventStore()
    var collected: [String] = []
    var unavailable: [String] = []
    var findings: [String] = []

    switch type {
    case .calendar:
      let status = EKEventStore.authorizationStatus(for: .event)
      guard status == .fullAccess || status == .authorized else {
        unavailable = ["标题", "开始时间", "结束时间", "地点", "备注", "参与人"]
        findings.append("在授予完整日历访问权限前，这些日历字段对 App 不可见。")
        return makeEventKitResult(
          type: type,
          authorization: authorization,
          collected: collected,
          unavailable: unavailable,
          findings: findings
        )
      }

      let calendars = store.calendars(for: .event)
      let predicate = store.predicateForEvents(withStart: .now.addingTimeInterval(-86_400), end: .now.addingTimeInterval(30 * 86_400), calendars: calendars)
      let events = store.events(matching: predicate)
      collected.append("可见事件数量=\(events.count)")
      if let event = events.first {
        collected.append("样本.标题=\(event.title ?? "空")")
        collected.append("样本.开始时间=\(event.startDate?.formatted(date: .abbreviated, time: .shortened) ?? "空")")
        collected.append("样本.地点=\(event.location ?? "空")")
        collected.append("样本.有备注=\(!(event.notes ?? "").isEmpty)")
        collected.append("样本.参与人数=\(event.attendees?.count ?? 0)")
      } else {
        unavailable.append("日历样本")
      }
    case .reminders:
      let status = EKEventStore.authorizationStatus(for: .reminder)
      guard status == .fullAccess || status == .authorized else {
        unavailable = ["标题", "到期时间", "备注", "所属列表"]
        findings.append("在授予完整提醒事项访问权限前，这些提醒字段对 App 不可见。")
        return makeEventKitResult(
          type: type,
          authorization: authorization,
          collected: collected,
          unavailable: unavailable,
          findings: findings
        )
      }

      let predicate = store.predicateForReminders(in: nil)
      let reminderSnapshot = await withCheckedContinuation { continuation in
        store.fetchReminders(matching: predicate) { reminders in
          let resolvedReminders = reminders ?? []
          let first = resolvedReminders.first
          continuation.resume(
            returning: ReminderSnapshot(
              count: resolvedReminders.count,
              title: first?.title,
              calendarTitle: first?.calendar.title,
              notesPresent: !((first?.notes ?? "").isEmpty),
              hasDueDate: first?.dueDateComponents != nil
            )
          )
        }
      }
      collected.append("可见提醒数量=\(reminderSnapshot.count)")
      if reminderSnapshot.count > 0 {
        collected.append("样本.标题=\(reminderSnapshot.title ?? "空")")
        collected.append("样本.所属列表=\(reminderSnapshot.calendarTitle ?? "空")")
        collected.append("样本.有备注=\(reminderSnapshot.notesPresent)")
        collected.append("样本.有到期时间=\(reminderSnapshot.hasDueDate)")
      } else {
        unavailable.append("提醒事项样本")
      }
    default:
      break
    }

    findings.append("EventKit 只会返回用户明确授权的数据类型。")
    return makeEventKitResult(
      type: type,
      authorization: authorization,
      collected: collected,
      unavailable: unavailable,
      findings: findings
    )
  }

  private static func makeEventKitResult(
    type: PermissionType,
    authorization: PermissionAuthorizationState,
    collected: [String],
    unavailable: [String],
    findings: [String]
  ) -> PermissionExperimentResult {
    let analysis = PermissionRiskAnalyzer.analyze(
      type: type,
      authorization: authorization,
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings
    )

    return .init(
      permissionType: type,
      authorizationStatus: authorization.status,
      authorizationSubstatus: authorization.substatus,
      triggerAction: type == .calendar ? "日历读取" : "提醒事项读取",
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings,
      privacyRiskLevel: analysis.0,
      privacyImpactSummary: analysis.1,
      rawSamplePreview: collected.joined(separator: "\n").nilIfEmpty ?? "没有 EventKit 样本",
      notes: authorization.notes
    )
  }
}

private struct ReminderSnapshot: Sendable {
  let count: Int
  let title: String?
  let calendarTitle: String?
  let notesPresent: Bool
  let hasDueDate: Bool
}

enum PermissionLabMotionExperiment {
  static func run() async -> PermissionExperimentResult {
    let authorization = await PermissionBroker.shared.authorizationState(for: .motion)
    let manager = CMMotionManager()
    var collected: [String] = [
      "加速度计可用=\(manager.isAccelerometerAvailable)",
      "陀螺仪可用=\(manager.isGyroAvailable)",
      "设备运动可用=\(manager.isDeviceMotionAvailable)"
    ]
    var unavailable: [String] = []
    let findings = ["本模块只做一次前台短时能力快照，不进行后台运动持续记录。"]

    if manager.isDeviceMotionAvailable {
      manager.deviceMotionUpdateInterval = 0.2
      manager.startDeviceMotionUpdates()
      try? await Task.sleep(for: .milliseconds(250))
      if let motion = manager.deviceMotion {
        collected.append("重力向量=\(motion.gravity.x),\(motion.gravity.y),\(motion.gravity.z)")
        collected.append("用户加速度=\(motion.userAcceleration.x),\(motion.userAcceleration.y),\(motion.userAcceleration.z)")
      } else {
        unavailable.append("设备运动样本")
      }
      manager.stopDeviceMotionUpdates()
    } else {
      unavailable.append("设备运动样本")
    }

    let analysis = PermissionRiskAnalyzer.analyze(
      type: .motion,
      authorization: authorization,
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings
    )

    return .init(
      permissionType: .motion,
      authorizationStatus: authorization.status,
      authorizationSubstatus: authorization.substatus,
      triggerAction: "运动快照",
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings,
      privacyRiskLevel: analysis.0,
      privacyImpactSummary: analysis.1,
      rawSamplePreview: collected.joined(separator: "\n"),
      notes: authorization.notes
    )
  }
}

enum PermissionLabMediaLibraryExperiment {
  static func run() async -> PermissionExperimentResult {
    let authorization = await PermissionBroker.shared.authorizationState(for: .mediaLibrary)
    var collected: [String] = []
    var unavailable: [String] = []
    var findings: [String] = []

    if MPMediaLibrary.authorizationStatus() == .authorized {
      let query = MPMediaQuery.songs()
      let items = query.items ?? []
      collected.append("可见歌曲数量=\(items.count)")
      if let song = items.first {
        collected.append("样本.标题=\(song.title ?? "空")")
        collected.append("样本.歌手=\(song.artist ?? "空")")
        collected.append("样本.专辑=\(song.albumTitle ?? "空")")
        collected.append("样本.播放时长=\(song.playbackDuration)")
      } else {
        unavailable.append("媒体样本")
      }
      findings.append("当设备存在本地或可见媒体资料库内容时，媒体资料库访问会暴露明显的听歌偏好信号。")
    } else {
      unavailable = ["歌曲标题", "歌手", "专辑", "时长"]
      findings.append("没有媒体资料库授权时，这部分查询面保持不可用。")
    }

    let analysis = PermissionRiskAnalyzer.analyze(
      type: .mediaLibrary,
      authorization: authorization,
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings
    )

    return .init(
      permissionType: .mediaLibrary,
      authorizationStatus: authorization.status,
      authorizationSubstatus: authorization.substatus,
      triggerAction: "媒体资料库查询",
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings,
      privacyRiskLevel: analysis.0,
      privacyImpactSummary: analysis.1,
      rawSamplePreview: collected.joined(separator: "\n").nilIfEmpty ?? "没有媒体样本",
      notes: authorization.notes
    )
  }
}

struct PermissionLabSystemPhotoPicker: UIViewControllerRepresentable {
  let onResults: ([PHPickerResult]) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onResults: onResults)
  }

  func makeUIViewController(context: Context) -> PHPickerViewController {
    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.selectionLimit = 3
    configuration.filter = .any(of: [.images, .videos, .livePhotos])
    let controller = PHPickerViewController(configuration: configuration)
    controller.delegate = context.coordinator
    return controller
  }

  func updateUIViewController(_: PHPickerViewController, context _: Context) {}

  final class Coordinator: NSObject, PHPickerViewControllerDelegate {
    let onResults: ([PHPickerResult]) -> Void

    init(onResults: @escaping ([PHPickerResult]) -> Void) {
      self.onResults = onResults
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
      picker.dismiss(animated: true)
      onResults(results)
    }
  }
}

struct PermissionLabDocumentPicker: UIViewControllerRepresentable {
  let onPick: (URL) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onPick: onPick)
  }

  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
    controller.delegate = context.coordinator
    controller.allowsMultipleSelection = false
    return controller
  }

  func updateUIViewController(_: UIDocumentPickerViewController, context _: Context) {}

  final class Coordinator: NSObject, UIDocumentPickerDelegate {
    let onPick: (URL) -> Void

    init(onPick: @escaping (URL) -> Void) {
      self.onPick = onPick
    }

    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
      guard let first = urls.first else { return }
      onPick(first)
    }
  }
}

struct PermissionLabCameraCaptureView: UIViewControllerRepresentable {
  let onCapture: ([UIImagePickerController.InfoKey: Any]) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onCapture: onCapture)
  }

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let controller = UIImagePickerController()
    controller.sourceType = .camera
    controller.mediaTypes = ["public.image"]
    controller.delegate = context.coordinator
    return controller
  }

  func updateUIViewController(_: UIImagePickerController, context _: Context) {}

  final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
    let onCapture: ([UIImagePickerController.InfoKey: Any]) -> Void

    init(onCapture: @escaping ([UIImagePickerController.InfoKey: Any]) -> Void) {
      self.onCapture = onCapture
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      picker.dismiss(animated: true)
    }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      picker.dismiss(animated: true)
      onCapture(info)
    }
  }
}

// MARK: - Notification experiment

enum PermissionLabNotificationExperiment {
  @MainActor
  static func scheduleLocalNotification() async -> PermissionExperimentResult {
    let center = UNUserNotificationCenter.current()
    var collected: [String] = []
    var unavailable: [String] = []
    var findings: [String] = []

    // Step 1: Request permission (triggers system prompt if not yet decided)
    let granted: Bool
    do {
      granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
    } catch {
      granted = false
      findings.append("权限请求失败：\(error.localizedDescription)")
    }
    collected.append("授权请求结果=\(granted ? "已授权" : "已拒绝/失败")")

    // Step 2: Read detailed settings
    let settings = await center.notificationSettings()
    collected.append("授权状态=\(settings.authorizationStatus.displayName)")
    collected.append("提醒=\(settings.alertSetting.displayName)")
    collected.append("角标=\(settings.badgeSetting.displayName)")
    collected.append("声音=\(settings.soundSetting.displayName)")
    collected.append("锁屏=\(settings.lockScreenSetting.displayName)")
    collected.append("通知中心=\(settings.notificationCenterSetting.displayName)")
    collected.append("提醒样式=\(settings.alertStyle.displayName)")
    if #available(iOS 15.0, *) {
      collected.append("时效性=\(settings.timeSensitiveSetting.displayName)")
    } else {
      unavailable.append("时效性通知设置（需要 iOS 15+）")
    }

    let authorization = PermissionAuthorizationState(
      status: settings.authorizationStatus.displayName,
      substatus: [],
      notes: []
    )

    guard granted else {
      findings.append("未授予通知权限，无法调度本地通知演示。")
      findings.append("本实验不使用 silent push、后台唤醒或任何隐蔽采集能力。")
      let analysis = PermissionRiskAnalyzer.analyze(
        type: .notifications,
        authorization: authorization,
        fieldsCollected: collected,
        fieldsUnavailable: unavailable,
        boundaryFindings: findings
      )
      return .init(
        permissionType: .notifications,
        authorizationStatus: authorization.status,
        authorizationSubstatus: authorization.substatus,
        triggerAction: "本地通知演示",
        fieldsCollected: collected,
        fieldsUnavailable: unavailable,
        boundaryFindings: findings,
        privacyRiskLevel: analysis.0,
        privacyImpactSummary: analysis.1,
        rawSamplePreview: "已拒绝通知权限，未调度本地通知。",
        notes: ["本实验不使用 silent push，不实现任何后台唤醒或隐蔽采集能力。"]
      )
    }

    // Step 3: Schedule a visible local notification with short delay
    let content = UNMutableNotificationContent()
    content.title = "权限实验室本地通知"
    content.body = "这是一条由用户显式触发的本地通知演示，用于记录系统提示行为。"
    content.sound = .default
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
    let requestID = "permission-lab-demo-\(UUID().uuidString)"
    let request = UNNotificationRequest(identifier: requestID, content: content, trigger: trigger)

    do {
      try await center.add(request)
      collected.append("本地通知调度=已成功（3 秒后触发）")
      findings.append("通知已调度：对用户完全可见（横幅/提示框/锁屏），展示形式由系统设置决定。")
      findings.append("前台时 App 若未实现 UNUserNotificationCenterDelegate，通知不会自动展示。")
    } catch {
      unavailable.append("本地通知调度失败：\(error.localizedDescription)")
    }

    // Step 4: Boundary observation — pending count
    let pending = await center.pendingNotificationRequests()
    collected.append("当前待发通知数量=\(pending.count)")
    findings.append("系统保留通知展示与调度的最终控制权，App 无法绕过系统设置强制弹出通知。")
    findings.append("本实验不使用 silent push，不实现任何后台唤醒或隐蔽采集能力。")

    let analysis = PermissionRiskAnalyzer.analyze(
      type: .notifications,
      authorization: authorization,
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings
    )
    return .init(
      permissionType: .notifications,
      authorizationStatus: authorization.status,
      authorizationSubstatus: authorization.substatus,
      triggerAction: "本地通知演示",
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings,
      privacyRiskLevel: analysis.0,
      privacyImpactSummary: analysis.1,
      rawSamplePreview: collected.prefix(3).joined(separator: "\n"),
      notes: ["本实验不使用 silent push，不实现任何后台唤醒或隐蔽采集能力。"]
    )
  }
}

// MARK: - Local network probe (Bonjour / Network.framework)

/// Performs a foreground-only, user-triggered Bonjour browse to observe local network
/// permission behavior. Uses NWBrowser which triggers the system prompt on first run.
@MainActor
final class PermissionLabLocalNetworkProbe: NSObject {
  private var browser: NWBrowser?
  private var foundServices: [String] = []
  private var hasCompleted = false
  private var completion: (([String], String?) -> Void)?

  func probe(timeout: TimeInterval = 4.0) async -> ([String], String?) {
    await withCheckedContinuation { [weak self] cont in
      guard let self else { cont.resume(returning: ([], nil)); return }
      self.completion = { services, error in cont.resume(returning: (services, error)) }
      self.startBrowsing()
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(timeout))
        self?.complete(error: nil)
      }
    }
  }

  private func startBrowsing() {
    let browser = NWBrowser(for: .bonjour(type: "_http._tcp.", domain: nil), using: .tcp)
    self.browser = browser

    browser.browseResultsChangedHandler = { [weak self] results, _ in
      let services = results.prefix(10).compactMap { result -> String? in
        if case let .service(name, type, _, _) = result.endpoint {
          return "\(name) (\(type))"
        }
        return nil
      }
      Task { @MainActor [weak self] in self?.foundServices = services }
    }

    browser.stateUpdateHandler = { [weak self] state in
      if case .failed(let nwError) = state {
        Task { @MainActor [weak self] in self?.complete(error: nwError.localizedDescription) }
      }
    }

    browser.start(queue: .global(qos: .utility))
  }

  private func complete(error: String?) {
    guard !hasCompleted else { return }
    hasCompleted = true
    browser?.cancel()
    browser = nil
    completion?(foundServices, error)
    completion = nil
  }
}

enum PermissionLabLocalNetworkExperiment {
  @MainActor
  static func run() async -> PermissionExperimentResult {
    var collected: [String] = []
    var unavailable: [String] = []
    var findings: [String] = []

    // Check static config prerequisites
    let info = Bundle.main.infoDictionary ?? [:]
    let hasUsageDesc = (info["NSLocalNetworkUsageDescription"] as? String).map { !$0.isEmpty } ?? false
    let bonjourServices = info["NSBonjourServices"] as? [String] ?? []

    collected.append("NSLocalNetworkUsageDescription=\(hasUsageDesc ? "已配置" : "缺失")")
    collected.append("NSBonjourServices=\(bonjourServices.isEmpty ? "未声明" : bonjourServices.joined(separator: ", "))")

    if !hasUsageDesc {
      unavailable.append("NSLocalNetworkUsageDescription 未配置，系统不会弹出授权提示")
      findings.append("缺少 NSLocalNetworkUsageDescription，本地网络提示无法触发。请先补充 Info.plist。")
    }

    findings.append("本地网络没有统一公开的授权状态查询 API，通过触发结果观察边界行为。")
    findings.append("本次发现尝试仅在用户点击触发后执行，不实现任何后台持续扫描。")

    // Execute Bonjour browse — this triggers the system local network permission prompt
    let probe = PermissionLabLocalNetworkProbe()
    let (services, probeError) = await probe.probe(timeout: 4.0)

    if let probeError {
      findings.append("Bonjour 浏览失败：\(probeError)。可能被拒绝了本地网络权限，或环境中没有可发现服务。")
      unavailable.append("Bonjour 服务发现（失败）")
    } else if services.isEmpty {
      findings.append("Bonjour 浏览未发现 _http._tcp. 服务。可能权限被拒绝，或当前局域网内没有此类服务。")
      unavailable.append("可发现的 _http._tcp. 服务")
    } else {
      collected.append("发现服务数量=\(services.count)")
      for service in services {
        collected.append("服务=\(service)")
      }
      findings.append("成功发现 \(services.count) 个 _http._tcp. 服务，说明本地网络权限已授予。")
    }

    findings.append("真机 + 真实局域网才能完整验证本地网络提示行为和服务发现结果。")

    let authorization = PermissionAuthorizationState(
      status: probeError == nil && !services.isEmpty ? "已触发并发现服务" : "已触发（无发现或权限受限）",
      substatus: [],
      notes: ["本地网络没有统一授权状态 API；以触发结果和错误语义表达边界。"]
    )

    let analysis = PermissionRiskAnalyzer.analyze(
      type: .localNetwork,
      authorization: authorization,
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings
    )
    return .init(
      permissionType: .localNetwork,
      authorizationStatus: authorization.status,
      authorizationSubstatus: authorization.substatus,
      triggerAction: "Bonjour 发现触发",
      fieldsCollected: collected,
      fieldsUnavailable: unavailable,
      boundaryFindings: findings,
      privacyRiskLevel: analysis.0,
      privacyImpactSummary: analysis.1,
      rawSamplePreview: services.isEmpty ? "无发现结果" : services.prefix(3).joined(separator: "\n"),
      notes: authorization.notes
    )
  }
}

extension PHAssetMediaType {
  var displayName: String {
    switch self {
    case .image: "image"
    case .video: "video"
    case .audio: "audio"
    case .unknown: "unknown"
    @unknown default: "unknown"
    }
  }
}
