import Foundation
import GRDB

/// The example workspace from DESIGN.md §2 and §12, placed in the week containing
/// `referenceDate`. Used by tests, previews and the app's "Load sample data" command.
public enum SampleData {
    public struct Handles: Sendable {
        public var personal, personalGeneral, errands, apartmentMove: UUID
        public var school, cs61a, cs61b, project3, ee66: UUID
        public var clubs, robotics, roboticsGeneral, competitionBot, hei: UUID
        public var hw9, quiz4, studyQuiz4, lab5, groceries: UUID
        public var categories: [String: UUID]
    }

    @discardableResult
    public static func install(
        into store: WorkspaceStore,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) throws -> Handles {
        try store.db.write { db in
            try install(in: db, referenceDate: referenceDate, calendar: calendar)
        }
    }

    static func install(in db: Database, referenceDate: Date, calendar: Calendar) throws -> Handles {
        let tz = calendar.timeZone
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: referenceDate)!.start
        func day(_ offset: Int) -> LocalDate {
            LocalDate(calendar.date(byAdding: .day, value: offset, to: weekStart)!, in: tz)
        }
        func at(_ offset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            day(offset).startOfDay(in: tz).addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
        }
        // Week offsets: 0 = Sunday … 6 = Saturday (Calendar's week start).
        let mon = 1, tue = 2, wed = 3, thu = 4, fri = 5

        // Categories
        var categories: [String: UUID] = [:]
        for (name, symbol, global) in TaskCategory.builtIns {
            if let existing = try TaskCategory.live().filter(Column("name") == name).fetchOne(db) {
                categories[name] = existing.id
                continue
            }
            var c = TaskCategory(name: name, symbol: symbol, isGlobal: global)
            try WorkspaceStore.save(&c, in: db)
            categories[name] = c.id
        }

        func make(_ name: String, _ kind: ContainerKind, _ parent: UUID?, _ color: String = "grey") throws -> UUID {
            try WorkspaceStore.createContainer(name: name, kind: kind, parentId: parent, color: color, in: db).id
        }
        func setDefaultList(_ folder: UUID, _ list: UUID) throws {
            guard var f = try Container.fetchOne(db, id: folder) else { return }
            f.defaultListId = list
            try WorkspaceStore.save(&f, in: db)
        }
        func classTerm(_ container: UUID, code: String, pattern: String) throws {
            var t = ClassTerm(
                containerId: container,
                termStart: day(-70), termEnd: day(35),
                skipRanges: .array([.object([
                    "start": .string(day(17).description),
                    "end": .string(day(21).description),
                    "label": .string("Thanksgiving"),
                ])]),
                courseCode: code, eventTitlePattern: pattern
            )
            try WorkspaceStore.save(&t, in: db)
        }
        func project(_ container: UUID) throws -> [TaskStatus: UUID] {
            var meta = ProjectMeta(containerId: container)
            try WorkspaceStore.save(&meta, in: db)
            var firstColumn: [TaskStatus: UUID] = [:]
            let ranks = Rank.sequence(count: BoardColumn.defaultColumns.count)
            for ((name, status), rank) in zip(BoardColumn.defaultColumns, ranks) {
                var col = BoardColumn(containerId: container, name: name, mapsToStatus: status, sortRank: rank)
                try WorkspaceStore.save(&col, in: db)
                if firstColumn[status] == nil { firstColumn[status] = col.id }
            }
            return firstColumn
        }
        func task(_ title: String, in container: UUID?, category: String? = nil,
                  due: LocalDate? = nil, dueTime: LocalTime? = nil,
                  status: TaskStatus = .notStarted, column: UUID? = nil, parent: UUID? = nil) throws -> UUID {
            try WorkspaceStore.createTask(TaskItem(
                containerId: container, parentTaskId: parent, title: title,
                categoryId: category.flatMap { categories[$0] }, status: status,
                dueDate: due, dueTime: dueTime, dueTz: dueTime == nil ? nil : tz.identifier,
                boardColumnId: column
            ), in: db).id
        }
        func block(_ task: UUID, _ start: Date, _ end: Date) throws {
            var b = ScheduleBlock(taskId: task, startsAt: start, endsAt: end)
            try WorkspaceStore.save(&b, in: db)
        }

        // Personal
        let personal = try make("Personal", .folder, nil, "plum")
        let personalGeneral = try make("General", .list, personal, "plum")
        let errands = try make("Errands", .list, personal, "plum")
        let apartmentMove = try make("Apartment Move", .project, personal, "gold")
        try setDefaultList(personal, personalGeneral)
        let moveCols = try project(apartmentMove)

        // School
        let school = try make("School", .folder, nil, "green")
        let cs61a = try make("CS61A", .class, school, "rust")
        let cs61b = try make("CS61B", .class, school, "steel")
        let project3 = try make("Project 3", .project, cs61b, "steel")
        let ee66 = try make("EE66", .class, school, "green")
        try classTerm(cs61a, code: "CS61A", pattern: "COMPSCI 61A")
        try classTerm(cs61b, code: "CS61B", pattern: "COMPSCI 61B")
        try classTerm(ee66, code: "EE66", pattern: "ELENG 66")
        let p3Cols = try project(project3)

        // Clubs
        let clubs = try make("Clubs", .folder, nil, "violet")
        let robotics = try make("Robotics", .folder, clubs, "violet")
        let roboticsGeneral = try make("General", .list, robotics, "violet")
        let competitionBot = try make("Competition Bot", .project, robotics, "rose")
        let hei = try make("HEI", .list, clubs, "steel")
        try setDefaultList(robotics, roboticsGeneral)
        let botCols = try project(competitionBot)

        // §12 example 2: due vs scheduled
        let hw9 = try task("HW 9", in: cs61b, category: "Homework", due: day(fri))
        let quiz4 = try task("Quiz 4", in: cs61b, category: "Quiz", due: day(thu), dueTime: LocalTime(hour: 14, minute: 0))
        let studyQuiz4 = try task("Study for Quiz 4", in: cs61b, category: "Study")
        try block(studyQuiz4, at(tue, 19), at(tue, 20))

        // §12 example 3: one lab, two work blocks, one deadline
        let lab5 = try task("Lab 5", in: ee66, category: "Lab", due: day(fri))
        try block(lab5, at(mon, 15), at(mon, 17))
        try block(lab5, at(wed, 16), at(wed, 18))

        _ = try task("Lecture 10 reading", in: cs61a, category: "Reading", due: day(mon))
        _ = try task("HW 7", in: cs61a, category: "Homework", due: day(wed), dueTime: LocalTime(hour: 23, minute: 59))

        // Project boards
        let ckpt = try task("Checkpoint", in: project3, category: "Milestone", due: day(mon + 7), column: p3Cols[.notStarted])
        _ = try task("Write tests", in: project3, column: p3Cols[.inProgress], parent: nil)
        _ = try task("Read spec", in: project3, status: .done, column: p3Cols[.done])
        _ = try task("Draft design doc", in: project3, column: p3Cols[.notStarted], parent: ckpt)

        _ = try task("CAD drivetrain", in: competitionBot, status: .inProgress, column: botCols[.inProgress])
        _ = try task("Order motors", in: competitionBot, due: day(thu), column: botCols[.notStarted])
        _ = try task("Pick team name", in: competitionBot, status: .done, column: botCols[.done])

        _ = try task("Book movers", in: apartmentMove, due: day(fri + 7), column: moveCols[.notStarted])

        // Personal + clubs
        let groceries = try task("Buy groceries", in: personalGeneral, due: LocalDate(referenceDate, in: tz))
        _ = try task("Return package", in: errands, due: day(tue))
        _ = try task("Post meeting notes", in: hei, due: day(mon))
        _ = try task("Inbox: look into summer internships", in: nil)

        return Handles(
            personal: personal, personalGeneral: personalGeneral, errands: errands, apartmentMove: apartmentMove,
            school: school, cs61a: cs61a, cs61b: cs61b, project3: project3, ee66: ee66,
            clubs: clubs, robotics: robotics, roboticsGeneral: roboticsGeneral, competitionBot: competitionBot, hei: hei,
            hw9: hw9, quiz4: quiz4, studyQuiz4: studyQuiz4, lab5: lab5, groceries: groceries,
            categories: categories
        )
    }
}
