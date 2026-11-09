// The setup window for install.sh. install.sh compiles this with the Command Line Tools'
// swiftc when they are installed, so there is no downloaded app to approve; without them it
// keeps using Terminal. The window runs install.sh with ALTIUM_INSTALLER_UI=app: lines that
// start with "@@sw<TAB>" are prompts and progress, every other line goes to the built-in
// terminal pane, and answers go back on the script's standard input. Quitting stops the
// script's whole process group, and the script then stops the Wine it started.
import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

enum Step: Int, CaseIterable, Identifiable {
    case installer, wine, altium, finish
    var id: Int { rawValue }

    init?(key: String) {
        switch key {
        case "installer": self = .installer
        case "wine": self = .wine
        case "altium": self = .altium
        case "finish": self = .finish
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .installer: return "Choose the Altium installer"
        case .wine: return "Prepare Wine"
        case .altium: return "Install Altium"
        case .finish: return "Finish"
        }
    }

    // Shown under the step in the sidebar.
    var subtitle: String {
        switch self {
        case .installer: return "Your offline setup"
        case .wine: return "Automatic · about 10 minutes"
        case .altium: return "In the Altium installer"
        case .finish: return "Add to Applications"
        }
    }

    // Shown while the step runs.
    var explanation: String {
        switch self {
        case .installer:
            return "Choose the Altium Designer offline installer you downloaded from your Altium account. It can be the folder or the .zip."
        case .wine:
            return "Setting up Wine, which runs Altium on your Mac, in its own disk image. This takes about 10 minutes. You can leave this running."
        case .altium:
            return "Follow the Altium installer in its own window."
        case .finish:
            return "Adding Altium Designer (Wine) to Applications, then opening Altium."
        }
    }
}

enum Page: Equatable {
    case working
    case message(title: String, text: String, button: String)
    // The script is watching for something to happen; no answer is needed.
    case waiting(title: String, text: String)
    case choose(text: String)
    case failed(stage: String)
    case finished(text: String)
}

struct LogLine: Identifiable {
    let id: Int
    let text: String
}

final class Installer: ObservableObject {
    @Published var page: Page = .working
    @Published var step: Step = .installer
    @Published var stage = "Starting"
    @Published var status = ""
    @Published var log: [LogLine] = []
    @Published var showTerminal = false
    @Published var field = ""
    @Published var found = false

    let script: URL?
    let root: String?
    let arguments: [String]
    private(set) var group: pid_t = 0
    private var running = false
    private var input: Int32 = -1
    private var output: FileHandle?
    private var partial = Data()
    private var nextLine = 0
    private var failedStage: String?
    private var finishedText: String?

    init(script: URL?, root: String?, arguments: [String]) {
        self.script = script
        self.root = root
        self.arguments = arguments
    }

    var finished: Bool { if case .finished = page { return true } else { return false } }
    var failed: Bool { if case .failed = page { return true } else { return false } }
    var busy: Bool {
        guard running else { return false }
        if case .message = page { return false }
        if case .choose = page { return false }
        return true
    }

    func start() {
        guard let script, FileManager.default.fileExists(atPath: script.path) else {
            append("Couldn't find install.sh. Run it from Terminal instead.")
            page = .failed(stage: "starting")
            showTerminal = true
            return
        }
        page = .working
        stage = "Starting"
        status = ""
        failedStage = nil
        finishedText = nil
        var inFDs: [Int32] = [0, 0]
        var outFDs: [Int32] = [0, 0]
        guard pipe(&inFDs) == 0, pipe(&outFDs) == 0 else { return }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, inFDs[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outFDs[1], 1)
        posix_spawn_file_actions_adddup2(&actions, outFDs[1], 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        // Its own process group, so quitting can stop the script and everything it started.
        posix_spawnattr_setpgroup(&attributes, 0)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF
                                                     | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var environment = ProcessInfo.processInfo.environment
        environment["ALTIUM_INSTALLER_UI"] = "app"
        if let root { environment["ALTIUM_WINE_ROOT"] = root }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        let argv: [UnsafeMutablePointer<CChar>?] = ([strdup("/bin/bash"), strdup(script.path)]
                                                    + arguments.map { strdup($0) }) + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        var child: pid_t = 0
        let result = posix_spawn(&child, "/bin/bash", &actions, &attributes, argv, envp)
        argv.forEach { free($0) }
        envp.forEach { free($0) }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
        close(inFDs[0])
        close(outFDs[1])
        guard result == 0 else {
            close(inFDs[1])
            close(outFDs[0])
            append("Couldn't start setup: \(String(cString: strerror(result)))")
            page = .failed(stage: "starting")
            return
        }
        group = child
        running = true
        input = inFDs[1]
        let handle = FileHandle(fileDescriptor: outFDs[0], closeOnDealloc: true)
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil }
            DispatchQueue.main.async { self?.receive(data) }
        }
        output = handle
        DispatchQueue.global().async { [weak self] in
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            // Let the last output arrive before showing the result.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.exited(code) }
        }
    }

    private func receive(_ data: Data) {
        if data.isEmpty {
            if !partial.isEmpty { handle(String(decoding: partial, as: UTF8.self)) }
            partial.removeAll()
            return
        }
        partial.append(data)
        while let newline = partial.firstIndex(of: 0x0A) {
            let line = partial[partial.startIndex..<newline]
            partial.removeSubrange(partial.startIndex...newline)
            handle(String(decoding: line, as: UTF8.self))
        }
    }

    private func handle(_ raw: String) {
        // Progress meters redraw with carriage returns; keep what was drawn last. The scripts'
        // colored labels are terminal escape codes; drop them.
        let last = raw.split(separator: "\r", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let line = last.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        guard line.hasPrefix("@@sw\t") else {
            append(line)
            return
        }
        let fields = line.dropFirst(5).split(separator: "\t", omittingEmptySubsequences: false).map { unescape(String($0)) }
        func at(_ index: Int) -> String { index < fields.count ? fields[index] : "" }
        switch at(0) {
        case "stage":
            if let next = Step(key: at(1)) { step = next }
            stage = at(2)
            status = ""
        case "notify":
            status = at(1)
        case "message":
            page = .message(title: at(2), text: at(3), button: at(1))
        case "wait":
            page = .waiting(title: at(1), text: at(2))
            status = at(3)
        case "choose":
            field = at(1)
            page = .choose(text: at(2))
            checkFound()
        case "failed":
            failedStage = at(1)
        case "finished":
            finishedText = at(1)
        default:
            append(line)
        }
    }

    private func unescape(_ text: String) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    private func append(_ text: String) {
        log.append(LogLine(id: nextLine, text: text))
        nextLine += 1
        if log.count > 4000 { log.removeFirst(log.count - 3000) }
    }

    private func exited(_ code: Int32) {
        running = false
        if input >= 0 { close(input); input = -1 }
        if code == 0 {
            step = .finish
            page = .finished(text: finishedText ?? "Setup is done.")
        } else if code != 130 && code != 143 {
            page = .failed(stage: failedStage ?? stage)
            showTerminal = true
        }
    }

    func reply(_ answer: String) {
        page = .working
        guard input >= 0 else { return }
        let bytes = Array((answer + "\n").utf8)
        _ = bytes.withUnsafeBufferPointer { write(input, $0.baseAddress, $0.count) }
    }

    // The offline installer is a folder or a .zip; install.sh checks what is inside it.
    func checkFound() {
        let path = (field.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        var directory: ObjCBool = false
        let exists = !path.isEmpty && FileManager.default.fileExists(atPath: path, isDirectory: &directory)
        found = exists && (directory.boolValue || path.lowercased().hasSuffix(".zip"))
    }

    func browse() {
        let panel = NSOpenPanel()
        panel.message = "Choose the Altium offline installer (folder or .zip)"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .folder]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url {
            field = url.path
            checkFound()
        }
    }

    func retry() {
        log.removeAll()
        start()
    }

    // Stops the script and everything it started. After a successful setup nothing is
    // stopped, so Altium keeps running.
    func stop(then done: @escaping () -> Void) {
        let target = group
        guard target != 0, !finished else { done(); return }
        if input >= 0 { close(input); input = -1 }
        kill(-target, SIGTERM)
        DispatchQueue.global().async {
            for _ in 0..<40 where kill(-target, 0) == 0 { usleep(100_000) }
            kill(-target, SIGKILL)
            DispatchQueue.main.async(execute: done)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let installer: Installer
    private var closingWindow = false

    // Arguments: --script <install.sh> [--root <dir>] [--arg <install.sh option>]...
    override init() {
        let arguments = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        var passed: [String] = []
        for (index, argument) in arguments.enumerated() where argument == "--arg" && index + 1 < arguments.count {
            passed.append(arguments[index + 1])
        }
        installer = Installer(script: value(after: "--script").map { URL(fileURLWithPath: $0) },
                              root: value(after: "--root"), arguments: passed)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            self?.closingWindow = true
        }
        NSApp.activate(ignoringOtherApps: true)
        installer.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if installer.busy && !closingWindow {
            let alert = NSAlert()
            alert.messageText = "Stop setup?"
            alert.informativeText = "Setup stops now. You can run it again later."
            alert.addButton(withTitle: "Stop Setup")
            alert.addButton(withTitle: "Keep Running")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        installer.stop { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct AltiumInstallerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Altium Designer Installer", id: "installer") {
            ContentView(installer: delegate.installer)
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

struct ContentView: View {
    @ObservedObject var installer: Installer

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(installer: installer)
                .frame(width: 230)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                PageView(installer: installer)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                TerminalPane(installer: installer)
                Divider()
                BottomBar(installer: installer)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        }
    }
}

struct Sidebar: View {
    @ObservedObject var installer: Installer

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Altium Designer")
                .font(.headline)
                .padding(.bottom, 10)
            ForEach(Step.allCases) { step in
                HStack(alignment: .top, spacing: 10) {
                    icon(for: step).frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .fontWeight(step == installer.step && !installer.finished ? .semibold : .regular)
                            .foregroundStyle(step.rawValue > installer.step.rawValue ? .secondary : .primary)
                        Text(step.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(22)
    }

    @ViewBuilder private func icon(for step: Step) -> some View {
        if installer.finished || step.rawValue < installer.step.rawValue {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if step.rawValue > installer.step.rawValue {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        } else if installer.failed {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else if installer.busy {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "arrow.right.circle.fill").foregroundStyle(Color.accentColor)
        }
    }
}

struct PageView: View {
    @ObservedObject var installer: Installer
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch installer.page {
            case .working:
                heading(installer.step.title)
                paragraph(installer.step.explanation)
                    .foregroundStyle(.secondary)
                Text(sentence(installer.stage) + "…")
                    .font(.headline)
                    .padding(.top, 6)
                ProgressView().progressViewStyle(.linear)
                if !installer.status.isEmpty {
                    Text(installer.status).foregroundStyle(.secondary)
                }
                if !installer.showTerminal, let last = installer.log.last(where: { !$0.text.isEmpty }) {
                    Text(last.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            case let .message(title, text, _):
                heading(title.isEmpty ? installer.step.title : title)
                paragraph(text)
            case let .waiting(title, text):
                heading(title.isEmpty ? installer.step.title : title)
                paragraph(text)
                HStack(alignment: .top, spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(installer.status.isEmpty ? "Waiting…" : installer.status)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            case let .choose(text):
                heading("Choose the Altium installer")
                paragraph(text)
                HStack {
                    TextField("Offline installer folder or .zip", text: $installer.field)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { installer.checkFound() }
                    Button("Browse…") { installer.browse() }
                }
                if installer.found {
                    Label("Found \((installer.field as NSString).lastPathComponent)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("Download the offline installer from your Altium account, then choose it here.")
                        .foregroundStyle(.secondary)
                }
            case let .failed(stage):
                Label("Setup stopped", systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.red)
                paragraph("Setup stopped while \(stage). Details are in the terminal below.\n\nFix the problem, then click Try Again.")
            case let .finished(text):
                Label("Setup is done", systemImage: "checkmark.seal.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.green)
                paragraph(text)
            }
        }
        .onReceive(poll) { _ in
            if case .choose = installer.page { installer.checkFound() }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.title2.bold())
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).font(.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    private func sentence(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}

struct TerminalPane: View {
    @ObservedObject var installer: Installer

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { installer.showTerminal.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(installer.showTerminal ? 90 : 0))
                        .font(.caption.weight(.semibold))
                    Image(systemName: "terminal")
                    Text("Terminal")
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 20)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if installer.showTerminal {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(installer.log) { line in
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color(white: 0.88))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                        .padding(10)
                        .textSelection(.enabled)
                    }
                    .background(Color(white: 0.11))
                    .onAppear { if let last = installer.log.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    .onReceive(installer.$log) { log in
                        if let last = log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .frame(height: 200)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

struct BottomBar: View {
    @ObservedObject var installer: Installer

    var body: some View {
        HStack {
            Button(installer.finished ? "Close" : "Quit") { NSApp.terminate(nil) }
            Spacer()
            switch installer.page {
            case .working, .waiting, .finished:
                EmptyView()
            case let .message(_, _, button):
                primary(button) { installer.reply("ok") }
            case .choose:
                primary("Continue") {
                    installer.reply((installer.field.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath)
                }
                .disabled(!installer.found)
            case .failed:
                primary("Try Again") { installer.retry() }
            }
        }
        .controlSize(.large)
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
    }
}
