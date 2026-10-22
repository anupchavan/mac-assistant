import AVFoundation
import CoreAudio
import SoundAnalysis

/// Microphone → 16 kHz mono Int16 PCM chunks (~100 ms), plus a simple level for local silence detection.
final class Microphone {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var pending = Data()
    private(set) var running = false
    private(set) var startedAt = Date()
    /// Called on the audio thread with each ~100 ms chunk and its RMS level (0…1).
    var onChunk: ((Data, Float) -> Void)?

    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        // Recording from Bluetooth headphones (AirPods) switches them into call mode, and they switch back a
        // second or two after we stop, right when the answer starts speaking, which glitches playback. So when
        // the default input is Bluetooth, record from the built-in mic and leave the headphones in music mode.
        if AudioDevices.defaultInputIsBluetooth, var builtIn = AudioDevices.builtInInput, let unit = input.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &builtIn, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.error("mic: couldn't select the built-in microphone (\(status))") }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw NSError(domain: "mic", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input"]) }
        converter = AVAudioConverter(from: format, to: target)
        pending.removeAll()
        input.installTap(onBus: 0, bufferSize: 1600, format: format) { [weak self] buffer, _ in
            self?.convert(buffer)
        }
        engine.prepare()
        try engine.start()
        running = true
        startedAt = Date()
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        if !pending.isEmpty { onChunk?(pending, 0); pending.removeAll() }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard err == nil, let ch = out.int16ChannelData else { return }
        let n = Int(out.frameLength)
        pending.append(UnsafeBufferPointer(start: ch[0], count: n))
        // 100 ms = 1600 samples = 3200 bytes
        while pending.count >= 3200 {
            let chunk = pending.prefix(3200)
            pending.removeFirst(3200)
            onChunk?(Data(chunk), Self.rms(chunk))
        }
    }

    static func rms(_ data: Data) -> Float {
        data.withUnsafeBytes { raw -> Float in
            let s = raw.bindMemory(to: Int16.self)
            guard !s.isEmpty else { return 0 }
            var sum: Float = 0
            for v in s { let f = Float(v) / 32768; sum += f * f }
            return (sum / Float(s.count)).squareRoot()
        }
    }

    static func wav(_ pcm: Data, sampleRate: Int = 16000) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    /// Headphones (or AirPods) on the default output: voice barge-in is only safe there.
    static func outputIsHeadphones() -> Bool {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return false }
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyTransportType
        if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport) == noErr,
           transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE || transport == kAudioDeviceTransportTypeUSB {
            return true
        }
        var source: UInt32 = 0
        addr.mSelector = kAudioDevicePropertyDataSource
        addr.mScope = kAudioDevicePropertyScopeOutput
        if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &source) == noErr {
            return source == 0x6864706E // 'hdpn'
        }
        return false
    }
}

/// Streams Int16 PCM from Bulbul to the speakers. Stop is instant (clears scheduled buffers).
final class PCMPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat
    private let lock = NSLock()
    private var scheduledFrames: Int64 = 0
    private var playedFrames: Int64 = 0
    private var started = false
    private var generation = 0
    private var queued: [(id: Int, buf: AVAudioPCMBuffer)] = []   // scheduled, not yet played
    private var nextID = 0
    private var configObserver: NSObjectProtocol?
    /// Called on the main queue when everything scheduled has played.
    var onDrained: (() -> Void)?
    var sampleRate: Double { format.sampleRate }

    init(sampleRate: Double = 22050) {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        // The output device can change under us (headphones switching modes, plugging in, AirPods handing
        // off). The engine stops and the node drops its queue; restart and replay what hadn't played yet.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.recoverFromConfigurationChange()
        }
    }

    deinit { if let configObserver { NotificationCenter.default.removeObserver(configObserver) } }

    private func recoverFromConfigurationChange() {
        lock.lock()
        generation += 1
        let pending = queued
        queued.removeAll()
        let gen = generation
        lock.unlock()
        Log.info("audio output changed; replaying \(pending.count) buffer(s)")
        node.stop()
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { Log.error("audio restart failed: \(error.localizedDescription)"); return }
        for item in pending { schedule(item.buf, generation: gen) }
        if !pending.isEmpty { node.play(); started = true } else { started = false }
    }

    private func schedule(_ buf: AVAudioPCMBuffer, generation gen: Int) {
        lock.lock(); let id = nextID; nextID += 1; queued.append((id, buf)); lock.unlock()
        let n = Int64(buf.frameLength)
        node.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard gen == self.generation else { self.lock.unlock(); return }
            self.queued.removeAll { $0.id == id }
            self.playedFrames += n
            let drained = self.playedFrames >= self.scheduledFrames
            self.lock.unlock()
            if drained { DispatchQueue.main.async { self.onDrained?() } }
        }
    }

    /// Seconds of audio played so far in this utterance.
    var playedSeconds: Double { lock.lock(); defer { lock.unlock() }; return Double(playedFrames) / format.sampleRate }
    var scheduledSeconds: Double { lock.lock(); defer { lock.unlock() }; return Double(scheduledFrames) / format.sampleRate }

    func enqueue(int16 data: Data) {
        var pcm = data
        if pcm.count > 44, pcm.prefix(4) == "RIFF".data(using: .ascii)! { pcm = pcm.subdata(in: 44..<pcm.count) }
        let n = pcm.count / 2
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        let dst = buf.floatChannelData![0]
        pcm.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<n { dst[i] = Float(Int16(littleEndian: src[i])) / 32768 }
        }
        if !engine.isRunning { try? engine.start() }
        lock.lock(); scheduledFrames += Int64(n); let gen = generation; lock.unlock()
        schedule(buf, generation: gen)
        if !started { node.play(); started = true }
    }

    func stop() {
        lock.lock(); generation += 1; scheduledFrames = 0; playedFrames = 0; queued.removeAll(); lock.unlock()
        node.stop()
        started = false
    }

    func reset() { stop() }
}

/// Local speech detection on the mic's ~100 ms RMS chunks. The noise floor is the quietest level of
/// the last 3 s, so a fan or a noisy room (often 0.03 RMS, double a quiet one) stops counting as speech
/// within a chunk, while speech, which always has quieter gaps between words, can't drag it up.
/// "Speech" only after enough voiced time, so a key click never counts as someone talking.
struct SpeechGate {
    static let minVoicedMs: Double = 300

    private(set) var voicedMs: Double = 0
    private(set) var silenceMs: Double = 0      // consecutive, since the last voiced chunk
    private var recent: [Float] = []            // levels of the last 3 s, newest last
    private var chunks = 0

    var heardSpeech: Bool { voicedMs >= Self.minVoicedMs }
    var noiseFloor: Float { min(recent.min() ?? 0.008, 0.06) }

    /// Returns whether this chunk was voiced.
    @discardableResult
    mutating func feed(_ rms: Float, ms: Double = 100) -> Bool {
        chunks += 1
        // The first chunk carries the fn key's click; it never counts, not even toward the floor.
        guard chunks > 1 else { return false }
        let voiced = rms > max(0.015, noiseFloor * 2.5)
        recent.append(rms)
        if recent.count > 30 { recent.removeFirst() }
        if voiced { voicedMs += ms; silenceMs = 0 } else { silenceMs += ms }
        return voiced
    }

    /// Transcripts that mean nothing was said: empty, only punctuation, or a known silence
    /// hallucination when there was little voiced audio.
    static func isNoise(_ text: String, voicedMs: Double) -> Bool {
        let bare = text.lowercased().unicodeScalars.filter { CharacterSet.letters.union(.decimalDigits).union(.whitespaces).contains($0) }
        let t = String(String.UnicodeScalarView(bare)).split(separator: " ").joined(separator: " ")
        if t.isEmpty { return true }
        return voicedMs < 800 && hallucinations.contains(t)
    }

    static let hallucinations: Set<String> = [
        "thank you", "thanks", "thank you so much", "thanks for watching", "thank you for watching", "you", "bye", "bye bye",
        "hello", "hi", "hey", "hey how are you", "okay", "ok", "hmm", "um", "uh", "so", "yeah", "yes", "no",
        "namaste", "dhanyavaad", "dhanyavad", "shukriya", "haan", "accha", "subscribe",
    ]
}

/// Holds back audio that isn't speech. Realtime STT invents words from anything else: Saaras v4 writes
/// "However, whatever happens, happens." over silence, a fan or typing. So the socket only hears what
/// Apple's on-device sound classifier calls speech, plus 1 s before it (the classifier needs half a
/// second to be sure, and soft onsets matter) and 1 s after it.
final class SpeechFilter: NSObject, SNResultsObserving {
    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let send: (Data) -> Void
    private let queue = DispatchQueue(label: "speech-filter")
    private let analyzer = SNAudioStreamAnalyzer(format: SpeechFilter.format)
    private var held: [Data] = []       // the last second, not sent
    private var frame: Int64 = 0        // 16 kHz frames seen so far
    private var openUntil: Int64 = -1   // audio before this frame goes straight through

    /// Whether any speech went to the socket.
    var heardSpeech: Bool { queue.sync { openUntil >= 0 } }

    init(send: @escaping (Data) -> Void) {
        self.send = send
        super.init()
        do {
            let r = try SNClassifySoundRequest(classifierIdentifier: .version1)
            r.windowDuration = CMTime(value: 8000, timescale: 16000)   // 0.5 s windows every 0.25 s
            r.overlapFactor = 0.5
            try analyzer.add(r, withObserver: self)
        } catch {
            Log.error("speech filter: \(error.localizedDescription); sending all audio")
            openUntil = .max
        }
    }

    /// Each ~100 ms chunk of 16 kHz Int16 mono, from the audio thread.
    func pass(_ chunk: Data) {
        queue.async { [self] in
            let start = frame
            let n = chunk.count / 2
            frame += Int64(n)
            if openUntil != .max, let buf = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(n)) {
                buf.frameLength = AVAudioFrameCount(n)
                chunk.withUnsafeBytes { raw in
                    let src = raw.bindMemory(to: Int16.self)
                    for i in 0..<n { buf.floatChannelData![0][i] = Float(Int16(littleEndian: src[i])) / 32768 }
                }
                analyzer.analyze(buf, atAudioFramePosition: start)
            }
            if start < openUntil { send(chunk); return }
            held.append(chunk)
            if held.count > 10 { held.removeFirst() }
        }
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let c = result as? SNClassificationResult, (c.classification(forIdentifier: "speech")?.confidence ?? 0) > 0.6 else { return }
        let end = Int64(c.timeRange.end.seconds * 16000)
        queue.async { [self] in
            openUntil = max(openUntil, end + 16000)
            for h in held { send(h) }
            held.removeAll()
        }
    }
}

/// Core Audio device lookups for choosing the mic.
enum AudioDevices {
    static var defaultInputIsBluetooth: Bool {
        guard let id = defaultInput else { return false }
        let t = transport(id)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    static var defaultInput: AudioDeviceID? {
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr && id != 0 ? id : nil
    }

    /// The Mac's own microphone, if it has one.
    static var builtInInput: AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { transport($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var t = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t) == noErr ? t : 0
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }
}
