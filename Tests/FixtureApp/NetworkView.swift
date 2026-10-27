// The fixture's Network tab (M4b live tests): one kind of traffic per button, to the live tests' server on
// 127.0.0.1:8765 (HTTP) and 8766 (WebSocket).
import SwiftUI
import WebKit

struct NetworkView: View {
    @State private var result = "none"
    @State private var query = ""
    @State private var search: Task<Void, Never>?
    private let base = "http://127.0.0.1:8765"

    var body: some View {
        List {
            Text("Result: \(result)").accessibilityIdentifier("netResult")
            Button("Slow API") { get("/slow") { result = "slow \($0)" } }
            Button("Fast API") { get("/fast") { result = "fast \($0)" } }
            Button("Medium API") { get("/medium") { result = "medium \($0)" } }
            Button("Failing API") { get("/fail") { _ in } }
            Button("Analytics only") { get("/metrics/event") { _ in } }
            Button("Raw socket") { rawSocket() }
            Button("Open WebSocket") { webSocket() }
            Button("Copy code") { UIPasteboard.general.string = "FIXTURE-CODE-2026" }
            Button("Dead network button") {}
            TextField("Search", text: $query)
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("search")
                .onChange(of: query) { _, q in
                    search?.cancel()
                    search = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if !Task.isCancelled { get("/fast?q=" + encoded) { _ in } }
                    }
                }
            FixtureWeb(url: URL(string: base + "/page")!).frame(height: 120)
        }
        .navigationTitle("Network")
    }

    func get(_ path: String, done: @escaping @MainActor (Int) -> Void) {
        URLSession.shared.dataTask(with: URL(string: base + path)!) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            Task { @MainActor in done(status) }
        }.resume()
    }

    /// A slow request over a BSD socket: a stack URLSession's logs never see (spec: the activity layer's case).
    func rawSocket() {
        DispatchQueue.global().async {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(8765).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            let request = "GET /slow HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
            _ = request.withCString { send(fd, $0, strlen($0), 0) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = recv(fd, &buffer, buffer.count, 0)
            close(fd)
        }
    }

    func webSocket() {
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8766/")!)
        task.resume()
        func next() { task.receive { if case .success = $0 { next() } } }
        next()
    }
}

struct FixtureWeb: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.load(URLRequest(url: url))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
