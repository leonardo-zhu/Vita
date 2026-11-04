import Foundation
import Testing
@testable import Vita

struct ChatRowTests {
    private func entry(_ excluded: Bool) -> ChatEntry {
        ChatEntry(id: UUID(), role: .user, text: "x", cardRef: nil, createdAt: Date(), isExcluded: excluded)
    }

    @Test func consecutiveExcludedMessagesCollapseIntoOneRow() {
        let entries = [entry(false), entry(true), entry(true), entry(false), entry(true)]
        let rows = ChatRow.rows(entries)
        #expect(rows.count == 4)
        #expect(rows[0] == .message(entries[0]))
        #expect(rows[1] == .hidden(firstID: entries[1].id, count: 2))
        #expect(rows[2] == .message(entries[3]))
        #expect(rows[3] == .hidden(firstID: entries[4].id, count: 1))
    }

    @Test func decodesExcludedFlagAndDefaultsToVisible() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let base = #"{"id":"6f1d1c1e-0000-4000-8000-000000000001","role":"user","text":"hi","cardRef":null,"createdAt":"2026-11-05T01:00:00Z""#
        let excluded = try decoder.decode(ChatMessageDTO.self, from: Data((base + #","excludedFromContext":true}"#).utf8))
        let old = try decoder.decode(ChatMessageDTO.self, from: Data((base + "}").utf8))
        #expect(excluded.domain.isExcluded)
        #expect(!old.domain.isExcluded)
    }
}
