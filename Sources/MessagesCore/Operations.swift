import Foundation

/// Serializes local state and joins the current selected directory with read-only Messages queries.
public actor MessagesOperations {
    private let store: MessageStore
    private let directory: any ContactsDirectorySource
    private let binding: ContactsContainerBinding
    private let state: LocalState

    public init(store: MessageStore, directory: any ContactsDirectorySource, binding: ContactsContainerBinding, state: LocalState) {
        self.store = store
        self.directory = directory
        self.binding = binding
        self.state = state
    }

    public func refreshDueContacts(now: Date = Date()) throws {
        try state.bindContainer(binding.containerID)
        guard state.isSeeded else { _ = try preparedPeople(now: now); return }
        let due = state.entriesDueForRefresh(now: now)
        guard !due.isEmpty else { return }
        let identities = Set(due.map { $0.person.identity })
        let people = try directory.contacts(in: binding, identities: identities, matchingHandles: [])
        try validateDirectory(people)
        let found = Set(people.map(\.identity))
        for identity in identities.subtracting(found) { try state.removeCachedContact(identity) }
        try state.use(people, now: now)
    }

    public func setChatAlias(_ input: SetChatAliasInput) throws -> SetChatAliasResult {
        guard try store.chat(id: ChatID(rawValue: input.chatID)) != nil else { throw OperationError.unknownChat(input.chatID) }
        if let alias = input.alias {
            guard !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OperationError.invalidSelector }
            try state.setAlias(alias, for: input.chatID)
        } else { try state.removeAlias(for: input.chatID) }
        return SetChatAliasResult(chatID: input.chatID, alias: state.alias(for: input.chatID))
    }

    public func findChats(_ input: FindChatsInput, now: Date = Date()) throws -> FindChatsResult {
        try validate(limit: input.limit, dates: input.dateRange)
        let people = try preparedPeople(now: now)
        let resolution = try resolve(input.participants, people: people)
        guard resolution.candidates.isEmpty else {
            return FindChatsResult(chats: [], contactCandidates: resolution.candidates, nextCursor: nil)
        }
        let filter = ChatFilter(participantHandleGroups: resolution.groups, exactMembership: input.membership == .exact,
                                startDate: input.dateRange.start, endDate: input.dateRange.end, unreadOnly: input.unreadOnly)
        let cursor: FindCursor? = try decodeCursor(input.cursor)
        let original = FindChatsInput(query: input.query, participants: input.participants, membership: input.membership,
                                      dateRange: input.dateRange, unreadOnly: input.unreadOnly, limit: input.limit)
        if let cursor, cursor.input != original { throw OperationError.invalidCursor }
        let snapshot = try store.chatSnapshot(filter: filter, arrivalFenceRowID: cursor?.fence, databaseGeneration: cursor?.generation)
        let matching = snapshot.chats.filter { chat in
            guard matches(chat, query: input.query, people: people) else { return false }
            guard let cursor else { return true }
            return (chat.lastActivityNanos ?? Int64.min) < cursor.beforeDate || ((chat.lastActivityNanos ?? Int64.min) == cursor.beforeDate && chat.sourceRowID < cursor.beforeRow)
        }
        let selected = Array(matching.prefix(input.limit))
        try cacheUsed(people, handles: selected.flatMap(\.participants), identities: resolution.identities, now: now)
        let next: String?
        if matching.count > input.limit, let last = selected.last {
            next = try encodeCursor(FindCursor(input: original, generation: snapshot.databaseGeneration, fence: snapshot.arrivalFenceRowID,
                                              beforeDate: last.lastActivityNanos ?? Int64.min, beforeRow: last.sourceRowID))
        } else { next = nil }
        return FindChatsResult(chats: selected.map { enrich($0, people: people) }, contactCandidates: [], nextCursor: next)
    }

    public func readMessages(_ input: ReadMessagesInput, now: Date = Date()) throws -> MessagePageResult {
        try validate(limit: input.limit, dates: input.dateRange)
        guard let chat = try store.chat(id: ChatID(rawValue: input.chatID)) else { throw OperationError.unknownChat(input.chatID) }
        let filter = MessageFilter(chatID: chat.id, startDate: input.dateRange.start, endDate: input.dateRange.end, unreadOnly: input.unreadOnly)
        let page = try store.readMessages(ReadMessagesRequest(filter: filter, limit: input.limit, cursor: try decodeCursor(input.cursor)))
        let people = try peopleForRead(handles: chat.participants + page.messages.compactMap(\.sender), now: now)
        try cacheUsed(people, handles: chat.participants + page.messages.compactMap(\.sender), now: now)
        return MessagePageResult(chat: enrich(chat, people: people), messages: page.messages.compactMap { message($0, people: people) },
                                 events: page.messages.compactMap { event($0, people: people) },
                                 decodingDiagnostics: diagnostics(page), nextCursor: try encodeCursor(page.nextCursor))
    }

    public func searchMessages(_ input: SearchMessagesInput, now: Date = Date()) throws -> SearchMessagesResult {
        try validate(limit: input.limit, dates: input.dateRange)
        guard !input.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OperationError.invalidQuery }
        if let chatID = input.chatID, try store.chat(id: ChatID(rawValue: chatID)) == nil { throw OperationError.unknownChat(chatID) }
        let people = try preparedPeople(now: now)
        let resolution = try resolve(input.participants, people: people)
        guard resolution.candidates.isEmpty else {
            return SearchMessagesResult(chats: [], messages: [], events: [], decodingDiagnostics: [], contactCandidates: resolution.candidates, nextCursor: nil)
        }
        let filter = MessageFilter(chatID: input.chatID.map(ChatID.init(rawValue:)), participantHandleGroups: resolution.groups,
                                   exactMembership: input.membership == .exact, startDate: input.dateRange.start,
                                   endDate: input.dateRange.end, unreadOnly: input.unreadOnly)
        let page = try store.searchMessages(SearchMessagesRequest(filter: filter, query: input.query, limit: input.limit, cursor: try decodeCursor(input.cursor)))
        let ids = Set(page.messages.map(\.chatID) + page.decodingFailures.map(\.chatID))
        let chats = try store.allChats().filter { ids.contains($0.id) }
        try cacheUsed(people, handles: chats.flatMap(\.participants) + page.messages.compactMap(\.sender), identities: resolution.identities, now: now)
        return SearchMessagesResult(chats: chats.map { enrich($0, people: people) }, messages: page.messages.compactMap { message($0, people: people) },
                                    events: page.messages.compactMap { event($0, people: people) }, decodingDiagnostics: diagnostics(page),
                                    contactCandidates: [], nextCursor: try encodeCursor(page.nextCursor))
    }

    private func preparedPeople(now: Date) throws -> [ContactPerson] {
        let people = try directory.allContacts(in: binding)
        try validateDirectory(people)
        try state.bindContainer(binding.containerID)
        if state.cacheEntries.contains(where: { $0.person.identity.containerID != binding.containerID }) { try state.discardCachedContacts() }
        if !state.isSeeded {
            let frequency = try store.frequentContactHandles(since: now.addingTimeInterval(-90 * 86_400))
            let normalized = Dictionary(frequency.map { (normalize($0.key), $0.value) }, uniquingKeysWith: +)
            var scores: [(person: ContactPerson, score: Int)] = []
            for person in people {
                let score = Set(person.handles.map(normalize)).reduce(0) { $0 + (normalized[$1] ?? 0) }
                if score > 0 { scores.append((person, score)) }
            }
            scores.sort { left, right in
                if left.score == right.score { return left.person.identity.id < right.person.identity.id }
                return left.score > right.score
            }
            try state.seedInitialCache(scores.map(\.person), now: now)
        }
        let current = Dictionary(uniqueKeysWithValues: people.map { ($0.identity, $0) })
        var overdue: [ContactPerson] = []
        let due = Set(state.entriesDueForRefresh(now: now).map { $0.person.identity })
        for cached in state.cacheEntries {
            guard let person = current[cached.person.identity] else { try state.removeCachedContact(cached.person.identity); continue }
            if due.contains(person.identity) { overdue.append(person) }
        }
        try state.use(overdue, now: now)
        return people
    }

    private func peopleForRead(handles: [String], now: Date) throws -> [ContactPerson] {
        guard state.isSeeded, !state.cacheEntries.contains(where: { $0.person.identity.containerID != binding.containerID }) else {
            return try preparedPeople(now: now)
        }
        let wanted = Set(handles.map(normalize))
        let cached = state.cacheEntries.map(\.person).filter { person in person.handles.contains { wanted.contains(normalize($0)) } }
        let known = Set(cached.flatMap(\.handles).map(normalize))
        guard wanted.isSubset(of: known) else { return try preparedPeople(now: now) }
        let fresh = try directory.contacts(in: binding, identities: Set(cached.map(\.identity)), matchingHandles: wanted)
        try validateDirectory(fresh)
        let freshHandles = Set(fresh.flatMap(\.handles).map(normalize))
        guard wanted.isSubset(of: freshHandles) else { return try preparedPeople(now: now) }
        return fresh
    }

    private func validateDirectory(_ people: [ContactPerson]) throws {
        guard people.allSatisfy({ $0.identity.containerID == binding.containerID }), Set(people.map(\.identity)).count == people.count else {
            throw OperationError.invalidDirectory
        }
    }

    private struct Resolution { var groups: [[String]] = []; var identities: [ContactIdentity] = []; var candidates: [ContactCandidate] = [] }
    private func resolve(_ selectors: [PersonSelector], people: [ContactPerson]) throws -> Resolution {
        var result = Resolution()
        for selector in selectors {
            guard (selector.query == nil) != (selector.sourceIdentity == nil) else { throw OperationError.invalidSelector }
            let found: [ContactPerson]
            if let identity = selector.sourceIdentity { found = people.filter { $0.identity == identity } }
            else {
                let query = selector.query!
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OperationError.invalidSelector }
                found = people.filter { personMatches($0, query: query) }
                // Explicit full handles can address people absent from Contacts.
                if found.isEmpty, query.contains("@") || query.filter(\.isNumber).count >= 7 {
                    result.groups.append([normalize(query)]); continue
                }
            }
            guard !found.isEmpty else { throw OperationError.contactNotFound }
            if found.count > 1 { result.candidates += found.map(ContactCandidate.init); continue }
            let person = found[0]
            guard !person.handles.isEmpty else { throw OperationError.contactNotFound }
            result.groups.append(Array(Set(person.handles.map(normalize))).sorted())
            result.identities.append(person.identity)
        }
        return result
    }

    private func cacheUsed(_ people: [ContactPerson], handles: [String], identities: [ContactIdentity] = [], now: Date) throws {
        let used = Set(handles.map(normalize))
        let selected = people.filter { person in identities.contains(person.identity) || person.handles.contains(where: { used.contains(normalize($0)) }) }
        try state.use(selected, now: now)
    }

    private func normalize(_ handle: String) -> String {
        normalizedContactHandle(handle)
    }
    private func personMatches(_ person: ContactPerson, query: String) -> Bool {
        person.displayName.localizedCaseInsensitiveContains(query) || person.handles.contains { $0.localizedCaseInsensitiveContains(query) || normalize($0) == normalize(query) }
    }
    private func matches(_ chat: ChatRecord, query: String?, people: [ContactPerson]) -> Bool {
        guard let query else { return true }
        let values = [state.alias(for: chat.id.rawValue) ?? "", chat.nativeName ?? "", chat.identifier] + chat.participants
        if values.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
        let handles = Set(chat.participants.map(normalize))
        return people.contains { personMatches($0, query: query) && $0.handles.contains { handles.contains(normalize($0)) } }
    }
    private func participant(_ handle: String?, people: [ContactPerson]) -> Participant? {
        guard let handle else { return nil }
        let found = people.filter { $0.handles.contains { normalize($0) == normalize(handle) } }
        guard found.count == 1 else { return Participant(handle: handle) }
        return Participant(handle: handle, displayName: found[0].displayName, sourceIdentity: found[0].identity)
    }
    private func enrich(_ chat: ChatRecord, people: [ContactPerson]) -> ChatResult {
        let participants = chat.participants.compactMap { participant($0, people: people) }
        let alias = state.alias(for: chat.id.rawValue)
        let label = alias ?? chat.nativeName ?? participants.map { $0.displayName ?? $0.handle }.joined(separator: ", ")
        return ChatResult(chatID: chat.id.rawValue, label: label.isEmpty ? chat.identifier : label, nativeName: chat.nativeName, alias: alias,
                          participants: participants, service: chat.service, lastActivity: chat.lastActivityAt, unreadCount: chat.unreadCount)
    }
    private func attachments(_ record: MessageRecord) -> [AttachmentResult] {
        record.attachments.map { AttachmentResult(id: $0.id, filename: $0.transferName ?? $0.filename.map { URL(fileURLWithPath: $0).lastPathComponent }, mimeType: $0.mimeType, availability: $0.availability) }
    }
    private func message(_ record: MessageRecord, people: [ContactPerson]) -> MessageResult? {
        guard record.kind == .ordinary || record.kind == .attachmentOnly else { return nil }
        return MessageResult(id: record.id.rawValue, chatID: record.chatID.rawValue, date: record.date, sender: participant(record.sender, people: people),
                             isFromMe: record.isFromMe, text: record.body.text, attachments: attachments(record), kind: record.kind == .ordinary ? .ordinary : .attachment,
                             decodingStatus: record.body.status, isEdited: record.isEdited, isRetracted: record.isRetracted)
    }
    private func event(_ record: MessageRecord, people: [ContactPerson]) -> MessageEventResult? {
        guard record.kind != .ordinary && record.kind != .attachmentOnly else { return nil }
        return MessageEventResult(id: record.id.rawValue, chatID: record.chatID.rawValue, date: record.date, kind: record.kind.rawValue, text: record.body.text,
                                  sender: participant(record.sender, people: people), associatedMessageID: record.associatedMessageGUID,
                                  associatedMessageType: record.associatedMessageType, decodingStatus: record.body.status,
                                  attachments: attachments(record), isEdited: record.isEdited, isRetracted: record.isRetracted,
                                  diagnostic: record.kind == .unknown ? "Source row classification is unavailable or unrecognized" : nil)
    }
    private func diagnostics(_ page: MessagePage) -> [DecodingDiagnostic] {
        page.decodingFailures.map { DecodingDiagnostic(messageID: $0.messageID.rawValue, chatID: $0.chatID.rawValue, reason: "body decoding failed") }
    }
    private func validate(limit: Int, dates: DateRange) throws {
        guard (1...100).contains(limit) else { throw OperationError.invalidLimit(limit) }
        if let start = dates.start, let end = dates.end, start >= end { throw MessageStoreError.invalidDateRange }
    }
    private func encodeCursor<T: Encodable>(_ value: T?) throws -> String? { try value.map { try JSONEncoder().encode($0).base64EncodedString() } }
    private func decodeCursor<T: Decodable>(_ value: String?) throws -> T? {
        guard let value else { return nil }
        guard let data = Data(base64Encoded: value) else { throw OperationError.invalidCursor }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw OperationError.invalidCursor }
    }
    private struct FindCursor: Codable {
        let input: FindChatsInput
        let generation: Int64
        let fence: Int64
        let beforeDate: Int64
        let beforeRow: Int64
    }
}

public enum OperationError: Error, Sendable {
    case invalidLimit(Int), unknownChat(String), invalidCursor, invalidSelector, contactNotFound, invalidDirectory, invalidQuery
}
