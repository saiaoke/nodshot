//
//  ContentView.swift
//  NodShot —— 点头快门
//
//  注意：手机挂在脖子上时你是看不到屏幕的，
//  所以所有反馈都靠「声音 + 震动」，屏幕只用来"开拍前调参"。
//

import SwiftUI
import AVFoundation
import UIKit

@main
struct NodShotApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - 取景画面（后置摄像头的实时预览）
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var videoLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        videoLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct CameraPreviewView: UIViewRepresentable {
    let engine: CameraEngine

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        engine.attachPreview(view.videoLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        engine.attachPreview(uiView.videoLayer)
    }
}

struct ContentView: View {
    @StateObject private var engine = CameraEngine()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if engine.showPreview { previewCard }
                    statusCard
                    actionRow
                    meterCard
                    settingsCard
                    if engine.showDebug { debugCard }
                    footerCard
                }
                .padding(16)
            }
            .background(Color(white: 0.07).ignoresSafeArea())
            .navigationTitle("点头快门")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear { engine.stop() }
        }
    }

    // MARK: - 取景卡
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                CameraPreviewView(engine: engine)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                if !engine.running {
                    VStack(spacing: 6) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 34))
                            .foregroundStyle(.white.opacity(0.5))
                        Text("点「启动」后显示取景画面")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                } else if !engine.dualCamera {
                    Text("当前为单摄模式，取景画面来自前置摄像头")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(6)
                        .background(Color.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )

            Text("以上是后置摄像头看到的画面 —— 照片拍到的就是这个范围。产品要完整落在框里。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 状态卡
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(engine.running ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                Text(engine.running ? "相机运行中" : "相机未启动")
                    .font(.headline)
                Spacer()
                Text(engine.dualCamera ? "双摄" : "单摄")
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
            }
            Text(engine.hint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 大按钮
    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                if engine.running { engine.stop() } else { engine.start() }
            } label: {
                Text(engine.running ? "停止" : "启动")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }
            .buttonStyle(.plain)
            .background(engine.running ? Color.red.opacity(0.85) : Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Button {
                engine.recalibrate()
            } label: {
                Text("重新标定")
                    .font(.subheadline.bold())
                    .frame(width: 100)
                    .padding(.vertical, 18)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.12))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - 实时指标
    private var meterCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(engine.faceVisible ? "已锁定人脸" : "未检测到人脸",
                      systemImage: engine.faceVisible ? "face.smiling.fill" : "face.dashed")
                    .font(.subheadline.bold())
                    .foregroundStyle(engine.faceVisible ? Color.green : Color.orange)
                Spacer()
                Text("触发：\(engine.triggerMode.rawValue)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            meter(title: "点头幅度", value: engine.nodRatio)
            meter(title: "张嘴幅度", value: engine.mouthRatio)

            Text("条形超过 100% 就会拍一张。挂到脖子上以后你看不到这里，所以先把手机拿在手里调好。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func meter(title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", value * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(value >= 1 ? .green : .secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.12))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(value >= 1 ? Color.green : Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(min(max(value, 0), 1)))
                }
            }
            .frame(height: 8)
        }
    }

    // MARK: - 设置
    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("触发方式").font(.caption).foregroundStyle(.secondary)
                Picker("触发方式", selection: $engine.triggerMode) {
                    ForEach(TriggerMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("灵敏度").font(.subheadline)
                    Spacer()
                    Text(String(format: "%.2f", engine.sensitivity))
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $engine.sensitivity, in: 0...1)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("两次拍摄最小间隔").font(.subheadline)
                    Spacer()
                    Text(String(format: "%.1f 秒", engine.cooldown))
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $engine.cooldown, in: 0.6...5.0)
            }

            Toggle("测试模式（只震动不拍照）", isOn: $engine.testMode)
            Toggle("显示取景画面（挂好机位后可关掉省电）", isOn: $engine.showPreview)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("拍实况图（Live Photo，带 3 秒动态）", isOn: $engine.livePhoto)
                if engine.running && !engine.livePhotoSupported {
                    Text("双摄模式下系统不允许直接拍实况。开启后：点头 → App 自动切到后置单摄拍真·实况（约 1~2 秒延迟）→ 自动切回点头检测。产品是静物，延迟无影响。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !engine.liveStatusText.isEmpty {
                    Text(engine.liveStatusText)
                        .font(.caption2)
                        .foregroundStyle(engine.liveStatusText.contains("成功") ? Color.green : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle("竖屏挂法（多数情况打开）", isOn: $engine.upright)
            Toggle("显示调试数值", isOn: $engine.showDebug)
        }
        .padding(14)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .tint(.accentColor)
    }

    private var debugCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("调试").font(.caption).foregroundStyle(.secondary)
            Text(engine.debugText)
                .font(.caption.monospaced())
                .foregroundStyle(.green)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 底部
    private var footerCard: some View {
        HStack(spacing: 14) {
            Group {
                if let img = engine.lastShot {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.white.opacity(0.08)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text("本次已拍 \(engine.shotCount) 张")
                    .font(.headline)
                Text("上次触发 \(engine.lastFireTime) · 照片已存入「最近项目」")
                    .font(.caption).foregroundStyle(.secondary)
                Text("版本 v7（启动失败自动拆掉重建 + 先置空再等释放）")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    ContentView()
}
