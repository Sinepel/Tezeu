import Foundation

/// Texte traduit selon la langue du Mac. La clé est le texte français ;
/// les traductions sont dans Resources/<langue>.lproj/Localizable.strings.
/// Sans traduction (ou hors de l'app, ex. SelfCheck), le texte français est affiché.
public func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// Même chose avec des valeurs à insérer (%@, %d, %.1f…), formatées selon la langue du Mac.
public func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}
