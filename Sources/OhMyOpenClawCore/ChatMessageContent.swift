import Foundation

/// Projects typed Gateway records without interpreting arbitrary conversation text as JSON.
enum ChatMessageContent {
    struct Projection {
        var role: ChatMessage.Role
        var text: String
        var attachments: [ChatAttachment]
        var isToolMessage: Bool
    }

    private static let toolRoles = Set(["toolresult", "tool_result", "tool", "function"])
    private static let toolCalls = Set(["toolcall", "tool_call", "tooluse", "tool_use", "function_call"])
    private static let toolResults = Set(["toolresult", "tool_result", "function_call_output"])
    private static let toolFields = ["toolCallId", "tool_call_id", "toolUseId", "tool_use_id", "toolName", "tool_name"]

    static func project(_ value: JSONValue, fallbackID: String) -> Projection {
        let rawRole = value["role"].stringValue?.lowercased() ?? "assistant"
        let role = ChatMessage.Role(rawValue: rawRole) ?? .system
        let provenance = value["provenance"]
        let internalInput = rawRole == "user" && (
            provenance["kind"].stringValue == "internal_system" ||
            ["exec", "restart", "cron_failure_repair", "tool_handoff"].contains(provenance["sourceTool"].stringValue ?? "")
        )
        let hidden = (role == .system && !toolRoles.contains(rawRole)) || value["display"].boolValue == false ||
            value["customType"].stringValue == "openclaw.runtime-context" || internalInput
        guard !hidden else { return Projection(role: .system, text: "", attachments: [], isToolMessage: false) }

        let content: JSONValue
        if rawRole == "assistant", let display = value["openclawDisplayContent"].arrayValue {
            content = .array(display)
        } else { content = value["content"] }
        let blocks = content.arrayValue ?? []
        let hasToolBlocks = blocks.contains { toolCalls.contains(type(of: $0)) || toolResults.contains(type(of: $0)) }
        let envelope = toolFields.contains { !(value[$0].stringValue ?? "").isEmpty }
        var tool = toolRoles.contains(rawRole) || envelope || toolCalls.contains(type(of: value)) || toolResults.contains(type(of: value))
        if rawRole == "user", hasToolBlocks { tool = true }

        var text = ""
        if !tool, role == .user || role == .assistant {
            if let string = content.stringValue { text = string }
            else if content.arrayValue != nil {
                var textBlocks = blocks.filter { block in
                    let kind = type(of: block)
                    return kind == "text" || kind == "input_text" || (rawRole == "assistant" && kind == "output_text")
                }
                if rawRole == "assistant" {
                    let final = textBlocks.filter { phase(of: $0) == "final_answer" }
                    if !final.isEmpty { textBlocks = final }
                }
                text = textBlocks.compactMap { $0["text"].stringValue }.joined()
            } else { text = value["text"].stringValue ?? "" }
        }

        var attachments: [ChatAttachment] = []
        if tool || role == .user || role == .assistant {
            appendMedia(blocks, to: &attachments, fallbackID: fallbackID, toolOnly: tool)
        }
        if rawRole == "assistant", hasToolBlocks, text.isEmpty { tool = true }
        if tool { return Projection(role: .system, text: "", attachments: attachments, isToolMessage: true) }
        guard role == .user || role == .assistant else {
            return Projection(role: .system, text: "", attachments: [], isToolMessage: false)
        }
        appendInboundMedia(value, to: &attachments)
        return Projection(role: role, text: text, attachments: attachments, isToolMessage: false)
    }

    private static func appendInboundMedia(_ value: JSONValue, to attachments: inout [ChatAttachment]) {
        guard let messageID = value["__openclaw"]["id"].stringValue ?? value["id"].stringValue else { return }
        var seen = Set<String>()
        let facts = (value["__openclaw"]["media"].arrayValue ?? []).compactMap { fact -> ChatAttachment? in
            guard let source = fact["url"].stringValue ?? fact["path"].stringValue,
                  let reference = InboundMediaReference(source: source, messageID: messageID),
                  let mime = fact["contentType"].stringValue ?? fact["mimeType"].stringValue,
                  mime.lowercased().hasPrefix("image/"), seen.insert(source).inserted else { return nil }
            return ChatAttachment(id: messageID + ":media:" + source,
                                  fileName: fact["fileName"].stringValue ?? "画像", mimeType: mime.lowercased(),
                                  data: Data(), sizeBytes: fact["sizeBytes"].intValue, inboundMedia: reference)
        }
        guard !facts.isEmpty else { return }
        let images = attachments.indices.filter { attachments[$0].mimeType.hasPrefix("image/") }
        if images.count == facts.count {
            // The media facts describe the same ordered images whose content blocks
            // may have had their bytes removed from the history projection.
            for (index, fact) in zip(images, facts) {
                attachments[index].inboundMedia = fact.inboundMedia
                if attachments[index].fileName == "画像" { attachments[index].fileName = fact.fileName }
                if attachments[index].mimeType == "image/*" { attachments[index].mimeType = fact.mimeType }
                attachments[index].sizeBytes = attachments[index].sizeBytes ?? fact.sizeBytes
            }
        } else {
            attachments.removeAll { $0.mimeType.hasPrefix("image/") && $0.data.isEmpty && $0.artifactID == nil && $0.url == nil && $0.openURL == nil }
            for fact in facts where !attachments.contains(where: { $0.url == fact.inboundMedia?.source || $0.inboundMedia == fact.inboundMedia }) {
                attachments.append(fact)
            }
        }
    }

    private static func type(of value: JSONValue) -> String { value["type"].stringValue?.lowercased() ?? "" }

    private static func phase(of block: JSONValue) -> String? {
        if let phase = block["phase"].stringValue { return phase }
        guard let signature = block["textSignature"].stringValue,
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(signature.utf8)),
              decoded["v"].intValue == 1 else { return nil }
        return decoded["phase"].stringValue
    }

    private static func appendMedia(_ blocks: [JSONValue], to attachments: inout [ChatAttachment], fallbackID: String, toolOnly: Bool, depth: Int = 0) {
        guard depth < 16 else { return }
        for block in blocks {
            let kind = type(of: block)
            if (!toolOnly || kind == "image" || kind == "attachment"),
               let attachment = ChatAttachment.parse(block: block, fallbackID: fallbackID + ":attachment:\(attachments.count)") {
                attachments.append(attachment)
            } else if toolResults.contains(kind), let nested = block["content"].arrayValue {
                // Only explicit tool-result media is public; never traverse arguments,
                // details, or strings that happen to contain serialized provider data.
                appendMedia(nested, to: &attachments, fallbackID: fallbackID, toolOnly: true, depth: depth + 1)
            }
        }
    }
}
