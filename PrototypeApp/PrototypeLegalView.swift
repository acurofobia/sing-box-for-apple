import Library
import SwiftUI
import UIKit

struct PrototypeLegalView: View {
    let document: PrototypeLegalDocument
    @State private var text: String?
    @State private var failed = false
    @State private var search = ""

    var body: some View {
        Group {
            if let text {
                if document == .licenses {
                    List(PrototypeLegalDocument.licenseSections(from: text).filter {
                        search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                    }) { section in
                        NavigationLink {
                            PrototypeLegalTextView(text: section.text, detectLinks: false)
                                .navigationTitle(section.title)
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar(.visible, for: .navigationBar)
                        } label: { Text(verbatim: section.title) }
                    }
                    .searchable(text: $search, prompt: "Найти компонент")
                    .accessibilityIdentifier("prototype.legal.licenseList")
                } else {
                    PrototypeLegalTextView(text: text)
                }
            } else if failed {
                ContentUnavailableView("Документ недоступен", systemImage: "doc.text",
                                       description: Text("Не удалось открыть документ. Свяжитесь с разработчиком: fusedased@gmail.com."))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task {
            do { text = try document.text() } catch {
                VPNDiagnostics.applicationError("open legal document", error: error)
                failed = true
            }
        }
    }
}

struct PrototypeLegalTextView: UIViewRepresentable {
    let text: String
    var detectLinks = true
    var monospaced = false
    var accessibilityIdentifier = "prototype.legal.text"

    func makeUIView(context _: Context) -> UITextView {
        // TextKit 1 keeps long bundled license documents inexpensive to scroll.
        let view = UITextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.font = monospaced
            ? UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
            : .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 24, right: 20)
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = detectLinks ? [.link] : []
        view.accessibilityIdentifier = accessibilityIdentifier
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context _: Context) {
        if view.text != text { view.text = text }
    }
}

struct PrototypeLegalLinks: View {
    @State private var document: PrototypeLegalDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(PrototypeLegalDocument.allCases) { item in
                Button { document = item } label: {
                    Text(item.title).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("prototype.legal." + item.rawValue)
            }
        }
        .font(.subheadline)
        .sheet(item: $document) { item in
            NavigationStack {
                PrototypeLegalView(document: item)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Закрыть") { document = nil }
                        }
                    }
            }
        }
    }
}
