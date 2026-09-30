import Foundation

/// 数据目录。Mac Catalyst 上免费团队签不出 App Sandbox,App 以未沙盒运行:
/// 数据统一收进 ~/Library/Application Support/TravelNotes/,避免
/// ① SwiftData 默认写到与其他 App 共享的 default.store;② 照片污染用户可见的 ~/Documents。
/// iOS 沿用沙盒默认位置,老数据不受影响。
enum AppData {
    /// SwiftData 库:Catalyst 显式指定;iOS 返回 nil 走 SwiftData 默认(保持既有数据兼容)
    static var storeURL: URL? {
        #if targetEnvironment(macCatalyst)
        return dataDir.appendingPathComponent("TravelNotes.store")
        #else
        return nil
        #endif
    }

    static var photosDir: URL {
        #if targetEnvironment(macCatalyst)
        return dataDir.appendingPathComponent("Photos", isDirectory: true)
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photos", isDirectory: true)
        #endif
    }

    private static var dataDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TravelNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
