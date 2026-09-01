import FactoryKit

/// Example integration of bootstrap surface configuration in app entry point.
///
/// Add this to your `App` or `AppDelegate` during early initialization.

// MARK: - Production Configuration

/// Production apps should not modify the default configuration.
/// The default is `.speakingRoom` and is set in the dependency container.
///
/// Example (no action needed):
/// ```swift
/// @main
/// struct FluentWorkApp: App {
///     var body: some Scene {
///         WindowGroup {
///             ContentView()
///         }
///     }
/// }
/// ```

// MARK: - Debug Configuration (Compile-Time)

#if DEBUG
/// Configure at compile time based on build scheme or preprocessor flags.
///
/// Example: Debug scheme always starts with Daily Read
/// ```swift
/// @main
/// struct FluentWorkApp: App {
///     init() {
///         #if DEBUG
///         DebugBootstrapConfiguration.forceSurface(.dailyRead)
///         #endif
///     }
///     
///     var body: some Scene {
///         WindowGroup {
///             ContentView()
///         }
///     }
/// }
/// ```
#endif

// MARK: - Debug Configuration (Launch Arguments)

#if DEBUG
/// Configure at runtime via Xcode scheme launch arguments.
///
/// Setup:
/// 1. Product > Scheme > Edit Scheme > Run > Arguments
/// 2. Add to "Arguments Passed On Launch":
///    - `--daily-read-first`
///    - `--corpus-first`
///    - `--speaking-room-first`
///
/// Example integration:
/// ```swift
/// @main
/// struct FluentWorkApp: App {
///     init() {
///         #if DEBUG
///         DebugBootstrapConfiguration.configureLaunchArgumentOverride()
///         #endif
///     }
///     
///     var body: some Scene {
///         WindowGroup {
///             ContentView()
///         }
///     }
/// }
/// ```
#endif

// MARK: - Debug Configuration (Debug Menu)

#if DEBUG
/// Configure at runtime via in-app debug menu with persistence.
///
/// Example debug menu view:
/// ```swift
/// struct DebugMenuView: View {
///     @State private var selectedSurface: WorkspaceSurface = .speakingRoom
///     
///     var body: some View {
///         Form {
///             Section("Bootstrap Surface") {
///                 Picker("Initial Surface", selection: $selectedSurface) {
///                     Text("Speaking Room").tag(WorkspaceSurface.speakingRoom)
///                     Text("Daily Read").tag(WorkspaceSurface.dailyRead)
///                     Text("Corpus").tag(WorkspaceSurface.corpus)
///                 }
///                 .onChange(of: selectedSurface) { _, newValue in
///                     UserDefaults.standard.set(newValue.rawValue, forKey: "debug.bootstrap.surface")
///                     DebugBootstrapConfiguration.configureFromUserDefaults()
///                 }
///                 
///                 Button("Reset to Default") {
///                     UserDefaults.standard.removeObject(forKey: "debug.bootstrap.surface")
///                     DebugBootstrapConfiguration.reset()
///                     selectedSurface = .speakingRoom
///                 }
///             }
///         }
///         .navigationTitle("Debug Settings")
///         .onAppear {
///             if let raw = UserDefaults.standard.string(forKey: "debug.bootstrap.surface"),
///                let surface = WorkspaceSurface(rawValue: raw) {
///                 selectedSurface = surface
///             }
///         }
///     }
/// }
/// ```
///
/// App initialization:
/// ```swift
/// @main
/// struct FluentWorkApp: App {
///     init() {
///         #if DEBUG
///         DebugBootstrapConfiguration.configureFromUserDefaults()
///         #endif
///     }
///     
///     var body: some Scene {
///         WindowGroup {
///             ContentView()
///         }
///     }
/// }
/// ```
#endif

// MARK: - Test Configuration

/// Configure in unit and integration tests.
///
/// Example: Test Daily Read surface bootstrap
/// ```swift
/// @Test func dailyReadBootstrapFlow() async throws {
///     let container = Container()
///     container.preferredSurfaceProvider.register {
///         { .dailyRead }
///     }
///     
///     let store = AppStoreFactory.make(container: container)
///     store.dispatch(.lifecycle(.appLaunched))
///     
///     // Wait for bootstrap...
///     
///     #expect(store.state.workspace.activeSurface == .dailyRead)
/// }
/// ```

// MARK: - Advanced: Dynamic Selection

#if DEBUG
/// Example: Select surface based on time of day for dogfooding
/// ```swift
/// extension DebugBootstrapConfiguration {
///     static func configureTimeBasedSurface() {
///         Container.shared.preferredSurfaceProvider.register {
///             {
///                 let hour = Calendar.current.component(.hour, from: Date())
///                 switch hour {
///                 case 6..<12:
///                     return .dailyRead  // Morning: reading
///                 case 12..<18:
///                     return .corpus     // Afternoon: review
///                 default:
///                     return .speakingRoom  // Evening: practice
///                 }
///             }
///         }
///     }
/// }
/// ```
#endif

// MARK: - Advanced: A/B Testing Integration

/// Example: Remote config-driven surface selection
/// ```swift
/// extension Container {
///     var remoteConfigDrivenSurfaceProvider: Factory<@Sendable () -> WorkspaceSurface> {
///         self {
///             {
///                 // Pseudo-code: actual remote config integration would vary
///                 let config = RemoteConfig.shared
///                 if config.bool(forKey: "daily_read_first_experiment") {
///                     return .dailyRead
///                 }
///                 return .speakingRoom
///             }
///         }.singleton
///     }
/// }
/// ```
///
/// Then in bootstrap client factory:
/// ```swift
/// var bootstrapClient: Factory<BootstrapClientProtocol> {
///     self {
///         ResolverBackedBootstrapClient(
///             resolver: self.featureFlagResolver(),
///             preferredSurfaceProvider: self.remoteConfigDrivenSurfaceProvider()
///         )
///     }.singleton
/// }
/// ```
