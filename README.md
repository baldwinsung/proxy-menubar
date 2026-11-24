# 🛡️ MacProxyMenuBar

Installs as `/Applications/MacProxyMenuBar.app` (called SimpleProxyMenuBar
before 2026-11-18; `build.sh` removes the old copy, settings carry over). The
Xcode project and target keep the old `SimpleProxyMenuBar` name.

A lightweight native macOS menu bar app that shows your **current proxy IP address** at a glance.

> ⚠️ **Disclaimer:** This software is provided "as is", without warranty of any kind. The author(s) are not liable for any damages or issues arising from the use of this software. Use at your own risk. See [LICENSE](LICENSE) for full details.

> 🤖 **AI Disclosure:** This project was created with assistance from [Claude](https://claude.ai) by Anthropic.

---

## Install / upgrade

```bash
curl -fsSL https://raw.githubusercontent.com/baldwinsung/proxy-menubar/main/install.sh | bash
```

Downloads the latest [release](https://github.com/baldwinsung/proxy-menubar/releases),
checks its SHA-256, quits the running app, removes every previous copy
(including the old `SimpleProxyMenuBar.app`), installs to `/Applications` and
relaunches. It asks for your password only if the old copy is root-owned.
Behind a proxy, `export https_proxy=…` first (curl doesn't read PAC files).

**Upgrading from the menu:** Help → **Check for Updates…** (the app also
checks quietly at launch and retitles the item **⬆︎ Update to …** when one is
out). It downloads the release through your proxy settings and runs the same
`install.sh`. Releases are ad-hoc signed, not notarized, so after an upgrade
macOS may ask again for Local Network access.

**Versions:** `1.1 (58)` = `MARKETING_VERSION` (build number = git commit
count). Every push to `main` that builds publishes release `v1.1.58`.

**Bundle ID** is `com.baldwinsung.MacProxyMenuBar` since 1.1 (was Xcode's
placeholder `com.user.SimpleProxyMenuBar`). The first launch copies the PAC
URL and diagnostic test URLs from the old ID; turn **Preferences → Open at
Login** on again once.

## Features

- **Native Swift** — no dependencies, no Python, no Electron
- Detects proxies using `networksetup` — the same tool macOS uses internally
- Checks all network services for HTTP, HTTPS, SOCKS, and PAC proxies
- Icons: **🛡️** proxy active · **🌐** no proxy
- Click the IP item to **copy to clipboard**
- Auto-refreshes every 30 seconds (toggle on/off)
- Manual refresh with ⌘R
- Reverse DNS hostname lookup
- **🩺 Run Diagnostics… (⌘D)** — does the proxy setup actually work? Runs
  automatically after **Save & Enable** of a PAC URL:
  1. **PAC fetch** — HTTP status, size, time; flags a failed download or a file
     that isn't a PAC (no `FindProxyForURL`)
  2. **PAC evaluation** — runs the PAC through macOS's own engine for each test
     URL and shows `DIRECT` or `PROXY host:port` (and PAC script errors)
  3. **Proxy reachable** — TCP connect to each proxy's port (not ping)
  4. **Proxy works** — a real HTTPS request through each proxy (spots 407/403)
  5. **Egress** — public IP direct vs through the system vs per proxy, and
     whether traffic really goes where the PAC says
  6. **Effective settings** — PAC, WPAD, manual proxies and bypass list as
     macOS applies them now
  - **Local Network permission** — whether macOS lets this app reach LAN
    addresses (macOS 15+ privacy). Denied shows as ❌ with the fix, instead of
    every LAN proxy failing with "Network is down"; waits ~10 s in case the
    Allow prompt is on screen. **Local Network Settings…** in the window opens
    the pane. Browsers need their own permission, which can't be checked or
    granted from here. The app also touches the LAN once at launch so macOS
    asks right after install.
  Results open in a window with **Copy Report**; the menu shows the last
  result. Test URLs are editable under **Proxy Configuration → Set Diagnostic
  Test URLs…** (add an internal host to check it goes DIRECT).
- **PAC URL follows the system** — on launch and every time the menu opens,
  the app reads the PAC URL macOS is using and shows it with its source:
  **from system** (set outside the app — System Settings, `networksetup`,
  Ansible) or **entered manually** (via Set PAC URL…). A Save Only URL that
  isn't applied yet also shows **System is using: …**. When the system PAC
  changes outside the app, the system wins, so Enable Auto Proxy never
  re-applies a stale URL.
- **Preferences** → Open at Login toggle
- **Help** → **About MacProxyMenuBar** (version, where the public IP comes from, what else the app contacts, privacy, source link) and a link to GitHub
- **Public IP source** — fetched from `https://myip.baldwinsung.com` through your current proxy settings, so it shows the address the internet sees; the menu shows "via myip.baldwinsung.com" under the IP
- Hides from Dock (`LSUIElement`) — lives only in the menu bar

## Requirements

- macOS 12.0+
- Xcode 15+

## Setup

```bash
git clone https://github.com/baldwinsung/proxy-menubar.git
cd proxy-menubar
open SimpleProxyMenuBar.xcodeproj
```

1. In Xcode, go to the **SimpleProxyMenuBar** target → **Signing & Capabilities**
2. Set your **Team**
3. Press **⌘R** to build and run

## Build & Install to /Applications

```bash
./build.sh
```

Builds a Release binary with `xcodebuild` (build number = git commit count)
and installs it to `/Applications` using `ditto`, owned by you so the in-app
updater can replace it without a password.

## Project Structure

```
SimpleProxyMenuBar/
├── SimpleProxyMenuBar.xcodeproj/
│   ├── project.pbxproj
│   └── xcshareddata/xcschemes/
│       └── SimpleProxyMenuBar.xcscheme
├── AppDelegate.swift       # Menu bar UI, preferences, help
├── ProxyChecker.swift      # Proxy detection + IP fetching
├── Diagnostics.swift       # Run Diagnostics checks + report window
├── main.swift              # Entry point
├── Assets.xcassets/        # App icon and accent color
├── build.sh                # Build and install to /Applications
├── LICENSE
└── README.md
```

## Screenshots

| Menu bar | Proxy configuration | Proxy server list |
|---|---|---|
| ![Menu bar](screenshots/menu-bar.png) | ![Proxy configuration](screenshots/proxy_configuration.png) | ![Proxy server list](screenshots/proxy-server-list.png) |

## How Proxy Detection Works

Iterates every network service from `networksetup -listallnetworkservices` and checks:

```bash
networksetup -getautoproxyurl       "$svc"   # PAC
networksetup -getwebproxy           "$svc"   # HTTP
networksetup -getsecurewebproxy     "$svc"   # HTTPS
networksetup -getsocksfirewallproxy "$svc"   # SOCKS
```

If any service reports `Enabled: Yes`, the proxy is shown as active with its host, port, and service name — e.g. `HTTPS [Wi-Fi]: 127.0.0.1:7890`.

## Set up your proxy

Manage your proxy with a PAC (proxy auto-config) file. MDN documents the
format, with examples — this one routes by URL pattern:
[Proxy Auto-Configuration (PAC) file — load balancing/routing based on URL patterns](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/Proxy_servers_and_tunneling/Proxy_Auto-Configuration_PAC_file#load_balancingrouting_based_on_url_patterns).
Then set its URL under **Proxy Configuration → Set PAC URL…** and run
**🩺 Run Diagnostics…** to check it.

## License

MIT — see [LICENSE](LICENSE). Free to use, modify, and distribute.

## Disclaimer

This software is provided without warranty. The author(s) accept no liability for any damages, data loss, security issues, or other problems arising from the use of this software. It is your responsibility to ensure it is suitable for your use case.
