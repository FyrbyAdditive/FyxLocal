// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FyxLocalCore
import FyxLocalMCP

/// Inspector section exposing connected MCP servers' resources (attach to
/// the conversation as composer attachments) and prompt templates (insert
/// their text into the composer, after collecting arguments when needed).
/// Server-provided names/descriptions render verbatim, never as
/// localisation keys.
struct MCPSection: View {
    @Bindable var viewModel: ChatViewModel
    @Bindable var environment: AppEnvironment

    @State private var busyResourceURI: String?
    @State private var busyPromptName: String?
    @State private var errorMessage: String?
    @State private var argumentsRequest: PromptArgumentsRequest?

    struct PromptArgumentsRequest: Identifiable {
        let id = UUID()
        let serverID: MCPServerID
        let serverName: String
        let prompt: MCPPrompt
    }

    private var servers: [MCPServerRecord] {
        environment.mcpServers.filter { record in
            guard case .ready = environment.mcpRegistry.status[record.id] else { return false }
            let hasResources = !(environment.mcpRegistry.resources[record.id] ?? []).isEmpty
            let hasPrompts = !(environment.mcpRegistry.prompts[record.id] ?? []).isEmpty
            return hasResources || hasPrompts
        }
    }

    var body: some View {
        if !servers.isEmpty {
            Section {
                ForEach(servers, id: \.id) { record in
                    DisclosureGroup {
                        resourceRows(record)
                        promptRows(record)
                    } label: {
                        Label {
                            Text(verbatim: record.displayName)
                        } icon: {
                            Image(systemName: "server.rack")
                        }
                    }
                }
                if let errorMessage {
                    Text(verbatim: errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("MCP servers", bundle: .module)
            }
            .sheet(item: $argumentsRequest) { request in
                MCPPromptArgumentsSheet(request: request) { arguments in
                    argumentsRequest = nil
                    if let arguments {
                        runPrompt(request.prompt, serverID: request.serverID, arguments: arguments)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func resourceRows(_ record: MCPServerRecord) -> some View {
        ForEach(environment.mcpRegistry.resources[record.id] ?? []) { resource in
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: resource.title ?? resource.name)
                            .lineLimit(1)
                        if let description = resource.description {
                            Text(verbatim: description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } icon: {
                    Image(systemName: iconName(for: resource.mimeType))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if busyResourceURI == resource.uri {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        attach(resource, serverID: record.id)
                    } label: {
                        Text("Attach", bundle: .module)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder
    private func promptRows(_ record: MCPServerRecord) -> some View {
        ForEach(environment.mcpRegistry.prompts[record.id] ?? []) { prompt in
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: prompt.title ?? prompt.name)
                            .lineLimit(1)
                        if let description = prompt.description {
                            Text(verbatim: description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } icon: {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if busyPromptName == prompt.name {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        use(prompt, record: record)
                    } label: {
                        Text("Use", bundle: .module)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func iconName(for mimeType: String?) -> String {
        guard let mimeType else { return "doc" }
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType.hasPrefix("text/") { return "doc.text" }
        if mimeType.contains("json") || mimeType.contains("xml") { return "curlybraces" }
        return "doc"
    }

    // MARK: - Actions

    private func attach(_ resource: MCPResource, serverID: MCPServerID) {
        busyResourceURI = resource.uri
        Task {
            defer { busyResourceURI = nil }
            do {
                let contents = try await environment.mcpRegistry.readResource(serverID: serverID, uri: resource.uri)
                var attachedAny = false
                for entry in contents {
                    switch entry {
                    case .text(_, _, let text):
                        guard text.utf8.count <= ChatViewModel.maxTextAttachmentBytes else {
                            errorMessage = String(localized: "\(resource.name) is too large to attach as text (over 1 MB).")
                            continue
                        }
                        viewModel.draftAttachments.append(
                            PendingAttachment(filename: resource.name, kind: .textFile(contents: text))
                        )
                        attachedAny = true
                    case .blob(_, let mimeType, let base64):
                        if let mimeType, mimeType.hasPrefix("image/"), let data = Data(base64Encoded: base64) {
                            guard viewModel.activeModelAcceptsImages else {
                                errorMessage = String(localized: "This model doesn't accept images. Enable image input for it in Settings → Providers.")
                                continue
                            }
                            viewModel.draftAttachments.append(
                                PendingAttachment(filename: resource.name, kind: .image(data: data, mimeType: mimeType))
                            )
                            attachedAny = true
                        } else {
                            errorMessage = String(localized: "This resource type can't be attached.", bundle: .module)
                        }
                    }
                }
                if attachedAny { errorMessage = nil }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func use(_ prompt: MCPPrompt, record: MCPServerRecord) {
        if prompt.arguments.isEmpty {
            runPrompt(prompt, serverID: record.id, arguments: [:])
        } else {
            argumentsRequest = PromptArgumentsRequest(
                serverID: record.id,
                serverName: record.displayName,
                prompt: prompt
            )
        }
    }

    private func runPrompt(_ prompt: MCPPrompt, serverID: MCPServerID, arguments: [String: String]) {
        busyPromptName = prompt.name
        Task {
            defer { busyPromptName = nil }
            do {
                let result = try await environment.mcpRegistry.getPrompt(
                    serverID: serverID,
                    name: prompt.name,
                    arguments: arguments
                )
                insert(result)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Prefills the composer with the prompt's text (user reviews before
    /// sending); image content becomes a pending attachment.
    private func insert(_ result: MCPPromptResult) {
        var texts: [String] = []
        for message in result.messages {
            switch message.content {
            case .text(let text):
                texts.append(text)
            case .resource(_, let text):
                if let text { texts.append(text) }
            case .image(let base64, let mimeType):
                if viewModel.activeModelAcceptsImages, let data = Data(base64Encoded: base64) {
                    viewModel.draftAttachments.append(
                        PendingAttachment(filename: "prompt-image", kind: .image(data: data, mimeType: mimeType))
                    )
                }
            }
        }
        let joined = texts.joined(separator: "\n\n")
        guard !joined.isEmpty else { return }
        viewModel.draftText = viewModel.draftText.isEmpty
            ? joined
            : viewModel.draftText + "\n\n" + joined
    }
}

/// Argument-collection sheet for MCP prompts. Reuses the elicitation form
/// stack: every prompt argument maps to an unconstrained string field.
struct MCPPromptArgumentsSheet: View {
    let request: MCPSection.PromptArgumentsRequest
    /// nil = cancelled.
    let onComplete: ([String: String]?) -> Void

    @State private var form: ElicitationFormModel
    @State private var showErrors = false

    init(request: MCPSection.PromptArgumentsRequest, onComplete: @escaping ([String: String]?) -> Void) {
        self.request = request
        self.onComplete = onComplete
        let fields = request.prompt.arguments.map { argument in
            MCPElicitationField(
                name: argument.name,
                title: argument.title,
                description: argument.description,
                kind: .string(minLength: nil, maxLength: nil, pattern: nil, format: nil, defaultValue: nil),
                isRequired: argument.required
            )
        }
        _form = State(initialValue: ElicitationFormModel(fields: fields))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: request.prompt.title ?? request.prompt.name)
                .font(.headline)
            if let description = request.prompt.description {
                Text(verbatim: description)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(form.fields.indices, id: \.self) { index in
                let field = form.fields[index]
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(verbatim: field.displayTitle)
                            .font(.callout.weight(.medium))
                        if field.spec.isRequired {
                            Text("Required", bundle: .module)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    TextField(text: Binding(
                        get: { form.fields[index].text },
                        set: { form.fields[index].text = $0 }
                    )) {
                        Text(verbatim: "")
                    }
                    .textFieldStyle(.roundedBorder)
                    if let description = field.spec.description {
                        Text(verbatim: description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if showErrors, form.error(for: field) != nil {
                        Text("This field is required.", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            HStack {
                Button {
                    onComplete(nil)
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    if form.isValid {
                        onComplete(stringArguments())
                    } else {
                        showErrors = true
                    }
                } label: {
                    Text("Insert", bundle: .module)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420, maxWidth: 520)
    }

    private func stringArguments() -> [String: String] {
        var arguments: [String: String] = [:]
        for field in form.fields {
            let trimmed = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                arguments[field.spec.name] = trimmed
            }
        }
        return arguments
    }
}
