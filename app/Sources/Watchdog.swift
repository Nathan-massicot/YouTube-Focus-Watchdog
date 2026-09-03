// YouTube Full Focus — the bridge between the SwiftUI layer and the shell payload.
//
// The app itself enforces nothing: install.sh, uninstall.sh and the LaunchDaemon
// remain the whole product. This file only (a) reads the deployed state without
// needing root, and (b) runs the bundled scripts as root through the standard
// macOS authorization prompt.

import Foundation

// MARK: - Deployed paths

/// Absolute paths install.sh deploys to. These must mirror install.sh exactly.
enum Paths {
    static let daemonPlist = "/Library/LaunchDaemons/com.focus.youtube.watchdog.plist"
    static let configEnv = "/usr/local/etc/youtube-focus/config.env"
    static let styleSheet = "/usr/local/etc/youtube-focus/youtube-focus.css"
    static let watchdog = "/usr/local/bin/watchdog.sh"
}

// MARK: - Status

/// What the app can determine about the install by reading disk, no root needed.
enum InstallStatus: Equatable {
    /// No LaunchDaemon on disk.
    case notInstalled
    /// Enforcing, and the end date is known.
    case active(expiry: Date, daysRemaining: Int)
    /// Enforcing, but config.env could not be read (an install from before the
    /// installer widened its permissions). Re-installing restores the display.
    case activeUnknownExpiry
    /// The end date has passed: the watchdog no longer enforces and the
    /// uninstaller will accept the request.
    case expired(expiry: Date)

    var isInstalled: Bool { self != .notInstalled }

    /// uninstall.sh refuses to run before the expiry date, so mirror that here
    /// rather than letting the user hit an authorization prompt for nothing.
    var canUninstall: Bool {
        if case .expired = self { return true }
        return false
    }
}

enum Watchdog {
    /// `date -j -f %Y-%m-%d` in the shell scripts parses in the local time zone,
    /// so this formatter has to as well or the two would disagree at midnight.
    static let dateParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    /// Inspects the filesystem and reports the current enforcement state.
    static func probe() -> InstallStatus {
        guard FileManager.default.fileExists(atPath: Paths.daemonPlist) else {
            return .notInstalled
        }
        guard let expiry = readExpiryDate() else {
            return .activeUnknownExpiry
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let lastEnforcedDay = calendar.startOfDay(for: expiry)

        // watchdog.sh stops enforcing only once the date is strictly past, and
        // uninstall.sh unlocks on the same boundary — the expiry day itself is
        // still blocked.
        if today > lastEnforcedDay {
            return .expired(expiry: expiry)
        }

        let days = calendar.dateComponents([.day], from: today, to: lastEnforcedDay).day ?? 0
        return .active(expiry: expiry, daysRemaining: days)
    }

    /// Pulls EXPIRY_DATE out of the deployed config.env without sourcing it.
    static func readExpiryDate() -> Date? {
        guard let contents = try? String(contentsOfFile: Paths.configEnv, encoding: .utf8) else {
            return nil
        }
        for line in contents.split(separator: "\n") {
            guard line.hasPrefix("EXPIRY_DATE=") else { continue }
            // EXPIRY_DATE="2026-09-01"  — take what is between the quotes and
            // ignore any trailing comment.
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            return dateParser.date(from: String(parts[1]))
        }
        return nil
    }
}

// MARK: - Privileged execution

enum PrivilegedError: LocalizedError {
    /// The user dismissed the macOS authorization prompt.
    case cancelled
    /// The script ran but exited non-zero; `log` is its combined output.
    case scriptFailed(log: String)
    /// Something went wrong before the script could even start.
    case setupFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Authentification annulée — rien n’a été modifié."
        case .scriptFailed:
            return "Le script s’est interrompu avant la fin. Détail ci-dessous."
        case .setupFailed(let reason):
            return "Préparation impossible : \(reason)"
        }
    }
}

enum Privileged {
    /// The bundled copy of the shell project (css, watchdog, plist, scripts).
    static var payloadDirectory: URL? {
        Bundle.main.url(forResource: "payload", withExtension: nil)
    }

    /// Runs a bundled bash script as root and returns everything it printed.
    ///
    /// The command is not interpolated into AppleScript source. Instead the app
    /// writes a tiny wrapper into a private temporary directory and passes its
    /// path to osascript as an *argument*, so neither the bundle path (which
    /// contains a space) nor the arguments can break out of their quoting.
    static func runAsRoot(script: String, arguments: [String] = []) throws -> String {
        guard let payload = payloadDirectory else {
            throw PrivilegedError.setupFailed("ressources introuvables dans l’app")
        }
        let scriptURL = payload.appendingPathComponent(script)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw PrivilegedError.setupFailed("\(script) absent de l’app")
        }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("youtube-focus-\(UUID().uuidString)")
        do {
            try fm.createDirectory(
                at: workDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw PrivilegedError.setupFailed(error.localizedDescription)
        }
        defer { try? fm.removeItem(at: workDir) }

        let logURL = workDir.appendingPathComponent("output.log")
        let wrapperURL = workDir.appendingPathComponent("run.sh")

        let quotedArgs = arguments.map(shellQuote).joined(separator: " ")
        let wrapper = """
        #!/bin/bash
        # Generated by YouTube Full Focus.app. Runs the bundled script as root and
        # funnels stdout+stderr into one file the app reads back to the user.
        exec /bin/bash \(shellQuote(scriptURL.path)) \(quotedArgs) > \(shellQuote(logURL.path)) 2>&1

        """
        do {
            try wrapper.write(to: wrapperURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapperURL.path)
        } catch {
            throw PrivilegedError.setupFailed(error.localizedDescription)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "do shell script \"/bin/bash \" & quoted form of (item 1 of argv) with administrator privileges",
            "-e", "end run",
            wrapperURL.path,
        ]

        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw PrivilegedError.setupFailed(error.localizedDescription)
        }

        // Drain before waiting: a full pipe buffer would deadlock the child.
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stderr = String(data: errorData, encoding: .utf8) ?? ""
        let log = stripANSI((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")

        if process.terminationStatus != 0 {
            // AppleScript reports a dismissed authorization dialog as -128.
            if stderr.contains("-128") || stderr.lowercased().contains("user canceled") {
                throw PrivilegedError.cancelled
            }
            throw PrivilegedError.scriptFailed(log: log.isEmpty ? stderr : log)
        }

        return log
    }

    /// Wraps a value in single quotes so bash treats it as one literal argument.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The shell scripts colour their output; strip the escape sequences so the
    /// log reads cleanly in a SwiftUI text view.
    private static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
    }
}
