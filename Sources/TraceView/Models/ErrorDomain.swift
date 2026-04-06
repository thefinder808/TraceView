import Foundation

enum ErrorDomain: String, CaseIterable, Identifiable {
    case errno = "errno"
    case osStatus = "OSStatus"
    case ioReturn = "IOReturn"
    case machError = "Mach"
    case httpStatus = "HTTP"

    var id: String { rawValue }

    var displayName: String { rawValue }
}
