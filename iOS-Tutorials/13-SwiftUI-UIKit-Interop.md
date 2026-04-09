# Tutorial 13 — SwiftUI & UIKit Interoperability
## Build: InteropKit — bridging old and new
**Time:** 60 min | **Swift 6 + SwiftUI** | **Topics:** UIViewRepresentable, UIViewControllerRepresentable, UIHostingController, Coordinator pattern, data flow between frameworks

---

## What you'll build
Four real-world interop scenarios:
1. UIKit `UITextView` inside SwiftUI (custom keyboard toolbar)
2. `MKMapView` wrapped for SwiftUI (before MapKit SwiftUI API existed)
3. SwiftUI view inside a UIKit `UITableViewCell`
4. Bidirectional data flow with Coordinator

---

## When you need interop

```
Use UIViewRepresentable when:
- No SwiftUI equivalent exists (e.g., WKWebView, AVPlayerViewController, legacy custom views)
- UIKit version has critical features not in SwiftUI (e.g., UITextView with full keyboard toolbar)
- Performance: UICollectionView is still faster than LazyVGrid for very complex cells

Use UIHostingController when:
- You have a UIKit-based app and want to modernize screen by screen
- A feature is easier in SwiftUI (e.g., complex animations, adaptive layouts)
```

---

## Step 1 — UITextView wrapper (full-featured text editor) (~15 min)

```swift
// RichTextEditor.swift
import SwiftUI
import UIKit

// ★ UIViewRepresentable: bridge UIKit UIView → SwiftUI View
struct RichTextEditor: UIViewRepresentable {

    @Binding var text: String
    @Binding var isFocused: Bool
    var onCommit: (() -> Void)? = nil

    // makeUIView: called once, create the UIKit view
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator   // ★ Coordinator is the delegate
        textView.font = .preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true

        // Add a custom toolbar (impossible in SwiftUI TextField)
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        let bold   = UIBarButtonItem(image: UIImage(systemName: "bold"),
                                     style: .plain, target: context.coordinator,
                                     action: #selector(Coordinator.toggleBold))
        let italic = UIBarButtonItem(image: UIImage(systemName: "italic"),
                                     style: .plain, target: context.coordinator,
                                     action: #selector(Coordinator.toggleItalic))
        let flex   = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done   = UIBarButtonItem(barButtonSystemItem: .done, target: context.coordinator,
                                     action: #selector(Coordinator.done))
        toolbar.items = [bold, italic, flex, done]
        textView.inputAccessoryView = toolbar

        return textView
    }

    // updateUIView: called every time SwiftUI state changes
    // ★ Guard against feedback loops when text changes originate from UIKit
    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        if isFocused && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    // Coordinator: UIKit delegate → SwiftUI binding updates
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // ★ Coordinator pattern: the Coordinator acts as the UIKit delegate
    // It holds a reference to the parent representable to update bindings
    class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextEditor

        init(parent: RichTextEditor) { self.parent = parent }

        // UITextViewDelegate — called from UIKit, update SwiftUI binding
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }

        @objc func toggleBold(_ sender: Any) {
            // Exercise: apply bold attribute to selected range
        }

        @objc func toggleItalic(_ sender: Any) {
            // Exercise: apply italic attribute to selected range
        }

        @objc func done(_ sender: Any) {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
            parent.onCommit?()
        }
    }
}
```

---

## Step 2 — MKMapView wrapper (~10 min)

```swift
// MapViewRepresentable.swift
import SwiftUI
import MapKit

struct Annotation: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let title: String
}

struct MapViewRepresentable: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let annotations: [Annotation]
    var onAnnotationTapped: ((Annotation) -> Void)? = nil

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.setRegion(region, animated: false)
        return map
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        // Sync region (only when changed from SwiftUI side)
        if uiView.region.center.latitude != region.center.latitude {
            uiView.setRegion(region, animated: true)
        }

        // Sync annotations efficiently
        let existing = Set(uiView.annotations.compactMap { $0 as? AnnotationPin }
            .map(\.annotationID))
        let new = Set(annotations.map(\.id))

        let toRemove = uiView.annotations.compactMap { $0 as? AnnotationPin }
            .filter { !new.contains($0.annotationID) }
        let toAdd = annotations.filter { !existing.contains($0.id) }
            .map { AnnotationPin(annotation: $0) }

        uiView.removeAnnotations(toRemove)
        uiView.addAnnotations(toAdd)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    class Coordinator: NSObject, MKMapViewDelegate {
        let parent: MapViewRepresentable
        init(parent: MapViewRepresentable) { self.parent = parent }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Push user's pan/zoom back to SwiftUI binding
            parent.region = mapView.region
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let pin = view.annotation as? AnnotationPin else { return }
            parent.onAnnotationTapped?(pin.source)
        }
    }
}

// MKAnnotation wrapper (must be NSObject)
final class AnnotationPin: NSObject, MKAnnotation {
    let source: Annotation
    let annotationID: UUID
    var coordinate: CLLocationCoordinate2D { source.coordinate }
    var title: String? { source.title }

    init(annotation: Annotation) {
        self.source = annotation
        self.annotationID = annotation.id
    }
}
```

---

## Step 3 — SwiftUI inside UITableViewCell (UIHostingController) (~10 min)

```swift
// SwiftUITableViewCell.swift
import SwiftUI
import UIKit

// Pattern: embed UIHostingController's view inside a UIView
class SwiftUITableViewCell: UITableViewCell {

    private var hostingController: UIHostingController<AnyView>?

    func configure<V: View>(with swiftUIView: V, parent: UIViewController) {
        if let existing = hostingController {
            existing.rootView = AnyView(swiftUIView)
        } else {
            let hosting = UIHostingController(rootView: AnyView(swiftUIView))
            hosting.view.backgroundColor = .clear

            // Add as child ViewController (required for lifecycle)
            parent.addChild(hosting)
            contentView.addSubview(hosting.view)
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hosting.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                hosting.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])
            hosting.didMove(toParent: parent)
            hostingController = hosting
        }
    }
}

// The SwiftUI view rendered inside the cell
struct ProductCellContent: View {
    let name: String
    let price: String
    let rating: Double

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.2))
                .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline)
                HStack {
                    ForEach(0..<5, id: \.self) { i in
                        Image(systemName: Double(i) < rating ? "star.fill" : "star")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    Text(price).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding()
    }
}
```

---

## Step 4 — WKWebView wrapper (~5 min)

```swift
// WebView.swift
import SwiftUI
import WebKit

struct WebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var progress: Double

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator

        // KVO for progress (can't use delegate for this)
        context.coordinator.progressObservation = web.observe(
            \.estimatedProgress, options: [.new]
        ) { [weak context] _, change in
            Task { @MainActor in
                context?.coordinator.parent.progress = change.newValue ?? 0
            }
        }

        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebView
        var progressObservation: NSKeyValueObservation?

        init(parent: WebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }
    }
}
```

---

## ★ Challenge

Build a `UIViewControllerRepresentable` wrapper for `AVPlayerViewController`:

```swift
import AVKit

struct VideoPlayerView: UIViewControllerRepresentable {
    let url: URL
    @Binding var isPlaying: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let player = AVPlayer(url: url)
        let vc = AVPlayerViewController()
        vc.player = player
        if isPlaying { player.play() }
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        isPlaying
            ? uiViewController.player?.play()
            : uiViewController.player?.pause()
    }
}
```

---

## Key concepts to remember

**`makeUIView` runs once; `updateUIView` runs on every SwiftUI re-render.** Put expensive setup in `makeUIView`. Guard against redundant updates in `updateUIView` (e.g., `if uiView.text != text`).

**Always use Coordinator for delegation.** Never make the representable struct itself the delegate — it's a value type and will be recreated constantly.

**`addChild` is required when embedding UIHostingController.** Without it, `viewWillAppear`/`viewDidDisappear` won't fire inside the SwiftUI view — this breaks animations, timers, and lifecycle-dependent code.

**`@Binding` bridges SwiftUI → UIKit; delegate callbacks bridge UIKit → SwiftUI.** These two together give you bidirectional data flow.

---

## MVVM Integration: Shared ViewModel across UIKit and SwiftUI

The critical insight for interop: **`@Observable` ViewModels work identically in both UIKit and SwiftUI.** The ViewModel has zero framework coupling.

```swift
// SharedViewModel.swift — works in UIKit and SwiftUI with zero changes
import Observation

enum InteropAction: Sendable {
    case updateText(String)
    case submitForm
    case clearForm
    case selectColor(UIColor)
}

struct InteropState: Equatable {
    var text: String         = ""
    var isSubmitted: Bool    = false
    var selectedColor: UIColor = .systemBlue
    var validationError: String? = nil

    var canSubmit: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty && !isSubmitted }
}

@MainActor
@Observable
final class InteropViewModel {
    private(set) var state = InteropState()

    func send(_ action: InteropAction) {
        switch action {
        case .updateText(let t):
            state.text = t
            state.validationError = t.count < 3 && !t.isEmpty ? "Minimum 3 characters" : nil
        case .submitForm:
            guard state.canSubmit else { return }
            state.isSubmitted = true
        case .clearForm:
            state = InteropState()
        case .selectColor(let color):
            state.selectedColor = color
        }
    }
}

// UIKit side — observes @Observable via withObservationTracking
class InteropViewController: UIViewController {
    private let vm = InteropViewModel()
    private var observationTask: Task<Void, Never>?

    private let textField = UITextField()
    private let submitButton = UIButton(type: .system)
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        bindToViewModel()
    }

    private func bindToViewModel() {
        // ★ Swift 6 way to observe @Observable from UIKit
        observationTask = Task { @MainActor in
            while !Task.isCancelled {
                withObservationTracking {
                    // Read state — observation registers dependencies
                    self.submitButton.isEnabled = self.vm.state.canSubmit
                    self.statusLabel.text = self.vm.state.isSubmitted ? "Submitted!" : ""
                    if let error = self.vm.state.validationError {
                        self.statusLabel.text = error
                        self.statusLabel.textColor = .systemRed
                    }
                } onChange: {
                    // Called when any accessed property changes
                    Task { @MainActor in self.bindToViewModel() }
                }
                break   // withObservationTracking registers once; loop re-registers
            }
        }
    }

    @objc private func textChanged() {
        vm.send(.updateText(textField.text ?? ""))
    }

    @objc private func submitTapped() {
        vm.send(.submitForm)
    }

    private func setupUI() {
        view.backgroundColor = .systemBackground
        textField.borderStyle = .roundedRect
        textField.placeholder = "Enter text (min 3 chars)"
        textField.addTarget(self, action: #selector(textChanged), for: .editingChanged)

        submitButton.setTitle("Submit", for: .normal)
        submitButton.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [textField, submitButton, statusLabel])
        stack.axis = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: 280)
        ])
    }

    deinit { observationTask?.cancel() }
}

// SwiftUI side — same ViewModel, plain @State
// InteropFormView.swift
import SwiftUI

struct InteropFormView: View {
    @State private var vm = InteropViewModel()

    var body: some View {
        Form {
            Section("Input") {
                TextField("Enter text (min 3 chars)", text: Binding(
                    get: { vm.state.text },
                    set: { vm.send(.updateText($0)) }
                ))
                if let error = vm.state.validationError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Button("Submit") { vm.send(.submitForm) }
                    .disabled(!vm.state.canSubmit)

                if vm.state.isSubmitted {
                    Label("Submitted!", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Section {
                Button("Clear", role: .destructive) { vm.send(.clearForm) }
            }
        }
        .navigationTitle("Interop Form")
    }
}

// MARK: — Swift Testing
// ★ One test suite covers both UIKit and SwiftUI behaviour — VM is framework-agnostic

import Testing
@testable import InteropKit

@Suite("InteropViewModel")
struct InteropViewModelTests {

    @Test @MainActor
    func initialStateIsEmpty() {
        let vm = InteropViewModel()
        #expect(vm.state.text.isEmpty)
        #expect(!vm.state.isSubmitted)
        #expect(!vm.state.canSubmit)
    }

    @Test @MainActor
    func shortTextShowsValidationError() {
        let vm = InteropViewModel()
        vm.send(.updateText("ab"))
        #expect(vm.state.validationError != nil)
        #expect(!vm.state.canSubmit)
    }

    @Test @MainActor
    func validTextClearsValidationError() {
        let vm = InteropViewModel()
        vm.send(.updateText("hello"))
        #expect(vm.state.validationError == nil)
        #expect(vm.state.canSubmit)
    }

    @Test @MainActor
    func submitValidFormSetsSubmitted() {
        let vm = InteropViewModel()
        vm.send(.updateText("hello"))
        vm.send(.submitForm)
        #expect(vm.state.isSubmitted)
        #expect(!vm.state.canSubmit)  // already submitted — disabled
    }

    @Test @MainActor
    func submitInvalidFormIsNoop() {
        let vm = InteropViewModel()
        vm.send(.submitForm)  // text is empty
        #expect(!vm.state.isSubmitted)
    }

    @Test @MainActor
    func clearFormResetsAllState() {
        let vm = InteropViewModel()
        vm.send(.updateText("hello"))
        vm.send(.submitForm)
        vm.send(.clearForm)
        #expect(vm.state == InteropState())
    }

    @Test @MainActor
    func emptyTextHasNoValidationError() {
        let vm = InteropViewModel()
        vm.send(.updateText(""))   // empty is not an error, just not submittable
        #expect(vm.state.validationError == nil)
        #expect(!vm.state.canSubmit)
    }
}
```

**The architecture insight for Staff interviews:** The ViewModel has no `import SwiftUI` or `import UIKit`. Both frameworks talk to the same ViewModel via `send(_:)`. The single test suite covers behaviour for both surfaces. This is the correct layering — swap one rendering layer for another without touching business logic.

---

## Follow-up questions

- *What happens if you forget to call `didMove(toParent:)` on a UIHostingController?* (The child VC's lifecycle methods don't fire; SwiftUI `.task` and `.onAppear` may misbehave)
- *How do you handle size changes in `UIViewRepresentable`?* (Implement `sizeThatFits(_:uiView:context:)` to participate in SwiftUI's layout)
- *What's the performance cost of UIHostingController?* (Moderate — each one has its own SwiftUI render tree; don't use one per cell in a large list)
- *Why use `withObservationTracking` in UIKit instead of Combine?* (It's the native observation system for `@Observable` — no KVO bridge, no `@Published`, no retain cycle risks with `AnyCancellable`)
