// YouTube Full Focus — view model.
//
// Owns the observed install state and drives the two privileged operations.
// Everything here runs on the main actor; the blocking shell work is pushed to
// a detached task so the window never freezes behind the password prompt.

import Foundation
import SwiftUI

/// The preset lengths offered on the schedule card.
enum DurationPreset: Int, CaseIterable, Identifiable {
    case week = 7
    case fortnight = 14
    case month = 30
    case quarter = 90
    /// Any end date the user picks by hand.
    case custom = -1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .week: return "7 j"
        case .fortnight: return "14 j"
        case .month: return "30 j"
        case .quarter: return "90 j"
        case .custom: return "Date…"
        }
    }
}

/// Result of an install/uninstall run, surfaced in a sheet.
struct OperationReport: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let log: String
    let succeeded: Bool
}

@MainActor
final class FocusModel: ObservableObject {
    @Published private(set) var status: InstallStatus = .notInstalled
    @Published private(set) var isWorking = false
    @Published var report: OperationReport?

    @Published var preset: DurationPreset = .month
    @Published var customEndDate: Date = Calendar.current.date(
        byAdding: .day, value: 30, to: Calendar.current.startOfDay(for: Date())
    ) ?? Date()

    /// True when the app is running from a disk image or a Gatekeeper
    /// translocation sandbox rather than from /Applications.
    let isRunningFromReadOnlyLocation: Bool = {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }()

    init() {
        refresh()
    }

    // MARK: - State

    func refresh() {
        status = Watchdog.probe()
    }

    /// The end date the current selection resolves to, normalised to a day.
    var plannedEndDate: Date {
        let calendar = Calendar.current
        if preset == .custom {
            return calendar.startOfDay(for: customEndDate)
        }
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: preset.rawValue, to: today) ?? today
    }

    /// The end date currently enforced on disk, when it is known.
    var currentExpiry: Date? {
        switch status {
        case .active(let expiry, _), .expired(let expiry): return expiry
        case .notInstalled, .activeUnknownExpiry: return nil
        }
    }

    /// A blocking period can only ever be pushed further out. Allowing a nearer
    /// date would turn the commitment into a one-click escape hatch.
    var extensionOnly: Bool {
        if case .active = status { return true }
        return status == .activeUnknownExpiry
    }

    /// Why the primary button is disabled, or nil when it is usable.
    var blockingReason: String? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        if plannedEndDate <= today {
            return "Choisissez une date postérieure à aujourd’hui."
        }
        if case .active(let expiry, _) = status, plannedEndDate <= calendar.startOfDay(for: expiry) {
            return "Une période est déjà active jusqu’au \(expiry.formatted(date: .long, time: .omitted)). "
                 + "Vous ne pouvez que la prolonger."
        }
        return nil
    }

    var canStart: Bool { !isWorking && blockingReason == nil }

    // MARK: - Operations

    func install() async {
        let dateString = Watchdog.dateParser.string(from: plannedEndDate)
        let isExtension = extensionOnly

        await perform(
            successTitle: isExtension ? "Blocage prolongé" : "Blocage activé",
            successMessage: "YouTube Full Focus applique la feuille de style jusqu’au "
                + "\(plannedEndDate.formatted(date: .long, time: .omitted)) inclus."
        ) {
            try Privileged.runAsRoot(script: "install.sh", arguments: ["--expiry", dateString])
        }
    }

    func uninstall() async {
        await perform(
            successTitle: "Blocage retiré",
            successMessage: "Le démon, la feuille de style et les préférences Safari ont été nettoyés."
        ) {
            try Privileged.runAsRoot(script: "uninstall.sh")
        }
    }

    /// Shared plumbing: run `work` off the main actor, then refresh and report.
    private func perform(
        successTitle: String,
        successMessage: String,
        _ work: @escaping @Sendable () throws -> String
    ) async {
        isWorking = true
        defer {
            isWorking = false
            refresh()
        }

        do {
            let log = try await Task.detached(priority: .userInitiated) {
                try work()
            }.value
            report = OperationReport(
                title: successTitle,
                message: successMessage,
                log: log,
                succeeded: true
            )
        } catch let error as PrivilegedError {
            switch error {
            case .cancelled:
                // Dismissing the password prompt is a normal answer, not an
                // error worth a report sheet.
                break
            case .scriptFailed(let log):
                report = OperationReport(
                    title: "Opération interrompue",
                    message: error.localizedDescription,
                    log: log,
                    succeeded: false
                )
            case .setupFailed:
                report = OperationReport(
                    title: "Opération impossible",
                    message: error.localizedDescription,
                    log: "",
                    succeeded: false
                )
            }
        } catch {
            report = OperationReport(
                title: "Opération impossible",
                message: error.localizedDescription,
                log: "",
                succeeded: false
            )
        }
    }
}
