import SwiftUI
import AppKit
import QuickLookThumbnailing

final class ThumbnailLoader: @unchecked Sendable {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.totalCostLimit = 512 * 1024 * 1024 }   // ~512 MB of decoded pixels

    func removeAll() { cache.removeAllObjects() }

    func image(for url: URL) async -> NSImage? {
        // Key on size and modification date too, so a different file at the same path never reuses a thumbnail.
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(url.path)|\(v?.fileSize ?? -1)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 320, height: 320),
                                                   scale: 2, representationTypes: .all)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = rep.nsImage
        let cost = rep.cgImage.bytesPerRow * rep.cgImage.height
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }
}

/// Thumbnail rendered from the file at `url` itself — for the right pane that means the copy on disk.
struct ThumbnailView: View {
    let url: URL
    /// Changes when the file at `url` changes (size/date), so a new card's file at the same path reloads.
    var version: String = ""
    var contentMode: ContentMode = .fit
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.gray.opacity(0.12)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: contentMode)
            }
        }
        .task(id: url.path + "|" + version) {
            image = await ThumbnailLoader.shared.image(for: url)
        }
    }
}
