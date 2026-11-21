// Nabla : projets LaTeX compilés sur ce Mac, avec lecture de formules manuscrites.
import SwiftUI
import UniformTypeIdentifiers

@main
struct Notes2LaTeXApp: App {
    @AppStorage("appearance") private var appearance = "system"

    init() { NSApplication.shared.setActivationPolicy(.regular) }  // fenêtre au premier plan aussi avec `swift run`

    var body: some Scene {
        WindowGroup("Nabla") { RootView() }
            .defaultSize(width: 1320, height: 820)
            .commands {
                CommandGroup(after: .saveItem) { ExportPDFCommand() }
                CommandGroup(after: .pasteboard) { FindCommands() }
                CommandGroup(after: .toolbar) {
                    Picker("Apparence", selection: $appearance) {
                        Text("Comme le système").tag("system")
                        Text("Clair").tag("light")
                        Text("Sombre").tag("dark")
                    }
                }
            }
    }
}

/// Le projet de la fenêtre au premier plan fournit son export ; le menu le déclenche.
struct ExportPDFKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var exportPDF: (() -> Void)? {
        get { self[ExportPDFKey.self] }
        set { self[ExportPDFKey.self] = newValue }
    }
}

struct ExportPDFCommand: View {
    @FocusedValue(\.exportPDF) private var export
    var body: some View {
        Button("Exporter en PDF…") { export?() }
            .keyboardShortcut("e")
            .disabled(export == nil)
    }
}

/// SwiftUI ne met pas de « Rechercher » dans le menu Édition : on envoie l'action à l'éditeur actif,
/// qui lit le type de recherche dans le tag de l'expéditeur.
struct FindCommands: View {
    var body: some View {
        Divider()
        Button("Rechercher…") { find(.showFindInterface) }.keyboardShortcut("f")
        Button("Rechercher et remplacer…") { find(.showReplaceInterface) }.keyboardShortcut("f", modifiers: [.command, .option])
        Button("Occurrence suivante") { find(.nextMatch) }.keyboardShortcut("g")
        Button("Occurrence précédente") { find(.previousMatch) }.keyboardShortcut("g", modifiers: [.command, .shift])
    }

    func find(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: sender)
    }
}

struct RootView: View {
    @State private var project: Project?
    @AppStorage("recents") private var recents = ""  // chemins des derniers projets, un par ligne
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        Group {
            if let project {
                ProjectView(project: project) { self.project = nil }
                    .id(project.root)
            } else {
                WelcomeView(recents: recentURLs, open: open)
            }
        }
        .onChange(of: appearance, initial: true) {
            // NSApp.appearance : l'éditeur et le PDF (AppKit) suivent aussi, pas seulement SwiftUI.
            NSApp.appearance = appearance == "light" ? NSAppearance(named: .aqua)
                : appearance == "dark" ? NSAppearance(named: .darkAqua) : nil
        }
    }

    var recentURLs: [URL] {
        recents.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Ouvre un dossier de projet, ou le dossier d'un fichier .tex choisi (ce fichier est alors ouvert).
    func open(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        let root = isDir.boolValue ? url : url.deletingLastPathComponent()
        recents = ([root.path] + recentURLs.map(\.path).filter { $0 != root.path }).prefix(8).joined(separator: "\n")
        let p = Project(root: root)
        if !isDir.boolValue, let file = relativePath(url.path, root: root) { p.open(file) }
        project = p
    }
}

struct WelcomeView: View {
    let recents: [URL]
    let open: (URL) -> Void
    @State private var message: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)  // le logo, tiré de l'icône de l'app
                    .resizable()
                    .frame(width: 112, height: 112)
                    .accessibilityHidden(true)
                Text("Nabla").font(.largeTitle.weight(.semibold))
                Text("Vos projets LaTeX, compilés sur ce Mac.").foregroundStyle(.secondary)
                Text("Nouveau projet").font(.headline).padding(.top, 18)
                HStack(spacing: 12) {
                    ForEach(projectTemplates) { template in
                        Button { newProject(template) } label: {
                            VStack(spacing: 8) {
                                Image(systemName: template.icon).font(.system(size: 24, weight: .light)).frame(height: 30)
                                Text(template.name).font(.callout)
                            }
                            .frame(width: 104, height: 88)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Nouveau projet à partir du modèle « \(template.name) »")
                    }
                }
                Button(action: openPanel) {
                    Label("Ouvrir un dossier ou un .tex…", systemImage: "folder")
                }
                .controlSize(.large)
                .keyboardShortcut("o")
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            List {
                Section("Récents") {
                    if recents.isEmpty {
                        Text("Aucun projet pour l'instant").foregroundStyle(.secondary)
                    }
                    ForEach(recents, id: \.self) { url in
                        Button { open(url) } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent).fontWeight(.medium)
                                    Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                }
                            } icon: { Image(systemName: "folder.fill").foregroundStyle(.tint) }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 320)
        }
        .frame(minWidth: 960, minHeight: 520)
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") {} }
    }

    func newProject(_ template: ProjectTemplate) {
        let panel = NSSavePanel()
        panel.title = "Nouveau projet"
        panel.prompt = "Créer"
        panel.nameFieldLabel = "Nom du projet :"
        panel.nameFieldStringValue = "Sans titre"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let error = createProject(at: url, template: template.main) { message = error } else { open(url) }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, UTType(filenameExtension: "tex") ?? .plainText]
        panel.message = "Choisir le dossier d'un projet, ou un fichier .tex"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }
}
