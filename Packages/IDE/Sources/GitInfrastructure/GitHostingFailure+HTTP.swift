import Foundation
import HTTPInfrastructure
import IDEApplication

extension GitHostingFailure {
    init(http error: HTTPError, publishing: Bool) {
        let kind: Kind
        var status: Int?
        var delay: TimeInterval?
        switch error {
        case .connection(let code): kind = code == .timedOut ? .timedOut : .connection
        case .transportFailure: kind = .connection
        case .redirectRejected(let code):
            kind = .redirectRejected
            status = code
        case .unexpectedResponseURL: kind = .redirectRejected
        case .responseTooLarge: kind = .responseTooLarge
        case .invalidRequest, .invalidPolicy, .invalidResponse: kind = .invalidResponse
        case .status(let code, let retryAfter):
            status = code
            delay = retryAfter
            switch code {
            case 401: kind = .unauthorized
            case 403: kind = .forbidden
            case 404: kind = .notFound
            case 409, 422: kind = .conflict
            case 429: kind = .rateLimited
            case 500...599: kind = .serviceUnavailable
            default: kind = .unexpectedStatus
            }
        }
        self.init(
            kind: kind,
            statusCode: status,
            retryAfter: delay,
            publicationMayHaveSucceeded: publishing &&
                ![.unauthorized, .forbidden, .notFound, .rateLimited].contains(kind)
        )
    }
}
