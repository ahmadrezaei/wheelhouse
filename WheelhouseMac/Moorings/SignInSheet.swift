import SwiftUI
import WheelhouseDesktop
import WheelhouseKit

/// Runs an exec plugin (or a provider login command) on a pseudo-terminal (ARCHITECTURE-MAC §4.6): stdin and stderr on the PTY, so
/// prompts, device codes and URLs are visible; stdout on a pipe, for the ExecCredential JSON. What the person types is written to
/// the PTY and nowhere else: it is never parsed, stored or logged, and the terminal output is not recorded.
@MainActor @Observable
final class SignInModel {
    private(set) var output = AttributedString()
    private(set) var finished = false
    private(set) var failure: String?
    private var pty: PTYProcess?
    private let provider: ExecCredentialProvider?
    private let spec: ProcessSpec?
    private let loginCommand: ProcessSpec?

    init(provider: ExecCredentialProvider) { self.provider = provider; self.spec = nil; self.loginCommand = nil }
    init(command: ProcessSpec) { self.provider = nil; self.spec = nil; self.loginCommand = command }

    func start() async {
        do {
            let processSpec: ProcessSpec
            if let provider { processSpec = try await provider.interactiveSpec() } else if let loginCommand { processSpec = loginCommand } else { return }
            let pty = try PTYProcess(spec: processSpec, size: (cols: 80, rows: 24), stdoutPipe: provider != nil)
            self.pty = pty
            Task { for await chunk in pty.output { append(chunk) } }
            // stdout is collected by a task whose value is awaited: the stream ends when the pipe closes, so no bytes are missed.
            let collector = Task<Data, Never> {
                var data = Data()
                for await c in pty.stdout { data.append(c) }
                return data
            }
            let exit = await pty.waitForExit()
            finished = true
            if exit.code == 0, let provider {
                try await provider.completeSignIn(stdout: await collector.value)
            } else if exit.code != 0 {
                failure = "The program exited with \(exit.code.map(String.init) ?? "a signal")."
            }
        } catch {
            finished = true
            failure = error.localizedDescription
        }
    }

    func send(_ line: String) { pty?.write(Data((line + "\n").utf8)) }
    func cancel() { Task { await pty?.terminate() } }

    private func append(_ data: Data) {
        var text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\r", with: "")
        var piece = AttributedString(text)
        // Plain URLs become clickable.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for m in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range, in: text), let url = m.url, let a = piece.range(of: String(text[r])) { piece[a].link = url }
            }
        }
        output += piece
    }
}

struct SignInSheet: View {
    @State var model: SignInModel
    let title: String
    @State private var line = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ScrollView { Text(model.output).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(minHeight: 180).padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            if let failure = model.failure { Text(failure).foregroundStyle(.red).font(.callout) }
            HStack {
                SecureField("Type here if the program asks", text: $line).onSubmit { model.send(line); line = "" }.disabled(model.finished)
                Button("Cancel") { model.cancel(); dismiss() }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).disabled(!model.finished || model.failure != nil)
            }
        }
        .padding(20).frame(width: 560)
        .task { await model.start(); if model.finished, model.failure == nil { dismiss() } }
        .onDisappear { model.cancel() }
    }
}
