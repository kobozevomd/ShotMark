import Foundation

/// Anonymous Catbox uploads: https://catbox.moe/tools.php
/// The caller must obtain consent before sending the screenshot.
enum LinkUploader {
    enum UploadError: LocalizedError {
        case tooLarge, invalidResponse, http(Int)

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "PNG превышает лимит Catbox (200 МБ). Уменьшите область снимка."
            case .invalidResponse: return "Catbox не вернул ссылку на PNG. Попробуйте позже."
            case .http(let status): return "Catbox вернул ошибку HTTP \(status). Попробуйте позже."
            }
        }
    }

    static func request(png: Data) throws -> URLRequest {
        guard png.count <= 200 * 1024 * 1024 else { throw UploadError.tooLarge }
        let boundary = "ShotMark-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"reqtype\"\r\n\r\nfileupload\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"fileToUpload\"; filename=\"Screenshot.png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
        body.append(png)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "https://catbox.moe/user/api.php")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    static func link(data: Data, response: URLResponse) throws -> URL {
        guard let response = response as? HTTPURLResponse else { throw UploadError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw UploadError.http(response.statusCode) }
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: value), url.scheme == "https", url.host == "files.catbox.moe",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.pathExtension.lowercased() == "png", url.pathComponents.count == 2 else {
            throw UploadError.invalidResponse
        }
        return url
    }
}
