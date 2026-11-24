// MacProxyMenuBar
// Created with assistance from Claude (https://claude.ai) by Anthropic.
// MIT License — see LICENSE file for details.

import Cocoa
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var proxyChecker: ProxyChecker!
    var refreshTimer: Timer?
    var autoRefreshEnabled = true

    // Menu items
    let ipMenuItem               = NSMenuItem(title: "External IP: Loading...", action: #selector(copyIP), keyEquivalent: "")
    let ipSourceMenuItem         = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    lazy var updateMenuItem      = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
    let proxyStatusMenuItem      = NSMenuItem(title: "Proxy: Checking...", action: nil, keyEquivalent: "")
    let proxyDetailMenuItem      = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let refreshMenuItem          = NSMenuItem(title: "⟳  Refresh", action: #selector(manualRefresh), keyEquivalent: "r")
    lazy var autoRefreshMenuItem = NSMenuItem(title: "Auto-refresh: ON", action: #selector(toggleAutoRefresh), keyEquivalent: "")
    let lastUpdatedMenuItem      = NSMenuItem(title: "Last updated: —", action: nil, keyEquivalent: "")
    lazy var launchAtLoginMenuItem   = NSMenuItem(title: "Open at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    lazy var proxyServersMenuItem    = NSMenuItem(title: "Proxy Servers", action: nil, keyEquivalent: "")
    lazy var pacEnabledMenuItem      = NSMenuItem(title: "Enable Auto Proxy", action: #selector(togglePAC), keyEquivalent: "")
    lazy var pacURLMenuItem          = NSMenuItem(title: "Set PAC URL...", action: #selector(setPACURL), keyEquivalent: "")
    lazy var pacCurrentURLMenuItem   = NSMenuItem(title: "PAC URL: —", action: nil, keyEquivalent: "")
    lazy var pacSourceMenuItem       = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    lazy var pacSystemMenuItem       = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    lazy var diagnosticsMenuItem     = NSMenuItem(title: "🩺  Run Diagnostics…", action: #selector(runDiagnostics), keyEquivalent: "d")
    lazy var diagnosticsResultItem   = NSMenuItem(title: "Diagnostics: not run yet", action: nil, keyEquivalent: "")
    lazy var testURLsMenuItem        = NSMenuItem(title: "Set Diagnostic Test URLs…", action: #selector(setTestURLs), keyEquivalent: "")
    var diagnosticsWindow: DiagnosticsWindowController?

    // UserDefaults keys
    let kPACURL = "pac_url"
    let kPACSource = "pac_url_source"          // "system" | "manual"
    let kPACLastSystem = "pac_url_last_system" // system PAC URL seen at the last sync
    let kDiagOnLaunch = "diag_on_launch"
    let kMigratedOldID = "migrated_from_old_bundle_id"
    /// Bundle ID before 2026-11-24 (Xcode's placeholder); settings are copied from it once.
    static let oldBundleID = "com.user.SimpleProxyMenuBar"

    /// The system's PAC as of the last syncPACFromSystem() (nil = none configured).
    var systemPACSnapshot: SystemPAC?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        migrateOldSettings()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🔍 ..."
        statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        proxyChecker = ProxyChecker()

        syncPACFromSystem()
        buildMenu()

        // Touch the LAN once at launch so macOS shows the Local Network
        // "Allow" prompt right away (it only appears on a real LAN
        // connection, and can't be granted programmatically). Harmless once
        // the user has answered; re-prompts if a rebuild changed the app's
        // signing identity.
        DispatchQueue.global(qos: .utility).async {
            if let t = LocalNetworkProbe.target(candidates: []) {
                _ = LocalNetworkProbe.check(host: t.host, port: t.port, grace: 30)
            }
        }
        startAutoRefresh()
        refresh()

        // Quiet update check shortly after launch: only retitles the
        // Help menu item if a newer release exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.runUpdateCheck(quiet: true) }

        // Set by "Save & Enable": check the new PAC actually works once the
        // relaunched app has settled.
        if UserDefaults.standard.bool(forKey: kDiagOnLaunch) {
            UserDefaults.standard.set(false, forKey: kDiagOnLaunch)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.runDiagnostics() }
        }
    }

    // MARK: - Menu

    func buildMenu() {
        let menu = NSMenu()

        // IP
        ipMenuItem.target = self
        ipMenuItem.toolTip = "Click to copy IP"
        menu.addItem(ipMenuItem)
        ipSourceMenuItem.attributedTitle = NSAttributedString(
            string: "via \(ProxyChecker.ipServiceHost)",
            attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor])
        ipSourceMenuItem.isEnabled = false
        ipSourceMenuItem.indentationLevel = 1
        ipSourceMenuItem.toolTip = "The public IP is pulled from \(ProxyChecker.ipServiceURL.absoluteString) over your current proxy settings."
        menu.addItem(ipSourceMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Proxy status
        proxyStatusMenuItem.isEnabled = false
        menu.addItem(proxyStatusMenuItem)

        proxyDetailMenuItem.isEnabled = false
        proxyDetailMenuItem.indentationLevel = 1
        menu.addItem(proxyDetailMenuItem)

        // Proxy servers (dynamic submenu, rebuilt on each refresh)
        let placeholderMenu = NSMenu()
        let loadingItem = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
        loadingItem.isEnabled = false
        placeholderMenu.addItem(loadingItem)
        proxyServersMenuItem.submenu = placeholderMenu
        menu.addItem(proxyServersMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Diagnostics
        diagnosticsMenuItem.target = self
        menu.addItem(diagnosticsMenuItem)
        diagnosticsResultItem.isEnabled = false
        diagnosticsResultItem.indentationLevel = 1
        menu.addItem(diagnosticsResultItem)

        menu.addItem(NSMenuItem.separator())

        // Last updated
        lastUpdatedMenuItem.isEnabled = false
        menu.addItem(lastUpdatedMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Refresh
        refreshMenuItem.target = self
        menu.addItem(refreshMenuItem)

        autoRefreshMenuItem.target = self
        menu.addItem(autoRefreshMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Proxy Configuration submenu
        menu.addItem(buildProxyConfigMenu())

        // Preferences submenu
        let prefsMenu = NSMenu()
        launchAtLoginMenuItem.target = self
        launchAtLoginMenuItem.state = isLaunchAtLoginEnabled() ? .on : .off
        prefsMenu.addItem(launchAtLoginMenuItem)

        let prefsItem = NSMenuItem(title: "Preferences", action: nil, keyEquivalent: "")
        prefsItem.submenu = prefsMenu
        menu.addItem(prefsItem)

        // Help submenu
        let helpMenu = NSMenu()
        let aboutItem = NSMenuItem(title: "About MacProxyMenuBar", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        helpMenu.addItem(aboutItem)
        updateMenuItem.target = self
        helpMenu.addItem(updateMenuItem)
        helpMenu.addItem(NSMenuItem.separator())

        let githubItem = NSMenuItem(title: "GitHub: baldwinsung", action: #selector(openGitHub), keyEquivalent: "")
        githubItem.target = self
        helpMenu.addItem(githubItem)

        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpItem.submenu = helpMenu
        menu.addItem(helpItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        menu.delegate = self   // menuWillOpen re-reads the system PAC

        statusItem.menu = menu
    }

    func buildProxyConfigMenu() -> NSMenuItem {
        let proxyMenu = NSMenu()

        // Enable/disable toggle — reflect current state
        pacEnabledMenuItem.target = self
        pacEnabledMenuItem.state = isPACEnabled() ? .on : .off
        proxyMenu.addItem(pacEnabledMenuItem)

        proxyMenu.addItem(NSMenuItem.separator())

        // Current PAC URL (read-only display)
        pacCurrentURLMenuItem.isEnabled = false
        pacSourceMenuItem.isEnabled = false
        pacSourceMenuItem.indentationLevel = 1
        pacSystemMenuItem.isEnabled = false
        pacSystemMenuItem.indentationLevel = 1
        updatePACURLMenuItem()
        proxyMenu.addItem(pacCurrentURLMenuItem)
        proxyMenu.addItem(pacSourceMenuItem)
        proxyMenu.addItem(pacSystemMenuItem)

        // Set PAC URL
        pacURLMenuItem.target = self
        proxyMenu.addItem(pacURLMenuItem)

        proxyMenu.addItem(NSMenuItem.separator())
        testURLsMenuItem.target = self
        proxyMenu.addItem(testURLsMenuItem)

        let proxyConfigItem = NSMenuItem(title: "Proxy Configuration", action: nil, keyEquivalent: "")
        proxyConfigItem.submenu = proxyMenu
        return proxyConfigItem
    }

    // MARK: - Refresh

    func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc func refresh() {
        DispatchQueue.main.async {
            self.statusItem.button?.title = "🔄"
            self.ipMenuItem.title = "📡 External IP: Refreshing..."
        }
        proxyChecker.check { [weak self] result in
            DispatchQueue.main.async {
                self?.updateUI(with: result)
            }
        }
    }

    @objc func manualRefresh() { refresh() }

    @objc func toggleAutoRefresh() {
        autoRefreshEnabled.toggle()
        if autoRefreshEnabled {
            startAutoRefresh()
            autoRefreshMenuItem.title = "Auto-refresh: ON"
        } else {
            refreshTimer?.invalidate()
            refreshTimer = nil
            autoRefreshMenuItem.title = "Auto-refresh: OFF"
        }
    }

    // MARK: - Copy IP

    @objc func copyIP() {
        guard let ip = proxyChecker.lastExternalIP, !ip.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)

        let original = statusItem.button?.title
        statusItem.button?.title = "✅ Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.statusItem.button?.title = original ?? ip
        }
    }

    // MARK: - Update UI

    func updateUI(with result: ProxyResult) {
        let ip   = result.externalIP ?? "Unavailable"
        let icon = result.isProxyActive ? "🛡️" : "🌐"
        statusItem.button?.title = "\(icon) \(ip)"

        ipMenuItem.title = "📡 External IP: \(ip)"
        if let hostname = result.hostname, hostname != ip {
            ipMenuItem.toolTip = hostname
        }

        if result.isProxyActive {
            proxyStatusMenuItem.title = "🟢 Proxy Active"
            proxyDetailMenuItem.title = result.proxyDetail ?? ""
            proxyDetailMenuItem.isHidden = false
        } else {
            proxyStatusMenuItem.title = "⚪ No Proxy Configured"
            proxyDetailMenuItem.isHidden = true
        }

        updateProxyServersMenu(result.proxyServers)

        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        lastUpdatedMenuItem.title = "Last updated: \(formatter.string(from: Date()))"
    }

    func updateProxyServersMenu(_ servers: [ProxyServerInfo]) {
        let submenu = NSMenu()

        guard !servers.isEmpty else {
            let item = NSMenuItem(title: "No proxy servers configured", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
            proxyServersMenuItem.title = "Proxy Servers (0 active)"
            proxyServersMenuItem.submenu = submenu
            return
        }

        let enabledCount = servers.filter { $0.isEnabled }.count

        for server in servers {
            let stateIcon = server.isEnabled ? "🟢" : "⚪"

            // Line 1: type, service, configured host:port (or URL for PAC)
            let displayHost: String
            if server.type == "PAC" {
                let url = server.configuredHost
                displayHost = url.count > 45 ? String(url.prefix(42)) + "..." : url
            } else {
                let portSuffix = server.port.isEmpty ? "" : ":\(server.port)"
                displayHost = "\(server.configuredHost)\(portSuffix)"
            }

            let mainItem = NSMenuItem(
                title: "\(stateIcon) \(server.type) [\(server.networkService)]: \(displayHost)",
                action: nil, keyEquivalent: ""
            )
            mainItem.isEnabled = false
            submenu.addItem(mainItem)

            // Line 2 (indented): resolved IP and TTL
            var details: [String] = []
            if let ip = server.resolvedIP {
                details.append("IP: \(ip)")
            }
            if let ttl = server.ttl {
                details.append("TTL: \(ttl)s")
            }
            if let ping = server.ping {
                details.append("ping: \(ping)ms")
            }
            if !details.isEmpty {
                let detailItem = NSMenuItem(title: details.joined(separator: "  |  "), action: nil, keyEquivalent: "")
                detailItem.isEnabled = false
                detailItem.indentationLevel = 1
                submenu.addItem(detailItem)
            }

            submenu.addItem(NSMenuItem.separator())
        }

        // Remove trailing separator
        if submenu.items.last?.isSeparatorItem == true {
            submenu.removeItem(at: submenu.items.count - 1)
        }

        proxyServersMenuItem.title = "Proxy Servers (\(enabledCount) active)"
        proxyServersMenuItem.submenu = submenu
    }

    // MARK: - PAC Proxy Configuration

    /// Returns true if auto proxy (PAC) is enabled on any network service
    func isPACEnabled() -> Bool {
        let services = getNetworkServices()
        for svc in services {
            let out = shell("/usr/sbin/networksetup -getautoproxyurl \"\(svc)\"")
            if out.range(of: "Enabled: Yes", options: .caseInsensitive) != nil {
                return true
            }
        }
        return false
    }

    @objc func togglePAC() {
        let enable = pacEnabledMenuItem.state == .off

        // Require a PAC URL to be set before enabling
        if enable {
            let savedURL = UserDefaults.standard.string(forKey: kPACURL) ?? ""
            if savedURL.isEmpty {
                showAlert("No PAC URL Set", message: "Please set a PAC URL first using \"Set PAC URL...\"")
                return
            }
            applyPACToAllServices(url: savedURL, enabled: true)
            UserDefaults.standard.set(true, forKey: kDiagOnLaunch)
        } else {
            applyPACToAllServices(url: nil, enabled: false)
        }

        pacEnabledMenuItem.state = enable ? .on : .off
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.restartApp() }
    }

    @objc func setPACURL() {
        let alert = NSAlert()
        alert.messageText     = "Set PAC URL"
        alert.informativeText = "Enter the URL of your proxy auto-config file:"
        alert.addButton(withTitle: "Save & Enable")
        alert.addButton(withTitle: "Save Only")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        input.placeholderString = "https://example.com/proxy.pac"
        input.stringValue = UserDefaults.standard.string(forKey: kPACURL) ?? ""
        alert.accessoryView = input

        // Focus the text field
        alert.window.initialFirstResponder = input

        let response = alert.runModal()

        let url = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // A bare hostname ("pac.example.com") is accepted by networksetup
        // but macOS can't fetch it, so every app silently goes DIRECT.
        if response != .alertThirdButtonReturn, !url.isEmpty {
            let u = URL(string: url)
            if u?.host == nil || !["http", "https"].contains(u?.scheme?.lowercased() ?? "") {
                showAlert("Invalid PAC URL", message: "The PAC URL needs http:// or https:// and a path, for example:\n\nhttp://\(url)/proxy.pac")
                return
            }
        }

        switch response {
        case .alertFirstButtonReturn:  // Save & Enable
            guard !url.isEmpty else {
                showAlert("Invalid URL", message: "Please enter a valid PAC URL.")
                return
            }
            UserDefaults.standard.set(url, forKey: kPACURL)
            UserDefaults.standard.set("manual", forKey: kPACSource)
            // We're about to make this the system PAC, so the next sync sees
            // no external change and keeps it labelled "entered manually".
            UserDefaults.standard.set(url, forKey: kPACLastSystem)
            updatePACURLMenuItem()
            applyPACToAllServices(url: url, enabled: true)
            pacEnabledMenuItem.state = .on
            UserDefaults.standard.set(true, forKey: kDiagOnLaunch)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.restartApp() }

        case .alertSecondButtonReturn: // Save Only
            guard !url.isEmpty else { return }
            UserDefaults.standard.set(url, forKey: kPACURL)
            UserDefaults.standard.set("manual", forKey: kPACSource)
            updatePACURLMenuItem()

        default: // Cancel
            break
        }
    }

    /// Apply (or disable) the PAC URL across all network services
    func applyPACToAllServices(url: String?, enabled: Bool) {
        let services = getNetworkServices()
        for svc in services {
            if enabled, let url = url {
                shell("/usr/sbin/networksetup -setautoproxyurl \"\(svc)\" \"\(url)\"")
                shell("/usr/sbin/networksetup -setautoproxystate \"\(svc)\" on")
            } else {
                shell("/usr/sbin/networksetup -setautoproxystate \"\(svc)\" off")
            }
        }
    }

    func getNetworkServices() -> [String] {
        let output = shell("/usr/sbin/networksetup -listallnetworkservices")
        return output
            .components(separatedBy: "\n")
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    /// Reads the PAC URL macOS is configured with. Prefers the effective
    /// settings (primary service, what apps actually get); when PAC is off
    /// those omit the URL, so fall back to the URL still stored per service.
    func systemPAC() -> SystemPAC? {
        if let s = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
           let url = s[kCFNetworkProxiesProxyAutoConfigURLString as String] as? String,
           !url.isEmpty {
            let on = (s[kCFNetworkProxiesProxyAutoConfigEnable as String] as? NSNumber)?.boolValue ?? false
            return SystemPAC(url: url, enabled: on)
        }
        for svc in getNetworkServices() {
            let out = shell("/usr/sbin/networksetup -getautoproxyurl \"\(svc)\"")
            for line in out.components(separatedBy: "\n") where line.hasPrefix("URL: ") {
                let url = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if !url.isEmpty && url != "(null)" {
                    let on = out.range(of: "Enabled: Yes", options: .caseInsensitive) != nil
                    return SystemPAC(url: url, enabled: on)
                }
            }
        }
        return nil
    }

    /// Makes the app's PAC URL follow the system. If the system PAC changed
    /// since the last sync (or this is the first sync), the system's URL
    /// wins and is labelled "from system" — so a stale saved URL can never be
    /// re-applied by "Enable Auto Proxy". A URL entered here stays labelled
    /// "entered manually" until something outside the app changes the system PAC.
    func syncPACFromSystem() {
        let d = UserDefaults.standard
        let sys = systemPAC()
        systemPACSnapshot = sys
        guard let sys = sys else { return }

        let saved = d.string(forKey: kPACURL) ?? ""
        if sys.url != d.string(forKey: kPACLastSystem) || saved.isEmpty {
            d.set(sys.url, forKey: kPACLastSystem)
            if sys.url != saved {
                d.set(sys.url, forKey: kPACURL)
                d.set("system", forKey: kPACSource)
            }
        }
    }

    func updatePACURLMenuItem() {
        let d = UserDefaults.standard
        let url = d.string(forKey: kPACURL) ?? ""
        func short(_ s: String) -> String { s.count > 50 ? String(s.prefix(47)) + "..." : s }

        pacSystemMenuItem.isHidden = true
        if url.isEmpty {
            pacCurrentURLMenuItem.title = "PAC URL: not set"
            pacCurrentURLMenuItem.toolTip = nil
            pacSourceMenuItem.isHidden = true
            return
        }
        pacCurrentURLMenuItem.title = "PAC URL: \(short(url))"
        pacCurrentURLMenuItem.toolTip = url
        pacSourceMenuItem.isHidden = false
        pacSourceMenuItem.title = d.string(forKey: kPACSource) == "manual"
            ? "Source: entered manually" : "Source: from system"

        // A "Save Only" URL that isn't applied yet: show what macOS really uses.
        if let sys = systemPACSnapshot, sys.url != url {
            pacSystemMenuItem.title = "System is using: \(short(sys.url))"
            pacSystemMenuItem.toolTip = sys.url
            pacSystemMenuItem.isHidden = false
        }
    }

    // MARK: - Diagnostics

    @objc func runDiagnostics() {
        if diagnosticsWindow == nil {
            let w = DiagnosticsWindowController()
            w.onFinished = { [weak self] r in
                let icon = r.failures > 0 ? "❌" : (r.warnings > 0 ? "⚠️" : "✅")
                let f = DateFormatter()
                f.timeStyle = .short
                self?.diagnosticsResultItem.title = "\(icon) \(r.summary) (\(f.string(from: r.started)))"
            }
            diagnosticsWindow = w
        }
        diagnosticsWindow?.showAndRun()
    }

    @objc func setTestURLs() {
        let alert = NSAlert()
        alert.messageText = "Diagnostic Test URLs"
        alert.informativeText = "URLs to run through the PAC file, one per line. Add an internal host to check it goes DIRECT. The PAC server itself is always tested."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Reset to Defaults")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 110))
        input.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        input.string = (UserDefaults.standard.stringArray(forKey: ProxyDiagnostics.kTestURLs)
                        ?? ProxyDiagnostics.defaultTestURLs).joined(separator: "\n")
        let scroll = NSScrollView(frame: input.frame)
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = input
        alert.accessoryView = scroll
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let urls = input.string.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { URL(string: $0)?.host != nil }
            UserDefaults.standard.set(urls, forKey: ProxyDiagnostics.kTestURLs)
        case .alertSecondButtonReturn:
            UserDefaults.standard.removeObject(forKey: ProxyDiagnostics.kTestURLs)
        default:
            break
        }
    }

    // MARK: - Launch at Login

    func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            let result = shell("osascript -e 'tell application \"System Events\" to get the name of every login item' 2>/dev/null")
            return result.contains("MacProxyMenuBar")
        }
    }

    @objc func toggleLaunchAtLogin() {
        let enable = launchAtLoginMenuItem.state == .off
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLoginMenuItem.state = enable ? .on : .off
            } catch {
                showAlert("Open at Login", message: "Could not update Login Items:\n\(error.localizedDescription)")
            }
        } else {
            let appPath = Bundle.main.bundlePath
            let action  = enable ? "make login item at end with properties {path:\"\(appPath)\", hidden:false}"
                                 : "delete (every login item whose name is \"MacProxyMenuBar\")"
            shell("osascript -e 'tell application \"System Events\" to \(action)' 2>/dev/null")
            launchAtLoginMenuItem.state = enable ? .on : .off
        }
    }

    // MARK: - Help

    // MARK: - About

    static let repoURL = "https://github.com/baldwinsung/proxy-menubar"

    /// Standard macOS About panel (icon, version, build, copyright from the
    /// bundle) plus credits that say where each piece of data comes from.
    @objc func showAbout() {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let bold = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 4
        let credits = NSMutableAttributedString()
        func add(_ text: String, font: NSFont, link: String? = nil) {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para,
                                                        .foregroundColor: NSColor.labelColor]
            if let link = link, let url = URL(string: link) { attrs[.link] = url }
            credits.append(NSAttributedString(string: text, attributes: attrs))
        }
        add("Shows your public IP and proxy status, and manages the macOS auto-proxy (PAC) setting.\n\n", font: body)
        add("Public IP\n", font: bold)
        add("Pulled from ", font: body)
        add(ProxyChecker.ipServiceHost, font: body, link: ProxyChecker.ipServiceURL.absoluteString)
        add(" over your current proxy settings, so it is the address the internet sees (the proxy's when one is in use). Refreshed every 30 s while auto-refresh is on; click the IP in the menu to copy it.\n\n", font: body)
        add("Other network use\n", font: bold)
        add("A reverse-DNS lookup of that IP, pings to your configured proxy servers, your PAC file, and the diagnostic test URLs when you run Diagnostics.\n\n", font: body)
        add("Privacy\n", font: bold)
        add("No analytics or telemetry. Settings are stored only on this Mac.\n\n", font: body)
        add("Source code (MIT License)", font: body, link: AppDelegate.repoURL)
        add("\nRequires macOS 12 or later.", font: body)

        NSApp.activate(ignoringOtherApps: true)   // menu-bar app: bring the panel to the front
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    // MARK: - Settings migration

    /// The bundle ID changed from Xcode's placeholder on 2026-11-24, which
    /// gives the app a fresh defaults domain. Copy our own keys across once.
    /// (Not sandboxed, so the old domain is readable.)
    func migrateOldSettings() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: kMigratedOldID) else { return }
        d.set(true, forKey: kMigratedOldID)
        guard let old = d.persistentDomain(forName: AppDelegate.oldBundleID) else { return }
        for key in [kPACURL, kPACSource, kPACLastSystem, ProxyDiagnostics.kTestURLs] where d.object(forKey: key) == nil {
            if let v = old[key] { d.set(v, forKey: key) }
        }
    }

    // MARK: - Updates

    var pendingRelease: Updater.Release?

    @objc func checkForUpdates() {
        if let rel = pendingRelease { offerUpdate(rel) } else { runUpdateCheck(quiet: false) }
    }

    func runUpdateCheck(quiet: Bool) {
        if !quiet { updateMenuItem.title = "Checking for Updates…" }
        Updater.latest { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let rel) where rel.build > Updater.currentBuild:
                    self.pendingRelease = rel
                    self.updateMenuItem.title = "⬆︎ Update to \(rel.displayVersion)…"
                    if !quiet { self.offerUpdate(rel) }
                case .success:
                    self.updateMenuItem.title = "Check for Updates…"
                    if !quiet { self.showAlert("You're up to date", message: "MacProxyMenuBar \(Updater.currentDisplayVersion) is the latest version.") }
                case .failure(let err):
                    self.updateMenuItem.title = "Check for Updates…"
                    if !quiet { self.showAlert("Update check failed", message: err.localizedDescription) }
                }
            }
        }
    }

    func offerUpdate(_ rel: Updater.Release) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "MacProxyMenuBar \(rel.displayVersion) is available"
        alert.informativeText = "You have \(Updater.currentDisplayVersion).\n\n\(rel.notes)\n\nInstalling quits the app, replaces it in /Applications (removing any older copy, including SimpleProxyMenuBar) and reopens it. macOS may ask for your password and to allow Local Network access again."
        alert.addButton(withTitle: "Install & Relaunch")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            updateMenuItem.title = "Downloading \(rel.displayVersion)…"
            Updater.install(rel) { [weak self] err in
                guard let err = err else { return }
                DispatchQueue.main.async {
                    self?.updateMenuItem.title = "⬆︎ Update to \(rel.displayVersion)…"
                    self?.showAlert("Update failed", message: err.localizedDescription)
                }
            }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(rel.pageURL)
        default:
            break
        }
    }

    @objc func openGitHub() {
        if let url = URL(string: "https://github.com/baldwinsung") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Helpers

    func restartApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 1 && open \"\(bundlePath)\""]
        task.standardOutput = FileHandle.nullDevice
        task.standardError  = FileHandle.nullDevice
        try? task.run()
        // Do NOT call waitUntilExit — detach so it survives after terminate
        NSApp.terminate(nil)
    }

    @discardableResult
    private func shell(_ command: String) -> String {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments  = ["-c", command]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        try? task.run()
        task.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func showAlert(_ title: String, message: String) {
        let alert = NSAlert()
        alert.messageText     = title
        alert.informativeText = message
        alert.runModal()
    }
}

struct SystemPAC {
    let url: String
    let enabled: Bool
}

extension AppDelegate: NSMenuDelegate {
    /// Re-read the system PAC every time the menu opens, so the PAC line and
    /// the Enable Auto Proxy checkmark reflect changes made outside the app
    /// (System Settings, networksetup, personal_proxy's macos/deploy.yml).
    func menuWillOpen(_ menu: NSMenu) {
        syncPACFromSystem()
        updatePACURLMenuItem()
        pacEnabledMenuItem.state = isPACEnabled() ? .on : .off
    }
}

// MARK: - Updater

/// Releases are published by .github/workflows/build.yml on every push to
/// main, tagged v<MARKETING_VERSION>.<build> where build = git commit count
/// (also the app's CFBundleVersion). Installing runs that release's own
/// install.sh, the same script as the README one-liner.
enum Updater {
    static let repo = "baldwinsung/proxy-menubar"

    struct Release {
        let tag: String           // "v1.1.58"
        let build: Int            // 58
        let displayVersion: String // "1.1 (58)"
        let notes: String
        let pageURL: URL
    }

    static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }
    static var currentDisplayVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "\(v) (\(currentBuild))"
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    static func latest(completion: @escaping (Result<Release, Error>) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MacProxyMenuBar/\(currentBuild)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { return completion(.failure(err)) }
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data = data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = j["tag_name"] as? String, let page = (j["html_url"] as? String).flatMap(URL.init(string:)) else {
                return completion(.failure(UpdateError("No release information from GitHub (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)).")))
            }
            // v1.1.58 -> version 1.1, build 58
            var parts = tag.dropFirst(tag.hasPrefix("v") ? 1 : 0).split(separator: ".").map(String.init)
            guard parts.count >= 2, let build = Int(parts.removeLast()) else {
                return completion(.failure(UpdateError("Unexpected release tag \(tag).")))
            }
            let notes = (j["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            completion(.success(Release(tag: tag, build: build, displayVersion: "\(parts.joined(separator: ".")) (\(build))",
                                        notes: String(notes.prefix(600)), pageURL: page)))
        }.resume()
    }

    /// Downloads the release's install.sh, zip and .sha256 with URLSession
    /// (which follows the system proxy/PAC; a background curl wouldn't),
    /// then runs install.sh on the local zip. install.sh verifies the
    /// checksum, quits this app, swaps the bundle and relaunches it. If
    /// /Applications/MacProxyMenuBar.app isn't writable by this user (e.g.
    /// build.sh installed it with sudo), it runs through osascript's admin
    /// prompt; install.sh then hands ownership back so later updates don't ask.
    static func install(_ rel: Release, completion: @escaping (Error?) -> Void) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacProxyMenuBar-update-\(rel.build)")
        try? FileManager.default.removeItem(at: dir)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return completion(error) }
        let base = "https://github.com/\(repo)/releases/download/\(rel.tag)/"
        let files = ["install.sh", "MacProxyMenuBar.zip", "MacProxyMenuBar.zip.sha256"]
        func fetch(_ i: Int) {
            guard i < files.count else { return run() }
            URLSession.shared.downloadTask(with: URL(string: base + files[i])!) { tmp, resp, err in
                if let err = err { return completion(err) }
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let tmp = tmp else {
                    return completion(UpdateError("Download of \(files[i]) failed (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0))."))
                }
                do { try FileManager.default.moveItem(at: tmp, to: dir.appendingPathComponent(files[i])) } catch { return completion(error) }
                fetch(i + 1)
            }.resume()
        }
        func run() {
            let app = "/Applications/MacProxyMenuBar.app"
            let fm = FileManager.default
            let writable = fm.isWritableFile(atPath: "/Applications") &&
                (!fm.fileExists(atPath: app) || fm.isWritableFile(atPath: app + "/Contents"))
            let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let d = dir.path
            let cmd = "OPEN_AS_UID=\(getuid()) /bin/bash \(q(d + "/install.sh")) --zip \(q(d + "/MacProxyMenuBar.zip")) --sha256 \(q(d + "/MacProxyMenuBar.zip.sha256")) >\(q(d + "/install.log")) 2>&1"
            let p = Process()
            if writable {
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = ["-c", cmd]
            } else {
                let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
            }
            do { try p.run(); completion(nil) } catch { completion(error) }   // install.sh quits this app
        }
        fetch(0)
    }
}
