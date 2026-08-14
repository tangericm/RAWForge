import SwiftUI

/// The saved protocols, and nothing else.
///
/// This used to live inside the editor — a library, a preset browser and an
/// editing form on one screen — which made it unclear whether tapping a name
/// was choosing it, opening it, or replacing what was being typed. They are
/// separate acts and now separate screens.
struct ProtocolLibraryView: View {
    @ObservedObject var model: CaptureModel
    @State private var editing: CaptureSet?
    @State private var creating = false
    @State private var pendingDelete: String?

    var body: some View {
        List {
            if model.savedProtocols.isEmpty {
                Section {
                    Text("A protocol is a named, versioned list of exposures. It is what makes "
                         + "a capture repeatable — an unnamed set cannot be re-run identically "
                         + "later, which is the whole difference between this and a camera.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(model.savedProtocols, id: \.name) { p in
                        Button { editing = p } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(p.name) v\(p.version)").font(.callout)
                                    Text("\(p.specs.count) frames · \(p.generator.describe)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "square.and.pencil").foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Delete", role: .destructive) { pendingDelete = p.name }
                        }
                    }
                } footer: {
                    Text("Editing writes the next version. The one already shot stays as shot — "
                         + "sessions carry the full definition inline, not a reference to this "
                         + "file, so nothing here can change what a past session means.")
                }
            }

            Section("Start from a preset") {
                ForEach(ProtocolLibrary.presets(), id: \.0) { name, set in
                    Button {
                        editing = CaptureSet(name: name, version: 0, specs: set.specs,
                                             generator: set.generator,
                                             perSensorEVOffsetStops: [:])
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name).font(.callout)
                            Text(set.generator.describe).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Protocols")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { creating = true } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $creating) { ProtocolEditorView(model: model, editing: nil) }
        .sheet(item: $editing) { ProtocolEditorView(model: model, editing: $0) }
        .confirmationDialog("Delete this protocol?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            if let n = pendingDelete {
                Button("Delete \(n)", role: .destructive) {
                    ProtocolLibrary.delete(named: n)
                    model.refreshProtocols()
                    logInfo(.flow, "protocol \(n) deleted")
                    pendingDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Sessions already shot under it are unaffected. Sets already in the shot list "
                 + "keep their copy of the definition too.")
        }
        .onAppear { model.refreshProtocols() }
    }
}

/// `.sheet(item:)` needs identity, and a protocol's identity is its name.
extension CaptureSet: Identifiable {
    public var id: String { name }
}
