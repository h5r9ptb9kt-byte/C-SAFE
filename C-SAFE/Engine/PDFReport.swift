//
//  PDFReport.swift — C-SAFE
//  Rapport PDF lisible par la production : infos de la carte, statut de vérification,
//  une ligne par clip avec vignette, durée, résolution, cadence, codec, taille et empreinte.
//  Fonctionne sur Mac et iPhone (CoreGraphics + CoreText + AVFoundation + ImageIO, rien à installer).
//

import Foundation
import AVFoundation
import CoreGraphics
import CoreText
import ImageIO

enum PDFReport {

    // MARK: - Données (gardées en JSON dans Rapports_de_copie/.C-SAFE/rapports pour le rapport du jour)

    struct Clip: Codable {
        var name: String
        var size: Int64
        var kind: String          // « vidéo », « photo », « son »
        var duration: Double?     // secondes
        var resolution: String?
        var fps: String?
        var codec: String?
        var hash: String
        var thumb: Data?          // JPEG ~320 px
    }

    struct CardData: Codable {
        var project: String
        var day: String
        var display: String
        var label: String
        var cardName: String
        var date: String
        var files: Int
        var totalBytes: Int64
        var seconds: Int
        var speed: Int64
        var hash: String
        var verified: Bool
        var destinations: [String]
        var clips: [Clip]
        var extraFiles: Int = 0
    }

    static let videoExt: Set<String> = ["mp4", "mov", "mxf", "mts", "m2ts", "avi", "insv", "m4v", "braw", "r3d", "crm"]
    static let photoExt: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "dng", "arw", "cr2", "cr3", "nef", "raf", "rw2", "orf", "insp"]
    static let audioExt: Set<String> = ["wav", "bwf", "mp3", "aif", "aiff", "m4a"]

    /// Analyse les clips copiés (sur le premier disque, déjà vérifié) : vignettes + infos techniques.
    static func prepare(_ base: CardData, cardFolder: URL, files: [(rel: String, size: Int64)],
                        hashes: [String: String], progress: ((Int, Int) -> Void)? = nil) -> CardData {
        var data = base
        var extra = 0
        let media = files.filter { isMedia($0.rel) }.count
        var done = 0
        progress?(0, media)
        for f in files {
            let ext = (f.rel as NSString).pathExtension.lowercased()
            let url = cardFolder.appendingPathComponent(f.rel)
            var clip = Clip(name: f.rel, size: f.size, kind: "", hash: hashes[f.rel] ?? "")
            if videoExt.contains(ext) {
                clip.kind = "vidéo"
                autoreleasepool { describeVideo(url, into: &clip) }
            } else if photoExt.contains(ext) {
                clip.kind = "photo"
                autoreleasepool { describePhoto(url, into: &clip) }
            } else if audioExt.contains(ext) {
                clip.kind = "son"
                autoreleasepool { describeAudio(url, into: &clip) }
            } else {
                extra += 1
                continue
            }
            data.clips.append(clip)
            done += 1
            progress?(done, media)
        }
        data.extraFiles = extra
        return data
    }

    /// Écrit le PDF de la carte + ses données (pour le rapport du jour). Retourne l'URL du PDF.
    @discardableResult
    static func write(_ data: CardData, projectDir: URL, reportName: String) -> URL? {
        let rd = projectDir.appendingPathComponent(Naming.reportDir)
        let store = rd.appendingPathComponent(Naming.hiddenDir).appendingPathComponent("rapports")
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        if let json = try? JSONEncoder().encode(data) {
            try? json.write(to: store.appendingPathComponent("\(reportName).json"), options: .atomic)
        }
        let pdf = rd.appendingPathComponent("\(reportName)_rapport.pdf")
        let title = "Rapport de copie — \(data.display.split(separator: "/").last.map(String.init) ?? data.label)"
        return render(title: title, subtitle: "\(data.project) · \(data.day)", cards: [data], dayMode: false, to: pdf) ? pdf : nil
    }

    /// Rassemble toutes les cartes d'un jour dans un seul PDF : « J1_2026-11-04_rapport_du_jour.pdf ».
    static func dayReport(projectDir: URL, day: String) -> URL? {
        let rd = projectDir.appendingPathComponent(Naming.reportDir)
        let cards = savedCards(projectDir: projectDir).filter { $0.day == day }.sorted { $0.display < $1.display }
        guard !cards.isEmpty else { return nil }
        let pdf = rd.appendingPathComponent("\(day)_rapport_du_jour.pdf")
        return render(title: "Rapport du jour — \(day)", subtitle: cards[0].project, cards: cards, dayMode: true, to: pdf) ? pdf : nil
    }

    static func isMedia(_ rel: String) -> Bool {
        let ext = (rel as NSString).pathExtension.lowercased()
        return videoExt.contains(ext) || photoExt.contains(ext) || audioExt.contains(ext)
    }

    /// Nombre de cartes déjà prêtes pour le rapport du jour (sans les relire)
    static func savedCardCount(projectDir: URL, day: String) -> Int {
        let store = projectDir.appendingPathComponent(Naming.reportDir)
            .appendingPathComponent(Naming.hiddenDir).appendingPathComponent("rapports")
        return Naming.list(store).filter { $0.hasPrefix(day + "_") && $0.hasSuffix(".json") }.count
    }

    static func savedCards(projectDir: URL) -> [CardData] {
        let store = projectDir.appendingPathComponent(Naming.reportDir)
            .appendingPathComponent(Naming.hiddenDir).appendingPathComponent("rapports")
        return Naming.list(store).filter { $0.hasSuffix(".json") }.compactMap {
            guard let d = try? Data(contentsOf: store.appendingPathComponent($0)) else { return nil }
            return try? JSONDecoder().decode(CardData.self, from: d)
        }
    }

    // MARK: - Analyse des fichiers

    private static func describeVideo(_ url: URL, into clip: inout Clip) {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        if seconds.isFinite, seconds > 0 { clip.duration = seconds }
        if let track = asset.tracks(withMediaType: .video).first {
            let size = track.naturalSize.applying(track.preferredTransform)
            let w = Int(abs(size.width).rounded()), h = Int(abs(size.height).rounded())
            if w > 0, h > 0 { clip.resolution = "\(w)×\(h)" }
            let fps = track.nominalFrameRate
            if fps > 0 { clip.fps = fps.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(fps)) i/s" : String(format: "%.3g i/s", fps) }
            if let desc = (track.formatDescriptions as? [CMFormatDescription])?.first {
                clip.codec = codecName(CMFormatDescriptionGetMediaSubType(desc))
            }
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 320, height: 320)
            let at = CMTime(seconds: min(1.0, (clip.duration ?? 0) * 0.1), preferredTimescale: 600)
            if let img = try? gen.copyCGImage(at: at, actualTime: nil) { clip.thumb = jpeg(img) }
        }
    }

    private static func describePhoto(_ url: URL, into clip: inout Clip) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            clip.resolution = "\(w)×\(h)"
        }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 320]
        if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { clip.thumb = jpeg(img) }
    }

    private static func describeAudio(_ url: URL, into clip: inout Clip) {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        if seconds.isFinite, seconds > 0 { clip.duration = seconds }
        if let track = asset.tracks(withMediaType: .audio).first,
           let desc = (track.formatDescriptions as? [CMFormatDescription])?.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            clip.codec = "\(Int(asbd.mSampleRate / 1000)) kHz · \(asbd.mChannelsPerFrame) piste(s)"
        }
    }

    private static func codecName(_ code: FourCharCode) -> String {
        let names: [String: String] = ["avc1": "H.264", "hvc1": "H.265 (HEVC)", "hev1": "H.265 (HEVC)",
                                       "apco": "ProRes 422 Proxy", "apcs": "ProRes 422 LT", "apcn": "ProRes 422",
                                       "apch": "ProRes 422 HQ", "ap4h": "ProRes 4444", "ap4x": "ProRes 4444 XQ",
                                       "aprn": "ProRes RAW", "aprh": "ProRes RAW HQ", "mjpg": "Motion JPEG"]
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let s = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "?"
        return names[s] ?? s
    }

    private static func jpeg(_ img: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    // MARK: - Mise en page (A4, couleurs C-FOCUS)

    private static let W: CGFloat = 595, H: CGFloat = 842, M: CGFloat = 36
    private static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    private static let navy = rgb(0x0F1924), orange = rgb(0xE8742A), cream = rgb(0xF1EAD6),
                        ink = rgb(0x1D2733), gray = rgb(0x6B7A89), light = rgb(0xEEF1F4),
                        green = rgb(0x2FA874), red = rgb(0xD9443C)

    private final class Page {
        let ctx: CGContext
        var y: CGFloat = 0          // distance depuis le haut
        var number = 0
        let footer: String
        init(_ ctx: CGContext, footer: String) { self.ctx = ctx; self.footer = footer }

        func new() {
            if number > 0 { finish() }
            number += 1
            ctx.beginPDFPage(nil)
            y = M
        }
        func finish() {
            text("\(footer) — page \(number)", x: M, top: H - 24, size: 7.5, color: gray)
            ctx.endPDFPage()
        }
        func need(_ h: CGFloat) { if y + h > H - 40 { new() } }

        func rect(_ x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat, fill: CGColor, radius: CGFloat = 0) {
            let r = CGRect(x: x, y: H - top - h, width: w, height: h)
            ctx.setFillColor(fill)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }

        /// Texte sur une ligne (tronqué si besoin). `top` = haut de la ligne.
        @discardableResult
        func text(_ s: String, x: CGFloat, top: CGFloat, size: CGFloat, bold: Bool = false, mono: Bool = false,
                  color: CGColor, maxWidth: CGFloat = 520, alignRight: Bool = false) -> CGFloat {
            let name = mono ? "Menlo-Regular" : (bold ? "Helvetica-Bold" : "Helvetica")
            let font = CTFontCreateWithName(name as CFString, size, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
            var line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
            if CTLineGetTypographicBounds(line, nil, nil, nil) > Double(maxWidth) {
                let dots = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
                if let t = CTLineCreateTruncatedLine(line, Double(maxWidth), .middle, dots) { line = t }
            }
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.textPosition = CGPoint(x: alignRight ? x - width : x, y: H - top - size)
            CTLineDraw(line, ctx)
            return width
        }

        func image(_ data: Data?, x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat) {
            rect(x, top: top, w: w, h: h, fill: light, radius: 3)
            guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                text("pas d'aperçu", x: x + 14, top: top + h / 2 - 4, size: 7, color: gray, maxWidth: w)
                return
            }
            let iw = CGFloat(img.width), ih = CGFloat(img.height)
            let scale = min(w / iw, h / ih)
            let dw = iw * scale, dh = ih * scale
            ctx.draw(img, in: CGRect(x: x + (w - dw) / 2, y: H - top - h + (h - dh) / 2, width: dw, height: dh))
        }
    }

    private static func render(title: String, subtitle: String, cards: [CardData], dayMode: Bool, to url: URL) -> Bool {
        var box = CGRect(x: 0, y: 0, width: W, height: H)
        let meta: [CFString: Any] = [kCGPDFContextCreator: "C-SAFE · C-FOCUS", kCGPDFContextTitle: title]
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, meta as CFDictionary) else { return false }
        let page = Page(ctx, footer: "C-SAFE · C-FOCUS · \(title)")
        page.new()

        // Bandeau
        page.rect(0, top: 0, w: W, h: 78, fill: navy)
        page.rect(0, top: 78, w: W, h: 3, fill: orange)
        page.text("C-SAFE", x: M, top: 20, size: 22, bold: true, color: cream)
        page.text("par C-FOCUS", x: M, top: 46, size: 9, color: orange)
        page.text(title, x: W - M, top: 22, size: 13, bold: true, color: cream, maxWidth: 360, alignRight: true)
        page.text(subtitle, x: W - M, top: 42, size: 9.5, color: cream, maxWidth: 360, alignRight: true)
        page.y = 98

        if dayMode {
            let ok = cards.allSatisfy { $0.verified }
            let total = cards.reduce(Int64(0)) { $0 + $1.totalBytes }
            badge(page, ok: ok, text: ok ? "✓ \(cards.count) carte(s) copiées et vérifiées — \(OffloadJob.human(total)) au total"
                                         : "✗ Au moins une carte n'a pas été vérifiée : voir le détail")
            page.text("Cartes du jour", x: M, top: page.y, size: 11, bold: true, color: ink)
            page.y += 18
            for c in cards {
                page.need(16)
                page.text(c.verified ? "✓" : "✗", x: M, top: page.y, size: 9, bold: true, color: c.verified ? green : red)
                page.text(c.display.split(separator: "/").last.map(String.init) ?? c.display, x: M + 14, top: page.y, size: 9, bold: true, color: ink, maxWidth: 230)
                page.text("\(c.files) fichiers · \(OffloadJob.human(c.totalBytes)) · \(c.hash) · \(c.date)", x: M + 250, top: page.y, size: 8.5, color: gray, maxWidth: 270)
                page.y += 15
            }
            page.y += 10
        }

        for c in cards {
            cardSection(page, c, compactHeader: dayMode)
        }
        page.finish()
        ctx.closePDF()
        return true
    }

    private static func badge(_ page: Page, ok: Bool, text: String) {
        page.rect(M, top: page.y, w: W - 2 * M, h: 26, fill: ok ? rgb(0xE6F6EE) : rgb(0xFBE7E5), radius: 6)
        page.text(text, x: M + 10, top: page.y + 8, size: 10, bold: true, color: ok ? green : red, maxWidth: W - 2 * M - 20)
        page.y += 36
    }

    private static func cardSection(_ page: Page, _ c: CardData, compactHeader: Bool) {
        page.need(150)
        if compactHeader {
            page.rect(M, top: page.y, w: W - 2 * M, h: 22, fill: light, radius: 5)
            page.text(c.display, x: M + 8, top: page.y + 6, size: 10, bold: true, color: ink, maxWidth: W - 2 * M - 16)
            page.y += 30
        } else {
            badge(page, ok: c.verified, text: c.verified
                  ? "✓ Copie vérifiée (\(c.hash)) : chaque fichier relu sur chaque disque, toutes les copies sont identiques"
                  : "✗ Vérification en échec : ne formate pas la carte")
        }
        let info: [(String, String)] = [
            ("Projet", c.project), ("Jour", c.day), ("Dossier", c.display), ("Source", c.label),
            ("Carte d'origine", c.cardName), ("Date", c.date),
            ("Contenu", "\(c.files) fichiers · \(OffloadJob.human(c.totalBytes))"),
            ("Durée · débit", "\(c.seconds / 60) min \(c.seconds % 60) s · \(OffloadJob.human(c.speed))/s"),
            ("Vérification", "\(c.hash) — \(c.verified ? "OK" : "ÉCHEC")"),
        ]
        let colW = (W - 2 * M) / 2
        for (i, kv) in info.enumerated() {
            let x = M + CGFloat(i % 2) * colW
            if i % 2 == 0 && i > 0 { page.y += 15 }
            page.text(kv.0, x: x, top: page.y, size: 8, color: gray, maxWidth: 80)
            page.text(kv.1, x: x + 82, top: page.y, size: 8.5, bold: true, color: ink, maxWidth: colW - 90)
        }
        page.y += 20
        page.text("Disques", x: M, top: page.y, size: 8, color: gray)
        for d in c.destinations {
            page.text(d, x: M + 82, top: page.y, size: 8.5, color: d.hasPrefix("OK") ? ink : red, maxWidth: W - 2 * M - 82)
            page.y += 13
        }
        page.y += 8

        // Clips
        let rowH: CGFloat = 62
        if !c.clips.isEmpty {
            page.need(rowH + 20)
            page.text("Clips (\(c.clips.count))", x: M, top: page.y, size: 11, bold: true, color: ink)
            page.y += 18
        }
        for clip in c.clips {
            page.need(rowH)
            let top = page.y
            page.image(clip.thumb, x: M, top: top, w: 88, h: 50)
            let x = M + 98
            page.text((clip.name as NSString).lastPathComponent, x: x, top: top + 2, size: 10, bold: true, color: ink, maxWidth: 300)
            page.text(OffloadJob.human(clip.size), x: W - M, top: top + 2, size: 9, bold: true, color: ink, alignRight: true)
            var details: [String] = []
            if let d = clip.duration { details.append(timecode(d)) }
            if let r = clip.resolution { details.append(r) }
            if let f = clip.fps { details.append(f) }
            if let k = clip.codec { details.append(k) }
            if details.isEmpty { details.append(clip.kind) }
            page.text(details.joined(separator: " · "), x: x, top: top + 18, size: 8.5, color: ink, maxWidth: W - M - x)
            page.text("\(c.hash) \(clip.hash)", x: x, top: top + 33, size: 7, mono: true, color: gray, maxWidth: W - M - x)
            page.rect(M, top: top + rowH - 6, w: W - 2 * M, h: 0.5, fill: light)
            page.y += rowH
        }
        if c.extraFiles > 0 {
            page.need(16)
            page.text("+ \(c.extraFiles) fichier(s) annexe(s) de la carte (XML, index, vignettes caméra…), copiés et vérifiés aussi.",
                      x: M, top: page.y, size: 8, color: gray)
            page.y += 18
        }
        page.y += 14
    }

    private static func timecode(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }
}
