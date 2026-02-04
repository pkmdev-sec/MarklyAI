import XCTest
@testable import Arcmark

final class ModelTests: XCTestCase {
    private func makeStore() -> DataStore {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return DataStore(baseDirectory: temp)
    }

    func testJSONRoundTrip() throws {
        let link = Link(id: UUID(), title: "Example", url: "https://example.com", faviconPath: nil)
        let folder = Folder(id: UUID(), name: "Folder", children: [.link(link)], isExpanded: true)
        let workspace = Workspace(id: UUID(), name: "Inbox", colorId: .ember, items: [.folder(folder)])
        let state = AppState(schemaVersion: 1, workspaces: [workspace], selectedWorkspaceId: workspace.id)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AppState.self, from: data)
        XCTAssertEqual(state, decoded)
    }

    func testMoveNodeReorderAndNest() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        model.addFolder(name: "Folder", parentId: nil)
        model.addLink(urlString: "https://a.com", title: "A", parentId: nil)
        model.addLink(urlString: "https://b.com", title: "B", parentId: nil)

        guard
            let folderId = model.currentWorkspace.items.compactMap({
                if case .folder(let folder) = $0 { return folder.id }
                return nil
            }).first,
            let linkAId = model.currentWorkspace.items.compactMap({
                if case .link(let link) = $0, link.title == "A" { return link.id }
                return nil
            }).first
        else {
            XCTFail("Expected nodes to exist")
            return
        }

        model.moveNode(id: linkAId, toParentId: folderId, index: 0)
        let location = model.location(of: linkAId)
        XCTAssertEqual(location?.parentId, folderId)

        if let folderNode = model.nodeById(folderId), case .folder(let folder) = folderNode {
            XCTAssertEqual(folder.children.count, 1)
        } else {
            XCTFail("Expected folder to contain moved link")
        }

        if let linkBId = model.currentWorkspace.items.compactMap({
            if case .link(let link) = $0, link.title == "B" { return link.id }
            return nil
        }).first {
            model.moveNode(id: linkBId, toParentId: nil, index: 0)
            let locationB = model.location(of: linkBId)
            XCTAssertEqual(locationB?.parentId, nil)
            XCTAssertEqual(locationB?.index, 0)
        }
    }

    func testWorkspaceScopedFiltering() {
        let link1 = Link(id: UUID(), title: "Docs", url: "https://docs.com", faviconPath: nil)
        let link2 = Link(id: UUID(), title: "Blog", url: "https://blog.com", faviconPath: nil)
        let folder = Folder(id: UUID(), name: "Reading", children: [.link(link2)], isExpanded: false)
        let nodes: [Node] = [.link(link1), .folder(folder)]

        let results = NodeFiltering.filter(nodes: nodes, query: "blog")
        XCTAssertEqual(results.count, 1)
        if case .folder(let filteredFolder) = results[0] {
            XCTAssertEqual(filteredFolder.children.count, 1)
        } else {
            XCTFail("Expected folder to remain for matching child")
        }
    }
}
