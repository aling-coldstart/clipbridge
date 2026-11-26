import AppKit

enum ClipKind: String {
    case text, image, files
}

/// A clip captured on the Mac, staged in `dir` (kind.txt + text.txt | image.png).
/// For `.files`, the original file URLs are uploaded directly from `fileURLs`.
struct OutgoingClip {
    let id: String
    let kind: ClipKind
    let dir: URL
    let fileURLs: [URL]
    /// Total size of `fileURLs` (0 for text and image clips).
    let bytes: Int64
    /// Identifies the content; see `ClipSignature`.
    let signature: String
}

enum CaptureResult {
    case clip(OutgoingClip)
    case skipped(String)
    case tooLarge(Int64)
}

private let concealedTypes: Set<NSPasteboard.PasteboardType> = [
    NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
    NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
]

private func totalSize(of urls: [URL]) -> Int64 {
    let fm = FileManager.default
    var total: Int64 = 0
    for url in urls {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
        if isDir.boolValue, let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let child as URL in walker {
                total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        } else {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
    return total
}

private func pngData(from pb: NSPasteboard) -> Data? {
    if let png = pb.data(forType: .png) { return png }
    guard let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

/// Read the general pasteboard. Priority: files > text > image.
func captureClip(from pb: NSPasteboard) throws -> CaptureResult {
    let types = Set(pb.types ?? [])
    if !types.isDisjoint(with: concealedTypes) { return .skipped("concealed (password manager)") }

    let id = newClipID(prefix: "m")
    let dir = Config.outDir.appendingPathComponent(id)
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    let fileURLs = (pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []

    let kind: ClipKind
    let signature: String
    var bytes: Int64 = 0
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if !fileURLs.isEmpty {
        bytes = totalSize(of: fileURLs)
        if bytes > Config.maxFileBytes { try? FileManager.default.removeItem(at: dir); return .tooLarge(bytes) }
        kind = .files
        signature = ClipSignature.files(fileURLs)
    } else if let text = pb.string(forType: .string), !text.isEmpty {
        try text.write(to: dir.appendingPathComponent("text.txt"), atomically: true, encoding: .utf8)
        kind = .text
        signature = ClipSignature.text(text)
    } else if let png = pngData(from: pb) {
        try png.write(to: dir.appendingPathComponent("image.png"))
        kind = .image
        signature = ClipSignature.image(png)
    } else {
        try? FileManager.default.removeItem(at: dir)
        return .skipped("no text, image or files")
    }
    try kind.rawValue.write(to: dir.appendingPathComponent("kind.txt"), atomically: true, encoding: .utf8)
    return .clip(OutgoingClip(id: id, kind: kind, dir: dir, fileURLs: kind == .files ? fileURLs : [], bytes: bytes,
                              signature: signature))
}

/// Put a clip folder received from Windows onto the pasteboard. Returns its kind and
/// the signature of its content.
func applyClip(at dir: URL, to pb: NSPasteboard) throws -> (kind: ClipKind, signature: String) {
    let raw = try String(contentsOf: dir.appendingPathComponent("kind.txt"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let kind = ClipKind(rawValue: raw) else { throw ClipError.badKind(raw) }
    switch kind {
    case .text:
        let text = try String(contentsOf: dir.appendingPathComponent("text.txt"), encoding: .utf8)
        pb.clearContents()
        pb.setString(text, forType: .string)
        return (kind, ClipSignature.text(text))
    case .image:
        let png = try Data(contentsOf: dir.appendingPathComponent("image.png"))
        guard let image = NSImage(data: png) else { throw ClipError.badImage }
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(png, forType: .png)
        if let tiff = image.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        return (kind, ClipSignature.image(png))
    case .files:
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir.appendingPathComponent("files"), includingPropertiesForKeys: nil)
        guard !urls.isEmpty else { throw ClipError.emptyFiles }
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        return (kind, ClipSignature.files(urls))
    }
}

enum ClipError: Error {
    case badKind(String)
    case badImage
    case emptyFiles
}
