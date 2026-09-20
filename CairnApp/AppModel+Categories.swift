import Foundation
import CairnCore

/// Category management, funneled through the store-writing engine so the same
/// validation and ordering rules apply no matter which screen asks.
extension AppModel {
    @discardableResult
    func createCategory(name: String, symbolName: String, colorHex: String) async -> Bool {
        do {
            try await engine.createCategory(name: name, symbolName: symbolName, colorHex: colorHex)
            return true
        } catch {
            banner = categoryErrorMessage(error)
            return false
        }
    }

    @discardableResult
    func updateCategory(id: UUID, name: String, symbolName: String, colorHex: String) async -> Bool {
        do {
            try await engine.updateCategory(
                id: id,
                name: name,
                symbolName: symbolName,
                colorHex: colorHex
            )
            return true
        } catch {
            banner = categoryErrorMessage(error)
            return false
        }
    }

    func setCategoryArchived(id: UUID, archived: Bool) async {
        do {
            try await engine.setCategoryArchived(id: id, archived: archived)
        } catch {
            banner = categoryErrorMessage(error)
        }
    }

    func moveCategory(id: UUID, direction: CategoryMoveDirection) async {
        do {
            try await engine.moveCategory(id: id, direction: direction)
        } catch {
            banner = categoryErrorMessage(error)
        }
    }

    /// Deletes a category only when nothing references it. When it is referenced
    /// the engine refuses and the message explains that it was kept.
    @discardableResult
    func deleteCategory(id: UUID) async -> Bool {
        do {
            try await engine.deleteCategory(id: id)
            return true
        } catch {
            banner = categoryErrorMessage(error)
            return false
        }
    }

    private func categoryErrorMessage(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
