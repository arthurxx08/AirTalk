import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var audio = AudioDiagnostics()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text("AirTalk")
                        .font(.largeTitle.bold())
                    Text("AirPods 音声テスト v0.1")
                        .foregroundStyle(.secondary)
                }

                GroupBox("接続状態") {
                    VStack(alignment: .leading, spacing: 8) {
                        statusRow("入力", audio.inputRoute)
                        statusRow("出力", audio.outputRoute)
                        statusRow("音声セッション", audio.sessionStatus)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("マイク入力") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(audio.permissionStatus)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ProgressView(value: audio.inputLevel)
                            .tint(.green)
                        Text("入力レベル: \(Int(audio.inputLevel * 100))%")
                            .font(.caption.monospacedDigit())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("スピーカー出力") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("テスト音をAirPodsから再生します。音量を小さめにして試してください。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button {
                                audio.playTestTone()
                            } label: {
                                Label("テスト音を再生", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!audio.isRunning)

                            Button {
                                audio.stopTestTone()
                            } label: {
                                Label("停止", systemImage: "stop.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    audio.toggle()
                } label: {
                    Label(audio.isRunning ? "音声テストを終了" : "音声テストを開始",
                          systemImage: audio.isRunning ? "stop.circle" : "mic.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(audio.isRunning ? .red : .blue)

                Text(audio.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { audio.refreshRoutes() }
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.footnote)
    }
}

@MainActor
final class AudioDiagnostics: ObservableObject {
    @Published var isRunning = false
    @Published var inputLevel: Float = 0
    @Published var inputRoute = "未確認"
    @Published var outputRoute = "未確認"
    @Published var sessionStatus = "停止中"
    @Published var permissionStatus = "マイク権限を確認します"
    @Published var message = "開始を押すとマイク入力と音声出力を同時にテストします。"

    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var meterTimer: Timer?
    private var latestLevel: Float = 0

    func toggle() {
        if isRunning {
            stop()
        } else {
            requestPermissionAndStart()
        }
    }

    private func requestPermissionAndStart() {
        switch session.recordPermission {
        case .granted:
            start()
        case .denied:
            permissionStatus = "マイク権限がありません。設定アプリで許可してください。"
            message = "設定 > AirTalk > マイク をオンにしてください。"
        case .undetermined:
            session.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.permissionStatus = granted ? "マイク使用許可済み" : "マイク使用が拒否されました"
                    if granted { self.start() }
                }
            }
        @unknown default:
            permissionStatus = "マイク権限を確認できません"
        }
    }

    private func start() {
        do {
            try session.setCategory(.playAndRecord,
                                   mode: .voiceChat,
                                   options: [.allowBluetooth])
            try session.setActive(true)

            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.channelCount > 0 else {
                message = "マイク入力チャンネルが見つかりません。"
                return
            }

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                guard let channel = buffer.floatChannelData?[0] else { return }
                let count = Int(buffer.frameLength)
                guard count > 0 else { return }
                var sum: Float = 0
                for i in 0..<count {
                    let sample = channel[i]
                    sum += sample * sample
                }
                let rms = sqrt(sum / Float(count))
                let scaled = min(1, rms * 5)
                Task { @MainActor in self?.latestLevel = scaled }
            }

            engine.attach(player)
            let outputFormat = engine.outputNode.inputFormat(forBus: 0)
            engine.connect(player, to: engine.mainMixerNode, format: outputFormat)

            engine.prepare()
            try engine.start()

            isRunning = true
            permissionStatus = "マイク使用許可済み"
            sessionStatus = "動作中（PlayAndRecord / VoiceChat）"
            message = "入力と出力を同時に開始しました。テスト音を再生して確認してください。"
            refreshRoutes()
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.inputLevel = self.latestLevel
                    self.refreshRoutes()
                }
            }
        } catch {
            message = "開始エラー: \(error.localizedDescription)"
            stop()
        }
    }

    func playTestTone() {
        guard isRunning else { return }
        let sampleRate: Double = 24000
        let duration: Double = 1.2
        let frames = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return }

        buffer.frameLength = frames
        let frequency = 440.0
        for frame in 0..<Int(frames) {
            let t = Double(frame) / sampleRate
            let fade = min(1.0, min(t / 0.03, (duration - t) / 0.08))
            channel[frame] = Float(0.12 * fade * sin(2.0 * Double.pi * frequency * t))
        }

        if !player.isPlaying {
            player.play()
        }
        player.scheduleBuffer(buffer, at: nil, options: [])
        message = "440Hzのテスト音を再生しました。"
    }

    func stopTestTone() {
        player.stop()
        if isRunning { player.play() }
        message = "テスト音を停止しました。"
    }

    func stop() {
        meterTimer?.invalidate()
        meterTimer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.disconnectNodeOutput(player)
        engine.detach(player)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
        inputLevel = 0
        latestLevel = 0
        sessionStatus = "停止中"
        refreshRoutes()
    }

    func refreshRoutes() {
        let inputs = session.currentRoute.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }
        let outputs = session.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }
        inputRoute = inputs.isEmpty ? "入力デバイスなし" : inputs.joined(separator: ", ")
        outputRoute = outputs.isEmpty ? "出力デバイスなし" : outputs.joined(separator: ", ")
    }
}
