import AppKit

@main
struct FeatureTests {
    static func main() throws {
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0, 255])
        let request = try LinkUploader.request(png: png)
        precondition(request.url?.absoluteString == "https://catbox.moe/user/api.php")
        precondition(request.httpMethod == "POST")
        let contentType = request.value(forHTTPHeaderField: "Content-Type")!
        let boundary = contentType.components(separatedBy: "boundary=")[1]
        let body = request.httpBody!
        precondition(body.range(of: png) != nil, "PNG bytes must survive multipart encoding")
        precondition(body.starts(with: Data("--\(boundary)\r\n".utf8)))
        precondition(body.suffix(Data("--\(boundary)--\r\n".utf8).count) == Data("--\(boundary)--\r\n".utf8))
        precondition(body.range(of: Data("name=\"reqtype\"\r\n\r\nfileupload\r\n".utf8)) != nil)
        precondition(body.range(of: Data("name=\"fileToUpload\"; filename=\"Screenshot.png\"".utf8)) != nil)

        func response(_ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        let link = try LinkUploader.link(data: Data("https://files.catbox.moe/abc123.png\n".utf8), response: response(200))
        precondition(link.absoluteString == "https://files.catbox.moe/abc123.png")
        for value in ["", "rate limited", "http://files.catbox.moe/a.png", "https://evil.example/a.png",
                      "https://files.catbox.moe.evil.example/a.png", "https://files.catbox.moe/a.html",
                      "https://files.catbox.moe/a.png?x=y", "https://user@files.catbox.moe/a.png"] {
            precondition((try? LinkUploader.link(data: Data(value.utf8), response: response(200))) == nil,
                         "Unexpected response accepted: \(value)")
        }
        for status in [400, 413, 429, 500] {
            precondition((try? LinkUploader.link(data: Data(link.absoluteString.utf8), response: response(status))) == nil)
        }
        print("PASS: multipart PNG upload and response validation")

        func image(text: String) -> CGImage {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 320,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 1200, height: 320).fill()
            (text as NSString).draw(at: NSPoint(x: 40, y: 100), withAttributes: [
                .font: NSFont.systemFont(ofSize: 58), .foregroundColor: NSColor.black
            ])
            NSGraphicsContext.restoreGraphicsState()
            return rep.cgImage!
        }
        let recognized = try TextRecognizer.recognize(image(text: "ShotMark 123\nПривет мир"))
        precondition(recognized.contains("ShotMark") && recognized.contains("123"), recognized)
        precondition(recognized.lowercased().contains("привет"), recognized)
        let empty = try TextRecognizer.recognize(image(text: ""))
        precondition(empty.isEmpty, "Blank image must produce no text")
        print("PASS: local English/Russian OCR and blank image")
    }
}
