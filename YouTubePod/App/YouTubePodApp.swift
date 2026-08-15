import GoogleSignIn
import SwiftData
import SwiftUI
@preconcurrency import PythonKit

@main
struct YouTubePodApp: App {
    private let container: ModelContainer
    @State private var environment: AppEnvironment

    init() {
        PythonRuntimeBootstrap.configure()
        PythonRuntimeBootstrap.prepareInterpreter()
        do {
            // The released PoC store was created before a VersionedSchema was
            // introduced. Opening that store with a staged migration marks it
            // as an unknown model version. Adding the independent transfer
            // entity through SwiftData's inferred lightweight migration keeps
            // the existing library and playback history intact.
            let container = try ModelContainer(
                for: SavedAudio.self,
                WatchTransferRecord.self
            )
            self.container = container
            _environment = State(initialValue: AppEnvironment(modelContext: container.mainContext))
        } catch {
            fatalError("SwiftData initialization failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
                .task { await environment.start() }
        }
        .modelContainer(container)
    }
}

@MainActor
private enum PythonRuntimeBootstrap {
    private static var isInterpreterPrepared = false

    static func configure() {
        let bundle = Bundle.main
        let pythonRoot = bundle.bundleURL.appendingPathComponent("python")
        let libRoot = pythonRoot.appendingPathComponent("lib")
        guard let versionFolder = try? FileManager.default.contentsOfDirectory(atPath: libRoot.path)
            .first(where: { $0.hasPrefix("python3.") }) else { return }

        let standardLibrary = libRoot.appendingPathComponent(versionFolder).path
        let dynamicLibraries = libRoot.appendingPathComponent(versionFolder).appendingPathComponent("lib-dynload").path
        let packages = bundle.bundleURL.appendingPathComponent("python-packages").path
        let scripts = bundle.bundleURL.appendingPathComponent("PythonRuntime").path

        setenv("PYTHONHOME", pythonRoot.path, 1)
        setenv("PYTHONPATH", [packages, scripts, standardLibrary, dynamicLibraries].joined(separator: ":"), 1)
        if let cache = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            setenv("XDG_CACHE_HOME", cache.path, 1)
        }
    }

    static func prepareInterpreter() {
        guard !isInterpreterPrepared else { return }
        _ = PythonKit.Python.builtins
        CPythonGIL.releaseInitializingThread()
        isInterpreterPrepared = true
    }
}
