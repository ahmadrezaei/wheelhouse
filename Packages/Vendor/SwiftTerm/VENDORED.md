# Vendored SwiftTerm

- Upstream: https://github.com/migueldeicaza/SwiftTerm (MIT, see LICENSE)
- Tag: v1.99.2
- Commit: a183c15b52858530a17de57dcc72b93eeebc9857
- Tarball SHA-256: b819f0143fd14c929e9ab5422f2c0b3a01f424d5721e9ae2e5f3f428a96312dc
- Produced by: scripts/vendor-swiftterm.sh (do not edit these files by hand)

Changes from upstream:
- Package.swift is replaced by a plugin-free manifest (iOS 27 and macOS 27, no swift-png, no executables).
- Sources/SwiftTerm/Generated/SwiftTermBuildInfo.swift and SwiftTermTerminfo.swift are the outputs of upstream's
  SwiftTermBuildInfoGenerator, run once with the tag and commit above and committed.
- swifterm-terminfo is the generator's input, kept for reference.
- Everything else under Sources/SwiftTerm is byte-for-byte upstream. Tests/SwiftTermVendorTests is ours.
