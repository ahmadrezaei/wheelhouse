import UIKit
import WheelhouseKit
import WheelhouseUI

/// iPhone keyboard accessory: Esc, Ctrl (sticky; tap again to lock), Tab, arrows, | ~ / -. Long-press Esc (or the … button)
/// for Alt, Home/End, PgUp/PgDn and F1–F12. Renderer-independent: it only emits ``TerminalKey``s and text.
@MainActor
final class TerminalExtraKeysBar: UIInputView {
    var onKey: ((TerminalKey, TerminalModifiers) -> Void)?
    var onText: ((String) -> Void)?
    let state: TerminalModifierState

    private let stack = UIStackView()
    private var ctrlButton: UIButton?
    private var altMenuButton: UIButton?
    private var repeatTimer: Timer?

    init(state: TerminalModifierState) {
        self.state = state
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        build()
        state.onChange = { [weak self] in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 44) }

    private func build() {
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        let esc = key("esc", accessibility: "Escape") { [weak self] in self?.onKey?(.escape, []) }
        esc.menu = moreMenu()
        stack.addArrangedSubview(esc)

        let ctrl = key("ctrl", accessibility: "Control, sticky modifier") { [weak self] in self?.cycleControl() }
        ctrlButton = ctrl
        stack.addArrangedSubview(ctrl)

        stack.addArrangedSubview(key("tab", accessibility: "Tab") { [weak self] in self?.onKey?(.tab, []) })
        stack.addArrangedSubview(arrow("arrow.left", .left, "Left"))
        stack.addArrangedSubview(arrow("arrow.up", .up, "Up"))
        stack.addArrangedSubview(arrow("arrow.down", .down, "Down"))
        stack.addArrangedSubview(arrow("arrow.right", .right, "Right"))
        for ch in ["|", "~", "/", "-"] {
            stack.addArrangedSubview(key(ch, accessibility: ch == "|" ? "Pipe" : ch == "~" ? "Tilde" : ch == "/" ? "Slash" : "Dash") { [weak self] in self?.type(ch) })
        }
        let more = key("ellipsis", symbol: true, accessibility: "More keys") {}
        more.menu = moreMenu()
        more.showsMenuAsPrimaryAction = true
        altMenuButton = more
        stack.addArrangedSubview(more)
        refresh()
    }

    private func type(_ text: String) {
        let m = state.consume()
        if m.isEmpty { onText?(text) } else { onText?(String(decoding: TerminalKeyEncoder.bytes(forText: text, modifiers: m), as: UTF8.self)) }
    }

    private func cycleControl() {
        if !state.control { state.control = true; state.controlLocked = false }
        else if !state.controlLocked { state.controlLocked = true }
        else { state.control = false; state.controlLocked = false }
    }

    private func refresh() {
        guard let ctrlButton else { return }
        var cfg = ctrlButton.configuration ?? .plain()
        cfg.baseForegroundColor = state.control ? UIColor.black : UIColor.label
        cfg.background.backgroundColor = state.control ? (state.controlLocked ? UIColor(Palette.warning) : UIColor(Palette.tint)) : UIColor.secondarySystemFill
        cfg.title = state.controlLocked ? "ctrl•" : "ctrl"
        ctrlButton.configuration = cfg
        ctrlButton.accessibilityValue = state.control ? (state.controlLocked ? "Locked" : "On") : "Off"
        if let altMenuButton { altMenuButton.menu = moreMenu() }
    }

    private func moreMenu() -> UIMenu {
        let alt = UIAction(title: "Alt (next key)", image: UIImage(systemName: "option"), state: state.alt ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.state.alt.toggle()
        }
        let nav = UIMenu(options: .displayInline, children: [
            UIAction(title: "Home") { [weak self] _ in self?.onKey?(.home, []) },
            UIAction(title: "End") { [weak self] _ in self?.onKey?(.end, []) },
            UIAction(title: "Page Up") { [weak self] _ in self?.onKey?(.pageUp, []) },
            UIAction(title: "Page Down") { [weak self] _ in self?.onKey?(.pageDown, []) },
            UIAction(title: "Delete") { [weak self] _ in self?.onKey?(.delete, []) },
        ])
        let fkeys = UIMenu(title: "Function Keys", image: UIImage(systemName: "fn"), children: (1...12).map { n in
            UIAction(title: "F\(n)") { [weak self] _ in self?.onKey?(.function(n), []) }
        })
        return UIMenu(children: [alt, nav, fkeys])
    }

    // MARK: Buttons

    private func key(_ title: String, symbol: Bool = false, accessibility: String, action: @escaping () -> Void) -> UIButton {
        var cfg = UIButton.Configuration.plain()
        if symbol { cfg.image = UIImage(systemName: title) } else { cfg.title = title }
        cfg.baseForegroundColor = .label
        cfg.background.backgroundColor = .secondarySystemFill
        cfg.background.cornerRadius = 8
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { c in
            var c = c
            c.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
            return c
        }
        let b = UIButton(configuration: cfg, primaryAction: UIAction { _ in action() })
        b.accessibilityLabel = accessibility
        b.configurationUpdateHandler = nil
        return b
    }

    private func arrow(_ symbol: String, _ k: TerminalKey, _ label: String) -> UIButton {
        let b = key(symbol, symbol: true, accessibility: label) {}
        b.addAction(UIAction { [weak self] _ in self?.startRepeating(k) }, for: .touchDown)
        for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
            b.addAction(UIAction { [weak self] _ in self?.stopRepeating() }, for: event)
        }
        return b
    }

    private func fire(_ k: TerminalKey) {
        let m = state.consume()
        onKey?(k, m)
    }

    private func startRepeating(_ k: TerminalKey) {
        stopRepeating()
        fire(k)
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.fire(k) }
                }
            }
        }
    }

    private func stopRepeating() { repeatTimer?.invalidate(); repeatTimer = nil }
}
