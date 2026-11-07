import Foundation

/// The live metadata-only list (M6a). The API server answers `PartialObjectMetadataList`: every item carries `metadata` and
/// nothing else, so listing every Helm release Secret costs kilobytes, never the payloads.
extension LiveKubeClient {
    static let partialMetadataAccept = "application/json;as=PartialObjectMetadataList;g=meta.k8s.io;v=v1"

    private struct MetadataPage: Decodable {
        struct Item: Decodable { var metadata: ObjectMeta }
        var metadata: ListMeta?
        var items: [Item]?
    }

    /// With `limit` the call returns that single page (and `continueToken` when more exists); without it, every page is read
    /// (500 at a time) and joined.
    public func listMetadata(kind: ResourceKind, namespace: String?, labelSelector: String?, limit: Int?) async throws -> ObjectMetadataList {
        let pageSize = limit ?? 500
        var items: [ObjectMeta] = []
        var resourceVersion: String?
        var continueToken: String?
        repeat {
            var query: [(String, String)] = []
            if let labelSelector, !labelSelector.isEmpty { query.append(("labelSelector", labelSelector)) }
            query.append(("limit", String(pageSize)))
            if let continueToken { query.append(("continue", continueToken)) }
            var request = try makeRequest(path: kind.collectionPath(namespace: namespace), query: query)
            request.setValue(Self.partialMetadataAccept, forHTTPHeaderField: "Accept")
            let data = try await perform(request)
            let page: MetadataPage
            do { page = try KubeJSON.decoder.decode(MetadataPage.self, from: data) }
            catch { throw KubeError.decoding(String(describing: error).prefix(300).description) }
            items += (page.items ?? []).map(\.metadata)
            resourceVersion = resourceVersion ?? page.metadata?.resourceVersion
            continueToken = page.metadata?.continue.flatMap { $0.isEmpty ? nil : $0 }
        } while limit == nil && continueToken != nil
        return ObjectMetadataList(kind: kind, items: items, resourceVersion: resourceVersion, continueToken: continueToken)
    }
}
