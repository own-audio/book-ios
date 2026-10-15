import Foundation

/// Repairs text that was UTF-8 once and got read as a single-byte encoding somewhere between
/// the file's tags and the server's database: "Ã¡" for "á", "Ä\u{8d}" for "č". Some servers
/// hold such titles and chapter names (seen on a 2.37 library tagged by old software); fixing
/// them at display time is cheaper than asking every owner to retag.
///
/// Only text that is certainly broken is touched: it must contain one of the lead bytes
/// UTF-8 uses (`Ã`, `Ä`, `Å`, `Â`, `Ø`, `Ð`, `Ñ`, `Þ`, `ß`…) and re-decode cleanly; otherwise
/// the text is returned as it came.
public enum Mojibake {
    private static let suspects: Set<Character> = ["Ã", "Ä", "Å", "Â", "Ø", "Ð", "Ñ", "Þ", "ß", "Ĺ", "Ĺ", "Ĺ", "Å", "Ă", "È", "É", "Ê", "Ë", "Ì", "Í", "Î", "Ï"]

    public static func repair(_ text: String) -> String {
        guard text.contains(where: { suspects.contains($0) }) else { return text }
        // The misreading could have been Latin-1 (most servers) or Windows-1250/1252 (tags
        // written on Windows); try each and keep the first that gives valid UTF-8 with fewer
        // suspicious characters than before.
        let encodings: [String.Encoding] = [.isoLatin1, .windowsCP1252, .windowsCP1250]
        let before = text.filter { suspects.contains($0) }.count
        for encoding in encodings {
            guard let bytes = text.data(using: encoding), let fixed = String(data: bytes, encoding: .utf8), fixed != text else { continue }
            let after = fixed.filter { suspects.contains($0) }.count
            if after < before { return fixed }
        }
        return text
    }

    public static func repair(_ text: String?) -> String? {
        text.map(repair)
    }
}
