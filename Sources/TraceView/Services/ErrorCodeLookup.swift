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
        return results.filter { info in
            let key = "\(info.domain.rawValue):\(info.code)"
            return seen.insert(key).inserted
        }
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

        // HTTP status (only for positive values in range)
        if value > 0 && value < 600 {
            if let r = lookupHTTPStatus(Int(value)) { results.append(r) }
        }

        return results
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
        47: ("EAFNOSUPPORT", "Address family not supported"),
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
    ]

    static let osStatusTable: [Int32: (String, String)] = [
        0: ("noErr", "No error"),
        -34: ("dskFulErr", "Disk full"),
        -35: ("nsvErr", "No such volume"),
        -36: ("ioErr", "I/O error"),
        -37: ("bdNamErr", "Bad name"),
        -38: ("fnOpnErr", "File not open"),
        -39: ("eofErr", "End of file"),
        -40: ("posErr", "Tried to position before start of file"),
        -42: ("tmfoErr", "Too many files open"),
        -43: ("fnfErr", "File not found"),
        -44: ("wPrErr", "Disk is write-protected"),
        -45: ("fLckdErr", "File is locked"),
        -46: ("vLckdErr", "Volume is locked"),
        -47: ("fBsyErr", "File is busy"),
        -48: ("dupFNErr", "Duplicate filename"),
        -49: ("opWrErr", "File already open with write permission"),
        -50: ("paramErr", "Parameter error"),
        -51: ("rfNumErr", "Reference number error"),
        -54: ("permErr", "Permission error"),
        -61: ("wrPermErr", "Write permissions error"),
        -108: ("memFullErr", "Not enough memory"),
        -120: ("dirNFErr", "Directory not found"),
        -128: ("userCanceledErr", "User canceled"),
        -192: ("resNotFound", "Resource not found"),
        -5000: ("afpAccessDenied", "AFP access denied"),
        -10810: ("kLSUnknownErr", "Launch Services unknown error"),
        -10814: ("kLSApplicationNotFoundErr", "Application not found"),
        -25291: ("errSecAuthFailed", "Authorization/authentication failed"),
        -25293: ("errSecDuplicateItem", "Duplicate item in keychain"),
        -25294: ("errSecItemNotFound", "Item not found in keychain"),
        -25299: ("errSecInteractionNotAllowed", "Interaction not allowed"),
        -25300: ("errSecDecode", "Unable to decode data"),
        -25308: ("errSecMissingEntitlement", "Missing entitlement"),
        -34018: ("errSecMissingEntitlement", "Missing entitlement for keychain access"),
        -67030: ("errSecCSUnsigned", "Code is not signed"),
        -67049: ("errSecCSBadResource", "Sealed resource is invalid"),
        -67050: ("errSecCSResourceNotSupported", "Resource envelope is obsolete"),
        -67061: ("errSecCSSignatureFailed", "Code signature validation failed"),
        -67062: ("errSecCSBadObjectFormat", "Invalid object format"),
        -10863: ("kAudioHardwareUnspecifiedError", "Unspecified audio hardware error"),
    ]

    static let ioReturnTable: [UInt32: (String, String)] = [
        0x00000000: ("kIOReturnSuccess", "No error"),
        0xE00002BC: ("kIOReturnNotReady", "Device not ready"),
        0xE00002BD: ("kIOReturnNotAttached", "Device not attached"),
        0xE00002BE: ("kIOReturnBusy", "Device busy"),
        0xE00002BF: ("kIOReturnInternalError", "Internal error"),
        0xE00002C0: ("kIOReturnNoDevice", "No such device"),
        0xE00002C1: ("kIOReturnStillOpen", "Device still open"),
        0xE00002C2: ("kIOReturnCannotLock", "Cannot acquire lock"),
        0xE00002C3: ("kIOReturnNotOpen", "Device not open"),
        0xE00002C4: ("kIOReturnExclusiveAccess", "Exclusive access required"),
        0xE00002C7: ("kIOReturnUnsupported", "Unsupported function"),
        0xE00002C8: ("kIOReturnVMError", "Virtual memory error"),
        0xE00002C9: ("kIOReturnBadMessageID", "Bad message ID"),
        0xE00002CA: ("kIOReturnAborted", "Operation aborted"),
        0xE00002CB: ("kIOReturnNoBandwidth", "No bandwidth available"),
        0xE00002CC: ("kIOReturnNotResponding", "Device not responding"),
        0xE00002CD: ("kIOReturnIsoTooOld", "Isochronous request too old"),
        0xE00002CE: ("kIOReturnIsoTooNew", "Isochronous request too new"),
        0xE00002D0: ("kIOReturnInvalid", "Invalid parameter"),
        0xE00002D3: ("kIOReturnNotFound", "Not found"),
        0xE00002D5: ("kIOReturnNoMemory", "Out of memory"),
        0xE00002D6: ("kIOReturnNoResources", "Insufficient resources"),
        0xE00002D7: ("kIOReturnIPCError", "IPC error"),
        0xE00002D8: ("kIOReturnNoInterrupt", "No interrupt"),
        0xE00002EB: ("kIOReturnError", "General error"),
        0xE00002ED: ("kIOReturnNoCompletion", "No completion"),
        0xE00002EE: ("kIOReturnNoMedia", "No media"),
        0xE00002F0: ("kIOReturnBadMedia", "Bad media"),
        0xE0000005: ("kIOReturnLockedRead", "Device read locked"),
        0xE0000006: ("kIOReturnLockedWrite", "Device write locked"),
        0xE000000B: ("kIOReturnPortExists", "Port already exists"),
        0xE00000B5: ("kIOReturnTimeout", "Operation timed out"),
        0xE00000B8: ("kIOReturnOffline", "Device offline"),
        0xE00000C0: ("kIOReturnNoChannels", "No DMA channels available"),
        0xE00000C1: ("kIOReturnNoSpace", "No space"),
        0xE0004061: ("kIOUSBPipeStalled", "USB pipe stalled"),
    ]

    static let machErrorTable: [Int32: (String, String)] = [
        0: ("KERN_SUCCESS", "Success"),
        1: ("KERN_INVALID_ADDRESS", "Specified address is not currently valid"),
        2: ("KERN_PROTECTION_FAILURE", "Specified memory is valid, but does not permit the required forms of access"),
        3: ("KERN_NO_SPACE", "The address range specified is already in use or no address range of the specified size could be found"),
        4: ("KERN_INVALID_ARGUMENT", "The function requested was not applicable to this type of argument"),
        5: ("KERN_FAILURE", "The function could not be performed"),
        6: ("KERN_RESOURCE_SHORTAGE", "A system resource could not be allocated"),
        7: ("KERN_NOT_RECEIVER", "The task in question does not hold receive rights for the port argument"),
        8: ("KERN_NO_ACCESS", "Bogus access restriction"),
        9: ("KERN_MEMORY_FAILURE", "During a page fault, the target address refers to a memory object that has been destroyed"),
        10: ("KERN_MEMORY_ERROR", "During a page fault, the memory object indicated that the data could not be returned"),
        14: ("KERN_ALREADY_IN_SET", "The receive right is already a member of the portset"),
        15: ("KERN_NOT_IN_SET", "The receive right is not a member of a port set"),
        16: ("KERN_NAME_EXISTS", "The name already denotes a right in the task"),
        17: ("KERN_ABORTED", "The operation was aborted"),
        18: ("KERN_INVALID_NAME", "The name doesn't denote a right in the task"),
        20: ("KERN_INVALID_RIGHT", "Bitmask of legal values is properly right"),
        21: ("KERN_INVALID_VALUE", "The bitmask of valid values is not valid"),
        23: ("KERN_INVALID_CAPABILITY", "The supplied port capability is improper"),
        24: ("KERN_RIGHT_EXISTS", "The task already has send or receive rights for the port"),
        26: ("KERN_INVALID_HOST", "Target host isn't actually a host"),
        27: ("KERN_MEMORY_PRESENT", "Attempt to supply an already present memory object"),
        28: ("KERN_MEMORY_DATA_MOVED", "Memory has been moved"),
        29: ("KERN_MEMORY_RESTART_COPY", "Restart the affected memory copy"),
        30: ("KERN_INVALID_PROCESSOR_SET", "An argument applied to assert processor set privilege was not a processor set control port"),
        31: ("KERN_POLICY_LIMIT", "The specified scheduling attributes exceed the thread's limits"),
        32: ("KERN_INVALID_POLICY", "The specified scheduling policy is not currently enabled for the processor set"),
        33: ("KERN_INVALID_OBJECT", "The external memory manager failed to initialize the memory object"),
        37: ("KERN_POLICY_STATIC", "A catch-all for otherwise uncategorized policy-static errors"),
        41: ("KERN_INSUFFICIENT_BUFFER_SIZE", "The buffer is too small for the returned data"),
        46: ("KERN_DENIED", "Denied by security policy"),
        49: ("KERN_CODESIGN_ERROR", "The requested property cannot be changed at this time"),
        50: ("KERN_NOT_SUPPORTED", "The provided control port is not supported"),
        52: ("KERN_NOT_WAITING", "Thread is not waiting"),
    ]

    static let httpStatusTable: [Int: (String, String)] = [
        100: ("Continue", "The server has received the request headers and the client should proceed to send the request body"),
        101: ("Switching Protocols", "The server is switching protocols as requested"),
        200: ("OK", "The request has succeeded"),
        201: ("Created", "The request has been fulfilled and a new resource has been created"),
        202: ("Accepted", "The request has been accepted for processing, but not completed"),
        204: ("No Content", "The server has fulfilled the request but there is no content to send"),
        301: ("Moved Permanently", "The resource has been permanently moved to a new URL"),
        302: ("Found", "The resource has been temporarily moved to a different URL"),
        304: ("Not Modified", "The resource has not been modified since the last request"),
        307: ("Temporary Redirect", "The resource has been temporarily moved; use same method"),
        308: ("Permanent Redirect", "The resource has been permanently moved; use same method"),
        400: ("Bad Request", "The server cannot process the request due to client error"),
        401: ("Unauthorized", "Authentication is required and has failed or not been provided"),
        403: ("Forbidden", "The server understood the request but refuses to authorize it"),
        404: ("Not Found", "The requested resource could not be found"),
        405: ("Method Not Allowed", "The request method is not supported for the requested resource"),
        408: ("Request Timeout", "The server timed out waiting for the request"),
        409: ("Conflict", "The request conflicts with the current state of the server"),
        410: ("Gone", "The resource is no longer available and will not be available again"),
        413: ("Payload Too Large", "The request entity is larger than limits defined by server"),
        422: ("Unprocessable Entity", "The request was well-formed but semantically erroneous"),
        429: ("Too Many Requests", "The user has sent too many requests in a given amount of time"),
        500: ("Internal Server Error", "An unexpected condition was encountered by the server"),
        501: ("Not Implemented", "The server does not support the functionality required to fulfill the request"),
        502: ("Bad Gateway", "The server received an invalid response from the upstream server"),
        503: ("Service Unavailable", "The server is currently unable to handle the request"),
        504: ("Gateway Timeout", "The upstream server failed to send a request in time"),
    ]
}
