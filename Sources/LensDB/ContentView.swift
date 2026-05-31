import SwiftUI
import AppKit

/// Window appearance the user can pick. `auto` follows the system setting.
enum Appearance: String, CaseIterable, Identifiable {
    case auto, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .auto: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// Applied at the AppKit level (`NSApp.appearance`) rather than via SwiftUI's
    /// `.preferredColorScheme`: the latter doesn't reliably re-propagate across a
    /// NavigationSplitView's separately-hosted columns when switching back to
    /// Auto, leaving a light/dark mix. nil means "follow the system".
    var nsAppearance: NSAppearance? {
        switch self {
        case .auto: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

extension Color {
    /// Brand accent — the logo's gold. (Its teal-green gem tone is the alt.)
    static let brandAccent = Color(red: 0xD8 / 255, green: 0xA8 / 255, blue: 0x60 / 255)
    /// Readable text/icon color on top of `brandAccent`. Gold is light, so this
    /// is near-black (white-on-gold has poor contrast).
    static let onBrandAccent = Color(red: 0x23 / 255, green: 0x1A / 255, blue: 0x06 / 255)
}

/// Selected-row background: a brand-accent pill. We render it ourselves (rows
/// are buttons, lists carry no `selection:`) because macOS won't let `.tint`
/// recolor the built-in List selection highlight.
@ViewBuilder
fileprivate func brandSelectionBackground(_ selected: Bool) -> some View {
    if selected {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.brandAccent)
            .padding(.vertical, 1)
            .padding(.horizontal, 6)
    } else {
        Color.clear
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var showSettings = false
    @AppStorage("appearance") private var appearance: Appearance = .auto

    var body: some View {
        NavigationSplitView {
            DatabaseSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            TableListView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            DetailView(model: model)
        }
        // These live on the split view (not the sidebar column) with a trailing
        // placement so they stay visible when the sidebar is collapsed.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await model.refreshAll() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh all connections")
                Button { showSettings = true } label: {
                    Image(systemName: "plus")
                }
                .help("Add a connection")
                // Segmented so all three modes stay in view and switching is a
                // single click (no menu to open first).
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { option in
                        Image(systemName: option.symbol)
                            .help(option.label)
                            .tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Appearance: Auto / Light / Dark")
            }
        }
        .tint(.brandAccent)
        .task { await model.bootstrap() }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model).tint(.brandAccent)
        }
        // Drive the whole app's appearance through AppKit so every column and
        // the toolbar switch together — including back to Auto — with no mix.
        .onAppear { NSApp.appearance = appearance.nsAppearance }
        .onChange(of: appearance) { _, newValue in
            NSApp.appearance = newValue.nsAppearance
        }
    }
}

// MARK: - Sidebar: databases

struct DatabaseSidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            ForEach(model.connections) { connection in
                Section {
                    if model.isExpanded(connection.id) {
                        rows(for: connection)
                    }
                } header: {
                    header(for: connection)
                }
            }
        }
        .overlay {
            if model.connections.isEmpty {
                ContentUnavailableView(
                    "No connections",
                    systemImage: "cylinder",
                    description: Text("Add a connection with the gear icon to browse databases.")
                )
            }
        }
        // The detail column owns the only navigationTitle (see DetailView), so
        // the toolbar shows exactly one title and nothing overlaps on collapse.
    }

    @ViewBuilder
    private func rows(for connection: Connection) -> some View {
        if connection.isLoading && connection.databases.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").foregroundStyle(.secondary)
            }
        } else if connection.databases.isEmpty {
            Text(connection.errorMessage ?? "No databases")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        } else {
            ForEach(connection.databases) { database in
                let sel = DatabaseSelection(connectionID: connection.id, databaseName: database.name)
                let isSel = model.selection == sel
                Button {
                    Task { await model.selectDatabase(sel) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(database.name)
                            .foregroundStyle(isSel ? Color.onBrandAccent : .primary)
                        HStack(spacing: 5) {
                            if let size = database.size { Text(size) }
                            if let owner = database.owner { Text("· \(owner)") }
                        }
                        .font(.caption)
                        .foregroundStyle(isSel ? Color.onBrandAccent.opacity(0.85) : .secondary)
                    }
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(brandSelectionBackground(isSel))
            }
        }
    }

    private func header(for connection: Connection) -> some View {
        let expanded = model.isExpanded(connection.id)
        return HStack(spacing: 4) {
            // Chevron + name toggle the section. An explicit chevron is used
            // (rather than List's hover-only disclosure) so the affordance is
            // always visible and easy to hit.
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    model.setExpanded(connection.id, !expanded)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(connection.label).textCase(nil)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse" : "Expand")

            Spacer(minLength: 4)
            Button { Task { await model.loadDatabases(for: connection.id) } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh this connection")
            Button { Task { await model.removeConnection(connection.id) } } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this connection")
        }
    }
}

// MARK: - Content: tables & views

struct TableListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.selectedDatabase == nil {
                ContentUnavailableView("Select a database", systemImage: "cylinder.split.1x2")
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    List {
                        ForEach(model.schemaOrder, id: \.self) { schema in
                            Section(schema) {
                                ForEach(model.tables(in: schema)) { table in
                                    let isSel = model.selectedTableID == table.id
                                    Button {
                                        Task { await model.selectTable(table.id) }
                                    } label: {
                                        row(for: table, selected: isSel)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .listRowBackground(brandSelectionBackground(isSel))
                                }
                            }
                        }
                    }
                    .overlay {
                        if model.isLoadingTables {
                            ProgressView()
                        } else if model.tables.isEmpty {
                            ContentUnavailableView("No tables", systemImage: "tablecells")
                        }
                    }
                    .searchable(text: $model.tableSearch, prompt: "Filter tables")
                }
            }
        }
        // No navigationTitle on purpose. The selected database name used to live
        // here as the column's title, but when the sidebar collapses SwiftUI
        // moves that title into the toolbar's leading area, on top of the
        // sidebar-toggle button. We show it in `header` (inside the column body)
        // instead, where it can never overlap the toolbar.
    }

    /// Which database these tables belong to. Lives in the column body so it
    /// stays visible — and correctly placed — whether or not the sidebar is open.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cylinder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.selectedDatabase?.name ?? "")
                    .font(.headline)
                    .lineLimit(1)
                if let connection = model.selectedConnection {
                    Text(connection.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func row(for table: TableInfo, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon(for: table.kind))
                .foregroundStyle(selected ? Color.onBrandAccent : .secondary)
                .frame(width: 16)
            Text(table.name).lineLimit(1)
                .foregroundStyle(selected ? Color.onBrandAccent : .primary)
            Spacer(minLength: 4)
            Text(rowsLabel(table.estimatedRows))
                .font(.caption)
                .foregroundStyle(selected ? Color.onBrandAccent.opacity(0.8) : Color.secondary.opacity(0.65))
        }
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "view": return "eye"
        case "matview": return "square.stack.3d.up"
        case "foreign": return "link"
        default: return "tablecells"
        }
    }

    private func rowsLabel(_ rows: Int64) -> String {
        guard rows > 0 else { return "" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let number = formatter.string(from: NSNumber(value: rows)) ?? "\(rows)"
        return "~\(number)"
    }
}
