import Foundation

enum LogSource {
    case file(URL)
    case unifiedLog(predicate: String?)
    case stdin
}
