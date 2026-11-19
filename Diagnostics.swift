// MacProxyMenuBar — proxy diagnostics.
// Created with assistance from Claude (https://claude.ai) by Anthropic.
// MIT License — see LICENSE file for details.
//
// Answers "does the proxy setup actually work?" in six checks:
//   1. PAC fetch       — can the PAC file be downloaded, and is it a PAC file?
//   2. PAC evaluation  — what the PAC returns for each test URL (macOS's own
//                        PAC engine, the one Safari uses)
//   Local Network      — has macOS allowed this app onto the LAN? (macOS 15+
//                        privacy; when denied, every LAN proxy looks dead)
//   3. Proxy reachable — a TCP connection to each proxy's port (not ping)
//   4. Proxy works     — a real HTTPS request through each proxy
//   5. Egress          — public IP direct vs through the system vs per proxy
//   6. Effective       — what macOS is applying right now

import Cocoa
import Foundation
import Network

struct ProxyEndpoint: Hashable {
    var type: String   // "HTTP", "HTTPS", "SOCKS"
    var host: String
    var port: Int
    var label: String { "\(type) \(host):\(port)" }
}

enum CheckStatus: String {
    case ok = "✅", warn = "⚠️", fail = "❌", info = "ℹ️"
}

final class DiagnosticsReport {
    private(set) var lines: [String] = []
    private(set) var warnings = 0
    private(set) var failures = 0
    let started = Date()

    func section(_ title: String) {
        if !lines.isEmpty { lines.append("") }
        lines.append(title)
        lines.append(String(repeating: "─", count: title.count))
    }

    func add(_ status: CheckStatus, _ text: String) {
        if status == .warn { warnings += 1 }
        if status == .fail { failures += 1 }
        lines.append("\(status.rawValue) \(text)")
    }

    func detail(_ text: String) { lines.append("     \(text)") }

    var summary: String {
        if failures == 0 && warnings == 0 { return "All checks passed" }
        var parts: [String] = []
        if failures > 0 { parts.append("\(failures) failed") }
        if warnings > 0 { parts.append("\(warnings) warning\(warnings == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    var text: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        let head = "MacProxyMenuBar diagnostics — \(f.string(from: started))\nResult: \(summary)\n"
        return head + "\n" + lines.joined(separator: "\n") + "\n"
    }
}

final class ProxyDiagnostics {
    static let egressURL = URL(string: "https://myip.baldwinsung.com")!
    static let defaultTestURLs = ["https://www.apple.com/", "https://myip.baldwinsung.com/"]
    static let kTestURLs = "diag_test_urls"

    /// Test URLs: the user's list (Proxy Configuration → Set Test URLs…) or
    /// the defaults, plus the PAC server itself (usually an internal host,
    /// which a PAC normally sends DIRECT).
    static func testURLs(pacURL: String?) -> [URL] {
        var raw = UserDefaults.standard.stringArray(forKey: kTestURLs) ?? defaultTestURLs
        if let p = pacURL, let u = URL(string: p), let host = u.host {
            raw.append("\(u.scheme ?? "http")://\(host)/")
        }
        var seen = Set<String>()
        return raw.compactMap { s in
            let t = s.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, seen.insert(t).inserted else { return nil }
            return URL(string: t)
        }
    }

    /// Chrome on macOS can't resolve *.local names, even through the macOS
    /// resolver (seen 2026-11: ERR_NAME_NOT_RESOLVED while Safari worked).
    static func chromeCantResolve(_ host: String) -> Bool {
        host.lowercased().hasSuffix(".local") || host.lowercased().hasSuffix(".local.")
    }

    // MARK: - Run

    func run() -> DiagnosticsReport {
        let r = DiagnosticsReport()
        let settings = systemProxySettings()
        let pacEnabled = (settings["ProxyAutoConfigEnable"] as? Int ?? 0) == 1
        let pacURL = settings["ProxyAutoConfigURLString"] as? String

        // 6 first: everything else depends on what macOS is applying.
        effectiveSettings(settings, r)

        // 1 + 2
        var proxies: [ProxyEndpoint] = manualProxies(settings)
        var pacSaysProxyForEgress: ProxyEndpoint?
        var pacSaysDirectForEgress = false
        if pacEnabled, let pacURL = pacURL, !pacURL.isEmpty {
            if let script = fetchPAC(pacURL, r) {
                let results = evaluatePAC(script, urls: ProxyDiagnostics.testURLs(pacURL: pacURL), r)
                for (url, list) in results {
                    for p in list where !proxies.contains(p) { proxies.append(p) }
                    if url.host == ProxyDiagnostics.egressURL.host {
                        pacSaysProxyForEgress = list.first
                        pacSaysDirectForEgress = list.isEmpty
                    }
                }
            }
        } else {
            r.section("1. PAC file")
            r.add(.info, "Automatic proxy configuration is off — nothing to fetch")
            r.section("2. PAC evaluation")
            r.add(.info, "Skipped (no PAC file)")
        }

        // Local Network permission: without it every LAN proxy fails 3 + 4
        // with a misleading "Network is down".
        r.section("Local Network permission (macOS privacy)")
        var lanDenied = false
        if let t = LocalNetworkProbe.target(candidates: proxies) {
            switch LocalNetworkProbe.check(host: t.host, port: t.port) {
            case .allowed:
                r.add(.ok, "This app is allowed on the local network (tested \(t.host):\(t.port))")
            case .denied:
                lanDenied = true
                r.add(.fail, "Denied: macOS blocks this app from the local network, so LAN proxies look unreachable (macOS reports it as \"Network is down\")")
                r.detail("Fix: Privacy & Security → Local Network → turn on MacProxyMenuBar (button below), then quit and reopen the app")
            case .unknown(let why):
                r.add(.warn, "Couldn't tell (\(why)) — if an Allow prompt is showing, click Allow and run again")
            }
        } else {
            r.add(.info, "No LAN address to test against (no private-IP proxy, no default gateway)")
        }
        r.add(.info, "Browsers need their own Local Network permission (Chrome, Firefox, …; Safari is exempt) — other apps' settings can't be checked from here")

        // 3 + 4
        r.section("3. Proxy reachable (TCP connect)")
        if proxies.isEmpty { r.add(.info, "No proxy servers configured or returned by the PAC") }
        for p in proxies where Self.chromeCantResolve(p.host) {
            r.add(.warn, "\(p.label) is a .local name: Chrome and other Chromium-based apps can't resolve it, so they get no proxy (Safari can). Use its IP address.")
        }
        var reachable = Set<ProxyEndpoint>()
        for p in proxies {
            let (ms, err) = tcpConnect(host: p.host, port: p.port)
            if let ms = ms {
                r.add(.ok, "\(p.label) — connected in \(ms) ms")
                reachable.insert(p)
            } else {
                r.add(.fail, "\(p.label) — \(err ?? "no connection")")
                if lanDenied && LocalNetworkProbe.isPrivateIPv4(p.host) {
                    r.detail("blocked by the Local Network permission above, not necessarily down")
                }
            }
        }

        r.section("4. Proxy works (HTTPS request through it)")
        if proxies.isEmpty { r.add(.info, "Skipped (no proxies)") }
        var viaProxyIP: [ProxyEndpoint: String] = [:]
        for p in proxies {
            guard reachable.contains(p) else {
                r.add(.fail, "\(p.label) — skipped, port not reachable")
                continue
            }
            let res = fetchIP(proxy: p)
            if let ip = res.ip {
                r.add(.ok, "\(p.label) — HTTP \(res.status ?? 0) in \(res.ms) ms, egress \(ip)")
                viaProxyIP[p] = ip
            } else {
                r.add(.fail, "\(p.label) — \(res.error ?? "HTTP \(res.status ?? 0)")")
                if res.status == 407 { r.detail("407 = the proxy wants a username/password") }
                if res.status == 403 { r.detail("403 = the proxy refused this destination (ACL)") }
            }
        }

        // 5
        r.section("5. Egress (public IP from \(ProxyDiagnostics.egressURL.host ?? ""))")
        // Is a direct connection possible at all? A plain BSD socket can't be
        // routed through a proxy, so this is the ground truth.
        let tcp = directConnect(host: ProxyDiagnostics.egressURL.host ?? "")
        let directBlocked = tcp.error != nil
        var direct = FetchResult(ms: tcp.ms)
        if let e = tcp.error {
            direct.error = e
            r.add(.info, "Direct (no proxy):     blocked — \(e)")
        } else {
            direct = fetchIPDirect()
            if let ip = direct.ip {
                r.add(.info, "Direct (no proxy):     \(ip)")
            } else {
                r.add(.info, "Direct (no proxy):     open (TCP connect in \(tcp.ms) ms), IP lookup failed — \(direct.error ?? "?")")
            }
        }
        let system = fetchIP(proxy: nil, direct: false)
        if let ip = system.ip {
            r.add(.info, "System (macOS path):   \(ip)")
        } else {
            r.add(.fail, "System (macOS path):   failed — \(system.error ?? "HTTP \(system.status ?? 0)")")
        }
        for (p, ip) in viaProxyIP { r.add(.info, "Via \(p.label): \(ip)") }

        if let sys = system.ip {
            if let want = pacSaysProxyForEgress {
                if directBlocked, let pip = viaProxyIP[want], pip == sys {
                    r.add(.ok, "Traffic goes through \(want.label), as the PAC says, and direct connections are blocked, so apps that ignore the proxy settings can't get around it")
                } else if directBlocked && viaProxyIP[want] == nil {
                    r.add(.info, "Direct connections are blocked; \(want.label)'s own egress is unknown (checks 3/4 couldn't reach it), so it can't be compared with \(sys)")
                } else if directBlocked {
                    r.add(.warn, "Direct connections are blocked, but system egress \(sys) doesn't match \(want.label)'s egress")
                } else if let pip = viaProxyIP[want], pip == sys, direct.ip == pip {
                    r.add(.warn, "Can't tell from the IP: direct traffic and \(want.label) both leave from \(sys) (the network routes everything out the same exit)")
                } else if let pip = viaProxyIP[want], pip == sys {
                    r.add(.ok, "Traffic goes through \(want.label), as the PAC says")
                } else if let d = direct.ip, d == sys {
                    r.add(.warn, "PAC says \(want.label), but the system path egresses directly (\(sys)) — macOS isn't applying the PAC (cached? another service first in the service order?)")
                } else if viaProxyIP[want] == nil {
                    r.add(.info, "PAC says \(want.label); its egress is unknown (checks 3/4 couldn't reach it), so it can't be compared with \(sys)")
                } else {
                    r.add(.warn, "PAC says \(want.label); system egress \(sys) doesn't match that proxy's egress")
                }
            } else if pacSaysDirectForEgress {
                r.add(.ok, "PAC says DIRECT for this host; system egress is \(sys)")
            } else if !manualProxies(settings).isEmpty {
                let match = viaProxyIP.first { $0.value == sys }
                if let m = match { r.add(.ok, "Traffic goes through \(m.key.label)") }
                else if let d = direct.ip, d == sys { r.add(.warn, "A manual proxy is set but traffic egresses directly") }
            } else if direct.ip == sys {
                r.add(.info, "No proxy in use — traffic egresses directly")
            }
        }

        return r
    }

    // MARK: - 6. Effective settings

    func systemProxySettings() -> [String: Any] {
        (CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]) ?? [:]
    }

    private func manualProxies(_ s: [String: Any]) -> [ProxyEndpoint] {
        var out: [ProxyEndpoint] = []
        for (type, prefix) in [("HTTP", "HTTP"), ("HTTP", "HTTPS"), ("SOCKS", "SOCKS")] {
            guard (s["\(prefix)Enable"] as? Int ?? 0) == 1,
                  let host = s["\(prefix)Proxy"] as? String, !host.isEmpty,
                  let port = s["\(prefix)Port"] as? Int else { continue }
            // An "HTTPS proxy" in System Settings is an HTTP proxy used for
            // https:// URLs (CONNECT), so test it as HTTP.
            let p = ProxyEndpoint(type: type, host: host, port: port)
            if !out.contains(p) { out.append(p) }
        }
        return out
    }

    private func effectiveSettings(_ s: [String: Any], _ r: DiagnosticsReport) {
        r.section("6. Effective settings (what macOS applies now)")
        func on(_ k: String) -> Bool { (s[k] as? Int ?? 0) == 1 }
        if on("ProxyAutoConfigEnable") {
            r.add(.info, "Automatic proxy configuration: ON — \(s["ProxyAutoConfigURLString"] as? String ?? "(no URL)")")
        } else {
            r.add(.info, "Automatic proxy configuration: off")
        }
        r.add(on("ProxyAutoDiscoveryEnable") ? .warn : .info,
              "Auto proxy discovery (WPAD): \(on("ProxyAutoDiscoveryEnable") ? "ON — the network can push its own PAC" : "off")")
        for (label, prefix) in [("Web proxy (HTTP)", "HTTP"), ("Secure web proxy (HTTPS)", "HTTPS"), ("SOCKS proxy", "SOCKS")] {
            if on("\(prefix)Enable") {
                r.add(.info, "\(label): \(s["\(prefix)Proxy"] as? String ?? "?"):\(s["\(prefix)Port"] as? Int ?? 0)")
            }
        }
        if let ex = s["ExceptionsList"] as? [String], !ex.isEmpty {
            r.add(.info, "Bypass list: \(ex.joined(separator: ", "))")
        }
        if on("ExcludeSimpleHostnames") { r.add(.info, "Simple hostnames bypass the proxy") }
        if on("ProxyAutoConfigEnable") && (on("HTTPEnable") || on("HTTPSEnable")) {
            r.add(.warn, "Both a PAC file and manual proxies are on. Apps differ in which they use, and the bypass list only applies to the manual ones — keep one (System Settings → Network → Details → Proxies)")
        }
    }

    // MARK: - 1. PAC fetch

    private func fetchPAC(_ urlString: String, _ r: DiagnosticsReport) -> String? {
        r.section("1. PAC file")
        r.add(.info, "URL: \(urlString)")
        guard let url = URL(string: urlString), let host = url.host,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            r.add(.fail, "Not a valid PAC URL: it needs http:// or https:// and a path, e.g. http://\(urlString)/proxy.pac")
            r.detail("macOS can't fetch it, so it falls back to DIRECT. Fix it in Set PAC URL… (or System Settings → Network → Details → Proxies).")
            return nil
        }
        if Self.chromeCantResolve(host) {
            r.add(.warn, "\(host) is a .local name: Chrome and other Chromium-based apps can't resolve it, so they can't fetch this PAC (Safari can). Use an IP address, or a local copy at http://127.0.0.1:…")
        }
        // macOS fetches the PAC directly, never through a proxy: do the same.
        let res = get(url, proxyDict: Self.directProxyDict, timeout: 6)
        if let err = res.error {
            r.add(.fail, "Fetch failed after \(res.ms) ms: \(err)")
            r.detail("Without the PAC, macOS falls back to DIRECT. Check the PAC server is up and the network (firewall/ACL) allows this Mac to reach it.")
            return nil
        }
        let body = String(data: res.data ?? Data(), encoding: .utf8) ?? ""
        guard res.status == 200 else {
            r.add(.fail, "HTTP \(res.status ?? 0) in \(res.ms) ms")
            return nil
        }
        r.add(.ok, "HTTP 200, \(res.data?.count ?? 0) bytes in \(res.ms) ms\(res.contentType.map { ", \($0)" } ?? "")")
        if !body.contains("FindProxyForURL") {
            r.add(.fail, "The file has no FindProxyForURL function — not a PAC file (an error or login page?)")
            r.detail(String(body.prefix(160)).replacingOccurrences(of: "\n", with: " "))
            return nil
        }
        if let ct = res.contentType, !ct.contains("proxy-autoconfig"), !ct.contains("javascript") {
            r.add(.info, "Content-Type \(ct) — macOS accepts it; application/x-ns-proxy-autoconfig is the standard type")
        }
        return body
    }

    // MARK: - 2. PAC evaluation

    private func evaluatePAC(_ script: String, urls: [URL], _ r: DiagnosticsReport) -> [(URL, [ProxyEndpoint])] {
        r.section("2. PAC evaluation (macOS PAC engine)")
        var out: [(URL, [ProxyEndpoint])] = []
        for url in urls {
            var err: Unmanaged<CFError>?
            guard let arr = CFNetworkCopyProxiesForAutoConfigurationScript(script as CFString, url as CFURL, &err)?
                    .takeRetainedValue() as? [[String: Any]] else {
                let msg = err.map { String(describing: $0.takeRetainedValue()) } ?? "no result"
                r.add(.fail, "\(url.absoluteString) → PAC error: \(msg)")
                continue
            }
            var list: [ProxyEndpoint] = []
            var parts: [String] = []
            for p in arr {
                let type = p[kCFProxyTypeKey as String] as? String ?? ""
                if type == (kCFProxyTypeNone as String) { parts.append("DIRECT"); continue }
                let host = p[kCFProxyHostNameKey as String] as? String ?? "?"
                let port = (p[kCFProxyPortNumberKey as String] as? NSNumber)?.intValue ?? 0
                // kCFProxyTypeHTTPS is what CFNetwork reports for a PAC
                // "PROXY host:port" on an https:// URL: the same HTTP proxy,
                // used with CONNECT. Treat it as HTTP so it's tested once.
                let t = type == (kCFProxyTypeSOCKS as String) ? "SOCKS" : "HTTP"
                let e = ProxyEndpoint(type: t, host: host, port: port)
                list.append(e)
                parts.append(e.label)
            }
            r.add(.info, "\(url.absoluteString) → \(parts.isEmpty ? "DIRECT" : parts.joined(separator: "; "))")
            out.append((url, list))
        }
        return out
    }

    // MARK: - 3. TCP connect

    private func tcpConnect(host: String, port: Int, timeout: TimeInterval = 4) -> (Int?, String?) {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return (nil, "bad port \(port)") }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        let done = DispatchSemaphore(value: 0)
        let start = Date()
        var ms: Int?
        var error: String?
        let lock = NSLock()
        var finished = false
        func finish(_ m: Int?, _ e: String?) {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            ms = m; error = e
            done.signal()
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(Int(Date().timeIntervalSince(start) * 1000), nil)
            case .failed(let e): finish(nil, e.localizedDescription)
            case .waiting(let e): finish(nil, e.localizedDescription)
            default: break
            }
        }
        conn.start(queue: DispatchQueue.global(qos: .userInitiated))
        if done.wait(timeout: .now() + timeout) == .timedOut {
            finish(nil, "timed out after \(Int(timeout)) s")
        }
        conn.cancel()
        return (ms, error)
    }

    // MARK: - 5. Truly direct fetch

    /// TCP connect with a plain BSD socket. Sockets never go through system
    /// proxies or a PAC, so this answers "can this Mac reach the internet
    /// without the proxy?". Network.framework can't: it applied the PAC even
    /// with preferNoProxies set.
    private func directConnect(host: String, port: UInt16 = 443, timeout: TimeInterval = 5) -> (ms: Int, error: String?) {
        let start = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        if rc != 0 { return (ms(), "DNS lookup failed: \(String(cString: gai_strerror(rc)))") }
        defer { freeaddrinfo(res) }
        var lastErr = "no address for \(host)"
        var ai = res
        while let a = ai {
            ai = a.pointee.ai_next
            let left = timeout - Date().timeIntervalSince(start)
            if left <= 0 { lastErr = "timed out after \(Int(timeout)) s"; break }
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd < 0 { lastErr = String(cString: strerror(errno)); continue }
            defer { close(fd) }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
            if connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 { return (ms(), nil) }
            if errno != EINPROGRESS { lastErr = String(cString: strerror(errno)); continue }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let n = poll(&pfd, 1, Int32(left * 1000))
            if n == 0 { lastErr = "timed out after \(Int(timeout)) s"; continue }
            if n < 0 { lastErr = String(cString: strerror(errno)); continue }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
            if soErr == 0 { return (ms(), nil) }
            lastErr = String(cString: strerror(soErr))
        }
        return (ms(), lastErr)
    }

    /// GET egressURL over a raw TLS connection with proxies refused. Only
    /// called after directConnect succeeds; on its own it isn't proof of a
    /// direct path (see directConnect).
    private func fetchIPDirect(timeout: TimeInterval = 8) -> FetchResult {
        let host = Self.egressURL.host ?? ""
        let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        params.preferNoProxies = true
        let conn = NWConnection(host: NWEndpoint.Host(host), port: 443, using: params)
        let start = Date()
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var buffer = Data()
        var error: String?
        var finished = false
        func finish(_ e: String?) {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            error = e
            done.signal()
        }
        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, err in
                if let d = data { lock.lock(); buffer.append(d); lock.unlock() }
                if let e = err { finish(e.localizedDescription); return }
                if complete { finish(nil) } else { receive() }
            }
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let req = "GET / HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: ProxyMenuBar/diagnostics\r\nAccept: application/json\r\nConnection: close\r\n\r\n"
                conn.send(content: req.data(using: .utf8), completion: .contentProcessed { e in
                    if let e = e { finish(e.localizedDescription) } else { receive() }
                })
            case .failed(let e): finish(e.localizedDescription)
            case .waiting(let e): finish(e.localizedDescription)
            default: break
            }
        }
        conn.start(queue: DispatchQueue.global(qos: .userInitiated))
        if done.wait(timeout: .now() + timeout) == .timedOut { finish("timed out after \(Int(timeout)) s") }
        conn.cancel()

        var out = FetchResult(ms: Int(Date().timeIntervalSince(start) * 1000))
        lock.lock(); let text = String(decoding: buffer, as: UTF8.self); lock.unlock()
        if let line = text.components(separatedBy: "\r\n").first, line.hasPrefix("HTTP/") {
            let parts = line.components(separatedBy: " ")
            if parts.count > 1 { out.status = Int(parts[1]) }
        }
        if let range = text.range(of: "\r\n\r\n") {
            let body = String(text[range.upperBound...])
            // Body may be chunked; pull the first IPv4/IPv6-looking token.
            let pattern = #"\b(?:\d{1,3}(?:\.\d{1,3}){3}|[0-9a-fA-F]{0,4}(?::[0-9a-fA-F]{0,4}){2,7})\b"#
            if let m = body.range(of: pattern, options: .regularExpression), out.status == 200 {
                out.ip = String(body[m])
            }
        }
        if out.ip == nil { out.error = error ?? "HTTP \(out.status ?? 0), no IP in response" }
        return out
    }

    // MARK: - 4/5. HTTP through a chosen path

    static let directProxyDict: [AnyHashable: Any] = [
        "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
        "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0,
    ]

    private static func proxyDict(_ p: ProxyEndpoint) -> [AnyHashable: Any] {
        if p.type == "SOCKS" {
            return ["SOCKSEnable": 1, "SOCKSProxy": p.host, "SOCKSPort": p.port]
        }
        return ["HTTPEnable": 1, "HTTPProxy": p.host, "HTTPPort": p.port,
                "HTTPSEnable": 1, "HTTPSProxy": p.host, "HTTPSPort": p.port]
    }

    struct FetchResult {
        var status: Int?
        var data: Data?
        var contentType: String?
        var error: String?
        var ms: Int
        var ip: String?
    }

    /// proxy == nil && direct == false: the system's own path (PAC included).
    private func fetchIP(proxy: ProxyEndpoint?, direct: Bool = false) -> FetchResult {
        let dict: [AnyHashable: Any]? = proxy.map(Self.proxyDict) ?? (direct ? Self.directProxyDict : nil)
        var res = get(Self.egressURL, proxyDict: dict, timeout: 8)
        if res.error == nil, res.status == 200, let data = res.data {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ip = json["ip"] as? String {
                res.ip = ip
            } else if let t = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t.count < 64 {
                res.ip = t
            }
        }
        return res
    }

    /// proxyDict nil = system settings; otherwise exactly this proxy config.
    private func get(_ url: URL, proxyDict: [AnyHashable: Any]?, timeout: TimeInterval) -> FetchResult {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let d = proxyDict { cfg.connectionProxyDictionary = d }
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        var req = URLRequest(url: url)
        req.setValue("ProxyMenuBar/diagnostics", forHTTPHeaderField: "User-Agent")
        let start = Date()
        let done = DispatchSemaphore(value: 0)
        var out = FetchResult(ms: 0)
        session.dataTask(with: req) { data, resp, err in
            out.ms = Int(Date().timeIntervalSince(start) * 1000)
            if let http = resp as? HTTPURLResponse {
                out.status = http.statusCode
                out.contentType = http.value(forHTTPHeaderField: "Content-Type")
            }
            out.data = data
            if let e = err as NSError? {
                out.error = "\(e.localizedDescription) (\(e.domain) \(e.code))"
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 2)
        return out
    }
}

// MARK: - Local Network permission

enum LocalNetworkAccess {
    case allowed, denied, unknown(String)
}

/// macOS 15+ asks the user before an app may talk to LAN addresses
/// (loopback is exempt). There is no API to read or grant the setting, so
/// this infers it from a real connection attempt — which is also what makes
/// macOS show the Allow prompt the first time.
enum LocalNetworkProbe {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

    /// A LAN address to test: the first proxy on a private IPv4 address,
    /// else the default gateway (port 80; refused is fine — it still proves
    /// packets got out).
    static func target(candidates: [ProxyEndpoint]) -> (host: String, port: Int)? {
        if let p = candidates.first(where: { isPrivateIPv4($0.host) }) { return (p.host, p.port) }
        if let gw = defaultGateway() { return (gw, 80) }
        return nil
    }

    static func isPrivateIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let o = parts.compactMap { Int($0) }
        guard parts.count == 4, o.count == 4, o.allSatisfy({ (0...255).contains($0) }) else { return false }
        return o[0] == 10
            || (o[0] == 172 && (16...31).contains(o[1]))
            || (o[0] == 192 && o[1] == 168)
            || (o[0] == 169 && o[1] == 254)
    }

    static func defaultGateway() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/route")
        task.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") {
                let gw = String(t.dropFirst("gateway:".count)).trimmingCharacters(in: .whitespaces)
                return isPrivateIPv4(gw) ? gw : nil
            }
        }
        return nil
    }

    /// Any outcome except a Local Network denial — connected, refused,
    /// unreachable — means the permission isn't what's in the way. A denied
    /// connection sits in .waiting and turns .ready if the user clicks Allow,
    /// so keep waiting up to `grace` seconds in case the prompt is on screen.
    static func check(host: String, port: Int, grace: TimeInterval = 10) -> LocalNetworkAccess {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .unknown("bad port \(port)") }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        let lock = NSLock()
        var result: LocalNetworkAccess?
        var sawDenied = false
        let done = DispatchSemaphore(value: 0)
        func finish(_ r: LocalNetworkAccess) {
            lock.lock(); defer { lock.unlock() }
            guard result == nil else { return }
            result = r
            done.signal()
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(.allowed)
            case .waiting(let e):
                if isDenial(conn, e) { lock.lock(); sawDenied = true; lock.unlock() } else { finish(.allowed) }
            case .failed(let e):
                finish(isDenial(conn, e) ? .denied : .allowed)
            default:
                break
            }
        }
        conn.start(queue: DispatchQueue.global(qos: .userInitiated))
        _ = done.wait(timeout: .now() + grace)
        conn.cancel()
        conn.stateUpdateHandler = nil   // the handler captures conn; break the cycle
        lock.lock(); defer { lock.unlock() }
        if let r = result { return r }
        return sawDenied ? .denied : .unknown("no answer from \(host):\(port) in \(Int(grace)) s")
    }

    /// macOS 26 reports a Local Network denial as POSIX ENETDOWN ("Network is
    /// down", NWError 50); the path's unsatisfiedReason says so explicitly.
    private static func isDenial(_ conn: NWConnection, _ e: NWError) -> Bool {
        if conn.currentPath?.unsatisfiedReason == .localNetworkDenied { return true }
        if case .posix(let code) = e, code == .ENETDOWN { return true }
        return false
    }
}

// MARK: - Report window

final class DiagnosticsWindowController: NSWindowController {
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let runButton = NSButton(title: "Run Again", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Report", target: nil, action: nil)
    private let lanButton = NSButton(title: "Local Network Settings…", target: nil, action: nil)
    private var report: DiagnosticsReport?
    var onFinished: ((DiagnosticsReport) -> Void)?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Proxy Diagnostics"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildUI()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView

        runButton.target = self
        runButton.action = #selector(runAgain)
        copyButton.target = self
        copyButton.action = #selector(copyReport)
        lanButton.target = self
        lanButton.action = #selector(openLocalNetworkSettings)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [statusLabel, NSView(), lanButton, copyButton, runButton])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
    }

    func showAndRun() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        runAgain()
    }

    @objc func runAgain() {
        runButton.isEnabled = false
        copyButton.isEnabled = false
        statusLabel.stringValue = "Running… (up to ~30 s)"
        textView.string = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let r = ProxyDiagnostics().run()
            DispatchQueue.main.async {
                self.report = r
                self.textView.string = r.text
                self.statusLabel.stringValue = r.summary
                self.runButton.isEnabled = true
                self.copyButton.isEnabled = true
                self.onFinished?(r)
            }
        }
    }

    @objc func openLocalNetworkSettings() {
        NSWorkspace.shared.open(LocalNetworkProbe.settingsURL)
    }

    @objc func copyReport() {
        guard let r = report else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(r.text, forType: .string)
        statusLabel.stringValue = "Copied to clipboard"
    }
}
