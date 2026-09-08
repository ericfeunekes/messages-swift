import Foundation

public struct CachedContact: Codable, Sendable, Hashable {
    public let person: ContactPerson
    public let admittedAt: Date
    public let refreshedAt: Date

    public init(person: ContactPerson, admittedAt: Date, refreshedAt: Date) {
        self.person = person
        self.admittedAt = admittedAt
        self.refreshedAt = refreshedAt
    }
}

public enum LocalStateError: Error, Equatable, Sendable {
    case aliasAlreadyUsed(alias: String, chatIDs: [String])
    case unsupportedStateVersion(Int)
    case duplicateCachedContactIdentity(ContactIdentity)
}

/// Durable local state. The on-disk schema is two versioned JSON documents:
/// `contacts.json` has `{version,isSeeded,entries}` and `aliases.json` has
/// `{version,aliases}`. Separating files ensures cache replacement cannot
/// discard user-owned aliases. Writes replace a complete file atomically.
/// Operations serialize access to this type.
public final class LocalState {
    public static let defaultDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("messages-swift", isDirectory: true)

    private struct CacheFile: Codable {
        var version = 1
        var containerID: String?
        var isSeeded = false
        var entries: [CachedContact] = []
    }

    private struct AliasFile: Codable {
        var version = 1
        var aliases: [String: String] = [:]
    }

    private let directory: URL
    private let capacity: Int
    private var cache: CacheFile
    private var aliasFile: AliasFile

    public init(directory: URL = LocalState.defaultDirectory, capacity: Int = 100) throws {
        precondition(capacity > 0, "Contact cache capacity must be positive")
        self.directory = directory
        self.capacity = capacity
        let directoryAlreadyExists = FileManager.default.fileExists(atPath: directory.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !directoryAlreadyExists {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let loadedCache = try Self.read(CacheFile.self, from: directory.appendingPathComponent("contacts.json")) ?? CacheFile()
        let loadedAliases = try Self.read(AliasFile.self, from: directory.appendingPathComponent("aliases.json")) ?? AliasFile()
        try Self.validate(loadedCache)
        try Self.validate(loadedAliases)
        cache = loadedCache
        aliasFile = loadedAliases
    }

    public var isSeeded: Bool { cache.isSeeded }
    public var cacheEntries: [CachedContact] { cache.entries }

    /// A different selected source invalidates even an empty populated baseline.
    public func bindContainer(_ containerID: String) throws {
        guard cache.containerID != containerID else { return }
        var proposed = CacheFile()
        proposed.containerID = containerID
        try persistCache(proposed)
        cache = proposed
    }

    public func alias(for chatID: String) -> String? { aliasFile.aliases[chatID] }

    public func aliases() -> [String: String] { aliasFile.aliases }

    /// Seeds exactly once, including an intentionally empty frequent-contact baseline.
    public func seedInitialCache(_ people: [ContactPerson], now: Date) throws {
        guard !cache.isSeeded else { return }
        var proposed = cache
        var seen = Set<ContactIdentity>()
        proposed.entries = people.compactMap { person in
            guard seen.insert(person.identity).inserted, seen.count <= capacity else { return nil }
            return CachedContact(person: person, admittedAt: now, refreshedAt: now)
        }
        proposed.isSeeded = true
        try persistCache(proposed)
        cache = proposed
    }

    /// Records a current selected-container value on every use. Refreshing an
    /// existing entry preserves its original FIFO admission position.
    public func use(_ person: ContactPerson, now: Date) throws {
        try use([person], now: now)
    }

    /// One operation writes its used contacts together, in admission order.
    public func use(_ people: [ContactPerson], now: Date) throws {
        guard !people.isEmpty else { return }
        var proposed = cache
        for person in people {
        if let index = proposed.entries.firstIndex(where: { $0.person.identity == person.identity }) {
            let old = proposed.entries[index]
            proposed.entries[index] = CachedContact(person: person, admittedAt: old.admittedAt, refreshedAt: now)
        } else {
            if proposed.entries.count == capacity { proposed.entries.removeFirst() }
            proposed.entries.append(CachedContact(person: person, admittedAt: now, refreshedAt: now))
        }
        }
        try persistCache(proposed)
        cache = proposed
    }

    /// Removes a contact that is absent from the current selected-container
    /// snapshot. This only changes disposable cache data.
    public func removeCachedContact(_ identity: ContactIdentity) throws {
        guard let index = cache.entries.firstIndex(where: { $0.person.identity == identity }) else { return }
        var proposed = cache
        proposed.entries.remove(at: index)
        try persistCache(proposed)
        cache = proposed
    }

    /// Discards cache data when its selected-container binding changes. Aliases
    /// are held in a different file and remain untouched.
    public func discardCachedContacts() throws {
        var proposed = cache
        proposed.entries = []
        proposed.isSeeded = false
        try persistCache(proposed)
        cache = proposed
    }

    /// Returns cached records due for a daily refresh. The scheduler owns when
    /// to call this; this method does not claim to perform an upstream refresh.
    public func entriesDueForRefresh(now: Date, calendar: Calendar = .current) -> [CachedContact] {
        cache.entries.filter { !calendar.isDate($0.refreshedAt, inSameDayAs: now) }
    }

    public func setAlias(_ alias: String, for chatID: String) throws {
        let normalized = Self.normalizedAlias(alias)
        let conflicts = aliasFile.aliases.compactMap { candidateID, candidateAlias -> String? in
            candidateID != chatID && Self.normalizedAlias(candidateAlias) == normalized ? candidateID : nil
        }.sorted()
        guard conflicts.isEmpty else {
            throw LocalStateError.aliasAlreadyUsed(alias: alias, chatIDs: conflicts)
        }
        var proposed = aliasFile
        proposed.aliases[chatID] = alias
        try persistAliases(proposed)
        aliasFile = proposed
    }

    public func removeAlias(for chatID: String) throws {
        guard aliasFile.aliases[chatID] != nil else { return }
        var proposed = aliasFile
        proposed.aliases.removeValue(forKey: chatID)
        try persistAliases(proposed)
        aliasFile = proposed
    }

    private static func normalizedAlias(_ alias: String) -> String {
        alias.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private static func validate(_ file: CacheFile) throws {
        guard file.version == 1 else { throw LocalStateError.unsupportedStateVersion(file.version) }
        var identities = Set<ContactIdentity>()
        for entry in file.entries {
            guard identities.insert(entry.person.identity).inserted else {
                throw LocalStateError.duplicateCachedContactIdentity(entry.person.identity)
            }
        }
    }

    private static func validate(_ file: AliasFile) throws {
        guard file.version == 1 else { throw LocalStateError.unsupportedStateVersion(file.version) }
    }

    private func persistCache(_ proposed: CacheFile) throws {
        try write(JSONEncoder().encode(proposed), to: directory.appendingPathComponent("contacts.json"))
    }

    private func persistAliases(_ proposed: AliasFile) throws {
        try write(JSONEncoder().encode(proposed), to: directory.appendingPathComponent("aliases.json"))
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
