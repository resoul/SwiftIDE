import Foundation

/// Finds the SwiftPM package a file belongs to: the nearest folder above it that holds a
/// `Package.swift`. SourceKit-LSP understands a file's imports and neighbours only from there.
public enum PackageRootLocator {
    public static func root(forFile path: String, fileManager: FileManager = .default) -> URL? {
        var directory = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL
        while true {
            if fileManager.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) { return directory }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }
}
