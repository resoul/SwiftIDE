// What differs between configurations: the compilation condition, set per configuration.
enum Build {
#if FLAVOUR_DEBUG
    static let flavour = "debug"
#elseif FLAVOUR_RELEASE
    static let flavour = "release"
#else
    static let flavour = "unknown"
#endif
}
