import UIKit

/// Mirrors `processImage` in Web/src/components/MetallicPaint.tsx — converts
/// a UIImage into a depth-field (R channel) + shape mask (A channel) texture
/// that the metallic shader samples. The depth field is produced by 200 Jacobi
/// relaxation passes seeded from the icon boundary, identical to the Web build.
enum MetallicPaintImage {
    struct Processed {
        let width: Int
        let height: Int
        /// RGBA8 pixels (depth in R/G/B, mask in A) ready for MTLTexture upload.
        let pixels: [UInt8]
    }

    /// One per (image, cropTransparent) key. Preprocessing (decode, downscale, 100 SOR passes)
    /// takes ~200 ms in Release and 1.5 s or more in Debug, so:
    ///   - concurrent callers share ONE computation per key (the launch prewarm and the
    ///     welcome icon used to compute the same field side by side, doubling the work);
    ///   - the result is kept on disk (Caches) for the next launches, keyed by the app build
    ///     (an asset change ships in a new build);
    ///   - `didBecomeReady` is posted on the main queue once a key is available, so the launch
    ///     splash can end exactly when the welcome icon can draw.
    // nonisolated(unsafe): every access goes through `cacheLock`.
    private nonisolated(unsafe) static var cache: [String: Processed] = [:]
    private nonisolated(unsafe) static var inFlight: [String: DispatchGroup] = [:]
    private static let cacheLock = NSLock()

    /// Posted on the main queue with `object` = the cache key when a processed image is ready.
    static let didBecomeReady = Notification.Name("MetallicPaintImage.didBecomeReady")

    static func cacheKey(imageName: String, cropTransparent: Bool) -> String {
        "\(imageName)::\(cropTransparent ? 1 : 0)"
    }

    static func isReady(imageName: String, cropTransparent: Bool = false) -> Bool {
        let key = cacheKey(imageName: imageName, cropTransparent: cropTransparent)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key] != nil
    }

    static func processed(imageName: String, cropTransparent: Bool = false) -> Processed? {
        let key = cacheKey(imageName: imageName, cropTransparent: cropTransparent)
        return resolve(key: key) {
            guard let image = UIImage(named: imageName),
                  let raw = sampleRGBA(from: image) else { return nil }
            return process(raw: raw, cropTransparent: cropTransparent)
        }
    }

    /// Rasterize an SF Symbol into the same depth-field mask the shader uses
    /// for bundled icons. Cached per symbol name — the Jacobi pass is expensive.
    static func processedSymbol(_ systemName: String) -> Processed? {
        resolve(key: "symbol-fill::\(systemName)") {
            guard let image = rasterizedSymbol(systemName),
                  let raw = sampleRGBA(from: image) else { return nil }
            return process(raw: raw, cropTransparent: true)
        }
    }

    /// Memory cache → a computation already under way (waited for) → disk cache → `compute`.
    /// Blocks the calling thread while computing: call it off the main thread.
    private static func resolve(key: String, compute: () -> Processed?) -> Processed? {
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        if let running = inFlight[key] {
            cacheLock.unlock()
            running.wait()
            cacheLock.lock()
            defer { cacheLock.unlock() }
            return cache[key]
        }
        let group = DispatchGroup()
        group.enter()
        inFlight[key] = group
        cacheLock.unlock()

        var result = loadFromDisk(key: key)
        if result == nil {
            result = compute()
            if let result { saveToDisk(result, key: key) }
        }

        cacheLock.lock()
        if let result { cache[key] = result }
        inFlight[key] = nil
        cacheLock.unlock()
        group.leave()
        if result != nil {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: didBecomeReady, object: key)
            }
        }
        return result
    }

    // MARK: - Disk cache

    private static var diskDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MetallicPaint", isDirectory: true)
    }

    /// Changes whenever the shipped images can have changed: the build number, plus the size and
    /// date of the compiled asset catalog (a new icon in a debug build keeps the build number).
    /// Contains no "-", which separates it from the key in the file name.
    private static let diskStamp: String = {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        var catalog = "0"
        if let car = Bundle.main.url(forResource: "Assets", withExtension: "car"),
           let attrs = try? FileManager.default.attributesOfItem(atPath: car.path) {
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let date = Int64((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            catalog = "\(size)x\(date)"
        }
        let raw = "v2_\(build)_\(catalog)"
        return String(raw.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
    }()

    private static func diskURL(key: String) -> URL? {
        let safe = key.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return diskDirectory?.appendingPathComponent("\(diskStamp)-\(String(safe)).rgba")
    }

    /// File layout: width (UInt32 LE), height (UInt32 LE), then width × height × 4 bytes.
    private static func loadFromDisk(key: String) -> Processed? {
        guard let url = diskURL(key: key), let data = try? Data(contentsOf: url), data.count > 8 else { return nil }
        let width = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian })
        let height = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian })
        guard width > 0, height > 0, data.count == 8 + width * height * 4 else { return nil }
        return Processed(width: width, height: height, pixels: [UInt8](data.dropFirst(8)))
    }

    private static func saveToDisk(_ processed: Processed, key: String) {
        guard let dir = diskDirectory, let url = diskURL(key: key) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var data = Data(capacity: 8 + processed.pixels.count)
        var w = UInt32(processed.width).littleEndian
        var h = UInt32(processed.height).littleEndian
        withUnsafeBytes(of: &w) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &h) { data.append(contentsOf: $0) }
        data.append(contentsOf: processed.pixels)
        try? data.write(to: url, options: .atomic)
        // Older builds' files: drop them (they are recomputed, never needed again).
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            let prefix = diskStamp + "-"
            for file in files where !file.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func rasterizedSymbol(_ systemName: String) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: 200, weight: .bold)
        guard let symbol = UIImage(systemName: systemName, withConfiguration: config)?
            .withTintColor(.white, renderingMode: .alwaysOriginal) else { return nil }
        let side: CGFloat = 256
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { _ in
            let glyph = side * 0.78
            let origin = (side - glyph) / 2
            symbol.draw(in: CGRect(x: origin, y: origin, width: glyph, height: glyph))
        }
    }

    // MARK: - Pipeline

    private static func sampleRGBA(from image: UIImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let cg = image.cgImage else { return nil }
        // Web uses 500–1000 for browser perf budgets. On-device Swift with
        // bounds checking is much slower per pixel, so we cap the depth-field
        // input at 360px — visually indistinguishable when the icon renders at
        // <80pt, and keeps the 200-pass relaxation under ~600 ms in Debug.
        let maxSide = 360
        let minSide = 200
        var w = cg.width
        var h = cg.height
        let scale: CGFloat
        if w > maxSide || h > maxSide || w < minSide || h < minSide {
            if w > h {
                scale = w > maxSide ? CGFloat(maxSide) / CGFloat(w)
                      : w < minSide ? CGFloat(minSide) / CGFloat(w) : 1
            } else {
                scale = h > maxSide ? CGFloat(maxSide) / CGFloat(h)
                      : h < minSide ? CGFloat(minSide) / CGFloat(h) : 1
            }
        } else {
            scale = 1
        }
        w = Int((CGFloat(w) * scale).rounded())
        h = Int((CGFloat(h) * scale).rounded())

        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: cs, bitmapInfo: info
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (bytes, w, h)
    }

    private static func process(raw: (pixels: [UInt8], width: Int, height: Int), cropTransparent: Bool) -> Processed {
        var data = raw.pixels
        var width = raw.width
        var height = raw.height

        if cropTransparent {
            // Optional crop pass — mirrors Web. Drops fully-transparent border.
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width {
                    let a = data[(y * width + x) * 4 + 3]
                    if a <= 16 { continue }
                    if x < minX { minX = x }
                    if y < minY { minY = y }
                    if x > maxX { maxX = x }
                    if y > maxY { maxY = y }
                }
            }
            if maxX >= minX, maxY >= minY {
                let padding = Int((Double(max(maxX - minX + 1, maxY - minY + 1)) * 0.035).rounded(.up))
                let cropX = max(0, minX - padding)
                let cropY = max(0, minY - padding)
                let cropRight = min(width, maxX + padding + 1)
                let cropBottom = min(height, maxY + padding + 1)
                let nw = cropRight - cropX
                let nh = cropBottom - cropY
                var cropped = [UInt8](repeating: 0, count: nw * nh * 4)
                for y in 0..<nh {
                    let srcRow = (cropY + y) * width + cropX
                    let dstRow = y * nw
                    for x in 0..<nw {
                        let s = (srcRow + x) * 4
                        let d = (dstRow + x) * 4
                        cropped[d] = data[s]
                        cropped[d + 1] = data[s + 1]
                        cropped[d + 2] = data[s + 2]
                        cropped[d + 3] = data[s + 3]
                    }
                }
                data = cropped
                width = nw
                height = nh
            }
        }

        let size = width * height
        var alphaValues = [Float](repeating: 0, count: size)
        var shapeMask = [UInt8](repeating: 0, count: size)
        var boundaryMask = [UInt8](repeating: 0, count: size)
        var backgroundCandidate = [UInt8](repeating: 0, count: size)
        var backgroundMask = [UInt8](repeating: 0, count: size)

        for index in 0..<size {
            let pixel = index * 4
            let r = Int(data[pixel])
            let g = Int(data[pixel + 1])
            let b = Int(data[pixel + 2])
            let a = Int(data[pixel + 3])
            let isNearWhite = r > 238 && g > 238 && b > 238 && (max(r, g, b) - min(r, g, b)) < 18
            let isLowAlphaSidebar = cropTransparent && a < 96
            backgroundCandidate[index] = (a < 5 || isLowAlphaSidebar || (a > 180 && isNearWhite)) ? 1 : 0
        }

        // Flood-fill from the edges to mark connected background pixels.
        var queue = [Int](); queue.reserveCapacity(size)
        var qHead = 0
        func enqueueBackground(_ idx: Int) {
            if backgroundCandidate[idx] == 0 || backgroundMask[idx] != 0 { return }
            backgroundMask[idx] = 1
            queue.append(idx)
        }
        for x in 0..<width {
            enqueueBackground(x)
            enqueueBackground((height - 1) * width + x)
        }
        for y in 1..<(height - 1) {
            enqueueBackground(y * width)
            enqueueBackground(y * width + width - 1)
        }
        while qHead < queue.count {
            let index = queue[qHead]; qHead += 1
            let x = index % width
            if x > 0 { enqueueBackground(index - 1) }
            if x < width - 1 { enqueueBackground(index + 1) }
            if index >= width { enqueueBackground(index - width) }
            if index < size - width { enqueueBackground(index + width) }
        }

        for index in 0..<size {
            let pixel = index * 4
            let a = Int(data[pixel + 3])
            let normalized: Float
            if backgroundMask[index] != 0 {
                normalized = 0
            } else if cropTransparent {
                normalized = max(0, min(1, (Float(a) - 72) / 144))
            } else {
                normalized = Float(a) / 255
            }
            alphaValues[index] = normalized
            shapeMask[index] = normalized > 0.1 ? 1 : 0
        }

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                if shapeMask[index] == 0 { continue }
                if x == 0 || x == width - 1 || y == 0 || y == height - 1
                    || shapeMask[index - 1] == 0 || shapeMask[index + 1] == 0
                    || shapeMask[index - width] == 0 || shapeMask[index + width] == 0 {
                    boundaryMask[index] = 1
                }
            }
        }

        // 100 SOR relaxation passes (Web does 200) with unsafe buffer access
        // — bounds checks dominate this hot loop in Debug builds.
        var depth = [Float](repeating: 0, count: size)
        let omega: Float = 1.85
        depth.withUnsafeMutableBufferPointer { d in
            shapeMask.withUnsafeBufferPointer { s in
                boundaryMask.withUnsafeBufferPointer { b in
                    for _ in 0..<100 {
                        for y in 1..<(height - 1) {
                            let rowStart = y * width
                            for x in 1..<(width - 1) {
                                let index = rowStart + x
                                if s[index] == 0 || b[index] != 0 { continue }
                                var sum: Float = 0
                                if s[index + 1] != 0 { sum += d[index + 1] }
                                if s[index - 1] != 0 { sum += d[index - 1] }
                                if s[index + width] != 0 { sum += d[index + width] }
                                if s[index - width] != 0 { sum += d[index - width] }
                                let next = (0.01 + sum) / 4
                                d[index] = omega * next + (1 - omega) * d[index]
                            }
                        }
                    }
                }
            }
        }

        var maxValue: Float = 0
        for v in depth where v > maxValue { maxValue = v }
        if maxValue == 0 { maxValue = 1 }

        var output = [UInt8](repeating: 0, count: size * 4)
        for index in 0..<size {
            let pixel = index * 4
            let d = depth[index] / maxValue
            let gray = UInt8(min(255, max(0, Int((255.0 * (1 - d * d)).rounded()))))
            output[pixel] = gray
            output[pixel + 1] = gray
            output[pixel + 2] = gray
            output[pixel + 3] = UInt8(min(255, max(0, Int((alphaValues[index] * 255).rounded()))))
        }

        return Processed(width: width, height: height, pixels: output)
    }
}
