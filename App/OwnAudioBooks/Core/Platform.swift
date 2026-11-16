import Foundation

/// Where the app runs. On an Apple-silicon Mac the iPad app runs as is ("Designed for iPad"):
/// no mobile data, a pointer and a keyboard instead of a finger, and a device the servers
/// should see as a Mac.
enum Platform {
    static let isMac = ProcessInfo.processInfo.isiOSAppOnMac
}
