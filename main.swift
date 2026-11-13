import AppKit
import SwiftUI
import Foundation

// Native utility. Privileged operations enter only through the exact CLI action below.
let arguments = Array(CommandLine.arguments.dropFirst())
func writeJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    } catch {
        FileHandle.standardError.write(Data("JSON 编码失败：\(error)\n".utf8))
        exit(1)
    }
}

struct CLIError: Codable {
    let success: Bool
    let message: String
    init(message: String) { self.success = false; self.message = message }
}

if !arguments.isEmpty {
    do {
        switch arguments {
        case ["--inspect"]:
            writeJSON(try ResetEngine.inspect())
        case ["--diagnose"]:
            writeJSON(NetworkDiagnostics.run())
        case ["--repair"]:
            guard geteuid() == 0 else { throw NSError(domain: "NetworkFirstAid", code: 1, userInfo: [NSLocalizedDescriptionKey: "修复网络需要 macOS 管理员授权。"] ) }
            writeJSON(try ResetEngine.reset())
        case ["--self-test"]:
            var results = try ResetEngine.runSelfTests()
            guard shellQuote("a'b c") == "'a'\\''b c'" else { fatalError("shell escaping") }
            guard appleScriptLiteral("a\"b\\c") == "\"a\\\"b\\\\c\"" else { fatalError("AppleScript escaping") }
            results += ["Shell 与 AppleScript 路径转义通过"]
            writeJSON(results)
        default:
            throw NSError(domain: "NetworkFirstAid", code: 2, userInfo: [NSLocalizedDescriptionKey: "不支持的启动参数。"])
        }
        exit(0)
    } catch {
        if arguments == ["--repair"] {
            writeJSON(OperationResult(success: false, message: error.localizedDescription, log: [], warnings: []))
            exit(0)
        }
        writeJSON(CLIError(message: error.localizedDescription))
        exit(1)
    }
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func appleScriptLiteral(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r") + "\""
}

enum RepairPhase { case idle, checking, authorizing, verifying }

@MainActor
final class RepairModel: ObservableObject {
    @Published var status: MachineStatus?
    @Published var connectivity: ConnectivityReport?
    @Published var phase: RepairPhase = .idle
    @Published var headline = "正在检查网络"
    @Published var explanation = "读取 DNS、hosts 与代理设置。"
    @Published var logs: [String] = []
    @Published var lastCheck: Date?
    @Published var hasRepaired = false
    @Published var successful = false
    @Published var errorState = false
    @Published var showDetails = false

    var busy: Bool { phase != .idle }
    var manualDNSCount: Int { status?.services.filter { $0.eligible && $0.hasManualConfiguration }.count ?? 0 }
    var eligibleServices: [DNSServiceStatus] { status?.services.filter { $0.eligible } ?? [] }
    var proxyDescriptions: [String] { status?.activeProxyDescriptions ?? [] }

    func append(_ message: String) {
        let date = DateFormatter(); date.dateFormat = "HH:mm:ss"
        logs.append("\(date.string(from: Date()))  \(message)")
    }

    func refresh() {
        guard !busy else { return }
        phase = .checking
        headline = "正在检查网络"
        explanation = "读取系统配置，并测试公开网站连接。"
        errorState = false
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (MachineStatus?, ConnectivityReport, String?) in
                var machine: MachineStatus?
                var failure: String?
                do { machine = try ResetEngine.inspect() } catch { failure = error.localizedDescription }
                return (machine, NetworkDiagnostics.run(), failure)
            }.value
            status = result.0; connectivity = result.1; lastCheck = Date()
            if let failure = result.2 {
                headline = "配置检查未完成"; explanation = failure; errorState = true
                append("读取配置失败：\(failure)")
            } else {
                successful = result.1.httpsWorks && !result.1.captivePortalSuspected
                headline = successful ? "当前网络可以连接" : "网络连接需要检查"
                explanation = result.1.summary
                append("检查完成：\(result.1.summary)")
            }
            phase = .idle
        }
    }

    func repair() {
        guard !busy else { return }
        phase = .authorizing; hasRepaired = false; successful = false; errorState = false
        headline = "正在申请系统授权"
        explanation = "请在 macOS 授权窗口中验证管理员身份。"
        append("开始一键修复。申请 macOS 管理员授权。")
        Task {
            let response = await Task.detached(priority: .userInitiated) { () -> Result<OperationResult, Error> in
                Result { try Self.runAuthorizedRepair() }
            }.value
            switch response {
            case .success(let result):
                logs += result.log
                logs += result.warnings.map { "提示：\($0)" }
                append(result.message)
                guard result.success else {
                    phase = .idle; headline = "修复未完成"; explanation = result.message
                    errorState = true; showDetails = true
                    return
                }
                phase = .verifying; headline = "正在复查网络"
                explanation = "配置已处理，正在验证 DNS 和 HTTPS 连接。"
                let check = await Task.detached(priority: .userInitiated) { () -> (MachineStatus?, ConnectivityReport) in
                    (try? ResetEngine.inspect(), NetworkDiagnostics.run())
                }.value
                status = check.0; connectivity = check.1; lastCheck = Date()
                hasRepaired = result.warnings.isEmpty
                successful = check.1.httpsWorks && !check.1.captivePortalSuspected
                if !result.warnings.isEmpty {
                    headline = "修复已执行，请查看提示"
                    explanation = result.warnings.joined(separator: "；")
                    errorState = true; showDetails = true
                } else {
                    headline = successful ? "修复完成，网络可连接" : "配置已修复，连接仍需检查"
                    explanation = successful ? "DNS、hosts、系统代理和缓存已处理，公开网站连接测试通过。" : check.1.summary
                }
                append("复查：\(check.1.summary)")
                phase = .idle
            case .failure(let error):
                phase = .idle
                let nsError = error as NSError
                if nsError.code == -128 {
                    headline = "已取消修复"; explanation = "未获得管理员授权，未执行修复。"
                    append("用户取消系统授权。")
                } else {
                    headline = "修复未完成"; explanation = error.localizedDescription
                    append("错误：\(error.localizedDescription)"); errorState = true; showDetails = true
                }
            }
        }
    }

    nonisolated static func runAuthorizedRepair() throws -> OperationResult {
        guard let executable = Bundle.main.executableURL?.path else {
            throw NSError(domain: "NetworkFirstAid", code: 3, userInfo: [NSLocalizedDescriptionKey: "找不到应用执行文件。请重新解压应用。"])
        }
        let command = shellQuote(executable) + " --repair"
        let script = "do shell script " + appleScriptLiteral(command) + " with administrator privileges without altering line endings"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out; process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: errors, encoding: .utf8) ?? "系统授权或修复失败。"
            if message.contains("(-128)") || message.contains("User canceled") {
                throw NSError(domain: "NetworkFirstAid", code: -128, userInfo: [NSLocalizedDescriptionKey: "已取消授权"])
            }
            throw NSError(domain: "NetworkFirstAid", code: 4, userInfo: [NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        if let result = try? JSONDecoder().decode(OperationResult.self, from: data) { return result }
        if let error = try? JSONDecoder().decode(CLIError.self, from: data) {
            throw NSError(domain: "NetworkFirstAid", code: 5, userInfo: [NSLocalizedDescriptionKey: error.message])
        }
        throw NSError(domain: "NetworkFirstAid", code: 6, userInfo: [NSLocalizedDescriptionKey: "修复进程没有返回有效结果。请打开日志查看。"])
    }
}

struct SettingRow: View {
    let icon: String
    let title: String
    let description: String
    let value: String
    var attention = false
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(description).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(value).font(.system(size: 12, weight: .medium))
                .foregroundStyle(attention ? Color.orange : Color.secondary)
                .multilineTextAlignment(.trailing).frame(maxWidth: 190, alignment: .trailing)
        }.padding(.horizontal, 17).padding(.vertical, 14)
    }
}

struct AuthorLogo: View {
    var size: CGFloat = 24
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle().fill(Color.primary.opacity(0.85))
            Image(systemName: "figure.roll")
                .font(.system(size: size * 0.62, weight: .medium))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .frame(width: size, height: size)
            Image(systemName: "bolt.fill")
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundStyle(Color.yellow)
                .padding(size * 0.03)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct AuthorAccount: Identifiable {
    let platform: String
    let name: String
    let handle: String
    var id: String { platform }
    static let all = [
        AuthorAccount(platform: "抖音", name: "电动轮椅", handle: "@aigclunyi"),
        AuthorAccount(platform: "小红书", name: "电动轮椅", handle: "@aigclunyi"),
        AuthorAccount(platform: "X", name: "AIGC电动轮椅", handle: "@cheese069696")
    ]
}

struct AuthorPopover: View {
    @State private var copiedPlatform: String?

    @ViewBuilder private func platformMark(_ platform: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(platform == "小红书" ? Color(red: 0.88, green: 0.13, blue: 0.24) : Color(white: 0.12))
            if platform == "抖音" {
                Image(systemName: "music.note").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
            } else {
                Text(platform).font(.system(size: platform == "X" ? 20 : 9, weight: .bold)).foregroundStyle(.white)
            }
        }.frame(width: 34, height: 34).accessibilityHidden(true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 10) {
                AuthorLogo(size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text("电动轮椅").font(.system(size: 15, weight: .semibold))
                    Text("作者与社交账号").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            ForEach(AuthorAccount.all) { account in
                HStack(spacing: 11) {
                    platformMark(account.platform)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(account.platform).font(.system(size: 11, weight: .semibold))
                            Text(account.name).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text(account.handle).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                    Spacer(minLength: 5)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(account.handle, forType: .string)
                        copiedPlatform = account.platform
                    } label: {
                        Image(systemName: copiedPlatform == account.platform ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12)).frame(width: 22, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help(copiedPlatform == account.platform ? "已复制 \(account.handle)" : "复制 \(account.platform)账号")
                    .accessibilityLabel("复制\(account.platform)账号 \(account.handle)")
                }
            }
            Text(copiedPlatform.map { "已复制\($0)账号，可在对应平台搜索。" } ?? "复制账号后，可在对应平台搜索。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .accessibilityLabel(copiedPlatform.map { "已复制\($0)账号" } ?? "可复制社交账号")
        }.padding(20).frame(width: 330)
    }
}

struct MainView: View {
    @ObservedObject var model: RepairModel
    @State private var showAuthor = false
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: "network")
                            .font(.system(size: 30, weight: .regular)).foregroundStyle(Color.accentColor)
                            .frame(width: 54, height: 54)
                            .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("网络修复").font(.system(size: 24, weight: .semibold))
                            Text("VPN 使用后的网络问题，一键检查与修复。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    HStack(alignment: .top, spacing: 11) {
                        if model.busy {
                            ProgressView().controlSize(.small).padding(.top, 3)
                        } else {
                            Image(systemName: model.errorState ? "exclamationmark.circle.fill" : model.successful ? "checkmark.circle.fill" : "exclamationmark.circle")
                                .font(.system(size: 20))
                                .foregroundStyle(model.errorState ? Color.orange : model.successful ? Color.green : Color.orange)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.headline).font(.system(size: 14, weight: .semibold))
                            Text(model.explanation).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        Spacer(minLength: 0)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("检查与修复项目").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            Spacer()
                            if let time = model.lastCheck {
                                Text(time, style: .time).font(.system(size: 11)).foregroundStyle(.tertiary)
                            }
                        }
                        VStack(spacing: 0) {
                            SettingRow(icon: "server.rack", title: "DNS 与搜索域", description: "恢复自动获取", value: model.status == nil ? "读取中…" : model.manualDNSCount == 0 ? "自动获取" : "\(model.manualDNSCount) 个服务有手动设置", attention: model.manualDNSCount > 0)
                            Divider().padding(.leading, 58)
                            SettingRow(icon: "doc.text", title: "hosts 文件", description: "恢复 macOS 默认映射", value: model.status == nil ? "读取中…" : model.status!.hostsIsDefault ? "默认内容" : "存在自定义映射", attention: model.status?.hostsIsDefault == false)
                            Divider().padding(.leading, 58)
                            SettingRow(icon: "arrow.triangle.branch", title: "系统代理", description: "关闭 HTTP、HTTPS、SOCKS 与自动代理", value: model.status == nil ? "读取中…" : model.proxyDescriptions.isEmpty ? "未启用" : "\(model.proxyDescriptions.count) 个服务启用", attention: !model.proxyDescriptions.isEmpty)
                            Divider().padding(.leading, 58)
                            SettingRow(icon: "arrow.clockwise", title: "DNS 缓存", description: "清理旧记录，重新加载解析服务", value: model.hasRepaired ? "已刷新" : "修复时刷新")
                        }
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary).padding(.top, 1)
                        Text("请先断开 VPN 或退出代理软件，避免修复后被重新接管。修复会移除自定义 hosts，并关闭当前网络位置的普通服务代理。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    DisclosureGroup(isExpanded: $model.showDetails) {
                        VStack(alignment: .leading, spacing: 12) {
                            if let status = model.status {
                                Text("当前生效 DNS：\(status.effectiveDNSServers.isEmpty ? "未发现" : status.effectiveDNSServers.joined(separator: "、"))")
                                Text("检查服务：\(model.eligibleServices.map(\.name).joined(separator: "、"))")
                                if !model.proxyDescriptions.isEmpty { Text("已启用代理：\(model.proxyDescriptions.joined(separator: "；"))") }
                                if !status.vpnIndicators.isEmpty { Text("隧道提示：\(status.vpnIndicators.joined(separator: "；"))") }
                                if !status.resolverFiles.isEmpty { Text("发现额外域名解析配置：\(status.resolverFiles.joined(separator: "、"))。此工具不删除这些配置。") }
                            }
                            if let check = model.connectivity {
                                ForEach(Array(check.details.enumerated()), id: \.offset) { item in Text(item.element) }
                            }
                            if !model.logs.isEmpty {
                                Divider()
                                Text(model.logs.joined(separator: "\n")).font(.system(size: 11, design: .monospaced))
                            }
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                    } label: {
                        Text("诊断详情与日志").font(.system(size: 12))
                    }.tint(.secondary)
                }.padding(28)
            }
            Divider()
            HStack(spacing: 12) {
                Button(action: model.refresh) { Label("重新检查", systemImage: "arrow.clockwise") }
                    .disabled(model.busy).keyboardShortcut("r", modifiers: .command)
                Button { showAuthor.toggle() } label: {
                    HStack(spacing: 6) {
                        AuthorLogo()
                        Text("电动轮椅").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .help("作者与社交账号：抖音、小红书、X")
                .accessibilityLabel("电动轮椅，作者与社交账号")
                .popover(isPresented: $showAuthor, arrowEdge: .bottom) { AuthorPopover() }
                Spacer()
                if model.busy {
                    Text(model.phase == .authorizing ? "等待授权或正在修复…" : model.phase == .verifying ? "复查连接…" : "检查中…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("修复需要管理员授权").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button(action: model.repair) {
                    Text("修复网络").frame(minWidth: 94)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.busy || model.status == nil)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .help("自动清理 DNS、hosts、系统代理与 DNS 缓存，并复查网络")
            }.padding(.horizontal, 28).padding(.vertical, 18)
        }.frame(minWidth: 620, minHeight: 675)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.refresh() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var model: RepairModel!
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = RepairModel()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "网络修复"
        window.minSize = NSSize(width: 620, height: 710)
        window.contentView = NSHostingView(rootView: MainView(model: model))
        window.delegate = self
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.busy == true {
            let alert = NSAlert()
            alert.messageText = "网络操作正在进行"
            alert.informativeText = "请等待检查或修复结束。系统授权窗口可以点击取消。"
            alert.addButton(withTitle: "继续等待")
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { _ = applicationShouldTerminate(NSApp); return false }
        return true
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil); return true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let menu = NSMenu()
let applicationMenuItem = NSMenuItem()
let appMenu = NSMenu()
appMenu.addItem(withTitle: "关于网络修复", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "隐藏网络修复", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "退出网络修复", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
applicationMenuItem.submenu = appMenu; menu.addItem(applicationMenuItem)
let editItem = NSMenuItem(); let editMenu = NSMenu(title: "编辑")
editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu; menu.addItem(editItem)
app.mainMenu = menu
let delegate = AppDelegate()
app.delegate = delegate
app.run()
