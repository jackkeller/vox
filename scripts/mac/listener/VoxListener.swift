// VoxListener - macOS voice input for Vox. Wake word + dictation through
// Apple's on-device Speech framework; each finished command is handed to
// scripts/mac/send.sh, which types it into the target terminal.
//
// Built into ~/.claude/vox/VoxListener.app by build-listener.sh and started
// with `open`, so macOS asks for mic/speech permission on behalf of this app.
// Run as a child of the terminal instead, the terminal's own usage strings
// apply - Terminal.app has none, and macOS kills the process on first use.
//
//   VoxListener --plugin-root <dir>                 listen on the microphone
//   VoxListener --plugin-root <dir> --file <audio>  same, fed from a file (testing)
//   add --debug to log every transcript
//   VoxListener --check                             write permission/engine report to check.txt

import AppKit
import AVFoundation
import Speech

let stateDir = FileManager.default.homeDirectoryForCurrentUser.path + "/.claude/vox"
let debug = CommandLine.arguments.contains("--debug")

func log(_ message: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date())) [listener] \(message)\n"
    let path = stateDir + "/voice.log"
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        h.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

func beep(_ name: String) {
    NSSound(named: NSSound.Name(name))?.play()
}

// Defaults mirror scripts/common.ps1; config.json overrides any key.
struct Config {
    var wakeWords = ["hey claude", "okay claude"]
    var endWords = ["over", "send it", "go ahead", "that is all", "send"]
    var duplex = "half"
    var ttsTailMs = 300.0
    var silenceGapSec = 2.5
    var maxCommandSec = 30.0
    var commandWaitSec = 10.0

    static func load() -> Config {
        var c = Config()
        guard let data = FileManager.default.contents(atPath: stateDir + "/config.json"),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return c }
        if let v = j["wakeWords"] as? [String] { c.wakeWords = v }
        if let v = j["endWords"] as? [String] { c.endWords = v }
        if let v = j["duplex"] as? String { c.duplex = v }
        if let v = j["ttsTailMs"] as? Double { c.ttsTailMs = v }
        if let v = j["silenceGapSec"] as? Double { c.silenceGapSec = v }
        if let v = j["maxCommandSec"] as? Double { c.maxCommandSec = v }
        if let v = j["commandWaitSec"] as? Double { c.commandWaitSec = v }
        return c
    }
}

func normalize(_ word: String) -> String {
    String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
}

// Dictation writes some words differently from how they're configured
// ("Claude" as "Claud", "okay" as "OK"); treat these as the same word.
let soundalikes: [String: Set<String>] = [
    "claude": ["cloud", "clyde", "claud", "clod", "claudes"],
    "okay": ["ok"],
]

func sameWord(_ heard: String, _ wanted: String) -> Bool {
    heard == wanted || soundalikes[wanted]?.contains(heard) == true
}

final class Listener {
    let cfg = Config.load()
    let sendScript: String
    let recognizer: SFSpeechRecognizer
    let engine = AVAudioEngine()
    let wakePhrases: [[String]]
    let endPhrases: [[String]]

    // The audio thread appends to whichever request is current.
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var taskStarted = Date()

    private var capturing = false
    private var wakeAt = Date()
    private var command = ""
    private var lastChange = Date()
    private var endWordAt: Date?
    private var sending = false
    private var paused = false
    private var resumeAt: Date?

    init(pluginRoot: String, recognizer: SFSpeechRecognizer) {
        sendScript = pluginRoot + "/scripts/mac/send.sh"
        self.recognizer = recognizer
        wakePhrases = cfg.wakeWords.map { $0.split(separator: " ").map { normalize(String($0)) } }
        endPhrases = cfg.endWords.map { $0.split(separator: " ").map { normalize(String($0)) } }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); request?.append(buffer); lock.unlock()
    }

    func startMicrophone() throws {
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func run() {
        startTask()
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    // A fresh recognition task. Also clears the transcript, so a wake word
    // heard earlier can't match again.
    func startTask() {
        stopTask()
        generation += 1
        let gen = generation
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.addsPunctuation = true
        req.contextualStrings = cfg.wakeWords
        lock.lock(); request = req; lock.unlock()
        taskStarted = Date()
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                if let result { self.handle(result) }
                if error != nil || result?.isFinal == true {
                    // Tasks end on their own after long silence; keep listening.
                    if !self.sending && !self.paused {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            if gen == self.generation { self.startTask() }
                        }
                    }
                }
            }
        }
    }

    func stopTask() {
        generation += 1
        lock.lock(); request?.endAudio(); request = nil; lock.unlock()
        task?.cancel()
        task = nil
    }

    // Index (into the transcript's words) just past the last wake phrase, if any.
    func wakeEnd(_ words: [String]) -> Int? {
        var best: Int?
        for phrase in wakePhrases where !phrase.isEmpty && words.count >= phrase.count {
            for i in 0...(words.count - phrase.count) {
                if zip(words[i..<(i + phrase.count)], phrase).allSatisfy(sameWord) {
                    best = max(best ?? 0, i + phrase.count)
                }
            }
        }
        return best
    }

    // Words of the formatted transcript with their character ranges. Segments
    // aren't usable here: the recognizer returns a hinted phrase like
    // "Okay claude," as one segment, and punctuation as segments of its own.
    func words(_ s: NSString) -> [(word: String, range: NSRange)] {
        var out: [(String, NSRange)] = []
        s.enumerateSubstrings(in: NSRange(location: 0, length: s.length), options: .byWords) { w, r, _, _ in
            if let w { out.append((normalize(w), r)) }
        }
        return out
    }

    func handle(_ result: SFSpeechRecognitionResult) {
        if paused || sending { return }
        let s = result.bestTranscription.formattedString as NSString
        if debug { log("heard: \(s)") }
        let w = words(s)
        guard let end = wakeEnd(w.map { $0.word }) else { return }

        if !capturing {
            capturing = true
            wakeAt = Date()
            command = ""
            endWordAt = nil
            lastChange = Date()
            let first = w[max(0, end - 2)].range.location
            log("wake '\(s.substring(with: NSRange(location: first, length: NSMaxRange(w[end - 1].range) - first)))'")
            beep("Tink")
            if cfg.duplex == "full" { hushSpeaker() }
        }

        var stop = s.length
        let spoken = w[end...].map { $0.word }
        for phrase in endPhrases where !phrase.isEmpty && spoken.count > phrase.count && Array(spoken.suffix(phrase.count)) == phrase {
            stop = w[w.count - phrase.count].range.location
            if endWordAt == nil { endWordAt = Date() }
            break
        }
        var cmd = ""
        if end < w.count, stop > w[end].range.location {
            let start = w[end].range.location
            let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:"))
            cmd = s.substring(with: NSRange(location: start, length: stop - start)).trimmingCharacters(in: edges)
        }
        if cmd != command {
            command = cmd
            lastChange = Date()
        }
    }

    func tick() {
        if FileManager.default.fileExists(atPath: stateDir + "/stop.flag") {
            log("stop.flag seen - exiting")
            exit(0)
        }

        // Half duplex: go deaf while Claude speaks so the mic can't hear the
        // reply and wake itself.
        if cfg.duplex == "half" {
            if speakerAlive() {
                if !paused {
                    paused = true
                    capturing = false
                    stopTask()
                    log("TTS speaking - listener paused")
                }
                resumeAt = nil
                return
            }
            if paused {
                if resumeAt == nil { resumeAt = Date().addingTimeInterval(cfg.ttsTailMs / 1000) }
                if Date() < resumeAt! { return }
                paused = false
                resumeAt = nil
                startTask()
                log("TTS ended - listening resumed")
                return
            }
        }
        if sending { return }

        if capturing {
            let elapsed = Date().timeIntervalSince(wakeAt)
            if command.isEmpty && elapsed >= cfg.commandWaitSec {
                log("no speech in \(Int(cfg.commandWaitSec))s - reset, ready for next wake")
                capturing = false
                beep("Funk")
                startTask()
            } else if let e = endWordAt, Date().timeIntervalSince(e) >= 0.6 {
                // Brief settle so the words just before the end word can be
                // revised from their partial guesses.
                log("end-word - finishing")
                finish()
            } else if !command.isEmpty && Date().timeIntervalSince(lastChange) >= cfg.silenceGapSec {
                finish()
            } else if elapsed >= cfg.maxCommandSec {
                log("command time cap reached")
                finish()
            }
        } else if Date().timeIntervalSince(taskStarted) >= 50 {
            // Keep the transcript short and stay clear of per-task time limits.
            startTask()
        }
    }

    func finish() {
        capturing = false
        endWordAt = nil
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        command = ""
        stopTask()
        if text.isEmpty {
            log("empty command - ignored")
            beep("Funk")
            startTask()
            return
        }
        sending = true
        let script = sendScript
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script, text]
            var ok = false
            do {
                try p.run()
                p.waitUntilExit()
                ok = p.terminationStatus == 0
            } catch {
                log("send failed to launch: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                beep(ok ? "Pop" : "Basso")
                self.sending = false
                self.startTask()
            }
        }
    }

    func speakerPid() -> pid_t? {
        guard let s = try? String(contentsOfFile: stateDir + "/speaker.pid", encoding: .utf8),
              let p = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return p
    }

    func speakerAlive() -> Bool {
        guard let p = speakerPid() else { return false }
        return kill(p, 0) == 0
    }

    func hushSpeaker() {
        if let p = speakerPid() { kill(p, SIGTERM) }
    }
}

// Feeds an audio file at real-time pace, then silence, so the wake/silence
// timing behaves as it would on the microphone.
final class FileFeeder {
    let listener: Listener
    let file: AVAudioFile
    let chunk: AVAudioFrameCount
    var silenceLeft = 40

    init(listener: Listener, path: String) throws {
        self.listener = listener
        file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
    }

    func start() {
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self, let buf = AVAudioPCMBuffer(pcmFormat: self.file.processingFormat, frameCapacity: self.chunk) else { return }
            if self.file.framePosition < self.file.length {
                try? self.file.read(into: buf, frameCount: self.chunk)
            } else {
                buf.frameLength = self.chunk // zero-filled silence
                self.silenceLeft -= 1
                if self.silenceLeft <= 0 {
                    t.invalidate()
                    log("file input finished")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
                }
            }
            self.listener.append(buf)
        }
    }
}

func requestSpeech(_ done: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {
    SFSpeechRecognizer.requestAuthorization { s in DispatchQueue.main.async { done(s) } }
}

func requestMic(_ done: @escaping (Bool) -> Void) {
    AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
}

func describe(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
    switch s {
    case .authorized: return "ALLOWED"
    case .denied: return "DENIED"
    case .restricted: return "RESTRICTED"
    default: return "NOT DETERMINED"
    }
}

func runCheck() {
    requestSpeech { speech in
        requestMic { mic in
            var lines = ["Speech recognition: \(describe(speech))", "Microphone        : \(mic ? "ALLOWED" : "DENIED")"]
            var ok = speech == .authorized && mic
            if let r = SFSpeechRecognizer() {
                lines.append("Language          : \(r.locale.identifier)")
                lines.append("On-device model   : \(r.supportsOnDeviceRecognition ? "available" : "NOT available")")
                ok = ok && r.supportsOnDeviceRecognition
            } else {
                lines.append("Language          : no recognizer for \(Locale.current.identifier)")
                ok = false
            }
            lines.append(ok ? "RESULT: OK" : "RESULT: NOT READY")
            try? (lines.joined(separator: "\n") + "\n").write(toFile: stateDir + "/check.txt", atomically: true, encoding: .utf8)
            exit(0)
        }
    }
}

func runListener(pluginRoot: String, file: String?) {
    let pidFile = stateDir + "/listener.pid"
    unlink(stateDir + "/stop.flag")
    requestSpeech { speech in
        requestMic { mic in
            guard speech == .authorized, mic || file != nil else {
                log("FATAL: permission missing (speech \(describe(speech)), mic \(mic ? "ALLOWED" : "DENIED")) - run /vox:check")
                exit(2)
            }
            guard let r = SFSpeechRecognizer(), r.supportsOnDeviceRecognition else {
                log("FATAL: no on-device speech model for \(Locale.current.identifier) - run /vox:check")
                exit(2)
            }
            let listener = Listener(pluginRoot: pluginRoot, recognizer: r)
            do {
                if let file {
                    let feeder = try FileFeeder(listener: listener, path: file)
                    feeder.start()
                    objc_setAssociatedObject(NSApp as Any, "feeder", feeder, .OBJC_ASSOCIATION_RETAIN)
                } else {
                    try listener.startMicrophone()
                }
            } catch {
                log("FATAL: audio input failed: \(error.localizedDescription)")
                exit(2)
            }
            objc_setAssociatedObject(NSApp as Any, "listener", listener, .OBJC_ASSOCIATION_RETAIN)
            try? "\(getpid())\n".write(toFile: pidFile, atomically: true, encoding: .utf8)
            atexit { unlink(stateDir + "/listener.pid") }
            listener.run()
            beep("Tink")
            log("ready. engine=apple-speech (\(r.locale.identifier), on-device). wake: \(listener.cfg.wakeWords.joined(separator: ", ")), duplex=\(listener.cfg.duplex)")
        }
    }
}

let args = CommandLine.arguments
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if args.contains("--check") {
    runCheck()
} else if let root = arg("--plugin-root") {
    runListener(pluginRoot: root, file: arg("--file"))
} else {
    log("FATAL: VoxListener needs --plugin-root or --check")
    exit(2)
}
app.run()
