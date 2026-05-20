import Foundation

actor TransferManifestStore {
    private let fileURL: URL
    private var manifest: TransferManifest

    init(filename: String = "transfer-manifest.json") {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TailSync", isDirectory: true)
        self.fileURL = supportDirectory.appendingPathComponent(filename)

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.manifest.decode(TransferManifest.self, from: data) {
            self.manifest = decoded
        } else {
            self.manifest = TransferManifest()
        }
    }

    func allRecords() -> [TransferRecord] {
        manifest.records.values.sorted { lhs, rhs in
            switch (lhs.creationDate, rhs.creationDate) {
            case let (left?, right?):
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.filename < rhs.filename
            }
        }
    }

    func record(for id: String) -> TransferRecord? {
        manifest.records[id]
    }

    func upsert(_ record: TransferRecord) async throws {
        manifest.records[record.id] = record
        try save()
    }

    func upsert(_ records: [TransferRecord]) async throws {
        guard !records.isEmpty else { return }
        for record in records {
            manifest.records[record.id] = record
        }
        try save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.manifest.encode(manifest)
        try data.write(to: fileURL, options: [.atomic])
    }
}

private extension JSONEncoder {
    static var manifest: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var manifest: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
