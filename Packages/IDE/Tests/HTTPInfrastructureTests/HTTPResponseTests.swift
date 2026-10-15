import Foundation
import Testing
import HTTPInfrastructure

struct HTTPResponseTests {
    @Test func retryAfterAcceptsSecondsAndHTTPDatesWithoutSchedulingRetries() throws {
        let now = Date(timeIntervalSince1970: 784_111_717) // Sun, 06 Nov 1994 08:48:37 GMT
        for header in [
            "120",
            "Sun, 06 Nov 1994 08:50:37 GMT",
            "Sunday, 06-Nov-94 08:50:37 GMT",
            "Sun Nov 6 08:50:37 1994"
        ] {
            let response = HTTPResponse(status: 503, data: Data(), headers: ["ReTrY-AfTeR": header])
            #expect(response.retryAfter(relativeTo: now) == 120)
            #expect(throws: HTTPError.status(code: 503, retryAfter: 120)) { try response.requireSuccess(now: now) }
        }
        let past = HTTPResponse(status: 429, data: Data(), headers: ["Retry-After": "Sun, 06 Nov 1994 08:40:37 GMT"])
        #expect(past.retryAfter(relativeTo: now) == 0)
        for header in ["-1", "NaN", "infinity", "", "1.5", "not a date"] {
            #expect(HTTPResponse(status: 429, data: Data(), headers: ["Retry-After": header])
                .retryAfter(relativeTo: now) == nil)
        }
        #expect(throws: Never.self) { try HTTPResponse(status: 204, data: Data()).requireSuccess() }
    }
}
