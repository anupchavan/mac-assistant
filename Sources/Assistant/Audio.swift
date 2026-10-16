import AVFoundation
import CoreAudio

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
    /// Called on the main queue when everything scheduled has played.
    var onDrained: (() -> Void)?
    var sampleRate: Double { format.sampleRate }

    init(sampleRate: Double = 22050) {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
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
        node.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard gen == self.generation else { self.lock.unlock(); return }
            self.playedFrames += Int64(n)
            let drained = self.playedFrames >= self.scheduledFrames
            self.lock.unlock()
            if drained { DispatchQueue.main.async { self.onDrained?() } }
        }
        if !started { node.play(); started = true }
    }

    func stop() {
        lock.lock(); generation += 1; scheduledFrames = 0; playedFrames = 0; lock.unlock()
        node.stop()
        started = false
    }

    func reset() { stop() }
}

/// Local speech detection on the mic's ~100 ms RMS chunks. An adaptive noise floor, and "speech"
/// only after enough voiced time, so a key click or room noise never counts as someone talking.
struct SpeechGate {
    static let minVoicedMs: Double = 300

    private(set) var noiseFloor: Float = 0.008
    private(set) var voicedMs: Double = 0
    private(set) var silenceMs: Double = 0      // consecutive, since the last voiced chunk
    private var chunks = 0

    var heardSpeech: Bool { voicedMs >= Self.minVoicedMs }

    /// Returns whether this chunk was voiced.
    @discardableResult
    mutating func feed(_ rms: Float, ms: Double = 100) -> Bool {
        chunks += 1
        // The first chunk carries the fn key's click; it only seeds the floor.
        if chunks > 1, rms > max(0.015, noiseFloor * 2.5) {
            voicedMs += ms
            silenceMs = 0
            return true
        }
        noiseFloor = noiseFloor * 0.9 + min(rms, 0.05) * 0.1
        silenceMs += ms
        return false
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
