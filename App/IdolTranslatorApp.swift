import SwiftUI
import ReplayKit

@main
struct IdolTranslatorApp: App {
    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }
}

// MARK: - 画中画内嵌预览画布
struct PiPPreviewCanvas: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.layer.cornerRadius = 10
        view.clipsToBounds = true
        
        let layer = PiPSubtitleManager.shared.displayLayer
        layer.videoGravity = .resizeAspect
        view.layer.addSublayer(layer)
        PiPSubtitleManager.shared.setupPiP()
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            PiPSubtitleManager.shared.displayLayer.frame = uiView.bounds
        }
    }
}

// MARK: - 系统录屏广播选择器封装
struct SystemBroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.showsMicrophoneButton = false
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

// MARK: - 顶层三栏 Tab 导航
struct MainTabView: View {
    @StateObject private var engine = TranslatorEngine()
    @StateObject private var pipManager = PiPSubtitleManager.shared
    
    @AppStorage("gemini_api_key") private var apiKey: String = ""
    @AppStorage("gemini_model_name") private var modelName: String = "gemini-2.5-flash"
    @AppStorage("source_lang") private var selectedLangRaw: String = SourceLang.korean.rawValue
    @AppStorage("input_mode") private var selectedModeRaw: String = InputMode.systemAudio.rawValue
    @AppStorage("segment_length") private var segmentLength: Double = 14.0
    @AppStorage("pip_font_size") private var pipFontSize: Double = 36.0
    @AppStorage("pip_bilingual") private var pipBilingual: Bool = true
    @AppStorage("pip_theme") private var pipThemeRaw: String = PiPTheme.classicDark.rawValue
    @AppStorage("custom_glossary") private var customGlossary: String = """
    Liz / 리즈 / 金志垣 -> Liz
    Gaeul / 가을 -> 秋天
    Wonyoung / 원영 -> 员瑛
    Yujin / 유진 -> 宥真
    Rei / 레이 -> Rei
    Leeseo / 이서 -> 李瑞
    다이브 -> DIVE
    사쿠라 / 꾸라 -> 咲良(小樱花)
    광수 -> 光洙
    컴백 -> 回归
    본방사수 -> 死守本放
    """

    var body: some View {
        TabView {
            DashboardView(
                engine: engine,
                pipManager: pipManager,
                selectedLangRaw: $selectedLangRaw,
                selectedModeRaw: $selectedModeRaw,
                onSyncSettings: syncSettingsToEngine
            )
            .tabItem {
                Label("同传控制台", systemImage: "waveform.circle.fill")
            }

            HistoryListView(engine: engine)
                .tabItem {
                    Label("直播字幕记录", systemImage: "bubble.left.and.bubble.right.fill")
                }

            SettingsView(
                engine: engine,
                pipManager: pipManager,
                apiKey: $apiKey,
                modelName: $modelName,
                segmentLength: $segmentLength,
                pipFontSize: $pipFontSize,
                pipBilingual: $pipBilingual,
                pipThemeRaw: $pipThemeRaw,
                customGlossary: $customGlossary,
                onSyncSettings: syncSettingsToEngine
            )
            .tabItem {
                Label("配置与词库", systemImage: "slider.horizontal.3")
            }
        }
        .onAppear {
            engine.requestPermissions()
            syncSettingsToEngine()
        }
    }

    private func syncSettingsToEngine() {
        engine.apiKey = apiKey
        engine.modelName = modelName
        engine.currentLang = SourceLang(rawValue: selectedLangRaw) ?? .korean
        engine.currentMode = InputMode(rawValue: selectedModeRaw) ?? .systemAudio
        engine.segmentLengthThreshold = Int(segmentLength)
        engine.customGlossary = customGlossary
        
        pipManager.fontSize = CGFloat(pipFontSize)
        pipManager.showBilingual = pipBilingual
        pipManager.theme = PiPTheme(rawValue: pipThemeRaw) ?? .classicDark
        pipManager.renderCurrentFrame()
    }
}

// MARK: - Tab 1: 同传主控仪表盘
struct DashboardView: View {
    @ObservedObject var engine: TranslatorEngine
    @ObservedObject var pipManager: PiPSubtitleManager
    @Binding var selectedLangRaw: String
    @Binding var selectedModeRaw: String
    var onSyncSettings: () -> Void

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(engine.isRunning ? Color.green : Color.gray)
                            .frame(width: 12, height: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.statusMessage)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("已收内录包: \(engine.udpPacketsReceived) | 已请求翻译: \(engine.apiRequestCount) 次")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("画中画悬浮窗实时画面预览", systemImage: "pip")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(pipManager.isPiPActive ? "已悬浮置顶" : "未弹出")
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(pipManager.isPiPActive ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                                .foregroundColor(pipManager.isPiPActive ? .green : .secondary)
                                .cornerRadius(6)
                        }
                        
                        PiPPreviewCanvas()
                            .frame(height: 88)
                            .shadow(radius: 3)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("实时识别原文")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        Text(engine.liveRecognizedText)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(.tertiarySystemBackground))
                            .cornerRadius(8)

                        HStack {
                            Text("Gemini 实时中文译文")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        Text(engine.liveTranslatedText)
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.blue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(.tertiarySystemBackground))
                            .cornerRadius(8)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    VStack(spacing: 12) {
                        Picker("识别语言", selection: $selectedLangRaw) {
                            ForEach(SourceLang.allCases, id: \.rawValue) { lang in
                                Text(lang.displayName).tag(lang.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: selectedLangRaw) { _ in
                            onSyncSettings()
                            if engine.isRunning { engine.start() }
                        }

                        Picker("音频输入源", selection: $selectedModeRaw) {
                            ForEach(InputMode.allCases, id: \.rawValue) { mode in
                                Text(mode.rawValue).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: selectedModeRaw) { _ in
                            onSyncSettings()
                            if engine.isRunning { engine.start() }
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    VStack(spacing: 12) {
                        Button(action: {
                            onSyncSettings()
                            engine.isRunning ? engine.stop() : engine.start()
                        }) {
                            HStack {
                                Image(systemName: engine.isRunning ? "stop.fill" : "play.fill")
                                Text(engine.isRunning ? "停止同传翻译引擎" : "第一步：启动同传翻译引擎")
                                    .fontWeight(.bold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(engine.isRunning ? Color.red : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }

                        Button(action: {
                            pipManager.togglePiP()
                        }) {
                            HStack {
                                Image(systemName: pipManager.isPiPActive ? "pip.exit" : "pip.enter")
                                Text(pipManager.isPiPActive ? "收回画中画悬浮字幕条" : "第二步：弹出画中画悬浮字幕条")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.indigo)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }

                        if selectedModeRaw == InputMode.systemAudio.rawValue {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("第三步：点击右侧按钮开启系统内录")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Text("在弹出列表中选择「直播内录捕获」，随后切去直播 App 即可")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                SystemBroadcastPicker()
                                    .frame(width: 44, height: 44)
                                    .background(Color.orange.opacity(0.15))
                                    .clipShape(Circle())
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("爱豆直播同传台")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Tab 2: 历史字幕记录流
struct HistoryListView: View {
    @ObservedObject var engine: TranslatorEngine
    @State private var showCopiedToast = false

    var body: some View {
        NavigationView {
            Group {
                if engine.history.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("暂无直播字幕记录")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("启动翻译引擎后，所有识别到的原句与中文翻译都会按时间轴保存在这里。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                } else {
                    List {
                        ForEach(engine.history) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(item.timestamp, style: .time)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(item.latencyMs) ms")
                                        .font(.caption2)
                                        .foregroundColor(item.latencyMs < 1500 ? .green : .orange)
                                }
                                Text(item.originalText)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                Text(item.translatedText)
                                    .font(.body)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                            }
                            .padding(.vertical, 4)
                            .contextMenu {
                                Button(action: {
                                    UIPasteboard.general.string = "\(item.originalText)\n\(item.translatedText)"
                                }) {
                                    Label("复制双语内容", systemImage: "doc.on.doc")
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("直播字幕历史 (\(engine.history.count))")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !engine.history.isEmpty {
                        Button(role: .destructive, action: { engine.clearHistory() }) {
                            Text("清空")
                                .foregroundColor(.red)
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !engine.history.isEmpty {
                        Button(action: {
                            UIPasteboard.general.string = engine.exportHistoryText()
                            showCopiedToast = true
                        }) {
                            Label("复制全部", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .alert("已复制整场直播记录到剪贴板", isPresented: $showCopiedToast) {
                Button("好", role: .cancel) {}
            }
        }
    }
}

// MARK: - Tab 3: 高阶设置与专属词库
struct SettingsView: View {
    @ObservedObject var engine: TranslatorEngine
    @ObservedObject var pipManager: PiPSubtitleManager
    
    @Binding var apiKey: String
    @Binding var modelName: String
    @Binding var segmentLength: Double
    @Binding var pipFontSize: Double
    @Binding var pipBilingual: Bool
    @Binding var pipThemeRaw: String
    @Binding var customGlossary: String
    var onSyncSettings: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Gemini API 配置"), footer: Text("推荐使用 gemini-2.5-flash 或 gemini-3.1-flash-lite，兼顾低延迟与极低 Token 成本。")) {
                    SecureField("粘贴 Gemini API Key", text: $apiKey)
                        .onChange(of: apiKey) { _ in onSyncSettings() }
                    
                    TextField("模型名称 (如 gemini-2.5-flash)", text: $modelName)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .onChange(of: modelName) { _ in onSyncSettings() }
                    
                    Button("发送测试文本验证 API 与画中画") {
                        onSyncSettings()
                        engine.translateWithGemini(text: "오늘 콘서트 와주셔서 진짜 너무 고마워요 다이브 사랑해요!")
                    }
                }

                Section(header: Text("画中画 (PiP) 悬浮窗样式调节")) {
                    Picker("字幕配色主题", selection: $pipThemeRaw) {
                        ForEach(PiPTheme.allCases, id: \.rawValue) { theme in
                            Text(theme.rawValue).tag(theme.rawValue)
                        }
                    }
                    .onChange(of: pipThemeRaw) { _ in onSyncSettings() }

                    Toggle("同屏显示双语 (原文 + 译文)", isOn: $pipBilingual)
                        .onChange(of: pipBilingual) { _ in onSyncSettings() }

                    VStack(alignment: .leading) {
                        Text("悬浮窗译文字号: \(Int(pipFontSize)) pt")
                            .font(.subheadline)
                        Slider(value: $pipFontSize, in: 24...52, step: 2)
                            .onChange(of: pipFontSize) { _ in onSyncSettings() }
                    }
                }

                Section(header: Text("断句灵敏度调节"), footer: Text("字数越少字幕刷新越快，但过短可能导致语境不完整；韩语直播建议设为 12~16 字。")) {
                    VStack(alignment: .leading) {
                        Text("单次触发翻译字数阈值: \(Int(segmentLength)) 字")
                            .font(.subheadline)
                        Slider(value: $segmentLength, in: 6...30, step: 2)
                            .onChange(of: segmentLength) { _ in onSyncSettings() }
                    }
                }

                Section(header: Text("爱豆专有名词与黑话词库 (防同音错字)"), footer: Text("本地语音识别常把爱豆名字识别成同音词，在此处维护对照表后，Gemini 会在翻译时自动纠错。")) {
                    TextEditor(text: $customGlossary)
                        .frame(minHeight: 160)
                        .font(.system(.footnote, design: .monospaced))
                        .onChange(of: customGlossary) { _ in onSyncSettings() }
                }
            }
            .navigationTitle("配置与专属词库")
        }
    }
}
