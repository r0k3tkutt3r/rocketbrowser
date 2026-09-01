import AppKit
import Foundation
import Vision
import WebKit

/// Reads text out of the images on a page so find-in-page can match it.
///
/// Nothing is downloaded and nothing is uploaded: the pixels come from a snapshot of the
/// web view itself, and Vision runs the recognition on-device. Working from a rendered
/// snapshot rather than the image files means CSS background images, `<canvas>`, inline
/// SVG and video frames are all covered — anything the page actually draws — and the
/// coordinates come out in viewport space, where the page can use them directly.
///
/// The trade is that only what is on screen can be read. `FindController` re-scans when
/// scrolling settles, so more matches appear as the user moves down the page.
final class ImageTextScanner {

    struct Region {
        let key: String
        /// Viewport CSS pixels, already clipped to the visible area.
        let rect: CGRect
    }

    /// A scan either produces matches or is replaced by a newer one. Reporting the
    /// second case matters as much as the first: the caller shows "reading images…"
    /// while a scan is outstanding, so a scan that ended silently would leave that
    /// label up for good.
    enum Outcome {
        case matches([CGRect])
        case superseded
    }

    /// Vision gains nothing from a 2560-pixel-wide crop, and costs roughly the square of
    /// the dimension. Normalised bounding boxes are resolution-independent, so shrinking
    /// the pixels leaves every coordinate untouched.
    private static let maxRecognitionDimension: CGFloat = 1400

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "SearchImageText") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "SearchImageText") }
    }

    /// Recognised lines, keyed by region. Text is cached rather than matches, so editing
    /// the query re-filters what Vision already read instead of running it again.
    private var cache: [String: [VNRecognizedText]] = [:]
    private let queue = DispatchQueue(label: "rocket.imagetext", qos: .userInitiated)
    /// Bumped on every new scan and on navigation; late results carrying an old value
    /// belong to a query or a page that is gone.
    private var generation = 0

    private static var hasWarmedUp = false

    /// Vision loads its recognition model on the first request, and a cold load can take
    /// orders of magnitude longer than any single scan afterwards. Opening the find bar
    /// starts that load in the background, so it overlaps with the user typing rather
    /// than stalling the first search. Main-thread only, so the flag needs no locking.
    static func warmUp() {
        guard isEnabled, !hasWarmedUp else { return }
        hasWarmedUp = true
        DispatchQueue.global(qos: .utility).async {
            guard let context = CGContext(data: nil, width: 32, height: 32,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = context.makeImage() else { return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        }
    }

    func reset() {
        cache.removeAll()
        generation &+= 1
    }

    func cancel() {
        generation &+= 1
    }

    // MARK: - Scanning

    func scan(webView: WKWebView, query: String, completion: @escaping (Outcome) -> Void) {
        generation &+= 1
        let token = generation

        webView.evaluateJavaScript("window.__rocketFind.imageRegions();") { [weak self] value, _ in
            guard let self else { completion(.superseded); return }
            guard token == self.generation else { completion(.superseded); return }
            guard let info = value as? [String: Any],
                  let raw = info["regions"] as? [[String: Any]], !raw.isEmpty,
                  let viewportWidth = info["viewportWidth"] as? Double, viewportWidth > 0 else {
                completion(.matches([]))
                return
            }

            let scroll = CGPoint(x: info["scrollX"] as? Double ?? 0,
                                 y: info["scrollY"] as? Double ?? 0)
            let regions: [Region] = raw.compactMap { item in
                guard let key = item["key"] as? String,
                      let x = item["x"] as? Double, let y = item["y"] as? Double,
                      let width = item["width"] as? Double, let height = item["height"] as? Double
                else { return nil }
                return Region(key: key, rect: CGRect(x: x, y: y, width: width, height: height))
            }
            guard !regions.isEmpty else { completion(.matches([])); return }

            let missing = regions.filter { self.cache[$0.key] == nil }
            guard !missing.isEmpty else {
                completion(.matches(self.matches(for: query, in: regions, scroll: scroll)))
                return
            }

            self.snapshot(webView) { image in
                guard token == self.generation else { completion(.superseded); return }
                guard let image else {
                    completion(.matches(self.matches(for: query, in: regions, scroll: scroll)))
                    return
                }
                // Derived from the snapshot rather than assumed: this absorbs the backing
                // scale, the page zoom (⌘+/⌘-) and any pinch magnification in one number.
                let pixelScale = CGFloat(image.width) / CGFloat(viewportWidth)

                self.queue.async {
                    // Recognised in parallel: each region is independent, and running
                    // them one after another was the bulk of the wait.
                    var recognised = [[VNRecognizedText]](repeating: [], count: missing.count)
                    let lock = NSLock()
                    DispatchQueue.concurrentPerform(iterations: missing.count) { index in
                        let lines = ImageTextScanner.recognise(
                            image, region: missing[index].rect, pixelScale: pixelScale)
                        lock.lock()
                        recognised[index] = lines
                        lock.unlock()
                    }
                    DispatchQueue.main.async {
                        guard token == self.generation else { completion(.superseded); return }
                        for (index, region) in missing.enumerated() {
                            self.cache[region.key] = recognised[index]
                        }
                        completion(.matches(self.matches(for: query, in: regions, scroll: scroll)))
                    }
                }
            }
        }
    }

    private func snapshot(_ webView: WKWebView, completion: @escaping (CGImage?) -> Void) {
        // A null rect means the whole visible viewport, which is exactly the area the
        // region rectangles were measured against.
        webView.takeSnapshot(with: WKSnapshotConfiguration()) { image, _ in
            guard let image else { completion(nil); return }
            var rect = CGRect(origin: .zero, size: image.size)
            completion(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        }
    }

    static func recognise(_ image: CGImage, region: CGRect, pixelScale: CGFloat) -> [VNRecognizedText] {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // CGImage cropping counts from the top-left, the same way the viewport does, so
        // the region rectangle only needs scaling.
        let crop = CGRect(x: region.minX * pixelScale,
                          y: region.minY * pixelScale,
                          width: region.width * pixelScale,
                          height: region.height * pixelScale)
            .integral
            .intersection(bounds)

        guard crop.width >= 16, crop.height >= 16,
              let cropped = image.cropping(to: crop) else { return [] }
        let scaled = downscaled(cropped, to: maxRecognitionDimension)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Off deliberately: this feeds a search index, so the literal glyphs matter more
        // than a linguistically plausible sentence.
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: scaled, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first }
    }

    static func downscaled(_ image: CGImage, to maxDimension: CGFloat) -> CGImage {
        let longest = CGFloat(max(image.width, image.height))
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let width = Int((CGFloat(image.width) * scale).rounded())
        let height = Int((CGFloat(image.height) * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private func matches(for query: String, in regions: [Region], scroll: CGPoint) -> [CGRect] {
        guard !query.isEmpty else { return [] }
        var results: [CGRect] = []
        for region in regions {
            guard let lines = cache[region.key] else { continue }
            for line in lines {
                for range in ImageTextScanner.ranges(of: query, in: line.string) {
                    guard let box = try? line.boundingBox(for: range) else { continue }
                    results.append(ImageTextScanner.documentRect(normalized: box.boundingBox,
                                                                 region: region.rect,
                                                                 scroll: scroll))
                }
            }
        }
        return results
    }

    // MARK: - Pure helpers

    /// Vision reports boxes normalised to the cropped region with a bottom-left origin.
    /// The page counts CSS pixels from the top-left of the document, so the box is scaled
    /// back up, flipped, and shifted by the region's position and the scroll offset.
    static func documentRect(normalized box: CGRect, region: CGRect, scroll: CGPoint) -> CGRect {
        CGRect(x: scroll.x + region.minX + box.minX * region.width,
               y: scroll.y + region.minY + (1 - box.maxY) * region.height,
               width: box.width * region.width,
               height: box.height * region.height)
    }

    /// Every occurrence of `query`, ignoring case and accents the way a browser's find
    /// bar does. Empty matches are stepped over so a pathological query cannot spin.
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: query,
                                     options: [.caseInsensitive, .diacriticInsensitive],
                                     range: start..<text.endIndex) {
            found.append(range)
            start = range.upperBound > range.lowerBound
                ? range.upperBound
                : text.index(after: range.lowerBound)
        }
        return found
    }
}
