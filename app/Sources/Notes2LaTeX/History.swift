// Historique des versions : copies datées de chaque fichier, rangées hors du projet
// dans ~/Library/Application Support/Nabla/Historique/<projet>/<fichier>/.
import Foundation

struct Snapshot: Identifiable, Hashable {
    let url: URL
    let date: Date
    var id: URL { url }
    var text: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
}

func historyDir(root: URL, file: String) -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Nabla/Historique")
        .appendingPathComponent(root.path.replacingOccurrences(of: "/", with: "_"))
        .appendingPathComponent(file.replacingOccurrences(of: "/", with: "_"))
}

/// Versions d'un fichier, la plus récente d'abord.
func snapshots(root: URL, file: String) -> [Snapshot] {
    let urls = (try? FileManager.default.contentsOfDirectory(at: historyDir(root: root, file: file),
                                                             includingPropertiesForKeys: [.creationDateKey])) ?? []
    return urls.compactMap { url in
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate).flatMap { Snapshot(url: url, date: $0) }
    }
    .sorted { $0.date > $1.date }
}

/// Enregistre une version si elle diffère de la dernière et que celle-ci date d'au moins `minInterval` secondes.
/// Garde les 200 plus récentes.
@discardableResult
func saveSnapshot(_ text: String, root: URL, file: String, minInterval: TimeInterval = 0, now: Date = .now) -> Bool {
    let existing = snapshots(root: root, file: file)
    if let last = existing.first, last.text == text || now.timeIntervalSince(last.date) < minInterval { return false }
    let dir = historyDir(root: root, file: file)
    let name = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate, .withFullTime, .withFractionalSeconds])
        .replacingOccurrences(of: ":", with: "-")
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    } catch { return false }
    for old in existing.dropFirst(199) { try? FileManager.default.removeItem(at: old.url) }
    return true
}
