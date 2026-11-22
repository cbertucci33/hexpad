import XCTest
@testable import HexpadKit

/// Wave 5B — Edit > Change History.
///
/// The model is pure: these tests feed synthetic timestamps and text snapshots
/// straight in, so no window, save panel or clock is involved.
final class ChangeHistoryTests: XCTestCase {

    private func date(_ seconds: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: TimeInterval(seconds))
    }

    // MARK: - Recording

    func testSavedEntryKeepsExactSnapshotAndLabel() {
        let model = ChangeHistoryModel()
        let text = "line one\nline two\r\n"
        let entry = model.recordSaved(snapshot: text, at: date(100))

        XCTAssertEqual(entry.kind, .saved)
        XCTAssertEqual(entry.timestamp, date(100))
        XCTAssertEqual(entry.snapshot, text)
        XCTAssertTrue(model.snapshot(for: entry) == text, "revert uses the verbatim snapshot")
        XCTAssertTrue(entry.title.hasPrefix("Saved on "), entry.title)
        XCTAssertEqual(model.count, 1)
    }

    func testModifiedEntryHasNoSnapshot() {
        let model = ChangeHistoryModel()
        let entry = model.recordModified(at: date(100))

        XCTAssertEqual(entry.kind, .modified)
        XCTAssertNil(entry.snapshot)
        XCTAssertNil(model.snapshot(for: entry))
        XCTAssertTrue(entry.title.hasPrefix("Modified on "), entry.title)
    }

    func testGenericRecordRoutesBothKinds() {
        let model = ChangeHistoryModel()
        let saved = model.record(.saved, snapshot: "abc", at: date(1))
        let modified = model.record(.modified, at: date(2))
        XCTAssertEqual(model.entries.map(\.kind), [.saved, .modified])
        XCTAssertEqual(model.snapshot(for: saved), "abc")
        XCTAssertNil(model.snapshot(for: modified))
    }

    // MARK: - Coalescing window (2s, pinned in ChangeHistoryModel)

    func testPureCoalescingDecisionAtWindowBoundaries() {
        let t = date(1_000)
        XCTAssertFalse(ChangeHistoryModel.shouldCoalesce(last: nil, current: t))
        XCTAssertTrue(ChangeHistoryModel.shouldCoalesce(last: t, current: t.addingTimeInterval(0.5)))
        XCTAssertTrue(ChangeHistoryModel.shouldCoalesce(last: t, current: t.addingTimeInterval(1.999)))
        XCTAssertFalse(ChangeHistoryModel.shouldCoalesce(last: t, current: t.addingTimeInterval(2.0)))
        XCTAssertFalse(ChangeHistoryModel.shouldCoalesce(last: t, current: t.addingTimeInterval(-1)),
                       "out-of-order timestamps never coalesce")
        XCTAssertTrue(ChangeHistoryModel.shouldCoalesce(last: t, current: t.addingTimeInterval(3),
                                                        window: 5),
                      "callers may narrow or widen the window")
    }

    func testBurstOfKeystrokesBecomesOneModifiedEntry() {
        let model = ChangeHistoryModel()
        let first = model.recordModified(at: date(10))
        for second in [11, 12, 12.5] {
            let entry = model.recordModified(at: Date(timeIntervalSinceReferenceDate: Double(second)))
            XCTAssertEqual(entry.id, first.id, "same burst keeps one identity")
        }

        XCTAssertEqual(model.count, 1)
        XCTAssertEqual(model.entries[0].timestamp, Date(timeIntervalSinceReferenceDate: 12.5))
        XCTAssertEqual(model.entries[0].kind, .modified)
    }

    func testGapBeyondWindowStartsANewModifiedEntry() {
        let model = ChangeHistoryModel()
        _ = model.recordModified(at: date(10))
        _ = model.recordModified(at: date(11))
        let third = model.recordModified(at: date(20))

        XCTAssertEqual(model.count, 2)
        XCTAssertEqual(model.entries.map(\.timestamp), [date(11), date(20)])
        XCTAssertNotEqual(model.entries[0].id, third.id)
    }

    func testSaveBreaksTheModificationBurst() {
        let model = ChangeHistoryModel()
        _ = model.recordModified(at: date(10))
        _ = model.recordSaved(snapshot: "baseline", at: date(11))
        let afterSave = model.recordModified(at: Date(timeIntervalSinceReferenceDate: 11.5)) // within 2s of the save

        XCTAssertEqual(model.count, 3, "the post-save edit is its own modified entry")
        XCTAssertEqual(afterSave.kind, .modified)
        XCTAssertEqual(model.entries.map(\.kind), [.modified, .saved, .modified])
    }

    // MARK: - Cap

    func testEntryLimitCapsSavedEntriesAndTheirSnapshots() {
        let model = ChangeHistoryModel()
        for index in 0..<25 {
            model.recordSaved(snapshot: "snapshot-\(index)", at: date(index))
        }

        XCTAssertEqual(model.count, ChangeHistoryModel.entryLimit)
        XCTAssertEqual(model.entries.first?.snapshot, "snapshot-5", "oldest five rows dropped")
        XCTAssertEqual(model.entries.last?.snapshot, "snapshot-24")
        XCTAssertEqual(model.menuEntries.count, ChangeHistoryModel.entryLimit)
        XCTAssertFalse(model.entries.contains { $0.snapshot == "snapshot-4" })
    }

    func testMenuCapIsSharedBetweenSavedAndModifiedGroups() {
        let model = ChangeHistoryModel()
        // 15 saves, each followed by a modification in a new burst (>2s apart).
        for index in 0..<15 {
            model.recordSaved(snapshot: "s\(index)", at: date(index * 10))
            model.recordModified(at: date(index * 10 + 5))
        }

        // The 20-entry cap applies to the raw record first, so the oldest
        // saves (and their modifications) are gone; the menu projection then
        // shows exactly those 20 rows, split across both groups.
        XCTAssertEqual(model.count, ChangeHistoryModel.entryLimit)
        let menu = model.menuEntries
        XCTAssertEqual(menu.count, ChangeHistoryModel.entryLimit)
        XCTAssertEqual(menu.filter(\.isSaved).count, 10)
        XCTAssertEqual(menu.filter { !$0.isSaved }.count, 10)
    }

    // MARK: - Menu projection

    func testMenuListsSavedFirstThenModifiedEachNewestFirst() {
        let model = ChangeHistoryModel()
        let oldSave = model.recordSaved(snapshot: "old", at: date(1))
        let oldEdit = model.recordModified(at: date(2))
        let newSave = model.recordSaved(snapshot: "new", at: date(3))
        let newEdit = model.recordModified(at: date(4))

        XCTAssertEqual(model.menuEntries, [newSave, oldSave, newEdit, oldEdit])
        XCTAssertEqual(model.menuEntries.map(\.title).prefix(2),
                       [newSave.title, oldSave.title])
    }

    func testStaleAndModifiedSnapshotsAreNotRevertible() {
        let model = ChangeHistoryModel()
        let stale = model.recordSaved(snapshot: "stale", at: date(0))
        for index in 1...ChangeHistoryModel.entryLimit {
            model.recordSaved(snapshot: "s\(index)", at: date(index))
        }
        XCTAssertNil(model.snapshot(for: stale), "a trimmed row cannot be reverted")
        XCTAssertEqual(model.snapshot(for: model.entries.last!), "s20")
    }

    func testEmptyModelHasEmptyMenu() {
        let model = ChangeHistoryModel()
        XCTAssertTrue(model.isEmpty)
        XCTAssertTrue(model.menuEntries.isEmpty)
        XCTAssertFalse(model.hasChangesSinceSave)
    }

    // MARK: - Edits since save (S18b-1)

    func testRecordEditTracksTimestampsAndRanges() {
        let model = ChangeHistoryModel()
        let range = NSRange(location: 4, length: 2)
        model.record(edit: ChangeHistoryEdit(timestamp: date(100), range: range))
        model.record(edit: ChangeHistoryEdit(timestamp: date(101)))

        XCTAssertEqual(model.changesSinceSaveCount, 2)
        XCTAssertTrue(model.hasChangesSinceSave)
        XCTAssertEqual(model.editsSinceSave.map(\.timestamp), [date(100), date(101)])
        XCTAssertEqual(model.editsSinceSave[0].range, range)
        XCTAssertNil(model.editsSinceSave[1].range)
        XCTAssertEqual(model.count, 0, "since-save edits are not menu rows")
    }

    func testEveryEditCountsEvenWhenMenuRowCoalesces() {
        let model = ChangeHistoryModel()
        _ = model.recordModified(at: date(10))
        _ = model.recordModified(at: date(11))
        _ = model.recordModified(at: date(12))

        XCTAssertEqual(model.count, 1, "one coalesced menu row for the burst")
        XCTAssertEqual(model.changesSinceSaveCount, 3, "every edit advances the count")
        XCTAssertEqual(model.editsSinceSave.map(\.timestamp), [date(10), date(11), date(12)])
    }

    func testRecordModifiedCarriesRangeIntoSinceSaveLog() {
        let model = ChangeHistoryModel()
        let range = NSRange(location: 3, length: 5)
        _ = model.recordModified(in: range, at: date(1))

        XCTAssertEqual(model.editsSinceSave.first?.range, range)
        XCTAssertEqual(model.changesSinceSaveCount, 1)
    }

    func testMarkSavedClearsSinceSaveButLeavesMenuHistory() {
        let model = ChangeHistoryModel()
        model.recordSaved(snapshot: "base", at: date(1))
        _ = model.recordModified(at: date(2))
        XCTAssertEqual(model.changesSinceSaveCount, 1)

        model.markSaved()

        XCTAssertEqual(model.changesSinceSaveCount, 0)
        XCTAssertFalse(model.hasChangesSinceSave)
        XCTAssertEqual(model.count, 2, "menu rows survive marking the baseline")
        XCTAssertEqual(model.editsSinceSave, [])
    }

    func testSaveClearsPendingEditCount() {
        let model = ChangeHistoryModel()
        _ = model.recordModified(at: date(1))
        _ = model.recordModified(at: date(2))
        XCTAssertEqual(model.changesSinceSaveCount, 2)

        let saved = model.recordSaved(snapshot: "saved", at: date(3))

        XCTAssertEqual(model.changesSinceSaveCount, 0)
        XCTAssertEqual(model.snapshot(for: saved), "saved")
    }

    func testSinceSaveDirtyViewMirrorsEditThenSave() {
        let model = ChangeHistoryModel()
        XCTAssertFalse(model.hasChangesSinceSave, "fresh document starts clean")

        _ = model.recordModified(at: date(1))
        XCTAssertTrue(model.hasChangesSinceSave, "an edit makes it dirty")

        model.recordSaved(snapshot: "clean", at: date(2))
        XCTAssertFalse(model.hasChangesSinceSave, "a save clears the dirty view again")
    }

    func testSinceSaveLogIsCappedAndDropsOldest() {
        let model = ChangeHistoryModel()
        let overflow = 5
        for index in 0..<(ChangeHistoryModel.editLimit + overflow) {
            model.record(edit: ChangeHistoryEdit(timestamp: date(index)))
        }

        XCTAssertEqual(model.changesSinceSaveCount, ChangeHistoryModel.editLimit)
        XCTAssertEqual(model.editsSinceSave.first?.timestamp, date(overflow))
        XCTAssertEqual(model.editsSinceSave.last?.timestamp,
                       date(ChangeHistoryModel.editLimit + overflow - 1))
    }

    /// P-11: the bounded log is a ring, so it keeps rotating correctly after
    /// several wraps and still hands back newest-first order to callers. The
    /// cap and the "oldest dropped" rule are unchanged.
    func testSinceSaveRingKeepsNewestEntriesAfterSeveralWraps() {
        let model = ChangeHistoryModel()
        let total = ChangeHistoryModel.editLimit * 2 + 7
        for index in 0..<total {
            model.record(edit: ChangeHistoryEdit(timestamp: date(index)))
        }

        XCTAssertEqual(model.changesSinceSaveCount, ChangeHistoryModel.editLimit)
        XCTAssertEqual(model.editsSinceSave.count, ChangeHistoryModel.editLimit)
        XCTAssertEqual(model.editsSinceSave.first?.timestamp,
                       date(total - ChangeHistoryModel.editLimit))
        XCTAssertEqual(model.editsSinceSave.last?.timestamp, date(total - 1))

        model.markSaved()
        XCTAssertEqual(model.changesSinceSaveCount, 0)
        XCTAssertTrue(model.editsSinceSave.isEmpty)

        model.record(edit: ChangeHistoryEdit(timestamp: date(total + 1)))
        XCTAssertEqual(model.editsSinceSave.map(\.timestamp), [date(total + 1)],
                       "the ring restarts cleanly after a save")
    }
}
