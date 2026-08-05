import ElephruitCore
import ElephruitDesign
import SwiftUI

/// Naming something before it exists: a project, a piece of work, a rename.
///
/// ### Why a sheet rather than an alert
/// An alert with a text field is the shorter code and it is the wrong control here. Its field
/// arrives without focus under automation and hands the button action whatever the binding
/// happened to hold, which is how "create a project" intermittently created a project called
/// nothing and stayed on the list. A sheet is a real view: focus is asked for and granted, the
/// text is this view's own state until it is handed over, and `onDismiss` gives the caller a
/// moment that is definitively *after* the presentation has gone — which is the only safe moment
/// to push a screen.
///
/// It also has room to say what is being made. A template's one-line summary is the difference
/// between choosing "Software project" and finding out what that decided.
struct MobileNameSheet: View {
    let title: String
    let prompt: String
    let subtitle: String?
    let confirmTitle: String
    var initialText: String = ""
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(prompt, text: $text)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit(confirm)
                        .accessibilityIdentifier("nameSheet.field")
                } footer: {
                    if let subtitle {
                        Text(subtitle)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle, action: confirm)
                        .disabled(text.nilIfBlank == nil)
                        .accessibilityIdentifier("nameSheet.confirm")
                }
            }
        }
        .presentationDetents([.medium])
        .task {
            text = initialText
            isFocused = true
        }
    }

    private func confirm() {
        guard let name = text.nilIfBlank else { return }
        onConfirm(name)
        dismiss()
    }
}
