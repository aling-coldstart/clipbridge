import AppKit
import CryptoKit
import UniformTypeIdentifiers

/// Fingerprints of what a clip contains. Other apps rewrite the pasteboard without the
/// user copying anything (clipboard managers, security tools that turn a copied image
/// into a temp .png file); comparing signatures keeps that from being synced again.
enum ClipSignature {
    static func text(_ text: String) -> String {
        "text:" + sha256(Data(text.utf8))
    }

    /// Hashes the decoded pixels, so the same picture matches whatever its encoding
    /// (PNG, TIFF, re-saved by another app). Data that will not decode is hashed as is.
    static func image(_ data: Data) -> String {
        pixelSignature(data) ?? "image-bytes:" + sha256(data)
    }

    /// A lone image file counts as that image: some apps replace a copied image with a
    /// file holding it. Anything else is identified by path, size and modification time.
    static func files(_ urls: [URL], maxImageFileBytes: Int64 = 32 * 1024 * 1024) -> String {
        if urls.count == 1, let signature = imageFileSignature(urls[0], maxBytes: maxImageFileBytes) {
            return signature
        }
        return "files:" + urls.map(fingerprint).joined(separator: "\n")
    }

    private static func imageFileSignature(_ url: URL, maxBytes: Int64) -> String? {
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return nil }
        let (size, _) = sizeAndDate(of: url)
        guard size > 0, size <= maxBytes, let data = try? Data(contentsOf: url) else { return nil }
        return pixelSignature(data)
    }

    /// Largest picture we decode to compare pixels (about 400 MB of RGBA).
    private static let maxPixels = 100_000_000

    private static func pixelSignature(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0, width * height <= maxPixels else { return nil }
        // Draw in the picture's own colour space when possible, so no colour matching
        // changes the samples.
        let ownSpace = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: ownSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let pixels = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var hasher = SHA256()
        hasher.update(data: Data("\(width)x\(height):".utf8))
        hasher.update(bufferPointer: UnsafeRawBufferPointer(start: pixels, count: width * height * 4))
        return "image:" + hex(hasher.finalize())
    }

    /// Path, size and modification time; for a folder, the totals of everything inside.
    private static func fingerprint(_ url: URL) -> String {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return "\(url.path)|missing" }
        guard isDir.boolValue else {
            let (size, modified) = sizeAndDate(of: url)
            return "\(url.path)|\(size)|\(modified)"
        }
        var count = 0
        var total: Int64 = 0
        var newest: TimeInterval = 0
        if let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let child as URL in walker {
                guard (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let (size, modified) = sizeAndDate(of: child)
                count += 1
                total += size
                newest = max(newest, modified)
            }
        }
        return "\(url.path)|dir|\(count)|\(total)|\(newest)"
    }

    private static func sizeAndDate(of url: URL) -> (Int64, TimeInterval) {
        // Not URL.resourceValues: a URL caches those, and would hide a later edit.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, modified)
    }

    private static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The content both clipboards currently hold: the last clip sent to or received from
/// Windows. A pasteboard change with the same signature is a rewrite, not a new copy.
struct SyncedContent {
    /// Windows deletes received files after this long, so a repeat is then sent again.
    let maxAge: TimeInterval
    private var signature: String?
    private var since = Date.distantPast

    init(maxAge: TimeInterval) { self.maxAge = maxAge }

    func isRepeat(_ candidate: String, now: Date = Date()) -> Bool {
        candidate == signature && now.timeIntervalSince(since) < maxAge
    }

    mutating func record(_ signature: String, now: Date = Date()) {
        self.signature = signature
        since = now
    }

    mutating func forget() {
        signature = nil
    }
}
