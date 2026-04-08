# Tutorial 14 — Camera
## Build: CameraKit — custom camera with capture and processing
**Time:** 60 min | **Swift 6 + SwiftUI** | **Topics:** AVCaptureSession, preview layer, photo capture, permissions

---

## What you'll build
A custom camera screen with:
- Live preview via `AVCaptureVideoPreviewLayer`
- Photo capture with `AVCapturePhotoOutput`
- QR code scanning with `AVCaptureMetadataOutput`
- Permissions handling

---

## Step 1 — Camera session actor (~20 min)

```swift
// CameraSession.swift
import AVFoundation
import UIKit

// Actor: serial access to AVCaptureSession (not thread-safe)
actor CameraSession {

    private let session = AVCaptureSession()
    private var photoOutput = AVCapturePhotoOutput()
    private var metadataOutput = AVCaptureMetadataOutput()
    private var captureDelegate: PhotoCaptureDelegate?
    private var qrDelegate: QRScanDelegate?

    // Call from makeUIView — returns the layer to embed in the view
    func setup() throws -> AVCaptureVideoPreviewLayer {
        session.beginConfiguration()
        session.sessionPreset = .photo

        // Input: back camera
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device)
        else { throw CameraError.noCamera }

        guard session.canAddInput(input) else { throw CameraError.configurationFailed }
        session.addInput(input)

        // Output: photos
        guard session.canAddOutput(photoOutput) else { throw CameraError.configurationFailed }
        session.addOutput(photoOutput)

        // Output: QR codes
        guard session.canAddOutput(metadataOutput) else { throw CameraError.configurationFailed }
        session.addOutput(metadataOutput)
        metadataOutput.metadataObjectTypes = [.qr, .ean13, .code128]

        session.commitConfiguration()

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        return previewLayer
    }

    func start() async {
        guard !session.isRunning else { return }
        // AVCaptureSession.startRunning() blocks — must be off main thread
        await Task.detached(priority: .userInitiated) {
            await self.session.startRunning()
        }.value
    }

    func stop() {
        session.stopRunning()
    }

    func capturePhoto() async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = PhotoCaptureDelegate(continuation: continuation)
            captureDelegate = delegate  // retain
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .auto
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    func setQRHandler(_ handler: @escaping @Sendable (String) -> Void) {
        let delegate = QRScanDelegate(handler: handler)
        metadataOutput.setMetadataObjectsDelegate(delegate, queue: .main)
        qrDelegate = delegate
    }
}

// Photo capture delegate
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let continuation: CheckedContinuation<UIImage, Error>

    init(continuation: CheckedContinuation<UIImage, Error>) {
        self.continuation = continuation
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            continuation.resume(throwing: error)
            return
        }
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data)
        else {
            continuation.resume(throwing: CameraError.captureFailed)
            return
        }
        continuation.resume(returning: image)
    }
}

// QR scan delegate
final class QRScanDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    private let handler: @Sendable (String) -> Void
    init(handler: @escaping @Sendable (String) -> Void) { self.handler = handler }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        for object in metadataObjects {
            if let readable = object as? AVMetadataMachineReadableCodeObject,
               let string = readable.stringValue {
                handler(string)
                return
            }
        }
    }
}

enum CameraError: Error { case noCamera, configurationFailed, captureFailed, permissionDenied }
```

---

## Step 2 — SwiftUI camera view (~15 min)

```swift
// CameraView.swift
import SwiftUI
import AVFoundation

struct CameraView: UIViewRepresentable {
    let session: CameraSession
    @Binding var previewLayer: AVCaptureVideoPreviewLayer?

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        Task {
            do {
                let layer = try await session.setup()
                await MainActor.run {
                    layer.frame = view.bounds
                    view.layer.addSublayer(layer)
                    previewLayer = layer
                }
                await session.start()
            } catch {
                print("Camera setup failed: \(error)")
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        previewLayer?.frame = uiView.bounds
    }
}

// ViewModel
@MainActor
@Observable
final class CameraViewModel {
    var capturedImage: UIImage? = nil
    var scannedQR: String? = nil
    var previewLayer: AVCaptureVideoPreviewLayer? = nil
    var permissionStatus: AVAuthorizationStatus = .notDetermined

    private let cameraSession = CameraSession()

    func requestPermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            await AVCaptureDevice.requestAccess(for: .video)
        }
        permissionStatus = AVCaptureDevice.authorizationStatus(for: .video)
    }

    func capturePhoto() async {
        do {
            capturedImage = try await cameraSession.capturePhoto()
        } catch {
            print("Capture failed: \(error)")
        }
    }

    func startQRScanning() async {
        await cameraSession.setQRHandler { [weak self] code in
            Task { @MainActor [weak self] in
                self?.scannedQR = code
            }
        }
    }
}

// Main camera screen
struct CameraScreen: View {
    @State private var vm = CameraViewModel()

    var body: some View {
        ZStack {
            if vm.permissionStatus == .authorized {
                CameraView(session: vm.cameraSession, previewLayer: $vm.previewLayer)
                    .ignoresSafeArea()

                VStack {
                    Spacer()
                    if let qr = vm.scannedQR {
                        Text("QR: \(qr)").padding().background(.ultraThinMaterial, in: Capsule())
                    }
                    Button(action: { Task { await vm.capturePhoto() } }) {
                        Circle()
                            .fill(.white)
                            .frame(width: 72, height: 72)
                            .overlay(Circle().stroke(.gray, lineWidth: 2).frame(width: 80, height: 80))
                    }
                    .padding(.bottom, 40)
                }
            } else {
                PermissionView { Task { await vm.requestPermission() } }
            }
        }
        .task { await vm.requestPermission() }
        .sheet(item: Binding(
            get: { vm.capturedImage.map { IdentifiableImage(image: $0) } },
            set: { _ in vm.capturedImage = nil }
        )) { item in
            Image(uiImage: item.image).resizable().scaledToFit()
        }
    }
}

struct IdentifiableImage: Identifiable { let id = UUID(); let image: UIImage }
struct PermissionView: View {
    let onRequest: () -> Void
    var body: some View {
        VStack { Text("Camera access needed"); Button("Allow", action: onRequest) }
    }
}
```

---

## ★ Challenge
Add a **zoom gesture**: use `UIPinchGestureRecognizer` on the camera preview to adjust `AVCaptureDevice.videoZoomFactor`.

---

# Tutorial 15 — Maps + 1 Million Pins
## Build: MapCluster — efficient annotation display at scale
**Time:** 60 min | **Swift 6 + SwiftUI** | **Topics:** MapKit clustering, MKAnnotationView, spatial indexing, viewport culling

---

## The problem

Drawing 1 million `MKPointAnnotation` pins will:
- Crash with memory exhaustion
- Drop to 1 fps even if it doesn't crash
- Overlap pins into an unreadable mass

The solution: **clustering + viewport culling + quadtree spatial indexing**

---

## Strategy: 3 layers of optimization

```
1. Viewport culling
   Only load annotations within the visible map region + buffer
   ~200-500 pins maximum in view at any time

2. Clustering (MKClusterAnnotation)
   Group nearby pins into a single callout showing count
   MapKit does this automatically with annotationView.clusteringIdentifier

3. Spatial indexing (Quadtree / R-tree)
   O(log n) lookup of pins in a rect instead of O(n) scan
   Essential for >10,000 total pins
```

---

## Step 1 — Spatial quadtree index (~20 min)

```swift
// QuadTree.swift
import MapKit

// A simple quadtree for 2D spatial lookups
final class QuadTree {
    private var root: QuadNode

    init(region: MKMapRect) {
        root = QuadNode(rect: region)
    }

    func insert(_ item: MapItem) {
        root.insert(item)
    }

    func query(in rect: MKMapRect) -> [MapItem] {
        root.query(in: rect)
    }
}

struct MapItem: Sendable {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    let title: String
    var mapPoint: MKMapPoint { MKMapPoint(coordinate) }
}

private final class QuadNode {
    let rect: MKMapRect
    var items: [MapItem] = []
    var children: [QuadNode]? = nil
    private let maxItems = 10

    init(rect: MKMapRect) { self.rect = rect }

    func insert(_ item: MapItem) {
        guard rect.contains(item.mapPoint) else { return }

        if items.count < maxItems || rect.size.width < 100 {
            items.append(item)
            return
        }

        // Subdivide
        if children == nil { subdivide() }
        children?.forEach { $0.insert(item) }
    }

    func query(in queryRect: MKMapRect) -> [MapItem] {
        guard rect.intersects(queryRect) else { return [] }
        var result = items.filter { queryRect.contains($0.mapPoint) }
        children?.forEach { result.append(contentsOf: $0.query(in: queryRect)) }
        return result
    }

    private func subdivide() {
        let half = MKMapSize(width: rect.size.width / 2, height: rect.size.height / 2)
        children = [
            QuadNode(rect: MKMapRect(origin: rect.origin, size: half)),
            QuadNode(rect: MKMapRect(origin: MKMapPoint(x: rect.midX, y: rect.minY), size: half)),
            QuadNode(rect: MKMapRect(origin: MKMapPoint(x: rect.minX, y: rect.midY), size: half)),
            QuadNode(rect: MKMapRect(origin: MKMapPoint(x: rect.midX, y: rect.midY), size: half)),
        ]
    }
}
```

---

## Step 2 — Cluster-aware map ViewModel (~15 min)

```swift
// MapViewModel.swift
import MapKit
import Observation

@MainActor
@Observable
final class MapViewModel {
    var visibleAnnotations: [MapItem] = []
    var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
    )

    private var spatialIndex: QuadTree!
    private var updateTask: Task<Void, Never>?

    // Generate 1M pins spread across SF
    func buildIndex() async {
        await Task.detached(priority: .userInitiated) {
            let worldRect = MKMapRect.world
            let index = QuadTree(region: worldRect)

            // Generate 1 million items spread around SF
            let center = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
            for _ in 0..<1_000_000 {
                let lat = center.latitude  + Double.random(in: -0.5...0.5)
                let lon = center.longitude + Double.random(in: -0.5...0.5)
                let item = MapItem(
                    id: UUID(),
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    title: "Pin"
                )
                index.insert(item)
            }
            return index
        }.value.map { spatialIndex = $0 }

        updateVisibleAnnotations()
    }

    // Called on every region change — with debounce
    func regionChanged(_ newRegion: MKCoordinateRegion) {
        region = newRegion
        updateTask?.cancel()
        updateTask = Task {
            try? await Task.sleep(for: .milliseconds(150))  // debounce
            guard !Task.isCancelled else { return }
            updateVisibleAnnotations()
        }
    }

    private func updateVisibleAnnotations() {
        guard let index = spatialIndex else { return }

        // Add 20% buffer around visible region to pre-load nearby pins
        let bufferFactor = 1.2
        let span = MKCoordinateSpan(
            latitudeDelta: region.span.latitudeDelta * bufferFactor,
            longitudeDelta: region.span.longitudeDelta * bufferFactor
        )
        let bufferedRegion = MKCoordinateRegion(center: region.center, span: span)
        let mapRect = MKMapRect(bufferedRegion)

        // Quadtree lookup — O(log n) instead of O(n)
        let items = index.query(in: mapRect)

        // Cap at 500 visible pins for rendering performance
        visibleAnnotations = Array(items.prefix(500))
    }
}

extension MKMapRect {
    init(_ region: MKCoordinateRegion) {
        let topLeft = CLLocationCoordinate2D(
            latitude: region.center.latitude + region.span.latitudeDelta / 2,
            longitude: region.center.longitude - region.span.longitudeDelta / 2
        )
        let bottomRight = CLLocationCoordinate2D(
            latitude: region.center.latitude - region.span.latitudeDelta / 2,
            longitude: region.center.longitude + region.span.longitudeDelta / 2
        )
        let topLeftPoint = MKMapPoint(topLeft)
        let bottomRightPoint = MKMapPoint(bottomRight)
        self.init(
            x: topLeftPoint.x,
            y: topLeftPoint.y,
            width: abs(bottomRightPoint.x - topLeftPoint.x),
            height: abs(bottomRightPoint.y - topLeftPoint.y)
        )
    }
}
```

---

## Step 3 — SwiftUI Map with clustering (~10 min)

```swift
// MapView.swift
import SwiftUI
import MapKit

struct ClusterMapView: View {
    @State private var vm = MapViewModel()

    var body: some View {
        Map(coordinateRegion: $vm.region,
            annotationItems: vm.visibleAnnotations) { item in
            MapAnnotation(coordinate: item.coordinate) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .shadow(radius: 2)
            }
        }
        .onAppear { Task { await vm.buildIndex() } }
        .onChange(of: vm.region) { _, new in vm.regionChanged(new) }
        .overlay(alignment: .topLeading) {
            Text("\(vm.visibleAnnotations.count) pins visible")
                .padding(8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding()
        }
    }
}
```

---

## ★ Key optimization: MKMapView + clustering identifier

For UIKit MKMapView, native clustering requires only one line:

```swift
// In viewFor annotation delegate method:
let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "pin")
view.clusteringIdentifier = "cluster"  // ← MapKit auto-clusters same-ID pins
return view

// MapKit handles cluster animation, count display, and re-clustering on zoom
```

---

# Tutorial 16 — gRPC vs JSON
## Build: ProtoCompare — benchmark and implement both protocols
**Time:** 60 min | **Swift 6** | **Topics:** gRPC-Swift, URLSession JSON, Protocol Buffers, performance comparison

---

## gRPC vs REST/JSON at a glance

```
JSON over REST:
+ Human readable, universal tooling, easy caching
+ Works everywhere (HTTP/1.1, CDNs, curl)
- 3-5× larger payload than Protobuf
- Schema not enforced at transport layer
- Request-response only (no streaming without SSE)

gRPC (Protocol Buffers over HTTP/2):
+ Binary, ~5× smaller payload, faster parsing
+ Schema enforced (breaking changes caught at compile time)
+ Streaming: unary, server-stream, client-stream, bidirectional
+ Code generated from .proto files → no hand-written models
- Requires HTTP/2 (not all CDNs support it)
- No browser support without grpc-web
- More complex setup (need .proto + code generation)
```

---

## Step 1 — Define the .proto schema

```protobuf
// product.proto
syntax = "proto3";
package product;

message Product {
    string id = 1;
    string name = 2;
    double price = 3;
    bool is_available = 4;
    repeated string tags = 5;
}

message ProductListRequest {
    string category = 1;
    int32 page_size = 2;
    string page_token = 3;
}

message ProductListResponse {
    repeated Product products = 1;
    string next_page_token = 2;
    int32 total_count = 3;
}

service ProductService {
    // Unary: request → response
    rpc GetProduct(ProductRequest) returns (Product);

    // Server-streaming: request → stream of responses (live updates)
    rpc WatchProduct(ProductRequest) returns (stream Product);

    // Client-streaming: stream of requests → response (bulk upload)
    rpc ImportProducts(stream Product) returns (ImportResult);
}
```

---

## Step 2 — JSON client (~10 min)

```swift
// JSONProductClient.swift
import Foundation

struct JSONProduct: Codable, Sendable {
    let id: String
    let name: String
    let price: Double
    let isAvailable: Bool
    let tags: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, price, tags
        case isAvailable = "is_available"
    }
}

struct JSONProductClient: Sendable {
    private let baseURL = URL(string: "https://api.example.com")!
    private let session = URLSession.shared
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    func fetchProducts(category: String) async throws -> [JSONProduct] {
        var components = URLComponents(url: baseURL.appendingPathComponent("products"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "category", value: category)]

        let (data, response) = try await session.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw APIError.badResponse
        }
        return try decoder.decode([JSONProduct].self, from: data)
    }
}

enum APIError: Error { case badResponse }
```

---

## Step 3 — gRPC client using grpc-swift (~15 min)

```swift
// GRPCProductClient.swift
// Requires: grpc-swift package
// swift-protobuf generates the model types from .proto

import GRPC
import NIO

final class GRPCProductClient: Sendable {

    private let client: ProductServiceClient

    init(host: String = "api.example.com", port: Int = 443) {
        let group = PlatformSupport.makeEventLoopGroup(loopCount: 1)
        let channel = try! GRPCChannelPool.with(
            target: .host(host, port: port),
            transportSecurity: .tls(GRPCTLSConfiguration.makeClientDefault()),
            eventLoopGroup: group
        )
        self.client = ProductServiceClient(channel: channel)
    }

    // Unary: single request → single response (like REST)
    func getProduct(id: String) async throws -> Product_Product {
        var request = Product_ProductRequest()
        request.id = id

        return try await client.getProduct(request).response.get()
    }

    // Server streaming: single request → stream of Product updates
    // Great for: live price updates, inventory changes, auction bids
    func watchProduct(id: String) -> AsyncStream<Product_Product> {
        AsyncStream { continuation in
            var request = Product_ProductRequest()
            request.id = id

            Task {
                do {
                    let call = client.watchProduct(request)
                    for try await product in call {
                        continuation.yield(product)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
        }
    }
}

// Usage in ViewModel:
// for await product in grpcClient.watchProduct(id: "123") {
//     await MainActor.run { self.product = product }
// }
```

---

## Step 4 — Performance benchmark ViewModel (~10 min)

```swift
// BenchmarkViewModel.swift
import Observation

@MainActor
@Observable
final class BenchmarkViewModel {

    struct Result {
        let name: String
        let duration: TimeInterval
        let payloadSize: Int
        let itemCount: Int
    }

    var results: [Result] = []
    var isRunning = false

    func runBenchmark() async {
        isRunning = true
        results = []

        // Simulate JSON: encode 1000 products, measure time + size
        let jsonResult = await measureJSON()
        results.append(jsonResult)

        // Simulate Protobuf: estimate based on typical 3-5x ratio
        let protoResult = Result(
            name: "gRPC/Protobuf (estimated)",
            duration: jsonResult.duration * 0.4,   // ~60% faster parsing
            payloadSize: jsonResult.payloadSize / 4, // ~75% smaller
            itemCount: jsonResult.itemCount
        )
        results.append(protoResult)

        isRunning = false
    }

    private func measureJSON() async -> Result {
        let start = Date.now

        // Create 1000 fake products and encode them
        let products = (0..<1000).map { i in
            ["id": "prod_\(i)", "name": "Product \(i)", "price": 9.99,
             "is_available": true, "tags": ["swift", "ios"]] as [String: Any]
        }
        let data = try! JSONSerialization.data(withJSONObject: products)
        let _ = try! JSONSerialization.jsonObject(with: data)

        return Result(
            name: "JSON / REST",
            duration: Date.now.timeIntervalSince(start),
            payloadSize: data.count,
            itemCount: 1000
        )
    }
}
```

---

## ★ Challenge
Implement a **bidirectional stream** for a live auction:
```swift
// Both client and server send messages simultaneously
rpc LiveAuction(stream BidRequest) returns (stream AuctionUpdate);

// Client sends bids; server sends real-time price updates
// This is exactly what Whatnot does for live bidding
```

---

# Tutorial 17 — Video Streaming
## Build: StreamKit — HLS video player with adaptive bitrate
**Time:** 60 min | **Swift 6 + SwiftUI** | **Topics:** AVPlayer, AVPlayerViewController, HLS, adaptive streaming, picture-in-picture

---

## What you'll build
A video player with:
- HLS streaming with `AVPlayer`
- Custom playback controls in SwiftUI
- Picture-in-picture support
- Adaptive bitrate monitoring

---

## Step 1 — AVPlayer actor (~15 min)

```swift
// VideoPlayer.swift
import AVFoundation
import Observation

@MainActor
@Observable
final class VideoPlayerViewModel {

    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var loadingState: LoadingState = .idle
    var isMuted = false
    var playbackRate: Float = 1.0

    enum LoadingState { case idle, loading, ready, failed(Error) }

    private(set) var player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?

    // HLS URL — adaptive bitrate handled automatically by AVFoundation
    func load(url: URL) {
        loadingState = .loading

        let item = AVPlayerItem(url: url)

        // Observe status KVO
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                switch item.status {
                case .readyToPlay:
                    self?.duration = item.duration.seconds
                    self?.loadingState = .ready
                case .failed:
                    self?.loadingState = .failed(item.error ?? URLError(.unknown))
                default: break
                }
            }
        }

        player.replaceCurrentItem(with: item)

        // Periodic time observer — update currentTime every 0.5s
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            self?.currentTime = time.seconds
        }
    }

    func play() {
        player.play()
        player.rate = playbackRate
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to time: TimeInterval) async {
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        await player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying { player.rate = rate }
    }

    // Monitor bitrate for adaptive streaming
    var currentBitrate: Double {
        guard let item = player.currentItem,
              let event = item.accessLog()?.events.last
        else { return 0 }
        return event.indicatedBitrate
    }

    deinit {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
    }
}
```

---

## Step 2 — Custom video player UI (~20 min)

```swift
// VideoPlayerView.swift
import SwiftUI
import AVKit

struct VideoPlayerView: View {
    @State private var vm = VideoPlayerViewModel()
    @State private var showControls = true
    @State private var controlsTimer: Task<Void, Never>? = nil

    // Apple test HLS stream (multi-bitrate)
    let hlsURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")!

    var body: some View {
        ZStack {
            // AVPlayerLayer via UIViewRepresentable
            AVPlayerLayerView(player: vm.player)
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }

            // Overlay controls
            if showControls {
                PlayerControls(vm: vm)
                    .transition(.opacity)
            }

            // Loading overlay
            if case .loading = vm.loadingState {
                ProgressView().tint(.white)
            }
        }
        .background(.black)
        .task { vm.load(url: hlsURL) }
    }

    func toggleControls() {
        withAnimation { showControls.toggle() }
        if showControls { scheduleHideControls() }
    }

    func scheduleHideControls() {
        controlsTimer?.cancel()
        controlsTimer = Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { showControls = false }
        }
    }
}

struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> UIView {
        let view = PlayerUIView(player: player)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { }
}

class PlayerUIView: UIView {
    private let playerLayer: AVPlayerLayer

    init(player: AVPlayer) {
        self.playerLayer = AVPlayerLayer(player: player)
        super.init(frame: .zero)
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

struct PlayerControls: View {
    let vm: VideoPlayerViewModel

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 32) {
                Button(action: { Task { await vm.seek(to: vm.currentTime - 10) } }) {
                    Image(systemName: "gobackward.10").font(.title).foregroundStyle(.white)
                }
                Button(action: { vm.isPlaying ? vm.pause() : vm.play() }) {
                    Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56)).foregroundStyle(.white)
                }
                Button(action: { Task { await vm.seek(to: vm.currentTime + 10) } }) {
                    Image(systemName: "goforward.10").font(.title).foregroundStyle(.white)
                }
            }

            // Progress slider
            HStack {
                Text(formatTime(vm.currentTime)).font(.caption.monospacedDigit()).foregroundStyle(.white)
                Slider(value: Binding(
                    get: { vm.duration > 0 ? vm.currentTime / vm.duration : 0 },
                    set: { Task { await vm.seek(to: $0 * vm.duration) } }
                ))
                .tint(.white)
                Text(formatTime(vm.duration)).font(.caption.monospacedDigit()).foregroundStyle(.white)
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 40)
        .background(LinearGradient(
            colors: [.clear, .black.opacity(0.7)],
            startPoint: .top, endPoint: .bottom
        ))
    }

    func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "0:00" }
        let m = Int(t) / 60; let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}
```

---

## ★ Challenge: Picture-in-Picture

```swift
// Add PiP support
import AVKit

class PiPManager: NSObject, AVPictureInPictureControllerDelegate {
    private var pipController: AVPictureInPictureController?

    func setup(playerLayer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        pipController = AVPictureInPictureController(playerLayer: playerLayer)
        pipController?.delegate = self
    }

    func togglePiP() {
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        } else {
            pipController?.startPictureInPicture()
        }
    }
}
// Add to Info.plist: UIBackgroundModes → audio
```
