// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FyxLocalCore
import FyxLocalMCP

/// Modal form for an MCP server's form-mode `elicitation/create` request.
/// The requesting server is named prominently (spec MUST), the server's own
/// message and field texts render verbatim (never as localisation keys), and
/// the user always has explicit Decline and Cancel paths.
struct MCPElicitationSheet: View {
    let prompt: MCPElicitationCoordinator.Prompt
    let onResolve: (MCPElicitationResult) -> Void

    @State private var form: ElicitationFormModel
    /// Validation errors only show after the first Accept attempt so an
    /// empty required form doesn't open covered in red.
    @State private var showErrors = false

    init(prompt: MCPElicitationCoordinator.Prompt, onResolve: @escaping (MCPElicitationResult) -> Void) {
        self.prompt = prompt
        self.onResolve = onResolve
        _form = State(initialValue: prompt.form)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("\(prompt.serverDisplayName) is requesting information", bundle: .module)
                    .font(.headline)
            }

            Text(verbatim: prompt.message)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            if !form.fields.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(form.fields.indices, id: \.self) { index in
                            fieldRow(at: index)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 360)
            }

            HStack {
                Button {
                    onResolve(.cancel)
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    onResolve(.decline)
                } label: {
                    Text("Decline", bundle: .module)
                }
                Button {
                    if form.isValid {
                        onResolve(.accept(form.contentJSON()))
                    } else {
                        showErrors = true
                    }
                } label: {
                    Text("Accept", bundle: .module)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(showErrors && !form.isValid)
            }
        }
        .padding(24)
        .frame(minWidth: 440, maxWidth: 560)
    }

    @ViewBuilder
    private func fieldRow(at index: Int) -> some View {
        let field = form.fields[index]
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                // Field titles come from the server — verbatim.
                Text(verbatim: field.displayTitle)
                    .font(.callout.weight(.medium))
                if field.spec.isRequired {
                    Text("Required", bundle: .module)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            fieldControl(at: index)

            if let description = field.spec.description {
                Text(verbatim: description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showErrors, let error = form.error(for: field) {
                Text(errorText(error), bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func fieldControl(at index: Int) -> some View {
        let field = form.fields[index]
        switch field.spec.kind {
        case .string(_, _, _, let format, _):
            TextField(text: Binding(
                get: { form.fields[index].text },
                set: { form.fields[index].text = $0 }
            )) {
                Text(verbatim: placeholder(for: format))
            }
            .textFieldStyle(.roundedBorder)
        case .number:
            TextField(text: Binding(
                get: { form.fields[index].text },
                set: { form.fields[index].text = $0 }
            )) {
                Text(verbatim: "")
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 180)
        case .boolean:
            Toggle(isOn: Binding(
                get: { form.fields[index].boolValue },
                set: { form.fields[index].boolValue = $0 }
            )) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        case .enumeration(let options, _):
            Picker(selection: Binding(
                get: { form.fields[index].selection },
                set: { form.fields[index].selection = $0 }
            )) {
                Text(verbatim: "—").tag(String?.none)
                ForEach(options, id: \.value) { option in
                    Text(verbatim: option.title ?? option.value).tag(String?.some(option.value))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 280, alignment: .leading)
        case .multiSelect(let options, _):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(options, id: \.value) { option in
                    Toggle(isOn: Binding(
                        get: { form.fields[index].selections.contains(option.value) },
                        set: { isOn in
                            if isOn {
                                form.fields[index].selections.insert(option.value)
                            } else {
                                form.fields[index].selections.remove(option.value)
                            }
                        }
                    )) {
                        Text(verbatim: option.title ?? option.value)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private func placeholder(for format: MCPElicitationField.StringFormat?) -> String {
        switch format {
        case .email: return "name@example.com"
        case .uri: return "https://…"
        case .date: return "2026-01-31"
        case .dateTime: return "2026-01-31T12:00:00Z"
        case nil: return ""
        }
    }

    private func errorText(_ error: ElicitationFormModel.FieldError) -> LocalizedStringKey {
        switch error {
        case .required: return "This field is required."
        case .invalidEmail: return "Enter a valid email address."
        case .invalidURL: return "Enter a valid URL."
        case .invalidDate: return "Enter a valid date."
        case .notANumber: return "Enter a number."
        case .notAWholeNumber: return "Enter a whole number."
        case .outOfRange: return "Value is out of range."
        case .lengthOutOfBounds: return "Text length is out of bounds."
        }
    }
}
