import Foundation

/// Downloads Apple's developer disk image (the same files Xcode uses) from
/// the public mirror that pymobiledevice3 also relies on.
enum DDIService {
    private static let base = "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/"

    /// iOS 26.4 and newer install developer support as a cryptex.
    static func usesCryptex(iosVersion: String) -> Bool {
        let parts = iosVersion.split(separator: ".").compactMap { Int($0) }
        let major = parts.first ?? 0, minor = parts.count > 1 ? parts[1] : 0
        return major > 26 || (major == 26 && minor >= 4)
    }

    static func files(cryptex: Bool) -> [String] {
        cryptex
            ? ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache", "Image.dmg.cryptex_info", "Image.dmg.root_hash"]
            : ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"]
    }

    static func directory(cryptex: Bool) -> URL {
        AppPaths.ddiDirectory.appendingPathComponent(cryptex ? "cryptex" : "personalized", isDirectory: true)
    }

    static func isDownloaded(cryptex: Bool) -> Bool {
        let folder = directory(cryptex: cryptex)
        return files(cryptex: cryptex).allSatisfy {
            ((try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent($0).path)[.size]) as? Int ?? 0) > 0
        }
    }

    /// Downloads any missing files and returns the folder.
    static func download(cryptex: Bool, progress: @escaping @MainActor (String) -> Void) async throws -> URL {
        let folder = directory(cryptex: cryptex)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let remoteFolder = cryptex ? "Xcode_iOS_DDI_Cryptex/" : "Xcode_iOS_DDI_Personalized/"
        let names = files(cryptex: cryptex)
        for (index, name) in names.enumerated() {
            let destination = folder.appendingPathComponent(name)
            if ((try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? Int ?? 0) > 0 { continue }
            await progress("Downloading developer support (\(index + 1) of \(names.count))…")
            guard let url = URL(string: base + remoteFolder + name) else { throw DeviceError("Bad download address") }
            let (temporary, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw DeviceError("Download of \(name) failed. Check your internet connection and try again.")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        return folder
    }

    static func deleteDownloads() {
        try? FileManager.default.removeItem(at: AppPaths.ddiDirectory)
    }
}
