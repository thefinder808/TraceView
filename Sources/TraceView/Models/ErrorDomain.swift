import Foundation

enum ErrorDomain: String, CaseIterable, Identifiable {
    case errno = "errno"
    case osStatus = "OSStatus"
    case ioReturn = "IOReturn"
    case machError = "Mach"
    case httpStatus = "HTTP"
    // v1.0.6 additions:
    case cfNetwork = "CFNetwork"
    case cocoa = "Cocoa"
    case security = "Security"
    case posixSignal = "POSIX Signal"
    case sqlite = "SQLite"
    case grpc = "gRPC"
    case bonjour = "Bonjour"
    case posixExit = "Exit Code"

    var id: String { rawValue }
    var displayName: String { rawValue }
}
