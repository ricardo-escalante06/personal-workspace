import Foundation
import GRDB
import Testing
@testable import WorkspaceKit

private let owner = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!

private struct Device {
    let store: WorkspaceStore
    let engine: SyncEngine
    init(_ remote: InMemorySyncRemote) throws {
        store = try WorkspaceStore.inMemory()
        engine = SyncEngine(database: store.db, remote: remote, pageSize: 7)
    }
    func sync() async throws -> SyncReport { try await engine.sync(ownerId: owner) }
}

@Suite struct SyncTests {
    @Test func secondDeviceReceivesEverything() async throws {
        let remote = InMemorySyncRemote()
        let mac = try Device(remote), phone = try Device(remote)
        let h = try SampleData.install(into: mac.store)

        let first = try await mac.sync()
        #expect(first.pushed > 0)
        #expect(try mac.store.pendingChangeCount() == 0)
        // Owner is filled in on push and written back locally.
        let pushed = try await mac.store.db.read { try Container.fetchOne($0, id: h.school) }
        #expect(pushed?.ownerId == owner)

        // pageSize 7 forces multi-page pulls.
        try await phone.sync()
        #expect(try phone.store.containers().count == mac.store.containers().count)
        #expect(try phone.store.tasks(inScope: h.cs61b).count == mac.store.tasks(inScope: h.cs61b).count)
        let phoneBlocks = try await phone.store.db.read { try ScheduleBlock.live().fetchCount($0) }
        #expect(phoneBlocks == 3)
    }

    @Test func completionPropagatesBothWays() async throws {
        let remote = InMemorySyncRemote()
        let mac = try Device(remote), phone = try Device(remote)
        let h = try SampleData.install(into: mac.store)
        try await mac.sync(); try await phone.sync()

        try phone.store.setStatus(h.hw9, .done)
        try await phone.sync()
        try await mac.sync()
        let hw9 = try await mac.store.db.read { try TaskItem.fetchOne($0, id: h.hw9) }
        #expect(hw9?.status == .done)
        #expect(hw9?.completedAt != nil)

        try mac.store.setStatus(h.hw9, .notStarted)
        try await mac.sync(); try await phone.sync()
        let back = try await phone.store.db.read { try TaskItem.fetchOne($0, id: h.hw9) }
        #expect(back?.status == .notStarted)
        #expect(back?.completedAt == nil)
    }

    @Test func deletionsSyncAsTombstones() async throws {
        let remote = InMemorySyncRemote()
        let mac = try Device(remote), phone = try Device(remote)
        let h = try SampleData.install(into: mac.store)
        try await mac.sync(); try await phone.sync()

        try mac.store.deleteContainer(h.clubs)
        try await mac.sync(); try await phone.sync()
        #expect(try !phone.store.containers().contains { $0.id == h.robotics })
        #expect(try phone.store.tasks(inScope: nil).allSatisfy { $0.title != "CAD drivetrain" })
    }

    @Test func unpushedLocalEditIsNotOverwrittenByPull() async throws {
        let remote = InMemorySyncRemote()
        let mac = try Device(remote), phone = try Device(remote)
        let h = try SampleData.install(into: mac.store)
        try await mac.sync(); try await phone.sync()

        // Mac renames and syncs; phone (offline) renames the same task.
        try mac.store.update(TaskItem.self, h.hw9) { $0.title = "HW 9 (mac)" }
        try await mac.sync()
        try phone.store.update(TaskItem.self, h.hw9) { $0.title = "HW 9 (phone)" }

        // Phone pulls only: its pending edit must survive.
        _ = try await phone.engine.pull()
        let local = try await phone.store.db.read { try TaskItem.fetchOne($0, id: h.hw9) }
        #expect(local?.title == "HW 9 (phone)")

        // Full sync: phone's later write wins everywhere.
        try await phone.sync(); try await mac.sync()
        let onMac = try await mac.store.db.read { try TaskItem.fetchOne($0, id: h.hw9) }
        #expect(onMac?.title == "HW 9 (phone)")
    }

    @Test func failedPushKeepsChangesQueued() async throws {
        let remote = InMemorySyncRemote()
        let mac = try Device(remote)
        try SampleData.install(into: mac.store)
        let pending = try mac.store.pendingChangeCount()
        await remote.setFailNextPush(true)
        await #expect(throws: URLError.self) { try await mac.sync() }
        #expect(try mac.store.pendingChangeCount() == pending)
        try await mac.sync()
        #expect(try mac.store.pendingChangeCount() == 0)
    }

    @Test func pushSendsExplicitNulls() async throws {
        let remote = InMemorySyncRemote()
        let mac = try Device(remote)
        let list = try mac.store.createContainer(name: "L", kind: .list)
        let t = try mac.store.createTask(TaskItem(containerId: list.id, title: "T", dueDate: LocalDate(year: 2026, month: 1, day: 1)))
        try await mac.sync()
        try mac.store.update(TaskItem.self, t.id) { $0.dueDate = nil }
        try await mac.sync()
        let json = try #require(await remote.rowJSON("tasks", t.id))
        let row = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(row["due_date"] is NSNull)
        #expect(row.keys.count == TaskItem.remoteColumns.count)
    }

    @Test func pushOrdersParentsFirst() async throws {
        let remote = InMemorySyncRemote()
        let mac = try Device(remote)
        try SampleData.install(into: mac.store)
        let rows: [Container] = try await mac.store.db.read { db in
            let ids = try UUID.fetchAll(db, sql: "SELECT row_id FROM sync_outbox WHERE table_name = 'containers'")
            let data = try #require(try SyncTable.all.first { $0.name == "containers" }!.encodePending(db, ids, owner))
            return try SyncCoding.decodeRows(Container.self, from: data)
        }
        #expect(rows.map(\.depth) == rows.map(\.depth).sorted())
    }
}
