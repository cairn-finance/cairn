import Foundation
import SwiftData

/// Why a category change was refused.
public enum CategoryManagementError: Error, LocalizedError, Equatable {
    case emptyName
    case notFound
    case systemCategory
    case duplicateName
    case referenced(transactionCount: Int, ruleCount: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Give the category a name."
        case .notFound:
            return "That category no longer exists."
        case .systemCategory:
            return "Built-in categories can’t be renamed or removed."
        case .duplicateName:
            return "That name is already used by another category."
        case let .referenced(transactionCount, ruleCount):
            var parts: [String] = []
            if transactionCount > 0 {
                parts.append("\(transactionCount) transaction\(transactionCount == 1 ? "" : "s")")
            }
            if ruleCount > 0 {
                parts.append("\(ruleCount) rule\(ruleCount == 1 ? "" : "s")")
            }
            let list = parts.isEmpty ? "records" : parts.joined(separator: " and ")
            return "\(list) still use this category, so it wasn’t deleted."
        }
    }
}

/// What still points at one category.
public struct CategoryDeletionImpact: Sendable, Equatable {
    public let transactionCount: Int
    public let ruleCount: Int

    public init(transactionCount: Int, ruleCount: Int) {
        self.transactionCount = transactionCount
        self.ruleCount = ruleCount
    }

    public var isReferenced: Bool { transactionCount > 0 || ruleCount > 0 }
}

/// Which way a category moves in the visible list.
public enum CategoryMoveDirection: Sendable, Equatable {
    case up
    case down
}

public extension SyncEngine {
    /// Adds a category at the end of the ordering. Returns its stable id.
    @discardableResult
    func createCategory(
        name: String,
        symbolName: String,
        colorHex: String
    ) throws -> UUID {
        guard let trimmed = CategoryManagement.normalizedName(name) else {
            throw CategoryManagementError.emptyName
        }
        let existing = try modelContext.fetch(FetchDescriptor<Category>())
        guard !nameIsTaken(trimmed, among: existing, excluding: nil) else {
            throw CategoryManagementError.duplicateName
        }
        let nextOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        let category = Category(
            name: trimmed,
            symbolName: symbolName,
            colorHex: colorHex,
            sortOrder: nextOrder
        )
        modelContext.insert(category)
        try modelContext.save()
        return category.uuid
    }

    /// Renames and recolors a category. System categories keep their name and
    /// symbol but can still be recolored.
    func updateCategory(
        id: UUID,
        name: String,
        symbolName: String,
        colorHex: String
    ) throws {
        guard let trimmed = CategoryManagement.normalizedName(name) else {
            throw CategoryManagementError.emptyName
        }
        let category = try categoryForManagement(id: id)
        let existing = try modelContext.fetch(FetchDescriptor<Category>())
        // Keeping its own name is always allowed (a recolor, or a no-op rename),
        // even for a legacy built-in that hasn't been flagged system yet.
        if !CategoryManagement.namesCollide(trimmed, category.name),
           nameIsTaken(trimmed, among: existing, excluding: category.uuid) {
            throw CategoryManagementError.duplicateName
        }
        if category.isSystem {
            guard trimmed == category.name, symbolName == category.symbolName else {
                throw CategoryManagementError.systemCategory
            }
        } else {
            category.name = trimmed
            category.symbolName = symbolName
        }
        category.colorHex = colorHex
        try modelContext.save()
    }

    /// Hides or restores a category. System categories can never be archived.
    func setCategoryArchived(id: UUID, archived: Bool) throws {
        let category = try categoryForManagement(id: id)
        if archived, category.isSystem {
            throw CategoryManagementError.systemCategory
        }
        guard category.isArchived != archived else { return }
        category.isArchived = archived
        try modelContext.save()
    }

    /// Moves a category one step among the visible (non-archived) categories and
    /// rewrites the whole ordering, so `sortOrder` stays dense and stable.
    func moveCategory(id: UUID, direction: CategoryMoveDirection) throws {
        let ordered = try modelContext.fetch(FetchDescriptor<Category>())
            .sorted(by: Self.categoryOrder)
        let active = ordered.filter { !$0.isArchived }
        guard let position = active.firstIndex(where: { $0.uuid == id }) else {
            throw CategoryManagementError.notFound
        }
        let targetPosition = direction == .up ? position - 1 : position + 1
        guard active.indices.contains(targetPosition) else { return }
        let neighborID = active[targetPosition].uuid

        var reordered = ordered
        guard let source = reordered.firstIndex(where: { $0.uuid == id }),
              let destination = reordered.firstIndex(where: { $0.uuid == neighborID }) else {
            throw CategoryManagementError.notFound
        }
        reordered.swapAt(source, destination)
        for (index, category) in reordered.enumerated() {
            category.sortOrder = index
        }
        try modelContext.save()
    }

    /// What still points at a category. The caller can use this to explain why a
    /// removal would become an archive.
    func categoryDeletionImpact(id: UUID) throws -> CategoryDeletionImpact {
        let category = try categoryForManagement(id: id)
        return CategoryDeletionImpact(
            transactionCount: (category.userTransactions?.count ?? 0)
                + (category.autoTransactions?.count ?? 0),
            ruleCount: category.rules?.count ?? 0
        )
    }

    /// Deletes a category only when nothing references it. A referenced category
    /// is refused so the caller can offer Archive instead; a system category is
    /// always refused.
    func deleteCategory(id: UUID) throws {
        let category = try categoryForManagement(id: id)
        let impact = CategoryDeletionImpact(
            transactionCount: (category.userTransactions?.count ?? 0)
                + (category.autoTransactions?.count ?? 0),
            ruleCount: category.rules?.count ?? 0
        )
        switch CategoryManagement.deletionDecision(
            isSystem: category.isSystem,
            transactionCount: impact.transactionCount,
            ruleCount: impact.ruleCount
        ) {
        case .delete:
            modelContext.delete(category)
            try modelContext.save()
        case .archive:
            throw CategoryManagementError.referenced(
                transactionCount: impact.transactionCount,
                ruleCount: impact.ruleCount
            )
        case .forbidden:
            throw CategoryManagementError.systemCategory
        }
    }

    /// Deterministic order used everywhere categories are listed or moved.
    static func categoryOrder(_ lhs: Category, _ rhs: Category) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.uuid.uuidString < rhs.uuid.uuidString
    }

    private func categoryForManagement(id: UUID) throws -> Category {
        let descriptor = FetchDescriptor<Category>(predicate: #Predicate { $0.uuid == id })
        guard let category = try modelContext.fetch(descriptor).first else {
            throw CategoryManagementError.notFound
        }
        return category
    }

    /// Whether a proposed name collides with a built-in name or a stored
    /// category, ignoring case and excluding the row being edited.
    private func nameIsTaken(
        _ name: String,
        among existing: [Category],
        excluding uuid: UUID?
    ) -> Bool {
        if CategoryManagement.isSystemCategoryName(name) { return true }
        return existing.contains {
            $0.uuid != uuid && CategoryManagement.namesCollide($0.name, name)
        }
    }
}
