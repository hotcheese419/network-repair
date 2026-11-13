import Foundation
import SystemConfiguration
import Darwin

struct ConnectivityReport: Codable {
    let hasNetworkLink: Bool
    let dnsWorks: Bool
    let httpsWorks: Bool
    let captivePortalSuspected: Bool
    let summary: String
    let details: [String]
}

/// Read-only probes. Call from a background queue; never from the UI thread.
/// Uses fixed public URLs, bypasses local HTTP proxies and never sends local configuration.
enum NetworkDiagnostics {
    private static let marker = "__DNSRESET_PROBE__"

    struct ProbeOutcome {
        let name: String
        let exitCode: Int32
        let httpCode: Int
        let lookupSeconds: Double
        let remoteIP: String
        let redirectURL: String
        let body: String
        let didTimeOut: Bool

        var resolved: Bool {
            // A DNS failure cannot be upgraded to success merely because curl measured time.
            guard exitCode != 5 && exitCode != 6 else { return false }
            return !remoteIP.isEmpty || lookupSeconds > 0 || httpCode > 0
        }

        var reachedHTTPS: Bool {
            // A genuine HTTP response after a verified TLS handshake counts even if it is 403.
            !didTimeOut && exitCode == 0 && (100...599).contains(httpCode)
        }

        var unexpectedAppleResponse: Bool {
            guard name == "Apple", reachedHTTPS else { return false }
            if httpCode == 511 || (300...399).contains(httpCode) { return true }
            guard httpCode == 200 else { return false }
            let compact = body.lowercased().filter { !$0.isWhitespace }
            return !(compact.contains("<title>success</title>") && compact.contains("<body>success</body>"))
        }

        var detail: String {
            if didTimeOut || exitCode == 28 { return "\(name)：检查超时" }
            if exitCode == 5 || exitCode == 6 { return "\(name)：域名未能解析" }
            if reachedHTTPS { return "\(name)：域名已解析，HTTPS 已响应（\(httpCode)）" }
            if exitCode == 60 { return "\(name)：TLS 证书验证未通过" }
            if exitCode == 35 { return "\(name)：TLS 连接未建立" }
            if resolved { return "\(name)：域名已解析，HTTPS 未连通（\(exitCode)）" }
            return "\(name)：连接检查未通过（\(exitCode)）" 
        }
    }

    private struct RunningProbe {
        let name: String
        let task: Process
        let output: Pipe
    }

    static func run() -> ConnectivityReport {
        let interfaces = defaultInterfaces()
        let definitions: [(String, String, Bool)] = [
            ("Apple", "https://www.apple.com/library/test/success.html", false),
            ("百度", "https://www.baidu.com/", true)
        ]
        var running: [RunningProbe] = []
        var outcomes: [ProbeOutcome] = []

        for (name, url, headOnly) in definitions {
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
            var args = [
                "--disable", "--silent", "--noproxy", "*", "--proto", "=https",
                "--connect-timeout", "3", "--max-time", "5", "--max-redirs", "0",
                "--user-agent", "NetworkRepair/1.0",
                "--write-out", "\n\(marker) %{http_code} %{time_namelookup} %{remote_ip} %{redirect_url}\n"
            ]
            if headOnly { args += ["--head", "--output", "/dev/null"] }
            else { args += ["--max-filesize", "8192"] }
            args.append(url)
            task.arguments = args
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                running.append(RunningProbe(name: name, task: task, output: pipe))
            } catch {
                outcomes.append(parse(name: name, output: "", exitCode: -1, didTimeOut: false))
            }
        }

        // Both probes run concurrently. curl has its own deadline; this supervisor also
        // bounds execution if a system resolver or curl itself stops honoring that deadline.
        let deadline = ProcessInfo.processInfo.systemUptime + 7.0
        while running.contains(where: { $0.task.isRunning }) && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        for probe in running {
            let timedOut = probe.task.isRunning
            if timedOut {
                _ = Darwin.kill(probe.task.processIdentifier, SIGKILL)
            }
            // A killed local process exits promptly. Pipe capacity cannot block these
            // probes: the Apple body is limited to 8 KiB and the other body is discarded.
            probe.task.waitUntilExit()
            let data = probe.output.fileHandleForReading.readDataToEndOfFile()
            try? probe.output.fileHandleForReading.close()
            outcomes.append(parse(name: probe.name,
                                  output: String(decoding: data, as: UTF8.self),
                                  exitCode: probe.task.terminationStatus,
                                  didTimeOut: timedOut))
        }
        return report(interfaces: interfaces, outcomes: outcomes)
    }

    static func parse(name: String, output: String, exitCode: Int32, didTimeOut: Bool) -> ProbeOutcome {
        let lastMarker = output.range(of: marker, options: .backwards)
        let body = lastMarker.map { String(output[..<$0.lowerBound]) } ?? ""
        let metadata = lastMarker.map { String(output[$0.upperBound...]) } ?? ""
        let fields = metadata.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        return ProbeOutcome(name: name, exitCode: exitCode,
                            httpCode: fields.first.flatMap(Int.init) ?? 0,
                            lookupSeconds: fields.count > 1 ? Double(fields[1]) ?? 0 : 0,
                            remoteIP: fields.count > 2 ? fields[2] : "",
                            redirectURL: fields.count > 3 ? fields[3] : "",
                            body: body, didTimeOut: didTimeOut)
    }

    static func report(interfaces: [String], outcomes: [ProbeOutcome]) -> ConnectivityReport {
        let hasLink = !interfaces.isEmpty
        let dns = outcomes.contains { $0.resolved }
        let https = outcomes.contains { $0.reachedHTTPS }
        let captive = outcomes.contains { $0.unexpectedAppleResponse }
        let summary: String
        if captive {
            summary = "检测到可能的网络登录页，请打开浏览器完成认证。"
        } else if https {
            summary = "已通过互联网连接检查。"
        } else if !hasLink {
            summary = "未发现默认网络连接，请检查 Wi-Fi 或网线。"
        } else if dns {
            summary = "域名已解析，但 HTTPS 连接未通过检查。"
        } else {
            summary = "DNS 或外网连接未通过检查。"
        }
        var details = [hasLink ? "默认网络接口：\(interfaces.joined(separator: "、"))" : "没有检测到默认 IPv4 / IPv6 网络接口"]
        details += outcomes.sorted { $0.name < $1.name }.map { $0.detail }
        if captive { details.append("Apple 网络检测页返回了异常内容；这只是登录认证的线索。") }
        details.append("检查直接访问 Apple 与百度；VPN、网站限制和临时故障可能影响结果。")
        return ConnectivityReport(hasNetworkLink: hasLink, dnsWorks: dns, httpsWorks: https,
                                  captivePortalSuspected: captive, summary: summary, details: details)
    }

    private static func defaultInterfaces() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "NetworkRepairDiagnostics" as CFString, nil, nil) else { return [] }
        var interfaces: [String] = []
        for family in ["IPv4", "IPv6"] {
            let key = "State:/Network/Global/\(family)" as CFString
            guard let dict = SCDynamicStoreCopyValue(store, key) as? [String: Any],
                  let name = dict[kSCDynamicStorePropNetPrimaryInterface as String] as? String,
                  !name.isEmpty else { continue }
            if !interfaces.contains(name) { interfaces.append(name) }
        }
        return interfaces
    }
}
