import UIKit
import ImageIO

/// 照片统一压缩后存沙盒 Documents/Photos/(Mac Catalyst 见 AppData 注释),备份时拷走该目录即可
enum PhotoStore {
    static var photosDir: URL {
        let dir = AppData.photosDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(for name: String) -> URL {
        photosDir.appendingPathComponent(name)
    }

    /// 压缩保存(最长边 1600、JPEG 0.8),返回生成的文件名
    @discardableResult
    static func save(from data: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600
        ] as [CFString: Any] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
        guard let out = UIImage(cgImage: cg).jpegData(compressionQuality: 0.8) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do {
            try out.write(to: url(for: name))
            return name
        } catch {
            return nil
        }
    }

    /// 按需解码缩略图,避免列表里加载原图
    static func load(_ name: String, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url(for: name) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as [CFString: Any] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func delete(_ names: [String]) {
        for n in names {
            try? FileManager.default.removeItem(at: url(for: n))
        }
    }
}
