//
//  Updater.swift — C-SAFE
//  Bouton « Mettre à jour » :
//  - Mac : prend le C-SAFE.dmg rangé dans iCloud Drive › CFocus › App Mac C-FOCUS (ou un .dmg choisi
//    une fois à la main), compare les versions, remplace l'app et la relance.
//  - iPhone / iPad : une app ne peut pas se remplacer elle-même ; on demande à AltStore d'installer
//    la dernière version (le Mac avec AltServer doit être allumé, sur le même Wi-Fi).
//

import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Updater {
    /// Version de l'app en cours (« 1.47 ») et numéro de fabrication (47)
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    /// Lien direct vers la dernière app iPhone publiée (le même fichier que dans iCloud Drive)
    static let latestIPA = "https://github.com/h5r9ptb9kt-byte/C-SAFE/releases/latest/download/C-SAFE.ipa"

    #if os(macOS)
    /// Emplacement habituel du .dmg dans iCloud Drive
    static var iCloudDMG: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/CFocus/App Mac C-FOCUS/C-SAFE.dmg")
    }
    private static let customKey = "csafe.update.dmg"

    /// .dmg à utiliser : celui d'iCloud Drive, sinon celui choisi une fois à la main
    static func dmgLocation() -> URL? {
        if FileManager.default.fileExists(atPath: iCloudDMG.path) || isCloudPlaceholder(iCloudDMG) { return iCloudDMG }
        if let p = UserDefaults.standard.string(forKey: customKey), FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }
    static func remember(_ url: URL) { UserDefaults.standard.set(url.path, forKey: customKey) }

    private static func isCloudPlaceholder(_ url: URL) -> Bool {
        let dir = url.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("." + url.lastPathComponent + ".icloud").path)
    }

    struct Found { let app: URL; let mount: URL; let version: String; let build: Int }

    /// Télécharge le .dmg depuis iCloud si besoin, l'ouvre et lit la version de l'app qu'il contient.
    static func inspect(_ dmg: URL, status: (String) -> Void) throws -> Found {
        let fm = FileManager.default
        // Fichier resté dans le nuage : on le fait descendre
        var waited = 0
        while !fm.fileExists(atPath: dmg.path) || downloading(dmg) {
            if waited == 0 { status("Téléchargement depuis iCloud…") }
            try? fm.startDownloadingUbiquitousItem(at: dmg)
            Thread.sleep(forTimeInterval: 1)
            waited += 1
            if waited > 300 { throw OffloadError(message: "le fichier C-SAFE.dmg ne se télécharge pas depuis iCloud.") }
        }
        status("Ouverture de C-SAFE.dmg…")
        let out = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-plist", dmg.path])
        guard let plist = try PropertyListSerialization.propertyList(from: out, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPath = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw OffloadError(message: "impossible d'ouvrir C-SAFE.dmg.")
        }
        let mount = URL(fileURLWithPath: mountPath)
        guard let appName = (try? fm.contentsOfDirectory(atPath: mountPath))?.first(where: { $0.hasSuffix(".app") }) else {
            detach(mount)
            throw OffloadError(message: "C-SAFE.dmg ne contient pas d'application.")
        }
        let app = mount.appendingPathComponent(appName)
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = Int(info["CFBundleVersion"] as? String ?? "") ?? 0
        return Found(app: app, mount: mount, version: version, build: build)
    }

    private static func downloading(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
              let s = v.ubiquitousItemDownloadingStatus else { return false }
        return s != .current
    }

    /// Remplace l'app en cours par celle du .dmg, puis la relance.
    static func install(_ found: Found) throws {
        let fm = FileManager.default
        let dest = Bundle.main.bundleURL
        let staging = dest.deletingLastPathComponent().appendingPathComponent(".C-SAFE-mise-a-jour.app")
        try? fm.removeItem(at: staging)
        _ = try run("/usr/bin/ditto", [found.app.path, staging.path])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging.path])
        detach(found.mount)
        _ = try fm.replaceItemAt(dest, withItemAt: staging)
        // Relance une fois l'app actuelle fermée
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(dest.path)\""]
        try p.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    static func detach(_ mount: URL) {
        _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"])
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe(), err = Pipe()
        p.standardOutput = pipe
        p.standardError = err
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw OffloadError(message: "\((tool as NSString).lastPathComponent) a échoué : \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return data
    }
    #else
    /// Demande à AltStore d'installer la dernière version ; sinon ouvre le lien de téléchargement.
    @MainActor
    static func openAltStore() {
        let encoded = latestIPA.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? latestIPA
        guard let alt = URL(string: "altstore://install?url=\(encoded)"), let web = URL(string: latestIPA) else { return }
        UIApplication.shared.open(alt, options: [:]) { ok in
            if !ok { UIApplication.shared.open(web) }
        }
    }
    #endif
}
