import Foundation
import Darwin

enum TaildropSmokeTest {
    static func run() async {
        let filename = "tailsync-ios-smoke-test-\(Int(Date().timeIntervalSince1970)).txt"
        guard let baseURLString = ProcessInfo.processInfo.environment["TAILSYNC_SMOKE_PEER_API_URL"],
              let baseURL = URL(string: baseURLString) else {
            print("TAILSYNC_SMOKE_RESULT missing TAILSYNC_SMOKE_PEER_API_URL")
            fflush(stdout)
            exit(2)
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let escapedFilename = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        components?.percentEncodedPath = "/" + (basePath.isEmpty ? "v0/put" : basePath + "/v0/put") + "/" + escapedFilename

        guard let url = components?.url else {
            print("TAILSYNC_SMOKE_RESULT invalid-url")
            fflush(stdout)
            exit(2)
        }

        let payload = Data("TailSync iPhone Taildrop smoke test \(Date())\n".utf8)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 30
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")

        do {
            let (_, response) = try await URLSession.shared.upload(for: request, from: payload)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("TAILSYNC_SMOKE_RESULT status=\(statusCode) url=\(url.absoluteString)")
            fflush(stdout)
            exit(statusCode == 200 ? 0 : 1)
        } catch {
            print("TAILSYNC_SMOKE_RESULT error=\(error.localizedDescription) url=\(url.absoluteString)")
            fflush(stdout)
            exit(1)
        }
    }
}
