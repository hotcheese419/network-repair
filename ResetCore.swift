import Foundation
import SystemConfiguration
import Darwin

struct DNSServiceStatus: Codable {
    let id: String
    let name: String
    let interfaceType: String
    let servers: [String]
    let searchDomains: [String]
    let eligible: Bool
    let hasManualConfiguration: Bool
}

struct MachineStatus: Codable {
    let hostsIsDefault: Bool
    let hostsExtraEntries: [String]
    let services: [DNSServiceStatus]
    let effectiveDNSServers: [String]
    let vpnIndicators: [String]
    let resolverFiles: [String]
    let activeProxyDescriptions: [String]
}

struct OperationResult: Codable {
    let success: Bool
    let message: String
    let log: [String]
    let warnings: [String]
}

enum ResetError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case let .failed(message) = self { return message }; return nil }
}

enum ResetEngine {
    static let defaultHosts = """
    ##
    # Host Database
    #
    # localhost is used to configure the loopback interface
    # when the system is booting.  Do not change this entry.
    ##
    127.0.0.1\tlocalhost
    255.255.255.255\tbroadcasthost
    ::1             localhost

    """
    private static let hostsPath = "/private/etc/hosts"
    private static let backupVersion = 1

    private struct ServiceSnapshot: Codable {
        let id: String
        let name: String
        let configuration: Data?
        let enabled: Bool
        let proxiesConfiguration: Data?
        let proxiesEnabled: Bool
    }
    private struct Snapshot: Codable {
        let version: Int
        let id: String
        let date: String
        let kind: String
        let locationID: String
        let hosts: Data
        let hostsMode: UInt16
        let hostsUID: UInt32
        let hostsGID: UInt32
        let services: [ServiceSnapshot]
    }
    private static let proxyEnableKeys = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "FTPEnable", "RTSPEnable", "GopherEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"]

    static func inspect() throws -> MachineStatus {
        let prefs = try preferences()
        let services = try currentServices(prefs)
        let hosts = try readRegularFile(hostsPath, rootOnly: false)
        let extra = extraHostsEntries(hosts)
        let values = services.map { service -> DNSServiceStatus in
            let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS)
            let config = proto.flatMap { SCNetworkProtocolGetConfiguration($0) as? [String: Any] } ?? [:]
            return DNSServiceStatus(id: serviceID(service), name: serviceName(service),
                                    interfaceType: interfaceTypes(service).joined(separator: " / "),
                                    servers: config[kSCPropNetDNSServerAddresses as String] as? [String] ?? [],
                                    searchDomains: config[kSCPropNetDNSSearchDomains as String] as? [String] ?? [],
                                    eligible: isEligible(service), hasManualConfiguration: !config.filter { $0.key != "__INACTIVE__" }.isEmpty)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let dnsOutput = (try? run("/usr/sbin/scutil", ["--dns"])) ?? ""
        var dns: [String] = []
        for line in dnsOutput.split(separator: "\n") where line.contains("nameserver[") {
            if let range = line.range(of: ": ") {
                let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !dns.contains(value) { dns.append(value) }
            }
        }
        let ifOutput = (try? run("/sbin/ifconfig", ["-l"])) ?? ""
        let tunnels = ifOutput.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.hasPrefix("utun") || $0.hasPrefix("ppp") || $0.hasPrefix("ipsec") }
        let vpnList = (try? run("/usr/sbin/scutil", ["--nc", "list"])) ?? ""
        let connected = vpnList.split(separator: "\n").filter { $0.contains("(Connected)") }.map { String($0).trimmingCharacters(in: .whitespaces) }
        let activeProxies = services.filter(isEligible).compactMap { service -> String? in
            guard let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies), SCNetworkProtocolGetEnabled(proto) else { return nil }
            let config = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
            let enabled = enabledProxyKeys(config)
            return enabled.isEmpty ? nil : serviceName(service) + "：" + enabled.map(proxyDisplayName).joined(separator: "、")
        }
        let resolverFiles = (try? FileManager.default.contentsOfDirectory(atPath: "/private/etc/resolver"))?.filter { !$0.hasPrefix(".") }.sorted() ?? []
        return MachineStatus(hostsIsDefault: hostsSemanticallyDefault(hosts), hostsExtraEntries: extra,
                             services: values, effectiveDNSServers: dns,
                             vpnIndicators: connected + tunnels, resolverFiles: resolverFiles,
                             activeProxyDescriptions: activeProxies)
    }

    static func reset() throws -> OperationResult {
        try requireRoot()
        return try withOperationLock {
            let prefs = try preferences()
            guard SCPreferencesLock(prefs, false) else { throw failure("网络设置正被其他程序修改，请稍后重试") }
            defer { SCPreferencesUnlock(prefs) }
            let services = try currentServices(prefs).filter(isEligible)
            guard !services.isEmpty else { throw ResetError.failed("当前网络位置没有可修复的普通网络服务。") }
            let before = try snapshot(prefs, services: services, kind: "repair")
            var log = ["已在内存中保存本次操作的回滚快照。"]
            let transaction = performTransaction(stageNetwork: {
                for service in services {
                    if let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) {
                        guard SCNetworkProtocolSetConfiguration(proto, nil) else { throw failure("无法清除 \(serviceName(service)) 的手动 DNS") }
                    }
                    if let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
                       let config = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] {
                        guard SCNetworkProtocolSetConfiguration(proto, disabledProxyConfiguration(config) as CFDictionary) else { throw failure("无法关闭 \(serviceName(service)) 的系统代理") }
                    }
                }
            }, writeHosts: {
                try writeHosts(Data(defaultHosts.utf8), mode: 0o644, uid: 0, gid: 0)
            }, commitNetwork: {
                guard SCPreferencesCommitChanges(prefs) else { throw failure("无法保存网络修复设置") }
            }, applyNetwork: {
                guard SCPreferencesApplyChanges(prefs) else { throw failure("网络设置已保存，但应用失败") }
            }, verify: {
                let persistedPrefs = try preferences()
                guard currentLocationID(persistedPrefs) == before.locationID else { throw ResetError.failed("操作期间网络位置发生变化，验证已停止。") }
                let persisted = try currentServices(persistedPrefs)
                let ids = Set(services.map(serviceID))
                let selected = persisted.filter { ids.contains(serviceID($0)) }
                guard selected.count == services.count else { throw ResetError.failed("操作期间网络服务发生变化，验证已停止。") }
                try verifyNetworkRepair(selected)
                guard hostsSemanticallyDefault(try readRegularFile(hostsPath, rootOnly: true)) else { throw ResetError.failed("hosts 写入后验证失败。") }
            }, rollbackHosts: {
                try writeHosts(before.hosts, mode: before.hostsMode, uid: before.hostsUID, gid: before.hostsGID)
                guard try readRegularFile(hostsPath, rootOnly: true) == before.hosts else { throw ResetError.failed("hosts 回滚后验证失败。") }
            }, rollbackNetwork: {
                try applySnapshot(before, services: services)
                guard SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else { throw failure("网络设置回滚应用失败") }
                try verifyPersistedSnapshot(before)
            })
            if let error = transaction.error {
                log.append(transaction.rollbackErrors.isEmpty ? "操作失败，已回滚已修改的配置。" : "操作失败，部分配置未能回滚；请在系统设置中检查 DNS 与代理。")
                let cacheWarnings = flushCaches(log: &log)
                return OperationResult(success: false, message: error.localizedDescription, log: log,
                                       warnings: transaction.rollbackErrors + cacheWarnings)
            }
            log += ["hosts 已恢复 macOS 默认内容。", "当前网络位置的 \(services.count) 个普通网络服务 DNS、搜索域已恢复自动。", "已关闭这些网络服务的手动代理、PAC 自动代理及自动代理发现。"]
            var warnings = flushCaches(log: &log)
            warnings += inspectWarnings()
            return OperationResult(success: true, message: "网络修复已完成", log: log, warnings: warnings)
        }
    }

    private static func enabledProxyKeys(_ config: [String: Any]) -> [String] {
        proxyEnableKeys.filter { (config[$0] as? NSNumber)?.boolValue == true }
    }
    private static func disabledProxyConfiguration(_ config: [String: Any]) -> [String: Any] {
        var result = config
        // Preserve server addresses, ports, bypass lists and PAC URLs; change only the switches already present.
        for key in proxyEnableKeys where result[key] != nil { result[key] = 0 }
        return result
    }
    private static func proxyDisplayName(_ key: String) -> String {
        ["HTTPEnable": "HTTP", "HTTPSEnable": "HTTPS", "SOCKSEnable": "SOCKS", "FTPEnable": "FTP", "RTSPEnable": "RTSP", "GopherEnable": "Gopher", "ProxyAutoConfigEnable": "PAC", "ProxyAutoDiscoveryEnable": "自动发现"][key] ?? key
    }

    private static func requireRoot() throws {
        guard geteuid() == 0 else { throw ResetError.failed("修改系统设置需要 macOS 管理员授权。") }
    }
    private static func preferences() throws -> SCPreferences {
        guard let prefs = SCPreferencesCreate(nil, "DNSReset" as CFString, nil) else { throw failure("无法读取系统网络设置") }
        return prefs
    }
    private static func currentLocationID(_ prefs: SCPreferences) -> String {
        guard let set = SCNetworkSetCopyCurrent(prefs), let id = SCNetworkSetGetSetID(set) else { return "" }
        return id as String
    }
    private static func currentServices(_ prefs: SCPreferences) throws -> [SCNetworkService] {
        guard let set = SCNetworkSetCopyCurrent(prefs), let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else { throw ResetError.failed("无法读取当前网络位置。") }
        guard services.allSatisfy({ !serviceID($0).isEmpty }) else { throw ResetError.failed("网络服务标识缺失，已停止操作。") }
        return services
    }
    private static func serviceID(_ service: SCNetworkService) -> String { (SCNetworkServiceGetServiceID(service) as String?) ?? "" }
    private static func serviceName(_ service: SCNetworkService) -> String { (SCNetworkServiceGetName(service) as String?) ?? serviceID(service) }
    private static func interfaceTypes(_ service: SCNetworkService) -> [String] {
        var types: [String] = []
        var current = SCNetworkServiceGetInterface(service)
        while let interface = current {
            if let type = SCNetworkInterfaceGetInterfaceType(interface) { types.append(type as String) }
            current = SCNetworkInterfaceGetInterface(interface)
        }
        return types
    }
    private static func eligibleTypes(_ types: [String]) -> Bool {
        let ordinary: Set<String> = ["Ethernet", "IEEE80211", "Bridge", "Bond", "VLAN", "FireWire", "Bluetooth", "WWAN"]
        let excluded: Set<String> = ["PPP", "IPSec", "L2TP", "PPTP", "VPN", "6to4"]
        return !types.isEmpty && types.allSatisfy { !excluded.contains($0) } && types.contains { ordinary.contains($0) }
    }
    private static func isEligible(_ service: SCNetworkService) -> Bool { eligibleTypes(interfaceTypes(service)) }
    private static func failure(_ message: String) -> ResetError { .failed("\(message)（\(String(cString: SCErrorString(SCError())))）。") }

    private static func snapshot(_ prefs: SCPreferences, services: [SCNetworkService], kind: String) throws -> Snapshot {
        let info = try fileInfo(hostsPath, directory: false, rootOnly: true)
        let hosts = try readRegularFile(hostsPath, rootOnly: true)
        let data = try services.map { service -> ServiceSnapshot in
            let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS)
            let config: Data?
            if let proto, let dictionary = SCNetworkProtocolGetConfiguration(proto) {
                config = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
            } else { config = nil }
            let proxies = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
            let proxiesConfig: Data?
            if let proxies, let dictionary = SCNetworkProtocolGetConfiguration(proxies) {
                proxiesConfig = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
            } else { proxiesConfig = nil }
            return ServiceSnapshot(id: serviceID(service), name: serviceName(service), configuration: config, enabled: proto.map(SCNetworkProtocolGetEnabled) ?? true,
                                   proxiesConfiguration: proxiesConfig, proxiesEnabled: proxies.map(SCNetworkProtocolGetEnabled) ?? true)
        }
        return Snapshot(version: backupVersion, id: UUID().uuidString, date: ISO8601DateFormatter().string(from: Date()), kind: kind,
                        locationID: currentLocationID(prefs), hosts: hosts,
                        hostsMode: UInt16(info.st_mode & 0o777), hostsUID: info.st_uid, hostsGID: info.st_gid, services: data)
    }
    private static func applySnapshot(_ snapshot: Snapshot, services: [SCNetworkService]) throws {
        for saved in snapshot.services {
            guard let service = services.first(where: { serviceID($0) == saved.id }) else { throw ResetError.failed("回滚时无法找到 \(saved.name)。") }
            for (type, bytes, enabled) in [(kSCNetworkProtocolTypeDNS, saved.configuration, saved.enabled), (kSCNetworkProtocolTypeProxies, saved.proxiesConfiguration, saved.proxiesEnabled)] {
                guard let proto = SCNetworkServiceCopyProtocol(service, type) else {
                    if bytes != nil { throw ResetError.failed("回滚时无法找到 \(saved.name) 的协议配置。") }
                    continue
                }
                var config: CFDictionary?
                if let bytes {
                    guard let dictionary = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any] else { throw ResetError.failed("回滚快照数据格式不正确。") }
                    config = dictionary as CFDictionary
                }
                guard SCNetworkProtocolSetConfiguration(proto, config), SCNetworkProtocolSetEnabled(proto, enabled) else { throw failure("无法回滚 \(saved.name)") }
            }
        }
    }
    private static func verifyNetworkRepair(_ services: [SCNetworkService]) throws {
        for service in services {
            if let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) {
                let dictionary = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
                guard dictionary.filter({ $0.key != "__INACTIVE__" }).isEmpty else { throw ResetError.failed("\(serviceName(service)) 的 DNS 自动配置验证失败。") }
            }
            if let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) {
                let dictionary = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
                guard enabledProxyKeys(dictionary).isEmpty else { throw ResetError.failed("\(serviceName(service)) 的代理关闭验证失败。") }
            }
        }
    }
    private struct TransactionOutcome {
        let error: Error?
        let rollbackErrors: [String]
    }
    // The production operation and isolated failure-injection tests share this transaction coordinator.
    private static func performTransaction(stageNetwork: () throws -> Void, writeHosts: () throws -> Void,
                                           commitNetwork: () throws -> Void, applyNetwork: () throws -> Void,
                                           verify: () throws -> Void, rollbackHosts: () throws -> Void,
                                           rollbackNetwork: () throws -> Void) -> TransactionOutcome {
        var hostsWritten = false
        var commitAttempted = false
        do {
            try stageNetwork()
            try writeHosts()
            hostsWritten = true
            commitAttempted = true // A failed commit may have partially persisted; attempt rollback either way.
            try commitNetwork()
            try applyNetwork()
            try verify()
            return TransactionOutcome(error: nil, rollbackErrors: [])
        } catch {
            var failures: [String] = []
            if hostsWritten {
                do { try rollbackHosts() } catch { failures.append("hosts 回滚失败：\(error.localizedDescription)") }
            }
            if commitAttempted {
                do { try rollbackNetwork() } catch { failures.append("网络设置回滚失败：\(error.localizedDescription)") }
            }
            return TransactionOutcome(error: error, rollbackErrors: failures)
        }
    }
    private static func verifyPersistedSnapshot(_ snapshot: Snapshot) throws {
        let fresh = try preferences()
        guard currentLocationID(fresh) == snapshot.locationID else { throw ResetError.failed("回滚验证时网络位置已改变。") }
        let services = try currentServices(fresh)
        for saved in snapshot.services {
            guard let service = services.first(where: { serviceID($0) == saved.id }) else { throw ResetError.failed("回滚验证时网络服务已改变。") }
            for (type, bytes, enabled) in [(kSCNetworkProtocolTypeDNS, saved.configuration, saved.enabled), (kSCNetworkProtocolTypeProxies, saved.proxiesConfiguration, saved.proxiesEnabled)] {
                let proto = SCNetworkServiceCopyProtocol(service, type)
                let actual = proto.flatMap { SCNetworkProtocolGetConfiguration($0) as? [String: Any] } ?? [:]
                let expected = try bytes.map { try PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any] ?? [:] } ?? [:]
                guard NSDictionary(dictionary: actual).isEqual(to: expected), (proto.map(SCNetworkProtocolGetEnabled) ?? true) == enabled else { throw ResetError.failed("\(saved.name) 回滚后配置验证失败。") }
            }
        }
    }
    private static func withOperationLock<T>(_ body: () throws -> T) throws -> T {
        let path = "/private/var/run/local.dnsreset.operation.lock"
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ResetError.failed("无法获取操作锁。") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_mode & 0o022 == 0 else { throw ResetError.failed("操作锁权限异常，已停止。") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ResetError.failed("另一个网络修复操作正在进行，请稍后重试。") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private static func fileInfo(_ path: String, directory: Bool, rootOnly: Bool) throws -> stat {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG), directory || info.st_nlink == 1 else { throw ResetError.failed("文件不存在或不是安全的普通\(directory ? "目录" : "文件")：\(path)。") }
        if rootOnly && (info.st_uid != 0 || info.st_mode & 0o022 != 0) { throw ResetError.failed("文件所有者或权限异常：\(path)。") }
        return info
    }
    private static func readRegularFile(_ path: String, rootOnly: Bool) throws -> Data {
        _ = try fileInfo(path, directory: false, rootOnly: rootOnly)
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ResetError.failed("无法读取文件：\(path)。") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size <= 16_777_216,
              !rootOnly || (info.st_uid == 0 && info.st_mode & 0o022 == 0) else { throw ResetError.failed("文件校验失败：\(path)。") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw ResetError.failed("读取文件失败：\(path)。") }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 16_777_216 else { throw ResetError.failed("文件超过安全大小限制。") }
        }
        return data
    }
    private static func atomicWrite(_ data: Data, path: String, mode: mode_t, uid: uid_t, gid: gid_t) throws {
        let directory = (path as NSString).deletingLastPathComponent
        _ = try fileInfo(directory, directory: true, rootOnly: true)
        var oldInfo = stat()
        if lstat(path, &oldInfo) == 0 { _ = try fileInfo(path, directory: false, rootOnly: true) }
        else if errno != ENOENT { throw ResetError.failed("无法检查目标文件：\(path)。") }
        let temporary = directory + "/.dnsreset-" + UUID().uuidString
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ResetError.failed("无法创建原子写入文件：\(path)。") }
        var renamed = false
        defer { close(fd); if !renamed { unlink(temporary) } }
        try data.withUnsafeBytes { raw in
            var position = 0
            while position < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: position), raw.count - position)
                if count < 0 { if errno == EINTR { continue }; throw ResetError.failed("写入文件失败：\(path)。") }
                guard count > 0 else { throw ResetError.failed("文件写入中断。") }
                position += count
            }
        }
        guard fchown(fd, uid, gid) == 0, fchmod(fd, mode) == 0, fsync(fd) == 0 else { throw ResetError.failed("无法保存文件或权限：\(path)。") }
        guard rename(temporary, path) == 0 else { throw ResetError.failed("无法替换文件：\(path)。") }
        renamed = true
        let directoryFD = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if directoryFD >= 0 { _ = fsync(directoryFD); close(directoryFD) }
    }
    private static func writeHosts(_ data: Data, mode: UInt16, uid: UInt32, gid: UInt32) throws {
        _ = try fileInfo(hostsPath, directory: false, rootOnly: true)
        try atomicWrite(data, path: hostsPath, mode: mode_t(mode), uid: uid, gid: gid)
    }

    private static func activeHostLines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let tokens = content.split(whereSeparator: { $0.isWhitespace })
            return tokens.isEmpty ? nil : tokens.joined(separator: " ")
        }
    }
    private static func hostsSemanticallyDefault(_ data: Data) -> Bool {
        let actual = activeHostLines(data)
        let expected = activeHostLines(Data(defaultHosts.utf8))
        return actual.count == expected.count && Set(actual) == Set(expected)
    }
    private static func extraHostsEntries(_ data: Data) -> [String] {
        let defaults = Set(activeHostLines(Data(defaultHosts.utf8)))
        return activeHostLines(data).filter { !defaults.contains($0) }
    }
    private final class DeadlineState: @unchecked Sendable {
        private let lock = NSLock()
        private var expired = false
        func markExpired() { lock.lock(); expired = true; lock.unlock() }
        func wasExpired() -> Bool { lock.lock(); defer { lock.unlock() }; return expired }
    }
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"]
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let deadline = DeadlineState()
        let timeout = DispatchWorkItem {
            guard task.isRunning else { return }
            deadline.markExpired()
            task.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if task.isRunning { _ = Darwin.kill(task.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12, execute: timeout)
        defer { timeout.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard !deadline.wasExpired() else { throw ResetError.failed("\((executable as NSString).lastPathComponent) 执行超时，请稍后重试。") }
        let output = String(decoding: data, as: UTF8.self)
        guard task.terminationStatus == 0 else { throw ResetError.failed("\((executable as NSString).lastPathComponent) 执行失败：\(output.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return output
    }
    private static func flushCaches(log: inout [String]) -> [String] {
        var warnings: [String] = []
        do { _ = try run("/usr/bin/dscacheutil", ["-flushcache"]); log.append("已刷新目录服务 DNS 缓存。") }
        catch { warnings.append("DNS 缓存刷新失败：\(error.localizedDescription)") }
        do { _ = try run("/usr/bin/killall", ["-HUP", "mDNSResponder"]); log.append("已通知 mDNSResponder 重新加载。") }
        catch { warnings.append("mDNSResponder 刷新失败：\(error.localizedDescription)") }
        return warnings
    }
    private static func inspectWarnings() -> [String] {
        guard let status = try? inspect() else { return ["修改已完成，但无法读取实时 DNS 状态。"] }
        var warnings: [String] = []
        if !status.vpnIndicators.isEmpty { warnings.append("检测到隧道接口或已连接的 VPN；VPN、代理或网络扩展仍可能接管 DNS。建议断开后再检查。") }
        if !status.resolverFiles.isEmpty { warnings.append("/etc/resolver 存在额外域名解析规则，本工具保留了这些文件。") }
        return warnings
    }

    static func runSelfTests() throws -> [String] {
        func check(_ result: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try result() else { throw ResetError.failed("自检失败：\(message)") }
        }
        var passed: [String] = []
        try check(hostsSemanticallyDefault(Data(defaultHosts.utf8)), "默认 hosts")
        try check(hostsSemanticallyDefault(Data(("# test\n" + defaultHosts.replacingOccurrences(of: "\t", with: "    ")).utf8)), "hosts 注释与空格")
        try check(!hostsSemanticallyDefault(Data((defaultHosts + "1.2.3.4 example.test\n").utf8)), "自定义 hosts 检测")
        try check(extraHostsEntries(Data((defaultHosts + "1.2.3.4 example.test # comment\n").utf8)) == ["1.2.3.4 example.test"], "hosts 条目提取")
        try check(!hostsSemanticallyDefault(Data("127.0.0.1 localhost\n".utf8)), "缺失默认 hosts 项")
        passed.append("hosts 解析：默认、注释、空格、自定义条目及缺失项")
        try check(eligibleTypes(["Ethernet"]), "以太网资格")
        try check(eligibleTypes(["IEEE80211"]), "Wi-Fi 资格")
        try check(!eligibleTypes(["PPP", "Ethernet"]), "VPN 排除")
        try check(!eligibleTypes(["IPSec"]), "IPSec 排除")
        try check(!eligibleTypes([]), "未知接口排除")
        passed.append("接口范围：普通网络允许，VPN 与未知类型跳过")
        let dictionary: [String: Any] = ["ServerAddresses": ["1.1.1.1", "::1"], "SearchDomains": ["example.test"], "ServerPort": 5353]
        let bytes = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        let sample = Snapshot(version: backupVersion, id: UUID().uuidString, date: "test", kind: "reset", locationID: "test", hosts: Data(defaultHosts.utf8), hostsMode: 0o644, hostsUID: 0, hostsGID: 0,
                              services: [ServiceSnapshot(id: "id", name: "Wi-Fi", configuration: bytes, enabled: true, proxiesConfiguration: bytes, proxiesEnabled: true), ServiceSnapshot(id: "none", name: "Automatic", configuration: nil, enabled: false, proxiesConfiguration: nil, proxiesEnabled: true)])
        let encoded = try PropertyListEncoder().encode(sample)
        let decoded = try PropertyListDecoder().decode(Snapshot.self, from: encoded)
        try check(decoded.services[0].configuration == bytes && decoded.services[1].configuration == nil && !decoded.services[1].enabled && decoded.hosts == sample.hosts, "备份 plist 往返")
        let restored = try PropertyListSerialization.propertyList(from: decoded.services[0].configuration!, options: [], format: nil) as! [String: Any]
        try check(NSDictionary(dictionary: dictionary).isEqual(to: restored), "DNS plist 类型保留")
        passed.append("完整 DNS / 代理 plist、空配置、启用状态与 hosts 无损内存快照")
        let proxies: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890, "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://localhost/pac", "ExceptionsList": ["*.local"], "ExcludeSimpleHostnames": 1]
        let disabled = disabledProxyConfiguration(proxies)
        try check(enabledProxyKeys(disabled).isEmpty, "代理开关关闭")
        try check(disabled["HTTPProxy"] as? String == "127.0.0.1" && disabled["HTTPPort"] as? Int == 7890 && disabled["ProxyAutoConfigURLString"] as? String == "http://localhost/pac" && disabled["ExceptionsList"] as? [String] == ["*.local"] && disabled["ExcludeSimpleHostnames"] as? Int == 1, "代理地址及绕过列表保留")
        try check(disabledProxyConfiguration([:]).isEmpty, "空代理配置保持为空")
        passed.append("代理修复只关闭开关，保留端口、地址、PAC URL 与绕过列表")
        for failedStage in ["none", "stage", "hosts", "commit", "apply", "verify"] {
            var calls: [String] = []
            var hostsValue = "original"
            var networkValue = "original"
            func step(_ stage: String) throws {
                calls.append(stage)
                if stage == failedStage { throw ResetError.failed("injected-" + stage) }
            }
            let outcome = performTransaction(stageNetwork: { try step("stage") }, writeHosts: {
                try step("hosts"); hostsValue = "fixed"
            }, commitNetwork: {
                networkValue = "fixed" // A commit failure can leave partially persisted data.
                try step("commit")
            }, applyNetwork: { try step("apply") }, verify: { try step("verify") }, rollbackHosts: {
                calls.append("rollbackHosts"); hostsValue = "original"
            }, rollbackNetwork: { calls.append("rollbackNetwork"); networkValue = "original" })
            if failedStage == "none" {
                try check(outcome.error == nil && hostsValue == "fixed" && networkValue == "fixed" && !calls.contains("rollbackHosts"), "成功路径")
            } else {
                try check(outcome.error != nil && outcome.rollbackErrors.isEmpty && hostsValue == "original" && networkValue == "original", failedStage + " 失败回滚")
                try check(calls.contains("rollbackNetwork") == ["commit", "apply", "verify"].contains(failedStage), failedStage + " 回滚范围")
            }
        }
        let rollbackFailure = performTransaction(stageNetwork: {}, writeHosts: {}, commitNetwork: {}, applyNetwork: {
            throw ResetError.failed("injected apply")
        }, verify: {}, rollbackHosts: { throw ResetError.failed("injected hosts rollback") }, rollbackNetwork: {
            throw ResetError.failed("injected network rollback")
        })
        try check(rollbackFailure.error != nil && rollbackFailure.rollbackErrors.count == 2, "回滚错误透明报告")
        passed.append("真实事务协调器故障注入：暂存、hosts、提交、应用、验证失败及双回滚失败")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DNSReset-selftest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fixture = temporary.appendingPathComponent("hosts")
        try sample.hosts.write(to: fixture)
        try check(readRegularFile(fixture.path, rootOnly: false) == sample.hosts, "隔离文件读取")
        let link = temporary.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: fixture.path)
        var rejectedSymlink = false
        do { _ = try readRegularFile(link.path, rootOnly: false) } catch { rejectedSymlink = true }
        try check(rejectedSymlink, "拒绝符号链接")
        let hardlink = temporary.appendingPathComponent("hardlink")
        try FileManager.default.linkItem(at: fixture, to: hardlink)
        var rejectedHardlink = false
        do { _ = try readRegularFile(fixture.path, rootOnly: false) } catch { rejectedHardlink = true }
        try check(rejectedHardlink, "拒绝硬链接")
        passed.append("隔离文件安全检查：读取、符号链接拒绝、硬链接拒绝")
        return passed
    }
}
