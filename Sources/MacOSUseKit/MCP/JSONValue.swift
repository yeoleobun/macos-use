import Foundation

/// Recursive, strictly `Sendable` JSON value for zero-dependency MCP serialization and tool schemas.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let b):
            try container.encode(b)
        case .int(let i):
            try container.encode(i)
        case .double(let d):
            try container.encode(d)
        case .string(let s):
            try container.encode(s)
        case .array(let arr):
            try container.encode(arr)
        case .object(let obj):
            try container.encode(obj)
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(exactly: d)
        default: return nil
        }
    }

    public var uint32Value: UInt32? {
        guard let i = intValue, i >= 0 else { return nil }
        return UInt32(exactly: i)
    }

    public var int32Value: Int32? {
        guard let i = intValue else { return nil }
        return Int32(exactly: i)
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var stringArrayValue: [String]? {
        arrayValue?.compactMap(\.stringValue)
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public static func fromEncodable<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func prettyJSONString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

public enum JSONSchema {
    public static func object(
        properties: [String: JSONValue],
        required: [String] = []
    ) -> JSONValue {
        var map: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties)
        ]
        if !required.isEmpty {
            map["required"] = .array(required.map(JSONValue.string))
        }
        return .object(map)
    }

    public static func string(_ description: String, enumValues: [String]? = nil) -> JSONValue {
        var map: [String: JSONValue] = [
            "type": .string("string"),
            "description": .string(description)
        ]
        if let enumValues {
            map["enum"] = .array(enumValues.map(JSONValue.string))
        }
        return .object(map)
    }

    public static func integer(_ description: String) -> JSONValue {
        .object([
            "type": .string("integer"),
            "description": .string(description)
        ])
    }

    public static func number(_ description: String) -> JSONValue {
        .object([
            "type": .string("number"),
            "description": .string(description)
        ])
    }

    public static func boolean(_ description: String) -> JSONValue {
        .object([
            "type": .string("boolean"),
            "description": .string(description)
        ])
    }

    public static func stringArray(_ description: String) -> JSONValue {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object(["type": .string("string")])
        ])
    }

    public static func regionObject(_ description: String) -> JSONValue {
        .object([
            "type": .string("object"),
            "description": .string(description),
            "properties": .object([
                "x": .object(["type": .string("number")]),
                "y": .object(["type": .string("number")]),
                "width": .object(["type": .string("number")]),
                "height": .object(["type": .string("number")])
            ]),
            "required": .array([.string("x"), .string("y"), .string("width"), .string("height")])
        ])
    }
}
