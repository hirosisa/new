import Foundation
import AVFoundation

/// Media you own, copied into the app's Documents folder.
///
/// This is the one source that can never break: no network, no third party, no
/// terms of service. Files arrive via the Files app, AirDrop, or iTunes/Finder
/// file sharing (`UIFileSharingEnabled` is set in Info.plist), or through the
/// in-app importer in Library.
struct LocalFilesSource: MediaSource {

    let id = "local"
    let displayName = "My Files"
    let systemImage = "folder.fill"
    let blurb = "Audio and video you copy into the app. Works offline, always available."

    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "m4b"]
    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]

    static var mediaDirectory: URL {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        let media = documents.appendingPathComponent("Media", isDirectory: true)
        if !FileManager.default.fileExists(atPath: media.path) {
            try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        }
        return media
    }

    /// Every local file, newest first.
    func allItems() -> [MediaItem] {
        let directory = Self.mediaDirectory
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { Self.isPlayable($0) }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
            .map(Self.item(for:))
    }

    func search(query: String) async throws -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = allItems()
        guard !trimmed.isEmpty else { return all }

        return all.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.author.localizedCaseInsensitiveContains(trimmed)
        }
    }

    func resolveStream(for item: MediaItem, preferAudioOnly: Bool) async throws -> URL {
        // Resolve by filename rather than trusting a stored absolute path: the
        // app container path changes between installs and after a SideStore
        // refresh, which would otherwise invalidate every favourite.
        let url = Self.mediaDirectory.appendingPathComponent(item.nativeID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SourceError.noStream(item.title)
        }
        return url
    }

    // MARK: - Import

    /// Copies a picked file into the media directory, resolving name collisions.
    /// Security-scoped access is required for anything the picker hands back.
    @discardableResult
    static func importFile(at source: URL) throws -> MediaItem {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        guard isPlayable(source) else {
            throw SourceError.notConfigured("“\(source.lastPathComponent)” isn't a supported audio or video file.")
        }

        let directory = mediaDirectory
        var destination = directory.appendingPathComponent(source.lastPathComponent)

        if FileManager.default.fileExists(atPath: destination.path) {
            let base = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension
            var counter = 2
            repeat {
                let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                destination = directory.appendingPathComponent(candidate)
                counter += 1
            } while FileManager.default.fileExists(atPath: destination.path)
        }

        try FileManager.default.copyItem(at: source, to: destination)
        return item(for: destination)
    }

    static func delete(_ item: MediaItem) throws {
        let url = mediaDirectory.appendingPathComponent(item.nativeID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    private static func isPlayable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return audioExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    private static func item(for url: URL) -> MediaItem {
        let filename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let isVideo = videoExtensions.contains(ext)

        return MediaItem(
            sourceID: "local",
            nativeID: filename,
            title: url.deletingPathExtension().lastPathComponent,
            author: "On this iPhone",
            artworkURL: nil,
            duration: 0, // Filled in by the player; reading every file up front is slow.
            kind: isVideo ? .video : .audio,
            streamURL: url,
            detail: ext.uppercased()
        )
    }
}
