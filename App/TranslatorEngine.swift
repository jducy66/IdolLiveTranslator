import Foundation
import AVFoundation
import Speech
import Network

enum InputMode: String, CaseIterable {
    case systemAudio = "系统内录 (ReplayKit)"
    case microphone = "麦克风外录 (兼容容器)"
}

enum SourceLang: String, CaseIterable {
    case korean = "ko-KR"
    case japanese = "ja-JP"
    
    var displayName: String {
        switch self {
        case .korean: return "韩语 (한국어)"
        case .japanese: return "日语 (日本語)"
        }
    }
}

struct TranscriptItem: Identifiable, Codable {
    var id = UUID()
    let timestamp: Date
    let originalText: String
    let translatedText: String
    let latencyMs: Int
}

class TranslatorEngine: ObservableObject {
    @Published var isRunning = false
    @Published var statusMessage = "就绪"
    @Published var liveRecognizedText = "等待语音输入..."
    @Published var liveTranslatedText = "等待翻译结果..."
    @Published var history: [TranscriptItem] = []
    @Published var udpPacketsReceived: Int = 0
    @Published var apiRequestCount: Int = 0
    
    var apiKey: String = ""
    var modelName: String = "gemini-2.5-flash"
    var currentMode: InputMode = .systemAudio
    var currentLang: SourceLang = .korean
    var segmentLengthThreshold: Int = 14
    var customGlossary: String = ""
    
    private let audioEngine = AVAudioEngine()
    private var udpListener: NWListener?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var resetTimer: Timer?
    private var silenceTimer: Timer?
    private var currentTaskID: UUID = UUID()
    private var lastCommittedLength = 0
    
    private let udpAudioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
    }

    func start() {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            statusMessage = "错误：请先在【设置】中填入 Gemini API Key"
            return
        }
        stop()
        
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: currentLang.rawValue))
        
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
        
        startRecognitionTask()
        
        resetTimer = Timer.scheduledTimer(withTimeInterval: 50.0, repeats: true) { [weak self] _ in
            self?.restartRecognitionTask()
        }
        
        switch currentMode {
        case .microphone:
            startMicrophone()
            statusMessage = "运行中：麦克风正在收音..."
        case .systemAudio:
            startUDPListener()
            statusMessage = "运行中：监听内录端口 9999 (请开启录屏广播)"
        }
        isRunning = true
    }

    func stop() {
        resetTimer?.invalidate()
        resetTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        currentTaskID = UUID()
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        udpListener?.cancel()
        udpListener = nil
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()
        isRunning = false
        statusMessage = "已停止"
    }

    func clearHistory() {
        history.removeAll()
    }

    func exportHistoryText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return history.reversed().map { item in
            "[\(formatter.string(from: item.timestamp))] 原文: \(item.originalText)\n译文: \(item.translatedText)"
        }.joined(separator: "\n\n")
    }

    private func startRecognitionTask() {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest, let recognizer = speechRecognizer, recognizer.isAvailable else {
            DispatchQueue.main.async {
                self.statusMessage = "语音识别不可用，请确认系统已下载对应离线语音包"
            }
            return
        }
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.shouldReportPartialResults = true
        lastCommittedLength = 0
        
        let taskID = UUID()
        currentTaskID = taskID

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self = self, self.currentTaskID == taskID, let result = result else { return }
            let fullString = result.bestTranscription.formattedString
            let recentOriginal = String(fullString.suffix(42))
            
            DispatchQueue.main.async {
                self.liveRecognizedText = recentOriginal
                PiPSubtitleManager.shared.updateSubtitle(original: recentOriginal, translated: "")
                
                self.silenceTimer?.invalidate()
                if fullString.count > self.lastCommittedLength {
                    let newChunk = String(fullString.dropFirst(self.lastCommittedLength))
                    if newChunk.count >= self.segmentLengthThreshold || result.isFinal {
                        self.lastCommittedLength = fullString.count
                        self.translateWithGemini(text: newChunk)
                    } else if newChunk.count >= 2 {
                        self.silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
                            guard let self = self, self.currentTaskID == taskID, fullString.count > self.lastCommittedLength else { return }
                            let pendingChunk = String(fullString.dropFirst(self.lastCommittedLength))
                            self.lastCommittedLength = fullString.count
                            self.translateWithGemini(text: pendingChunk)
                        }
                    }
                }
            }
        }
    }

    private func restartRecognitionTask() {
        silenceTimer?.invalidate()
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()
        startRecognitionTask()
    }

    private func startMicrophone() {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        try? audioEngine.start()
    }

    private func startUDPListener() {
        let port = NWEndpoint.Port(rawValue: 9999)!
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        udpListener = try? NWListener(using: params, on: port)
        udpListener?.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .userInteractive))
            self?.receiveUDP(conn)
        }
        udpListener?.start(queue: .global(qos: .userInteractive))
    }

    private func receiveUDP(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty, let buffer = self.dataToPCMBuffer(data) {
                self.recognitionRequest?.append(buffer)
                DispatchQueue.main.async {
                    self.udpPacketsReceived += 1
                }
            }
            if error == nil { self.receiveUDP(conn) }
        }
    }

    private func dataToPCMBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        let frameCount = UInt32(data.count) / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: udpAudioFormat, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        data.withUnsafeBytes { ptr in
            if let addr = ptr.baseAddress {
                memcpy(buffer.int16ChannelData![0], addr, data.count)
            }
        }
        return buffer
    }
  
    func translateWithGemini(text: String) {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(cleanModel):generateContent?key=\(cleanKey)"
        guard let url = URL(string: urlStr) else { return }
        
        let startTime = Date()
        DispatchQueue.main.async { self.apiRequestCount += 1 }
        
        let recentContext = history.prefix(2).reversed().map { "\($0.originalText) -> \($0.translatedText)" }.joined(separator: "\n")
        
        let prompt = """
        你是一个专业的韩国/日本偶像直播实时同传翻译员。
        输入的语音识别文本可能因为直播背景音乐或口语吞音存在同音错别字。请先根据上下文与偶像粉丝圈词库在内部纠错，然后直接输出自然、口语化的中文翻译。禁止输出任何解释、标点说明或原文。
        
        【专属词库与人名对照】：
        \(customGlossary)
        
        【前文语境参考】：
        \(recentContext)
        
        【当前待翻译原句】：
        \(text)
        """
        
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": 120
            ]
        ]
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            let latency = Int(Date().timeIntervalSince(startTime) * 1000)
            
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { self.statusMessage = "网络请求失败" }
                return
            }
            
            if let errorDict = json["error"] as? [String: Any],
               let msg = errorDict["message"] as? String {
                DispatchQueue.main.async { self.statusMessage = "API 报错: \(msg)" }
                return
            }
            
            guard let candidates = json["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let resultText = parts.first?["text"] as? String else { return }
            
            let cleanResult = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
            
            DispatchQueue.main.async {
                self.liveTranslatedText = cleanResult
                PiPSubtitleManager.shared.updateSubtitle(original: text, translated: cleanResult)
                
                let item = TranscriptItem(timestamp: Date(), originalText: text, translatedText: cleanResult, latencyMs: latency)
                self.history.insert(item, at: 0)
                if self.history.count > 200 { self.history.removeLast() }
            }
        }.resume()
    }
}
  
