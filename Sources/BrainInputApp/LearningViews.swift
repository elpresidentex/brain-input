import BrainCore
import SwiftUI

struct DictionaryView: View {
    @EnvironmentObject var state: AppState
    @State private var newTerm = ""
    @State private var entries: [DictEntry] = []
    @State private var candidates: [(Correction, Int)] = []

    var body: some View {
        List {
            SwiftUI.Section {
                HStack {
                    TextField("Add a name, acronym or term", text: $newTerm).onSubmit(add)
                    Button("Add", action: add).disabled(newTerm.trimmed.isEmpty)
                }
            }
            SwiftUI.Section("Entries (\(entries.count))") {
                ForEach(entries) { e in
                    HStack {
                        Text(e.term).bold()
                        if e.source == "learned" { Chip("learned") }
                        if !e.heardAs.isEmpty { Text("heard as: \(e.heardAs.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button(role: .destructive) { state.dictionary.remove(e.term); reload() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            if !candidates.isEmpty {
                SwiftUI.Section("Seen once (becomes an entry when you make the same fix again)") {
                    ForEach(candidates, id: \.0) { c, _ in
                        HStack {
                            Text("\(c.from) → \(c.to)").foregroundStyle(.secondary)
                            Spacer()
                            Button("Add now") { state.dictionary.record([c]); reload() }.buttonStyle(.link)
                        }
                    }
                }
            }
        }
        .navigationTitle("Dictionary")
        .onAppear(perform: reload)
        .onChange(of: state.refreshTick) { reload() }
    }
    private func add() { state.dictionary.add(newTerm); newTerm = ""; reload() }
    private func reload() { entries = state.dictionary.entries; candidates = state.dictionary.candidates }
}

struct StyleView: View {
    @EnvironmentObject var state: AppState
    @State private var modeID = "chat"
    @State private var card = StyleCard(modeID: "chat")
    @State private var history: [StyleCard] = []
    @State private var importing = false
    @State private var importText = ""
    @State private var pending = 0

    var body: some View {
        Form {
            Picker("Mode", selection: $modeID) { ForEach(state.modes.all) { Text($0.name).tag($0.id) } }
            SwiftUI.Section("How I write here (version \(card.version), \(card.source))") {
                TextEditor(text: $card.description).frame(minHeight: 120)
                HStack {
                    Button("Save edit") { card.source = "edited"; card = state.styles.save(card); reload() }
                    Button(state.styleBusy == modeID ? "Working…" : "Regenerate from \(pending) new dictations") {
                        state.regenerateStyle(modeID, model: state.thinkingModel)
                    }.disabled(state.styleBusy != nil || pending == 0 || state.thinkingModel == nil)
                    Button("Import writing samples…") { importing = true }
                }
                Text("Regenerates on its own after \(StyleLearner(store: state.styles, notes: state.store).threshold) new dictations in this mode. File: ~/BrainInput/Style/\(modeID).md")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Examples") {
                if card.examples.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                ForEach(Array(card.examples.enumerated()), id: \.offset) { i, e in
                    HStack(alignment: .top) {
                        Text(e).textSelection(.enabled)
                        Spacer()
                        Button { card.examples.remove(at: i); card = state.styles.save(card); reload() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            if !history.isEmpty {
                SwiftUI.Section("Earlier versions") {
                    ForEach(history, id: \.version) { h in
                        DisclosureGroup("Version \(h.version) · \(h.updated.formatted(date: .abbreviated, time: .shortened)) · \(h.source)") {
                            Text(h.description).textSelection(.enabled)
                            Button("Restore this version") { var r = h; r.source = "edited"; card = state.styles.save(r); reload() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Style")
        .onAppear(perform: reload)
        .onChange(of: modeID) { reload() }
        .onChange(of: state.refreshTick) { reload() }
        .sheet(isPresented: $importing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Paste things you wrote in this context").font(.headline)
                Text("Separate samples with a line containing only ---. With an API key a description is written from them; without one they are stored as examples.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $importText).frame(width: 520, height: 280).border(.quaternary)
                HStack {
                    Spacer()
                    Button("Cancel") { importing = false }
                    Button("Import") {
                        let samples = importText.components(separatedBy: "\n---").map(\.trimmed).filter { !$0.isEmpty }
                        state.regenerateStyle(modeID, model: state.thinkingModel, imported: samples)
                        importText = ""; importing = false
                    }.keyboardShortcut(.defaultAction).disabled(importText.trimmed.isEmpty)
                }
            }.padding()
        }
    }

    private func reload() {
        card = state.styles.current(modeID) ?? StyleCard(modeID: modeID)
        history = state.styles.history(modeID)
        pending = StyleLearner(store: state.styles, notes: state.store).newSamples(modeID).count
    }
}
