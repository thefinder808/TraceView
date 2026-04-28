import Foundation

final class ErrorCodeLookup {
    static let shared = ErrorCodeLookup()

    /// Lookup an error code from any input format (decimal, hex, symbolic name).
    /// Returns all matching interpretations across domains.
    func lookup(input: String) -> [ErrorCodeInfo] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results: [ErrorCodeInfo] = []

        // Try symbolic name lookup first
        results.append(contentsOf: lookupByName(trimmed))

        // Try numeric interpretation
        if let code = parseNumber(trimmed) {
            results.append(contentsOf: lookupByCode(code, hexInput: trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X")))
        }

        // Deduplicate by domain + code
        var seen = Set<String>()
        let deduped = results.filter { info in
            let key = "\(info.domain.rawValue):\(info.code)"
            return seen.insert(key).inserted
        }
        // Conservative reorder: only bumps a domain to top when input has unambiguous signal
        return prioritize(input: trimmed, results: deduped)
    }

    /// Lookup in a specific domain
    func lookup(input: String, domain: ErrorDomain) -> [ErrorCodeInfo] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Try name
        if let info = lookupNameInDomain(trimmed, domain: domain) {
            return [info]
        }

        // Try number
        guard let code = parseNumber(trimmed) else { return [] }

        switch domain {
        case .errno: return lookupErrno(Int32(clamping: code)).map { [$0] } ?? []
        case .osStatus: return lookupOSStatus(Int32(clamping: code)).map { [$0] } ?? []
        case .ioReturn: return lookupIOReturn(UInt32(bitPattern: Int32(clamping: code))).map { [$0] } ?? []
        case .machError: return lookupMachError(Int32(clamping: code)).map { [$0] } ?? []
        case .httpStatus: return lookupHTTPStatus(Int(code)).map { [$0] } ?? []
        case .cfNetwork: return lookupCFNetwork(Int32(clamping: code)).map { [$0] } ?? []
        case .cocoa: return lookupCocoa(Int(code)).map { [$0] } ?? []
        case .security: return lookupSecurity(Int32(clamping: code)).map { [$0] } ?? []
        case .posixSignal: return lookupPOSIXSignal(Int32(clamping: code)).map { [$0] } ?? []
        case .sqlite: return lookupSQLite(Int32(clamping: code)).map { [$0] } ?? []
        case .grpc:
            if code >= 0 && code <= 16 {
                return lookupGRPC(Int32(code)).map { [$0] } ?? []
            }
            return []
        case .bonjour: return lookupBonjour(Int32(clamping: code)).map { [$0] } ?? []
        case .posixExit:
            if code >= 0 && code <= 255 {
                return lookupPOSIXExit(Int(code)).map { [$0] } ?? []
            }
            return []
        }
    }

    // MARK: - Parsing

    private func parseNumber(_ str: String) -> Int64? {
        let s = str.trimmingCharacters(in: .whitespacesAndNewlines)

        // Hex
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            let hex = String(s.dropFirst(2))
            if let val = UInt64(hex, radix: 16) {
                // Handle sign extension for 32-bit values
                if val > UInt64(Int32.max) && val <= UInt64(UInt32.max) {
                    return Int64(Int32(bitPattern: UInt32(val)))
                }
                return Int64(val)
            }
        }

        // Decimal (possibly negative)
        if let val = Int64(s) { return val }

        return nil
    }

    // MARK: - By Name

    private func lookupByName(_ name: String) -> [ErrorCodeInfo] {
        var results: [ErrorCodeInfo] = []
        let upper = name.uppercased()

        for (code, (sym, desc)) in Self.errnoTable {
            if sym.uppercased() == upper {
                results.append(ErrorCodeInfo(domain: .errno, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", code)))
            }
        }
        for (code, (sym, desc)) in Self.osStatusTable {
            if sym.uppercased() == upper {
                results.append(ErrorCodeInfo(domain: .osStatus, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", UInt32(bitPattern: code))))
            }
        }
        for (code, (sym, desc)) in Self.ioReturnTable {
            if sym.uppercased() == upper {
                results.append(ErrorCodeInfo(domain: .ioReturn, code: Int32(bitPattern: code), symbolicName: sym, description: desc, hexValue: String(format: "0x%08X", code)))
            }
        }
        for (code, (sym, desc)) in Self.machErrorTable {
            if sym.uppercased() == upper {
                results.append(ErrorCodeInfo(domain: .machError, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", UInt32(bitPattern: code))))
            }
        }
        for (code, (sym, desc)) in Self.cfNetworkTable {
            if sym.uppercased() == upper {
                results.append(ErrorCodeInfo(domain: .cfNetwork, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", UInt32(bitPattern: code))))
            }
        }
        for (code, (sym, desc)) in Self.cocoaTable {
            if sym.uppercased() == upper {
                results.append(ErrorCodeInfo(domain: .cocoa, code: Int32(clamping: code), symbolicName: sym, description: desc, hexValue: String(format: "0x%X", code)))
            }
        }
        for (code, (sym, desc)) in Self.securityTable {
            if sym.uppercased() == upper {
                results.append(ErrorCodeInfo(domain: .security, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", UInt32(bitPattern: code))))
            }
        }
        for (code, (sym, desc)) in Self.posixSignalTable {
            if sym.uppercased() == upper {
                results.append(ErrorCodeInfo(domain: .posixSignal, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", code)))
            }
        }
        for (code, (sym, desc)) in Self.sqliteTable {
            if sym.uppercased() == upper {
                results.append(ErrorCodeInfo(domain: .sqlite, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", code)))
            }
        }
        for (code, (sym, desc)) in Self.grpcTable {
            if sym.uppercased() == upper {
                results.append(ErrorCodeInfo(domain: .grpc, code: code, symbolicName: sym, description: desc, hexValue: nil))
            }
        }
        for (code, (sym, desc)) in Self.bonjourTable {
            if sym.uppercased() == upper {
                results.append(ErrorCodeInfo(domain: .bonjour, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", UInt32(bitPattern: code))))
            }
        }
        for (code, (sym, desc)) in Self.posixExitTable {
            if sym.uppercased() == upper {
                results.append(ErrorCodeInfo(domain: .posixExit, code: Int32(clamping: code), symbolicName: sym, description: desc, hexValue: String(format: "0x%X", code)))
            }
        }
        return results
    }

    private func lookupNameInDomain(_ name: String, domain: ErrorDomain) -> ErrorCodeInfo? {
        let upper = name.uppercased()
        switch domain {
        case .errno:
            for (code, (sym, desc)) in Self.errnoTable where sym.uppercased() == upper {
                return ErrorCodeInfo(domain: .errno, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", code))
            }
        case .osStatus:
            for (code, (sym, desc)) in Self.osStatusTable where sym.uppercased() == upper {
                return ErrorCodeInfo(domain: .osStatus, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", UInt32(bitPattern: code)))
            }
        case .ioReturn:
            for (code, (sym, desc)) in Self.ioReturnTable where sym.uppercased() == upper {
                return ErrorCodeInfo(domain: .ioReturn, code: Int32(bitPattern: code), symbolicName: sym, description: desc, hexValue: String(format: "0x%08X", code))
            }
        case .machError:
            for (code, (sym, desc)) in Self.machErrorTable where sym.uppercased() == upper {
                return ErrorCodeInfo(domain: .machError, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", UInt32(bitPattern: code)))
            }
        case .httpStatus:
            break
        case .cfNetwork:
            for (code, (sym, desc)) in Self.cfNetworkTable where sym.uppercased() == upper {
                return ErrorCodeInfo(domain: .cfNetwork, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", UInt32(bitPattern: code)))
            }
        case .cocoa:
            for (code, (sym, desc)) in Self.cocoaTable where sym.uppercased() == upper {
                return ErrorCodeInfo(domain: .cocoa, code: Int32(clamping: code), symbolicName: sym, description: desc, hexValue: String(format: "0x%X", code))
            }
        case .security:
            for (code, (sym, desc)) in Self.securityTable where sym.uppercased() == upper {
                return ErrorCodeInfo(domain: .security, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", UInt32(bitPattern: code)))
            }
        case .posixSignal:
            for (code, (sym, desc)) in Self.posixSignalTable where sym.uppercased() == upper {
                return ErrorCodeInfo(domain: .posixSignal, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", code))
            }
        case .sqlite:
            for (code, (sym, desc)) in Self.sqliteTable where sym.uppercased() == upper {
                return ErrorCodeInfo(domain: .sqlite, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", code))
            }
        case .grpc:
            for (code, (sym, desc)) in Self.grpcTable where sym.uppercased() == upper {
                return ErrorCodeInfo(domain: .grpc, code: code, symbolicName: sym, description: desc, hexValue: nil)
            }
        case .bonjour:
            for (code, (sym, desc)) in Self.bonjourTable where sym.uppercased() == upper {
                return ErrorCodeInfo(domain: .bonjour, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", UInt32(bitPattern: code)))
            }
        case .posixExit:
            for (code, (sym, desc)) in Self.posixExitTable where sym.uppercased() == upper {
                return ErrorCodeInfo(domain: .posixExit, code: Int32(clamping: code), symbolicName: sym, description: desc, hexValue: String(format: "0x%X", code))
            }
        }
        return nil
    }

    // MARK: - By Code

    private func lookupByCode(_ value: Int64, hexInput: Bool) -> [ErrorCodeInfo] {
        var results: [ErrorCodeInfo] = []

        let i32 = Int32(clamping: value)
        let u32 = UInt32(bitPattern: i32)

        if let r = lookupErrno(i32) { results.append(r) }
        if let r = lookupOSStatus(i32) { results.append(r) }
        if let r = lookupIOReturn(u32) { results.append(r) }
        if let r = lookupMachError(i32) { results.append(r) }
        if let r = lookupCFNetwork(i32) { results.append(r) }
        if let r = lookupCocoa(Int(value)) { results.append(r) }
        if let r = lookupSecurity(i32) { results.append(r) }
        if let r = lookupPOSIXSignal(i32) { results.append(r) }
        if let r = lookupSQLite(i32) { results.append(r) }
        if value >= 0 && value <= 16 {
            if let r = lookupGRPC(Int32(value)) { results.append(r) }
        }
        if let r = lookupBonjour(i32) { results.append(r) }
        if value >= 0 && value <= 255 {
            if let r = lookupPOSIXExit(Int(value)) { results.append(r) }
        }

        // HTTP status (only for positive values in range)
        if value > 0 && value < 600 {
            if let r = lookupHTTPStatus(Int(value)) { results.append(r) }
        }

        return results
    }

    // MARK: - Prioritization

    /// Conservative reordering: bumps domains to the top only when the input
    /// shows an unambiguous textual or numeric signal. Returns the array
    /// unchanged when no STRONG rule fires — a wrong top-pick is more annoying
    /// than a flat list.
    private func prioritize(input: String, results: [ErrorCodeInfo]) -> [ErrorCodeInfo] {
        guard results.count > 1 else { return results }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        let preferred = strongDomain(for: trimmed)
        guard let preferred else { return results }

        // Stable sort: matches in the preferred domain first, others in original order.
        var preferredResults: [ErrorCodeInfo] = []
        var rest: [ErrorCodeInfo] = []
        for r in results {
            if r.domain == preferred {
                preferredResults.append(r)
            } else {
                rest.append(r)
            }
        }
        return preferredResults + rest
    }

    /// Returns the unambiguous domain hinted by the input string, or nil if
    /// the input doesn't fire any STRONG rule. Order of checks matters: more
    /// specific patterns first.
    private func strongDomain(for input: String) -> ErrorDomain? {
        // Symbol-based rules (case-sensitive checks before case-insensitive)
        if input.hasPrefix("errSec") { return .security }

        let upper = input.uppercased()
        if upper.hasPrefix("SIG") { return .posixSignal }
        if upper.hasPrefix("SQLITE_") { return .sqlite }
        if upper.hasPrefix("KDNSSERVICEERR_") { return .bonjour }
        if upper.hasPrefix("NSURL") || upper.hasPrefix("KCFERROR") { return .cfNetwork }
        if upper.hasPrefix("EX_") { return .posixExit }
        // ^E[A-Z]+$ → errno (e.g. EACCES, ENOENT) — matches AFTER EX_ to avoid stealing those
        if upper.range(of: #"^E[A-Z]+$"#, options: .regularExpression) != nil {
            return .errno
        }

        // Numeric rules
        // Hex with sign-extended OSStatus pattern (0x8XXXXXXX)
        if input.hasPrefix("0x") || input.hasPrefix("0X") {
            let hex = String(input.dropFirst(2))
            if let val = UInt64(hex, radix: 16) {
                // OSStatus pattern: high bit set, 8-digit (0x80000000 .. 0x8FFFFFFF)
                if hex.count == 8, val >= 0x80000000, val <= 0x8FFFFFFF {
                    return .osStatus
                }
                // IOReturn pattern: 0xE00002XX
                if val >= 0xE0000200, val <= 0xE00002FF {
                    return .ioReturn
                }
            }
        }

        // Decimal with no prefix
        if let val = Int64(input) {
            // HTTP range
            if val >= 100, val <= 599 {
                return .httpStatus
            }
            // CFNetwork negative range
            if val < 0, val >= -3010 {
                return .cfNetwork
            }
        }

        return nil
    }

    // MARK: - Domain Lookups

    func lookupErrno(_ code: Int32) -> ErrorCodeInfo? {
        guard let (sym, desc) = Self.errnoTable[code] else { return nil }
        return ErrorCodeInfo(domain: .errno, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", code))
    }

    func lookupOSStatus(_ code: Int32) -> ErrorCodeInfo? {
        guard let (sym, desc) = Self.osStatusTable[code] else { return nil }
        return ErrorCodeInfo(domain: .osStatus, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", UInt32(bitPattern: code)))
    }

    func lookupIOReturn(_ code: UInt32) -> ErrorCodeInfo? {
        guard let (sym, desc) = Self.ioReturnTable[code] else { return nil }
        return ErrorCodeInfo(domain: .ioReturn, code: Int32(bitPattern: code), symbolicName: sym, description: desc, hexValue: String(format: "0x%08X", code))
    }

    func lookupMachError(_ code: Int32) -> ErrorCodeInfo? {
        guard let (sym, desc) = Self.machErrorTable[code] else { return nil }
        return ErrorCodeInfo(domain: .machError, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", UInt32(bitPattern: code)))
    }

    func lookupHTTPStatus(_ code: Int) -> ErrorCodeInfo? {
        guard let (sym, desc) = Self.httpStatusTable[code] else { return nil }
        return ErrorCodeInfo(domain: .httpStatus, code: Int32(code), symbolicName: sym, description: desc, hexValue: nil)
    }

    func lookupCFNetwork(_ code: Int32) -> ErrorCodeInfo? {
        guard let (sym, desc) = Self.cfNetworkTable[code] else { return nil }
        return ErrorCodeInfo(domain: .cfNetwork, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", UInt32(bitPattern: code)))
    }

    func lookupCocoa(_ code: Int) -> ErrorCodeInfo? {
        guard let (sym, desc) = Self.cocoaTable[code] else { return nil }
        return ErrorCodeInfo(domain: .cocoa, code: Int32(clamping: code), symbolicName: sym, description: desc, hexValue: String(format: "0x%X", code))
    }

    func lookupSecurity(_ code: Int32) -> ErrorCodeInfo? {
        guard let (sym, desc) = Self.securityTable[code] else { return nil }
        return ErrorCodeInfo(domain: .security, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", UInt32(bitPattern: code)))
    }

    func lookupPOSIXSignal(_ code: Int32) -> ErrorCodeInfo? {
        guard let (sym, desc) = Self.posixSignalTable[code] else { return nil }
        return ErrorCodeInfo(domain: .posixSignal, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", code))
    }

    func lookupSQLite(_ code: Int32) -> ErrorCodeInfo? {
        guard let (sym, desc) = Self.sqliteTable[code] else { return nil }
        return ErrorCodeInfo(domain: .sqlite, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", code))
    }

    func lookupGRPC(_ code: Int32) -> ErrorCodeInfo? {
        guard let (sym, desc) = Self.grpcTable[code] else { return nil }
        return ErrorCodeInfo(domain: .grpc, code: code, symbolicName: sym, description: desc, hexValue: nil)
    }

    func lookupBonjour(_ code: Int32) -> ErrorCodeInfo? {
        guard let (sym, desc) = Self.bonjourTable[code] else { return nil }
        return ErrorCodeInfo(domain: .bonjour, code: code, symbolicName: sym, description: desc, hexValue: String(format: "0x%X", UInt32(bitPattern: code)))
    }

    func lookupPOSIXExit(_ code: Int) -> ErrorCodeInfo? {
        guard let (sym, desc) = Self.posixExitTable[code] else { return nil }
        return ErrorCodeInfo(domain: .posixExit, code: Int32(clamping: code), symbolicName: sym, description: desc, hexValue: String(format: "0x%X", code))
    }

    // MARK: - Error Code Tables

    static let errnoTable: [Int32: (String, String)] = [
        1: ("EPERM", "Operation not permitted"),
        2: ("ENOENT", "No such file or directory"),
        3: ("ESRCH", "No such process"),
        4: ("EINTR", "Interrupted system call"),
        5: ("EIO", "Input/output error"),
        6: ("ENXIO", "Device not configured"),
        7: ("E2BIG", "Argument list too long"),
        8: ("ENOEXEC", "Exec format error"),
        9: ("EBADF", "Bad file descriptor"),
        10: ("ECHILD", "No child processes"),
        11: ("EDEADLK", "Resource deadlock avoided"),
        12: ("ENOMEM", "Cannot allocate memory"),
        13: ("EACCES", "Permission denied"),
        14: ("EFAULT", "Bad address"),
        15: ("ENOTBLK", "Block device required"),
        16: ("EBUSY", "Resource busy"),
        17: ("EEXIST", "File exists"),
        18: ("EXDEV", "Cross-device link"),
        19: ("ENODEV", "Operation not supported by device"),
        20: ("ENOTDIR", "Not a directory"),
        21: ("EISDIR", "Is a directory"),
        22: ("EINVAL", "Invalid argument"),
        23: ("ENFILE", "Too many open files in system"),
        24: ("EMFILE", "Too many open files"),
        25: ("ENOTTY", "Inappropriate ioctl for device"),
        26: ("ETXTBSY", "Text file busy"),
        27: ("EFBIG", "File too large"),
        28: ("ENOSPC", "No space left on device"),
        29: ("ESPIPE", "Illegal seek"),
        30: ("EROFS", "Read-only file system"),
        31: ("EMLINK", "Too many links"),
        32: ("EPIPE", "Broken pipe"),
        33: ("EDOM", "Numerical argument out of domain"),
        34: ("ERANGE", "Result too large"),
        35: ("EAGAIN", "Resource temporarily unavailable"),
        36: ("EINPROGRESS", "Operation now in progress"),
        37: ("EALREADY", "Operation already in progress"),
        38: ("ENOTSOCK", "Socket operation on non-socket"),
        39: ("EDESTADDRREQ", "Destination address required"),
        40: ("EMSGSIZE", "Message too long"),
        41: ("EPROTOTYPE", "Protocol wrong type for socket"),
        42: ("ENOPROTOOPT", "Protocol not available"),
        43: ("EPROTONOSUPPORT", "Protocol not supported"),
        44: ("ESOCKTNOSUPPORT", "Socket type not supported"),
        45: ("ENOTSUP", "Operation not supported"),
        46: ("EPFNOSUPPORT", "Protocol family not supported"),
        47: ("EAFNOSUPPORT", "Address family not supported by protocol family"),
        48: ("EADDRINUSE", "Address already in use"),
        49: ("EADDRNOTAVAIL", "Can't assign requested address"),
        50: ("ENETDOWN", "Network is down"),
        51: ("ENETUNREACH", "Network is unreachable"),
        52: ("ENETRESET", "Network dropped connection on reset"),
        53: ("ECONNABORTED", "Software caused connection abort"),
        54: ("ECONNRESET", "Connection reset by peer"),
        55: ("ENOBUFS", "No buffer space available"),
        56: ("EISCONN", "Socket is already connected"),
        57: ("ENOTCONN", "Socket is not connected"),
        58: ("ESHUTDOWN", "Can't send after socket shutdown"),
        59: ("ETOOMANYREFS", "Too many references: can't splice"),
        60: ("ETIMEDOUT", "Operation timed out"),
        61: ("ECONNREFUSED", "Connection refused"),
        62: ("ELOOP", "Too many levels of symbolic links"),
        63: ("ENAMETOOLONG", "File name too long"),
        64: ("EHOSTDOWN", "Host is down"),
        65: ("EHOSTUNREACH", "No route to host"),
        66: ("ENOTEMPTY", "Directory not empty"),
        67: ("EPROCLIM", "Too many processes"),
        68: ("EUSERS", "Too many users"),
        69: ("EDQUOT", "Disc quota exceeded"),
        70: ("ESTALE", "Stale NFS file handle"),
        71: ("EREMOTE", "Too many levels of remote in path"),
        72: ("EBADRPC", "RPC struct is bad"),
        73: ("ERPCMISMATCH", "RPC version wrong"),
        74: ("EPROGUNAVAIL", "RPC prog. not avail"),
        75: ("EPROGMISMATCH", "Program version wrong"),
        76: ("EPROCUNAVAIL", "Bad procedure for program"),
        77: ("ENOLCK", "No locks available"),
        78: ("ENOSYS", "Function not implemented"),
        79: ("EFTYPE", "Inappropriate file type or format"),
        80: ("EAUTH", "Authentication error"),
        81: ("ENEEDAUTH", "Need authenticator"),
        82: ("EPWROFF", "Device power is off"),
        83: ("EDEVERR", "Device error"),
        84: ("EOVERFLOW", "Value too large to be stored in data type"),
        85: ("EBADEXEC", "Bad executable"),
        86: ("EBADARCH", "Bad CPU type in executable"),
        87: ("ESHLIBVERS", "Shared library version mismatch"),
        88: ("EBADMACHO", "Malformed Macho file"),
        89: ("ECANCELED", "Operation canceled"),
        90: ("EIDRM", "Identifier removed"),
        91: ("ENOMSG", "No message of desired type"),
        92: ("EILSEQ", "Illegal byte sequence"),
        93: ("ENOATTR", "Attribute not found"),
        94: ("EBADMSG", "Bad message"),
        95: ("EMULTIHOP", "Reserved"),
        96: ("ENODATA", "No message available on STREAM"),
        97: ("ENOLINK", "Reserved"),
        98: ("ENOSR", "No STREAM resources"),
        99: ("ENOSTR", "Not a STREAM"),
        100: ("EPROTO", "Protocol error"),
        101: ("ETIME", "STREAM ioctl timeout"),
        102: ("EOPNOTSUPP", "Operation not supported on socket"),
        103: ("ENOPOLICY", "No such policy registered"),
        104: ("ENOTRECOVERABLE", "State not recoverable"),
        105: ("EOWNERDEAD", "Previous owner died"),
        106: ("EQFULL", "Interface output queue is full"),
        107: ("ENOTCAPABLE", "Capabilities insufficient"),
    ]

    // OSStatus is a sprawling namespace; this covers commonly-hit codes
    // across Carbon/File Manager, Memory Manager, Resource Manager, Sound
    // Manager, AppleEvents, Audio HAL, LaunchServices, Security, and Code
    // Signing. Sourced from MacErrors.h (CarbonCore), CoreAudioTypes.h,
    // SecBase.h, and LaunchServices headers.
    static let osStatusTable: [Int32: (String, String)] = [
        0: ("noErr", "No error"),

        // Queue / core
        -1:  ("qErr", "Queue element not found during deletion"),
        -2:  ("vTypErr", "Invalid queue element"),
        -3:  ("corErr", "Core routine number out of range"),
        -4:  ("unimpErr", "Unimplemented core routine"),

        // I/O System
        -17: ("controlErr", "Driver can't respond to Control call"),
        -18: ("statusErr", "Driver can't respond to Status call"),
        -19: ("readErr", "Driver can't respond to Read call"),
        -20: ("writErr", "Driver can't respond to Write call"),
        -21: ("badUnitErr", "Driver reference number does not match unit table"),
        -22: ("unitEmptyErr", "Driver reference number specifies nil handle"),
        -23: ("openErr", "Requested read/write permission doesn't match driver's open permission"),
        -24: ("closErr", "Close failed"),
        -25: ("dRemovErr", "Tried to remove an open driver"),
        -27: ("abortErr", "I/O call aborted by KillIO"),
        -28: ("notOpenErr", "Driver not opened"),

        // File Manager
        -33: ("dirFulErr", "Directory full"),
        -34: ("dskFulErr", "Disk full"),
        -35: ("nsvErr", "No such volume"),
        -36: ("ioErr", "I/O error"),
        -37: ("bdNamErr", "Bad file name"),
        -38: ("fnOpnErr", "File not open"),
        -39: ("eofErr", "End of file"),
        -40: ("posErr", "Tried to position before start of file"),
        -41: ("mFulErr", "Memory full (open) or file won't fit (load)"),
        -42: ("tmfoErr", "Too many files open"),
        -43: ("fnfErr", "File not found"),
        -44: ("wPrErr", "Diskette is write protected"),
        -45: ("fLckdErr", "File is locked"),
        -46: ("vLckdErr", "Volume is locked"),
        -47: ("fBsyErr", "File is busy (delete)"),
        -48: ("dupFNErr", "Duplicate filename and version"),
        -49: ("opWrErr", "File already open with write permission"),
        -50: ("paramErr", "Error in user parameter list"),
        -51: ("rfNumErr", "Reference number invalid"),
        -52: ("gfpErr", "Get file position error"),
        -53: ("volOffLinErr", "Volume not on line"),
        -54: ("permErr", "Permissions error (on file open)"),
        -55: ("volOnLinErr", "Volume already on-line"),
        -56: ("nsDrvErr", "No such drive"),
        -57: ("noMacDskErr", "Not a Macintosh disk"),
        -58: ("extFSErr", "Volume in question belongs to an external file system"),
        -59: ("fsRnErr", "File system internal error"),
        -60: ("badMDBErr", "Bad master directory block"),
        -61: ("wrPermErr", "Write permissions error"),
        -64: ("noDriveErr", "Drive not installed"),
        -120: ("dirNFErr", "Directory not found"),
        -122: ("badMovErr", "Move into offspring error"),
        -123: ("wrgVolTypErr", "Not an HFS volume"),
        -127: ("fsDSIntErr", "Internal file system error"),
        -128: ("userCanceledErr", "User canceled"),

        // Memory Manager
        -108: ("memFullErr", "Not enough memory"),
        -109: ("nilHandleErr", "Handle was NIL"),
        -110: ("memAdrErr", "Address was odd or too big"),
        -111: ("memWZErr", "WhichZone failed (applied to free block)"),
        -112: ("memPurErr", "Trying to purge a locked or non-purgeable block"),
        -113: ("memAZErr", "Address in zone check failed"),
        -114: ("memPCErr", "Pointer check failed"),
        -117: ("memLockedErr", "Trying to move a locked block (MoveHHi)"),

        // Resource Manager
        -185: ("badExtResource", "Extended resource has a bad format"),
        -186: ("CantDecompress", "Resource bent (compressed) data could not be decompressed"),
        -188: ("resourceInMemory", "Resource already in memory"),
        -189: ("writingPastEnd", "Writing past end of file"),
        -192: ("resNotFound", "Resource not found"),
        -193: ("resFNotFound", "Resource file not found"),
        -194: ("addResFailed", "AddResource failed"),
        -195: ("addRefFailed", "AddReference failed"),
        -196: ("rmvResFailed", "RmveResource failed"),
        -197: ("rmvRefFailed", "RmveReference failed"),
        -198: ("resAttrErr", "Attribute inconsistent with operation"),
        -199: ("mapReadErr", "Map inconsistent with operation"),

        // AppleEvents
        -1700: ("errAECoercionFail", "Data could not be coerced to the requested descriptor type"),
        -1701: ("errAEDescNotFound", "Descriptor not found"),
        -1703: ("errAEWrongDataType", "Wrong descriptor type"),
        -1704: ("errAENotAEDesc", "Not a valid AEDesc"),
        -1708: ("errAEEventNotHandled", "Event wasn't handled by an Apple event handler"),
        -1712: ("errAETimeout", "Apple event timed out"),
        -1713: ("errAENoUserInteraction", "No user interaction allowed"),

        // LaunchServices
        -10660: ("kLSAppInTrashErr", "Application cannot be run when inside a Trash folder"),
        -10810: ("kLSUnknownErr", "Launch Services unknown error"),
        -10811: ("kLSNotAnApplicationErr", "Item is not an application"),
        -10813: ("kLSDataUnavailableErr", "Data unavailable (e.g. no kind string)"),
        -10814: ("kLSApplicationNotFoundErr", "No application in the LS database matches the input criteria"),
        -10817: ("kLSDataErr", "Data is structured improperly"),
        -10818: ("kLSLaunchInProgressErr", "Attempted to launch an already-launching application"),
        -10822: ("kLSServerCommunicationErr", "Launch Services could not communicate with lsd"),
        -10823: ("kLSCannotSetInfoErr", "Cannot set application information"),
        -10827: ("kLSIncompatibleApplicationVersionErr", "App incompatible with this version of macOS"),
        -10828: ("kLSNoRosettaEnvironmentErr", "The app can't be run because Rosetta is not installed"),

        // Sound Manager
        -200: ("noHardwareErr", "Required sound hardware not available"),
        -201: ("notEnoughHardwareErr", "Required sound hardware resources not available"),

        // Core Audio HAL (AudioHardware.h)
        -10846: ("kAudioHardwareNotRunningError", "Audio hardware not running"),
        -10847: ("kAudioHardwareUnexpectedFileFormatError", "Unexpected file format"),
        -10848: ("kAudioHardwareIllegalOperationError", "Illegal operation"),
        -10849: ("kAudioHardwareBadObjectError", "Bad AudioObjectID"),
        -10850: ("kAudioHardwareBadDeviceError", "Bad AudioDeviceID"),
        -10851: ("kAudioHardwareBadStreamError", "Bad AudioStreamID"),
        -10852: ("kAudioHardwareUnsupportedOperationError", "Unsupported operation"),
        -10853: ("kAudioHardwareNotReadyError", "Audio object not ready"),
        -10863: ("kAudioHardwareUnspecifiedError", "Unspecified audio hardware error"),
        -10864: ("kAudioHardwareUnknownPropertyError", "Audio object doesn't know about the property"),
        -10865: ("kAudioHardwareBadPropertySizeError", "Bad property size"),
        -10866: ("kAudioHardwareIllegalOperationError", "Illegal operation on audio object"),
        -10867: ("kAudioHardwareBadObjectError_Legacy", "Legacy bad object error"),
        -10875: ("kAudioUnitErr_InvalidProperty", "Invalid audio unit property"),
        -10877: ("kAudioUnitErr_InvalidElement", "Invalid audio unit element"),

        // Security framework / Keychain
        // NOTE: -25240..-25245 were previously misattributed to errSec* names
        // that actually belong to other codes per SecBase.h. Removed in v1.0.6
        // since the new securityTable now provides authoritative entries for
        // those codes (errSecACLNotSimple/PolicyNotFound/etc.). The remaining
        // -25260..-25265 entries below are flagged for follow-up audit; they
        // may also be misattributed.
        -25260: ("errSecReadOnlyAttr", "The specified attribute could not be modified"),
        -25261: ("errSecWrongSecVersion", "Wrong security version"),
        -25262: ("errSecKeySizeNotAllowed", "This item's key's size is not allowed for this algorithm"),
        -25263: ("errSecNoStorageModule", "There is no storage module available"),
        -25264: ("errSecNoCertificateModule", "There is no certificate module available"),
        -25265: ("errSecNoPolicyModule", "There is no policy module available"),
        -25291: ("errSecNotAvailable", "No keychain is available"),
        -25292: ("errSecReadOnly", "Read-only error"),
        -25293: ("errSecAuthFailed", "Authorization/authentication failed"),
        -25294: ("errSecNoSuchKeychain", "No such keychain"),
        -25295: ("errSecInvalidKeychain", "The keychain is not valid"),
        -25296: ("errSecDuplicateKeychain", "A keychain with the same name already exists"),
        -25297: ("errSecDuplicateCallback", "The specified callback is already installed"),
        -25298: ("errSecInvalidCallback", "The specified callback is not valid"),
        -25299: ("errSecDuplicateItem", "Duplicate item in keychain"),
        -25300: ("errSecItemNotFound", "Item not found in keychain"),
        -25301: ("errSecBufferTooSmall", "Buffer too small"),
        -25303: ("errSecNoSuchAttr", "The attribute does not exist"),
        -25304: ("errSecInvalidItemRef", "The item reference is invalid"),
        -25305: ("errSecInvalidSearchRef", "The search reference is invalid"),
        -25306: ("errSecNoSuchClass", "The keychain item class does not exist"),
        -25307: ("errSecNoDefaultKeychain", "A default keychain does not exist"),
        -25308: ("errSecInteractionNotAllowed", "User interaction is not allowed"),
        -25316: ("errSecDataNotAvailable", "Data is not available"),
        -25317: ("errSecDataNotModifiable", "Data is not modifiable"),
        -25318: ("errSecCreateChainFailed", "Creating a chain failed"),
        -26275: ("errSecDecode", "Unable to decode the provided data"),

        // Code Signing (SecCodeRef)
        -67028: ("errSecCSOutdated", "The rules database is out of date"),
        -67029: ("errSecCSInvalidObjectRef", "Invalid API object reference"),
        -67030: ("errSecCSUnsigned", "Code is not signed"),
        -67031: ("errSecCSSignatureFailed", "Code signature validation failed"),
        -67032: ("errSecCSSignatureNotVerifiable", "Signature cannot be read"),
        -67033: ("errSecCSSignatureUnsupported", "Unsupported signature format"),
        -67034: ("errSecCSBadDictionaryFormat", "Property-list dictionary is invalid"),
        -67035: ("errSecCSResourcesNotSealed", "Resources not sealed by signature"),
        -67036: ("errSecCSResourcesNotFound", "Code has no resources"),
        -67037: ("errSecCSResourcesInvalid", "Resource directory is invalid"),
        -67038: ("errSecCSBadResource", "A sealed resource is invalid, missing, or modified"),
        -67039: ("errSecCSResourceRulesInvalid", "Resource rules are invalid"),
        -67040: ("errSecCSReqInvalid", "Code requirement is invalid"),
        -67041: ("errSecCSReqUnsupported", "Code requirement format is unsupported"),
        -67042: ("errSecCSReqFailed", "Code failed a requirement"),
        -67043: ("errSecCSBadObjectFormat", "Invalid object format"),
        -67044: ("errSecCSInternalError", "Internal code signing error"),
        -67045: ("errSecCSHostReject", "Code was rejected by host"),
        -67046: ("errSecCSNotAHost", "Not a host"),
        -67047: ("errSecCSSignatureInvalid", "Invalid code signature"),
        -67048: ("errSecCSHostProtocolRelativePath", "Relative path in host protocol"),
        -67049: ("errSecCSHostProtocolContradiction", "Host protocol contradiction"),
        -67050: ("errSecCSHostProtocolDedicationError", "Dedication error in host protocol"),
        -67051: ("errSecCSHostProtocolNotProxy", "Not a proxy host"),
        -67052: ("errSecCSHostProtocolStateError", "Host protocol state error"),
        -67053: ("errSecCSHostProtocolUnrelated", "Host protocol unrelated"),
        -67060: ("errSecCSStaticCodeNotFound", "Static code not found at specified path"),
        -67061: ("errSecCSUnsupportedGuestAttributes", "Unsupported guest attributes"),
        -67062: ("errSecCSInvalidAttributeValues", "Invalid attribute values"),
        -67066: ("errSecCSNoSuchCode", "No matching code found"),
        -67067: ("errSecCSMultipleGuests", "Multiple guests matched"),

        // AFP
        -5000: ("afpAccessDenied", "AFP access denied"),

        // Gestalt / general
        -5551: ("gestaltUnknownErr", "Gestalt selector unknown"),
    ]

    // Values mirror IOKit/IOReturn.h — sub_iokit_common is err_sub(0), so the
    // full value is 0xE0000000 | code. Prior table had the correct symbolic
    // names paired with the WRONG numeric codes for ~half the entries, plus
    // several entirely fabricated 0xE00000xx codes that don't exist in the
    // header.
    static let ioReturnTable: [UInt32: (String, String)] = [
        0x00000000: ("kIOReturnSuccess", "Operation successful"),
        0xE0000001: ("kIOReturnInvalid", "Invalid — should never be seen"),
        0xE00002BC: ("kIOReturnError", "General error"),
        0xE00002BD: ("kIOReturnNoMemory", "Cannot allocate memory"),
        0xE00002BE: ("kIOReturnNoResources", "Resource shortage"),
        0xE00002BF: ("kIOReturnIPCError", "Error during IPC"),
        0xE00002C0: ("kIOReturnNoDevice", "No such device"),
        0xE00002C1: ("kIOReturnNotPrivileged", "Privilege violation"),
        0xE00002C2: ("kIOReturnBadArgument", "Invalid argument"),
        0xE00002C3: ("kIOReturnLockedRead", "Device read locked"),
        0xE00002C4: ("kIOReturnLockedWrite", "Device write locked"),
        0xE00002C5: ("kIOReturnExclusiveAccess", "Exclusive access requested but granted"),
        0xE00002C6: ("kIOReturnBadMessageID", "Sent or received messages had different msgid_t"),
        0xE00002C7: ("kIOReturnUnsupported", "Unsupported function"),
        0xE00002C8: ("kIOReturnVMError", "Miscellaneous VM failure"),
        0xE00002C9: ("kIOReturnInternalError", "Internal error"),
        0xE00002CA: ("kIOReturnIOError", "General I/O error"),
        0xE00002CC: ("kIOReturnCannotLock", "Cannot acquire lock"),
        0xE00002CD: ("kIOReturnNotOpen", "Device not open"),
        0xE00002CE: ("kIOReturnNotReadable", "Read not supported"),
        0xE00002CF: ("kIOReturnNotWritable", "Write not supported"),
        0xE00002D0: ("kIOReturnNotAligned", "Alignment error"),
        0xE00002D1: ("kIOReturnBadMedia", "Media error"),
        0xE00002D2: ("kIOReturnStillOpen", "Device(s) still open"),
        0xE00002D3: ("kIOReturnRLDError", "Runtime-linker (rld) failure"),
        0xE00002D4: ("kIOReturnDMAError", "DMA failure"),
        0xE00002D5: ("kIOReturnBusy", "Device busy"),
        0xE00002D6: ("kIOReturnTimeout", "I/O timeout"),
        0xE00002D7: ("kIOReturnOffline", "Device offline"),
        0xE00002D8: ("kIOReturnNotReady", "Device not ready"),
        0xE00002D9: ("kIOReturnNotAttached", "Device not attached"),
        0xE00002DA: ("kIOReturnNoChannels", "No DMA channels left"),
        0xE00002DB: ("kIOReturnNoSpace", "No space for data"),
        0xE00002DD: ("kIOReturnPortExists", "Port already exists"),
        0xE00002DE: ("kIOReturnCannotWire", "Cannot wire down memory"),
        0xE00002DF: ("kIOReturnNoInterrupt", "No interrupt attached"),
        0xE00002E0: ("kIOReturnNoFrames", "No DMA frames enqueued"),
        0xE00002E1: ("kIOReturnMessageTooLarge", "Oversized message received"),
        0xE00002E2: ("kIOReturnNotPermitted", "Operation not permitted"),
        0xE00002E3: ("kIOReturnNoPower", "No power to device"),
        0xE00002E4: ("kIOReturnNoMedia", "Media not present"),
        0xE00002E5: ("kIOReturnUnformattedMedia", "Media not formatted"),
        0xE00002E6: ("kIOReturnUnsupportedMode", "No such mode"),
        0xE00002E7: ("kIOReturnUnderrun", "Data underrun"),
        0xE00002E8: ("kIOReturnOverrun", "Data overrun"),
        0xE00002E9: ("kIOReturnDeviceError", "Device not functioning properly"),
        0xE00002EA: ("kIOReturnNoCompletion", "A completion routine is required"),
        0xE00002EB: ("kIOReturnAborted", "Operation aborted"),
        0xE00002EC: ("kIOReturnNoBandwidth", "Bus bandwidth would be exceeded"),
        0xE00002ED: ("kIOReturnNotResponding", "Device not responding"),
        0xE00002EE: ("kIOReturnIsoTooOld", "Isochronous I/O request for distant past"),
        0xE00002EF: ("kIOReturnIsoTooNew", "Isochronous I/O request for distant future"),
        0xE00002F0: ("kIOReturnNotFound", "Data was not found"),
        // USB subsystem (sub_iokit_usb = err_sub(1) → 0xE0004000 | code)
        0xE0004061: ("kIOUSBPipeStalled", "USB pipe stalled (endpoint halted)"),
    ]

    // Values mirror mach/kern_return.h exactly. Prior table had most codes
    // at the wrong number — the names were right but the ints were off by
    // anywhere from a few to ~20.
    static let machErrorTable: [Int32: (String, String)] = [
        0:  ("KERN_SUCCESS", "Success"),
        1:  ("KERN_INVALID_ADDRESS", "Specified address is not currently valid"),
        2:  ("KERN_PROTECTION_FAILURE", "Memory is valid but does not permit the required access"),
        3:  ("KERN_NO_SPACE", "Address range specified is already in use or none of specified size is available"),
        4:  ("KERN_INVALID_ARGUMENT", "Function not applicable to this type of argument"),
        5:  ("KERN_FAILURE", "Function could not be performed"),
        6:  ("KERN_RESOURCE_SHORTAGE", "A system resource could not be allocated"),
        7:  ("KERN_NOT_RECEIVER", "Task does not hold receive rights for the port argument"),
        8:  ("KERN_NO_ACCESS", "Bogus access restriction"),
        9:  ("KERN_MEMORY_FAILURE", "During a page fault, the target memory object has been destroyed"),
        10: ("KERN_MEMORY_ERROR", "During a page fault, the memory object indicated that data could not be returned"),
        11: ("KERN_ALREADY_IN_SET", "The receive right is already a member of the portset"),
        12: ("KERN_NOT_IN_SET", "The receive right is not a member of a port set"),
        13: ("KERN_NAME_EXISTS", "The name already denotes a right in the task"),
        14: ("KERN_ABORTED", "The operation was aborted"),
        15: ("KERN_INVALID_NAME", "The name doesn't denote a right in the task"),
        16: ("KERN_INVALID_TASK", "The target task isn't an active task"),
        17: ("KERN_INVALID_RIGHT", "The name denotes a right but not an appropriate right"),
        18: ("KERN_INVALID_VALUE", "A blatant range error"),
        19: ("KERN_UREFS_OVERFLOW", "Operation would overflow the target's user-reference count"),
        20: ("KERN_INVALID_CAPABILITY", "The supplied port capability is improper"),
        21: ("KERN_RIGHT_EXISTS", "The task already has send or receive rights for the port"),
        22: ("KERN_INVALID_HOST", "Target host isn't actually a host"),
        23: ("KERN_MEMORY_PRESENT", "Attempt to supply precious data for memory already present"),
        24: ("KERN_MEMORY_DATA_MOVED", "Memory has been moved"),
        25: ("KERN_MEMORY_RESTART_COPY", "Restart the affected memory copy"),
        26: ("KERN_INVALID_PROCESSOR_SET", "Argument to assert processor-set privilege was not a processor-set control port"),
        27: ("KERN_POLICY_LIMIT", "The specified scheduling attributes exceed the thread's limits"),
        28: ("KERN_INVALID_POLICY", "The specified scheduling policy is not currently enabled for the processor set"),
        29: ("KERN_INVALID_OBJECT", "The external memory manager failed to initialize the memory object"),
        30: ("KERN_ALREADY_WAITING", "A thread is already waiting for a kernel object"),
        31: ("KERN_DEFAULT_SET", "An attempt was made to destroy the default processor set"),
        32: ("KERN_EXCEPTION_PROTECTED", "An attempt was made to fetch an exception port that is protected"),
        33: ("KERN_INVALID_LEDGER", "A ledger was required but not supplied"),
        34: ("KERN_INVALID_MEMORY_CONTROL", "The port was not a memory-cache control port"),
        35: ("KERN_INVALID_SECURITY", "An argument supplied to assert security privilege was not a host security port"),
        36: ("KERN_NOT_DEPRESSED", "An attempt was made to undepress a thread that was not depressed"),
        37: ("KERN_TERMINATED", "An operation was attempted on a terminated IPC space"),
        38: ("KERN_LOCK_SET_DESTROYED", "An operation was attempted on a lock set that has been destroyed"),
        39: ("KERN_LOCK_UNSTABLE", "The lock holder terminated while holding the lock"),
        40: ("KERN_LOCK_OWNED", "The lock is already owned by another thread"),
        41: ("KERN_LOCK_OWNED_SELF", "The lock is already owned by the calling thread"),
        42: ("KERN_SEMAPHORE_DESTROYED", "An operation was attempted on a semaphore that has been destroyed"),
        43: ("KERN_RPC_SERVER_TERMINATED", "Target RPC server terminated before reply"),
        44: ("KERN_RPC_TERMINATE_ORPHAN", "Terminate orphaned activation"),
        45: ("KERN_RPC_CONTINUE_ORPHAN", "Allow orphaned activation to continue"),
        46: ("KERN_NOT_SUPPORTED", "Empty thread activation (No thread linked to it)"),
        47: ("KERN_NODE_DOWN", "Remote node down or inaccessible"),
        48: ("KERN_NOT_WAITING", "A signalled thread was not actually waiting"),
        49: ("KERN_OPERATION_TIMED_OUT", "Thread-oriented operation has timed out without guard context"),
        50: ("KERN_CODESIGN_ERROR", "Page was rejected due to a signing failure"),
        51: ("KERN_POLICY_STATIC", "Attempt to change a policy-static value"),
        52: ("KERN_INSUFFICIENT_BUFFER_SIZE", "Provided buffer is of insufficient size for requested data"),
        53: ("KERN_DENIED", "Denied by security policy"),
        54: ("KERN_MISSING_KC", "The Kext Collection requested was not found"),
        55: ("KERN_INVALID_KC", "The Kext Collection requested was invalid"),
        56: ("KERN_NOT_FOUND", "A requested resource was not found"),
        57: ("KERN_INVALID_GUARD_OBJECT_SLOT", "Attempt to use an invalid guard object slot"),
    ]

    // Complete IANA HTTP status code registry (plus the few widely-adopted
    // unregistered codes like 418). Descriptions paraphrased from RFCs.
    static let httpStatusTable: [Int: (String, String)] = [
        // 1xx Informational
        100: ("Continue", "Server received request headers; client should proceed to send the body"),
        101: ("Switching Protocols", "Server is switching protocols as requested"),
        102: ("Processing", "Server has received and is processing the request (WebDAV)"),
        103: ("Early Hints", "Used to return preliminary response headers before the final response"),

        // 2xx Success
        200: ("OK", "Request succeeded"),
        201: ("Created", "Request fulfilled and a new resource was created"),
        202: ("Accepted", "Request accepted for processing but not completed"),
        203: ("Non-Authoritative Information", "Request succeeded but body is from a transforming proxy"),
        204: ("No Content", "Request succeeded; no body to return"),
        205: ("Reset Content", "Request succeeded; client should reset the document view"),
        206: ("Partial Content", "Partial GET request succeeded (range request)"),
        207: ("Multi-Status", "Multiple independent status codes in body (WebDAV)"),
        208: ("Already Reported", "Members already enumerated in a preceding part (WebDAV)"),
        226: ("IM Used", "Server fulfilled a GET request with instance-manipulations applied"),

        // 3xx Redirection
        300: ("Multiple Choices", "Multiple options for the resource; client should choose"),
        301: ("Moved Permanently", "Resource permanently moved to a new URL"),
        302: ("Found", "Resource temporarily at a different URL"),
        303: ("See Other", "Response to this request found at another URL using GET"),
        304: ("Not Modified", "Resource has not been modified since last request"),
        305: ("Use Proxy", "Must access resource through the specified proxy (deprecated)"),
        307: ("Temporary Redirect", "Resource temporarily moved; use same method"),
        308: ("Permanent Redirect", "Resource permanently moved; use same method"),

        // 4xx Client errors
        400: ("Bad Request", "Server cannot process the request due to client error"),
        401: ("Unauthorized", "Authentication required and has failed or not been provided"),
        402: ("Payment Required", "Reserved for future use"),
        403: ("Forbidden", "Server understood the request but refuses to authorize it"),
        404: ("Not Found", "Requested resource could not be found"),
        405: ("Method Not Allowed", "Request method not supported for this resource"),
        406: ("Not Acceptable", "Resource cannot satisfy the request's Accept headers"),
        407: ("Proxy Authentication Required", "Must authenticate with the proxy first"),
        408: ("Request Timeout", "Server timed out waiting for the request"),
        409: ("Conflict", "Request conflicts with the current state of the server"),
        410: ("Gone", "Resource is no longer available and will not be available again"),
        411: ("Length Required", "Request did not specify the length of its content"),
        412: ("Precondition Failed", "Precondition in request headers evaluated to false"),
        413: ("Content Too Large", "Request entity is larger than server limits"),
        414: ("URI Too Long", "Request URI is longer than the server is willing to interpret"),
        415: ("Unsupported Media Type", "Request entity has an unsupported media type"),
        416: ("Range Not Satisfiable", "Requested range cannot be fulfilled"),
        417: ("Expectation Failed", "Expectation in request headers cannot be met by the server"),
        418: ("I'm a Teapot", "Server refuses the attempt to brew coffee with a teapot (RFC 2324, April Fools)"),
        421: ("Misdirected Request", "Request was directed at a server unable to produce a response"),
        422: ("Unprocessable Content", "Request was well-formed but semantically erroneous"),
        423: ("Locked", "Resource is locked (WebDAV)"),
        424: ("Failed Dependency", "Request failed due to failure of a previous request (WebDAV)"),
        425: ("Too Early", "Server unwilling to risk processing a replayed request"),
        426: ("Upgrade Required", "Client should upgrade to a different protocol"),
        428: ("Precondition Required", "Origin server requires the request to be conditional"),
        429: ("Too Many Requests", "User has sent too many requests in a given time (rate limit)"),
        431: ("Request Header Fields Too Large", "Server unwilling to process the request due to header size"),
        451: ("Unavailable For Legal Reasons", "Resource unavailable due to legal demands"),

        // 5xx Server errors
        500: ("Internal Server Error", "Unexpected condition encountered by the server"),
        501: ("Not Implemented", "Server does not support the functionality required"),
        502: ("Bad Gateway", "Server received an invalid response from the upstream server"),
        503: ("Service Unavailable", "Server is currently unable to handle the request"),
        504: ("Gateway Timeout", "Upstream server failed to send a request in time"),
        505: ("HTTP Version Not Supported", "Server does not support the HTTP version used"),
        506: ("Variant Also Negotiates", "Transparent content negotiation configuration error"),
        507: ("Insufficient Storage", "Server cannot store the representation needed to complete the request"),
        508: ("Loop Detected", "Server detected an infinite loop while processing (WebDAV)"),
        510: ("Not Extended", "Further extensions to the request are required"),
        511: ("Network Authentication Required", "Client needs to authenticate to gain network access (captive portal)"),
    ]

    // Values mirror Foundation/NSURLError.h (NSURLErrorDomain / CFNetwork).
    static let cfNetworkTable: [Int32: (String, String)] = [
        -1: ("NSURLErrorUnknown", "Unknown error"),
        -999: ("NSURLErrorCancelled", "Cancelled"),
        -1000: ("NSURLErrorBadURL", "Bad URL"),
        -1001: ("NSURLErrorTimedOut", "Request timed out"),
        -1002: ("NSURLErrorUnsupportedURL", "Unsupported URL"),
        -1003: ("NSURLErrorCannotFindHost", "Cannot find host"),
        -1004: ("NSURLErrorCannotConnectToHost", "Cannot connect to host"),
        -1005: ("NSURLErrorNetworkConnectionLost", "Network connection lost"),
        -1006: ("NSURLErrorDNSLookupFailed", "DNS lookup failed"),
        -1007: ("NSURLErrorHTTPTooManyRedirects", "Too many HTTP redirects"),
        -1008: ("NSURLErrorResourceUnavailable", "Resource unavailable"),
        -1009: ("NSURLErrorNotConnectedToInternet", "Not connected to the internet"),
        -1010: ("NSURLErrorRedirectToNonExistentLocation", "Redirect to non-existent location"),
        -1011: ("NSURLErrorBadServerResponse", "Bad server response"),
        -1012: ("NSURLErrorUserCancelledAuthentication", "User cancelled authentication"),
        -1013: ("NSURLErrorUserAuthenticationRequired", "User authentication required"),
        -1014: ("NSURLErrorZeroByteResource", "Zero-byte resource returned"),
        -1015: ("NSURLErrorCannotDecodeRawData", "Cannot decode raw data"),
        -1016: ("NSURLErrorCannotDecodeContentData", "Cannot decode content data"),
        -1017: ("NSURLErrorCannotParseResponse", "Cannot parse response"),
        -1018: ("NSURLErrorInternationalRoamingOff", "International roaming is off"),
        -1019: ("NSURLErrorCallIsActive", "Call is active"),
        -1020: ("NSURLErrorDataNotAllowed", "Cellular data not allowed"),
        -1021: ("NSURLErrorRequestBodyStreamExhausted", "Request body stream exhausted"),
        -1022: ("NSURLErrorAppTransportSecurityRequiresSecureConnection", "ATS requires secure connection"),
        -1100: ("NSURLErrorFileDoesNotExist", "File does not exist"),
        -1101: ("NSURLErrorFileIsDirectory", "File is a directory"),
        -1102: ("NSURLErrorNoPermissionsToReadFile", "No permissions to read file"),
        -1103: ("NSURLErrorDataLengthExceedsMaximum", "Data length exceeds maximum"),
        -1104: ("NSURLErrorFileOutsideSafeArea", "File outside safe area"),
        -1200: ("NSURLErrorSecureConnectionFailed", "Secure connection failed"),
        -1201: ("NSURLErrorServerCertificateHasBadDate", "Server certificate has bad date"),
        -1202: ("NSURLErrorServerCertificateUntrusted", "Server certificate untrusted"),
        -1203: ("NSURLErrorServerCertificateHasUnknownRoot", "Server certificate has unknown root"),
        -1204: ("NSURLErrorServerCertificateNotYetValid", "Server certificate not yet valid"),
        -1205: ("NSURLErrorClientCertificateRejected", "Client certificate rejected"),
        -1206: ("NSURLErrorClientCertificateRequired", "Client certificate required"),
        -2000: ("NSURLErrorCannotLoadFromNetwork", "Cannot load from network"),
        -3000: ("NSURLErrorCannotCreateFile", "Cannot create file"),
        -3001: ("NSURLErrorCannotOpenFile", "Cannot open file"),
        -3002: ("NSURLErrorCannotCloseFile", "Cannot close file"),
        -3003: ("NSURLErrorCannotWriteToFile", "Cannot write to file"),
        -3004: ("NSURLErrorCannotRemoveFile", "Cannot remove file"),
        -3005: ("NSURLErrorCannotMoveFile", "Cannot move file"),
        -3006: ("NSURLErrorDownloadDecodingFailedMidStream", "Download decoding failed mid-stream"),
        -3007: ("NSURLErrorDownloadDecodingFailedToComplete", "Download decoding failed to complete"),
    ]

    static let cocoaTable: [Int: (String, String)] = [
        // Foundation generic
        4: ("NSFileNoSuchFileError", "No such file"),
        255: ("NSFileLockingError", "File locking error"),
        256: ("NSFileReadUnknownError", "Unknown file read error"),
        257: ("NSFileReadNoPermissionError", "No permission to read file"),
        258: ("NSFileReadInvalidFileNameError", "Invalid file name"),
        259: ("NSFileReadCorruptFileError", "Corrupt file"),
        260: ("NSFileReadNoSuchFileError", "No such file (read)"),
        261: ("NSFileReadInapplicableStringEncodingError", "Inapplicable string encoding"),
        262: ("NSFileReadUnsupportedSchemeError", "Unsupported URL scheme"),
        263: ("NSFileReadTooLargeError", "File too large"),
        264: ("NSFileReadUnknownStringEncodingError", "Unknown string encoding"),
        512: ("NSFileWriteUnknownError", "Unknown file write error"),
        513: ("NSFileWriteNoPermissionError", "No permission to write file"),
        514: ("NSFileWriteInvalidFileNameError", "Invalid file name (write)"),
        516: ("NSFileWriteFileExistsError", "File already exists"),
        517: ("NSFileWriteInapplicableStringEncodingError", "Inapplicable encoding (write)"),
        518: ("NSFileWriteUnsupportedSchemeError", "Unsupported URL scheme (write)"),
        640: ("NSFileWriteOutOfSpaceError", "Out of disk space"),
        642: ("NSFileWriteVolumeReadOnlyError", "Volume is read-only"),
        1024: ("NSExecutableNotLoadableError", "Executable not loadable"),
        1025: ("NSExecutableArchitectureMismatchError", "Executable architecture mismatch"),
        1026: ("NSExecutableRuntimeMismatchError", "Executable runtime mismatch"),
        1027: ("NSExecutableLoadError", "Executable load error"),
        1028: ("NSExecutableLinkError", "Executable link error"),
        // Property list / encoding
        3840: ("NSPropertyListReadCorruptError", "Corrupt property list"),
        3841: ("NSPropertyListReadUnknownVersionError", "Unknown property list version"),
        3842: ("NSPropertyListReadStreamError", "Property list stream error"),
        3851: ("NSPropertyListWriteStreamError", "Property list write stream error"),
        3852: ("NSPropertyListWriteInvalidError", "Invalid property list"),
        // XPC
        4097: ("NSXPCConnectionInterrupted", "XPC connection interrupted"),
        4099: ("NSXPCConnectionInvalid", "XPC connection invalid"),
        4101: ("NSXPCConnectionReplyInvalid", "XPC reply invalid"),
        // User defaults / ubiquity (commonly seen)
        4352: ("NSUbiquitousFileUnavailableError", "Ubiquitous file unavailable"),
        4353: ("NSUbiquitousFileNotUploadedDueToQuotaError", "Ubiquitous file quota exceeded"),
        4354: ("NSUbiquitousFileUbiquityServerNotAvailable", "Ubiquity server unavailable"),
        // CoreData (most common)
        133000: ("NSManagedObjectValidationError", "Managed object validation error"),
        133010: ("NSManagedObjectConstraintValidationError", "Constraint validation error"),
        133020: ("NSValidationMultipleErrorsError", "Multiple validation errors"),
        134060: ("NSPersistentStoreSaveError", "Persistent store save error"),
        134080: ("NSPersistentStoreOpenError", "Persistent store open error"),
        134090: ("NSPersistentStoreTimeoutError", "Persistent store timeout"),
        134100: ("NSPersistentStoreIncompatibleSchemaError", "Incompatible store schema"),
    ]

    // Sourced from Security.framework/Headers/SecBase.h (macOS 15.4 SDK).
    // Codes verified against the SDK header; several entries from the original
    // spec were corrected (see commit message for details).
    static let securityTable: [Int32: (String, String)] = [
        0: ("errSecSuccess", "Success"),
        -4: ("errSecUnimplemented", "Function or operation not implemented"),
        -34: ("errSecDiskFull", "The disk is full"),
        -36: ("errSecIO", "I/O error"),
        -49: ("errSecOpWr", "File already open with write permission"),
        -50: ("errSecParam", "One or more parameters passed to a function were not valid"),
        -61: ("errSecWrPerm", "Write permissions error"),
        -108: ("errSecAllocate", "Failed to allocate memory"),
        -128: ("errSecUserCanceled", "User canceled the operation"),
        -909: ("errSecBadReq", "Bad parameter or invalid state for operation"),
        -2070: ("errSecInternalComponent", "Internal component error"),
        -4960: ("errSecCoreFoundationUnknown", "CoreFoundation error"),
        -25240: ("errSecACLNotSimple", "The specified access control list is not in standard (simple) form"),
        -25241: ("errSecPolicyNotFound", "The specified policy cannot be found"),
        -25243: ("errSecNoAccessForItem", "The specified item has no access control"),
        -25244: ("errSecInvalidOwnerEdit", "Invalid attempt to change the owner of this item"),
        -25245: ("errSecTrustNotAvailable", "No trust results are available"),
        -25291: ("errSecNotAvailable", "No keychain is available"),
        -25292: ("errSecReadOnly", "This keychain cannot be modified"),
        -25293: ("errSecAuthFailed", "The user name or passphrase you entered is not correct"),
        -25294: ("errSecNoSuchKeychain", "The specified keychain could not be found"),
        -25295: ("errSecInvalidKeychain", "The specified keychain is not a valid keychain file"),
        -25296: ("errSecDuplicateKeychain", "A keychain with the same name already exists"),
        -25297: ("errSecDuplicateCallback", "The specified callback function is already installed"),
        -25298: ("errSecInvalidCallback", "The specified callback function is not valid"),
        -25299: ("errSecDuplicateItem", "The specified item already exists in the keychain"),
        -25300: ("errSecItemNotFound", "The specified item could not be found in the keychain"),
        -25301: ("errSecBufferTooSmall", "There is not enough memory available to use the specified item"),
        -25302: ("errSecDataTooLarge", "This item contains information which is too large or in a format that cannot be displayed"),
        -25303: ("errSecNoSuchAttr", "The specified attribute does not exist"),
        -25304: ("errSecInvalidItemRef", "The specified item is no longer valid; it may have been deleted from the keychain"),
        -25305: ("errSecInvalidSearchRef", "Unable to search the current keychain"),
        -25306: ("errSecNoSuchClass", "The specified item does not appear to be a valid keychain item"),
        -25307: ("errSecNoDefaultKeychain", "A default keychain could not be found"),
        -25308: ("errSecInteractionNotAllowed", "User interaction is not allowed"),
        -25309: ("errSecReadOnlyAttr", "The specified attribute could not be modified"),
        -25310: ("errSecWrongSecVersion", "This keychain was created by a different version of the system software and cannot be opened"),
        -25311: ("errSecKeySizeNotAllowed", "This item specifies a key size which is too large or too small"),
        -25312: ("errSecNoStorageModule", "A required component (data storage module) could not be loaded"),
        -25313: ("errSecNoCertificateModule", "A required component (certificate module) could not be loaded"),
        -25314: ("errSecNoPolicyModule", "A required component (policy module) could not be loaded"),
        -25315: ("errSecInteractionRequired", "User interaction is required but is currently not allowed"),
        -25316: ("errSecDataNotAvailable", "The contents of this item cannot be retrieved"),
        -25317: ("errSecDataNotModifiable", "The contents of this item cannot be modified"),
        -25318: ("errSecCreateChainFailed", "One or more certificates required to validate this certificate cannot be found"),
        -25319: ("errSecInvalidPrefsDomain", "The specified preferences domain is not valid"),
        -25320: ("errSecInDarkWake", "In dark wake, no UI possible"),
        -26267: ("errSecNotSigner", "A certificate was not signed by its proposed parent"),
        -26275: ("errSecDecode", "Unable to decode the provided data"),
        -34018: ("errSecMissingEntitlement", "A required entitlement isn't present"),
        -34020: ("errSecRestrictedAPI", "Client is restricted and is not permitted to perform this operation"),
        -67694: ("errSecInvalidValue", "An invalid value was detected"),
        -67871: ("errSecMissingValue", "A missing value was detected"),
    ]

    // BSD signal set used by Darwin/macOS. Numbers sourced from
    // <sys/signal.h> in the macOS 15.4 SDK. Linux realtime signals
    // (32-64) are intentionally not included.
    static let posixSignalTable: [Int32: (String, String)] = [
        1:  ("SIGHUP",    "Hangup detected on controlling terminal"),
        2:  ("SIGINT",    "Interrupt from keyboard (Ctrl-C)"),
        3:  ("SIGQUIT",   "Quit from keyboard (Ctrl-\\)"),
        4:  ("SIGILL",    "Illegal instruction"),
        5:  ("SIGTRAP",   "Trace/breakpoint trap"),
        6:  ("SIGABRT",   "Aborted (abort() called)"),
        7:  ("SIGEMT",    "Emulator trap"),
        8:  ("SIGFPE",    "Floating-point exception"),
        9:  ("SIGKILL",   "Killed (cannot be caught or ignored)"),
        10: ("SIGBUS",    "Bus error (bad memory access)"),
        11: ("SIGSEGV",   "Segmentation fault"),
        12: ("SIGSYS",    "Bad system call"),
        13: ("SIGPIPE",   "Broken pipe"),
        14: ("SIGALRM",   "Alarm clock"),
        15: ("SIGTERM",   "Terminated"),
        16: ("SIGURG",    "Urgent condition on socket"),
        17: ("SIGSTOP",   "Stop process (cannot be caught or ignored)"),
        18: ("SIGTSTP",   "Stop typed at terminal (Ctrl-Z)"),
        19: ("SIGCONT",   "Continue if stopped"),
        20: ("SIGCHLD",   "Child status changed"),
        21: ("SIGTTIN",   "Background process attempting read"),
        22: ("SIGTTOU",   "Background process attempting write"),
        23: ("SIGIO",     "I/O now possible"),
        24: ("SIGXCPU",   "CPU time limit exceeded"),
        25: ("SIGXFSZ",   "File size limit exceeded"),
        26: ("SIGVTALRM", "Virtual alarm clock"),
        27: ("SIGPROF",   "Profiling timer expired"),
        28: ("SIGWINCH",  "Window size change"),
        29: ("SIGINFO",   "Status request from keyboard (Ctrl-T)"),
        30: ("SIGUSR1",   "User-defined signal 1"),
        31: ("SIGUSR2",   "User-defined signal 2"),
    ]

    // SQLite result codes. Base codes sourced from sqlite3.h in the macOS 15.4 SDK.
    // Extended codes follow the (primary | (subcode << 8)) formula defined by SQLite.
    static let sqliteTable: [Int32: (String, String)] = [
        0:    ("SQLITE_OK",           "Successful result"),
        1:    ("SQLITE_ERROR",        "Generic error"),
        2:    ("SQLITE_INTERNAL",     "Internal logic error"),
        3:    ("SQLITE_PERM",         "Access permission denied"),
        4:    ("SQLITE_ABORT",        "Callback routine requested abort"),
        5:    ("SQLITE_BUSY",         "Database file is locked"),
        6:    ("SQLITE_LOCKED",       "Table in database is locked"),
        7:    ("SQLITE_NOMEM",        "Out of memory"),
        8:    ("SQLITE_READONLY",     "Attempt to write a readonly database"),
        9:    ("SQLITE_INTERRUPT",    "Operation terminated by sqlite3_interrupt()"),
        10:   ("SQLITE_IOERR",        "Disk I/O error"),
        11:   ("SQLITE_CORRUPT",      "Database disk image is malformed"),
        12:   ("SQLITE_NOTFOUND",     "Unknown opcode in sqlite3_file_control()"),
        13:   ("SQLITE_FULL",         "Insertion failed because database is full"),
        14:   ("SQLITE_CANTOPEN",     "Unable to open the database file"),
        15:   ("SQLITE_PROTOCOL",     "Database lock protocol error"),
        16:   ("SQLITE_EMPTY",        "Internal use only"),
        17:   ("SQLITE_SCHEMA",       "Database schema changed"),
        18:   ("SQLITE_TOOBIG",       "String or BLOB exceeds size limit"),
        19:   ("SQLITE_CONSTRAINT",   "Abort due to constraint violation"),
        20:   ("SQLITE_MISMATCH",     "Data type mismatch"),
        21:   ("SQLITE_MISUSE",       "Library used incorrectly"),
        22:   ("SQLITE_NOLFS",        "Uses OS features not supported on host"),
        23:   ("SQLITE_AUTH",         "Authorization denied"),
        24:   ("SQLITE_FORMAT",       "Not used"),
        25:   ("SQLITE_RANGE",        "2nd parameter to sqlite3_bind out of range"),
        26:   ("SQLITE_NOTADB",       "File opened that is not a database file"),
        27:   ("SQLITE_NOTICE",       "Notifications from sqlite3_log()"),
        28:   ("SQLITE_WARNING",      "Warnings from sqlite3_log()"),
        100:  ("SQLITE_ROW",          "sqlite3_step() has another row ready"),
        101:  ("SQLITE_DONE",         "sqlite3_step() has finished executing"),
        // Extended codes: primary | (subcode << 8)
        261:  ("SQLITE_BUSY_RECOVERY",          "Recovery from another process"),         // 5  | (1<<8)
        266:  ("SQLITE_IOERR_READ",             "I/O error on read"),                     // 10 | (1<<8)
        267:  ("SQLITE_CORRUPT_VTAB",           "Virtual table corruption"),               // 11 | (1<<8)
        275:  ("SQLITE_CONSTRAINT_CHECK",        "Check constraint failed"),               // 19 | (1<<8)
        522:  ("SQLITE_IOERR_SHORT_READ",       "Short read"),                            // 10 | (2<<8)
        778:  ("SQLITE_IOERR_WRITE",            "I/O error on write"),                    // 10 | (3<<8)
        787:  ("SQLITE_CONSTRAINT_FOREIGNKEY",  "Foreign key constraint failed"),         // 19 | (3<<8)
        1034: ("SQLITE_IOERR_FSYNC",            "I/O error on fsync"),                    // 10 | (4<<8)
        1290: ("SQLITE_IOERR_DIR_FSYNC",        "I/O error on directory fsync"),          // 10 | (5<<8)
        1555: ("SQLITE_CONSTRAINT_PRIMARYKEY",  "Primary key constraint failed"),         // 19 | (6<<8)
        2067: ("SQLITE_CONSTRAINT_UNIQUE",      "Unique constraint failed"),              // 19 | (8<<8)
    ]

    // Full canonical gRPC status code set. Source: grpc/grpc status_code_enum.h / status.proto.
    // Codes 0-16 are fixed by spec; no extensions expected.
    static let grpcTable: [Int32: (String, String)] = [
        0:  ("OK",                   "Not an error; returned on success"),
        1:  ("CANCELLED",            "Operation was cancelled (typically by caller)"),
        2:  ("UNKNOWN",              "Unknown error"),
        3:  ("INVALID_ARGUMENT",     "Client specified an invalid argument"),
        4:  ("DEADLINE_EXCEEDED",    "Deadline expired before operation could complete"),
        5:  ("NOT_FOUND",            "Some requested entity was not found"),
        6:  ("ALREADY_EXISTS",       "Entity caller attempted to create already exists"),
        7:  ("PERMISSION_DENIED",    "Caller does not have permission"),
        8:  ("RESOURCE_EXHAUSTED",   "Some resource has been exhausted"),
        9:  ("FAILED_PRECONDITION",  "System is not in required state"),
        10: ("ABORTED",              "Operation was aborted (typically due to concurrency issue)"),
        11: ("OUT_OF_RANGE",         "Operation attempted past valid range"),
        12: ("UNIMPLEMENTED",        "Operation is not implemented or not supported"),
        13: ("INTERNAL",             "Internal errors (broken invariants)"),
        14: ("UNAVAILABLE",          "Service unavailable (typically transient)"),
        15: ("DATA_LOSS",            "Unrecoverable data loss or corruption"),
        16: ("UNAUTHENTICATED",      "Request does not have valid credentials"),
    ]

    static let bonjourTable: [Int32: (String, String)] = [
        0:      ("kDNSServiceErr_NoError",                   "No error"),
        -65537: ("kDNSServiceErr_Unknown",                   "Unknown error"),
        -65538: ("kDNSServiceErr_NoSuchName",                "No such name"),
        -65539: ("kDNSServiceErr_NoMemory",                  "Out of memory"),
        -65540: ("kDNSServiceErr_BadParam",                  "Bad parameter"),
        -65541: ("kDNSServiceErr_BadReference",              "Bad reference"),
        -65542: ("kDNSServiceErr_BadState",                  "Bad state"),
        -65543: ("kDNSServiceErr_BadFlags",                  "Bad flags"),
        -65544: ("kDNSServiceErr_Unsupported",               "Unsupported operation"),
        -65545: ("kDNSServiceErr_NotInitialized",            "Not initialized"),
        -65547: ("kDNSServiceErr_AlreadyRegistered",         "Service already registered"),
        -65548: ("kDNSServiceErr_NameConflict",              "Name conflict"),
        -65549: ("kDNSServiceErr_Invalid",                   "Invalid"),
        -65550: ("kDNSServiceErr_Firewall",                  "Blocked by firewall"),
        -65551: ("kDNSServiceErr_Incompatible",              "Library incompatible with daemon"),
        -65552: ("kDNSServiceErr_BadInterfaceIndex",         "Bad interface index"),
        -65553: ("kDNSServiceErr_Refused",                   "Refused"),
        -65554: ("kDNSServiceErr_NoSuchRecord",              "No such record"),
        -65555: ("kDNSServiceErr_NoAuth",                    "No authentication"),
        -65556: ("kDNSServiceErr_NoSuchKey",                 "No such key"),
        -65557: ("kDNSServiceErr_NATTraversal",              "NAT traversal error"),
        -65558: ("kDNSServiceErr_DoubleNAT",                 "Double NAT"),
        -65559: ("kDNSServiceErr_BadTime",                   "Clock skew"),
        -65560: ("kDNSServiceErr_BadSig",                    "Bad signature"),
        -65561: ("kDNSServiceErr_BadKey",                    "Bad key"),
        -65562: ("kDNSServiceErr_Transient",                 "Transient error"),
        -65563: ("kDNSServiceErr_ServiceNotRunning",         "mDNSResponder not running"),
        -65564: ("kDNSServiceErr_NATPortMappingUnsupported", "NAT-PMP unsupported"),
        -65565: ("kDNSServiceErr_NATPortMappingDisabled",    "NAT-PMP disabled"),
        -65566: ("kDNSServiceErr_NoRouter",                  "No router"),
        -65567: ("kDNSServiceErr_PollingMode",               "Polling mode"),
        -65568: ("kDNSServiceErr_Timeout",                   "Timeout"),
        -65569: ("kDNSServiceErr_DefunctConnection",         "Defunct connection"),
        -65570: ("kDNSServiceErr_PolicyDenied",              "Policy denied"),
        -65571: ("kDNSServiceErr_NotPermitted",              "Not permitted"),
        -65572: ("kDNSServiceErr_StaleData",                 "Stale data"),
    ]

    static let posixExitTable: [Int: (String, String)] = [
        // Universal conventions
        0:   ("EXIT_SUCCESS",          "Successful termination"),
        1:   ("EXIT_FAILURE",          "Generic failure"),
        2:   ("EXIT_MISUSE",           "Misuse of shell builtins (Bash)"),
        // sysexits.h (BSD; widely used in Unix tools)
        64:  ("EX_USAGE",             "Command line usage error"),
        65:  ("EX_DATAERR",           "Data format error"),
        66:  ("EX_NOINPUT",           "Cannot open input"),
        67:  ("EX_NOUSER",            "Addressee unknown"),
        68:  ("EX_NOHOST",            "Host name unknown"),
        69:  ("EX_UNAVAILABLE",       "Service unavailable"),
        70:  ("EX_SOFTWARE",          "Internal software error"),
        71:  ("EX_OSERR",             "System error (e.g., can't fork)"),
        72:  ("EX_OSFILE",            "Critical OS file missing"),
        73:  ("EX_CANTCREAT",         "Cannot create output file"),
        74:  ("EX_IOERR",             "Input/output error"),
        75:  ("EX_TEMPFAIL",          "Temp failure; user is invited to retry"),
        76:  ("EX_PROTOCOL",          "Remote error in protocol"),
        77:  ("EX_NOPERM",            "Permission denied"),
        78:  ("EX_CONFIG",            "Configuration error"),
        // Shell conventions
        126: ("EXIT_NOT_EXECUTABLE",  "Command found but not executable"),
        127: ("EXIT_NOT_FOUND",       "Command not found"),
        128: ("EXIT_INVALID_ARG",     "Invalid argument to exit"),
        // 128 + signal number (most-commonly-seen subset)
        129: ("EXIT_SIGNALED_HUP",    "Killed by SIGHUP (128 + 1)"),
        130: ("EXIT_SIGNALED_INT",    "Killed by SIGINT (128 + 2; user pressed Ctrl-C)"),
        131: ("EXIT_SIGNALED_QUIT",   "Killed by SIGQUIT (128 + 3)"),
        132: ("EXIT_SIGNALED_ILL",    "Killed by SIGILL (128 + 4)"),
        134: ("EXIT_SIGNALED_ABRT",   "Killed by SIGABRT (128 + 6; abort() called)"),
        136: ("EXIT_SIGNALED_FPE",    "Killed by SIGFPE (128 + 8)"),
        137: ("EXIT_SIGNALED_KILL",   "Killed by SIGKILL (128 + 9; OOM-killer or kill -9)"),
        138: ("EXIT_SIGNALED_BUS",    "Killed by SIGBUS (128 + 10)"),
        139: ("EXIT_SIGNALED_SEGV",   "Killed by SIGSEGV (128 + 11; segfault)"),
        141: ("EXIT_SIGNALED_PIPE",   "Killed by SIGPIPE (128 + 13; broken pipe)"),
        142: ("EXIT_SIGNALED_ALRM",   "Killed by SIGALRM (128 + 14)"),
        143: ("EXIT_SIGNALED_TERM",   "Killed by SIGTERM (128 + 15)"),
        152: ("EXIT_SIGNALED_XCPU",   "Killed by SIGXCPU (128 + 24; CPU limit)"),
        153: ("EXIT_SIGNALED_XFSZ",   "Killed by SIGXFSZ (128 + 25; file size limit)"),
        255: ("EXIT_OUT_OF_RANGE",    "Exit code out of range (Bash)"),
    ]
}
