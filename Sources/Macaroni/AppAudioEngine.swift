import Foundation
import CoreAudio
import AudioToolbox
import Accelerate

/// Per-app volume for ONE process.
///
/// macOS has no API to "set app X's volume", so this does what SoundSource-style
/// apps do on modern macOS:
///   1. Create a process tap on that app with `.mutedWhenTapped` — the app's own
///      audio stops reaching the speakers and instead arrives in our tap.
///   2. Build a private aggregate device combining that tap (input) with the
///      real output device (output).
///   3. Run an IOProc that multiplies every sample by our gain and writes it to
///      the real output.
///
/// Net effect: that one app plays at whatever volume we choose, everything else
/// is untouched.
final class AppAudioEngine {

    let pid: pid_t
    private let processObjectID: AudioObjectID

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue: DispatchQueue

    /// Read on the realtime audio thread, written from the UI thread. A single
    /// Float write is atomic on arm64, and a torn read would at worst cost one
    /// buffer at a slightly wrong volume — so no locking on the audio path.
    private let gainPointer: UnsafeMutablePointer<Float>

    /// Frames that actually carried sound. Stays at zero if the tap is created
    /// but starved — which is exactly what happens when audio permission was
    /// denied: the tap succeeds, the app gets muted, and nothing is delivered.
    private let activeFramePointer: UnsafeMutablePointer<Int64>

    var activeFrames: Int64 { activeFramePointer.pointee }

    var gain: Float {
        get { gainPointer.pointee }
        set { gainPointer.pointee = max(0, min(1, newValue)) }
    }

    init(pid: pid_t, processObjectID: AudioObjectID, gain: Float) {
        self.pid = pid
        self.processObjectID = processObjectID
        self.ioQueue = DispatchQueue(label: "com.macaroni.audio.\(pid)", qos: .userInitiated)
        self.gainPointer = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        self.gainPointer.initialize(to: max(0, min(1, gain)))
        self.activeFramePointer = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        self.activeFramePointer.initialize(to: 0)
    }

    deinit {
        stop()
        gainPointer.deallocate()
        activeFramePointer.deallocate()
    }

    // MARK: - Lifecycle

    enum EngineError: Error, LocalizedError {
        case tapCreationFailed(OSStatus)
        case noOutputDevice
        case aggregateCreationFailed(OSStatus)
        case ioProcFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tapCreationFailed(let status):
                // -4 / permission errors here almost always mean the audio
                // recording permission hasn't been granted yet.
                return "Couldn't tap this app's audio (error \(status)). Check System Settings → Privacy & Security → Microphone / Audio Recording."
            case .noOutputDevice:
                return "No default output device."
            case .aggregateCreationFailed(let status):
                return "Couldn't create the audio device (error \(status))."
            case .ioProcFailed(let status):
                return "Couldn't start audio processing (error \(status))."
            }
        }
    }

    func start() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.uuid = UUID()
        description.name = "Macaroni tap \(pid)"
        description.isPrivate = true
        // The app's own output is muted; we become the thing that plays it.
        description.muteBehavior = .mutedWhenTapped

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw EngineError.tapCreationFailed(tapStatus)
        }
        tapID = newTapID

        guard let outputUID = Self.defaultOutputDeviceUID() else {
            throw EngineError.noOutputDevice
        }

        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Macaroni \(pid)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString
                ]
            ]
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newAggregateID
        )
        guard aggregateStatus == noErr, newAggregateID != kAudioObjectUnknown else {
            throw EngineError.aggregateCreationFailed(aggregateStatus)
        }
        aggregateID = newAggregateID

        let gainPtr = gainPointer
        let framePtr = activeFramePointer
        var newIOProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newIOProcID, aggregateID, ioQueue
        ) { _, inInputData, _, outOutputData, _ in
            let active = AppAudioEngine.render(
                input: inInputData,
                output: outOutputData,
                gain: gainPtr.pointee
            )
            framePtr.pointee &+= Int64(active)
        }
        guard ioStatus == noErr, let procID = newIOProcID else {
            throw EngineError.ioProcFailed(ioStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            throw EngineError.ioProcFailed(startStatus)
        }

        logFormats()
    }

    /// Logs what the tap and the output device actually agreed on. If audio ever
    /// sounds wrong again, this line says whether a rate or channel mismatch is
    /// behind it. Visible with:
    ///   log stream --predicate 'eventMessage CONTAINS "Macaroni"'
    private func logFormats() {
        func format(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
            var description = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &description) == noErr
            else { return nil }
            return description
        }

        let tapFormat = format(tapID, selector: kAudioTapPropertyFormat, scope: kAudioObjectPropertyScopeGlobal)
        let deviceFormat = format(aggregateID, selector: kAudioDevicePropertyStreamFormat, scope: kAudioDevicePropertyScopeOutput)

        let tapText = tapFormat.map { "\(Int($0.mSampleRate)) Hz / \($0.mChannelsPerFrame) ch" } ?? "unknown"
        let deviceText = deviceFormat.map { "\(Int($0.mSampleRate)) Hz / \($0.mChannelsPerFrame) ch" } ?? "unknown"
        NSLog("%@", "Macaroni pid \(pid): tap \(tapText) → output \(deviceText)")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    // MARK: - Realtime render

    /// Describes how one AudioBufferList is laid out, so we can read and write
    /// it without caring whether CoreAudio handed us interleaved or planar
    /// buffers.
    private struct Layout {
        let channels: Int
        let frames: Int
        let interleaved: Bool

        /// Non-interleaved lists carry one buffer per channel; interleaved ones
        /// carry a single buffer with all channels packed frame by frame.
        init?(_ list: UnsafeMutableAudioBufferListPointer) {
            guard list.count > 0 else { return nil }
            let first = list[0]
            if list.count == 1 && first.mNumberChannels > 1 {
                interleaved = true
                channels = Int(first.mNumberChannels)
                frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            } else {
                interleaved = false
                channels = list.count
                frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            }
            guard channels > 0 else { return nil }
        }
    }

    @inline(__always)
    private static func read(
        _ list: UnsafeMutableAudioBufferListPointer,
        _ layout: Layout,
        frame: Int,
        channel: Int
    ) -> Float {
        if layout.interleaved {
            guard let data = list[0].mData else { return 0 }
            return data.assumingMemoryBound(to: Float.self)[frame * layout.channels + channel]
        } else {
            guard let data = list[channel].mData else { return 0 }
            return data.assumingMemoryBound(to: Float.self)[frame]
        }
    }

    @inline(__always)
    private static func write(
        _ list: UnsafeMutableAudioBufferListPointer,
        _ layout: Layout,
        frame: Int,
        channel: Int,
        _ value: Float
    ) {
        if layout.interleaved {
            guard let data = list[0].mData else { return }
            data.assumingMemoryBound(to: Float.self)[frame * layout.channels + channel] = value
        } else {
            guard let data = list[channel].mData else { return }
            data.assumingMemoryBound(to: Float.self)[frame] = value
        }
    }

    private static func silence(_ list: UnsafeMutableAudioBufferListPointer) {
        for buffer in list {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }

    /// Copies tapped audio to the output, scaled by gain. Runs on the audio thread.
    ///
    /// The tap and the output device do NOT necessarily agree on sample rate or
    /// channel count — a voice call is typically mono at 16/24 kHz while the
    /// speakers run stereo at 48 kHz. Copying bytes straight across in that case
    /// plays the audio at the wrong speed and pitch (the "slow motion" bug).
    /// So: map channels, and stretch or compress the frames we were given to
    /// exactly fill the frames we were asked for.
    /// Returns the number of frames that carried actual sound, so the manager
    /// can tell "tapped and working" from "tapped and starved".
    @discardableResult
    private static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        gain: Float
    ) -> Int {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input)
        )
        let outputBuffers = UnsafeMutableAudioBufferListPointer(output)

        guard let inLayout = Layout(inputBuffers), let outLayout = Layout(outputBuffers) else {
            silence(outputBuffers)
            return 0
        }
        guard inLayout.frames > 0, outLayout.frames > 0 else {
            silence(outputBuffers)
            return 0
        }

        // Pure silence counts as nothing received — a denied tap delivers
        // buffers full of zeroes rather than no buffers at all.
        var peak: Float = 0
        if let probe = inputBuffers[0].mData, inputBuffers[0].mDataByteSize > 0 {
            vDSP_maxmgv(
                probe.assumingMemoryBound(to: Float.self), 1, &peak,
                vDSP_Length(Int(inputBuffers[0].mDataByteSize) / MemoryLayout<Float>.size)
            )
        }
        let activeFrames = peak > 0.000_001 ? inLayout.frames : 0

        // Fast path: formats already agree, so it's a straight scale-and-copy.
        if inLayout.channels == outLayout.channels,
           inLayout.frames == outLayout.frames,
           inLayout.interleaved == outLayout.interleaved {

            for index in 0..<min(inputBuffers.count, outputBuffers.count) {
                guard let source = inputBuffers[index].mData,
                      let destination = outputBuffers[index].mData else { continue }
                let byteCount = min(
                    Int(inputBuffers[index].mDataByteSize),
                    Int(outputBuffers[index].mDataByteSize)
                )
                guard byteCount > 0 else { continue }

                if gain >= 0.999 {
                    memcpy(destination, source, byteCount)
                } else if gain <= 0.001 {
                    memset(destination, 0, byteCount)
                } else {
                    var scale = gain
                    vDSP_vsmul(
                        source.assumingMemoryBound(to: Float.self), 1,
                        &scale,
                        destination.assumingMemoryBound(to: Float.self), 1,
                        vDSP_Length(byteCount / MemoryLayout<Float>.size)
                    )
                }
            }
            return activeFrames
        }

        if gain <= 0.001 {
            silence(outputBuffers)
            return activeFrames
        }

        // Slow path: resample by frame ratio and fan channels out.
        // Deriving the ratio from the frame counts we were actually handed
        // covers any rate difference without having to query either format.
        let ratio = Double(inLayout.frames) / Double(outLayout.frames)

        for frame in 0..<outLayout.frames {
            let position = Double(frame) * ratio
            let lowerIndex = min(Int(position), inLayout.frames - 1)
            let upperIndex = min(lowerIndex + 1, inLayout.frames - 1)
            let fraction = Float(position - Double(lowerIndex))

            for channel in 0..<outLayout.channels {
                // Mono source feeds every output channel; extra source channels
                // beyond what the output has are dropped.
                let sourceChannel = min(channel, inLayout.channels - 1)
                let lower = read(inputBuffers, inLayout, frame: lowerIndex, channel: sourceChannel)
                let upper = read(inputBuffers, inLayout, frame: upperIndex, channel: sourceChannel)
                let interpolated = lower + (upper - lower) * fraction
                write(outputBuffers, outLayout, frame: frame, channel: channel, interpolated * gain)
            }
        }

        return activeFrames
    }

    // MARK: - Helpers

    static func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return nil }

        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
        }
        guard status == noErr else { return nil }
        return uid as String
    }
}
