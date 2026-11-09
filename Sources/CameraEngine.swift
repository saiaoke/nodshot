//
//  CameraEngine.swift
//  NodShot —— 点头快门
//
//  一句话原理：
//  前置摄像头（对着你的脸）实时跑 Vision 人脸识别 → 算出"头往下掉了多少"
//  后置摄像头（对着产品）负责真正拍高清照片
//  两个摄像头用 AVCaptureMultiCamSession 同时打开（iPhone XS 及以后都支持）
//

import AVFoundation
import Photos
import UIKit
import Vision
import AudioToolbox
import os

enum TriggerMode: String, CaseIterable, Identifiable {
    case nod = "点头"
    case mouth = "张嘴"
    case both = "点头或张嘴"
    var id: String { rawValue }
}

final class CameraEngine: NSObject, ObservableObject {

    // MARK: - 可调参数（UI 上暴露）
    @Published var triggerMode: TriggerMode = .nod
    @Published var sensitivity: Double = 0.55 { didSet { recomputeThresholds() } }
    @Published var cooldown: Double = 1.6
    @Published var testMode: Bool = false          // 只震不动，用来调灵敏度
    @Published var upright: Bool = true            // 竖着挂（竖屏方向）
    @Published var showDebug: Bool = false
    @Published var showPreview: Bool = true        // 显示后置摄像头取景画面（挂脖后可以关掉省电降温）

    // MARK: - 运行状态（UI 只读）
    @Published private(set) var running = false
    @Published private(set) var faceVisible = false
    @Published private(set) var nodRatio: Double = 0     // 已除以阈值，>=1 就是触发
    @Published private(set) var mouthRatio: Double = 0
    @Published private(set) var shotCount = 0
    @Published private(set) var lastShot: UIImage?
    @Published private(set) var hint: String = "点「启动」开始。先手拿手机对着脸测一次。"
    @Published private(set) var dualCamera = false
    @Published private(set) var debugText: String = ""
    @Published private(set) var lastFireTime: String = "--"

    // MARK: - 取景画面（后置摄像头实时预览）
    // 图层由界面上的 PreviewView 创建（苹果官方做法），引擎只负责把摄像头接上去
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var previewPort: AVCaptureInput.Port?
    private var previewMirrored = false

    /// 界面上的预览图层就绪后调用；可重复调用，内部幂等
    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        layer.videoGravity = .resizeAspectFill
        if previewLayer === layer, layer.connection != nil { return }
        previewLayer = layer
        configurePreviewIfPossible()
    }

    private func configurePreviewIfPossible() {
        guard let layer = previewLayer, let s = session, let port = previewPort else { return }
        let needsConfig = s.isRunning
        if needsConfig { s.beginConfiguration() }
        if layer.session !== s { layer.setSessionWithNoConnection(s) }
        if layer.connection == nil {
            let c = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
            if s.canAddConnection(c) {
                s.addConnection(c)
                c.videoRotationAngle = 90
                c.isVideoMirrored = previewMirrored
            }
        }
        if needsConfig { s.commitConfiguration() }
    }

    // MARK: - 私有
    private var session: AVCaptureSession?
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let analysisQueue = DispatchQueue(label: "nodshot.analysis", qos: .userInitiated)
    private let faceRequest = VNDetectFaceLandmarksRequest()
    private var lastAnalyze: CFAbsoluteTime = 0

    private var baselineY: Double?      // 中性姿态时脸的垂直中心（自动标定）
    private var baselineH: Double = 0.3 // 中性姿态时脸的高度
    private var smoothDrop: Double = 0  // 平滑后的"头往下掉"量（单位：脸高）
    private var smoothMouth: Double = 0 // 平滑后的张嘴幅度（单位：脸高）
    private var nodArmed = true
    private var mouthArmed = true
    private var lastFire: CFAbsoluteTime = 0

    private var nodThreshold: Double = 0.20
    private var mouthThreshold: Double = 0.055

    override init() {
        super.init()
        recomputeThresholds()
    }

    // MARK: - 阈值映射
    private func recomputeThresholds() {
        let s = max(0.0, min(1.0, sensitivity))
        nodThreshold = 0.34 - 0.26 * s      // 灵敏度 0 → 0.34，1 → 0.08
        mouthThreshold = 0.085 - 0.055 * s  // 灵敏度 0 → 0.085，1 → 0.030
    }

    // MARK: - 启动 / 停止
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    if ok { self.start() } else { self.hint = "没有相机权限，请到 设置 > NodShot 打开" }
                }
            }
            return
        default:
            hint = "相机权限被关闭了：设置 > NodShot > 相机"
            return
        }

        if session == nil {
            do { try buildSession() }
            catch {
                hint = "相机初始化失败：\(error.localizedDescription)"
                return
            }
        }
        guard let s = session, !s.isRunning else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            s.startRunning()
            let ok = s.isRunning
            var cost: Float = 0
            if let mc = s as? AVCaptureMultiCamSession { cost = mc.hardwareCost }
            DispatchQueue.main.async {
                self.running = ok
                self.hint = ok ? (self.dualCamera ? "已启动，点头即可拍照" : "已启动（单摄模式，只能试触发不能存图）")
                                 : "启动失败，可能被其他 App 占用"
                self.debugText = String(format: "hardwareCost %.2f", Double(cost))
            }
        }
        requestPhotoPermission()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        guard let s = session else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            if s.isRunning { s.stopRunning() }
            DispatchQueue.main.async {
                self.running = false
                self.faceVisible = false
                self.nodRatio = 0
                self.mouthRatio = 0
                self.hint = "已停止"
            }
        }
    }

    func recalibrate() {
        analysisQueue.async {
            self.baselineY = nil
            self.smoothDrop = 0
            self.nodArmed = true
            DispatchQueue.main.async { self.hint = "已重新标定，保持正脸 1 秒" }
        }
    }

    // MARK: - 建 session
    private struct EngineError: LocalizedError {
        let msg: String
        var errorDescription: String? { msg }
    }

    private func buildSession() throws {
        let multiOK = AVCaptureMultiCamSession.isMultiCamSupported
        let s: AVCaptureSession = multiOK ? AVCaptureMultiCamSession() : AVCaptureSession()
        s.beginConfiguration()

        guard let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            s.commitConfiguration()
            throw EngineError(msg: "找不到前置摄像头")
        }
        let frontInput = try AVCaptureDeviceInput(device: front)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: analysisQueue)

        var dual = false
        // 预览用哪一个摄像头的画面：有后摄就显示后摄（产品那边），否则显示前摄
        previewPort = nil
        previewMirrored = false

        if multiOK, let rear = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           s.canAddInput(frontInput) {
            let rearInput = try AVCaptureDeviceInput(device: rear)

            s.addInputWithNoConnections(frontInput)
            s.addInputWithNoConnections(rearInput)
            s.addOutputWithNoConnections(videoOutput)
            s.addOutputWithNoConnections(photoOutput)

            // 前置 → 视频流（给 Vision 分析）
            if let port = frontInput.ports(for: .video,
                                           sourceDeviceType: .builtInWideAngleCamera,
                                           sourceDevicePosition: .front).first {
                let c = AVCaptureConnection(inputPorts: [port], output: videoOutput)
                if s.canAddConnection(c) { s.addConnection(c) }
            }
            // 后置 → 照片输出（真正拍照）
            if let port = rearInput.ports(for: .video,
                                          sourceDeviceType: .builtInWideAngleCamera,
                                          sourceDevicePosition: .back).first {
                let c = AVCaptureConnection(inputPorts: [port], output: photoOutput)
                if s.canAddConnection(c) {
                    s.addConnection(c)
                    c.videoRotationAngle = 90     // 手机竖着挂在胸前 → 照片正着
                    c.isVideoMirrored = false
                    dual = true
                    previewPort = port              // 取景画面用后置
                }
            }
        } else if s.canAddInput(frontInput) {
            // 兜底：只有前置，只能做触发测试
            s.addInput(frontInput)
            if s.canAddOutput(videoOutput) { s.addOutput(videoOutput) }
            previewPort = frontInput.ports(for: .video,
                                           sourceDeviceType: .builtInWideAngleCamera,
                                           sourceDevicePosition: .front).first
            previewMirrored = true
        }

        session = s
        dualCamera = dual
        // 取景画面：界面上的图层如果已经就绪，这里把摄像头接上
        configurePreviewIfPossible()

        s.commitConfiguration()
    }

    // MARK: - 权限
    private func requestPhotoPermission() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
    }

    // MARK: - 触发
    private func fire() {
        lastFire = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            self.lastFireTime = f.string(from: Date())
        }
        AudioServicesPlaySystemSound(1108)   // 系统快门声

        if testMode {
            DispatchQueue.main.async { self.hint = "测试触发成功（未拍照）" }
            return
        }
        guard dualCamera, let s = session, s.isRunning else {
            DispatchQueue.main.async { self.hint = "单摄/测试模式，未保存照片" }
            return
        }
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func setHint(_ text: String) {
        DispatchQueue.main.async { if self.hint != text { self.hint = text } }
    }
}

// MARK: - 视频流 → Vision
extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAnalyze > 0.04 else { return }   // 约 25 次/秒，够用又不烫
        lastAnalyze = now

        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let orientation: CGImagePropertyOrientation = upright ? .leftMirrored : .up
        let handler = VNImageRequestHandler(cvPixelBuffer: pixel, orientation: orientation, options: [:])
        do {
            try handler.perform([faceRequest])
        } catch {
            return
        }

        guard let face = faceRequest.results?.first else {
            smoothDrop *= 0.5
            smoothMouth *= 0.5
            DispatchQueue.main.async {
                self.faceVisible = false
                self.nodRatio = 0
                self.mouthRatio = 0
            }
            if smoothDrop < nodThreshold * 0.4 { nodArmed = true }
            setHint("没看到脸：手机要向上仰 30~45°（建议用硬质挂脖支架），让前置摄像头照到整张脸")
            return
        }

        process(face: face, now: now)
    }

    private func process(face: VNFaceObservation, now: CFAbsoluteTime) {
        let box = face.boundingBox
        let cy = Double(box.midY)
        let h = Double(box.height)
        guard h > 0.02 else { return }

        // —— 自动基线：脸往上走就跟得快，往下走几乎不动（避免"点着头就被当成新常态"）
        if baselineY == nil { baselineY = cy; baselineH = h }
        if let b = baselineY {
            if cy > b { baselineY = b + (cy - b) * 0.12 }
            else { baselineY = b + (cy - b) * 0.0015 }
        }
        let base = baselineY ?? cy
        let drop = (base - cy) / max(h, 0.04)

        smoothDrop = smoothDrop * 0.6 + drop * 0.4

        // —— 张嘴幅度：内唇上下距离 / 脸高
        var mouth = 0.0
        if let lm = face.landmarks {
            if let lips = lm.innerLips ?? lm.outerLips, lips.pointCount > 2 {
                var lo = 1.0, hi = 0.0
                for p in lips.normalizedPoints {
                    lo = min(lo, Double(p.y))
                    hi = max(hi, Double(p.y))
                }
                mouth = max(0, hi - lo)
            }
        }
        smoothMouth = smoothMouth * 0.6 + mouth * 0.4

        // —— 触发判定
        let sizeOK = abs(h / max(baselineH, 0.01) - 1.0) < 0.5   // 脸忽大忽小（转头/离开）就不给触发
        let ready = (now - lastFire) > cooldown

        if smoothDrop < nodThreshold * 0.45 { nodArmed = true }
        if smoothMouth < mouthThreshold * 0.5 { mouthArmed = true }

        var fired = false
        if ready && sizeOK {
            switch triggerMode {
            case .nod:
                if nodArmed && smoothDrop > nodThreshold { nodArmed = false; fired = true }
            case .mouth:
                if mouthArmed && smoothMouth > mouthThreshold { mouthArmed = false; fired = true }
            case .both:
                if nodArmed && smoothDrop > nodThreshold { nodArmed = false; fired = true }
                else if mouthArmed && smoothMouth > mouthThreshold { mouthArmed = false; fired = true }
            }
        }

        let nodN = smoothDrop / max(nodThreshold, 0.001)
        let mouthN = smoothMouth / max(mouthThreshold, 0.001)
        let dbg = String(format: "face cy %.3f  h %.3f  drop %.3f  mouth %.3f  base %.3f",
                         cy, h, smoothDrop, smoothMouth, base)

        DispatchQueue.main.async {
            self.faceVisible = true
            self.nodRatio = nodN
            self.mouthRatio = mouthN
            if self.showDebug { self.debugText = dbg }
        }

        if fired { fire() }
    }
}

// MARK: - 保存照片
extension CameraEngine: AVCapturePhotoCaptureDelegate {

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            setHint("拍照失败：\(error?.localizedDescription ?? "未知错误")")
            return
        }
        let image = UIImage(data: data)
        DispatchQueue.main.async {
            self.lastShot = image
            self.shotCount += 1
            self.hint = "已拍第 \(self.shotCount) 张"
        }
        save(data: data)
    }

    private func save(data: Data) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.setHint("没有相册写入权限：设置 > NodShot > 照片")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { ok, err in
                if !ok { self.setHint("存相册失败：\(err?.localizedDescription ?? "")") }
            }
        }
    }
}
