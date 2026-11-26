import BrainCore
import SwiftUI

/// Full-text search across meeting notes and dictations (SQLite FTS5 index).
struct SearchView: View {
    @EnvironmentObject var state: AppState
    @State private var query = ""
    @State private var kind = "all"
    @State private var hits: [SearchHit] = []
    @State private var selected: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search meetings, dictations and transcripts", text: $query).textFieldStyle(.plain).font(.title3).onSubmit(run)
                Picker("", selection: $kind) { Text("All").tag("all"); Text("Meetings").tag("meeting"); Text("Dictations").tag("dictation"); Text("Transcripts").tag("transcript") }
                    .pickerStyle(.segmented).frame(width: 330)
            }.padding(12)
            Divider()
            HSplitView {
                List(hits, id: \.ref, selection: $selected) { h in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Chip(h.kind); Text(h.title).bold().lineLimit(1); Spacer(); Text(h.date).font(.caption).foregroundStyle(.secondary) }
                        Text(h.snippet.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.tag(h.ref)
                }
                .frame(minWidth: 300)
                .overlay { if hits.isEmpty { ContentUnavailableView(query.isEmpty ? "Type to search" : "No matches", systemImage: "magnifyingglass") } }
                NoteReader(ref: selected)
            }
        }
        .navigationTitle("Search")
        .onChange(of: query) { run() }
        .onChange(of: kind) { run() }
    }
    private func run() { hits = state.store.search(query, kind: kind == "all" ? nil : kind, limit: 50) }
}
