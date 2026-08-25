import CoreGraphics

/// Design tokens for FluentWork UI. Dark-default semantic colors; no page-level hardcoding.
public enum DesignTokens {
    public enum Color {
        public static let backgroundPrimary = "#0B0F14"
        public static let backgroundSecondary = "#141A22"
        public static let textPrimary = "#F4F7FA"
        public static let textSecondary = "#9AA7B5"
        public static let accent = "#3D8BFF"
        public static let danger = "#FF5C5C"
        public static let success = "#3DCF8E"
        public static let warning = "#F5A524"
        public static let networkBanner = "#1C2430"
    }

    public enum Typography {
        /// Display / room title
        public static let titlePointSize: CGFloat = 20
        /// Body
        public static let bodyPointSize: CGFloat = 16
        /// Secondary / caption
        public static let captionPointSize: CGFloat = 15
    }

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 32
    }

    public enum Motion {
        /// Quick feedback (tap / toggle)
        public static let quickSeconds: Double = 0.15
        /// Standard transition
        public static let standardSeconds: Double = 0.25
        /// Emphasized panel / cover
        public static let emphasizedSeconds: Double = 0.35
    }
}
