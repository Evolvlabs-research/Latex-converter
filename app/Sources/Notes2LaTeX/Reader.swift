// Lecture des formules sans Python : le modèle converti en Core ML (export_coreml.py) et, en Swift,
// le même prétraitement que data.py et predict.py, la recherche en faisceau et la détokenisation.
import CoreML
import ImageIO

let imageHeight = 128, maxWidth = 1024, margin = 8, maxLen = 200
let pad = 0, bos = 1, eos = 2, unk = 3

/// Image en niveaux de gris, 0 à 255, ligne par ligne depuis le haut.
struct Gray: Equatable {
    var width: Int, height: Int
    var px: [UInt8]
    init(width: Int, height: Int, px: [UInt8]? = nil) {
        self.width = width; self.height = height
        self.px = px ?? [UInt8](repeating: 0, count: width * height)
    }
    subscript(x: Int, y: Int) -> UInt8 {
        get { px[y * width + x] }
        set { px[y * width + x] = newValue }
    }
}

final class FormulaReader {
    let encoder: MLModel, decoder: MLModel, itos: [String]

    /// `dir` contient Encoder et Decoder (.mlmodelc compilés par build.sh, ou .mlpackage compilés ici) et vocab.json.
    static func load(from dir: URL) async throws -> FormulaReader {
        func model(_ name: String) async throws -> MLModel {
            var url = dir.appendingPathComponent(name + ".mlmodelc")
            if !FileManager.default.fileExists(atPath: url.path) {
                url = try await MLModel.compileModel(at: dir.appendingPathComponent(name + ".mlpackage"))
            }
            let config = MLModelConfiguration()
            config.computeUnits = .cpuOnly  // formes variables à chaque pas : le GPU recompilerait sans cesse
            return try MLModel(contentsOf: url, configuration: config)
        }
        let itos = try JSONDecoder().decode([String].self, from: Data(contentsOf: dir.appendingPathComponent("vocab.json")))
        return FormulaReader(encoder: try await model("Encoder"), decoder: try await model("Decoder"), itos: itos)
    }

    private init(encoder: MLModel, decoder: MLModel, itos: [String]) {
        self.encoder = encoder; self.decoder = decoder; self.itos = itos
    }

    /// Photo ou trace InkML -> LaTeX.
    func read(_ file: URL) throws -> String {
        let img = file.pathExtension.lowercased() == "inkml" ? renderInk(try readInkML(file).strokes) : try loadPhoto(file)
        return detokenize(try beamSearch(img).filter { $0 > unk }.map { itos[$0] })
    }

    /// Les k débuts de formule les plus probables à chaque pas, comme `Im2Latex.beam_search` (k = 5, fixé à l'export).
    func beamSearch(_ img: Gray) throws -> [Int] {
        let k = 5
        let image = try MLMultiArray(shape: [1, 1, NSNumber(value: img.height), NSNumber(value: img.width)], dataType: .float32)
        let ip = image.dataPointer.assumingMemoryBound(to: Float.self)
        for i in img.px.indices { ip[i] = Float(img.px[i]) / 255 }
        let memory = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": image]))
            .featureValue(for: "memory")!.multiArrayValue!

        var seqs = [[Int]](repeating: [bos], count: k)
        var scores = [Float](repeating: -.infinity, count: k)
        scores[0] = 0  // au départ, une seule hypothèse
        var done = [Bool](repeating: false, count: k)
        for _ in 0..<(maxLen - 1) {
            let n = seqs[0].count
            let tokens = try MLMultiArray(shape: [NSNumber(value: k), NSNumber(value: n)], dataType: .int32)
            let tp = tokens.dataPointer.assumingMemoryBound(to: Int32.self)
            for (i, s) in seqs.enumerated() { for (j, t) in s.enumerated() { tp[i * n + j] = Int32(t) } }
            let logp = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["tokens": tokens, "memory": memory]))
                .featureValue(for: "logp")!.multiArrayValue!
            let v = logp.shape[1].intValue, s0 = logp.strides[0].intValue, s1 = logp.strides[1].intValue
            let lp = logp.dataPointer.assumingMemoryBound(to: Float.self)
            var cands: [(score: Float, row: Int, tok: Int)] = []
            for i in 0..<k where scores[i] > -.infinity {
                if done[i] { cands.append((scores[i], i, pad)); continue }  // une hypothèse finie ne s'allonge que de PAD
                for t in 0..<v { cands.append((scores[i] + lp[i * s0 + t * s1], i, t)) }
            }
            cands.sort { ($0.score, -$0.row, -$0.tok) > ($1.score, -$1.row, -$1.tok) }  // égalités : ordre fixe
            let best = cands.prefix(k)  // toujours assez : la meilleure hypothèse propose tout le vocabulaire
            seqs = best.map { seqs[$0.row] + [$0.tok] }
            done = best.map { done[$0.row] || $0.tok == eos }
            scores = best.map(\.score)
            if done.allSatisfy({ $0 }) { break }
        }
        let row = seqs[scores.indices.max { scores[$0] < scores[$1] }!].dropFirst()  // sans BOS
        return Array(row.prefix { $0 != eos })
    }
}

/// Tokens -> LaTeX : « \alpha x » garde son espace, comme `detokenize` de data.py.
func detokenize(_ tokens: [String]) -> String {
    var out = ""
    for tok in tokens {
        if out.contains(#/\\[a-zA-Z]+$/#), tok.first?.isLetter == true { out += " " }
        out += tok
    }
    return out
}

// MARK: - InkML

struct ReadError: Error { let message: String }

/// Traits et formule attendue d'un fichier InkML (normalizedLabel, sinon label).
func readInkML(_ url: URL) throws -> (strokes: [[CGPoint]], label: String?) {
    let doc = try XMLDocument(contentsOf: url)
    let traces = try doc.nodes(forXPath: "//*[local-name()='trace']").compactMap(\.stringValue)
    let strokes = traces.map { t in
        t.split(separator: ",").map { p in
            let v = p.split(whereSeparator: \.isWhitespace).prefix(2).map { Double($0) ?? 0 }
            return CGPoint(x: v[0], y: v.count > 1 ? v[1] : 0)
        }
    }.filter { !$0.isEmpty }
    guard !strokes.isEmpty else { throw ReadError(message: "Aucun trait dans \(url.lastPathComponent).") }
    var labels: [String: String] = [:]
    for a in try doc.nodes(forXPath: "//*[local-name()='annotation']") {
        if let e = a as? XMLElement, let type = e.attribute(forName: "type")?.stringValue { labels[type] = e.stringValue }
    }
    return (strokes, labels["normalizedLabel"] ?? labels["label"])
}

/// Échelle et largeur en pixels de l'image d'une formule de taille w x h, comme `image_width` de data.py.
func imageWidth(_ w: Double, _ h: Double) -> (scale: Double, width: Int) {
    let scale = min(Double(imageHeight - 2 * margin) / max(h, w / 16, 1e-6), Double(maxWidth - 2 * margin) / max(w, 1e-6))
    return (scale, max(32, min(maxWidth, Int(w * scale) + 2 * margin)))
}

/// Traits -> traits blancs de 3 px sur fond noir, hauteur fixe, comme `render` de data.py (sans augmentation).
func renderInk(_ strokes: [[CGPoint]]) -> Gray {
    let pts = strokes.joined()
    let x0 = pts.map(\.x).min()!, y0 = pts.map(\.y).min()!
    let (scale, width) = imageWidth(pts.map(\.x).max()! - x0, pts.map(\.y).max()! - y0)
    var img = Gray(width: width, height: imageHeight)
    for s in strokes {
        // (int) de Pillow : coordonnées tronquées
        let p = s.map { (Int(($0.x - x0) * scale + Double(margin)), Int(($0.y - y0) * scale + Double(margin))) }
        for (a, b) in zip(p, p.count == 1 ? p : Array(p.dropFirst())) { pillowWideLine(&img, a, b) }
    }
    return img
}

// Tracé de Pillow 13 (libImaging/Draw.c : ImagingDrawWideLine, polygon_generic) porté au pixel près :
// le modèle a appris sur ces images, un autre tracé (Core Graphics) change environ une lecture sur cinq.

private func roundUp<T: BinaryFloatingPoint>(_ f: T) -> Int { Int(f >= 0 ? (f + 0.5).rounded(.down) : -(abs(f) + 0.5).rounded(.down)) }
private func roundDown<T: BinaryFloatingPoint>(_ f: T) -> Int { Int(f >= 0 ? (f - 0.5).rounded(.up) : -(abs(f) - 0.5).rounded(.up)) }

private struct Edge {
    var xmin: Int, xmax: Int, ymin: Int, ymax: Int, x0: Int, y0: Int, dx: Float
    init(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
        xmin = min(x0, x1); xmax = max(x0, x1); ymin = min(y0, y1); ymax = max(y0, y1)
        dx = y0 == y1 ? 0 : Float(x1 - x0) / Float(y1 - y0)
        self.x0 = x0; self.y0 = y0
    }
    func x(at y: Int) -> Float { Float(y - y0) * dx + Float(x0) }
}

private func hline(_ img: inout Gray, _ x0: Int, _ y: Int, _ x1: Int) {
    guard y >= 0, y < img.height, x0 < img.width, x1 >= 0 else { return }
    let a = max(x0, 0), b = min(x1, img.width - 1)
    if a <= b { for x in a...b { img[x, y] = 255 } }
}

/// Segment de largeur 3 : parallélogramme entre les deux points, décalé de la normale arrondie.
private func pillowWideLine(_ img: inout Gray, _ p0: (Int, Int), _ p1: (Int, Int)) {
    let (x0, y0) = p0, (x1, y1) = p1, dx = x1 - x0, dy = y1 - y0
    if dx == 0 && dy == 0 {
        if x0 >= 0, x0 < img.width, y0 >= 0, y0 < img.height { img[x0, y0] = 255 }
        return
    }
    let big = Double(dx * dx + dy * dy).squareRoot(), small = Double(3 - 1) / 2
    let rmax = Double(roundUp(small)) / big, rmin = Double(roundDown(small)) / big
    let dxmin = roundDown(rmin * Double(dy)), dxmax = roundDown(rmax * Double(dy))
    let dymin = roundDown(rmin * Double(dx)), dymax = roundDown(rmax * Double(dx))
    let v = [(x0 - dxmin, y0 + dymax), (x1 - dxmin, y1 + dymax), (x1 + dxmax, y1 - dymin), (x0 + dxmax, y0 - dymin)]
    fillPolygon(&img, (0..<4).map { Edge(v[$0].0, v[$0].1, v[($0 + 1) % 4].0, v[($0 + 1) % 4].1) })
}

/// Remplissage par lignes de balayage, comme polygon_generic (sans transparence).
private func fillPolygon(_ img: inout Gray, _ edges: [Edge]) {
    var ymin = img.height - 1, ymax = 0, table: [Edge] = []
    for e in edges {
        ymin = min(ymin, e.ymin); ymax = max(ymax, e.ymax)
        if e.ymin == e.ymax { hline(&img, e.xmin, e.ymin, e.xmax) } else { table.append(e) }
    }
    ymin = max(ymin, 0); ymax = min(ymax, img.height)
    guard ymin <= ymax else { return }
    for y in ymin...ymax {
        var xx: [Float] = []
        for (i, cur) in table.enumerated() where y >= cur.ymin && y <= cur.ymax {
            xx.append(cur.x(at: y))
            if y == cur.ymax && y < ymax {
                xx.append(xx.last!)  // polygones cohérents
            } else if (y == cur.ymin || y == cur.ymax) && cur.dx != 0 {
                for other in table[..<i] where (y == other.ymin || y == other.ymax) && other.dx != 0 {
                    guard xx.last!.rounded() == other.x(at: y).rounded() else { continue }  // coin entre deux arêtes
                    let offset = y == cur.ymax ? -1 : 1
                    let adj = cur.x(at: y + offset)
                    guard y + offset >= other.ymin && y + offset <= other.ymax else { continue }
                    let adjOther = other.x(at: y + offset), last = xx.last!
                    if last > adj + 1 && last > adjOther + 1 {
                        xx[xx.count - 1] = max(adj, adjOther).rounded() + 1
                    } else if last < adj - 1 && last < adjOther - 1 {
                        xx[xx.count - 1] = min(adj, adjOther).rounded() - 1
                    }
                    break
                }
            }
        }
        xx.sort()
        for i in stride(from: 1, to: xx.count, by: 2) { hline(&img, roundUp(xx[i - 1]), y, roundDown(xx[i])) }
    }
}

// MARK: - Photo

/// Photo (encre sombre sur papier clair) -> traits blancs sur noir, comme `load_photo` de predict.py.
func loadPhoto(_ url: URL) throws -> Gray {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [  // pleine taille, tournée selon l'EXIF
              kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: max(w, h)] as CFDictionary)
    else { throw ReadError(message: "Image illisible : \(url.lastPathComponent).") }
    var img = grayscale(cg)
    img.px = autocontrastLUT(img.px).map { 255 - $0 }  // contraste auto puis inversion
    // shortcut: seuil fixe, sensible à l'éclairage ; passer à un seuil adaptatif si les photos sont inégales.
    img.px = img.px.map { $0 > 110 ? 255 : 0 }
    img = crop(img)
    let scale = min(Double(imageHeight - 2 * margin) / Double(img.height), Double(maxWidth - 2 * margin) / Double(img.width))
    img = resizeLanczos(img, width: max(1, Int(Double(img.width) * scale)), height: max(1, Int(Double(img.height) * scale)))
    var canvas = Gray(width: max(32, img.width + 2 * margin), height: imageHeight)
    let top = (imageHeight - img.height) / 2
    for y in 0..<img.height { for x in 0..<img.width { canvas[margin + x, top + y] = img[x, y] } }
    return canvas
}

/// Niveaux de gris avec les poids de Pillow (« L ») ; la transparence devient du papier blanc.
func grayscale(_ cg: CGImage) -> Gray {
    let w = cg.width, h = cg.height
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    rgba.withUnsafeMutableBytes { buf in
        // espace de couleur de l'image : pas de conversion, Pillow n'en fait pas non plus
        let space = cg.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var img = Gray(width: w, height: h)
    for i in 0..<(w * h) {
        let r = Int(rgba[4 * i]), g = Int(rgba[4 * i + 1]), b = Int(rgba[4 * i + 2])
        img.px[i] = UInt8((r * 19595 + g * 38470 + b * 7471 + 0x8000) >> 16)
    }
    return img
}

/// `ImageOps.autocontrast(img, cutoff=2)` : 2 % des pixels écartés à chaque bout, le reste étiré sur 0…255.
func autocontrastLUT(_ px: [UInt8]) -> [UInt8] {
    var hist = [Int](repeating: 0, count: 256)
    for v in px { hist[Int(v)] += 1 }
    for range in [Array(0..<256), Array((0..<256).reversed())] {
        var cut = px.count * 2 / 100
        for i in range where cut > 0 {
            let c = min(cut, hist[i])
            hist[i] -= c; cut -= c
        }
    }
    guard let lo = hist.firstIndex(where: { $0 > 0 }), let hi = hist.lastIndex(where: { $0 > 0 }), hi > lo else { return px }
    let scale = 255.0 / Double(hi - lo), offset = -Double(lo) * scale
    let lut = (0..<256).map { UInt8(clamping: Int(Double($0) * scale + offset)) }
    return px.map { lut[Int($0)] }
}

/// Plus petit rectangle qui contient les pixels non noirs (`getbbox`) ; l'image entière s'il n'y en a pas.
func crop(_ img: Gray) -> Gray {
    var x0 = img.width, y0 = img.height, x1 = -1, y1 = -1
    for y in 0..<img.height { for x in 0..<img.width where img[x, y] != 0 {
        x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
    } }
    guard x1 >= 0 else { return img }
    var out = Gray(width: x1 - x0 + 1, height: y1 - y0 + 1)
    for y in 0..<out.height { for x in 0..<out.width { out[x, y] = img[x0 + x, y0 + y] } }
    return out
}

/// `Image.resize(..., Image.LANCZOS)` de Pillow, au pixel près : deux passes (largeur puis hauteur), coefficients entiers.
func resizeLanczos(_ img: Gray, width: Int, height: Int) -> Gray {
    if width == img.width && height == img.height { return img }
    func lanczos(_ x: Double) -> Double {
        func sinc(_ x: Double) -> Double { x == 0 ? 1 : sin(x * .pi) / (x * .pi) }
        return -3 <= x && x < 3 ? sinc(x) * sinc(x / 3) : 0
    }
    /// Pour chaque pixel de sortie : premier pixel source et poids en virgule fixe (22 bits).
    func coeffs(_ inSize: Int, _ outSize: Int) -> [(min: Int, k: [Int])] {
        let scale = Double(inSize) / Double(outSize), filterscale = max(scale, 1), support = 3 * filterscale
        return (0..<outSize).map { xx in
            let center = (Double(xx) + 0.5) * scale
            let xmin = max(0, Int(center - support + 0.5)), xmax = min(inSize, Int(center + support + 0.5))
            let w = (xmin..<xmax).map { lanczos((Double($0) - center + 0.5) * (1 / filterscale)) }
            let total = w.reduce(0, +)
            return (xmin, w.map { v in let n = total != 0 ? v / total : v; return Int(n * Double(1 << 22) + (n < 0 ? -0.5 : 0.5)) })
        }
    }
    func clip8(_ v: Int) -> UInt8 { v >= (1 << 30) ? 255 : v <= 0 ? 0 : UInt8(v >> 22) }
    var src = img
    if width != img.width {
        let c = coeffs(img.width, width)
        var out = Gray(width: width, height: src.height)
        for y in 0..<src.height { for x in 0..<width {
            var ss = 1 << 21
            for (i, k) in c[x].k.enumerated() { ss += Int(src[c[x].min + i, y]) * k }
            out[x, y] = clip8(ss)
        } }
        src = out
    }
    if height != img.height {
        let c = coeffs(img.height, height)
        var out = Gray(width: src.width, height: height)
        for y in 0..<height { for x in 0..<src.width {
            var ss = 1 << 21
            for (i, k) in c[y].k.enumerated() { ss += Int(src[x, c[y].min + i]) * k }
            out[x, y] = clip8(ss)
        } }
        src = out
    }
    return src
}
