import BrainCore
import SwiftUI

struct ModesView: View {
    @EnvironmentObject var state: AppState
    @State private var modes: [Mode] = []
    @State private var selection: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(modes, selection: $selection) { m in
                    HStack { Text(m.name); Spacer(); if m.readsScreen { Image(systemName: "eye").foregroundStyle(.secondary).help("Reads the visible window") } }.tag(m.id)
                }
                HStack {
                    Button { let m = Mode(id: "custom-\(UUID().uuidString.prefix(6))", name: "New mode", instructions: ""); modes.insert(m, at: 0); selection = m.id; save() } label: { Image(systemName: "plus") }
                    Button { modes.removeAll { $0.id == selection && !$0.builtIn }; save() } label: { Image(systemName: "minus") }
                        .disabled(modes.first { $0.id == selection }?.builtIn ?? true)
                    Spacer()
                    Button("Reset all") { modes = Mode.defaults; save() }
                }.buttonStyle(.borderless).padding(8)
            }.frame(minWidth: 180, maxWidth: 240)
            if let i = modes.firstIndex(where: { $0.id == selection }) {
                Form {
                    TextField("Name", text: $modes[i].name)
                    SwiftUI.Section("Clean-up instructions (added to the base rules)") {
                        TextEditor(text: $modes[i].instructions).font(.body).frame(minHeight: 150)
                    }
                    if modes[i].id != "default" {
                        SwiftUI.Section("Used in these apps (bundle IDs, one per line; end with a dot to match a prefix)") {
                            TextEditor(text: lines($modes[i].bundleIDs)).font(.system(.caption, design: .monospaced)).frame(minHeight: 70)
                        }
                        SwiftUI.Section("Used on these websites (part of the URL or tab title, one per line)") {
                            TextEditor(text: lines($modes[i].urlPatterns)).font(.system(.caption, design: .monospaced)).frame(minHeight: 60)
                        }
                    }
                    Toggle("Read the visible window so names on screen are spelled as shown", isOn: $modes[i].readsScreen)
                }
                .formStyle(.grouped)
                .onChange(of: modes) { save() }
            } else {
                ContentUnavailableView("Pick a mode", systemImage: "square.stack.3d.up",
                                       description: Text("The mode is chosen from the frontmost app and, in browsers, the page. Websites win over apps; list order breaks ties."))
            }
        }
        .navigationTitle("Modes")
        .onAppear { modes = state.modes.all; selection = selection ?? modes.first?.id }
    }

    private func save() { state.modes.save(modes) }
    private func lines(_ b: Binding<[String]>) -> Binding<String> {
        Binding(get: { b.wrappedValue.joined(separator: "\n") },
                set: { b.wrappedValue = $0.components(separatedBy: "\n").map(\.trimmed).filter { !$0.isEmpty } })
    }
}
