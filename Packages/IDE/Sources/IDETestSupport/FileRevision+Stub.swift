import IDEDomain

extension FileRevision {
    public static func stub(_ tick: Int64 = 1) -> FileRevision {
        FileRevision(
            fileID: FileIdentity(device: 0, inode: 1),
            size: 0,
            modificationTime: tick,
            contentDigest: ContentDigest(bytes: [UInt8(truncatingIfNeeded: tick)])
        )
    }
}
