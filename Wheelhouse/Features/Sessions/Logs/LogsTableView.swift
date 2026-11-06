import SwiftUI
import UIKit
import WheelhouseKit
import WheelhouseUI

/// Everything the table needs to render; value type so SwiftUI diffing stays cheap.
struct LogsDisplaySettings: Equatable {
    var wrap = true
    var timestamps = false
    var fontSize: CGFloat = 12
    var query = ""
    var useRegex = false
    var currentLineID: Int?
}

/// UITableView-backed log list (rows are cheap labels; only visible rows are built, so 20k lines scroll smoothly).
/// With wrap off the table sits inside a horizontal scroll view sized to the longest line.
struct LogsTableView: UIViewRepresentable {
    let lines: [LogLine]
    let settings: LogsDisplaySettings
    let matcher: LogMatcher?
    let follow: Bool
    let scrollTarget: LogsModel.ScrollTarget?
    var onUserScrolledAway: () -> Void
    var onReachedBottom: () -> Void
    var onSelect: (LogLine) -> Void

    func makeUIView(context: Context) -> LogsContainerView {
        let v = LogsContainerView()
        v.onUserScrolledAway = onUserScrolledAway
        v.onReachedBottom = onReachedBottom
        v.onSelect = onSelect
        return v
    }

    func updateUIView(_ v: LogsContainerView, context: Context) {
        v.onUserScrolledAway = onUserScrolledAway
        v.onReachedBottom = onReachedBottom
        v.onSelect = onSelect
        v.apply(lines: lines, settings: settings, matcher: matcher, follow: follow, scrollTarget: scrollTarget)
    }
}

final class LogsContainerView: UIView, UITableViewDataSource, UITableViewDelegate, UIScrollViewDelegate {
    var onUserScrolledAway: () -> Void = {}
    var onReachedBottom: () -> Void = {}
    var onSelect: (LogLine) -> Void = { _ in }

    private let hScroll = UIScrollView()
    private let table = UITableView(frame: .zero, style: .plain)
    private var lines: [LogLine] = []
    private var settings = LogsDisplaySettings()
    private var matcher: LogMatcher?
    private var follow = true
    private var lastToken = 0
    private var charWidth: CGFloat = 7
    private var maxChars = 0
    private var programmaticScroll = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        hScroll.delegate = self
        hScroll.showsVerticalScrollIndicator = false
        hScroll.alwaysBounceVertical = false
        hScroll.isDirectionalLockEnabled = true
        addSubview(hScroll)
        table.dataSource = self
        table.delegate = self
        table.separatorStyle = .none
        table.register(LogCell.self, forCellReuseIdentifier: LogCell.reuse)
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 20
        table.backgroundColor = .clear
        table.keyboardDismissMode = .interactive
        table.contentInsetAdjustmentBehavior = .automatic
        hScroll.addSubview(table)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Apply

    func apply(lines new: [LogLine], settings newSettings: LogsDisplaySettings, matcher newMatcher: LogMatcher?, follow newFollow: Bool, scrollTarget: LogsModel.ScrollTarget?) {
        let settingsChanged = newSettings != settings
        let oldFirst = lines.first?.id, oldCount = lines.count
        let wasFollowing = follow
        let anchor = captureAnchor()

        let fontChanged = newSettings.fontSize != settings.fontSize
        let old = lines
        lines = new
        settings = newSettings
        matcher = newMatcher
        follow = newFollow
        if fontChanged || charWidth <= 0 {
            charWidth = ("M" as NSString).size(withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)]).width
        }

        let appendOnly = !settingsChanged && oldFirst == new.first?.id && new.count >= oldCount && oldCount > 0
        // A full ring buffer drops lines at the front while new ones arrive at the back. Reloading the whole table for
        // that (10 times a second on a chatty pod) is what used to burn CPU: delete the dropped rows and insert the new ones.
        var frontDrop: Int?
        if !appendOnly, !settingsChanged, wasFollowing, newFollow, oldCount > 0, let first = new.first?.id, first != oldFirst,
           let k = old.firstIndex(where: { $0.id == first }), k > 0, oldCount - k <= new.count,
           old[oldCount - 1].id == new[oldCount - k - 1].id {
            frontDrop = k
        }
        if appendOnly || frontDrop != nil {
            if settings.wrap { maxChars = 0 } else {
                var m = maxChars
                for l in new[(frontDrop.map { oldCount - $0 } ?? oldCount)...] { m = max(m, min(l.message.utf8.count, 4000)) }
                maxChars = m
            }
        } else {
            recomputeWidth()
        }

        if appendOnly {
            if new.count > oldCount {
                if table.window != nil {
                    table.layoutIfNeeded()   // settle a pending reload before diffing (avoids NSInternalInconsistencyException)
                    let paths = (oldCount..<new.count).map { IndexPath(row: $0, section: 0) }
                    UIView.performWithoutAnimation { table.performBatchUpdates { table.insertRows(at: paths, with: .none) } }
                } else {
                    table.reloadData()
                }
            }
        } else if let k = frontDrop {
            if table.window != nil {
                table.layoutIfNeeded()
                let removed = (0..<k).map { IndexPath(row: $0, section: 0) }
                let inserted = (oldCount - k..<new.count).map { IndexPath(row: $0, section: 0) }
                UIView.performWithoutAnimation {
                    table.performBatchUpdates {
                        table.deleteRows(at: removed, with: .none)
                        table.insertRows(at: inserted, with: .none)
                    }
                }
            } else {
                table.reloadData()
            }
        } else {
            table.reloadData()
            if !newFollow, !wasFollowing, let anchor { restore(anchor) }
        }
        needsLayoutForWidth()

        if newFollow && !table.isTracking && !table.isDecelerating { scrollToBottom() }
        if let t = scrollTarget, t.token != lastToken {
            lastToken = t.token
            if t.lineID < 0 { scrollToBottom() } else { scrollTo(lineID: t.lineID) }
        }
    }

    private func recomputeWidth() {
        guard !settings.wrap else { maxChars = 0; return }
        var m = 0
        for l in lines { m = max(m, l.message.utf8.count) }
        maxChars = min(m, 4000)
    }

    private func needsLayoutForWidth() { setNeedsLayout() }

    override func layoutSubviews() {
        super.layoutSubviews()
        hScroll.frame = bounds
        let prefix: CGFloat = settings.timestamps ? 14 : 5
        let contentWidth = settings.wrap ? bounds.width : max(bounds.width, CGFloat(maxChars + Int(prefix)) * charWidth + 32)
        let frame = CGRect(x: 0, y: 0, width: contentWidth, height: bounds.height)
        if table.frame != frame { table.frame = frame }
        hScroll.contentSize = CGSize(width: contentWidth, height: bounds.height)
        hScroll.alwaysBounceHorizontal = !settings.wrap
        hScroll.isScrollEnabled = !settings.wrap
        if settings.wrap { hScroll.contentOffset.x = 0 }
    }

    // MARK: Scrolling

    private func scrollToBottom() {
        guard !lines.isEmpty else { return }
        programmaticScroll = true
        table.layoutIfNeeded()
        table.scrollToRow(at: IndexPath(row: lines.count - 1, section: 0), at: .bottom, animated: false)
        programmaticScroll = false
    }

    private func index(ofLineID id: Int) -> Int? {
        var lo = 0, hi = lines.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].id == id { return mid }
            if lines[mid].id < id { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    private func scrollTo(lineID: Int) {
        guard let i = index(ofLineID: lineID) else { return }
        programmaticScroll = true
        table.layoutIfNeeded()
        table.scrollToRow(at: IndexPath(row: i, section: 0), at: .middle, animated: false)
        programmaticScroll = false
    }

    private struct Anchor { var lineID: Int; var offset: CGFloat }

    private func captureAnchor() -> Anchor? {
        guard let path = table.indexPathsForVisibleRows?.first, path.row < lines.count else { return nil }
        let rect = table.rectForRow(at: path)
        return Anchor(lineID: lines[path.row].id, offset: table.contentOffset.y - rect.minY)
    }

    private func restore(_ anchor: Anchor) {
        guard let i = index(ofLineID: anchor.lineID) else { return }
        table.layoutIfNeeded()
        let rect = table.rectForRow(at: IndexPath(row: i, section: 0))
        table.setContentOffset(CGPoint(x: 0, y: rect.minY + anchor.offset), animated: false)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === table, !programmaticScroll else { return }
        let atBottom = scrollView.contentOffset.y + scrollView.bounds.height >= scrollView.contentSize.height - 24 - scrollView.adjustedContentInset.bottom
        if scrollView.isTracking || scrollView.isDecelerating {
            if atBottom { onReachedBottom() } else { onUserScrolledAway() }
        }
    }

    // MARK: Data source

    func numberOfSections(in tableView: UITableView) -> Int { 1 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { lines.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: LogCell.reuse, for: indexPath) as! LogCell // swiftlint:disable:this force_cast
        let line = lines[indexPath.row]
        cell.configure(line, settings: settings, matcher: matcher, isCurrent: line.id == settings.currentLineID)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect(lines[indexPath.row])
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let line = lines[indexPath.row]
        guard line.kind == .line else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: "Copy Line", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = line.message },
                UIAction(title: "Copy with Timestamp", image: UIImage(systemName: "clock")) { _ in UIPasteboard.general.string = line.text(timestamps: true) },
            ])
        }
    }
}

// MARK: - Cell

private final class LogCell: UITableViewCell {
    static let reuse = "log"
    private let label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .default
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func levelColor(_ l: LogLevel) -> UIColor {
        switch l {
        case .error: UIColor(Palette.criticalText)
        case .warn: UIColor(Palette.warningText)
        case .info: UIColor(Palette.infoText)
        case .debug: .tertiaryLabel
        case .none: .label
        }
    }

    func configure(_ line: LogLine, settings: LogsDisplaySettings, matcher: LogMatcher?, isCurrent: Bool) {
        let size = settings.fontSize
        let mono = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        label.numberOfLines = settings.wrap ? 0 : 1
        label.lineBreakMode = settings.wrap ? .byCharWrapping : .byClipping

        if line.kind == .marker {
            contentView.backgroundColor = UIColor(Palette.info).withAlphaComponent(0.10)
            let p = NSMutableParagraphStyle(); p.alignment = .center
            label.attributedText = NSAttributedString(string: "── \(line.message) ──", attributes: [
                .font: UIFont.systemFont(ofSize: size - 1, weight: .semibold), .foregroundColor: UIColor(Palette.infoText), .paragraphStyle: p,
            ])
            label.numberOfLines = 0
            return
        }

        let out = NSMutableAttributedString()
        if settings.timestamps, let ts = line.timestamp {
            let short = ts.count >= 23 ? String(ts.dropFirst(11).prefix(12)) : ts
            out.append(NSAttributedString(string: short + " ", attributes: [.font: UIFont.monospacedSystemFont(ofSize: size - 1, weight: .regular), .foregroundColor: UIColor.tertiaryLabel]))
        }
        if line.level != .none {
            let tag: String
            switch line.level { case .error: tag = "ERR"; case .warn: tag = "WRN"; case .info: tag = "INF"; case .debug: tag = "DBG"; case .none: tag = "" }
            out.append(NSAttributedString(string: tag + " ", attributes: [.font: UIFont.monospacedSystemFont(ofSize: size - 1, weight: .bold), .foregroundColor: Self.levelColor(line.level)]))
        }
        if let source = line.source {
            out.append(NSAttributedString(string: "[\(source)] ", attributes: [.font: UIFont.monospacedSystemFont(ofSize: size - 1, weight: .medium), .foregroundColor: UIColor(Palette.tintText)]))
        }
        let messageStart = out.length
        let messageColor: UIColor = line.level == .debug ? .secondaryLabel : .label
        out.append(NSAttributedString(string: line.message, attributes: [.font: mono, .foregroundColor: messageColor]))
        if let matcher {
            var first = true
            for r in matcher.ranges(in: line.message) {
                let shifted = NSRange(location: r.location + messageStart, length: r.length)
                let color = (isCurrent && first) ? UIColor(Palette.logCurrent) : UIColor(Palette.logHighlight)
                out.addAttributes([.backgroundColor: color.withAlphaComponent(isCurrent && first ? 0.9 : 0.55), .foregroundColor: UIColor.black], range: shifted)
                first = false
            }
        }
        contentView.backgroundColor = line.level == .error ? UIColor(Palette.critical).withAlphaComponent(0.10)
            : (line.level == .warn ? UIColor(Palette.warning).withAlphaComponent(0.07) : .clear)
        label.attributedText = out
        accessibilityLabel = (line.level == .none ? "" : "\(line.level.label). ") + line.message
    }
}
