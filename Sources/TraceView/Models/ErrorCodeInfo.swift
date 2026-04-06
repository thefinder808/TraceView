import Foundation

struct ErrorCodeInfo: Identifiable {
    let id = UUID()
    let domain: ErrorDomain
    let code: Int32
    let symbolicName: String
    let description: String
    let hexValue: String?

    var formattedCode: String {
        if let hex = hexValue {
            return "Decimal: \(code)  |  Hex: \(hex)"
        }
        return "Decimal: \(code)"
    }
}
