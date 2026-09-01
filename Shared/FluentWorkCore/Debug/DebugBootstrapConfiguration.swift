import Foundation

#if DEBUG
import FactoryKit

/// Debug-only bootstrap configuration utilities.
///
/// Use these helpers to override the default bootstrap surface for development
/// and testing. Never import this file in release builds.
public enum DebugBootstrapConfiguration {
    
    /// Configure the bootstrap surface based on launch arguments.
    ///
    /// Supported launch arguments:
    /// - `--workbench-first`: Bootstrap with Workbench surface
    /// - `--review-first`: Bootstrap with Review surface
    /// - `--speaking-room-first`: Bootstrap with Speaking Room (default)
    ///
    /// Example Xcode scheme argument:
    /// ```
    /// Product > Scheme > Edit Scheme > Run > Arguments > Arguments Passed On Launch
    /// --workbench-first
    /// ```
    public static func configureLaunchArgumentOverride() {
        Container.shared.preferredSurfaceProvider.register {
            {
                if CommandLine.arguments.contains("--workbench-first") {
                    return .workbench
                }
                if CommandLine.arguments.contains("--review-first") {
                    return .review
                }
                if CommandLine.arguments.contains("--speaking-room-first") {
                    return .speakingRoom
                }
                // Default
                return .speakingRoom
            }
        }
    }
    
    /// Force a specific surface for all bootstrap operations in this session.
    ///
    /// - Parameter surface: The workspace surface to use
    ///
    /// Example usage in `AppDelegate` or test setup:
    /// ```swift
    /// #if DEBUG
    /// DebugBootstrapConfiguration.forceSurface(.workbench)
    /// #endif
    /// ```
    public static func forceSurface(_ surface: WorkspaceSurface) {
        Container.shared.preferredSurfaceProvider.register {
            { surface }
        }
    }
    
    /// Configure surface based on user defaults key (for debug menu persistence).
    ///
    /// Example debug menu integration:
    /// ```swift
    /// UserDefaults.standard.set("workbench", forKey: "debug.bootstrap.surface")
    /// DebugBootstrapConfiguration.configureFromUserDefaults()
    /// ```
    public static func configureFromUserDefaults(key: String = "debug.bootstrap.surface") {
        Container.shared.preferredSurfaceProvider.register {
            {
                guard let rawValue = UserDefaults.standard.string(forKey: key),
                      let surface = WorkspaceSurface(rawValue: rawValue) else {
                    return .speakingRoom
                }
                return surface
            }
        }
    }
    
    /// Reset to production default (`.speakingRoom`).
    public static func reset() {
        Container.shared.preferredSurfaceProvider.reset()
    }
}
#endif
