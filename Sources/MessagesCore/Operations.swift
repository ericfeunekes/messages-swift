import Foundation

/// Serializes local state and joins the current selected directory with read-only Messages queries.
public actor MessagesOperations {
    private let store: MessageStore
    private let directory: any ContactsDirectorySource
    private let binding: ContactsContainerBinding
    private let state: LocalState
    private let sender: any MessagesSending
    private let outgoingStagingDirectory: URL
    private var sendInProgress = false

    public init(store: MessageStore, directory: any ContactsDirectorySource, binding: ContactsContainerBinding, state: LocalState, sender: any MessagesSending = MessagesScriptingSender(), outgoingStagingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/Attachments/messages-swift", isDirectory: true)) {
        self.store = store
        self.directory = directory
        self.binding = binding
        self.state = state
        self.sender = sender
        self.outgoingStagingDirectory = outgoingStagingDirectory
    }

    public func sendMessage(_ input: SendMessageInput, now: Date = Date()) async throws -> SendMessageResult {
        guard (input.chatID == nil) != (input.recipients == nil),
              input.chatID.map({ !$0.isEmpty && !$0.utf8.contains(0) }) ?? true else { throw SendValidationError.invalidDestination }
        guard input.text != nil || !input.files.isEmpty,
              input.text.map({ !$0.isEmpty && !$0.utf8.contains(0) }) ?? true else { throw SendValidationError.invalidContent }
        var parts: [SendPartResult] = []
        if input.text != nil { parts.append(.init(index: 0, kind: "text", fileIndex: nil, outcome: .notAttempted)) }
        for index in input.files.indices { parts.append(.init(index: parts.count, kind: "file", fileIndex: index, outcome: .notAttempted)) }
        // Validate the whole batch before any command can leave this process.
        let files = try input.files.map { try OutgoingFile(path: $0) }
        let people = try preparedPeople(now: now)
        let target: SendTarget
        let destination: SendDestination
        if let chatID = input.chatID {
            guard input.service == nil else { throw SendValidationError.invalidDestination }
            guard let chat = try store.chat(id: ChatID(rawValue: chatID)) else { throw OperationError.unknownChat(chatID) }
            target = .chat(chatID)
            destination = .init(chatID: chatID, service: chat.service, recipients: enrich(chat, people: people).participants)
            try cacheUsed(people, handles: chat.participants, now: now)
        } else {
            guard let recipients = input.recipients, recipients.count == 1,
                  let service = input.service, ["iMessage", "SMS", "RCS"].contains(service) else { throw SendValidationError.invalidDestination }
            let selector = recipients[0]
            guard (selector.query == nil) != (selector.sourceIdentity == nil) else { throw SendValidationError.invalidDestination }
            let handles: [String]
            let candidates: [ContactCandidate]
            if let query = selector.query, Self.isExplicitSendHandle(query) {
                // Explicit handles never expand to another address on the contact.
                handles = [normalize(query)]
                candidates = []
            } else {
                let found: [ContactPerson]
                if let identity = selector.sourceIdentity { found = people.filter { $0.identity == identity } }
                else {
                    guard let query = selector.query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SendValidationError.invalidDestination }
                    found = people.filter { personMatches($0, query: query) }
                }
                guard !found.isEmpty else { throw OperationError.contactNotFound }
                candidates = found.count > 1 ? found.map { ContactCandidate(person: $0) } : []
                handles = found.count == 1 ? Array(Set(found[0].handles.map(normalize))).sorted() : []
            }
            if !candidates.isEmpty || handles.count != 1 {
                return .init(status: .needsChoice, delivery: "unconfirmed", destination: nil,
                             contactCandidates: candidates, handleCandidates: handles, parts: parts)
            }
            guard let handle = handles.first, Self.isExplicitSendHandle(handle) else { throw SendValidationError.invalidDestination }
            target = .individual(handle: handle, service: service)
            destination = .init(chatID: nil, service: service, recipients: [participant(handle, people: people)!])
            try cacheUsed(people, handles: [handle], now: now)
        }
        var result = SendMessageResult(status: .rejected, delivery: "unconfirmed", destination: destination,
                                       contactCandidates: [], handleCandidates: [], parts: parts)
        // Actor reentrancy must not interleave two multi-part batches.
        guard !sendInProgress else { result.errorCode = "send_in_progress"; return result }
        sendInProgress = true
        defer { sendInProgress = false }
        let staged = try StagedOutgoingFiles(files: files, root: outgoingStagingDirectory)
        defer { staged.cleanupUnhanded() }
        for index in result.parts.indices {
            if Task.isCancelled {
                result.errorCode = "send_cancelled"
                break
            }
            guard files.allSatisfy({ $0.isUnchanged() }) else {
                result.parts[index].outcome = .rejected
                result.parts[index].errorCode = "send_file_changed"
                break
            }
            let payload: SendPayload
            if let fileIndex = result.parts[index].fileIndex { payload = .file(staged.paths[fileIndex]) }
            else { payload = .text(input.text!) }
            let outcome = await sender.send(target: target, payload: payload)
            if let fileIndex = result.parts[index].fileIndex, outcome == .accepted || outcome == .unknown {
                staged.retain(index: fileIndex)
            }
            switch outcome {
            case .accepted: result.parts[index].outcome = .accepted
            case .unavailable:
                result.parts[index].outcome = .rejected
                result.parts[index].errorCode = "messages_route_unavailable"
            case .rejected:
                result.parts[index].outcome = .rejected
                result.parts[index].errorCode = "messages_rejected"
            case .unknown:
                result.parts[index].outcome = .unknown
                result.parts[index].errorCode = "messages_outcome_unknown"
            }
            if outcome != .accepted { break }
        }
        if result.parts.contains(where: { $0.outcome == .unknown }) { result.status = .unknown }
        else if result.parts.allSatisfy({ $0.outcome == .accepted }) { result.status = .accepted }
        else if result.parts.contains(where: { $0.outcome == .accepted }) { result.status = .partial }
        return result
    }

    private static func isExplicitSendHandle(_ value: String) -> Bool {
        guard !value.isEmpty, !value.utf8.contains(0) else { return false }
        if value.contains("@") {
            let parts = value.split(separator: "@", omittingEmptySubsequences: false)
            return !value.contains(where: { $0.isWhitespace }) && parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
        }
        let phone = value.trimmingCharacters(in: .whitespaces)
        let body = phone.hasPrefix("+") ? phone.dropFirst() : phone[...]
        return body.filter({ $0.isASCII && $0.isNumber }).count >= 7 &&
            body.allSatisfy { ($0.isASCII && $0.isNumber) || " ()-.".contains($0) }
    }

    public func refreshDueContacts(now: Date = Date()) throws {
        try state.bindContainer(binding.containerID)
        guard state.isSeeded else { _ = try preparedPeople(now: now); return }
        let due = state.entriesDueForRefresh(now: now)
        guard !due.isEmpty else { return }
        let identities = Set(due.map { $0.person.identity })
        let people = try directory.contacts(in: binding, identities: identities, matchingHandles: []).people
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

    public func readAttachment(_ input: ReadAttachmentInput) throws -> AttachmentContent {
        try store.readAttachment(input)
    }

    public func readImage(_ input: ReadAttachmentInput) throws -> AttachmentContent {
        try store.readAttachment(input, image: true)
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
        let lookup = try peopleForRead(handles: chat.participants + page.messages.compactMap(\.sender), now: now)
        let people = lookup.people
        try cacheUsed(people, handles: chat.participants + page.messages.compactMap(\.sender), identities: lookup.people.map(\.identity), now: now)
        return MessagePageResult(chat: enrich(chat, people: people, unresolvedHandles: lookup.unresolvedHandles), messages: page.messages.compactMap { message($0, people: people, unresolvedHandles: lookup.unresolvedHandles) },
                                 events: page.messages.compactMap { event($0, people: people, unresolvedHandles: lookup.unresolvedHandles) },
                                 decodingDiagnostics: diagnostics(page), decodingFailureCount: page.decodingFailureCount, scannedAssociationCount: page.scannedAssociationCount, unresolvedContactHandles: lookup.unresolvedHandles.sorted(), contactCandidates: contactCandidates(lookup), nextCursor: try encodeCursor(page.nextCursor))
    }

    public func watchMessages(_ input: WatchMessagesInput) async throws -> WatchMessagesResult {
        try validate(limit: input.limit, dates: DateRange())
        guard (0...20).contains(input.waitSeconds) else { throw WatchError.invalidWait }
        guard let chat = try store.chat(id: ChatID(rawValue: input.chatID)) else { throw OperationError.unknownChat(input.chatID) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(input.waitSeconds))
        var cursor: WatchCursor? = try decodeCursor(input.cursor)
        var records: [MessageRecord] = []
        var scannedAssociationCount = 0
        repeat {
            try Task.checkCancellation()
            let batch = try store.watchBatch(chatID: input.chatID, cursor: cursor, limit: input.limit)
            cursor = batch.cursor
            records = batch.records
            scannedAssociationCount += batch.scannedAssociationCount
            if !records.isEmpty || clock.now >= deadline { break }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(100))))
        } while true
        try Task.checkCancellation()
        let now = Date()
        let handles = chat.participants + records.compactMap(\.sender)
        let lookup = try peopleForRead(handles: handles, now: now)
        try cacheUsed(lookup.people, handles: handles, identities: lookup.people.map(\.identity), now: now)
        let failures = records.filter { $0.body.status == .failed }
        let page = MessagePageResult(chat: enrich(chat, people: lookup.people, unresolvedHandles: lookup.unresolvedHandles),
            messages: records.compactMap { message($0, people: lookup.people, unresolvedHandles: lookup.unresolvedHandles) },
            events: records.compactMap { event($0, people: lookup.people, unresolvedHandles: lookup.unresolvedHandles) },
            decodingDiagnostics: failures.prefix(10).map { DecodingDiagnostic(messageID: $0.id.rawValue, chatID: $0.chatID.rawValue, reason: "body decoding failed") },
            decodingFailureCount: failures.count, scannedAssociationCount: scannedAssociationCount,
            unresolvedContactHandles: lookup.unresolvedHandles.sorted(), contactCandidates: contactCandidates(lookup), nextCursor: nil)
        return WatchMessagesResult(status: records.isEmpty ? "no_match" : "messages", cursor: try encodeCursor(cursor)!, page: page)
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
        let chats = try store.chats(ids: ids)
        try cacheUsed(people, handles: chats.flatMap(\.participants) + page.messages.compactMap(\.sender), identities: resolution.identities, now: now)
        return SearchMessagesResult(chats: chats.map { enrich($0, people: people) }, messages: page.messages.compactMap { message($0, people: people) },
                                    events: page.messages.compactMap { event($0, people: people) }, decodingDiagnostics: diagnostics(page),
                                    contactCandidates: [], decodingFailureCount: page.decodingFailureCount, scannedAssociationCount: page.scannedAssociationCount, nextCursor: try encodeCursor(page.nextCursor))
    }

    public func countMessageActivity(_ input: CountMessageActivityInput, now: Date = Date()) throws -> CountMessageActivityResult {
        guard (1...100).contains(input.limit) else { throw OperationError.invalidLimit(input.limit) }
        if let zone = input.timeZone, TimeZone(identifier: zone) == nil { throw ActivityError.invalidTimeZone }
        if let start = input.dateRange.start, let end = input.dateRange.end, start > end { throw MessageStoreError.invalidDateRange }
        let cursor: ActivityCursor? = try decodeCursor(input.cursor)
        if let cursor, cursor.input != input.withoutCursor { throw MessageStoreError.cursorFilterMismatch }
        if cursor == nil, let chatID = input.chatID, try store.chat(id: ChatID(rawValue: chatID)) == nil {
            throw OperationError.unknownChat(chatID)
        }
        let people = try preparedPeople(now: now)
        let resolution: Resolution
        do { resolution = try resolve(input.participants, people: people) }
        catch OperationError.contactNotFound where cursor != nil { throw MessageStoreError.cursorFilterMismatch }
        guard resolution.candidates.isEmpty else {
            if cursor != nil { throw MessageStoreError.cursorFilterMismatch }
            return CountMessageActivityResult(resolvedDateRange: nil, timeZone: input.timeZone ?? TimeZone.current.identifier, groupBy: input.groupBy,
                bucket: input.bucket, ranking: input.ranking, rows: [], chats: [], contactCandidates: resolution.candidates, nextCursor: nil)
        }
        let filter = MessageFilter(chatID: input.chatID.map(ChatID.init(rawValue:)), participantHandleGroups: resolution.groups,
            exactMembership: input.membership == .exact, startDate: input.dateRange.start, endDate: input.dateRange.end, unreadOnly: input.unreadOnly)
        let page = try store.countMessageActivity(input, filter: filter, cursor: cursor, now: now)
        let chats = try store.chats(ids: Set(page.rows.compactMap { $0.chatID.map(ChatID.init(rawValue:)) }))
        try cacheUsed(people, handles: chats.flatMap(\.participants), identities: resolution.identities, now: now)
        return CountMessageActivityResult(resolvedDateRange: page.range, timeZone: page.timeZone, groupBy: input.groupBy,
            bucket: input.bucket, ranking: input.ranking, rows: page.rows, chats: chats.map { enrich($0, people: people) },
            contactCandidates: [], nextCursor: try encodeCursor(page.cursor))
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

    private func peopleForRead(handles: [String], now: Date) throws -> ContactLookup {
        guard state.isSeeded, !state.cacheEntries.contains(where: { $0.person.identity.containerID != binding.containerID }) else {
            return ContactLookup(people: try preparedPeople(now: now))
        }
        let wanted = Set(handles.map(normalize))
        let cached = state.cacheEntries.map(\.person).filter { person in person.handles.contains { wanted.contains(normalize($0)) } }
        let known = Set(cached.flatMap(\.handles).map(normalize))
        guard wanted.isSubset(of: known) else { return ContactLookup(people: try preparedPeople(now: now)) }
        let fresh = try directory.contacts(in: binding, identities: Set(cached.map(\.identity)), matchingHandles: wanted)
        try validateDirectory(fresh.people)
        let freshHandles = Set(fresh.people.flatMap(\.handles).map(normalize))
        guard wanted.subtracting(fresh.unresolvedHandles).isSubset(of: freshHandles) else { return ContactLookup(people: try preparedPeople(now: now)) }
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
            if found.count > 1 { result.candidates += found.map { ContactCandidate(person: $0) }; continue }
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
    private func participant(_ handle: String?, people: [ContactPerson], unresolvedHandles: Set<String> = []) -> Participant? {
        guard let handle else { return nil }
        if unresolvedHandles.contains(normalize(handle)) { return Participant(handle: handle) }
        let found = people.filter { $0.handles.contains { normalize($0) == normalize(handle) } }
        guard found.count == 1 else { return Participant(handle: handle) }
        return Participant(handle: handle, displayName: found[0].displayName, sourceIdentity: found[0].identity)
    }
    private func enrich(_ chat: ChatRecord, people: [ContactPerson], unresolvedHandles: Set<String> = []) -> ChatResult {
        let participants = chat.participants.compactMap { participant($0, people: people, unresolvedHandles: unresolvedHandles) }
        let alias = state.alias(for: chat.id.rawValue)
        let label = alias ?? chat.nativeName ?? participants.map { $0.displayName ?? $0.handle }.joined(separator: ", ")
        return ChatResult(chatID: chat.id.rawValue, label: label.isEmpty ? chat.identifier : label, nativeName: chat.nativeName, alias: alias,
                          participants: participants, service: chat.service, lastActivity: chat.lastActivityAt, unreadCount: chat.unreadCount)
    }
    private func attachments(_ record: MessageRecord) -> [AttachmentResult] {
        record.attachments.map { AttachmentResult(id: $0.id, filename: $0.transferName ?? $0.filename.map { URL(fileURLWithPath: $0).lastPathComponent }, mimeType: $0.mimeType, availability: $0.availability, transferState: $0.transferState) }
    }
    private func message(_ record: MessageRecord, people: [ContactPerson], unresolvedHandles: Set<String> = []) -> MessageResult? {
        guard MessageNormalizer.isMessage(record.kind) else { return nil }
        return MessageResult(id: record.id.rawValue, chatID: record.chatID.rawValue, date: record.date, sender: participant(record.sender, people: people, unresolvedHandles: unresolvedHandles),
                             isFromMe: record.isFromMe, text: record.body.text, attachments: attachments(record), kind: record.kind == .ordinary ? .ordinary : .attachment,
                             decodingStatus: record.body.status, isEdited: record.isEdited, isRetracted: record.isRetracted,
                             isSent: record.isSent, isDelivered: record.isDelivered, deliveryErrorCode: record.deliveryErrorCode)
    }
    private func event(_ record: MessageRecord, people: [ContactPerson], unresolvedHandles: Set<String> = []) -> MessageEventResult? {
        guard !MessageNormalizer.isMessage(record.kind) else { return nil }
        return MessageEventResult(id: record.id.rawValue, chatID: record.chatID.rawValue, date: record.date, kind: record.kind.rawValue, text: record.body.text,
                                  sender: participant(record.sender, people: people, unresolvedHandles: unresolvedHandles), associatedMessageID: record.associatedMessageGUID,
                                  associatedMessageType: record.associatedMessageType, decodingStatus: record.body.status,
                                  attachments: attachments(record), isEdited: record.isEdited, isRetracted: record.isRetracted,
                                  diagnostic: record.kind == .unknown ? "Source row classification is unavailable or unrecognized" : nil)
    }
    private func contactCandidates(_ lookup: ContactLookup) -> [ContactCandidate] {
        var result: [ContactCandidate] = []
        for handle in lookup.candidatesByHandle.keys.sorted() {
            for person in lookup.candidatesByHandle[handle, default: []] {
                let exact = person.handles.contains { normalize($0) == handle }
                result.append(ContactCandidate(person: person, requestedHandle: handle, match: exact ? .exact : .approximate))
            }
        }
        return result
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
        let generation: String
        let fence: Int64
        let beforeDate: Int64
        let beforeRow: Int64
    }
}

public enum OperationError: Error, Sendable {
    case invalidLimit(Int), unknownChat(String), invalidCursor, invalidSelector, contactNotFound, invalidDirectory, invalidQuery
}
