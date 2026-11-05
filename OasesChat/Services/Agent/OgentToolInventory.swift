import Foundation

/// What the Ogent rootfs already has installed, for the system prompt.
///
/// Without it the model assumed a blank machine and started most media or
/// scraping tasks with `apk add curl python3 ffmpeg` — even though packages
/// persist in the rootfs. The snapshot is read host-side from the rootfs tree
/// (no guest round trip) and only changes when tools are actually added or
/// removed, so it doesn't churn the prompt cache.
enum OgentToolInventory {
    struct Snapshot: Equatable {
        var commands: [String]
        var pythonModules: [String]
        var previousPackages: [String]
    }

    static let commands = [
        "python3", "pip3", "uv", "curl", "wget", "git", "jq", "openssl", "bash",
        "zip", "unzip", "file", "sqlite3", "ffmpeg", "ffprobe", "yt-dlp", "node", "npm",
    ]

    /// (import name, display name)
    static let pythonModules: [(module: String, label: String)] = [
        ("requests", "requests"), ("httpx", "httpx"), ("aiohttp", "aiohttp"),
        ("websockets", "websockets"), ("PIL", "pillow"), ("Crypto", "pycryptodome"),
        ("bs4", "beautifulsoup4"), ("lxml", "lxml"), ("yaml", "pyyaml"), ("brotli", "brotli"),
        ("mutagen", "mutagen"), ("qrcode", "qrcode"), ("dateutil", "python-dateutil"),
        ("tabulate", "tabulate"), ("yt_dlp", "yt-dlp"), ("numpy", "numpy"),
        ("pandas", "pandas"), ("matplotlib", "matplotlib"),
    ]

    private static let binDirectories = ["usr/local/bin", "usr/bin", "bin", "usr/local/sbin", "usr/sbin", "sbin"]

    static func snapshot(dataURL: URL, fileManager: FileManager = .default) -> Snapshot {
        func exists(_ relative: String) -> Bool {
            fileManager.fileExists(atPath: dataURL.appendingPathComponent(relative).path)
        }

        let installedCommands = commands.filter { command in
            binDirectories.contains { exists("\($0)/\(command)") }
        }

        let sitePackages = pythonSitePackages(dataURL: dataURL, fileManager: fileManager)
        let installedModules = pythonModules.filter { entry in
            sitePackages.contains { dir in
                if fileManager.fileExists(atPath: dir.appendingPathComponent(entry.module).path)
                    || fileManager.fileExists(atPath: dir.appendingPathComponent(entry.module + ".py").path) {
                    return true
                }
                let names = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
                return names.contains { $0.hasPrefix(entry.module + ".") && $0.hasSuffix(".so") }
            }
        }.map(\.label)

        let previousURL = dataURL.appendingPathComponent(String(ISHRootfsService.previousWorldGuestPath.dropFirst()))
        let previous = ((try? String(contentsOf: previousURL, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        return Snapshot(commands: installedCommands, pythonModules: installedModules, previousPackages: previous)
    }

    private static func pythonSitePackages(dataURL: URL, fileManager: FileManager) -> [URL] {
        var result: [URL] = []
        for base in ["usr/lib", "usr/local/lib", "root/.local/lib"] {
            let dir = dataURL.appendingPathComponent(base, isDirectory: true)
            let entries = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in entries where name.hasPrefix("python3") {
                let site = dir.appendingPathComponent(name).appendingPathComponent("site-packages", isDirectory: true)
                if fileManager.fileExists(atPath: site.path) { result.append(site) }
            }
        }
        return result
    }

    static func promptSection(for snapshot: Snapshot) -> String {
        var text = "Linux environment (persistent):\n"
        text += "- The iSH Alpine rootfs keeps every file and every installed package across commands, sessions and app launches. Nothing is wiped between runs, so never reinstall a tool \"to be safe\" and do not run `apk update` unless an install actually fails.\n"
        if snapshot.commands.isEmpty {
            text += "- Installed tools could not be detected; check with `command -v <cmd>` before installing anything.\n"
        } else {
            text += "- Already installed: \(snapshot.commands.joined(separator: ", ")).\n"
        }
        if !snapshot.pythonModules.isEmpty {
            text += "- Python modules already installed: \(snapshot.pythonModules.joined(separator: ", ")).\n"
        }
        text += "- For anything not listed, first check with `command -v <cmd>` (or `python3 -c 'import x'`). If it is really missing, run `ogent-need <command-or-package>` — it installs only what is missing and retries via fast mirrors. Python libraries: prefer `ogent-need py3-<name>`; fall back to `pip install` only for pure-Python packages that have no Alpine package.\n"
        if !snapshot.previousPackages.isEmpty {
            text += "- Packages the user had installed before the last app update (not bundled anymore): \(snapshot.previousPackages.joined(separator: ", ")). Reinstall them with `ogent-need --restore` only when a task needs them.\n"
        }
        return text + "\n"
    }

    // MARK: Cached prompt text

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (at: Date, text: String)?
    private static let cacheLifetime: TimeInterval = 30

    /// Prompt text for the live rootfs, recomputed at most every 30 s.
    static func currentPromptSection() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached, Date().timeIntervalSince(cached.at) < cacheLifetime {
            return cached.text
        }
        let text = promptSection(for: snapshot(dataURL: ISHRootfsManager.dataURL))
        cached = (Date(), text)
        return text
    }
}
