import Testing

/// Every native window test shares one NSApplication. Run them in one inherited serialized
/// suite so another test cannot steal activation from the isolated real-key-window probe.
@Suite(.serialized)
struct NativeAppTests {}
