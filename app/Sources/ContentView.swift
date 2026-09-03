// YouTube Full Focus — main window.

import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model = FocusModel()

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    if model.isRunningFromReadOnlyLocation {
                        translocationNotice
                    }
                    statusCard
                    scheduleCard
                    if model.status.isInstalled {
                        setupCard
                    }
                    footer
                }
                .padding(20)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 460, height: 640)
        .sheet(item: $model.report) { report in
            ReportSheet(report: report) { model.report = nil }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            // Re-read disk when the user comes back, so an install or removal
            // done in a terminal is reflected without polling in the background.
            model.refresh()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 3) {
                Text("YouTube Full Focus")
                    .font(.system(size: 20, weight: .semibold))
                Text("Recommandations, Shorts et miniatures masqués dans Safari")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)   // clears the floating window controls
        .padding(.bottom, 18)
    }

    // MARK: - Status

    private var statusCard: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 5) {
                    Text(statusHeadline)
                        .font(.system(size: 15, weight: .semibold))
                    Text(statusDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if case .active(_, let days) = model.status {
                    VStack(spacing: 0) {
                        Text("\(days)")
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(days <= 1 ? "jour" : "jours")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .notInstalled: return .secondary
        case .active, .activeUnknownExpiry: return .green
        case .expired: return .orange
        }
    }

    private var statusHeadline: String {
        switch model.status {
        case .notInstalled: return "Inactif"
        case .active, .activeUnknownExpiry: return "Blocage actif"
        case .expired: return "Période terminée"
        }
    }

    private var statusDetail: String {
        switch model.status {
        case .notInstalled:
            return "Aucun blocage installé. Choisissez une durée ci-dessous pour démarrer."
        case .active(let expiry, _):
            return "Actif jusqu’au \(expiry.formatted(date: .long, time: .omitted)) inclus. "
                 + "Le retrait est verrouillé jusque-là."
        case .activeUnknownExpiry:
            return "Le blocage est en place mais sa date de fin est illisible "
                 + "(installation antérieure). Prolongez-le pour rétablir l’affichage."
        case .expired(let expiry):
            return "La période s’est terminée le \(expiry.formatted(date: .long, time: .omitted)). "
                 + "Le blocage ne s’applique plus et peut être retiré."
        }
    }

    // MARK: - Schedule

    private var scheduleCard: some View {
        Card(title: model.extensionOnly ? "Prolonger" : "Durée du blocage") {
            Picker("", selection: $model.preset) {
                ForEach(DurationPreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.preset == .custom {
                DatePicker(
                    "Fin le",
                    selection: $model.customEndDate,
                    in: Date()...,
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
            } else {
                HStack(spacing: 6) {
                    Text("Fin le")
                        .foregroundStyle(.secondary)
                    Text(model.plannedEndDate.formatted(date: .long, time: .omitted))
                        .fontWeight(.medium)
                }
                .font(.system(size: 12))
            }

            if let reason = model.blockingReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 2)

            HStack(spacing: 10) {
                Button {
                    Task { await model.install() }
                } label: {
                    Text(primaryButtonTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canStart)

                if model.status.isInstalled {
                    Button("Retirer") {
                        Task { await model.uninstall() }
                    }
                    .controlSize(.large)
                    .disabled(model.isWorking || !model.status.canUninstall)
                }
            }

            if model.isWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Opération en cours — autorisez avec votre mot de passe administrateur.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else if model.status.isInstalled && !model.status.canUninstall {
                Label(
                    "Le retrait se débloquera automatiquement le lendemain de la date de fin.",
                    systemImage: "lock.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var primaryButtonTitle: String {
        if model.isWorking { return "Patientez…" }
        return model.status.isInstalled ? "Prolonger le blocage" : "Activer le blocage"
    }

    // MARK: - Post-install setup

    private var setupCard: some View {
        Card(title: "Réglages recommandés") {
            SetupRow(
                icon: "externaldrive.badge.person.crop",
                title: "Accès complet au disque pour /bin/bash",
                detail: "Nécessaire pour que le démon puisse remettre la feuille de style "
                      + "si elle est désactivée dans les réglages de Safari.",
                actionLabel: "Ouvrir les réglages"
            ) {
                let url = URL(string:
                    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
                )!
                NSWorkspace.shared.open(url)
            }

            Divider()

            SetupRow(
                icon: "doc.text",
                title: "Feuille de style Safari",
                detail: "Pour un compte macOS standard, sélectionnez ce fichier une fois dans "
                      + "Safari › Réglages › Avancé › Feuille de style › Autre…",
                actionLabel: "Copier le chemin"
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Paths.styleSheet, forType: .string)
            }
        }
    }

    private var translocationNotice: some View {
        Card {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Déplacez l’app dans Applications")
                        .font(.system(size: 12, weight: .semibold))
                    Text("YouTube Full Focus tourne depuis une image disque ou un dossier en lecture "
                       + "seule. L’installation fonctionnera, mais glissez l’app dans "
                       + "Applications pour la retrouver ensuite.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "arrow.down.app")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var footer: some View {
        HStack {
            Link(
                "Documentation et code source",
                destination: URL(string: "https://github.com/Nathan-massicot/YouTube-Focus-Watchdog")!
            )
            .font(.system(size: 11))
            Spacer()
        }
    }
}

// MARK: - Building blocks

/// A titled, bordered panel — the single container style used on this window.
private struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let title {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09))
        )
    }
}

/// One "here is a manual step you should take" line with a trailing action.
private struct SetupRow: View {
    let icon: String
    let title: String
    let detail: String
    let actionLabel: String
    let action: () -> Void

    @State private var done = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(done ? "✓" : actionLabel) {
                action()
                done = true
                // Momentary confirmation; the row stays usable afterwards.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { done = false }
            }
            .font(.system(size: 11))
        }
    }
}

/// Outcome of an install or removal, with the script transcript folded away.
private struct ReportSheet: View {
    let report: OperationReport
    let dismiss: () -> Void

    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: report.succeeded
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(report.succeeded ? Color.green : Color.orange)
                Text(report.title).font(.system(size: 16, weight: .semibold))
            }

            Text(report.message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !report.log.isEmpty {
                DisclosureGroup("Détail technique", isExpanded: $showLog) {
                    ScrollView {
                        Text(report.log)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 220)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                }
                .font(.system(size: 11))
            }

            HStack {
                Spacer()
                Button("Fermer", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430)
    }
}
