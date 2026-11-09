import Foundation

/// Looks up `key` in Localizable.strings. The source language is Simplified Chinese
/// (`zh-Hans.lproj`, where each key maps to itself). English lives in `en.lproj`.
/// Shipping only the English table would make macOS treat `en` as the only available
/// localization, so Chinese systems could show English UI. Other languages fall back
/// to the Chinese source strings. Short name because this wraps many call sites.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
