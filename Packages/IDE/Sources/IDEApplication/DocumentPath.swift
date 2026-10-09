import Foundation

/// One name per file: symlinks resolved, `.`/`..` removed. Used as the identity of an open
/// document, so a file reached through a link opens once, and a save lands on the real file
/// instead of replacing the link.
public enum DocumentPath {
    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
