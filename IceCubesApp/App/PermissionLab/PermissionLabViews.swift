import AVFoundation
import CoreLocation
import EventKit
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import UIKit

// SwiftUI surfaces for the permission boundary experiment lab.

@MainActor
struct PermissionLabHomeView: View {
  @Environment(PermissionBroker.self) private var broker
  @Environment(PermissionLabResultStore.self) private var resultStore

  @State private var statuses: [PermissionType: PermissionAuthorizationState] = [:]
  @State private var requestingPermission: PermissionType?

  var body: some View {
    List {
      Section("权限实验室") {
        VStack(alignment: .leading, spacing: 8) {
          Text("权限边界实验室")
            .font(.headline)
          Text("系统化检查在用户明确授权、显式触发的前提下，各类 iOS 权限究竟能暴露哪些数据、哪些字段仍被系统限制，以及这些数据可能造成的隐私风险。")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
      }

      Section("实验模块") {
        ForEach(PermissionType.allCases) { type in
          PermissionModuleRow(
            type: type,
            status: statuses[type] ?? .unknown,
            hasResult: resultStore.latestResults[type] != nil,
            isRequesting: requestingPermission == type,
            onRequest: { requestPermission(for: type) }
          )
        }
      }

      Section("分析与导出") {
        NavigationLink(destination: PermissionExperimentOverviewView()) {
          Label("实验总览", systemImage: "square.text.square")
        }
        NavigationLink(destination: PermissionLabExportView()) {
          Label("本地导出", systemImage: "square.and.arrow.up")
        }
        NavigationLink(destination: PermissionLabRiskGuideView()) {
          Label("风险分析说明", systemImage: "exclamationmark.shield")
        }
        NavigationLink(destination: PermissionStaticAuditView()) {
          Label("静态合规审计", systemImage: "checkmark.shield")
        }
        NavigationLink(destination: PermissionBackgroundMatrixView()) {
          Label("后台能力矩阵", systemImage: "square.stack.3d.up")
        }
        NavigationLink(destination: PermissionLabCoverageSuggestionsView()) {
          Label("未覆盖权限建议", systemImage: "list.bullet.clipboard")
        }
      }
    }
    .navigationTitle("权限实验室")
    .task {
      await refreshStatuses()
    }
  }

  private func refreshStatuses() async {
    var updated: [PermissionType: PermissionAuthorizationState] = [:]
    for type in PermissionType.allCases {
      updated[type] = await broker.authorizationState(for: type)
    }
    statuses = updated
  }

  private func requestPermission(for type: PermissionType) {
    requestingPermission = type
    Task {
      statuses[type] = await broker.requestAuthorization(for: type)
      requestingPermission = nil
    }
  }
}

private struct PermissionModuleRow: View {
  let type: PermissionType
  let status: PermissionAuthorizationState
  let hasResult: Bool
  let isRequesting: Bool
  let onRequest: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        Label(type.title, systemImage: type.iconName)
          .font(.headline)
        Spacer()
        VStack(alignment: .trailing, spacing: 2) {
          Text(status.status)
            .font(.subheadline.monospaced())
          if !status.substatus.isEmpty {
            Text(status.substatus.joined(separator: ", "))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      Text(type.shortDescription)
        .font(.footnote)
        .foregroundStyle(.secondary)

      HStack {
        Button(isRequesting ? "请求中..." : "请求权限", action: onRequest)
          .buttonStyle(.borderedProminent)
          .disabled(isRequesting)

        NavigationLink(destination: PermissionExperimentDetailView(type: type)) {
          Text("执行实验")
        }
        .buttonStyle(.bordered)

        NavigationLink(destination: PermissionExperimentResultView(type: type)) {
          Text(hasResult ? "查看结果" : "暂无结果")
        }
        .buttonStyle(.bordered)
        .disabled(!hasResult)
      }
      .font(.caption)
    }
    .padding(.vertical, 4)
  }
}

@MainActor
struct PermissionExperimentDetailView: View {
  let type: PermissionType

  var body: some View {
    Group {
      switch type {
      case .photos:
        PhotosExperimentView()
      case .location:
        LocationExperimentView()
      case .contacts:
        ContactsExperimentView()
      case .pasteboard:
        PasteboardExperimentView()
      case .files:
        FilesExperimentView()
      case .camera:
        CameraExperimentView()
      case .microphone:
        MicrophoneExperimentView()
      case .notifications:
        NotificationsExperimentView()
      case .calendar:
        EventKitExperimentView(type: .calendar)
      case .reminders:
        EventKitExperimentView(type: .reminders)
      case .motion:
        MotionExperimentView()
      case .mediaLibrary:
        MediaLibraryExperimentView()
      case .localNetwork:
        LocalNetworkExperimentView()
      }
    }
    .navigationTitle(type.title)
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct ExperimentLatestResultSection: View {
  let result: PermissionExperimentResult?

  var body: some View {
    Section("最近一次结果") {
      if let result {
        VStack(alignment: .leading, spacing: 8) {
          Text(result.formattedTimestamp)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(result.rawSamplePreview.isEmpty ? "暂无样例预览" : result.rawSamplePreview)
            .font(.footnote.monospaced())
          NavigationLink(destination: PermissionExperimentResultView(type: result.permissionType)) {
            Label("打开完整结果页", systemImage: "doc.text.magnifyingglass")
          }
        }
      } else {
        Text("当前还没有保存实验结果。")
          .foregroundStyle(.secondary)
      }
    }
  }
}

@MainActor
private struct PhotosExperimentView: View {
  @Environment(PermissionBroker.self) private var broker
  @Environment(PermissionLabResultStore.self) private var resultStore

  @State private var authorization: PermissionAuthorizationState = .unknown
  @State private var isShowingSystemPicker = false
  @State private var isRunningPhotoKit = false

  var body: some View {
    Form {
      authorizationSection

      Section("实验路径") {
        Button("执行系统选择器最小权限路径") {
          isShowingSystemPicker = true
        }

        Button(isRunningPhotoKit ? "执行中..." : "执行 PhotoKit 元数据路径") {
          isRunningPhotoKit = true
          Task {
            let result = await PermissionLabPhotoExperiment.buildPhotoKitResult()
            resultStore.record(result)
            authorization = await broker.authorizationState(for: .photos)
            isRunningPhotoKit = false
          }
        }
        .disabled(isRunningPhotoKit)

        if authorization.substatus.contains("受限") {
          Button("修改受限相册选择范围") {
            presentLimitedLibraryPicker()
          }
        }
      }

      Section("实验目标") {
        Text("本模块用于比较「系统选择器最小权限路径」和「PhotoKit 明确授权路径」，并记录两条路径下到底能暴露哪些相册元数据。")
          .font(.footnote)
      }

      ExperimentLatestResultSection(result: resultStore.latestResults[.photos])
    }
    .task {
      authorization = await broker.authorizationState(for: .photos)
    }
    .sheet(isPresented: $isShowingSystemPicker) {
      PermissionLabSystemPhotoPicker { results in
        Task {
          let result = await PermissionLabPhotoExperiment.buildPickerResult(from: results)
          resultStore.record(result)
          authorization = await broker.authorizationState(for: .photos)
        }
      }
    }
  }

  private var authorizationSection: some View {
    Section("授权状态") {
      PermissionAuthorizationSummaryView(authorization: authorization)
      Button("请求 PhotoKit 授权") {
        Task {
          authorization = await broker.requestAuthorization(for: .photos)
        }
      }
    }
  }

  private func presentLimitedLibraryPicker() {
    guard let windowScene = UIApplication.shared.connectedScenes.first(where: {
      $0.activationState == .foregroundActive
    }) as? UIWindowScene,
      let controller = windowScene.windows.first(where: \.isKeyWindow)?.rootViewController
    else {
      return
    }
    PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
  }
}

@MainActor
private struct LocationExperimentView: View {
  @Environment(PermissionBroker.self) private var broker
  @Environment(PermissionLabResultStore.self) private var resultStore

  @State private var authorization: PermissionAuthorizationState = .unknown
  @State private var coordinator = LocationExperimentCoordinator()
  @State private var liveSamples: [CLLocation] = []
  @State private var isTracking = false

  var body: some View {
    Form {
      Section("授权状态") {
        PermissionAuthorizationSummaryView(authorization: authorization)
        Button("请求「使用期间允许」") {
          Task {
            authorization = await broker.requestAuthorization(for: .location)
          }
        }
        Button("请求「始终允许」") {
          Task {
            authorization = await broker.requestLocationAlwaysAuthorization()
          }
        }
      }

      Section("实验操作") {
        Button("执行单次定位样本") {
          Task {
            let location = await coordinator.requestSingleLocation()
            authorization = coordinator.currentAuthorizationState()
            resultStore.record(
              PermissionLabLocationExperiment.makeSingleLocationResult(
                location: location,
                authorization: authorization
              )
            )
          }
        }

        Button(isTracking ? "停止前台持续定位" : "开始前台持续定位") {
          if isTracking {
            let samples = coordinator.stopContinuousUpdates()
            resultStore.record(
              PermissionLabLocationExperiment.makeContinuousLocationResult(
                locations: samples,
                authorization: authorization
              )
            )
            isTracking = false
          } else {
            liveSamples = []
            coordinator.startContinuousUpdates { samples in
              liveSamples = samples
            }
            isTracking = true
          }
        }
      }

      if !liveSamples.isEmpty {
        Section("前台实时样本") {
          ForEach(Array(liveSamples.enumerated()), id: \.offset) { item in
            let sample = item.element
            Text("\(sample.coordinate.latitude), \(sample.coordinate.longitude) ± \(sample.horizontalAccuracy)m")
              .font(.footnote.monospaced())
          }
        }
      }

      ExperimentLatestResultSection(result: resultStore.latestResults[.location])
    }
    .task {
      authorization = await broker.authorizationState(for: .location)
    }
    .onDisappear {
      if isTracking {
        let samples = coordinator.stopContinuousUpdates()
        resultStore.record(
          PermissionLabLocationExperiment.makeContinuousLocationResult(
            locations: samples,
            authorization: authorization
          )
        )
        isTracking = false
      }
    }
  }
}

@MainActor
private struct ContactsExperimentView: View {
  @Environment(PermissionBroker.self) private var broker
  @Environment(PermissionLabResultStore.self) private var resultStore

  @State private var authorization: PermissionAuthorizationState = .unknown
  @State private var isRunning = false

  var body: some View {
    Form {
      Section("授权状态") {
        PermissionAuthorizationSummaryView(authorization: authorization)
        Button("请求通讯录权限") {
          Task {
            authorization = await broker.requestAuthorization(for: .contacts)
          }
        }
      }

      Section("实验操作") {
        Button(isRunning ? "执行中..." : "读取通讯录字段边界") {
          isRunning = true
          Task {
            let result = await PermissionLabContactsExperiment.run()
            resultStore.record(result)
            authorization = await broker.authorizationState(for: .contacts)
            isRunning = false
          }
        }
        .disabled(isRunning)
      }

      Section("系统边界") {
        Text("本实验不会默认自动读取所有联系人。只有在你点击实验按钮后才会开始枚举。联系人备注字段在本实验中被视为系统限制字段，因此不会主动请求。")
          .font(.footnote)
      }

      ExperimentLatestResultSection(result: resultStore.latestResults[.contacts])
    }
    .task {
      authorization = await broker.authorizationState(for: .contacts)
    }
  }
}

@MainActor
private struct PasteboardExperimentView: View {
  @Environment(PermissionLabResultStore.self) private var resultStore

  var body: some View {
    Form {
      Section("实验路径") {
        Button("程序直接读取探测") {
          Task {
            let result = await PermissionLabPasteboardExperiment.runProgrammaticRead(path: "programmaticRead")
            resultStore.record(result)
          }
        }

        Button("显式按钮读取") {
          Task {
            let result = await PermissionLabPasteboardExperiment.runProgrammaticRead(path: "explicitButtonRead")
            resultStore.record(result)
          }
        }

        PasteButton(supportedContentTypes: [.plainText, .url, .image]) { providers in
          Task {
            let result = await PermissionLabPasteboardExperiment.runPasteButtonResult(providers: providers)
            resultStore.record(result)
          }
        }
      }

      Section("说明") {
        Text("粘贴确认提示由系统控制。本实验记录的是不同路径下最终暴露了什么数据，而不是去绕过系统确认。")
          .font(.footnote)
      }

      ExperimentLatestResultSection(result: resultStore.latestResults[.pasteboard])
    }
  }
}

@MainActor
private struct FilesExperimentView: View {
  @Environment(PermissionLabResultStore.self) private var resultStore

  @State private var isShowingPicker = false

  var body: some View {
    Form {
      Section("实验操作") {
        Button("选择文件并检查元数据") {
          isShowingPicker = true
        }
      }

      Section("系统边界") {
        Text("App 不能大范围枚举整个文件系统，只能获得用户在系统文件选择器中主动选中的 URL。")
          .font(.footnote)
      }

      ExperimentLatestResultSection(result: resultStore.latestResults[.files])
    }
    .sheet(isPresented: $isShowingPicker) {
      PermissionLabDocumentPicker { url in
        Task {
          let result = await PermissionLabFilesExperiment.run(selectedURL: url)
          resultStore.record(result)
        }
      }
    }
  }
}

@MainActor
private struct CameraExperimentView: View {
  @Environment(PermissionBroker.self) private var broker
  @Environment(PermissionLabResultStore.self) private var resultStore

  @State private var authorization: PermissionAuthorizationState = .unknown
  @State private var isShowingCamera = false

  var body: some View {
    Form {
      Section("授权状态") {
        PermissionAuthorizationSummaryView(authorization: authorization)
        Button("请求相机权限") {
          Task {
            authorization = await broker.requestAuthorization(for: .camera)
          }
        }
      }

      Section("实验操作") {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
          Button("拍摄可见照片") {
            isShowingCamera = true
          }
        } else {
          Text("当前设备或模拟器不支持相机，但仍可用于观察授权状态与降级逻辑。")
            .font(.footnote)
        }
      }

      ExperimentLatestResultSection(result: resultStore.latestResults[.camera])
    }
    .task {
      authorization = await broker.authorizationState(for: .camera)
    }
    .sheet(isPresented: $isShowingCamera) {
      PermissionLabCameraCaptureView { info in
        Task {
          let result = await PermissionLabCameraExperiment.run(info: info)
          resultStore.record(result)
        }
      }
    }
  }
}

@MainActor
private struct MicrophoneExperimentView: View {
  @Environment(PermissionBroker.self) private var broker
  @Environment(PermissionLabResultStore.self) private var resultStore

  @State private var authorization: PermissionAuthorizationState = .unknown
  @State private var recorder = PermissionLabMicrophoneRecorder()
  @State private var isRecording = false
  @State private var errorMessage: String?

  var body: some View {
    Form {
      Section("授权状态") {
        PermissionAuthorizationSummaryView(authorization: authorization)
        Button("请求麦克风权限") {
          Task {
            authorization = await broker.requestAuthorization(for: .microphone)
          }
        }
      }

      Section("实验操作") {
        Button(isRecording ? "停止录音并分析" : "开始可见录音") {
          if isRecording {
            recorder.stopRecording()
            Task {
              let result = await recorder.buildResult()
              resultStore.record(result)
              isRecording = false
            }
          } else {
            do {
              try recorder.startRecording()
              isRecording = true
              errorMessage = nil
            } catch {
              errorMessage = error.localizedDescription
            }
          }
        }
      }

      if let errorMessage {
        Section("错误") {
          Text(errorMessage)
            .foregroundStyle(.red)
        }
      }

      ExperimentLatestResultSection(result: resultStore.latestResults[.microphone])
    }
    .task {
      authorization = await broker.authorizationState(for: .microphone)
    }
  }
}

@MainActor
private struct NotificationsExperimentView: View {
  @Environment(PermissionBroker.self) private var broker
  @Environment(PermissionLabResultStore.self) private var resultStore

  @State private var authorization: PermissionAuthorizationState = .unknown
  @State private var isDemoRunning = false

  var body: some View {
    Form {
      Section("授权状态") {
        PermissionAuthorizationSummaryView(authorization: authorization)

        Button("请求通知权限") {
          Task {
            authorization = await broker.requestAuthorization(for: .notifications)
            resultStore.record(makeStatusSnapshotResult(for: .notifications, authorization: authorization, trigger: "请求通知授权"))
          }
        }

        Button("刷新授权快照") {
          Task {
            authorization = await broker.authorizationState(for: .notifications)
            resultStore.record(makeStatusSnapshotResult(for: .notifications, authorization: authorization, trigger: "通知状态刷新"))
          }
        }
      }

      Section("本地通知演示") {
        Text("请求授权后，调度一条 3 秒延时可见本地通知，记录系统允许的行为和边界。")
          .font(.footnote)
          .foregroundStyle(.secondary)

        Button(isDemoRunning ? "执行中..." : "调度本地通知演示") {
          isDemoRunning = true
          Task {
            let result = await PermissionLabNotificationExperiment.scheduleLocalNotification()
            resultStore.record(result)
            authorization = await broker.authorizationState(for: .notifications)
            isDemoRunning = false
          }
        }
        .disabled(isDemoRunning)
      }

      Section("边界说明") {
        Text("本实验不使用 silent push、后台唤醒或任何隐蔽采集路径。通知的展示样式由用户在系统设置中配置，App 无法覆盖。")
          .font(.footnote)
      }

      ExperimentLatestResultSection(result: resultStore.latestResults[.notifications])
    }
    .task {
      authorization = await broker.authorizationState(for: .notifications)
    }
  }
}

@MainActor
private struct EventKitExperimentView: View {
  @Environment(PermissionBroker.self) private var broker
  @Environment(PermissionLabResultStore.self) private var resultStore

  let type: PermissionType
  @State private var authorization: PermissionAuthorizationState = .unknown

  var body: some View {
    Form {
      Section("授权状态") {
        PermissionAuthorizationSummaryView(authorization: authorization)
        Button("请求\(type.title)权限") {
          Task {
            authorization = await broker.requestAuthorization(for: type)
          }
        }
      }

      Section("实验操作") {
        Button("读取\(type.title)字段可见性") {
          Task {
            let result = await PermissionLabEventKitExperiment.run(for: type)
            resultStore.record(result)
            authorization = await broker.authorizationState(for: type)
          }
        }
      }

      ExperimentLatestResultSection(result: resultStore.latestResults[type])
    }
    .task {
      authorization = await broker.authorizationState(for: type)
    }
  }
}

@MainActor
private struct MotionExperimentView: View {
  @Environment(PermissionLabResultStore.self) private var resultStore

  var body: some View {
    Form {
      Section("实验操作") {
        Button("采集运动能力快照") {
          Task {
            let result = await PermissionLabMotionExperiment.run()
            resultStore.record(result)
          }
        }
      }

      ExperimentLatestResultSection(result: resultStore.latestResults[.motion])
    }
  }
}

@MainActor
private struct MediaLibraryExperimentView: View {
  @Environment(PermissionBroker.self) private var broker
  @Environment(PermissionLabResultStore.self) private var resultStore

  @State private var authorization: PermissionAuthorizationState = .unknown

  var body: some View {
    Form {
      Section("授权状态") {
        PermissionAuthorizationSummaryView(authorization: authorization)
        Button("请求媒体资料库权限") {
          Task {
            authorization = await broker.requestAuthorization(for: .mediaLibrary)
          }
        }
      }

      Section("实验操作") {
        Button("读取媒体资料库快照") {
          Task {
            let result = await PermissionLabMediaLibraryExperiment.run()
            resultStore.record(result)
            authorization = await broker.authorizationState(for: .mediaLibrary)
          }
        }
      }

      ExperimentLatestResultSection(result: resultStore.latestResults[.mediaLibrary])
    }
    .task {
      authorization = await broker.authorizationState(for: .mediaLibrary)
    }
  }
}

@MainActor
private struct LocalNetworkExperimentView: View {
  @Environment(PermissionLabResultStore.self) private var resultStore

  @State private var isRunning = false
  @State private var lastRunSummary: String?

  var body: some View {
    Form {
      Section("前提配置") {
        staticConfigRow("NSLocalNetworkUsageDescription",
          present: (Bundle.main.infoDictionary?["NSLocalNetworkUsageDescription"] as? String).map { !$0.isEmpty } ?? false)
        let bonjourServices = Bundle.main.infoDictionary?["NSBonjourServices"] as? [String] ?? []
        staticConfigRow("NSBonjourServices",
          present: !bonjourServices.isEmpty,
          detail: bonjourServices.isEmpty ? "未声明" : bonjourServices.joined(separator: ", "))
      }

      Section("实验操作") {
        Text("点击下方按钮后，系统将触发 Bonjour 发现尝试。首次运行会弹出「允许在本地网络中查找设备」系统提示。")
          .font(.footnote)
          .foregroundStyle(.secondary)

        Button(isRunning ? "发现中（约 4 秒）..." : "触发 Bonjour 发现审计") {
          isRunning = true
          lastRunSummary = nil
          Task {
            let result = await PermissionLabLocalNetworkExperiment.run()
            resultStore.record(result)
            lastRunSummary = result.rawSamplePreview
            isRunning = false
          }
        }
        .disabled(isRunning)
      }

      if let lastRunSummary {
        Section("本次结果摘要") {
          Text(lastRunSummary)
            .font(.footnote.monospaced())
        }
      }

      Section("边界说明") {
        Text("本地网络没有统一公开的授权状态查询 API，以触发结果和错误语义表达边界。")
          .font(.footnote)
        Text("完整验证需要真机且连接真实局域网；模拟器和无网络环境中服务发现结果会为空。")
          .font(.footnote)
        Text("本实验不实现任何后台持续扫描或静默数据上报能力。")
          .font(.footnote)
      }

      ExperimentLatestResultSection(result: resultStore.latestResults[.localNetwork])
    }
  }

  @ViewBuilder
  private func staticConfigRow(_ key: String, present: Bool, detail: String? = nil) -> some View {
    HStack(alignment: .top) {
      Image(systemName: present ? "checkmark.circle.fill" : "xmark.circle.fill")
        .foregroundStyle(present ? .green : .red)
      VStack(alignment: .leading, spacing: 2) {
        Text(key)
          .font(.footnote.monospaced())
        if let detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

private struct PermissionAuthorizationSummaryView: View {
  let authorization: PermissionAuthorizationState

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      LabeledContent("状态") {
        Text(authorization.status)
          .font(.body.monospaced())
      }
      if !authorization.substatus.isEmpty {
        LabeledContent("细分状态") {
          Text(authorization.substatus.joined(separator: ", "))
            .font(.footnote.monospaced())
            .multilineTextAlignment(.trailing)
        }
      }
      if !authorization.notes.isEmpty {
        ForEach(authorization.notes, id: \.self) { note in
          Text(note)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

@MainActor
struct PermissionExperimentResultView: View {
  @Environment(PermissionLabResultStore.self) private var resultStore
  let type: PermissionType

  var body: some View {
    List {
      if let result = resultStore.latestResults[type] {
        Section("授权状态") {
          Text(result.authorizationStatus)
          if !result.authorizationSubstatus.isEmpty {
            Text(result.authorizationSubstatus.joined(separator: ", "))
              .foregroundStyle(.secondary)
          }
          Text("触发动作：\(result.triggerAction)")
            .font(.footnote)
          Text("采集时间：\(result.formattedTimestamp)")
            .font(.footnote)
        }

        Section("可获取字段") {
          if result.fieldsCollected.isEmpty {
            Text("无")
              .foregroundStyle(.secondary)
          } else {
            ForEach(result.fieldsCollected, id: \.self) { field in
              Text(field)
                .font(.footnote.monospaced())
            }
          }
        }

        Section("不可获取字段") {
          if result.fieldsUnavailable.isEmpty {
            Text("未记录")
              .foregroundStyle(.secondary)
          } else {
            ForEach(result.fieldsUnavailable, id: \.self) { field in
              Text(field)
                .font(.footnote.monospaced())
            }
          }
        }

        Section("边界发现") {
          ForEach(result.boundaryFindings, id: \.self) { finding in
            Text(finding)
          }
        }

        Section("样例预览") {
          Text(result.rawSamplePreview)
            .font(.footnote.monospaced())
        }

        Section("风险分析") {
          HStack {
            Text("风险等级")
            Spacer()
            Text(result.privacyRiskLevel.displayName)
              .foregroundStyle(result.privacyRiskLevel.tint)
          }
          Text(result.privacyImpactSummary)
        }

        if !result.notes.isEmpty {
          Section("备注") {
            ForEach(result.notes, id: \.self) { note in
              Text(note)
            }
          }
        }

        // History comparison — show previous result if available
        if let prev = resultStore.previousResult(for: type) {
          Section("与上次结果对比") {
            LabeledContent("上次采集时间") {
              Text(prev.formattedTimestamp)
                .font(.caption.monospaced())
            }
            LabeledContent("授权状态") {
              VStack(alignment: .trailing, spacing: 2) {
                Text(prev.authorizationStatus)
                  .font(.footnote)
                if prev.authorizationStatus != result.authorizationStatus {
                  Text("← 已变更")
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
              }
            }
            LabeledContent("可获取字段数") {
              let delta = result.fieldsCollected.count - prev.fieldsCollected.count
              HStack(spacing: 4) {
                Text("\(prev.fieldsCollected.count) → \(result.fieldsCollected.count)")
                  .font(.footnote)
                if delta != 0 {
                  Text(delta > 0 ? "+\(delta)" : "\(delta)")
                    .font(.caption)
                    .foregroundStyle(delta > 0 ? .orange : .green)
                }
              }
            }
            LabeledContent("风险等级") {
              HStack(spacing: 4) {
                Text(prev.privacyRiskLevel.displayName)
                  .foregroundStyle(prev.privacyRiskLevel.tint)
                if prev.privacyRiskLevel != result.privacyRiskLevel {
                  Text("→ \(result.privacyRiskLevel.displayName)")
                    .foregroundStyle(result.privacyRiskLevel.tint)
                }
              }
              .font(.footnote)
            }
          }
        }

        // Full history list
        let allResults = resultStore.results(for: type)
        if allResults.count > 1 {
          Section("历史记录（\(allResults.count) 次）") {
            ForEach(allResults) { histEntry in
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Text(histEntry.formattedTimestamp)
                    .font(.caption.monospaced())
                  Spacer()
                  Text(histEntry.privacyRiskLevel.displayName)
                    .font(.caption)
                    .foregroundStyle(histEntry.privacyRiskLevel.tint)
                }
                Text(histEntry.authorizationStatus)
                  .font(.footnote)
                  .foregroundStyle(.secondary)
                Text("触发：\(histEntry.triggerAction)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .padding(.vertical, 2)
            }
          }
        }
      } else {
        Section {
          Text("当前还没有 \(type.title) 的实验结果。")
            .foregroundStyle(.secondary)
        }
      }
    }
    .navigationTitle("\(type.title)结果")
    .navigationBarTitleDisplayMode(.inline)
  }
}

@MainActor
struct PermissionExperimentOverviewView: View {
  @Environment(PermissionLabResultStore.self) private var resultStore

  var body: some View {
    List {
      Section("说明") {
        Text("本页汇总每个模块最近一次保存的实验结果，便于快速判断在当前系统配置下，哪些权限暴露的数据价值最高。")
      }

      Section("组合风险") {
        Text(combinedRiskSummary)
      }

      Section("最近结果") {
        ForEach(PermissionType.allCases) { type in
          if let result = resultStore.latestResults[type] {
            NavigationLink(destination: PermissionExperimentResultView(type: type)) {
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Label(type.title, systemImage: type.iconName)
                  Spacer()
                  Text(result.privacyRiskLevel.displayName)
                    .foregroundStyle(result.privacyRiskLevel.tint)
                }
                Text(result.authorizationStatus)
                  .font(.caption.monospaced())
                Text(result.privacyImpactSummary)
                  .font(.footnote)
                  .foregroundStyle(.secondary)
                  .lineLimit(3)
              }
            }
          } else {
            Label(type.title, systemImage: type.iconName)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .navigationTitle("实验总览")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var combinedRiskSummary: String {
    let results = resultStore.latestResults.values
    let hasLocation = results.contains { $0.permissionType == .location && !$0.fieldsCollected.isEmpty }
    let hasPhotos = results.contains { $0.permissionType == .photos && !$0.fieldsCollected.isEmpty }
    let hasContacts = results.contains { $0.permissionType == .contacts && !$0.fieldsCollected.isEmpty }
    let hasCalendar = results.contains { $0.permissionType == .calendar && !$0.fieldsCollected.isEmpty }
    let hasPasteboard = results.contains { $0.permissionType == .pasteboard && !$0.fieldsCollected.isEmpty }

    if hasLocation && hasPhotos && hasContacts {
      return "「定位 + 照片 + 通讯录」是当前实验里最具画像价值的组合。三者组合后，即使单独看每项权限似乎仍有边界，仍可能支撑轨迹分析、社交关系重建与身份关联。"
    }
    if hasLocation && hasCalendar {
      return "「定位 + 日历」可能揭示与会议安排、工作模式和周期性活动相关的行动规律。"
    }
    if hasPasteboard && (hasContacts || hasPhotos) {
      return "剪贴板若与通讯录或照片等更稳定的个人数据组合，可能暴露瞬时口令、链接、草稿和用户意图，并为画像补充上下文。"
    }
    return "建议至少运行两个以上模块再观察组合风险。跨权限组合带来的隐私风险通常高于各权限单独相加。"
  }
}

@MainActor
struct PermissionLabExportView: View {
  @Environment(PermissionLabResultStore.self) private var resultStore

  @State private var jsonURL: URL?
  @State private var summaryURL: URL?
  @State private var llmBundleURL: URL?
  @State private var exportError: String?
  @State private var llmPreview: LLMBundlePreview?

  struct LLMBundlePreview {
    let testedCount: Int
    let untestedCount: Int
    let overallRisk: String
    let insightCount: Int
  }

  var body: some View {
    List {
      Section("常规导出") {
        Text("生成原始 JSON 档案和可读文本摘要，保存在本地 Documents 目录。")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Button("生成本地导出文件") {
          do {
            let export = try resultStore.exportFiles()
            jsonURL = export.jsonURL
            summaryURL = export.summaryURL
            exportError = nil
          } catch {
            exportError = error.localizedDescription
          }
        }
      }

      if let jsonURL, let summaryURL {
        Section("已生成常规文件") {
          VStack(alignment: .leading, spacing: 8) {
            Text(jsonURL.lastPathComponent)
              .font(.caption.monospaced())
            ShareLink(item: jsonURL) {
              Label("分享 JSON 导出", systemImage: "doc.badge.arrow.up")
            }
          }

          VStack(alignment: .leading, spacing: 8) {
            Text(summaryURL.lastPathComponent)
              .font(.caption.monospaced())
            ShareLink(item: summaryURL) {
              Label("分享文本摘要", systemImage: "doc.plaintext")
            }
          }
        }
      }

      // LLM analysis export
      Section("LLM 分析导出") {
        VStack(alignment: .leading, spacing: 6) {
          Text("生成结构化 JSON，供下游大模型分析用户画像风险。")
            .font(.footnote)
          Text("包含：各权限采集字段与数据样本、被系统阻断的字段、跨权限组合洞察、LLM 分析任务 prompt。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)

        Button("生成 LLM 分析包") {
          do {
            let url = try resultStore.exportLLMBundle()
            llmBundleURL = url
            exportError = nil
            // Build preview stats
            let bundle = PermissionLabLLMExportBuilder.makeBundle(from: resultStore.results)
            llmPreview = LLMBundlePreview(
              testedCount: bundle.meta.permissionsTested,
              untestedCount: bundle.meta.permissionsAudited - bundle.meta.permissionsTested,
              overallRisk: bundle.combinedRisk.overallRiskLevel,
              insightCount: bundle.combinedRisk.crossPermissionInsights.count
            )
          } catch {
            exportError = error.localizedDescription
          }
        }
        .disabled(resultStore.results.isEmpty)
      }

      if let llmBundleURL, let preview = llmPreview {
        Section("LLM 分析包已生成") {
          LabeledContent("已测试权限") { Text("\(preview.testedCount) 个") }
          LabeledContent("未测试权限") { Text("\(preview.untestedCount) 个").foregroundStyle(.secondary) }
          LabeledContent("整体风险评级") {
            Text(preview.overallRisk)
              .foregroundStyle(riskColor(preview.overallRisk))
              .fontWeight(.medium)
          }
          LabeledContent("跨权限洞察条数") { Text("\(preview.insightCount) 条") }

          Text(llmBundleURL.lastPathComponent)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)

          ShareLink(item: llmBundleURL) {
            Label("发送到 LLM / 分享 JSON", systemImage: "arrow.up.doc.on.clipboard")
          }

          NavigationLink(destination: LLMBundlePreviewView(store: resultStore)) {
            Label("预览 LLM 分析任务 Prompt", systemImage: "text.magnifyingglass")
          }
        }
      }

      if resultStore.results.isEmpty {
        Section {
          Text("请先运行至少一个权限实验，再生成 LLM 分析包。")
            .foregroundStyle(.secondary)
            .font(.footnote)
        }
      }

      if let exportError {
        Section("错误") {
          Text(exportError)
            .foregroundStyle(.red)
        }
      }
    }
    .navigationTitle("本地导出")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func riskColor(_ level: String) -> Color {
    switch level {
    case "high": .red
    case "medium": .orange
    default: .green
    }
  }
}

@MainActor
struct LLMBundlePreviewView: View {
  let store: PermissionLabResultStore

  @State private var bundle: LLMAnalysisBundle?
  @State private var jsonPreview: String = ""
  @State private var isLoading = false

  var body: some View {
    List {
      if isLoading {
        Section {
          HStack {
            ProgressView()
            Text("正在生成分析包…").foregroundStyle(.secondary)
          }
        }
      } else if let bundle {
        Section("分析任务 · 系统提示词") {
          Text(bundle.analysisTask.systemPrompt)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }

        Section("关注方向") {
          ForEach(bundle.analysisTask.focusAreas, id: \.self) { area in
            Label(area, systemImage: "magnifyingglass")
              .font(.caption)
          }
        }

        Section("跨权限洞察") {
          if bundle.combinedRisk.crossPermissionInsights.isEmpty {
            Text("暂无（需先运行多个权限实验）").foregroundStyle(.secondary)
          } else {
            ForEach(bundle.combinedRisk.crossPermissionInsights, id: \.self) { insight in
              Label(insight, systemImage: "link")
                .font(.caption)
            }
          }
        }

        Section("权限摘要（\(bundle.permissions.count) 项）") {
          ForEach(bundle.permissions, id: \.id) { perm in
            VStack(alignment: .leading, spacing: 2) {
              HStack {
                Text(perm.displayName).font(.subheadline).bold()
                Spacer()
                Text(perm.authorizationStatus)
                  .font(.caption2)
                  .padding(.horizontal, 6).padding(.vertical, 2)
                  .background(riskColor(perm.riskLevel).opacity(0.15))
                  .foregroundStyle(riskColor(perm.riskLevel))
                  .clipShape(Capsule())
              }
              if perm.experimentRun {
                Text("已采集字段：\(perm.collectedFields.count)  已阻断：\(perm.blockedFields.count)")
                  .font(.caption2).foregroundStyle(.secondary)
              }
            }
          }
        }

        Section("JSON 预览（前 500 字符）") {
          Text(jsonPreview)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      } else {
        Section {
          Text("无法生成分析包，请先运行至少一项权限实验。").foregroundStyle(.secondary)
        }
      }
    }
    .navigationTitle("LLM 分析包预览")
    .navigationBarTitleDisplayMode(.inline)
    .task { await generatePreview() }
  }

  private func generatePreview() async {
    isLoading = true
    defer { isLoading = false }
    let b = PermissionLabLLMExportBuilder.makeBundle(from: store.results)
    bundle = b
    if let data = try? JSONEncoder().encode(b),
      let str = String(data: data, encoding: .utf8)
    {
      jsonPreview = String(str.prefix(500)) + (str.count > 500 ? "…" : "")
    }
  }

  private func riskColor(_ level: String) -> Color {
    switch level {
    case "high": .red
    case "medium": .orange
    default: .green
    }
  }
}

struct PermissionLabRiskGuideView: View {
  var body: some View {
    List {
      Section("教学目标") {
        Text("本应用用于权限边界教学与隐私风险分析，核心目的是回答：在 iOS 当前版本下，真正可读的数据有哪些、哪些仍被系统阻断、以及多权限组合后画像能力会增强到什么程度。")
      }

      Section("如何解读结果") {
        Text("授权状态表示系统形式上授予了什么权限；字段列表表示本次实验真正读取到什么；边界发现用于记录 iOS 仍限制了哪些内容。")
        Text("风险分析停留在隐私影响与推断能力层面，不提供绕过系统限制的方法。")
      }

      Section("风险等级") {
        Text("低：可见数据较少，或系统限制较强。")
        Text("中：已经足以支持明显的行为、内容或偏好推断。")
        Text("高：已具备身份、关系、轨迹或日常规律推断能力。")
      }
    }
    .navigationTitle("风险分析说明")
    .navigationBarTitleDisplayMode(.inline)
  }
}

// MARK: - Static compliance audit view

@MainActor
struct PermissionStaticAuditView: View {
  @State private var auditItems: [StaticAuditItem] = []

  var body: some View {
    List {
      Section("说明") {
        Text("静态合规审计检查 Info.plist 中权限相关配置键是否齐全，UIBackgroundModes 声明是否与实际功能一致，以及本地网络所需声明是否具备。")
          .font(.footnote)
        Text("审计结果仅基于 Bundle.main.infoDictionary 的运行时读取，不修改任何配置。")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      let missing = auditItems.filter { $0.status == .missing }
      let inconsistent = auditItems.filter { $0.status == .inconsistent }

      if !missing.isEmpty || !inconsistent.isEmpty {
        Section("需要关注（\(missing.count + inconsistent.count) 项）") {
          ForEach(missing + inconsistent) { item in
            AuditItemRow(item: item)
          }
        }
      }

      Section("全部配置项（\(auditItems.count) 项）") {
        ForEach(auditItems) { item in
          AuditItemRow(item: item)
        }
      }
    }
    .navigationTitle("静态合规审计")
    .navigationBarTitleDisplayMode(.inline)
    .task {
      auditItems = StaticComplianceAuditor.runAudit()
    }
    .refreshable {
      auditItems = StaticComplianceAuditor.runAudit()
    }
  }
}

private struct AuditItemRow: View {
  let item: StaticAuditItem

  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top) {
        Image(systemName: item.status.systemImage)
          .foregroundStyle(item.status.tint)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.configKey)
            .font(.footnote.monospaced())
            .lineLimit(isExpanded ? nil : 1)
          Text(item.status.displayName)
            .font(.caption)
            .foregroundStyle(item.status.tint)
        }
        Spacer()
        Button {
          withAnimation { isExpanded.toggle() }
        } label: {
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }

      if isExpanded {
        VStack(alignment: .leading, spacing: 4) {
          if !item.description.isEmpty && item.description != "（未找到此键）" {
            Text("值：\(item.description)")
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
          Text(item.recommendation)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 24)
      }
    }
    .padding(.vertical, 2)
  }
}

// MARK: - Background capability matrix view

struct PermissionBackgroundMatrixView: View {
  var body: some View {
    List {
      Section("说明") {
        Text("本页列出各权限类型在前台/后台下的可用性、所需系统声明、用户可见指示器和模拟器限制。这是合规边界说明，不涉及任何后台采集实现。")
          .font(.footnote)
      }

      ForEach(BackgroundCapabilityEntry.allEntries) { entry in
        Section(entry.permissionType.title) {
          capabilityRow("前台可用性", value: entry.foregroundAvailability)
          capabilityRow("后台可用性", value: entry.backgroundAvailability)

          if !entry.requiredDeclarations.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              Text("所需声明")
                .font(.caption)
                .foregroundStyle(.secondary)
              ForEach(entry.requiredDeclarations, id: \.self) { decl in
                Text("• \(decl)")
                  .font(.caption.monospaced())
              }
            }
          }

          if !entry.userVisibleIndicators.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              Text("用户可见指示器")
                .font(.caption)
                .foregroundStyle(.secondary)
              ForEach(entry.userVisibleIndicators, id: \.self) { indicator in
                Text("• \(indicator)")
                  .font(.caption)
              }
            }
          }

          if !entry.simulatorLimitations.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              Text("模拟器限制")
                .font(.caption)
                .foregroundStyle(.secondary)
              ForEach(entry.simulatorLimitations, id: \.self) { limitation in
                Text("• \(limitation)")
                  .font(.caption)
                  .foregroundStyle(.orange)
              }
            }
          }
        }
      }
    }
    .navigationTitle("后台能力矩阵")
    .navigationBarTitleDisplayMode(.inline)
  }

  @ViewBuilder
  private func capabilityRow(_ label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.footnote)
    }
  }
}

struct PermissionLabCoverageSuggestionsView: View {
  var body: some View {
    List {
      Section("当前未覆盖但值得补充的权限") {
        Text("蓝牙（Bluetooth）：可研究附近设备发现、蓝牙外设交互与环境指纹风险。")
        Text("语音识别（Speech Recognition）：可研究语音转文本后可暴露的内容维度。")
        Text("面容 ID / 本地认证（LocalAuthentication）：可研究可见能力边界，但不应尝试获取生物特征原始数据。")
        Text("App Tracking Transparency：可研究系统对跨 App 跟踪的限制与授权边界。")
        Text("HealthKit：可研究高敏感健康数据在明确授权下的字段粒度。")
        Text("Nearby Interaction / UWB：可研究近距离空间关系推断能力。")
        Text("NFC：可研究用户显式扫描后可见的标签数据范围。")
      }

      Section("为什么这些值得补充") {
        Text("这些权限或能力要么具有更高敏感度，要么在组合画像中有独特价值，适合在课程报告中作为「后续实验扩展方向」单独说明。")
      }

      Section("建议写入课程报告的结论") {
        Text("当前实验已覆盖相册、定位、通讯录、剪贴板等高价值权限，足以支撑对数据可见范围、系统边界和组合推断风险的主要分析。")
      }
    }
    .navigationTitle("未覆盖权限建议")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private func makeStatusSnapshotResult(
  for type: PermissionType,
  authorization: PermissionAuthorizationState,
  trigger: String,
  findings: [String] = []
) -> PermissionExperimentResult {
  let collected = [
    "授权状态=\(authorization.status)",
    "授权细分=\(authorization.substatus.joined(separator: ", ").nilIfEmpty ?? "无")"
  ]
  let boundaryFindings = findings.isEmpty
    ? ["当前模块主要记录授权状态和系统公开暴露的标志位，而不是原始内容数据。"]
    : findings
  let analysis = PermissionRiskAnalyzer.analyze(
    type: type,
    authorization: authorization,
    fieldsCollected: collected,
    fieldsUnavailable: [],
    boundaryFindings: boundaryFindings
  )

  return .init(
    permissionType: type,
    authorizationStatus: authorization.status,
    authorizationSubstatus: authorization.substatus,
    triggerAction: trigger,
    fieldsCollected: collected,
    fieldsUnavailable: [],
    boundaryFindings: boundaryFindings,
    privacyRiskLevel: analysis.0,
    privacyImpactSummary: analysis.1,
    rawSamplePreview: collected.joined(separator: "\n"),
    notes: authorization.notes
  )
}
