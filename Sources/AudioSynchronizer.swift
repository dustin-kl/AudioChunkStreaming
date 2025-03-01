import AVFoundation
import AudioToolbox
import Combine

final class AudioSynchronizer {
    typealias RateCallback = (_ time: Float) -> Void
    typealias TimeCallback = (_ time: CMTime) -> Void
    typealias ErrorCallback = (_ error: AudioPlayerError?) -> Void
    typealias CompleteCallback = () -> Void
    typealias PlayingCallback = () -> Void
    typealias PausedCallback = () -> Void

    private let queue = DispatchQueue(label: "audio.player.queue")
    private let onRateChanged: RateCallback
    private let onTimeChanged: TimeCallback
    private let onError: ErrorCallback
    private let onComplete: CompleteCallback
    private let onPlaying: PlayingCallback
    private let onPaused: PausedCallback
    private let timeUpdateInterval: CMTime

    private var receiveComplete =  false
    private var audioBuffersQueue: AudioBuffersQueue?
    private var audioFileStream: AudioFileStream?
    private var audioRenderer: AVSampleBufferAudioRenderer?
    private var audioSynchronizer: AVSampleBufferRenderSynchronizer?

    private var audioRendererErrorCancellable: AnyCancellable?
    private var audioRendererRateCancellable: AnyCancellable?
    private var audioRendererTimeCancellable: AnyCancellable?

    var volume: Float {
        get { audioRenderer?.volume ?? 0 }
        set { audioRenderer?.volume = newValue }
    }

    var isMuted: Bool {
        get { audioRenderer?.isMuted ?? false }
        set { audioRenderer?.isMuted = newValue }
    }

    init(
        timeUpdateInterval: CMTime,
        onRateChanged: @escaping RateCallback = { _ in },
        onTimeChanged: @escaping TimeCallback = { _ in },
        onError: @escaping ErrorCallback = { _ in },
        onComplete: @escaping CompleteCallback = {},
        onPlaying: @escaping PlayingCallback = {},
        onPaused: @escaping PausedCallback = {}
    ) {
        self.timeUpdateInterval = timeUpdateInterval
        self.onRateChanged = onRateChanged
        self.onTimeChanged = onTimeChanged
        self.onError = onError
        self.onComplete = onComplete
        self.onPlaying = onPlaying
        self.onPaused = onPaused
    }

    func prepare(type: AudioFileTypeID? = nil) {
        invalidate()
        audioFileStream = AudioFileStream(type: type) { [weak self] error in
            self?.onError(error)
        } receiveASBD: { [weak self] asbd in
            self?.onFileStreamDescriptionReceived(asbd: asbd)
        } receivePackets: { [weak self] numberOfBytes, bytes, numberOfPackets, packets in
            self?.onFileStreamPacketsReceived(
                numberOfBytes: numberOfBytes,
                bytes: bytes,
                numberOfPackets: numberOfPackets,
                packets: packets
            )
        }.open()
    }

    func pause() {
        guard let audioSynchronizer else { return }
        audioSynchronizer.setRate(0.0, time: audioSynchronizer.currentTime())
        onPaused()
    }

    func resume() {
        guard let audioSynchronizer else { return }
        audioSynchronizer.setRate(1.0, time: audioSynchronizer.currentTime())
        onPlaying()
    }

    func receive(data: Data) {
        audioFileStream?.parseData(data)
    }

    func finish() {
        audioFileStream?.finishDataParsing()
        receiveComplete = true
    }

    func invalidate() {
        removeBuffers()
        closeFileStream()
        cancelObservation()
        receiveComplete = false
        audioSynchronizer = nil
        audioRenderer = nil
    }

    // MARK: - Private

    private func onFileStreamDescriptionReceived(asbd: AudioStreamBasicDescription) {
        let renderer = AVSampleBufferAudioRenderer()
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(renderer)
        audioRenderer = renderer
        audioSynchronizer = synchronizer
        audioBuffersQueue = AudioBuffersQueue(audioDescription: asbd)
        startRequestingMediaData(audioRenderer: renderer, audioSynchronizer: synchronizer)
    }

    private func onFileStreamPacketsReceived(
        numberOfBytes: UInt32,
        bytes: UnsafeRawPointer,
        numberOfPackets: UInt32,
        packets: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        do {
            guard let audioBuffersQueue else { return }
            try audioBuffersQueue.enqueue(
                numberOfBytes: numberOfBytes,
                bytes: bytes,
                numberOfPackets: numberOfPackets,
                packets: packets
            )
        } catch {
            onError(AudioPlayerError(error: error))
        }
    }

    private func startRequestingMediaData(
        audioRenderer: AVSampleBufferAudioRenderer,
        audioSynchronizer: AVSampleBufferRenderSynchronizer
    ) {
        observeRenderer(audioRenderer, synchronizer: audioSynchronizer)
        audioRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.provideMediaDataIfNeeded(
                audioRenderer: audioRenderer,
                audioSynchronizer: audioSynchronizer
            )
        }
    }

    private func provideMediaDataIfNeeded(
        audioRenderer: AVSampleBufferAudioRenderer,
        audioSynchronizer: AVSampleBufferRenderSynchronizer
    ) {
        while audioRenderer.isReadyForMoreMediaData {
            if let buffer = audioBuffersQueue?.dequeue() {
                audioRenderer.enqueue(buffer)
                startPlaybackIfCan(
                    audioRenderer: audioRenderer,
                    audioSynchronizer: audioSynchronizer
                )
            } else if receiveComplete {
                audioRenderer.stopRequestingMediaData()
                break
            }
        }
    }

    private func startPlaybackIfCan(
        audioRenderer: AVSampleBufferAudioRenderer,
        audioSynchronizer: AVSampleBufferRenderSynchronizer
    ) {
        guard audioRenderer.hasSufficientMediaDataForReliablePlaybackStart, audioSynchronizer.rate == 0 else { return }
        audioSynchronizer.setRate(1.0, time: .zero)
        onPlaying()
    }

    private func closeFileStream() {
        audioFileStream?.close()
        audioFileStream = nil
    }

    private func removeBuffers() {
        audioBuffersQueue?.removeAll()
        audioBuffersQueue = nil
        audioRenderer?.flush()
    }

    private func observeRenderer(
        _ renderer: AVSampleBufferAudioRenderer,
        synchronizer: AVSampleBufferRenderSynchronizer
    ) {
        observeRate(synchronizer)
        observeTime(renderer)
        observeError(renderer)
    }

    private func cancelObservation() {
        cancelRateObservation()
        cancelTimeObservation()
        cancelErrorObservation()
    }

    private func observeRate(_ audioSynchronizer: AVSampleBufferRenderSynchronizer) {
        cancelRateObservation()
        let name = AVSampleBufferRenderSynchronizer.rateDidChangeNotification
        audioRendererRateCancellable = NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
            guard let self else { return }
            onRateChanged(audioSynchronizer.rate)
        }
    }

    private func cancelRateObservation() {
        audioRendererRateCancellable?.cancel()
        audioRendererRateCancellable = nil
    }

    private func observeTime(_ audioRenderer: AVSampleBufferAudioRenderer) {
        cancelTimeObservation()
        audioRendererTimeCancellable = audioSynchronizer?.periodicTimeObserver(
            interval: timeUpdateInterval,
            queue: queue
        ).sink { [weak self] time in
            guard let self else { return }
            if let audioBuffersQueue, let audioSynchronizer, time >= audioBuffersQueue.duration {
                onTimeChanged(audioBuffersQueue.duration)
                audioSynchronizer.setRate(0.0, time: audioSynchronizer.currentTime())
                onRateChanged(0.0)
                onComplete()
            } else {
                onTimeChanged(time)
            }
        }
    }

    private func cancelTimeObservation() {
        audioRendererTimeCancellable?.cancel()
        audioRendererTimeCancellable = nil
    }

    private func observeError(_ audioRenderer: AVSampleBufferAudioRenderer) {
        cancelErrorObservation()
        audioRendererErrorCancellable = audioRenderer.publisher(for: \.error).sink { [weak self] error in
            guard let self else { return }
            onError(error.flatMap(AudioPlayerError.init))
        }
    }

    private func cancelErrorObservation() {
        audioRendererErrorCancellable?.cancel()
        audioRendererErrorCancellable = nil
    }
}
