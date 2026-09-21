import Foundation
import SwiftData
import Testing
@testable import CairnCore

@Suite("Category management")
@MainActor
struct CategoryManagementTests {
    private func makeEngine() throws -> (container: ModelContainer, engine: SyncEngine) {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        return (result.container, SyncEngine(modelContainer: result.container))
    }

    @discardableResult
    private func insertCategory(
        _ context: ModelContext,
        name: String,
        sortOrder: Int,
        isSystem: Bool = false,
        archived: Bool = false
    ) -> CairnSchemaV1.Category {
        let category = CairnSchemaV1.Category(
            name: name,
            symbolName: "tag.fill",
            colorHex: "#8E8E93",
            sortOrder: sortOrder,
            isSystem: isSystem
        )
        category.isArchived = archived
        context.insert(category)
        return category
    }

    /// Reads back through a fresh context, since the engine writes on its own.
    private func refetch(_ id: UUID, in container: ModelContainer) throws -> CairnSchemaV1.Category {
        let stored = try ModelContext(container).fetch(FetchDescriptor<CairnSchemaV1.Category>())
        return try #require(stored.first { $0.uuid == id })
    }

    private func ordered(_ container: ModelContainer) throws -> [CairnSchemaV1.Category] {
        try ModelContext(container).fetch(FetchDescriptor<CairnSchemaV1.Category>())
            .sorted(by: SyncEngine.categoryOrder)
    }

    @Test("A new category is trimmed and appended to the ordering")
    func createAppends() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        insertCategory(context, name: "Groceries", sortOrder: 0)
        insertCategory(context, name: "Dining", sortOrder: 1)
        try context.save()

        let id = try await engine.createCategory(
            name: "  Coffee  ",
            symbolName: "cup.and.saucer.fill",
            colorHex: "#FF9500"
        )

        let created = try refetch(id, in: container)
        #expect(created.name == "Coffee")
        #expect(created.sortOrder == 2)
        #expect(!created.isSystem)
        #expect(!created.isArchived)
    }

    @Test("A blank name is refused")
    func createRejectsBlankName() async throws {
        let (_, engine) = try makeEngine()
        await #expect(throws: CategoryManagementError.emptyName) {
            try await engine.createCategory(name: "   ", symbolName: "tag.fill", colorHex: "#8E8E93")
        }
    }

    @Test("A name that duplicates a category or a built-in is refused")
    func duplicateNamesRefused() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        insertCategory(context, name: "Coffee", sortOrder: 0)
        let dining = insertCategory(context, name: "Dining", sortOrder: 1)
        try context.save()

        await #expect(throws: CategoryManagementError.duplicateName) {
            try await engine.createCategory(name: " coffee ", symbolName: "tag.fill", colorHex: "#FF9500")
        }
        await #expect(throws: CategoryManagementError.duplicateName) {
            try await engine.createCategory(name: "Fees", symbolName: "tag.fill", colorHex: "#FF9500")
        }
        await #expect(throws: CategoryManagementError.duplicateName) {
            try await engine.updateCategory(
                id: dining.uuid,
                name: "COFFEE",
                symbolName: "fork.knife",
                colorHex: "#FF2D55"
            )
        }
        // The name is unchanged when the rename was refused.
        #expect(try refetch(dining.uuid, in: container).name == "Dining")
    }

    @Test("Seeding marks every built-in category as system")
    func seedsSystemCategories() async throws {
        let (container, engine) = try makeEngine()
        try await engine.seedDefaultCategoriesIfNeeded()

        let all = try ModelContext(container).fetch(FetchDescriptor<CairnSchemaV1.Category>())
        for name in CategoryManagement.systemCategoryNames {
            let category = try #require(all.first { $0.name == name })
            #expect(category.isSystem)
        }
    }

    @Test("Deduplication backfills the system flag on legacy built-ins")
    func dedupBackfillsSystemFlag() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        insertCategory(context, name: "Fees", sortOrder: 0)
        insertCategory(context, name: "Income", sortOrder: 1)
        try context.save()

        _ = try await engine.deduplicateCategories()

        let all = try ModelContext(container).fetch(FetchDescriptor<CairnSchemaV1.Category>())
        #expect(all.first { $0.name == "Fees" }?.isSystem == true)
        #expect(all.first { $0.name == "Income" }?.isSystem == true)
    }

    @Test("A non-system category can be renamed and recolored")
    func renameAndRecolor() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let category = insertCategory(context, name: "Dining", sortOrder: 0)
        try context.save()

        try await engine.updateCategory(
            id: category.uuid,
            name: "  Restaurants ",
            symbolName: "fork.knife",
            colorHex: "#FF2D55"
        )

        let updated = try refetch(category.uuid, in: container)
        #expect(updated.name == "Restaurants")
        #expect(updated.symbolName == "fork.knife")
        #expect(updated.colorHex == "#FF2D55")
    }

    @Test("A system category keeps its name and symbol but can be recolored")
    func systemCategoryProtected() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let category = insertCategory(context, name: "Transfers", sortOrder: 0, isSystem: true)
        try context.save()

        await #expect(throws: CategoryManagementError.systemCategory) {
            try await engine.updateCategory(
                id: category.uuid,
                name: "Moved",
                symbolName: "arrow.left.arrow.right",
                colorHex: "#32ADE6"
            )
        }

        try await engine.updateCategory(
            id: category.uuid,
            name: "Transfers",
            symbolName: "tag.fill",
            colorHex: "#32ADE6"
        )
        let updated = try refetch(category.uuid, in: container)
        #expect(updated.name == "Transfers")
        #expect(updated.colorHex == "#32ADE6")
    }

    @Test("A system category cannot be archived, a non-system one can")
    func archiving() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let system = insertCategory(context, name: "Transfers", sortOrder: 0, isSystem: true)
        let custom = insertCategory(context, name: "Coffee", sortOrder: 1)
        try context.save()

        await #expect(throws: CategoryManagementError.systemCategory) {
            try await engine.setCategoryArchived(id: system.uuid, archived: true)
        }
        #expect(try !refetch(system.uuid, in: container).isArchived)

        try await engine.setCategoryArchived(id: custom.uuid, archived: true)
        #expect(try refetch(custom.uuid, in: container).isArchived)

        try await engine.setCategoryArchived(id: custom.uuid, archived: false)
        #expect(try !refetch(custom.uuid, in: container).isArchived)
    }

    @Test("Moving a category swaps it with its visible neighbour")
    func moveReorders() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        insertCategory(context, name: "Groceries", sortOrder: 0)
        insertCategory(context, name: "Dining", sortOrder: 1)
        let third = insertCategory(context, name: "Transport", sortOrder: 2)
        try context.save()

        try await engine.moveCategory(id: third.uuid, direction: .up)

        let names = try ordered(container).map(\.name)
        #expect(names == ["Groceries", "Transport", "Dining"])
        #expect(try ordered(container).map(\.sortOrder) == [0, 1, 2])
    }

    @Test("Archived categories are skipped when moving")
    func moveSkipsArchived() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let first = insertCategory(context, name: "Groceries", sortOrder: 0)
        insertCategory(context, name: "Old", sortOrder: 1, archived: true)
        let visible = insertCategory(context, name: "Dining", sortOrder: 2)
        try context.save()

        try await engine.moveCategory(id: visible.uuid, direction: .up)

        let refreshedFirst = try refetch(first.uuid, in: container)
        let refreshedVisible = try refetch(visible.uuid, in: container)
        #expect(refreshedVisible.sortOrder == 0)
        #expect(refreshedFirst.sortOrder > refreshedVisible.sortOrder)
    }

    @Test("Moving past the end of the list changes nothing")
    func moveAtBoundaryIsNoOp() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let only = insertCategory(context, name: "Groceries", sortOrder: 0)
        try context.save()

        try await engine.moveCategory(id: only.uuid, direction: .up)
        try await engine.moveCategory(id: only.uuid, direction: .down)

        #expect(try refetch(only.uuid, in: container).sortOrder == 0)
    }

    @Test("Deletion impact counts transactions and rules")
    func deletionImpact() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let category = insertCategory(context, name: "Dining", sortOrder: 0)
        let other = insertCategory(context, name: "Other", sortOrder: 1)
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)
        let userTransaction = LedgerTransaction(
            bankTransactionID: "T1",
            payeeDescription: "Coffee",
            amountMinorUnits: -500
        )
        userTransaction.userCategory = category
        context.insert(userTransaction)
        let autoTransaction = LedgerTransaction(
            bankTransactionID: "T2",
            payeeDescription: "Lunch",
            amountMinorUnits: -900
        )
        autoTransaction.autoCategory = category
        context.insert(autoTransaction)
        let rule = CategorizationRule(
            name: "Coffee",
            field: .payee,
            matchKind: .contains,
            pattern: "coffee",
            assignedCategory: category
        )
        context.insert(rule)
        context.insert(CategorizationRule(
            name: "Other",
            field: .payee,
            matchKind: .contains,
            pattern: "other",
            assignedCategory: other
        ))
        try context.save()

        let impact = try await engine.categoryDeletionImpact(id: category.uuid)
        #expect(impact.transactionCount == 2)
        #expect(impact.ruleCount == 1)
        #expect(impact.isReferenced)
    }

    @Test("An unused category can be deleted")
    func deleteUnused() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let category = insertCategory(context, name: "Coffee", sortOrder: 0)
        try context.save()

        try await engine.deleteCategory(id: category.uuid)

        #expect(try ModelContext(container).fetch(FetchDescriptor<CairnSchemaV1.Category>()).isEmpty)
    }

    @Test("A referenced category is refused rather than orphaned")
    func deleteReferencedIsRefused() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let category = insertCategory(context, name: "Dining", sortOrder: 0)
        let account = Account(bankAccountID: "A1", name: "Checking", currency: .usd)
        context.insert(account)
        let transaction = LedgerTransaction(
            bankTransactionID: "T1",
            payeeDescription: "Coffee",
            amountMinorUnits: -500
        )
        transaction.userCategory = category
        context.insert(transaction)
        try context.save()

        await #expect(throws: CategoryManagementError.referenced(transactionCount: 1, ruleCount: 0)) {
            try await engine.deleteCategory(id: category.uuid)
        }
        let stored = try ModelContext(container).fetch(FetchDescriptor<CairnSchemaV1.Category>())
        #expect(stored.count == 1)
        #expect(transaction.userCategory?.uuid == category.uuid)
    }

    @Test("A system category can never be deleted")
    func deleteSystemIsRefused() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let category = insertCategory(context, name: "Uncategorized", sortOrder: 0, isSystem: true)
        try context.save()

        await #expect(throws: CategoryManagementError.systemCategory) {
            try await engine.deleteCategory(id: category.uuid)
        }
        #expect(try ModelContext(container).fetch(FetchDescriptor<CairnSchemaV1.Category>()).count == 1)
    }
}
