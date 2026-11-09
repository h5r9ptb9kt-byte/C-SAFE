//
//  PDFReport.swift — C-SAFE
//  Rapport PDF lisible par la production et le montage :
//  - résumé (clips, durée de rushes, volume, vitesse), caméra, format, plage de timecode
//  - une grille de clips (2 par ligne) : vignette, TC début → fin, durée, format, taille, empreinte
//  - rapport du jour : frise de synchro au timecode (toutes les caméras et le son sur le même axe)
//  Timecode lu dans : piste timecode des MP4/MOV, XML Sony (…M01.XML), BWF (bext + iXML) pour le son.
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
        // Timecode (v58)
        var tcFrames: Int? = nil  // TC de début, en images depuis 00:00:00:00
        var tcRate: Int? = nil    // images par seconde du TC (24, 25, 30…)
        var tcDrop: Bool? = nil   // drop-frame (29,97 / 59,94)
        var camera: String? = nil // « Sony ILME-FX2 »
        var lens: String? = nil
        var note: String? = nil   // son : « Sc 12 · Prise 3 »

        var shortName: String { (name as NSString).lastPathComponent }
        /// Début en secondes depuis minuit (pour la frise)
        var tcSeconds: Double? {
            guard let f = tcFrames, let r = tcRate, r > 0 else { return nil }
            return Double(f) / (tcDrop == true ? Double(r) * 1000 / 1001 : Double(r))
        }
        var tcIn: String? {
            guard let f = tcFrames, let r = tcRate else { return nil }
            return TC.string(f, rate: r, drop: tcDrop == true)
        }
        var tcOut: String? {
            guard let f = tcFrames, let r = tcRate, let d = duration else { return nil }
            let real = tcDrop == true ? Double(r) * 1000 / 1001 : Double(r)
            return TC.string(f + max(0, Int((d * real).rounded()) - 1), rate: r, drop: tcDrop == true)
        }
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
    /// Dossiers de la caméra qui ne contiennent pas de rushes (vignettes, proxys, index)
    static let annexDirs: Set<String> = ["THMBNL", "SUB", "PROXY", "PROXIES", "THUMBNAIL", "THUMBNAILS", "AVF_INFO",
                                         "GENERAL", "CACHE", "MISC", "TAKE", "XDROOT_GENERAL"]

    static func isMedia(_ rel: String) -> Bool {
        let ext = (rel as NSString).pathExtension.lowercased()
        return videoExt.contains(ext) || photoExt.contains(ext) || audioExt.contains(ext)
    }

    /// Vrai rush (et pas une vignette caméra, un proxy ou un fichier caché)
    static func isClip(_ rel: String, videoStems: Set<String>) -> Bool {
        guard isMedia(rel) else { return false }
        let parts = rel.split(separator: "/").map(String.init)
        if parts.contains(where: { $0.hasPrefix(".") }) { return false }
        if parts.dropLast().contains(where: { annexDirs.contains($0.uppercased()) }) { return false }
        let name = parts.last ?? rel
        let ext = (name as NSString).pathExtension.lowercased()
        if photoExt.contains(ext) {
            // Vignette Sony/Canon « C0001T01.JPG » à côté de « C0001.MP4 »
            let stem = ((name as NSString).deletingPathExtension).uppercased()
            if let r = stem.range(of: #"T\d{2}$"#, options: .regularExpression), videoStems.contains(String(stem[..<r.lowerBound])) {
                return false
            }
        }
        return true
    }

    /// Analyse les clips copiés (sur le premier disque, déjà vérifié) : vignettes, infos techniques, timecode.
    static func prepare(_ base: CardData, cardFolder: URL, files: [(rel: String, size: Int64)],
                        hashes: [String: String], progress: ((Int, Int) -> Void)? = nil) -> CardData {
        var data = base
        let stems = Set(files.filter { videoExt.contains(($0.rel as NSString).pathExtension.lowercased()) }
            .map { (($0.rel as NSString).lastPathComponent as NSString).deletingPathExtension.uppercased() })
        let media = files.filter { isClip($0.rel, videoStems: stems) }
        var done = 0
        progress?(0, media.count)
        for f in media {
            let ext = (f.rel as NSString).pathExtension.lowercased()
            let url = cardFolder.appendingPathComponent(f.rel)
            var clip = Clip(name: f.rel, size: f.size, kind: "", hash: hashes[f.rel] ?? "")
            if videoExt.contains(ext) {
                clip.kind = "vidéo"
                autoreleasepool { describeVideo(url, into: &clip) }
            } else if photoExt.contains(ext) {
                clip.kind = "photo"
                autoreleasepool { describePhoto(url, into: &clip) }
            } else {
                clip.kind = "son"
                autoreleasepool { describeAudio(url, into: &clip) }
            }
            data.clips.append(clip)
            done += 1
            progress?(done, media.count)
        }
        data.extraFiles = files.count - media.count
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

    // MARK: - Timecode

    enum TC {
        /// Images → « 10:00:00:00 » (« ; » avant les images en drop-frame)
        static func string(_ frames: Int, rate: Int, drop: Bool) -> String {
            guard rate > 0 else { return "--:--:--:--" }
            var f = frames
            if drop, rate == 30 || rate == 60 {
                let d = rate == 60 ? 4 : 2
                let per10 = rate * 600 - d * 9, per1 = rate * 60 - d
                let tens = f / per10, rest = f % per10
                f += d * 9 * tens + (rest > d ? d * ((rest - d) / per1) : 0)
            }
            let dayFrames = rate * 86400
            f = ((f % dayFrames) + dayFrames) % dayFrames
            let ff = f % rate, s = (f / rate) % 60, m = (f / rate / 60) % 60, h = f / rate / 3600
            return String(format: "%02d:%02d:%02d%@%02d", h, m, s, drop ? ";" : ":", ff)
        }

        /// « 10:00:00:00 » → images
        static func frames(h: Int, m: Int, s: Int, f: Int, rate: Int, drop: Bool) -> Int {
            var total = ((h * 60 + m) * 60 + s) * rate + f
            if drop, rate == 30 || rate == 60 {
                let d = rate == 60 ? 4 : 2
                let mins = h * 60 + m
                total -= d * (mins - mins / 10)
            }
            return total
        }

        /// Valeur Sony « LtcChange value="FFSSMMHH" » (BCD, octets à l'envers) → (h, m, s, f, drop)
        static func sony(_ hex: String) -> [(h: Int, m: Int, s: Int, f: Int, drop: Bool)] {
            guard hex.count == 8, let v = UInt32(hex, radix: 16) else { return [] }
            let b = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
            func bcd(_ x: UInt8) -> Int { Int(x >> 4) * 10 + Int(x & 0x0F) }
            // Ordre habituel : images, secondes, minutes, heures ; l'ordre inverse est gardé en secours
            let a = (h: bcd(b[3] & 0x3F), m: bcd(b[2] & 0x7F), s: bcd(b[1] & 0x7F), f: bcd(b[0] & 0x3F), drop: b[0] & 0x40 != 0)
            let r = (h: bcd(b[0] & 0x3F), m: bcd(b[1] & 0x7F), s: bcd(b[2] & 0x7F), f: bcd(b[3] & 0x3F), drop: b[3] & 0x40 != 0)
            return [a, r].filter { $0.h < 24 && $0.m < 60 && $0.s < 60 && $0.f < 60 }
        }
    }

    /// XML Sony à côté du clip (C0001.MP4 → C0001M01.XML) : timecode, caméra, objectif
    static func sonyXML(for url: URL) -> (frames: Int, rate: Int, drop: Bool, camera: String?, lens: String?, slowmo: String?)? {
        let dir = url.deletingLastPathComponent(), stem = url.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        let candidates = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let xmlName = candidates.first(where: {
            let u = $0.uppercased()
            return u.hasPrefix(stem.uppercased() + "M0") && u.hasSuffix(".XML")
        }) ?? candidates.first(where: { $0.uppercased() == stem.uppercased() + ".XML" }),
              let xml = (try? String(contentsOf: dir.appendingPathComponent(xmlName), encoding: .utf8))
                ?? (try? String(contentsOf: dir.appendingPathComponent(xmlName), encoding: .isoLatin1)) else { return nil }

        func attr(_ tag: String, _ name: String, in s: String) -> String? {
            guard let r = s.range(of: "<\(tag)\\b[^>]*>", options: .regularExpression) else { return nil }
            let el = String(s[r])
            guard let a = el.range(of: "\(name)=\"[^\"]*\"", options: .regularExpression) else { return nil }
            return String(el[a]).components(separatedBy: "\"")[1]
        }
        let manufacturer = attr("Device", "manufacturer", in: xml)
        let model = attr("Device", "modelName", in: xml)
        let camera = [manufacturer, model].compactMap { $0 }.joined(separator: " ")
        let lens = attr("Lens", "modelName", in: xml)
        // Ralenti / accéléré : cadence de prise de vue ≠ cadence du fichier (ex. 100p → 25p)
        var slowmo: String?
        if let cap = attr("VideoFrame", "captureFps", in: xml).flatMap({ Double($0.filter { $0.isNumber || $0 == "." }) }),
           let fmt = attr("VideoFrame", "formatFps", in: xml).flatMap({ Double($0.filter { $0.isNumber || $0 == "." }) }),
           fmt > 0, abs(cap - fmt) > 0.5 {
            let r = cap / fmt
            slowmo = cap > fmt ? "Ralenti ×\(r.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(r)) : String(format: "%.1f", r)) (\(Int(cap))p)"
                               : "Accéléré (\(String(format: "%g", cap)) i/s)"
        }

        // Toutes les entrées LtcChange (début, …, fin)
        var changes: [(count: Int, value: String)] = []
        var rest = Substring(xml)
        while let r = rest.range(of: "<LtcChange\\b[^>]*>", options: .regularExpression) {
            let el = String(rest[r])
            if let c = attr("LtcChange", "frameCount", in: el).flatMap(Int.init), let v = attr("LtcChange", "value", in: el) {
                changes.append((c, v))
            }
            rest = rest[r.upperBound...]
        }
        let rate = Int(attr("LtcChangeTable", "tcFps", in: xml) ?? "")
            ?? Int((attr("VideoFrame", "formatFps", in: xml) ?? "").filter(\.isNumber).prefix(2)) ?? 25
        guard let start = changes.first(where: { $0.count == 0 }) ?? changes.first else {
            return camera.isEmpty && slowmo == nil ? nil : (0, 0, false, camera.isEmpty ? nil : camera, lens, slowmo)
        }
        var options = TC.sony(start.value)
        // Si les deux lectures sont possibles, on garde celle qui colle avec l'entrée de fin
        if options.count > 1, let end = changes.last, end.count > start.count {
            let endOptions = TC.sony(end.value)
            if let i = options.indices.first(where: { i in
                guard i < endOptions.count else { return false }
                let o = options[i], e = endOptions[i]
                let a = TC.frames(h: o.h, m: o.m, s: o.s, f: o.f, rate: rate, drop: o.drop)
                let b = TC.frames(h: e.h, m: e.m, s: e.s, f: e.f, rate: rate, drop: e.drop)
                return b - a == end.count - start.count
            }) { options = [options[i]] }
        }
        guard let t = options.first else { return camera.isEmpty && slowmo == nil ? nil : (0, 0, false, camera.isEmpty ? nil : camera, lens, slowmo) }
        let frames = TC.frames(h: t.h, m: t.m, s: t.s, f: t.f, rate: rate, drop: t.drop) - start.count
        return (frames, rate, t.drop, camera.isEmpty ? nil : camera, lens, slowmo)
    }

    /// Piste timecode (tmcd) lue directement dans le fichier MOV/MP4 (sans AVFoundation)
    static func movTimecode(_ url: URL) -> (frames: Int, rate: Int, drop: Bool)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        func be32(_ d: Data, _ o: Int) -> UInt32 { d.subdata(in: o..<o + 4).reduce(0) { $0 << 8 | UInt32($1) } }
        func be64(_ d: Data, _ o: Int) -> UInt64 { d.subdata(in: o..<o + 8).reduce(0) { $0 << 8 | UInt64($1) } }
        // 1. Trouver « moov » parmi les boîtes du premier niveau
        let fileSize = (try? h.seekToEnd()) ?? 0
        var off: UInt64 = 0
        var moov: Data?
        while off + 8 <= fileSize {
            try? h.seek(toOffset: off)
            guard let hd = try? h.read(upToCount: 16), hd.count >= 8 else { break }
            var size = UInt64(be32(hd, 0)), headerLen: UInt64 = 8
            let type = String(data: hd.subdata(in: 4..<8), encoding: .ascii) ?? ""
            if size == 1, hd.count >= 16 { size = be64(hd, 8); headerLen = 16 }
            if size == 0 { size = fileSize - off }
            if size < headerLen { break }
            if type == "moov" {
                guard size < 64 << 20 else { return nil }
                try? h.seek(toOffset: off + headerLen)
                moov = try? h.read(upToCount: Int(size - headerLen))
                break
            }
            off += size
        }
        guard let moov else { return nil }
        // 2. Boîtes enfants d'une plage de données
        func children(_ d: Data, _ range: Range<Int>) -> [(type: String, body: Range<Int>)] {
            var out: [(String, Range<Int>)] = []
            var o = range.lowerBound
            while o + 8 <= range.upperBound {
                var size = Int(be32(d, o)), hl = 8
                let type = String(data: d.subdata(in: o + 4..<o + 8), encoding: .ascii) ?? ""
                if size == 1, o + 16 <= range.upperBound { size = Int(be64(d, o + 8)); hl = 16 }
                if size == 0 { size = range.upperBound - o }
                if size < hl || o + size > range.upperBound { break }
                out.append((type, o + hl..<o + size))
                o += size
            }
            return out
        }
        func find(_ d: Data, _ r: Range<Int>, _ path: [String]) -> Range<Int>? {
            guard let first = path.first else { return r }
            for c in children(d, r) where c.type == first {
                if let f = find(d, c.body, Array(path.dropFirst())) { return f }
            }
            return nil
        }
        for trak in children(moov, 0..<moov.count) where trak.type == "trak" {
            guard let hdlr = find(moov, trak.body, ["mdia", "hdlr"]), hdlr.count >= 12,
                  String(data: moov.subdata(in: hdlr.lowerBound + 8..<hdlr.lowerBound + 12), encoding: .ascii) == "tmcd",
                  let stbl = find(moov, trak.body, ["mdia", "minf", "stbl"]),
                  let stsd = find(moov, stbl, ["stsd"]), stsd.count >= 8 + 8 + 27 else { continue }
            let e = stsd.lowerBound + 8   // début de la 1re entrée
            guard String(data: moov.subdata(in: e + 4..<e + 8), encoding: .ascii) == "tmcd" else { continue }
            let flags = be32(moov, e + 8 + 6 + 2 + 4)
            let quanta = Int(moov[e + 8 + 6 + 2 + 4 + 4 + 4 + 4])
            var chunk: UInt64?
            if let stco = find(moov, stbl, ["stco"]), stco.count >= 12 { chunk = UInt64(be32(moov, stco.lowerBound + 8)) }
            else if let co64 = find(moov, stbl, ["co64"]), co64.count >= 16 { chunk = be64(moov, co64.lowerBound + 8) }
            guard let chunk, quanta > 0 else { continue }
            try? h.seek(toOffset: chunk)
            guard let v = try? h.read(upToCount: 4), v.count == 4 else { continue }
            return (Int(Int32(bitPattern: be32(v, 0))), quanta, flags & 1 != 0)
        }
        return nil
    }

    /// Piste timecode (tmcd) d'un MP4/MOV
    static func trackTimecode(_ asset: AVAsset) -> (frames: Int, rate: Int, drop: Bool)? {
        guard let track = asset.tracks(withMediaType: .timecode).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        guard let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb),
              let fd = CMSampleBufferGetFormatDescription(sb) else { return nil }
        let rate = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(fd))
        let drop = CMTimeCodeFormatDescriptionGetTimeCodeFlags(fd) & kCMTimeCodeFlag_DropFrame != 0
        var frames = 0
        if CMFormatDescriptionGetMediaSubType(fd) == kCMTimeCodeFormatType_TimeCode64 {
            var v: Int64 = 0
            guard CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: 8, destination: &v) == noErr else { return nil }
            frames = Int(Int64(bigEndian: v))
        } else {
            var v: Int32 = 0
            guard CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: 4, destination: &v) == noErr else { return nil }
            frames = Int(Int32(bigEndian: v))
        }
        return rate > 0 ? (frames, rate, drop) : nil
    }

    /// BWF : TimeReference (bext) + cadence, scène et prise (iXML)
    static func bwfInfo(_ url: URL) -> (seconds: Double?, rate: Int, drop: Bool, note: String?) {
        var seconds: Double?, rate = 25, drop = false, note: String?
        guard let h = try? FileHandle(forReadingFrom: url) else { return (nil, rate, drop, nil) }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 12), head.count == 12,
              let riff = String(data: head.prefix(4), encoding: .ascii), riff == "RIFF" || riff == "RF64" else {
            return (nil, rate, drop, nil)
        }
        func u32(_ d: Data, _ o: Int) -> UInt32 { d.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
        func u64(_ d: Data, _ o: Int) -> UInt64 { d.subdata(in: o..<o + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian }
        var sampleRate: Double = 0, timeRef: UInt64?
        var offset: UInt64 = 12
        for _ in 0..<64 {
            try? h.seek(toOffset: offset)
            guard let ch = try? h.read(upToCount: 8), ch.count == 8 else { break }
            let id = String(data: ch.prefix(4), encoding: .ascii) ?? ""
            let size = u32(ch, 4)
            if id == "data" && size == 0xFFFFFFFF { break }
            if id == "fmt ", let d = try? h.read(upToCount: 16), d.count == 16 {
                sampleRate = Double(u32(d, 4))
            } else if id == "bext", size >= 346, let d = try? h.read(upToCount: 346), d.count == 346 {
                timeRef = u64(d, 338)
            } else if id == "iXML", let d = try? h.read(upToCount: Int(min(size, 256 * 1024))),
                      let x = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) {
                func tag(_ t: String) -> String? {
                    guard let r = x.range(of: "<\(t)>[^<]*</\(t)>", options: .regularExpression) else { return nil }
                    let v = String(x[r]).replacingOccurrences(of: "<\(t)>", with: "").replacingOccurrences(of: "</\(t)>", with: "")
                    return v.trimmingCharacters(in: .whitespaces).isEmpty ? nil : v.trimmingCharacters(in: .whitespaces)
                }
                if let tr = tag("TIMECODE_RATE") {
                    let p = tr.split(separator: "/").compactMap { Double($0) }
                    if let n = p.first { rate = Int((n / (p.count > 1 ? p[1] : 1)).rounded()) }
                }
                if let fl = tag("TIMECODE_FLAG") { drop = fl.uppercased() == "DF" }
                let parts = [tag("SCENE").map { "Sc \($0)" }, tag("TAKE").map { "Prise \($0)" }].compactMap { $0 }
                if !parts.isEmpty { note = parts.joined(separator: " · ") }
            }
            offset += 8 + UInt64(size) + UInt64(size & 1)
        }
        if let t = timeRef, sampleRate > 0 { seconds = Double(t) / sampleRate }
        return (seconds, rate, drop, note)
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
            if fps > 0 { clip.fps = fps.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(fps)) i/s" : String(format: "%.2f i/s", fps) }
            if let desc = (track.formatDescriptions as? [CMFormatDescription])?.first {
                clip.codec = codecName(CMFormatDescriptionGetMediaSubType(desc))
            }
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 320, height: 320)
            let at = CMTime(seconds: min(1.0, (clip.duration ?? 0) * 0.1), preferredTimescale: 600)
            if let img = try? gen.copyCGImage(at: at, actualTime: nil) { clip.thumb = jpeg(img) }
        }
        // Timecode : piste du fichier, sinon XML Sony
        let sony = sonyXML(for: url)
        if let tc = movTimecode(url) ?? trackTimecode(asset) {
            clip.tcFrames = tc.frames; clip.tcRate = tc.rate; clip.tcDrop = tc.drop
        } else if let s = sony, s.rate > 0 {
            clip.tcFrames = s.frames; clip.tcRate = s.rate; clip.tcDrop = s.drop
        }
        clip.camera = sony?.camera
        clip.lens = sony?.lens
        clip.note = sony?.slowmo
        if clip.camera == nil {
            let items = asset.commonMetadata + asset.metadata
            func value(_ id: AVMetadataIdentifier) -> String? {
                AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first?.stringValue
            }
            let make = value(.quickTimeMetadataMake) ?? value(.commonIdentifierMake)
            let model = value(.quickTimeMetadataModel) ?? value(.commonIdentifierModel)
            let cam = [make, model].compactMap { $0 }.joined(separator: " ")
            if !cam.isEmpty { clip.camera = cam }
        }
    }

    private static func describePhoto(_ url: URL, into clip: inout Clip) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
                clip.resolution = "\(w)×\(h)"
            }
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                let cam = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String]
                    .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                if !cam.isEmpty { clip.camera = cam }
            }
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
            let bits = asbd.mBitsPerChannel > 0 ? " · \(asbd.mBitsPerChannel) bits" : ""
            clip.codec = "\(Int(asbd.mSampleRate / 1000)) kHz\(bits) · \(asbd.mChannelsPerFrame) piste(s)"
        }
        let ext = url.pathExtension.lowercased()
        if ext == "wav" || ext == "bwf" {
            let b = bwfInfo(url)
            if let s = b.seconds {
                let real = b.drop ? Double(b.rate) * 1000 / 1001 : Double(b.rate)
                clip.tcFrames = Int((s * real).rounded()); clip.tcRate = b.rate; clip.tcDrop = b.drop
            }
            clip.note = b.note
        }
    }

    private static func codecName(_ code: FourCharCode) -> String {
        let names: [String: String] = ["avc1": "H.264", "avc3": "H.264", "hvc1": "H.265", "hev1": "H.265",
                                       "apco": "ProRes 422 Proxy", "apcs": "ProRes 422 LT", "apcn": "ProRes 422",
                                       "apch": "ProRes 422 HQ", "ap4h": "ProRes 4444", "ap4x": "ProRes 4444 XQ",
                                       "aprn": "ProRes RAW", "aprh": "ProRes RAW HQ", "mjpg": "Motion JPEG",
                                       "xavc": "XAVC", "dvh1": "Dolby Vision"]
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let s = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "?"
        return names[s] ?? s
    }

    private static func jpeg(_ img: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    // MARK: - Résumés

    static func durationText(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t >= 3600 { return String(format: "%d h %02d min", t / 3600, (t % 3600) / 60) }
        if t >= 60 { return String(format: "%d min %02d s", t / 60, t % 60) }
        return "\(t) s"
    }

    private static func mostCommon(_ values: [String?]) -> String? {
        var counts: [String: Int] = [:]
        for v in values.compactMap({ $0 }) where !v.isEmpty { counts[v, default: 0] += 1 }
        guard let best = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else { return nil }
        return counts.count > 1 ? "\(best.key) (+ \(counts.count - 1) autre\(counts.count > 2 ? "s" : ""))" : best.key
    }

    private static func countText(_ clips: [Clip]) -> String {
        let v = clips.filter { $0.kind == "vidéo" }.count, p = clips.filter { $0.kind == "photo" }.count,
            a = clips.filter { $0.kind == "son" }.count
        var parts: [String] = []
        if v > 0 { parts.append("\(v) vidéo\(v > 1 ? "s" : "")") }
        if p > 0 { parts.append("\(p) photo\(p > 1 ? "s" : "")") }
        if a > 0 { parts.append("\(a) son\(a > 1 ? "s" : "")") }
        return parts.isEmpty ? "aucun rush" : parts.joined(separator: " · ")
    }

    private static func formatText(_ clips: [Clip]) -> String? {
        let vids = clips.filter { $0.kind == "vidéo" }
        guard !vids.isEmpty else { return mostCommon(clips.map { $0.codec }) }
        return mostCommon(vids.map { c in
            [c.resolution, c.fps, c.codec].compactMap { $0 }.joined(separator: " · ")
        })
    }

    private static func tcRange(_ clips: [Clip]) -> String? {
        let withTC = clips.filter { $0.tcSeconds != nil }.sorted { $0.tcSeconds! < $1.tcSeconds! }
        guard let first = withTC.first, let last = withTC.max(by: {
            ($0.tcSeconds! + ($0.duration ?? 0)) < ($1.tcSeconds! + ($1.duration ?? 0))
        }), let a = first.tcIn else { return nil }
        let b = last.tcOut ?? last.tcIn ?? ""
        let missing = clips.filter { $0.kind != "photo" && $0.tcSeconds == nil }.count
        return "\(a) → \(b)" + (missing > 0 ? "  (\(missing) sans TC)" : "")
    }

    // MARK: - Mise en page (A4, couleurs C-FOCUS)

    private static let W: CGFloat = 595, H: CGFloat = 842, M: CGFloat = 32
    private static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    private static let navy = rgb(0x0F1924), orange = rgb(0xE8742A), cream = rgb(0xF1EAD6),
                        ink = rgb(0x1D2733), gray = rgb(0x6B7A89), light = rgb(0xEEF1F4), line = rgb(0xDDE2E8),
                        paper = rgb(0xF7F8FA), green = rgb(0x2FA874), red = rgb(0xD9443C)
    /// Couleurs des rangées de la frise (une par caméra / son)
    private static let lanes: [CGColor] = [rgb(0xE8742A), rgb(0x2F6FB5), rgb(0x2FA874), rgb(0x8E5BC2),
                                           rgb(0xC9A227), rgb(0xD9443C), rgb(0x2AA3A3), rgb(0x6B7A89)]

    private final class Page {
        let ctx: CGContext
        var y: CGFloat = 0          // distance depuis le haut
        var number = 0
        let footer: String
        var onNewPage: ((Page) -> Void)?
        init(_ ctx: CGContext, footer: String) { self.ctx = ctx; self.footer = footer }

        func new() {
            if number > 0 { finish() }
            number += 1
            ctx.beginPDFPage(nil)
            y = M
            if number > 1 {
                // Petit rappel en haut des pages suivantes
                rect(0, top: 0, w: W, h: 4, fill: orange)
                text(footer, x: M, top: 14, size: 7.5, color: gray, maxWidth: W - 2 * M)
                y = 34
                onNewPage?(self)
            }
        }
        func finish() {
            rect(M, top: H - 30, w: W - 2 * M, h: 0.5, fill: line)
            text("C-SAFE · C-FOCUS", x: M, top: H - 24, size: 7.5, bold: true, color: gray)
            text("page \(number)", x: W - M, top: H - 24, size: 7.5, color: gray, alignRight: true)
            ctx.endPDFPage()
        }
        func need(_ h: CGFloat) { if y + h > H - 40 { new() } }

        func rect(_ x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat, fill: CGColor, radius: CGFloat = 0) {
            let r = CGRect(x: x, y: H - top - h, width: w, height: h)
            ctx.setFillColor(fill)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(radius, w / 2, h / 2), cornerHeight: min(radius, w / 2, h / 2), transform: nil))
            ctx.fillPath()
        }
        func stroke(_ x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat, color: CGColor, radius: CGFloat = 0) {
            let r = CGRect(x: x, y: H - top - h, width: w, height: h).insetBy(dx: 0.25, dy: 0.25)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(0.5)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()
        }

        /// Texte sur une ligne (tronqué si besoin). `top` = haut de la ligne.
        @discardableResult
        func text(_ s: String, x: CGFloat, top: CGFloat, size: CGFloat, bold: Bool = false, mono: Bool = false,
                  color: CGColor, maxWidth: CGFloat = 520, alignRight: Bool = false, truncateEnd: Bool = false) -> CGFloat {
            let name = mono ? (bold ? "Menlo-Bold" : "Menlo-Regular") : (bold ? "Helvetica-Bold" : "Helvetica")
            let font = CTFontCreateWithName(name as CFString, size, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
            var line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
            if CTLineGetTypographicBounds(line, nil, nil, nil) > Double(maxWidth) {
                let dots = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
                if let t = CTLineCreateTruncatedLine(line, Double(maxWidth), truncateEnd ? .end : .middle, dots) { line = t }
            }
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.textPosition = CGPoint(x: alignRight ? x - width : x, y: H - top - size)
            CTLineDraw(line, ctx)
            return width
        }

        func image(_ data: Data?, x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat, placeholder: String) {
            rect(x, top: top, w: w, h: h, fill: navy, radius: 3)
            guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                text(placeholder, x: x + w / 2 - 3, top: top + h / 2 - 5, size: 9, bold: true, color: gray, maxWidth: w - 4)
                return
            }
            let iw = CGFloat(img.width), ih = CGFloat(img.height)
            let scale = max(w / iw, h / ih)          // remplit la case (recadrage léger)
            let dw = iw * scale, dh = ih * scale
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: H - top - h, width: w, height: h), cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.clip()
            ctx.draw(img, in: CGRect(x: x + (w - dw) / 2, y: H - top - h + (h - dh) / 2, width: dw, height: dh))
            ctx.restoreGState()
        }
    }

    private static func render(title: String, subtitle: String, cards: [CardData], dayMode: Bool, to url: URL) -> Bool {
        var box = CGRect(x: 0, y: 0, width: W, height: H)
        let meta: [CFString: Any] = [kCGPDFContextCreator: "C-SAFE · C-FOCUS", kCGPDFContextTitle: title]
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, meta as CFDictionary) else { return false }
        let page = Page(ctx, footer: "\(title) · \(subtitle)")
        page.new()

        // Bandeau
        page.rect(0, top: 0, w: W, h: 70, fill: navy)
        page.rect(0, top: 70, w: W, h: 3, fill: orange)
        page.text("C-SAFE", x: M, top: 18, size: 21, bold: true, color: cream)
        page.text("par C-FOCUS", x: M, top: 43, size: 8.5, color: orange)
        page.text(title, x: W - M, top: 20, size: 13, bold: true, color: cream, maxWidth: 380, alignRight: true)
        page.text(subtitle, x: W - M, top: 40, size: 9, color: cream, maxWidth: 380, alignRight: true)
        page.y = 88

        let allClips = cards.flatMap { $0.clips }
        if dayMode {
            let ok = cards.allSatisfy { $0.verified }
            let total = cards.reduce(Int64(0)) { $0 + $1.totalBytes }
            badge(page, ok: ok, text: ok ? "✓ \(cards.count) carte\(cards.count > 1 ? "s" : "") copiée\(cards.count > 1 ? "s" : "") et vérifiée\(cards.count > 1 ? "s" : "") sur tous les disques"
                                         : "✗ Au moins une carte n'a pas été vérifiée : ne formate rien, voir le détail")
            let rushes = allClips.compactMap { $0.kind == "photo" ? nil : $0.duration }.reduce(0, +)
            tiles(page, [("Cartes", "\(cards.count)", Set(cards.map { $0.label }).sorted().joined(separator: " · ")),
                         ("Rushes", "\(allClips.count)", countText(allClips)),
                         ("Durée", rushes > 0 ? durationText(rushes) : "—", "vidéo + son"),
                         ("Volume", OffloadJob.human(total), "\(cards.reduce(0) { $0 + $1.files }) fichiers")])
            syncTimeline(page, cards)
            cardList(page, cards)
        } else if let c = cards.first {
            badge(page, ok: c.verified, text: c.verified
                  ? "✓ Copie vérifiée (\(c.hash)) : chaque fichier relu sur chaque disque — tu peux formater la carte"
                  : "✗ Vérification en échec : NE FORMATE PAS la carte")
            let rushes = c.clips.compactMap { $0.kind == "photo" ? nil : $0.duration }.reduce(0, +)
            tiles(page, [("Rushes", "\(c.clips.count)", countText(c.clips)),
                         ("Durée", rushes > 0 ? durationText(rushes) : "—", "total des clips"),
                         ("Volume", OffloadJob.human(c.totalBytes), "\(c.files) fichiers"),
                         ("Copie", durationText(Double(c.seconds)), "\(OffloadJob.human(c.speed))/s")])
        }

        for (i, c) in cards.enumerated() {
            cardSection(page, c, dayMode: dayMode, index: i)
        }
        page.finish()
        ctx.closePDF()
        return true
    }

    private static func badge(_ page: Page, ok: Bool, text: String) {
        page.rect(M, top: page.y, w: W - 2 * M, h: 26, fill: ok ? rgb(0xE6F6EE) : rgb(0xFBE7E5), radius: 6)
        page.rect(M, top: page.y, w: 4, h: 26, fill: ok ? green : red, radius: 2)
        page.text(text, x: M + 12, top: page.y + 8, size: 9.5, bold: true, color: ok ? green : red, maxWidth: W - 2 * M - 22)
        page.y += 34
    }

    private static func tiles(_ page: Page, _ items: [(String, String, String)]) {
        let gap: CGFloat = 8, n = CGFloat(items.count)
        let w = (W - 2 * M - gap * (n - 1)) / n, h: CGFloat = 52
        for (i, t) in items.enumerated() {
            let x = M + CGFloat(i) * (w + gap)
            page.rect(x, top: page.y, w: w, h: h, fill: paper, radius: 6)
            page.stroke(x, top: page.y, w: w, h: h, color: line, radius: 6)
            page.text(t.0.uppercased(), x: x + 10, top: page.y + 8, size: 6.5, bold: true, color: gray, maxWidth: w - 20)
            page.text(t.1, x: x + 10, top: page.y + 19, size: 15, bold: true, color: ink, maxWidth: w - 20)
            page.text(t.2, x: x + 10, top: page.y + 38, size: 7, color: gray, maxWidth: w - 20, truncateEnd: true)
        }
        page.y += h + 14
    }

    private static func sectionTitle(_ page: Page, _ s: String, right: String? = nil) {
        page.text(s, x: M, top: page.y, size: 11, bold: true, color: ink)
        if let right { page.text(right, x: W - M, top: page.y + 2, size: 7.5, color: gray, alignRight: true) }
        page.rect(M, top: page.y + 16, w: 22, h: 2, fill: orange)
        page.y += 24
    }

    /// « OK · /Volumes/X10 Pro/Projet/… » → (ok, « X10 Pro », « Projet/… »)
    private static func splitDestination(_ d: String) -> (ok: Bool, disk: String, path: String) {
        let ok = d.hasPrefix("OK")
        var path = d.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
        if path.isEmpty { path = d }
        if path.hasPrefix("/Volumes/") {
            let parts = path.dropFirst("/Volumes/".count).split(separator: "/", maxSplits: 1).map(String.init)
            return (ok, parts.first ?? path, parts.count > 1 ? parts[1] : "")
        }
        let comps = path.split(separator: "/").map(String.init)
        // iPhone / autre : on montre le dossier qui précède le projet comme nom de disque
        return (ok, comps.count > 4 ? comps[comps.count - 5] : (comps.first ?? path), comps.suffix(4).joined(separator: "/"))
    }

    private static func infoGrid(_ page: Page, _ info: [(String, String)]) {
        let colW = (W - 2 * M) / 2
        for (i, kv) in info.enumerated() {
            let x = M + CGFloat(i % 2) * colW
            if i % 2 == 0 && i > 0 { page.y += 15 }
            page.text(kv.0, x: x, top: page.y, size: 7.5, color: gray, maxWidth: 76)
            page.text(kv.1, x: x + 78, top: page.y, size: 8.5, bold: true, color: ink, maxWidth: colW - 86, truncateEnd: true)
        }
        page.y += 19
    }

    private static func cardSection(_ page: Page, _ c: CardData, dayMode: Bool, index: Int) {
        let cardTitle = c.display.split(separator: "/").last.map(String.init) ?? c.label
        page.need(dayMode ? 190 : 150)
        if dayMode {
            page.rect(M, top: page.y, w: W - 2 * M, h: 24, fill: navy, radius: 5)
            page.text(c.verified ? "✓" : "✗", x: M + 10, top: page.y + 7, size: 10, bold: true, color: c.verified ? green : red)
            page.text(cardTitle, x: M + 26, top: page.y + 7, size: 10, bold: true, color: cream, maxWidth: 300)
            let rushes = c.clips.compactMap { $0.kind == "photo" ? nil : $0.duration }.reduce(0, +)
            page.text("\(countText(c.clips)) · \(rushes > 0 ? durationText(rushes) + " · " : "")\(OffloadJob.human(c.totalBytes))",
                      x: W - M - 10, top: page.y + 8, size: 8, color: cream, maxWidth: 220, alignRight: true)
            page.y += 34
        }
        let camera = mostCommon(c.clips.map { $0.camera })
        var info: [(String, String)] = []
        if !dayMode { info += [("Projet", c.project), ("Jour", c.day)] }
        info += [("Source", c.label), ("Carte d'origine", c.cardName)]
        if let camera { info.append(("Caméra", camera)) }
        if let lens = mostCommon(c.clips.map { $0.lens }) { info.append(("Objectif", lens)) }
        if let f = formatText(c.clips) { info.append(("Format", f)) }
        if let tc = tcRange(c.clips) { info.append(("Timecode", tc)) }
        info += [("Copie terminée", c.date), ("Vérification", "\(c.hash) — \(c.verified ? "OK" : "ÉCHEC")")]
        if dayMode { info.append(("Copie", "\(durationText(Double(c.seconds))) · \(OffloadJob.human(c.speed))/s")) }
        infoGrid(page, info)

        // Dossier + disques
        page.text("Dossier", x: M, top: page.y, size: 7.5, color: gray)
        page.text(c.display, x: M + 78, top: page.y, size: 8.5, mono: true, color: ink, maxWidth: W - 2 * M - 78)
        page.y += 15
        for (i, d) in c.destinations.enumerated() {
            let s = splitDestination(d)
            page.text(i == 0 ? "Disques" : "", x: M, top: page.y, size: 7.5, color: gray)
            let w = page.text("\(s.ok ? "✓" : "✗")  \(s.disk)", x: M + 78, top: page.y, size: 8.5, bold: true, color: s.ok ? ink : red, maxWidth: 160)
            page.text(s.path, x: M + 78 + w + 8, top: page.y + 1, size: 7, color: gray, maxWidth: W - 2 * M - 86 - w)
            page.y += 13
        }
        page.y += 10

        // Grille des clips : 2 par ligne
        let gap: CGFloat = 10, cellW = (W - 2 * M - gap) / 2, cellH: CGFloat = 58
        let thumbW: CGFloat = 84, thumbH: CGFloat = 47
        if !c.clips.isEmpty {
            page.need(cellH + 30)
            sectionTitle(page, dayMode ? "Clips — \(cardTitle)" : "Clips (\(c.clips.count))",
                         right: "TC début → fin · durée · format · taille · empreinte \(c.hash)")
        }
        let sorted = c.clips.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var i = 0
        while i < sorted.count {
            page.need(cellH)
            for col in 0..<2 where i + col < sorted.count {
                let clip = sorted[i + col]
                let x = M + CGFloat(col) * (cellW + gap), top = page.y
                page.rect(x, top: top, w: cellW, h: cellH - 6, fill: paper, radius: 5)
                page.image(clip.thumb, x: x + 3, top: top + 3, w: thumbW, h: thumbH,
                           placeholder: clip.kind == "son" ? "♪" : "—")
                let tx = x + thumbW + 10, tw = cellW - thumbW - 16
                let sizeW = page.text(OffloadJob.human(clip.size), x: x + cellW - 6, top: top + 6, size: 7.5, color: gray, alignRight: true)
                page.text(clip.shortName, x: tx, top: top + 5, size: 8.5, bold: true, color: ink, maxWidth: tw - sizeW - 6)
                if let a = clip.tcIn {
                    page.text("\(a) → \(clip.tcOut ?? "")", x: tx, top: top + 17, size: 7.5, mono: true, color: orange, maxWidth: tw)
                } else {
                    page.text(clip.kind == "photo" ? "photo" : "pas de timecode", x: tx, top: top + 17, size: 7.5, color: gray, maxWidth: tw)
                }
                var details: [String] = []
                if let d = clip.duration { details.append(durationText(d)) }
                if let n = clip.note { details.append(n) }
                if let r = clip.resolution { details.append(r) }
                if let f = clip.fps { details.append(f) }
                if let k = clip.codec { details.append(k) }
                page.text(details.joined(separator: " · "), x: tx, top: top + 28, size: 7.5, color: ink, maxWidth: tw, truncateEnd: true)
                page.text(clip.hash, x: tx, top: top + 39, size: 6.5, mono: true, color: gray, maxWidth: tw)
            }
            page.y += cellH
            i += 2
        }
        if c.extraFiles > 0 {
            page.need(16)
            page.text("+ \(c.extraFiles) fichier\(c.extraFiles > 1 ? "s" : "") annexe\(c.extraFiles > 1 ? "s" : "") de la carte (XML, vignettes caméra, proxys, index…) : copiés et vérifiés aussi, détail dans le .mhl.",
                      x: M, top: page.y + 2, size: 7.5, color: gray, maxWidth: W - 2 * M)
            page.y += 18
        }
        page.y += 16
    }

    // MARK: - Rapport du jour : liste des cartes + frise de synchro au timecode

    private static func cardList(_ page: Page, _ cards: [CardData]) {
        page.need(60)
        sectionTitle(page, "Cartes du jour")
        let cols: [(String, CGFloat)] = [("Carte", 0), ("Rushes", 200), ("Timecode", 300), ("Volume", 470)]
        for (t, x) in cols { page.text(t.uppercased(), x: M + 6 + x, top: page.y, size: 6.5, bold: true, color: gray) }
        page.y += 12
        for (i, c) in cards.enumerated() {
            page.need(18)
            if i % 2 == 0 { page.rect(M, top: page.y - 3, w: W - 2 * M, h: 17, fill: paper, radius: 3) }
            page.text(c.verified ? "✓" : "✗", x: M + 6, top: page.y + 1, size: 8.5, bold: true, color: c.verified ? green : red)
            page.text(c.display.split(separator: "/").last.map(String.init) ?? c.display, x: M + 18, top: page.y + 1, size: 8.5, bold: true, color: ink, maxWidth: 180)
            page.text(countText(c.clips), x: M + 206, top: page.y + 1, size: 8, color: ink, maxWidth: 92)
            page.text(tcRange(c.clips) ?? "—", x: M + 306, top: page.y + 1, size: 7.5, mono: true, color: ink, maxWidth: 160)
            page.text(OffloadJob.human(c.totalBytes), x: W - M - 6, top: page.y + 1, size: 8, color: ink, alignRight: true)
            page.y += 17
        }
        page.y += 14
    }

    private static func syncTimeline(_ page: Page, _ cards: [CardData]) {
        // Une rangée par source (CamA_FX2, CamB_FX3, Son_F8…)
        var order: [String] = []
        var bySource: [String: [Clip]] = [:]
        for c in cards {
            if bySource[c.label] == nil { order.append(c.label) }
            bySource[c.label, default: []] += c.clips.filter { $0.kind != "photo" }
        }
        let timed = order.map { (label: $0, clips: (bySource[$0] ?? []).filter { $0.tcSeconds != nil }) }
        let all = timed.flatMap { $0.clips }
        page.need(80)
        sectionTitle(page, "Synchro au timecode", right: all.isEmpty ? nil : "chaque trait = un clip, placé selon son TC")
        guard let minS = all.map({ $0.tcSeconds! }).min(),
              let maxS = all.map({ $0.tcSeconds! + max($0.duration ?? 0, 1) }).max() else {
            page.text("Aucun timecode lu sur les clips du jour : la synchro devra se faire au son (dérushage).",
                      x: M, top: page.y, size: 8.5, color: gray, maxWidth: W - 2 * M)
            page.y += 24
            return
        }
        // Graduation : toutes les 5, 10, 15, 30 ou 60 min selon l'étendue
        let span = max(maxS - minS, 60)
        let step: Double = [60, 300, 600, 900, 1800, 3600, 7200].first { span / $0 <= 8 } ?? 7200
        let start = (minS / step).rounded(.down) * step, end = (maxS / step).rounded(.up) * step
        let labelW: CGFloat = 92, x0 = M + labelW, w = W - M - x0
        let laneH: CGFloat = 18
        let rows = timed.filter { !$0.clips.isEmpty }
        let h = CGFloat(rows.count) * laneH + 20
        page.need(h + 40)
        let top = page.y
        func xFor(_ s: Double) -> CGFloat { x0 + CGFloat((s - start) / (end - start)) * w }
        page.rect(x0, top: top, w: w, h: CGFloat(rows.count) * laneH, fill: paper, radius: 4)
        var t = start
        while t <= end + 0.5 {
            let x = xFor(t)
            page.rect(x, top: top, w: 0.5, h: CGFloat(rows.count) * laneH + 3, fill: line)
            let hh = Int(t) / 3600 % 24, mm = Int(t) / 60 % 60
            page.text(String(format: "%02d:%02d", hh, mm), x: x - 10, top: top + CGFloat(rows.count) * laneH + 5, size: 6.5, color: gray)
            t += step
        }
        for (r, row) in rows.enumerated() {
            let y = top + CGFloat(r) * laneH
            let color = lanes[(order.firstIndex(of: row.label) ?? r) % lanes.count]
            page.rect(M, top: y + 5, w: 6, h: 8, fill: color, radius: 2)
            page.text(row.label, x: M + 10, top: y + 5, size: 7.5, bold: true, color: ink, maxWidth: labelW - 14)
            for clip in row.clips {
                let s = clip.tcSeconds!
                let x = xFor(s), xe = xFor(s + max(clip.duration ?? 0, 1))
                page.rect(x, top: y + 4, w: max(xe - x, 1.2), h: laneH - 8, fill: color, radius: 1.5)
            }
        }
        page.y = top + h + 6
        // Chevauchements entre sources
        var notes: [String] = []
        for i in 0..<rows.count {
            for j in (i + 1)..<max(rows.count, i + 1) {
                var overlap = 0.0
                for a in rows[i].clips {
                    for b in rows[j].clips {
                        let s = max(a.tcSeconds!, b.tcSeconds!)
                        let e = min(a.tcSeconds! + (a.duration ?? 0), b.tcSeconds! + (b.duration ?? 0))
                        if e > s { overlap += e - s }
                    }
                }
                if overlap >= 1 { notes.append("\(rows[i].label) + \(rows[j].label) : \(durationText(overlap)) en commun") }
            }
        }
        let missing = timed.flatMap { (bySource[$0.label] ?? []).filter { $0.tcSeconds == nil } }.count
        if !notes.isEmpty {
            page.text("Tournés en même temps — " + notes.joined(separator: "  ·  "), x: M, top: page.y, size: 7.5, color: ink, maxWidth: W - 2 * M, truncateEnd: true)
            page.y += 12
        }
        page.text("Les clips calés sur le même TC (jam-sync / boîtier) se synchronisent au timecode dans Premiere ou DaVinci." +
                  (missing > 0 ? " \(missing) clip(s) sans TC : synchro au son." : ""),
                  x: M, top: page.y, size: 7, color: gray, maxWidth: W - 2 * M, truncateEnd: true)
        page.y += 22
    }
}
