import Foundation

public struct JSONRPCRequest: Decodable, Sendable {
    public let jsonrpc: String?
    public let id: JSONValue?
    public let method: String
    public let params: JSONValue?
}

public struct JSONRPCError: Encodable, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct JSONRPCResponse: Encodable, Sendable {
    public let jsonrpc: String = "2.0"
    public let id: JSONValue
    public let result: JSONValue?
    public let error: JSONRPCError?

    public init(id: JSONValue, result: JSONValue) {
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: JSONValue, error: JSONRPCError) {
        self.id = id
        self.result = nil
        self.error = error
    }
}

public struct MCPToolDefinition: Encodable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct MCPContentItem: Encodable, Sendable {
    public let type: String
    public let text: String?
    public let data: String?
    public let mimeType: String?

    private init(type: String, text: String? = nil, data: String? = nil, mimeType: String? = nil) {
        self.type = type
        self.text = text
        self.data = data
        self.mimeType = mimeType
    }

    public static func text(_ value: String) -> MCPContentItem {
        MCPContentItem(type: "text", text: value)
    }

    public static func image(base64Data: String, mimeType: String) -> MCPContentItem {
        MCPContentItem(type: "image", data: base64Data, mimeType: mimeType)
    }
}

public struct MCPToolCallResult: Encodable, Sendable {
    public let content: [MCPContentItem]
    public let isError: Bool

    public init(content: [MCPContentItem], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ value: String, isError: Bool = false) -> MCPToolCallResult {
        MCPToolCallResult(content: [.text(value)], isError: isError)
    }
}
