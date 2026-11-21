// Fenêtre d'un projet : fichiers à gauche, éditeur au centre, PDF et journal à droite.
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ProjectView: View {
    @Bindable var project: Project
    let close: () -> Void
    @State private var showLog = false
    @State private var askingName = false
    @State private var newFileName = ""
    @State private var message: String?

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 360)
        } detail: {
            HSplitView {
                editorPane.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                previewPane.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(project.name)
        .navigationSubtitle(project.status)
        .toolbar { toolbar }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in project.reload() }
        .alert("Nouveau fichier", isPresented: $askingName) {
            TextField("chapitre.tex", text: $newFileName)
            Button("Créer") { message = project.createFile(named: newFileName); newFileName = "" }
            Button("Annuler", role: .cancel) { newFileName = "" }
        } message: {
            Text("Nom du fichier, éventuellement dans un sous-dossier (chap/intro.tex). Sans extension, ce sera un .tex.")
        }
    }

    // MARK: Fichiers

    var sidebar: some View {
        List(selection: Binding(get: { project.current }, set: { if $0 != project.current { project.open($0) } })) {
            Section("Fichiers") {
                ForEach(project.files, id: \.self) { file in
                    FileRow(file: file, isMain: file == project.main)
                        .tag(file)
                        .contextMenu {
                            if ext(file) == "tex" {
                                Button("Définir comme document principal") { project.setMain(file) }.disabled(file == project.main)
                            }
                            Button("Afficher dans le Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([project.root.appendingPathComponent(file)])
                            }
                            Divider()
                            Button("Placer dans la corbeille", role: .destructive) { project.trash(file) }
                        }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            project.importFiles(urls)
            return true
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") {} }
        .toolbar {
            ToolbarItemGroup {
                Button(action: close) { Label("Projets", systemImage: "chevron.backward") }
                    .help("Revenir à la liste des projets")
                Menu {
                    Button("Nouveau fichier…") { askingName = true }
                    Button("Importer des fichiers…", action: pickImports)
                } label: { Label("Ajouter", systemImage: "plus") }
                    .help("Ajouter un fichier au projet (on peut aussi glisser des fichiers dans la liste)")
            }
        }
    }

    // MARK: Éditeur

    @ViewBuilder var editorPane: some View {
        if project.isEditingText {
            LaTeXEditor(text: Binding(get: { project.text }, set: { project.edit($0) }), controller: project.editor)
        } else if let current = project.current, let image = NSImage(contentsOf: project.root.appendingPathComponent(current)) {
            Image(nsImage: image).resizable().scaledToFit().padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
        } else {
            ContentUnavailableView(
                project.current == nil ? "Aucun fichier ouvert" : "Aperçu indisponible",
                systemImage: "doc.text",
                description: Text(project.openError ?? (project.current == nil ? "Choisissez un fichier dans la liste." : "Ce type de fichier ne se modifie pas ici."))
            )
        }
    }

    // MARK: PDF et journal

    var previewPane: some View {
        VStack(spacing: 0) {
            if let pdf = project.pdf {
                PDFKitView(document: pdf, project: project)
            } else {
                ContentUnavailableView(
                    project.compiling ? "Compilation…" : "Pas encore de PDF",
                    systemImage: "doc.richtext",
                    description: Text("Le PDF s'affiche ici dès que le document principal compile.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showLog {
                LogPanel(project: project) { withAnimation(.snappy) { showLog = false } }
                    .transition(.move(edge: .bottom))
            } else if let first = project.log.first(where: { $0.kind == .error }) {
                ErrorBar(item: first, count: project.errors,
                         reveal: { project.reveal(file: first.file, line: first.line) },
                         showLog: { withAnimation(.snappy) { showLog = true } })
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: Barre d'outils

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if project.compiling || project.reading { ProgressView().controlSize(.small) }
            Button(action: pickPhoto) { Label("Lire une photo", systemImage: "text.viewfinder") }
                .labelStyle(.titleAndIcon)
                .help("Lire une formule manuscrite (photo ou InkML) et l'insérer au curseur — ⇧⌘I")
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(project.reading || !project.isEditingText)
            Button(action: project.showInPDF) { Label("Montrer dans le PDF", systemImage: "doc.text.magnifyingglass") }
                .help("Montrer dans le PDF la ligne du curseur — ⌘J. Double-cliquer dans le PDF fait l'inverse.")
                .keyboardShortcut("j")
                .disabled(project.pdf == nil || !project.isEditingText)
            Button(action: project.compile) { Label("Compiler", systemImage: "arrow.clockwise") }
                .help("Recompiler — ⌘R. Le PDF se met aussi à jour quand on arrête de taper.")
                .keyboardShortcut("r")
            Button { withAnimation(.snappy) { showLog.toggle() } } label: {
                Label("Journal", systemImage: project.errors > 0 ? "exclamationmark.triangle" : "list.bullet.rectangle")
            }
            .help("Erreurs et avertissements de la compilation — ⇧⌘L")
            .keyboardShortcut("l", modifiers: [.command, .shift])
            Button(action: exportPDF) { Label("Exporter le PDF", systemImage: "square.and.arrow.up") }
                .help("Enregistrer le PDF — ⌘E")
                .keyboardShortcut("e")
                .disabled(project.pdfData == nil)
        }
    }

    func pickPhoto() {
        let panel = NSOpenPanel()
        panel.message = "Choisir une photo de formule manuscrite ou un fichier InkML"
        panel.allowedContentTypes = [.image, UTType(filenameExtension: "inkml") ?? .xml]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        project.readPhoto(file)
    }

    func pickImports() {
        let panel = NSOpenPanel()
        panel.message = "Fichiers à copier dans le projet (images, .bib, .tex…)"
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        project.importFiles(panel.urls)
    }

    func exportPDF() {
        guard let data = project.pdfData else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = project.name + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url) } catch { message = "Export impossible : \(error.localizedDescription)" }
    }
}

struct FileRow: View {
    let file: String
    let isMain: Bool

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(file).lineLimit(1).truncationMode(.middle)
                if isMain {
                    Spacer(minLength: 4)
                    Text("principal").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(isMain ? Color.accentColor : .secondary)
        }
        .accessibilityLabel(isMain ? "\(file), document principal" : file)
    }

    var icon: String {
        switch ext(file) {
        case "tex": "doc.text"
        case "bib": "books.vertical"
        case "pdf": "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "svg", "eps": "photo"
        default: "doc"
        }
    }
}

struct ErrorBar: View {
    let item: LogItem
    let count: Int
    let reveal: () -> Void
    let showLog: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            Text(item.message).fontWeight(.medium).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 8)
            if let file = item.file, let line = item.line {
                Button("\(file) : ligne \(line)", action: reveal).buttonStyle(.link)
            }
            Button(count > 1 ? "Journal (\(count))" : "Journal", action: showLog)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct LogPanel: View {
    let project: Project
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Journal").font(.headline)
                Spacer()
                if let raw = project.output(".log"), FileManager.default.fileExists(atPath: raw.path) {
                    Button("Journal complet") { NSWorkspace.shared.open(raw) }
                }
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Fermer le journal")
                    .accessibilityLabel("Fermer le journal")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            // Liste toujours présente (message « vide » par-dessus) : retirer une List pendant que son
            // contenu rétrécit fait planter SwiftUI (index hors limites).
            List(Array(project.log.enumerated()), id: \.offset) { _, item in
                Button { project.reveal(file: item.file, line: item.line) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: item.kind == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(item.kind == .error ? .red : .orange)
                        Text(item.message).frame(maxWidth: .infinity, alignment: .leading)
                        if let file = item.file, let line = item.line {
                            Text("\(file):\(line)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        } else if let line = item.line {
                            Text("ligne \(line)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item.file == nil)
            }
            .listStyle(.inset)
            .overlay {
                if project.log.isEmpty {
                    Label("Aucune erreur ni avertissement", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 230)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - PDF

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    let project: Project

    func makeNSView(context: Context) -> FittingPDFView {
        let v = FittingPDFView()
        v.backgroundColor = .underPageBackgroundColor
        v.onDoubleClick = { [weak project] page, point in project?.showInSource(page: page, at: point) }
        project.pdfView = v
        return v
    }

    func updateNSView(_ v: FittingPDFView, context: Context) {
        guard v.document !== document else { return }
        let old = v.document
        let dest = v.currentDestination
        v.document = document
        v.fit()
        // Même page, même position d'une compilation à l'autre.
        guard let old, let dest, let oldPage = dest.page, document.pageCount > 0,
              let page = document.page(at: min(old.index(for: oldPage), document.pageCount - 1)) else { return }
        v.go(to: PDFDestination(page: page, at: dest.point))
    }
}

/// Pages à la largeur de la vue (2,5× au plus) ; un double-clic renvoie la page et le point touchés.
final class FittingPDFView: PDFView {
    var onDoubleClick: ((PDFPage, CGPoint) -> Void)?

    // Un double-clic va à la source (comme Overleaf) au lieu de sélectionner un mot.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, let onDoubleClick else { return super.mouseDown(with: event) }
        let p = convert(event.locationInWindow, from: nil)
        guard let page = page(for: p, nearest: true) else { return }
        onDoubleClick(page, convert(p, to: page))
    }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        fit()
    }

    func fit() {
        guard document != nil else { return }
        let s = min(scaleFactorForSizeToFit, 2.5)
        if s > 0 { scaleFactor = s }
    }
}
