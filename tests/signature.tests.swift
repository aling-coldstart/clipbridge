// Tests for the Mac agent's content signatures (mac/Sources/Signature.swift).
// Plain Swift, no XCTest:
//   xcrun swiftc -o signature-tests mac/Sources/Signature.swift tests/signature.tests.swift && ./signature-tests
import AppKit

@main
enum SignatureTests {
    static var failures = 0

    static func check(_ name: String, _ passed: Bool) {
        print((passed ? "ok    " : "FAIL  ") + name)
        if !passed { failures += 1 }
    }

    /// A small opaque test picture; different seeds give different pixels.
    static func bitmap(seed: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<24 {
            for x in 0..<32 {
                let red = CGFloat((x * 7 + seed) % 256) / 255
                let green = CGFloat((y * 9 + seed) % 256) / 255
                rep.setColor(NSColor(deviceRed: red, green: green, blue: 0.5, alpha: 1), atX: x, y: y)
            }
        }
        return rep
    }

    static func write(_ data: Data, _ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    static func main() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("clipbridge-tests-\(getpid())")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Text
        check("same text has the same signature", ClipSignature.text("hello") == ClipSignature.text("hello"))
        check("different text has a different signature", ClipSignature.text("hello") != ClipSignature.text("hello!"))

        // Images
        let picture = bitmap(seed: 1)
        let png = picture.representation(using: .png, properties: [:])!
        let interlaced = picture.representation(using: .png, properties: [.interlaced: true])!
        let tiff = picture.tiffRepresentation!
        let otherPng = bitmap(seed: 2).representation(using: .png, properties: [:])!
        check("test data: the two PNG encodings differ byte for byte", png != interlaced)
        check("the same picture encoded twice has the same signature",
              ClipSignature.image(png) == ClipSignature.image(interlaced))
        check("the same picture as PNG and as TIFF has the same signature",
              ClipSignature.image(png) == ClipSignature.image(tiff))
        check("a different picture has a different signature",
              ClipSignature.image(png) != ClipSignature.image(otherPng))
        let junk = Data("not an image".utf8)
        check("undecodable image data still gets a stable signature",
              ClipSignature.image(junk) == ClipSignature.image(junk)
                && ClipSignature.image(junk) != ClipSignature.image(Data("other".utf8)))
        check("an image never has the signature of a text", ClipSignature.image(png) != ClipSignature.text("hello"))

        // A copied image that another app turned into a file (the bug this guards against)
        let saved = try write(png, "Clipboard_Screenshot_1.png", in: tmp)
        check("an image saved to a lone file has the image's signature",
              ClipSignature.files([saved]) == ClipSignature.image(png))
        let reencoded = try write(interlaced, "Clipboard_Screenshot_2.png", in: tmp)
        check("a lone file holding the same picture re-encoded has the image's signature",
              ClipSignature.files([reencoded]) == ClipSignature.image(png))
        let otherSaved = try write(otherPng, "other.png", in: tmp)
        check("a lone file holding a different picture has a different signature",
              ClipSignature.files([otherSaved]) != ClipSignature.image(png))
        check("two image files are a file list, not an image",
              ClipSignature.files([saved, otherSaved]) != ClipSignature.image(png)
                && ClipSignature.files([saved, otherSaved]) != ClipSignature.image(otherPng))
        check("an image file over the size limit is treated as a plain file",
              ClipSignature.files([saved], maxImageFileBytes: 10) != ClipSignature.image(png))
        let fake = try write(junk, "fake.png", in: tmp)
        check("a .png file that is not an image is treated as a plain file",
              ClipSignature.files([fake]) == ClipSignature.files([fake])
                && ClipSignature.files([fake]) != ClipSignature.image(junk))

        // Plain files and folders
        let doc = try write(Data("v1".utf8), "notes.txt", in: tmp)
        let before = ClipSignature.files([doc])
        check("an unchanged file keeps its signature", before == ClipSignature.files([doc]))
        try Data("version 2".utf8).write(to: doc)
        check("an edited file gets a new signature", before != ClipSignature.files([doc]))
        check("different files have different signatures",
              ClipSignature.files([doc]) != ClipSignature.files([fake]))
        let folder = tmp.appendingPathComponent("folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try write(Data("a".utf8), "a.txt", in: folder)
        let folderBefore = ClipSignature.files([folder])
        check("an unchanged folder keeps its signature", folderBefore == ClipSignature.files([folder]))
        _ = try write(Data("b".utf8), "b.txt", in: folder)
        check("a folder with a new file gets a new signature", folderBefore != ClipSignature.files([folder]))
        let missing = tmp.appendingPathComponent("gone.txt")
        check("a missing file does not crash and differs from an existing one",
              ClipSignature.files([missing]) != ClipSignature.files([doc]))

        // What both clipboards currently hold
        let start = Date()
        var synced = SyncedContent(maxAge: 60)
        check("nothing is a repeat before anything was synced", !synced.isRepeat("text:a", now: start))
        synced.record("text:a", now: start)
        check("the content just synced is a repeat", synced.isRepeat("text:a", now: start.addingTimeInterval(5)))
        check("other content is not a repeat", !synced.isRepeat("text:b", now: start.addingTimeInterval(5)))
        check("the same content is sent again once the synced copy has expired",
              !synced.isRepeat("text:a", now: start.addingTimeInterval(61)))
        synced.record("text:a", now: start)
        synced.forget()
        check("nothing is a repeat after forgetting", !synced.isRepeat("text:a", now: start))

        try? fm.removeItem(at: tmp)
        print(failures == 0 ? "all passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
