//
//  KwotaApp.swift
//  Kwota
//

import SwiftUI
import AppKit
import Combine

@main
struct KwotaApp: App {
    @State private var vm: MenuBarViewModel
    @State private var dockMode: DockIconMode
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let runtimeContext = AppRuntimeContext.current
        _dockMode = State(initialValue: DockIconMode.auto)

        switch runtimeContext {
        case .normalApp:
            let vm = MenuBarViewModel()
            vm.shortcutCoordinator.start()
            _vm = State(initialValue: vm)
            AppDelegate.viewModel = vm
            let mode = DockIconModeStore().mode
            _dockMode = State(initialValue: mode)
            Self.applyInitialActivationPolicy(mode: mode)
        case .hostedTests:
            let vm = Self.makeHostedTestViewModel()
            _vm = State(initialValue: vm)
            AppDelegate.viewModel = vm
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(vm: vm)
        } label: {
            MenuBarIconView(vm: vm)
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView(vm: vm)
                .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                    let newMode = DockIconModeStore().mode
                    guard dockMode != newMode else { return }
                    dockMode = newMode
                    apply(mode: newMode)
                }
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
        .defaultSize(width: 820, height: 560)
    }

    private static func applyInitialActivationPolicy(mode: DockIconMode) {
        let app = NSApplication.shared
        switch mode {
        case .alwaysHide, .auto: app.setActivationPolicy(.accessory)
        case .alwaysShow:        app.setActivationPolicy(.regular)
        }
    }

    @MainActor
    private func apply(mode: DockIconMode) {
        switch mode {
        case .alwaysHide: NSApp.setActivationPolicy(.accessory)
        case .alwaysShow: NSApp.setActivationPolicy(.regular)
        case .auto:
            // Defer to SettingsWindowPresenter: if Settings is open, stay
            // .regular; otherwise drop to .accessory.
            let settingsOpen = NSApp.windows.contains {
                $0.identifier?.rawValue == "settings" && $0.isVisible
            }
            NSApp.setActivationPolicy(settingsOpen ? .regular : .accessory)
        }
    }

    private static func makeHostedTestViewModel() -> MenuBarViewModel {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("kwota-hosted-tests-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let keychain = KeychainCredentialStore(
            service: "com.thanhhaudev.Kwota.hosted-tests.\(UUID().uuidString)"
        )
        let profilesRoot = root.appendingPathComponent("profiles", isDirectory: true)
        let profileStore = ProfileStore(
            profilesFile: root.appendingPathComponent("profiles.json"),
            keychain: keychain,
            profileDirectoryProvider: { id in
                profilesRoot.appendingPathComponent(id.uuidString, isDirectory: true)
            }
        )

        let apiClient = ClaudeAPIClient(transport: { request in
            let url = request.url ?? URL(string: "https://example.invalid")!
            let response = HTTPURLResponse(
                url: url,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        })
        let cliReader = CLICredentialReader(
            credentialsFile: root.appendingPathComponent("missing-credentials.json"),
            keychainProbe: { nil }
        )
        let cliRefresher = CLITokenRefresher(reader: cliReader, store: keychain)
        let accountReader = OAuthAccountReader(
            configFile: root.appendingPathComponent(".claude.json"),
            provider: { nil }
        )
        let registry = ProviderRegistry()
        registry.register(ClaudeProvider(
            apiClient: apiClient,
            cliReader: cliReader,
            cliRefresher: cliRefresher,
            accountReader: accountReader,
            profileFetcher: OAuthProfileFetcher(transport: { request in
                let url = request.url ?? URL(string: "https://example.invalid")!
                let response = HTTPURLResponse(
                    url: url, statusCode: 401, httpVersion: nil, headerFields: nil
                )!
                return (Data(), response)
            }),
            profileStore: profileStore
        ))

        let launcher = NoopProcessLauncher()
        return MenuBarViewModel(
            usage: UsageMonitor(
                reader: FilesystemJSONLogReader(
                    root: root.appendingPathComponent("claude-projects", isDirectory: true)
                ),
                ledgerURL: root.appendingPathComponent("ledger.json")
            ),
            caffeine: CaffeinateManager(),
            probe: ClaudeProbe(launcher: launcher),
            cache: CacheCleaner(targets: [root.appendingPathComponent("cache", isDirectory: true)]),
            profileStore: profileStore,
            credentialStore: keychain,
            apiClient: apiClient,
            cliRefresher: cliRefresher,
            registry: registry,
            shortcutCoordinator: ShortcutCoordinator(),
            battery: HostedTestBatteryMonitor(),
            awakeNotifier: HostedTestNotifier(),
            awakeConfigStore: AwakeConfigStore(
                defaults: UserDefaults(suiteName: "kwota-hosted-\(UUID().uuidString)") ?? .standard
            ),
            startupMode: .hostedTests
        )
    }
}

/// Bridges AppKit's `applicationWillTerminate` so the UsageMonitor's 1s
/// trailing-debounce persist is flushed on clean quit. Without this hook,
/// FSEvents-driven ledger updates that landed within the debounce window
/// before the user quit Kwota are abandoned at process exit; the next
/// launch's JSONL re-walk recovers the events but `readerState` and
/// `lastUpdate` regress. `statsStore.flush()` serves the same purpose for
/// StatsStore: it forces the debounced rollup-and-offset write to complete
/// synchronously so the last token-usage ingest before quit is not lost and,
/// because reader offsets are stored in the same envelope, is not silently
/// re-processed on next launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var viewModel: MenuBarViewModel?

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.viewModel?.usage.stop()
        AppDelegate.viewModel?.statsStore.flush()
    }
}

private struct NoopProcessLauncher: ProcessLauncher {
    func run(executable: String, arguments: [String], environment: [String : String]?) throws -> ProcessResult {
        ProcessResult(stdout: "", stderr: "hosted test noop", exitCode: 1)
    }

    func start(executable: String, arguments: [String], environment: [String : String]?) throws -> ProcessHandle {
        NoopProcessHandle()
    }
}

private final class NoopProcessHandle: ProcessHandle {
    var isRunning: Bool { false }
    func terminate() {}
    func onTermination(_ handler: @escaping @MainActor () -> Void) {}
}

@MainActor
private final class HostedTestBatteryMonitor: BatteryMonitoring {
    private let subject = CurrentValueSubject<BatteryReading, Never>(
        BatteryReading(isOnBattery: false, percent: nil)
    )
    var reading: BatteryReading { subject.value }
    var readingPublisher: AnyPublisher<BatteryReading, Never> {
        subject.eraseToAnyPublisher()
    }
    func start() {}
}

@MainActor
private final class HostedTestNotifier: AwakeNotifying {
    @Published var isPermissionDenied: Bool = false
    var isPermissionDeniedPublisher: AnyPublisher<Bool, Never> {
        $isPermissionDenied.eraseToAnyPublisher()
    }
    func notifyStopped(_ reason: AwakeStopReason) {}
}
