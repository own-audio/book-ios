import Foundation

extension Float {
    /// A speed as the listener reads it: "1×", "1.25×", "0.75×", with this phone's decimal sign
    /// ("0,75×" in Czech). `String(format: "%.2g")` kept two digits, so 1.75 showed as "1.8×".
    var speedText: String { speedNumber + "×" }

    /// The number alone, for what VoiceOver reads.
    var speedNumber: String { Double(self).formatted(.number.precision(.fractionLength(0...2))) }
}
