//
//  StorageFootprintCard.swift
//  Kwota
//

import SwiftUI
import AppKit

struct StorageFootprintCard: View {
    let vm: MenuBarViewModel

    @State private var totalSize: DirectorySize = .zero
    @State private var profilesSize: DirectorySize = .zero
    @State private var historySize: DirectorySize = .zero
    @State private var refreshTrigger: Int = 0

    private struct DirectorySize: Equatable {
        let files: Int
        let bytes: Int
        static let zero = DirectorySize(files: 0, bytes: 0)
    }

    var body: some View {
        let profileCount = vm.profileStore.profiles.count
        return VStack(spacing: 0) {
            SettingsRow(title: "Application data",
                        subtitle: AppPaths.applicationSupportDirectory.path) {
                HStack(spacing: 6) {
                    Text("Total size: \(byteString(totalSize.bytes))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button {
                        copyPath(AppPaths.applicationSupportDirectory.path)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy path")
                }
            }

            SettingsSectionDivider()

            chevronRow(label: "Profiles",
                       detail: "\(profileCount) \(profileCount == 1 ? "profile" : "profiles") · \(byteString(profilesSize.bytes))",
                       url: AppPaths.applicationSupportDirectory.appendingPathComponent("profiles", isDirectory: true))

            SettingsSectionDivider()

            chevronRow(label: "Usage History",
                       detail: "\(historySize.files) \(historySize.files == 1 ? "file" : "files") · \(byteString(historySize.bytes))",
                       url: AppPaths.applicationSupportDirectory)

            HStack {
                Spacer()
                Button {
                    refreshTrigger &+= 1
                } label: {
                    Label("Recompute", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Recompute sizes")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .task(id: refreshTrigger) { await refresh() }
    }

    private func chevronRow(label: String, detail: String, url: URL) -> some View {
        SettingsRow(title: label) {
            HStack(spacing: 8) {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { reveal(url: url) }
        .accessibilityHint("Reveal in Finder")
    }

    private func reveal(url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([AppPaths.applicationSupportDirectory])
            AppLog.shared.log("StorageFootprintCard: reveal target missing at \(url.path), fell back to app support", level: .warn)
        }
    }

    private func copyPath(_ path: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(path, forType: .string)
    }

    @MainActor
    private func refresh() async {
        let appSupport = AppPaths.applicationSupportDirectory
        let profilesDir = appSupport.appendingPathComponent("profiles", isDirectory: true)

        async let total    = Self.directorySize(appSupport)
        async let profiles = Self.directorySize(profilesDir)
        async let history  = Self.historyOnlySize(profilesDir, profileIds: vm.profileStore.profiles.map(\.id))

        let (t, p, h) = await (total, profiles, history)
        totalSize = t
        profilesSize = p
        historySize = h
    }

    private static func directorySize(_ url: URL) async -> DirectorySize {
        await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else { return DirectorySize.zero }
            var files = 0
            var bytes = 0
            let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
            if let it = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
                for case let item as URL in it {
                    if Task.isCancelled { return DirectorySize(files: files, bytes: bytes) }
                    let v = try? item.resourceValues(forKeys: Set(keys))
                    if v?.isRegularFile == true {
                        files += 1
                        bytes += v?.fileSize ?? 0
                    }
                }
            }
            return DirectorySize(files: files, bytes: bytes)
        }.value
    }

    private static func historyOnlySize(_ profilesDir: URL, profileIds: [UUID]) async -> DirectorySize {
        await Task.detached(priority: .utility) {
            var files = 0
            var bytes = 0
            for id in profileIds {
                let f = profilesDir
                    .appendingPathComponent(id.uuidString, isDirectory: true)
                    .appendingPathComponent("usage-history.json")
                if let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                   v.isRegularFile == true {
                    files += 1
                    bytes += v.fileSize ?? 0
                }
            }
            return DirectorySize(files: files, bytes: bytes)
        }.value
    }

    private func byteString(_ n: Int) -> String {
        Int64(n).formatted(ByteFormatters.file)
    }
}
