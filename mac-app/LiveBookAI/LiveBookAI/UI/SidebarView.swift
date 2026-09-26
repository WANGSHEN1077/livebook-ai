import SwiftUI

/// Left sidebar: replay file + validation controls + screen capture placeholder.
struct SidebarView: View {
    @ObservedObject var model: LiveBookViewModel

    var body: some View {
        List {
            Section("回放（模拟直播窗口）") {
                Label(model.replayURL?.lastPathComponent ?? "未选择文件",
                      systemImage: "film")
                    .lineLimit(2)
                Button("选择回放文件…") {
                    model.pickReplayFile()
                }
                Button("加载默认 0813 回放") {
                    model.loadDefaultReplay()
                }
            }

            Section("控制") {
                if model.isCapturing {
                    Button("停止捕获") {
                        model.stopCapture()
                    }
                } else {
                    Button("开始捕获") {
                        model.startCapture()
                    }
                }
            }

            Section("回放速度") {
                Picker("倍速", selection: Binding(
                    get: { model.playbackSpeed },
                    set: { model.setSpeed($0) }
                )) {
                    Text("1x").tag(1.0)
                    Text("2x").tag(2.0)
                    Text("4x").tag(4.0)
                    Text("8x").tag(8.0)
                    Text("16x").tag(16.0)
                    Text("32x").tag(32.0)
                }
                .pickerStyle(.menu)
            }

            Section("基准校验（0813）") {
                Button {
                    model.runValidation()
                } label: {
                    if model.isValidating {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("运行 51 本校验", systemImage: "checkmark.seal")
                    }
                }
                .disabled(model.isValidating || model.replayURL == nil)
                if model.isValidating {
                    ProgressView(value: model.validationProgress)
                }
                if let summary = model.validationSummary {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("命中 \(summary.matched)/\(summary.total)")
                            .font(.headline)
                        Text("耗时 \(String(format: "%.1fs", summary.duration))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("真实直播窗口（微信）") {
                if model.isCapturingLive {
                    Label(model.availableWindows.first { $0.id == model.liveWindowID }?.title ?? "直播中",
                            systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                    if !model.recognizedBooks.isEmpty {
                        Text("已识别 \(model.recognizedBooks.count) 本")
                            .font(.caption)
                    }
                } else {
                    Button("扫描并选择微信直播窗口") {
                        Task { await model.loadWindows(autoSelect: true) }
                    }
                    if model.isLoadingWindows {
                        ProgressView().controlSize(.small)
                    }
                    if model.needsScreenPermission {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("需要屏幕录制权限（一次性）。允许后请重新启动 App。")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("打开系统设置 → 屏幕录制") {
                                model.openScreenRecordingSettings()
                            }
                            .font(.caption)
                        }
                    }
                    Picker("直播窗口", selection: Binding(
                        get: { model.selectedWindowID ?? 0 },
                        set: { model.selectWindowID($0) }
                    )) {
                        Text("未选择").tag(0)
                        ForEach(model.availableWindows, id: \.id) { w in
                            Text("\(w.title) [\(w.id)]").tag(Int(w.id))
                        }
                    }
                    .pickerStyle(.menu)
                    Button("开始实时识别直播") {
                        model.startLiveCaptureFromSelectedWindow()
                    }
                    .disabled(model.selectedWindowID == nil)
                }
                if !model.liveTranscript.isEmpty {
                    Text(model.liveTranscript)
                        .font(.caption)
                        .lineLimit(4)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.recognizedBooks, id: \.self) { title in
                    Label(title, systemImage: "book.closed")
                        .font(.caption)
                }
                if !model.auctionRecords.isEmpty {
                    Divider()
                    Text("成交记录")
                        .font(.subheadline)
                    ForEach(model.auctionRecords) { record in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(record.bookTitle)
                                    .lineLimit(2)
                                if let buyer = record.buyer {
                                    Text("买家: \(buyer)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let price = record.price {
                                Text("¥\(price)")
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundStyle(.green)
                            }
                        }
                        .font(.callout)
                    }
                    ForEach(model.auxBuyer != nil || model.auxPrice != nil ? [1] : [], id: \.self) { _ in
                        HStack {
                            Text("当前: \(model.auxBuyer ?? "—") ¥\(model.auxPrice.map(String.init) ?? "—")")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                if !model.coverCandidates.isEmpty {
                    Divider()
                    Text("封面书名候选")
                        .font(.subheadline)
                    ForEach(Array(model.coverCandidates.enumerated()), id: \.offset) { _, c in
                        Text(c)
                            .font(.caption)
                    }
                }
                if !model.settlementEvents.isEmpty {
                    Divider()
                    Text("成交信号（实时）")
                        .font(.subheadline)
                    ForEach(model.settlementEvents.prefix(20), id: \.self) { e in
                        Text(e)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !model.danmakuCurrentBids.isEmpty || !model.danmakuSettledWindows.isEmpty {
                    Divider()
                    Text("弹幕出价（实时）")
                        .font(.subheadline)
                    if !model.danmakuCurrentBids.isEmpty {
                        Text("当前窗口出价阶梯")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(model.danmakuCurrentBids) { bid in
                            HStack {
                                Text(bid.sender)
                                Spacer()
                                Text("¥\(bid.price)")
                                    .monospacedDigit()
                            }
                            .font(.caption)
                        }
                    }
                    if !model.danmakuSettledWindows.isEmpty {
                        Text("已结算 \(model.danmakuSettledWindows.count) 单")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(model.danmakuSettledWindows) { win in
                                    HStack {
                                        Text(win.buyer ?? "—")
                                        Spacer()
                                        Text("¥\(win.price ?? 0)")
                                            .foregroundStyle(.green)
                                    }
                                    .font(.caption)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                    }
                }
                if !model.danmakuLines.isEmpty {
                    Divider()
                    Text("弹幕")
                        .font(.subheadline)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.danmakuLines.enumerated()), id: \.offset) { _, d in
                                Text(d)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
            }
        }
        .listStyle(.sidebar)
    }
}
