import Foundation

/// Service for AI-powered bookmark organization using the Anthropic Claude API
@MainActor
final class AIOrganizationService {
    static let shared = AIOrganizationService()

    private let session: URLSession
    private let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model = "claude-sonnet-4-6"

    /// A decision made by the AI on how to organize a bookmark
    struct OrganizationDecision {
        enum Action: String {
            case place           // Place in existing workspace/folder
            case createFolder    // Create new folder, then place
            case createWorkspace // Create new workspace, then place
        }

        let action: Action
        let workspaceId: UUID?
        let folderId: UUID?
        let newWorkspaceName: String?
        let newFolderName: String?
        let reasoning: String
    }

    /// Error type for AI operations
    enum AIError: Error, CustomStringConvertible {
        case noAPIKey
        case networkError(Error)
        case httpError(Int, String?)
        case invalidResponse

        var description: String {
            switch self {
            case .noAPIKey:
                return "No API key found. Please enter your Anthropic API key in settings."
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .httpError(let code, let body):
                if let body = body, !body.isEmpty {
                    // Truncate long error messages
                    let truncated = body.prefix(200)
                    return "API error (\(code)): \(truncated)\(body.count > 200 ? "..." : "")"
                }
                return "API error: HTTP \(code)"
            case .invalidResponse:
                return "Invalid response from AI service"
            }
        }
    }

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30  // Increased from 10 to 30 seconds
        session = URLSession(configuration: config)
    }

    /// Check if AI organization is available (API key exists and feature enabled)
    var isAvailable: Bool {
        KeychainService.getAPIKey() != nil && UserDefaults.standard.bool(forKey: "aiOrganizationEnabled")
    }

    /// Test the API key by making a minimal request
    /// - Returns: `Result<Void, AIError>` with success or detailed error
    func testConnection() async -> Result<Void, AIError> {
        print("[AI] Testing connection...")
        
        guard let apiKey = KeychainService.getAPIKey() else {
            print("[AI] No API key found")
            return .failure(.noAPIKey)
        }

        print("[AI] API key found: \(String(apiKey.prefix(15)))...")

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 10,
            "messages": [["role": "user", "content": "ping"]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        print("[AI] Sending test request to \(apiURL)")

        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("[AI] Invalid response type")
                return .failure(.invalidResponse)
            }

            print("[AI] Received response: HTTP \(httpResponse.statusCode)")

            if httpResponse.statusCode == 200 {
                print("[AI] Connection successful")
                return .success(())
            } else {
                let bodyString = String(data: data, encoding: .utf8)
                print("[AI] HTTP error \(httpResponse.statusCode): \(bodyString ?? "no body")")
                return .failure(.httpError(httpResponse.statusCode, bodyString))
            }
        } catch {
            print("[AI] Network error: \(error)")
            return .failure(.networkError(error))
        }
    }

    /// Ask Claude to organize a bookmark
    /// - Parameters:
    ///   - url: The URL of the bookmark to organize
    ///   - title: The title/name of the bookmark
    ///   - workspaces: The current workspace structure for context
    /// - Returns: An `OrganizationDecision` if successful, `nil` if the API call failed
    func organize(url: String, title: String, workspaces: [Workspace], excludeLinkId: UUID? = nil) async -> OrganizationDecision? {
        print("[AI] Organizing: \(title) -> \(url)")

        guard let apiKey = KeychainService.getAPIKey() else {
            print("[AI] No API key found")
            return nil
        }

        // Build workspace structure, excluding the link being organized
        // (it was temporarily placed in current workspace for instant feedback)
        let structure = buildWorkspaceStructure(workspaces, excludeLinkId: excludeLinkId)

        let prompt = """
        You are an intelligent bookmark organizer for a macOS app called MarklyAI.

        Given a URL and title, decide where to place it in the user's bookmark structure.

        Current workspaces and folders:
        \(structure)

        New bookmark:
        - URL: \(url)
        - Title: \(title)

        RULES:
        1. If an appropriate workspace exists, place the bookmark there
        2. If no workspace fits, use "create_workspace" to make one with a BROAD category name
        3. ALWAYS use "create_folder" to organize links into sub-categories within workspaces:
           - If a workspace has 2+ links at the root that belong to different sub-topics, CREATE folders
           - Development workspace MUST have folders like: "Frontend", "Backend", "DevOps", "Databases", "Documentation"
           - Design workspace MUST have folders like: "UI Libraries", "Inspiration", "Tools"
           - Every link should ideally be in a folder, not floating at workspace root
        4. Workspace names should be high-level: "Development", "Design", "Research", "News & Media", "Social", "Tools & Apps", "Learning", "Entertainment", "Finance", "Shopping"
        5. NEVER create a workspace for a single technology (no "React", "Swift", "Python" workspaces)
        6. Be PROACTIVE: if "Inbox" is the only option, create the right workspace instead
        7. IMPORTANT: The bookmark was temporarily placed. Decide its REAL home based on content.
        8. NEVER say "already exists" or "duplicate" — always make an organization decision
        9. When using "create_folder", set workspaceId to the target workspace UUID AND set newFolderName

        Respond with ONLY a JSON object (no markdown):
        {
            "action": "place" | "create_folder" | "create_workspace",
            "workspaceId": "uuid of target workspace, or null if creating new workspace",
            "folderId": "uuid of existing folder to place in, or null",
            "newWorkspaceName": "name if action is create_workspace, else null",
            "newFolderName": "name if action is create_folder, else null",
            "reasoning": "one-line explanation"
        }

        Examples:
        - github.com/facebook/react → if Development exists: create_folder with workspaceId=<dev-uuid>, newFolderName="Frontend"
        - docs.python.org → if Development exists: create_folder with workspaceId=<dev-uuid>, newFolderName="Backend"
        - kubernetes.io → if Development exists: create_folder with workspaceId=<dev-uuid>, newFolderName="DevOps"
        - tailwindcss.com → if Development/Frontend folder exists: place with workspaceId=<dev-uuid>, folderId=<frontend-uuid>
        - medium.com/design → create_workspace "Design" if none exists
        - nytimes.com → create_workspace "News & Media" if none exists
        """

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 500,
            "messages": [["role": "user", "content": prompt]]
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("[AI] Invalid response type")
                return nil
            }

            print("[AI] Organization response: HTTP \(httpResponse.statusCode)")

            guard httpResponse.statusCode == 200 else {
                let bodyString = String(data: data, encoding: .utf8)
                print("[AI] HTTP error \(httpResponse.statusCode): \(bodyString ?? "no body")")
                return nil
            }

            let decision = parseResponse(data, workspaces: workspaces)
            if let decision = decision {
                print("[AI] Decision: \(decision.action) - \(decision.reasoning)")
            } else {
                print("[AI] Failed to parse response")
            }
            return decision
        } catch {
            print("[AI] Network error: \(error)")
            return nil
        }
    }

    /// Build a textual representation of the workspace structure for the AI prompt
    private func buildWorkspaceStructure(_ workspaces: [Workspace], excludeLinkId: UUID? = nil) -> String {
        var lines: [String] = []
        for workspace in workspaces {
            lines.append("Workspace: \"\(workspace.name)\" (id: \(workspace.id.uuidString))")
            appendNodeStructure(workspace.items, indent: 1, lines: &lines, excludeLinkId: excludeLinkId)
        }
        return lines.joined(separator: "\n")
    }

    /// Recursively append node structure (folders and links) to the output
    private func appendNodeStructure(_ nodes: [Node], indent: Int, lines: inout [String], excludeLinkId: UUID? = nil) {
        let prefix = String(repeating: "  ", count: indent)
        for node in nodes {
            // Skip the link being organized (it's temporarily in current workspace)
            if let excludeId = excludeLinkId, node.id == excludeId { continue }

            switch node {
            case .folder(let folder):
                lines.append("\(prefix)Folder: \"\(folder.name)\" (id: \(folder.id.uuidString))")
                appendNodeStructure(folder.children, indent: indent + 1, lines: &lines, excludeLinkId: excludeLinkId)
            case .link(let link):
                lines.append("\(prefix)Link: \"\(link.title)\" → \(link.url)")
            }
        }
    }

    /// Parse the AI response and extract the organization decision
    private func parseResponse(_ data: Data, workspaces: [Workspace]) -> OrganizationDecision? {
        // Parse Anthropic API response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstContent = content.first,
              let text = firstContent["text"] as? String else {
            print("[AI] Failed to parse API response structure")
            return nil
        }

        print("[AI] Received text: \(text)")

        // Extract JSON from response text (Claude might wrap it in markdown code blocks)
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let jsonData = cleanText.data(using: .utf8),
              let decision = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            print("[AI] Failed to parse decision JSON")
            return nil
        }

        let actionStr = decision["action"] as? String ?? "place"
        let action: OrganizationDecision.Action
        switch actionStr {
        case "create_folder": action = .createFolder
        case "create_workspace": action = .createWorkspace
        default: action = .place
        }

        let workspaceIdStr = decision["workspaceId"] as? String
        let folderIdStr = decision["folderId"] as? String

        return OrganizationDecision(
            action: action,
            workspaceId: workspaceIdStr.flatMap { UUID(uuidString: $0) },
            folderId: folderIdStr.flatMap { UUID(uuidString: $0) },
            newWorkspaceName: decision["newWorkspaceName"] as? String,
            newFolderName: decision["newFolderName"] as? String,
            reasoning: decision["reasoning"] as? String ?? ""
        )
    }
}
