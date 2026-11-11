import Foundation
import Network

// MARK: - Pure HTTP Request Parser (Testable)

nonisolated struct ParsedHTTPRequest: Sendable, Equatable {
    let method: String
    let rawTarget: String
    let path: String
    let queryItems: [String: String]
    let headers: [String: String]
    let body: Data
    let totalConsumedBytes: Int
}

nonisolated enum HTTPRequestParser {
    private static let headerDelimiter = Data("\r\n\r\n".utf8)

    /// Attempts to parse a single complete HTTP/1.1 request from the front of `buffer`.
    /// Returns `nil` if more bytes are needed (e.g., headers incomplete or `Content-Length` body not yet fully received).
    static func parse(from buffer: Data) -> ParsedHTTPRequest? {
        guard let headerEndRange = buffer.range(of: headerDelimiter) else {
            return nil
        }

        let headerData = buffer[buffer.startIndex..<headerEndRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerString.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0]).uppercased()
        let rawTargetSub = parts[1]
        let rawTarget = String(rawTargetSub)

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStartIndex = headerEndRange.upperBound
        let totalRequiredBytes = (bodyStartIndex - buffer.startIndex) + max(0, contentLength)
        guard buffer.count >= totalRequiredBytes else {
            return nil
        }

        let bodyEndIndex = buffer.index(bodyStartIndex, offsetBy: max(0, contentLength))
        let body = contentLength > 0 ? buffer.subdata(in: bodyStartIndex..<bodyEndIndex) : Data()

        // Fast-path target & query string slicing (avoids URLComponents heap allocations)
        let path: String
        var queryItems: [String: String] = [:]
        if let qIndex = rawTargetSub.firstIndex(of: "?") {
            path = String(rawTargetSub[..<qIndex])
            let querySub = rawTargetSub[rawTargetSub.index(after: qIndex)...]
            var pairStart = querySub.startIndex
            while pairStart < querySub.endIndex {
                let pairEnd = querySub[pairStart...].firstIndex(of: "&") ?? querySub.endIndex
                let pair = querySub[pairStart..<pairEnd]
                if let eq = pair.firstIndex(of: "=") {
                    let k = String(pair[..<eq])
                    let v = String(pair[pair.index(after: eq)...])
                    if !k.isEmpty {
                        queryItems[k] = v
                    }
                }
                if pairEnd == querySub.endIndex { break }
                pairStart = querySub.index(after: pairEnd)
            }
        } else {
            path = rawTarget
        }

        return ParsedHTTPRequest(
            method: method,
            rawTarget: rawTarget,
            path: path,
            queryItems: queryItems,
            headers: headers,
            body: body,
            totalConsumedBytes: totalRequiredBytes
        )
    }

    static func isCaptivePortalProbe(path: String) -> Bool {
        switch path {
        case "/generate_204", "/gen_204", "/hotspot-detect.html", "/library/test/success.html", "/ncsi.txt", "/connecttest.txt":
            return true
        default:
            return false
        }
    }
}

// MARK: - Embedded Low-Latency HTTP + MJPEG + Touch + Captive Portal Server

nonisolated final class StreamingWebServer: @unchecked Sendable {
    private struct FrameWaiter {
        let id: UUID
        let connection: NWConnection
        let clientLastIndex: UInt64
        let keepAlive: Bool
        let remainingBuffer: Data
        let timeoutWorkItem: DispatchWorkItem
    }

    private struct MJPEGClient {
        let id: UUID
        let connection: NWConnection
        var lastSentIndex: UInt64
        var isSending: Bool
    }

    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "com.aeronlabs.idisplays.webserver", qos: .userInteractive)
    private let stateLock = NSLock()
    private var activeConnections: [UUID: NWConnection] = [:]
    private var frameWaiters: [UUID: FrameWaiter] = [:]
    private var mjpegClients: [UUID: MJPEGClient] = [:]

    private(set) var port: UInt16 = 8080
    private(set) var isRunning: Bool = false

    private var _pipeline: ScreenCapturePipeline?
    private var _config: WirelessDisplayConfig = WirelessDisplayConfig()
    private var _touchEnabled: Bool = true
    private var _captivePortalBypass: Bool = true
    private var _cachedHTMLData: Data = Data()

    var onTouchEvent: (@Sendable (TouchEventPayload) -> Void)?
    var onLog: (@Sendable (DiagnosticEntry.Level, String) -> Void)?

    private static let captive204Response = Data(
        "HTTP/1.1 204 No Content\r\nContent-Type: text/plain\r\nContent-Length: 0\r\nCache-Control: no-store, no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: keep-alive\r\n\r\n".utf8
    )

    private static let captiveHTMLBody = Data("<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>".utf8)
    private static let mjpegPartTrailer = Data("\r\n".utf8)

    func updateConfiguration(
        config: WirelessDisplayConfig,
        touchEnabled: Bool,
        captivePortalBypass: Bool
    ) {
        let renderedHTML = Data(WebClientHTML.render(
            config: config,
            touchEnabled: touchEnabled && config.allowTouch
        ).utf8)
        stateLock.lock()
        _config = config
        _touchEnabled = touchEnabled
        _captivePortalBypass = captivePortalBypass
        _cachedHTMLData = renderedHTML
        stateLock.unlock()
    }

    func updatePipeline(_ pipeline: ScreenCapturePipeline?) {
        stateLock.lock()
        _pipeline = pipeline
        stateLock.unlock()
    }

    /// Called directly from `ScreenCapturePipeline` on `sampleQueue` as soon as a new JPEG frame is ready.
    func notifyNewFrame(data: Data, index: UInt64) {
        guard isRunning else { return }
        serverQueue.async { [weak self] in
            self?.flushWaitingClients(jpegData: data, index: index)
        }
    }

    func start(
        port: UInt16,
        pipeline: ScreenCapturePipeline?,
        config: WirelessDisplayConfig,
        touchEnabled: Bool,
        captivePortalBypass: Bool
    ) throws {
        stop()

        self.port = port
        let renderedHTML = Data(WebClientHTML.render(
            config: config,
            touchEnabled: touchEnabled && config.allowTouch
        ).utf8)

        stateLock.lock()
        self._pipeline = pipeline
        self._config = config
        self._touchEnabled = touchEnabled
        self._captivePortalBypass = captivePortalBypass
        self._cachedHTMLData = renderedHTML
        stateLock.unlock()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.serviceClass = .interactiveVideo
        if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 15
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "StreamingWebServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid TCP port \(port)"])
        }

        let newListener = try NWListener(using: params, on: nwPort)
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isRunning = true
                self.onLog?(.success, "HTTP & stream server listening on port \(port)")
            case .failed(let error):
                self.isRunning = false
                self.onLog?(.error, "Web server failed: \(error.localizedDescription)")
            case .cancelled:
                self.isRunning = false
            default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        newListener.start(queue: serverQueue)
        self.listener = newListener
    }

    func stop() {
        isRunning = false
        listener?.cancel()
        listener = nil

        stateLock.lock()
        let currentConnections = Array(activeConnections.values)
        activeConnections.removeAll()
        let waiters = Array(frameWaiters.values)
        frameWaiters.removeAll()
        mjpegClients.removeAll()
        stateLock.unlock()

        for waiter in waiters {
            waiter.timeoutWorkItem.cancel()
        }
        for conn in currentConnections {
            conn.cancel()
        }
    }

    private func snapshotConfig() -> (
        pipeline: ScreenCapturePipeline?,
        config: WirelessDisplayConfig,
        touchEnabled: Bool,
        captivePortalBypass: Bool,
        htmlData: Data
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (_pipeline, _config, _touchEnabled, _captivePortalBypass, _cachedHTMLData)
    }

    // MARK: - Connection & HTTP Loop

    private func handleNewConnection(_ connection: NWConnection) {
        let connId = UUID()
        stateLock.lock()
        activeConnections[connId] = connection
        stateLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.removeConnection(connId)
            default:
                break
            }
        }

        connection.start(queue: serverQueue)
        receiveLoop(on: connection, id: connId, buffer: Data())
    }

    private func removeConnection(_ id: UUID) {
        stateLock.lock()
        activeConnections.removeValue(forKey: id)
        let waiter = frameWaiters.removeValue(forKey: id)
        mjpegClients.removeValue(forKey: id)
        stateLock.unlock()
        waiter?.timeoutWorkItem.cancel()
    }

    private func receiveLoop(on connection: NWConnection, id: UUID, buffer: Data) {
        if let request = HTTPRequestParser.parse(from: buffer) {
            let remaining = buffer.subdata(in: (buffer.startIndex + request.totalConsumedBytes)..<buffer.endIndex)
            routeHTTPRequest(request, on: connection, id: id, remainingBuffer: remaining)
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data, !data.isEmpty {
                accumulated.append(data)
            }

            if let request = HTTPRequestParser.parse(from: accumulated) {
                let remaining = accumulated.subdata(in: (accumulated.startIndex + request.totalConsumedBytes)..<accumulated.endIndex)
                self.routeHTTPRequest(request, on: connection, id: id, remainingBuffer: remaining)
                return
            }

            if isComplete || error != nil || accumulated.count > 262_144 {
                connection.cancel()
                self.removeConnection(id)
                return
            }

            self.receiveLoop(on: connection, id: id, buffer: accumulated)
        }
    }

    private func routeHTTPRequest(
        _ request: ParsedHTTPRequest,
        on connection: NWConnection,
        id: UUID,
        remainingBuffer: Data
    ) {
        let snapshot = snapshotConfig()
        let keepAlive = (request.headers["connection"]?.lowercased() != "close")

        // 1. Fast-path Touch / Mouse / Scroll API endpoint
        if request.path == "/api/touch" {
            if snapshot.touchEnabled {
                if let type = request.queryItems["t"],
                   let x = Double(request.queryItems["x"] ?? ""),
                   let y = Double(request.queryItems["y"] ?? "") {
                    let dx = request.queryItems["dx"].flatMap(Double.init)
                    let dy = request.queryItems["dy"].flatMap(Double.init)
                    onTouchEvent?(TouchEventPayload(type: type, x: x, y: y, deltaX: dx, deltaY: dy))
                } else if !request.body.isEmpty,
                          let payload = try? JSONDecoder().decode(TouchEventPayload.self, from: request.body) {
                    onTouchEvent?(payload)
                }
            }
            if keepAlive {
                connection.send(content: Self.captive204Response, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error != nil {
                        connection.cancel()
                        self.removeConnection(id)
                    } else {
                        self.receiveLoop(on: connection, id: id, buffer: remainingBuffer)
                    }
                })
            } else {
                sendRawResponse(
                    status: "204 No Content",
                    contentType: "text/plain",
                    body: Data(),
                    keepAlive: false,
                    on: connection,
                    id: id,
                    remainingBuffer: remainingBuffer
                )
            }
            return
        }

        // 2. Single JPEG frame endpoint (/frame.jpg?last=42&wait=1)
        if request.path == "/frame.jpg" {
            let clientLastIndex = UInt64(request.queryItems["last"] ?? "0") ?? 0
            let shouldWait = request.queryItems["wait"] == "1"
            let frame = snapshot.pipeline?.latestFrame()

            if let frame, clientLastIndex > 0, frame.index == clientLastIndex {
                if shouldWait {
                    enqueueFrameWaiter(
                        id: id,
                        connection: connection,
                        clientLastIndex: clientLastIndex,
                        keepAlive: keepAlive,
                        remainingBuffer: remainingBuffer
                    )
                } else {
                    sendRawResponse(
                        status: "204 No Content",
                        contentType: "text/plain",
                        extraHeaders: ["X-Frame-Index: \(frame.index)"],
                        body: Data(),
                        keepAlive: keepAlive,
                        on: connection,
                        id: id,
                        remainingBuffer: remainingBuffer
                    )
                }
                return
            }

            if let jpegData = frame?.data {
                sendRawResponse(
                    status: "200 OK",
                    contentType: "image/jpeg",
                    extraHeaders: ["X-Frame-Index: \(frame?.index ?? 1)"],
                    body: jpegData,
                    keepAlive: keepAlive,
                    on: connection,
                    id: id,
                    remainingBuffer: remainingBuffer
                )
            } else {
                sendRawResponse(
                    status: "503 Service Unavailable",
                    contentType: "text/plain",
                    body: Data("No frame ready".utf8),
                    keepAlive: keepAlive,
                    on: connection,
                    id: id,
                    remainingBuffer: remainingBuffer
                )
            }
            return
        }

        // 3. Captive Portal Bypass / Detection endpoints (Android / Tesla / Apple / Windows)
        if snapshot.captivePortalBypass && HTTPRequestParser.isCaptivePortalProbe(path: request.path) {
            if request.path == "/generate_204" || request.path == "/gen_204" {
                sendRawResponse(
                    status: "204 No Content",
                    contentType: "text/plain",
                    body: Data(),
                    keepAlive: keepAlive,
                    on: connection,
                    id: id,
                    remainingBuffer: remainingBuffer
                )
            } else {
                sendRawResponse(
                    status: "200 OK",
                    contentType: "text/html; charset=utf-8",
                    body: Self.captiveHTMLBody,
                    keepAlive: keepAlive,
                    on: connection,
                    id: id,
                    remainingBuffer: remainingBuffer
                )
            }
            return
        }

        // 4. Multipart MJPEG stream endpoint (/stream.mjpg)
        if request.path == "/stream.mjpg" {
            startMJPEGStream(on: connection, id: id)
            return
        }

        // 5. Status JSON endpoint
        if request.path == "/api/status" {
            let c = snapshot.config
            let body = Data("{\"ok\":true,\"width\":\(c.preset.width),\"height\":\(c.preset.height),\"fps\":\(c.fps)}".utf8)
            sendRawResponse(
                status: "200 OK",
                contentType: "application/json",
                body: body,
                keepAlive: keepAlive,
                on: connection,
                id: id,
                remainingBuffer: remainingBuffer
            )
            return
        }

        // 6. Main Viewer Web UI (served from pre-rendered cache)
        let htmlBody = snapshot.htmlData.isEmpty
            ? Data(WebClientHTML.render(config: snapshot.config, touchEnabled: snapshot.touchEnabled && snapshot.config.allowTouch).utf8)
            : snapshot.htmlData
        sendRawResponse(
            status: "200 OK",
            contentType: "text/html; charset=utf-8",
            body: htmlBody,
            keepAlive: keepAlive,
            on: connection,
            id: id,
            remainingBuffer: remainingBuffer
        )
    }

    // MARK: - Event-Driven Long-Poll Waiters & MJPEG Push

    private func enqueueFrameWaiter(
        id: UUID,
        connection: NWConnection,
        clientLastIndex: UInt64,
        keepAlive: Bool,
        remainingBuffer: Data
    ) {
        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let expired = self.frameWaiters.removeValue(forKey: id)
            self.stateLock.unlock()

            guard let expired else { return }
            self.sendRawResponse(
                status: "204 No Content",
                contentType: "text/plain",
                extraHeaders: ["X-Frame-Index: \(expired.clientLastIndex)"],
                body: Data(),
                keepAlive: expired.keepAlive,
                on: expired.connection,
                id: expired.id,
                remainingBuffer: expired.remainingBuffer
            )
        }

        let waiter = FrameWaiter(
            id: id,
            connection: connection,
            clientLastIndex: clientLastIndex,
            keepAlive: keepAlive,
            remainingBuffer: remainingBuffer,
            timeoutWorkItem: timeoutItem
        )

        stateLock.lock()
        let previous = frameWaiters.updateValue(waiter, forKey: id)
        stateLock.unlock()
        previous?.timeoutWorkItem.cancel()

        // Hold up to 550ms when screen is static; wakes in <1ms as soon as any pixel changes.
        serverQueue.asyncAfter(deadline: .now() + 0.55, execute: timeoutItem)
    }

    private func flushWaitingClients(jpegData: Data, index: UInt64) {
        stateLock.lock()
        let waiters: [FrameWaiter]
        if frameWaiters.isEmpty {
            waiters = []
        } else {
            waiters = Array(frameWaiters.values)
            frameWaiters.removeAll()
        }
        let mjpegIds = Array(mjpegClients.keys)
        stateLock.unlock()

        for waiter in waiters {
            waiter.timeoutWorkItem.cancel()
            sendRawResponse(
                status: "200 OK",
                contentType: "image/jpeg",
                extraHeaders: ["X-Frame-Index: \(index)"],
                body: jpegData,
                keepAlive: waiter.keepAlive,
                on: waiter.connection,
                id: waiter.id,
                remainingBuffer: waiter.remainingBuffer
            )
        }

        for clientId in mjpegIds {
            sendMJPEGFrameIfReady(id: clientId, jpegData: jpegData, index: index)
        }
    }

    // MARK: - Continuous Event-Driven MJPEG Push Stream

    private func startMJPEGStream(on connection: NWConnection, id: UUID) {
        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: multipart/x-mixed-replace; boundary=frameboundary",
            "Cache-Control: no-store, no-cache, must-revalidate, max-age=0",
            "Pragma: no-cache",
            "Connection: close",
            "\r\n"
        ].joined(separator: "\r\n")

        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                self?.removeConnection(id)
                return
            }
            self.stateLock.lock()
            self.mjpegClients[id] = MJPEGClient(id: id, connection: connection, lastSentIndex: 0, isSending: false)
            let initialFrame = self._pipeline?.latestFrame()
            self.stateLock.unlock()

            if let data = initialFrame?.data, let idx = initialFrame?.index {
                self.sendMJPEGFrameIfReady(id: id, jpegData: data, index: idx)
            }
        })
    }

    private func sendMJPEGFrameIfReady(id: UUID, jpegData: Data, index: UInt64) {
        guard isRunning else { return }

        stateLock.lock()
        guard var client = mjpegClients[id], !client.isSending, client.lastSentIndex != index else {
            stateLock.unlock()
            return
        }
        client.isSending = true
        client.lastSentIndex = index
        mjpegClients[id] = client
        let connection = client.connection
        stateLock.unlock()

        let partHeader = Data("--frameboundary\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpegData.count)\r\n\r\n".utf8)
        connection.batch {
            connection.send(content: partHeader, isComplete: false, completion: .idempotent)
            connection.send(content: jpegData, isComplete: false, completion: .idempotent)
            connection.send(content: Self.mjpegPartTrailer, isComplete: false, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil {
                    connection.cancel()
                    self.removeConnection(id)
                    return
                }
                self.stateLock.lock()
                guard var updated = self.mjpegClients[id] else {
                    self.stateLock.unlock()
                    return
                }
                updated.isSending = false
                self.mjpegClients[id] = updated
                let latest = self._pipeline?.latestFrame()
                self.stateLock.unlock()

                if let latestData = latest?.data, let latestIdx = latest?.index, latestIdx != updated.lastSentIndex {
                    self.sendMJPEGFrameIfReady(id: id, jpegData: latestData, index: latestIdx)
                }
            })
        }
    }

    private func sendRawResponse(
        status: String,
        contentType: String,
        extraHeaders: [String] = [],
        body: Data,
        keepAlive: Bool,
        on connection: NWConnection,
        id: UUID,
        remainingBuffer: Data
    ) {
        var headerLines = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store, no-cache, must-revalidate, max-age=0",
            "Access-Control-Allow-Origin: *",
            "Connection: \(keepAlive ? "keep-alive" : "close")"
        ]
        headerLines.append(contentsOf: extraHeaders)
        headerLines.append("\r\n")

        let headerData = Data(headerLines.joined(separator: "\r\n").utf8)

        if body.isEmpty {
            connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil || !keepAlive {
                    connection.cancel()
                    self.removeConnection(id)
                } else {
                    self.receiveLoop(on: connection, id: id, buffer: remainingBuffer)
                }
            })
        } else {
            // Use NWConnection.batch to send header + body without copying the JPEG Data buffer.
            connection.batch {
                connection.send(content: headerData, isComplete: false, completion: .idempotent)
                connection.send(content: body, isComplete: false, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error != nil || !keepAlive {
                        connection.cancel()
                        self.removeConnection(id)
                    } else {
                        self.receiveLoop(on: connection, id: id, buffer: remainingBuffer)
                    }
                })
            }
        }
    }
}
