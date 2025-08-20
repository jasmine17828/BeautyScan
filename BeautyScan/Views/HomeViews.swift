import SwiftUI
import Observation
#if canImport(Charts)
import Charts
#endif

struct HomeView: View {
    // 資料
    @State private var store = RecordStore()

    // 偵測（照片/相機）Sheet
    @State private var showDetectSheet = false
    @State private var engine = FaceMeasureEngine()
    @State private var pendingMeasure: FaceMeasureEngine.Measure? = nil

    // 圖表 Sheet
    @State private var showChartSheet = false
    @State private var chosenSubject: String? = nil
    @State private var chosenProcedure: String? = nil
    @State private var chosenMetric: MetricKind = .ipdPx

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    // 1) 開始臉部偵測
                    Button {
                        showDetectSheet = true
                    } label: {
                        Text("開始臉部偵測（選照片或載入範例）")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)

                    // 2) 最近 5 筆
                    VStack(alignment: .leading, spacing: 12) {
                        Text("最近 5 筆紀錄")
                            .font(.title3.bold())
                            .padding(.horizontal, 20)

                        if store.records.isEmpty {
                            Text("目前沒有任何紀錄")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 20)
                        } else {
                            // 為避免型別推斷過慢，先準備資料
                            let recent = Array(store.records.prefix(5))
                            ForEach(recent) { rec in
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        // 主標：對象
                                        Text(rec.subject.isEmpty ? "未指定對象" : rec.subject)
                                            .font(.headline)
                                        // 副標：療程 + 日期
                                        let dateText = rec.date.formatted(date: .abbreviated, time: .shortened)
                                        Text("\(rec.procedure.isEmpty ? "未填寫療程" : rec.procedure) · \(dateText)")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    // 右側顯示目前選定指標的值
                                    if let v = chosenMetric.value(from: rec.metrics) {
                                        Text(String(format: "%.1f %@", v, chosenMetric.unit))
                                            .font(.subheadline.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                                .padding(.horizontal, 20)
                            }
                        }
                    }

                    // 3) 產生圖表
                    Button {
                        showChartSheet = true
                    } label: {
                        Text("產生圖表")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                }
                .padding(.vertical, 16)
            }
            .navigationTitle("BeautyScan")
            .navigationBarTitleDisplayMode(.inline)
        }
        // ===== 偵測流程（Sheet）=====
        .sheet(isPresented: $showDetectSheet) {
            NavigationStack {
                // 你的 PhotoTestView：載入照片/範例 → engine.measures
                PhotoTestView(engine: engine)
                    .navigationTitle("臉部偵測")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("關閉") { showDetectSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("下一步") {
                                if let m = engine.measures.first {
                                    pendingMeasure = m
                                }
                            }
                            .disabled(engine.measures.first == nil)
                        }
                    }
                    // 偵測完成 → 建立紀錄（第二層 sheet）
                    .sheet(item: $pendingMeasure) { m in
                        NavigationStack {
                            DetectRecordForm(
                                store: store,
                                measure: m,
                                defaultSubject: store.lastSubject
                            ) {
                                // onDone：收尾
                                showDetectSheet = false
                                pendingMeasure = nil
                                // 清空引擎狀態（可選）
                                engine.measures = []
                            }
                        }
                    }
            }
        }
        // ===== 圖表（Sheet）=====
        .sheet(isPresented: $showChartSheet) {
            NavigationStack {
                Form {
                    Section {
                        Picker("對象", selection: $chosenSubject) {
                            Text("全部對象").tag(Optional<String>.none)
                            ForEach(store.subjects, id: \.self) { s in
                                Text(s).tag(Optional<String>.some(s))
                            }
                        }
                        Picker("療程", selection: $chosenProcedure) {
                            Text("全部療程").tag(Optional<String>.none)
                            ForEach(store.procedures, id: \.self) { p in
                                Text(p).tag(Optional<String>.some(p))
                            }
                        }
                        Picker("數據", selection: $chosenMetric) {
                            ForEach(MetricKind.allCases) { kind in
                                Text(kind.rawValue).tag(kind)
                            }
                        }
                    }

                    let series: [(Date, Double)] =
                        store.chartSeries(subject: chosenSubject,
                                          procedure: chosenProcedure,
                                          metric: chosenMetric)

                    #if canImport(Charts)
                    if series.isEmpty {
                        Text("沒有可畫的資料").foregroundStyle(.secondary)
                    } else {
                        Chart {
                            ForEach(series, id: \.0) { pair in
                                let d = pair.0
                                let v = pair.1
                                LineMark(x: .value("日期", d),
                                         y: .value(chosenMetric.rawValue, v))
                                PointMark(x: .value("日期", d),
                                          y: .value(chosenMetric.rawValue, v))
                            }
                        }
                        .frame(height: 260)
                        .padding(.vertical, 8)
                    }
                    #else
                    if series.isEmpty {
                        Text("沒有可畫的資料").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("（未啟用 Charts）資料點：\(series.count) 筆")
                                .font(.footnote).foregroundStyle(.secondary)
                            ForEach(series, id: \.0) { pair in
                                let d = pair.0
                                let v = pair.1
                                Text("\(d.formatted(date: .abbreviated, time: .omitted))  \(String(format: "%.1f", v)) \(chosenMetric.unit)")
                                    .font(.subheadline.monospaced())
                            }
                        }
                    }
                    #endif
                }
                .navigationTitle("產生圖表")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showChartSheet = false }
                    }
                }
                .onAppear {
                    // 預設圖表對象＝上次使用對象
                    if chosenSubject == nil && !store.lastSubject.isEmpty {
                        chosenSubject = store.lastSubject
                    }
                }
            }
        }
    }
}

// ===== 偵測完成 → 建立紀錄表單 =====
private struct DetectRecordForm: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: RecordStore
    let measure: FaceMeasureEngine.Measure
    var defaultSubject: String = ""
    var onDone: () -> Void

    // 表單欄位
    @State private var date: Date = .now
    @State private var subjectPick: String? = nil
    @State private var subjectInput: String = ""
    @State private var procedurePick: String? = nil
    @State private var procedureInput: String = ""
    @State private var showWarnSubject = false
    @State private var showWarnProcedure = false

    var body: some View {
        Form {
            Section("對象") {
                Picker("從歷史選擇", selection: $subjectPick) {
                    Text("請選擇").tag(Optional<String>.none)
                    ForEach(store.subjects, id: \.self) { s in
                        Text(s).tag(Optional<String>.some(s))
                    }
                }
                TextField("對象名稱（例如：自己、客戶A）", text: $subjectInput)
            }

            Section("日期與時間") {
                DatePicker("量測時間", selection: $date)
            }

            Section("做了什麼？") {
                Picker("從歷史選擇", selection: $procedurePick) {
                    Text("請選擇").tag(Optional<String>.none)
                    ForEach(store.procedures, id: \.self) { p in
                        Text(p).tag(Optional<String>.some(p))
                    }
                }
                TextField("音波、肉毒、按摩…", text: $procedureInput)
            }

            Section("偵測數據（像素）") {
                metricRow("瞳距 IPD", measure.ipdPx)
                metricRow("鼻翼寬", measure.noseWidthPx)
                metricRow("嘴角距", measure.mouthWidthPx)
                metricRow("下顎線長度", measure.jawLengthPx)
            }
        }
        .navigationTitle("建立紀錄")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("儲存") {
                    // 對象必填
                    let subjPicked = subjectPick ?? ""
                    let subjTyped  = subjectInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    let finalSubj  = subjPicked.isEmpty ? subjTyped : subjPicked
                    guard !finalSubj.isEmpty else {
                        showWarnSubject = true
                        return
                    }
                    // 療程必填
                    let procPicked = procedurePick ?? ""
                    let procTyped  = procedureInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    let finalProc  = procPicked.isEmpty ? procTyped : procPicked
                    guard !finalProc.isEmpty else {
                        showWarnProcedure = true
                        return
                    }
                    // 存檔
                    store.addFromMeasure(measure,
                                         subject: finalSubj,
                                         procedure: finalProc,
                                         date: date)
                    onDone()
                    dismiss()
                }
            }
        }
        .onAppear {
            // 預帶上次對象
            if subjectPick == nil && subjectInput.isEmpty && !defaultSubject.isEmpty {
                subjectPick = defaultSubject
            }
        }
        .alert("請先輸入對象名稱", isPresented: $showWarnSubject) {
            Button("好") { }
        }
        .alert("請先選或輸入療程名稱", isPresented: $showWarnProcedure) {
            Button("好") { }
        }
    }

    // 顯示單筆指標
    @ViewBuilder
    private func metricRow(_ title: String, _ value: CGFloat?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let v = value {
                Text(String(format: "%.1f px", v))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
    }
}




