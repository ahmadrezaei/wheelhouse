import SwiftUI
import WheelhouseUI

enum AboutText {
    static let privacy = """
    Wheelhouse has no analytics, no tracking and no accounts.

    Cluster credentials (tokens, client certificates, CA certificates) are stored in the iOS Keychain on this device. They are only synced to your other devices through iCloud Keychain, end-to-end encrypted, if you turn on sync for a cluster.

    Wheelhouse talks directly from your device to the Kubernetes API servers you add. Nothing passes through a Wheelhouse server.

    Secret values are never logged or written to disk by the app and stay masked until you authenticate.
    """
}

struct AboutTextView: View {
    let title: String
    let text: String
    var body: some View {
        ScrollView { Text(text).padding(Spacing.l).frame(maxWidth: .infinity, alignment: .leading) }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

struct AcknowledgementsView: View {
    private let items: [(String, String, String)] = [
        ("Yams", "https://github.com/jpsim/Yams", "MIT License — Copyright (c) 2016 JP Simard. Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files, to deal in the Software without restriction, subject to the inclusion of the copyright notice and this permission notice in all copies or substantial portions of the Software. The software is provided \"as is\", without warranty of any kind."),
        ("SwiftTerm", "https://github.com/migueldeicaza/SwiftTerm", "MIT License — Copyright (c) 2020 Miguel de Icaza. Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files, to deal in the Software without restriction, subject to the inclusion of the copyright notice and this permission notice in all copies or substantial portions of the Software. The software is provided \"as is\", without warranty of any kind."),
    ]
    var body: some View {
        List(items, id: \.0) { item in
            VStack(alignment: .leading, spacing: 6) {
                Text(item.0).font(.headline)
                Text(item.1).font(.footnote).foregroundStyle(Palette.tintText)
                Text(item.2).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
        .navigationTitle("Acknowledgements").navigationBarTitleDisplayMode(.inline)
    }
}
