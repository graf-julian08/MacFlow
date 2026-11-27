import Foundation

/// User-facing failure. Every message is written for the person who dropped
/// the file: what failed and, where possible, why.
struct MacFlowError: LocalizedError, Sendable {
    let message: String
    var detail: String?

    init(_ message: String, detail: String? = nil) {
        self.message = message
        self.detail = detail
    }

    var errorDescription: String? { message }
    var failureReason: String? { detail }

    static let cancelled = MacFlowError("Cancelled")

    static func unsupported(_ what: String) -> MacFlowError {
        MacFlowError("\(what) is not supported for this file.")
    }

    static func decode(_ name: String, _ detail: String? = nil) -> MacFlowError {
        MacFlowError("“\(name)” could not be read.", detail: detail)
    }

    static func encode(_ what: String, _ detail: String? = nil) -> MacFlowError {
        MacFlowError("Could not write the \(what) file.", detail: detail)
    }

    static func validation(_ detail: String) -> MacFlowError {
        MacFlowError("The result failed verification and was discarded.", detail: detail)
    }
}

extension Error {
    /// Best human-readable description, never an empty string.
    var userMessage: String {
        if let error = self as? MacFlowError {
            if let detail = error.detail, !detail.isEmpty { return "\(error.message) \(detail)" }
            return error.message
        }
        if self is CancellationError { return "Cancelled" }
        let text = (self as NSError).localizedDescription
        return text.isEmpty ? String(describing: self) : text
    }

    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let error = self as? MacFlowError, error.message == MacFlowError.cancelled.message { return true }
        let ns = self as NSError
        return ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError
    }
}
