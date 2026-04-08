# Tutorial 18 — ARKit
## Build: ARMeasure — a real-world ruler using LiDAR/plane detection
**Time:** 60 min | **Swift 6 + SwiftUI** | **Topics:** ARKit, RealityKit, plane detection, raycasting, LiDAR

---

## What you'll build
An AR measuring tool that:
- Detects horizontal/vertical planes
- Places anchors on tap
- Measures distance between two placed points
- Shows live distance label in AR space

---

## Step 1 — ARSession configuration (~10 min)

```swift
// ARConfiguration.swift
import ARKit
import RealityKit

// Different AR modes and when to use them
enum ARMode {
    case worldTracking    // General AR, plane detection, object placement
    case imageTracking    // Track flat images (posters, cards)
    case faceTracking     // Front camera, face mesh
    case bodyTracking     // Full body pose estimation
    case objectScanning   // Create reference objects
}

// LiDAR-enhanced configuration (iPhone 12 Pro+, iPad Pro)
func makeWorldTrackingConfig() -> ARWorldTrackingConfiguration {
    let config = ARWorldTrackingConfiguration()
    config.planeDetection = [.horizontal, .vertical]
    config.environmentTexturing = .automatic

    // Enable scene reconstruction with LiDAR if available
    if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
        config.sceneReconstruction = .mesh
    }

    // Enable people occlusion
    if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
        config.frameSemantics = .personSegmentationWithDepth
    }

    return config
}
```

---

## Step 2 — Measurement view model (~15 min)

```swift
// MeasurementViewModel.swift
import ARKit
import RealityKit
import Observation

@MainActor
@Observable
final class MeasurementViewModel {

    var firstPoint: SIMD3<Float>? = nil
    var secondPoint: SIMD3<Float>? = nil
    var distance: Float? = nil
    var detectedPlanes: Int = 0
    var instructionText: String = "Move camera to detect surfaces"

    private var firstAnchor: AnchorEntity?
    private var secondAnchor: AnchorEntity?
    private var lineAnchor: AnchorEntity?

    // Called from ARView tap
    func handleTap(at worldPosition: SIMD3<Float>, in arView: ARView) {
        if firstPoint == nil {
            setFirstPoint(worldPosition, in: arView)
        } else if secondPoint == nil {
            setSecondPoint(worldPosition, in: arView)
        } else {
            // Reset measurement
            reset(in: arView)
        }
    }

    private func setFirstPoint(_ position: SIMD3<Float>, in arView: ARView) {
        firstPoint = position
        instructionText = "Tap to place second point"

        let anchor = AnchorEntity(world: position)
        anchor.addChild(makeSphere(color: .systemBlue))
        arView.scene.addAnchor(anchor)
        firstAnchor = anchor
    }

    private func setSecondPoint(_ position: SIMD3<Float>, in arView: ARView) {
        secondPoint = position

        let anchor = AnchorEntity(world: position)
        anchor.addChild(makeSphere(color: .systemRed))
        arView.scene.addAnchor(anchor)
        secondAnchor = anchor

        // Calculate and display distance
        if let first = firstPoint {
            let dist = simd_distance(first, position)
            distance = dist

            let meters = String(format: "%.2f m", dist)
            let cm = String(format: "%.0f cm", dist * 100)
            instructionText = "\(meters) (\(cm)) — tap to reset"

            // Draw line between points
            drawLine(from: first, to: position, in: arView)

            // Place floating label at midpoint
            let midpoint = (first + position) / 2
            let label = makeTextEntity(text: meters)
            let labelAnchor = AnchorEntity(world: midpoint + SIMD3<Float>(0, 0.05, 0))
            labelAnchor.addChild(label)
            arView.scene.addAnchor(labelAnchor)
            lineAnchor = labelAnchor
        }
    }

    func reset(in arView: ARView) {
        [firstAnchor, secondAnchor, lineAnchor].compactMap { $0 }.forEach {
            arView.scene.removeAnchor($0)
        }
        firstPoint = nil
        secondPoint = nil
        distance = nil
        firstAnchor = nil
        secondAnchor = nil
        lineAnchor = nil
        instructionText = "Tap to place first point"
    }

    func planeDetected() {
        detectedPlanes += 1
        if detectedPlanes == 1 {
            instructionText = "Surface found — tap to place first point"
        }
    }

    // MARK: - RealityKit entities

    private func makeSphere(color: UIColor) -> ModelEntity {
        let mesh = MeshResource.generateSphere(radius: 0.01)
        let material = SimpleMaterial(color: color, isMetallic: false)
        return ModelEntity(mesh: mesh, materials: [material])
    }

    private func makeTextEntity(text: String) -> ModelEntity {
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.002,
            font: .systemFont(ofSize: 0.05)
        )
        let material = SimpleMaterial(color: .white, isMetallic: false)
        return ModelEntity(mesh: mesh, materials: [material])
    }

    private func drawLine(from start: SIMD3<Float>, to end: SIMD3<Float>, in arView: ARView) {
        // Approximate line with thin cylinder between the two points
        let midpoint = (start + end) / 2
        let length = simd_distance(start, end)

        let cylinder = MeshResource.generateCylinder(height: length, radius: 0.002)
        let material = SimpleMaterial(color: .white.withAlphaComponent(0.8), isMetallic: false)
        let entity = ModelEntity(mesh: cylinder, materials: [material])

        // Orient cylinder toward end point
        let direction = normalize(end - start)
        entity.look(at: end, from: midpoint, relativeTo: nil)

        let anchor = AnchorEntity(world: midpoint)
        anchor.addChild(entity)
        arView.scene.addAnchor(anchor)
    }
}
```

---

## Step 3 — ARView wrapper (~15 min)

```swift
// ARViewRepresentable.swift
import SwiftUI
import ARKit
import RealityKit

struct ARViewContainer: UIViewRepresentable {
    let vm: MeasurementViewModel

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: true)

        // Configure session
        let config = makeWorldTrackingConfig()
        arView.session.delegate = context.coordinator
        arView.session.run(config)

        // Tap gesture for placing anchors
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        arView.addGestureRecognizer(tap)

        // Debug visualization (remove in production)
        arView.debugOptions = [.showAnchorOrigins, .showFeaturePoints]

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    class Coordinator: NSObject, ARSessionDelegate {
        let parent: ARViewContainer

        init(parent: ARViewContainer) { self.parent = parent }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView = gesture.view as? ARView else { return }
            let location = gesture.location(in: arView)

            // Raycast against detected planes
            let results = arView.raycast(from: location,
                                         allowing: .estimatedPlane,
                                         alignment: .any)
            if let first = results.first {
                let position = SIMD3<Float>(first.worldTransform.columns.3.x,
                                           first.worldTransform.columns.3.y,
                                           first.worldTransform.columns.3.z)
                Task { @MainActor in
                    self.parent.vm.handleTap(at: position, in: arView)
                }
            }
        }

        // Plane detected
        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            let planes = anchors.compactMap { $0 as? ARPlaneAnchor }
            guard !planes.isEmpty else { return }
            Task { @MainActor in parent.vm.planeDetected() }
        }
    }
}

// Main AR view
struct ARMeasureView: View {
    @State private var vm = MeasurementViewModel()

    var body: some View {
        ZStack {
            ARViewContainer(vm: vm).ignoresSafeArea()

            VStack {
                // HUD
                Text(vm.instructionText)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top)

                Spacer()

                if let dist = vm.distance {
                    Text(String(format: "%.2f m", dist))
                        .font(.largeTitle.bold())
                        .padding(16)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding(.bottom, 40)
                }
            }
        }
    }
}
```

---

## ★ Challenge
Add **3D model placement**: on long press, place a 1m reference cube so users can visually validate measurements.

---

# Tutorial 19 — TensorFlow Lite (Core ML)
## Build: VisionKit — on-device image classification
**Time:** 60 min | **Swift 6 + SwiftUI** | **Topics:** Core ML, Vision framework, TensorFlow Lite, model conversion, on-device inference

---

## Core ML vs TFLite — which to use?

```
Core ML (Apple native):
+ Integrated with Xcode — drag .mlmodel in, done
+ Uses ANE (Apple Neural Engine) for 10× speed
+ Automatic hardware selection (CPU/GPU/ANE)
+ No library dependency
- Apple-only, model must be converted

TensorFlow Lite:
+ Cross-platform (Android/iOS/embedded)
+ More model variety (HuggingFace, TF Hub)
+ Custom ops possible
- No ANE access (GPU delegate only)
- Adds ~2MB binary size
- More setup required

Recommendation: use Core ML when possible.
Use TFLite only for cross-platform shared models.
```

---

## Step 1 — Core ML image classifier (~20 min)

```swift
// ImageClassifier.swift
import CoreML
import Vision
import UIKit

// Actor: protects the model (VNCoreMLModel is NOT thread-safe)
actor ImageClassifier {

    private let model: VNCoreMLModel

    // Load model — do this once at app start, not per inference
    init() throws {
        // MobileNetV2 is included in Xcode model gallery
        // Download from: Xcode → File → New File → Core ML Model
        let config = MLModelConfiguration()
        config.computeUnits = .all   // use ANE + GPU + CPU
        let mlModel = try MobileNetV2(configuration: config).model
        self.model = try VNCoreMLModel(for: mlModel)
    }

    struct Prediction: Sendable {
        let label: String
        let confidence: Float
    }

    func classify(_ image: UIImage, topK: Int = 5) async throws -> [Prediction] {
        guard let cgImage = image.cgImage else { throw ClassifierError.invalidImage }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNCoreMLRequest(model: model) { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let results = (request.results as? [VNClassificationObservation])
                    ?? []
                let top = results
                    .sorted { $0.confidence > $1.confidence }
                    .prefix(topK)
                    .map { Prediction(label: $0.identifier, confidence: $0.confidence) }

                continuation.resume(returning: top)
            }

            request.imageCropAndScaleOption = .centerCrop

            let handler = VNImageRequestHandler(cgImage: cgImage)
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum ClassifierError: Error { case invalidImage, modelLoadFailed }
```

---

## Step 2 — Object detection with Vision (~15 min)

```swift
// ObjectDetector.swift
import Vision
import UIKit

actor ObjectDetector {

    struct Detection: Sendable, Identifiable {
        let id = UUID()
        let label: String
        let confidence: Float
        let boundingBox: CGRect   // normalized 0-1 coordinates
    }

    private let model: VNCoreMLModel

    init() throws {
        // Use YOLOv3 for object detection (download from Apple's model gallery)
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let mlModel = try YOLOv3(configuration: config).model
        self.model = try VNCoreMLModel(for: mlModel)
    }

    func detect(in image: UIImage, minimumConfidence: Float = 0.5) async throws -> [Detection] {
        guard let cgImage = image.cgImage else { throw ClassifierError.invalidImage }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNCoreMLRequest(model: model) { request, error in
                if let error { continuation.resume(throwing: error); return }

                let detections = (request.results as? [VNRecognizedObjectObservation])?
                    .filter { $0.confidence >= minimumConfidence }
                    .compactMap { obs -> Detection? in
                        guard let label = obs.labels.first?.identifier else { return nil }
                        return Detection(
                            label: label,
                            confidence: obs.confidence,
                            boundingBox: obs.boundingBox  // Vision coords (origin bottom-left)
                        )
                    } ?? []

                continuation.resume(returning: detections)
            }

            request.imageCropAndScaleOption = .scaleFill

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
            do { try handler.perform([request]) }
            catch { continuation.resume(throwing: error) }
        }
    }
}
```

---

## Step 3 — Live camera inference (~15 min)

```swift
// LiveInferenceViewModel.swift
import Vision
import CoreVideo
import Observation

// Process camera frames for real-time inference
// ★ Key: run inference off the main thread; update UI on main

@MainActor
@Observable
final class LiveInferenceViewModel {

    var predictions: [ImageClassifier.Prediction] = []
    var fps: Double = 0
    var isProcessing = false

    private let classifier: ImageClassifier? = try? ImageClassifier()
    private var lastFrameTime: Date = .now
    private var frameCount = 0

    // Called from camera's sample buffer delegate
    func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard !isProcessing else { return }  // Drop frames while processing
        guard let classifier else { return }

        isProcessing = true

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self,
                  let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            else { return }

            let ciImage = CIImage(cvImageBuffer: imageBuffer)
            let context = CIContext()
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
            let uiImage = UIImage(cgImage: cgImage)

            do {
                let results = try await classifier.classify(uiImage, topK: 3)
                await MainActor.run { [weak self] in
                    self?.predictions = results
                    self?.updateFPS()
                    self?.isProcessing = false
                }
            } catch {
                await MainActor.run { [weak self] in self?.isProcessing = false }
            }
        }
    }

    private func updateFPS() {
        frameCount += 1
        let elapsed = Date.now.timeIntervalSince(lastFrameTime)
        if elapsed >= 1.0 {
            fps = Double(frameCount) / elapsed
            frameCount = 0
            lastFrameTime = .now
        }
    }
}

// SwiftUI overlay showing predictions
struct PredictionsOverlay: View {
    let predictions: [ImageClassifier.Prediction]
    let fps: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "%.1f fps", fps))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            ForEach(predictions, id: \.label) { pred in
                HStack(spacing: 8) {
                    Text(pred.label)
                        .font(.caption.bold())
                    Spacer()
                    Text(String(format: "%.0f%%", pred.confidence * 100))
                        .font(.caption.monospacedDigit())
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(Double(pred.confidence) * 0.4),
                            in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}
```

---

## ★ Challenge: Convert TFLite model to Core ML

```bash
# Python: coremltools
pip install coremltools tensorflow

import coremltools as ct
import tensorflow as tf

# Load TFLite model
tflite_path = "model.tflite"

# Convert to Core ML
mlmodel = ct.converters.TensorFlow.convert(
    tf.lite.Interpreter(model_path=tflite_path),
    inputs=[ct.ImageType(name="input", shape=(1, 224, 224, 3))],
    classifier_config=ct.ClassifierConfig(class_labels)
)
mlmodel.save("model.mlmodel")
```

---

# Tutorial 20 — On-Device LLM (Offline)
## Build: LocalAI — a private, offline AI assistant
**Time:** 60 min | **Swift 6 + SwiftUI** | **Topics:** Apple Intelligence, Core ML, llama.cpp bridging, streaming inference

---

## The landscape (2025)

```
Option 1: Apple Intelligence (iOS 18.1+, requires A17 Pro / M-series)
  - Foundation Models framework (WWDC 2025)
  - Gemma 2B equivalent, private, on-device
  - Tool calling, structured output support
  - No API key, no network, no data leaves device

Option 2: llama.cpp via Swift Package
  - Run Llama 3.2 1B, Phi-3 Mini, Gemma 2B on older devices
  - More control, more model variety
  - Manual memory management

Option 3: Core ML converted models
  - Convert ONNX/TFLite → Core ML
  - Uses ANE for best performance
  - Models must be <4GB for device storage
```

---

## Step 1 — Foundation Models (Apple Intelligence) approach (~20 min)

```swift
// FoundationModelsSession.swift
// Requires: iOS 18.1+, Foundation Models framework (WWDC 2025)
import FoundationModels   // New in iOS 18.1

@MainActor
@Observable
final class LocalLLMViewModel {

    var messages: [ChatMessage] = []
    var isGenerating = false
    var streamingOutput = ""
    var modelState: ModelState = .checking

    enum ModelState {
        case checking
        case available
        case unavailable(String)
    }

    struct ChatMessage: Identifiable, Sendable {
        let id = UUID()
        let role: Role
        let content: String
        enum Role { case user, assistant }
    }

    private var session: LanguageModelSession?

    func initialize() async {
        // Check if on-device model is available
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            session = LanguageModelSession()  // creates a session with system model
            modelState = .available
        case .unavailable(let reason):
            modelState = .unavailable(reason.localizedDescription)
        }
    }

    func send(_ userMessage: String) async {
        guard let session, !isGenerating else { return }

        messages.append(ChatMessage(role: .user, content: userMessage))
        isGenerating = true
        streamingOutput = ""

        let prompt = Prompt(userMessage)

        do {
            // Streaming response — token by token
            let stream = session.streamResponse(to: prompt)
            for try await partial in stream {
                streamingOutput = partial.text
            }
            // Final message
            messages.append(ChatMessage(role: .assistant, content: streamingOutput))
            streamingOutput = ""
        } catch {
            messages.append(ChatMessage(role: .assistant, content: "Error: \(error.localizedDescription)"))
        }

        isGenerating = false
    }

    // Tool calling (structured output)
    func sendWithTools(_ message: String) async throws -> String {
        guard let session else { throw LLMError.modelUnavailable }

        // Define a tool the model can call
        struct WeatherTool: Tool {
            static let name = "get_weather"
            static let description = "Get current weather for a city"

            struct Parameters: Codable {
                let city: String
            }

            func call(parameters: Parameters) async throws -> String {
                return "72°F, sunny in \(parameters.city)"
            }
        }

        let sessionWithTools = LanguageModelSession(tools: [WeatherTool()])
        return try await sessionWithTools.respond(to: Prompt(message)).text
    }
}

enum LLMError: Error { case modelUnavailable }
```

---

## Step 2 — llama.cpp fallback for older devices (~20 min)

```swift
// LlamaCppBridge.swift
// Requires: swift-llama package (https://github.com/ggerganov/llama.cpp)
// Or use MLX-Swift for M-series Macs

import Foundation

// Pattern: wrap C library in Swift actor
actor LlamaCppModel {

    private var context: OpaquePointer?    // llama_context*
    private let modelPath: URL

    init(modelPath: URL) {
        self.modelPath = modelPath
    }

    func load() throws {
        // llama_backend_init(false)
        // context = llama_new_context_with_model(...)
        // (actual implementation requires llama.cpp C bindings)
        print("Loading model from \(modelPath.lastPathComponent)")
        // For tutorial purposes, simulate the interface
    }

    func generate(prompt: String, maxTokens: Int = 256) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task.detached(priority: .userInitiated) {
                // In real implementation:
                // 1. Tokenize the prompt
                // 2. Run llama_eval for each token
                // 3. Sample next token
                // 4. Decode token to string
                // 5. yield to stream

                // Simulation:
                let words = "I am a local AI model running entirely on your device. No internet required. Your data stays private.".components(separatedBy: " ")
                for word in words {
                    try? await Task.sleep(for: .milliseconds(50))
                    continuation.yield(word + " ")
                }
                continuation.finish()
            }
        }
    }

    deinit {
        // llama_free(context)
        // llama_backend_free()
    }
}

// Model download manager
actor ModelDownloader {

    enum DownloadState: Sendable {
        case notDownloaded
        case downloading(progress: Double)
        case ready(url: URL)
        case failed(Error)
    }

    private(set) var state: DownloadState = .notDownloaded

    // Llama 3.2 1B GGUF (~670MB) — quantized for mobile
    let modelURL = URL(string: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf")!

    func download() async {
        state = .downloading(progress: 0)
        let destination = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("llama-3.2-1b.gguf")

        if FileManager.default.fileExists(atPath: destination.path) {
            state = .ready(url: destination)
            return
        }

        // Download with progress using URLSession
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config)

        do {
            let (asyncBytes, response) = try await session.bytes(from: modelURL)
            let totalBytes = response.expectedContentLength

            var downloadedData = Data()
            var downloadedBytes: Int64 = 0

            for try await byte in asyncBytes {
                downloadedData.append(byte)
                downloadedBytes += 1

                if downloadedBytes % 1_000_000 == 0 {  // update every 1MB
                    let progress = Double(downloadedBytes) / Double(totalBytes)
                    state = .downloading(progress: progress)
                }
            }

            try downloadedData.write(to: destination)
            state = .ready(url: destination)
        } catch {
            state = .failed(error)
        }
    }
}
```

---

## Step 3 — SwiftUI chat interface (~15 min)

```swift
// LocalAIChatView.swift
import SwiftUI

struct LocalAIChatView: View {
    @State private var vm = LocalLLMViewModel()
    @State private var inputText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Model status badge
                modelStatusBadge

                // Chat messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(vm.messages) { msg in
                                ChatBubble(message: msg)
                                    .id(msg.id)
                            }
                            // Streaming output
                            if vm.isGenerating && !vm.streamingOutput.isEmpty {
                                ChatBubble(message: .init(role: .assistant, content: vm.streamingOutput + "▌"))
                            }
                        }
                        .padding()
                    }
                    .onChange(of: vm.messages.count) { _, _ in
                        if let last = vm.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                // Input bar
                HStack(spacing: 12) {
                    TextField("Ask anything (private)…", text: $inputText, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(12)
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 20))

                    Button {
                        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        inputText = ""
                        Task { await vm.send(text) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(inputText.isEmpty || vm.isGenerating ? .secondary : .accentColor)
                    }
                    .disabled(inputText.isEmpty || vm.isGenerating)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .navigationTitle("Local AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                        .help("Private — no data leaves your device")
                }
            }
        }
        .task { await vm.initialize() }
    }

    @ViewBuilder
    private var modelStatusBadge: some View {
        switch vm.modelState {
        case .checking:
            Label("Checking model…", systemImage: "cpu")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        case .available:
            Label("On-device model ready", systemImage: "checkmark.shield.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .padding(8)
        case .unavailable(let reason):
            Label(reason, systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(8)
        }
    }
}

struct ChatBubble: View {
    let message: LocalLLMViewModel.ChatMessage

    var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer() }
            Text(message.content)
                .padding(12)
                .background(
                    isUser ? Color.accentColor : Color(.systemGray5),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .foregroundStyle(isUser ? .white : .primary)
                .frame(maxWidth: 300, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer() }
        }
    }
}
```

---

## ★ Challenge: Structured output with type safety

```swift
// Foundation Models supports @Generable for type-safe structured responses
@Generable
struct RecipeResponse {
    let title: String
    let ingredients: [String]
    let steps: [String]
    let prepTimeMinutes: Int
}

// Generate structured data instead of free text
let recipe: RecipeResponse = try await session.respond(
    to: "Give me a simple pasta recipe",
    generating: RecipeResponse.self
)
// recipe.title, recipe.ingredients etc are fully typed
```

---

## Key takeaways for all three advanced tutorials

**ARKit:** Raycasting against detected planes is the foundation of all AR interaction. Master this before 3D object placement.

**Core ML:** The `Vision` framework handles all the image preprocessing boilerplate. Raw Core ML requires you to manage pixel buffers manually.

**On-device LLM:** Apple Intelligence requires explicit user opt-in on the device. Always have a graceful fallback (cloud API or "feature requires iPhone 15 Pro").

---

## Final follow-up questions across all tutorials

- *How do you handle the ANE (Neural Engine) not being available?* (`computeUnits = .cpuAndGPU` as fallback)
- *What's the difference between ARWorldTracking and ARImageTracking?* (World = 3D space; Image = flat 2D target tracking)
- *Can you run a 7B parameter model on iPhone?* (Not yet practically — 4B params quantized to 4-bit ≈ 2GB, feasible on 6GB RAM devices)
- *How does Foundation Models protect privacy?* (All inference runs in a secure on-device sandbox; Apple states no data is logged or sent to servers)
