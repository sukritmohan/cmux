import Foundation

/// Thread-safe registry tracking which bridge connections are subscribed to
/// cell-based screen output for each terminal surface.
///
/// Unlike BridgePTYStream which forwards raw PTY bytes, BridgeCellStream reads
/// the rendered cell grid from Ghostty's surface via `ghostty_surface_read_screen()`
/// and sends binary cell frames to subscribers. This allows mobile clients to
/// render terminal content without needing a VT parser.
///
/// Polling timer fires at 60fps. Each tick reads the screen, diffs against the
/// previous frame, and sends only dirty rows to minimize bandwidth.
final class BridgeCellStream: @unchecked Sendable {
    static let shared = BridgeCellStream()

    /// Maps surface UUIDs to the set of connection UUIDs subscribed to cell output.
    private var subscriptions: [UUID: Set<UUID>] = [:]

    /// Per-surface previous frame for diffing. Keyed by surface UUID.
    private var previousFrames: [UUID: PreviousFrame] = [:]

    /// Per-surface polling timers. Keyed by surface UUID.
    private var timers: [UUID: DispatchSourceTimer] = [:]

    /// Guards all mutable state.
    private let lock = NSLock()

    /// Serial queue for timer callbacks.
    private let pollQueue = DispatchQueue(label: "com.cmux.cell-stream-poll")

    /// Polling interval: ~60fps.
    private static let pollInterval: TimeInterval = 0.016

    /// Per-cell binary size in bytes.
    private static let cellSize = 20

    /// Observer token for `.bridgeSurfaceClosed` notifications.
    private var surfaceClosedObserver: NSObjectProtocol?

    /// Cached state from the previous frame for a surface.
    private struct PreviousFrame {
        var cells: [ghostty_cell_s]
        var cols: Int
        var rows: Int
        var cursorCol: UInt8
        var cursorRow: UInt8
        var cursorVisible: Bool
    }

    private init() {
        surfaceClosedObserver = NotificationCenter.default.addObserver(
            forName: .bridgeSurfaceClosed, object: nil, queue: nil
        ) { [weak self] notification in
            guard let self,
                  let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            self.removeAllSubscriptions(forSurface: surfaceId)
        }
    }

    deinit {
        if let observer = surfaceClosedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    /// Subscribes a connection to cell output for a terminal surface.
    ///
    /// On first subscriber: dispatches to main to read the initial screen snapshot,
    /// sends it as a full frame (0x01), and starts the polling timer.
    func addSubscriber(connectionId: UUID, surfaceId: UUID) {
        lock.lock()
        subscriptions[surfaceId, default: []].insert(connectionId)
        let isFirstSubscriber = subscriptions[surfaceId]?.count == 1
        lock.unlock()

        if isFirstSubscriber {
            startPolling(for: surfaceId)
        }
    }

    /// Unsubscribes a connection from cell output for a terminal surface.
    func removeSubscriber(connectionId: UUID, surfaceId: UUID) {
        lock.lock()
        subscriptions[surfaceId]?.remove(connectionId)
        let isEmpty = subscriptions[surfaceId]?.isEmpty == true
        if isEmpty {
            subscriptions.removeValue(forKey: surfaceId)
        }
        lock.unlock()

        if isEmpty {
            stopPolling(for: surfaceId)
        }
    }

    /// Removes all cell subscriptions for a disconnected connection.
    func removeAllSubscriptions(forConnection connectionId: UUID) {
        lock.lock()
        var emptiedSurfaces: [UUID] = []
        for surfaceId in Array(subscriptions.keys) {
            subscriptions[surfaceId]?.remove(connectionId)
            if subscriptions[surfaceId]?.isEmpty == true {
                subscriptions.removeValue(forKey: surfaceId)
                emptiedSurfaces.append(surfaceId)
            }
        }
        lock.unlock()

        for surfaceId in emptiedSurfaces {
            stopPolling(for: surfaceId)
        }
    }

    /// Removes all subscriptions for a destroyed surface.
    func removeAllSubscriptions(forSurface surfaceId: UUID) {
        lock.lock()
        subscriptions.removeValue(forKey: surfaceId)
        previousFrames.removeValue(forKey: surfaceId)
        let timer = timers.removeValue(forKey: surfaceId)
        lock.unlock()

        timer?.cancel()
    }

    /// Returns the set of connection UUIDs subscribed to a surface's cell output.
    func subscribedConnectionIds(for surfaceId: UUID) -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions[surfaceId] ?? []
    }

    // MARK: - Polling

    /// Starts the polling timer for a surface. Dispatches an initial full snapshot
    /// immediately, then polls at 60fps for changes.
    private func startPolling(for surfaceId: UUID) {
        // Send initial full snapshot on main thread (need surface access).
        DispatchQueue.main.async { [weak self] in
            self?.readAndSendFullSnapshot(surfaceId: surfaceId)
        }

        // Start repeating timer for diffs.
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(
            deadline: .now() + BridgeCellStream.pollInterval,
            repeating: BridgeCellStream.pollInterval
        )
        timer.setEventHandler { [weak self] in
            self?.pollTick(surfaceId: surfaceId)
        }

        lock.lock()
        timers[surfaceId]?.cancel()
        timers[surfaceId] = timer
        lock.unlock()

        timer.resume()
    }

    /// Stops the polling timer for a surface and cleans up cached state.
    private func stopPolling(for surfaceId: UUID) {
        lock.lock()
        let timer = timers.removeValue(forKey: surfaceId)
        previousFrames.removeValue(forKey: surfaceId)
        lock.unlock()

        timer?.cancel()
    }

    /// Reads the full screen and broadcasts as a 0x01 full snapshot frame.
    /// Must be called on the main thread.
    @MainActor
    private func readAndSendFullSnapshot(surfaceId: UUID) {
        guard let panel = resolveTerminalPanel(surfaceId: surfaceId),
              let surface = panel.surface.surface else {
            NSLog("[BridgeCellStream] Cannot read screen: surface %@ not found", surfaceId.uuidString)
            return
        }

        let size = ghostty_surface_size(surface)
        let cols = Int(size.columns)
        let rows = Int(size.rows)
        let total = cols * rows
        guard total > 0 else { return }

        // Read cells from Ghostty surface.
        var cellBuf = [ghostty_cell_s](repeating: ghostty_cell_s(), count: total)
        let written = ghostty_surface_read_screen(surface, &cellBuf, total)
        guard written == total else { return }

        // Read cursor state.
        var cursorCol: UInt16 = 0
        var cursorRow: UInt16 = 0
        _ = ghostty_surface_cursor_pos(surface, &cursorCol, &cursorRow)
        let cursorVis = ghostty_surface_cursor_visible(surface)

        // Cache the frame for future diffing.
        let cursorColU8 = UInt8(min(cursorCol, 255))
        let cursorRowU8 = UInt8(min(cursorRow, 255))

        lock.lock()
        previousFrames[surfaceId] = PreviousFrame(
            cells: cellBuf,
            cols: cols,
            rows: rows,
            cursorCol: cursorColU8,
            cursorRow: cursorRowU8,
            cursorVisible: cursorVis
        )
        lock.unlock()

        // Build frame type 0x01: full snapshot.
        let frame = buildFullSnapshotFrame(
            channelId: surfaceId.channelId,
            cols: cols,
            rows: rows,
            cursorCol: cursorColU8,
            cursorRow: cursorRowU8,
            cursorVisible: cursorVis,
            cells: cellBuf
        )

        broadcastCellFrame(surfaceId: surfaceId, frame: frame)
    }

    /// Timer callback: reads the screen, diffs against previous, sends updates.
    /// Dispatches the screen read to the main thread.
    private func pollTick(surfaceId: UUID) {
        DispatchQueue.main.async { [weak self] in
            self?.readAndDiff(surfaceId: surfaceId)
        }
    }

    /// Reads the screen on main thread, diffs against cached frame, and sends
    /// dirty-row (0x02) or cursor-only (0x03) updates.
    @MainActor
    private func readAndDiff(surfaceId: UUID) {
        guard let panel = resolveTerminalPanel(surfaceId: surfaceId),
              let surface = panel.surface.surface else { return }

        let size = ghostty_surface_size(surface)
        let cols = Int(size.columns)
        let rows = Int(size.rows)
        let total = cols * rows
        guard total > 0 else { return }

        // Read current cells.
        var cellBuf = [ghostty_cell_s](repeating: ghostty_cell_s(), count: total)
        let written = ghostty_surface_read_screen(surface, &cellBuf, total)
        guard written == total else { return }

        // Read cursor state.
        var cursorCol: UInt16 = 0
        var cursorRow: UInt16 = 0
        _ = ghostty_surface_cursor_pos(surface, &cursorCol, &cursorRow)
        let cursorVis = ghostty_surface_cursor_visible(surface)
        let cursorColU8 = UInt8(min(cursorCol, 255))
        let cursorRowU8 = UInt8(min(cursorRow, 255))

        lock.lock()
        let prev = previousFrames[surfaceId]
        lock.unlock()

        // If dimensions changed or no previous frame, send full snapshot.
        guard let prev, prev.cols == cols, prev.rows == rows else {
            lock.lock()
            previousFrames[surfaceId] = PreviousFrame(
                cells: cellBuf, cols: cols, rows: rows,
                cursorCol: cursorColU8, cursorRow: cursorRowU8, cursorVisible: cursorVis
            )
            lock.unlock()

            let frame = buildFullSnapshotFrame(
                channelId: surfaceId.channelId,
                cols: cols, rows: rows,
                cursorCol: cursorColU8, cursorRow: cursorRowU8, cursorVisible: cursorVis,
                cells: cellBuf
            )
            broadcastCellFrame(surfaceId: surfaceId, frame: frame)
            return
        }

        // Find dirty rows by comparing cell data.
        var dirtyRows: [Int] = []
        for row in 0..<rows {
            let start = row * cols
            let end = start + cols
            let rowSlice = cellBuf[start..<end]
            let prevSlice = prev.cells[start..<end]
            if !rowsEqual(Array(rowSlice), Array(prevSlice)) {
                dirtyRows.append(row)
            }
        }

        let cursorChanged = cursorColU8 != prev.cursorCol ||
                           cursorRowU8 != prev.cursorRow ||
                           cursorVis != prev.cursorVisible

        // Nothing changed.
        if dirtyRows.isEmpty && !cursorChanged { return }

        // Update cached frame.
        lock.lock()
        previousFrames[surfaceId] = PreviousFrame(
            cells: cellBuf, cols: cols, rows: rows,
            cursorCol: cursorColU8, cursorRow: cursorRowU8, cursorVisible: cursorVis
        )
        lock.unlock()

        if dirtyRows.isEmpty && cursorChanged {
            // Cursor-only update (0x03).
            let frame = buildCursorOnlyFrame(
                channelId: surfaceId.channelId,
                cursorCol: cursorColU8, cursorRow: cursorRowU8, cursorVisible: cursorVis
            )
            broadcastCellFrame(surfaceId: surfaceId, frame: frame)
        } else {
            // Dirty rows update (0x02).
            let frame = buildDirtyRowsFrame(
                channelId: surfaceId.channelId,
                cols: cols,
                cursorCol: cursorColU8, cursorRow: cursorRowU8, cursorVisible: cursorVis,
                dirtyRows: dirtyRows,
                cells: cellBuf
            )
            broadcastCellFrame(surfaceId: surfaceId, frame: frame)
        }
    }

    // MARK: - Frame Building

    /// Builds a full snapshot frame (type 0x01).
    private func buildFullSnapshotFrame(
        channelId: UInt32,
        cols: Int, rows: Int,
        cursorCol: UInt8, cursorRow: UInt8, cursorVisible: Bool,
        cells: [ghostty_cell_s]
    ) -> Data {
        let totalCells = cols * rows
        // 4 (channel) + 1 (type) + 2 (cols) + 2 (rows) + 1 (curCol) + 1 (curRow) + 1 (curVis) + cells
        var frame = Data(capacity: 12 + totalCells * BridgeCellStream.cellSize)

        // Channel ID (4 bytes LE).
        var leChannel = channelId.littleEndian
        frame.append(Data(bytes: &leChannel, count: 4))

        // Frame type.
        frame.append(0x01)

        // Cols, rows (2 bytes LE each).
        var leCols = UInt16(cols).littleEndian
        var leRows = UInt16(rows).littleEndian
        frame.append(Data(bytes: &leCols, count: 2))
        frame.append(Data(bytes: &leRows, count: 2))

        // Cursor.
        frame.append(cursorCol)
        frame.append(cursorRow)
        frame.append(cursorVisible ? 1 : 0)

        // Cell data.
        for cell in cells {
            appendCell(&frame, cell)
        }

        return frame
    }

    /// Builds a dirty rows frame (type 0x02).
    private func buildDirtyRowsFrame(
        channelId: UInt32,
        cols: Int,
        cursorCol: UInt8, cursorRow: UInt8, cursorVisible: Bool,
        dirtyRows: [Int],
        cells: [ghostty_cell_s]
    ) -> Data {
        // 4 (channel) + 1 (type) + 2 (cols) + 1 + 1 + 1 + per-row (2 + cols*20) + 2 (sentinel)
        let perRowSize = 2 + cols * BridgeCellStream.cellSize
        var frame = Data(capacity: 10 + dirtyRows.count * perRowSize + 2)

        var leChannel = channelId.littleEndian
        frame.append(Data(bytes: &leChannel, count: 4))

        frame.append(0x02)

        var leCols = UInt16(cols).littleEndian
        frame.append(Data(bytes: &leCols, count: 2))

        frame.append(cursorCol)
        frame.append(cursorRow)
        frame.append(cursorVisible ? 1 : 0)

        for row in dirtyRows {
            var leRow = UInt16(row).littleEndian
            frame.append(Data(bytes: &leRow, count: 2))

            let start = row * cols
            for x in 0..<cols {
                appendCell(&frame, cells[start + x])
            }
        }

        // Sentinel.
        var sentinel: UInt16 = 0xFFFF
        frame.append(Data(bytes: &sentinel, count: 2))

        return frame
    }

    /// Builds a cursor-only frame (type 0x03).
    private func buildCursorOnlyFrame(
        channelId: UInt32,
        cursorCol: UInt8, cursorRow: UInt8, cursorVisible: Bool
    ) -> Data {
        var frame = Data(capacity: 8)

        var leChannel = channelId.littleEndian
        frame.append(Data(bytes: &leChannel, count: 4))

        frame.append(0x03)
        frame.append(cursorCol)
        frame.append(cursorRow)
        frame.append(cursorVisible ? 1 : 0)

        return frame
    }

    /// Appends a single cell's 20-byte binary encoding to the frame.
    private func appendCell(_ frame: inout Data, _ cell: ghostty_cell_s) {
        var leCp = cell.codepoint.littleEndian
        frame.append(Data(bytes: &leCp, count: 4))
        frame.append(cell.grapheme_len)
        frame.append(cell.fg_r)
        frame.append(cell.fg_g)
        frame.append(cell.fg_b)
        frame.append(cell.fg_is_default ? 1 : 0)
        frame.append(cell.bg_r)
        frame.append(cell.bg_g)
        frame.append(cell.bg_b)
        frame.append(cell.bg_is_default ? 1 : 0)
        frame.append(cell.ul_r)
        frame.append(cell.ul_g)
        frame.append(cell.ul_b)
        frame.append(cell.ul_is_default ? 1 : 0)
        frame.append(cell.underline_style)
        var leFlags = cell.flags.littleEndian
        frame.append(Data(bytes: &leFlags, count: 2))
    }

    // MARK: - Diffing

    /// Compares two rows of cells for equality.
    private func rowsEqual(_ a: [ghostty_cell_s], _ b: [ghostty_cell_s]) -> Bool {
        guard a.count == b.count else { return false }
        return a.withUnsafeBytes { aBytes in
            b.withUnsafeBytes { bBytes in
                aBytes.elementsEqual(bBytes)
            }
        }
    }

    // MARK: - Broadcasting

    /// Sends a binary cell frame to all subscribed connections.
    private func broadcastCellFrame(surfaceId: UUID, frame: Data) {
        let subscriberIds = subscribedConnectionIds(for: surfaceId)
        guard !subscriberIds.isEmpty else { return }

        BridgeServer.shared.broadcastBinaryToConnections(
            connectionIds: subscriberIds,
            data: frame
        )
    }
}
