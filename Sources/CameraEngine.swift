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

    // MARK: - 实况图（Live Photo）
    /// 用户是否想拍实况图。切换后需要重建 session 才生效
    @Published var livePhoto: Bool = false {
        didSet {
            guard oldValue != livePhoto, running else { return }
            rebuildSession()
        }
    }
    /// 当前配置（双摄/单摄）下系统是否允许实况 —— 运行时查询
    @Published private(set) var livePhotoSupported = false

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
    /// 上一次实况拍摄的结果说明（显示在实况开关下方，帮我们诊断动态部分是否成功）
    @Published private(set) var liveStatusText: String = ""

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
                // ⚠️ 多摄模式下对预览连接设置镜像/旋转属性会直接抛异常（连"查询是否支持"都不行）
                // 所以这里什么都不设：预览图层会自动跟随竖屏方向
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

    // 实况图：照片与动态视频两部分都到了才算完成（苹果不保证回调先后顺序）
    private var awaitingLiveMovie = false
    private var livePendingPhotoData: Data?
    private var livePendingMovieURL: URL?

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
                self.debugText = String(format: "hardwareCost %.2f · 画质上限 %@ · 实况支持 %@",
                                        Double(cost),
                                        self.qualityName(self.photoOutput.maxPhotoQualityPrioritization),
                                        self.photoOutput.isLivePhotoCaptureSupported ? "是" : "否")
                if ok && self.livePhoto && !self.livePhotoSupported {
                    self.hint = "已启动（此配置不支持实况，拍普通照片）"
                }
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

    /// 切换实况开关后需要重建 session（实况必须在 startRunning 之前配置）
    private func rebuildSession() {
        guard let old = session else { return }
        running = false
        faceVisible = false
        hint = "正在重启相机…"
        DispatchQueue.global(qos: .userInitiated).async {
            if old.isRunning { old.stopRunning() }
            DispatchQueue.main.async {
                self.session = nil
                self.start()
            }
        }
    }

    func recalibrate() {        analysisQueue.async {
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
                    // 不设置旋转/镜像：多摄模式下这些属性的读写都可能抛异常
                    // 照片方向如果不对，用软件旋转修正（安全，不碰系统 API）
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

        // ⚠️ 支持性必须在 commitConfiguration 之后查询（配置块内恒为 false，已踩坑）
        //    注意：双摄多摄会话大概率仍然真不支持实况，这里修正后能查到真实值
        if dual && photoOutput.isLivePhotoCaptureSupported {
            photoOutput.isLivePhotoCaptureEnabled = livePhoto
            livePhotoSupported = true
        } else {
            livePhotoSupported = false
        }
    }

    // MARK: - 权限
    private func requestPhotoPermission() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
    }

    // MARK: - 触发
    private func fire() {
        guard !liveCaptureBusy else { return }   // 单摄拍实况期间不接受新触发
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

        // 想拍实况 + 双摄模式不允许 → 自动切到后置单摄拍真·实况（约1~2秒延迟）
        if livePhoto && !livePhotoSupported {
            captureLiveViaSingleCam()
            return
        }

        let settings = AVCapturePhotoSettings()
        // 自动用当前配置允许的最高画质：系统允许 .quality 就用 .quality，
        // 不允许（多摄模式限制）就自动落到系统上限。这是苹果官方示例的标准写法。
        settings.photoQualityPrioritization = photoOutput.maxPhotoQualityPrioritization

        // 实况图：照片 + 约 3 秒动态
        let useLive = livePhoto && livePhotoSupported && photoOutput.isLivePhotoCaptureEnabled
        awaitingLiveMovie = useLive
        livePendingPhotoData = nil
        if useLive {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("nodshot-live-\(UUID().uuidString).mov")
            settings.livePhotoMovieFileURL = url
        }

        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - 切换单摄拍真·实况（双摄模式下系统不允许实况，这是绕过办法）
    /// 切换期间为 true，冻结一切触发
    private var liveCaptureBusy = false
    /// 实况专用、每次新建的独立照片输出。
    /// ⚠️ 苹果规定同一个 AVCaptureOutput 不能挂到两个 session——复用多摄的 photoOutput
    /// 会在 startRunning 时内核断言崩溃（日志: attachToFigCaptureSession → SIGABRT，已踩坑）
    private var livePhotoOutput: AVCapturePhotoOutput?

    /// 点头触发后：停双摄 → 建后置单摄 session（开实况）→ 拍 → 存 → 切回双摄
    private func captureLiveViaSingleCam() {
        guard !liveCaptureBusy, let old = session else { return }
        liveCaptureBusy = true
        DispatchQueue.main.async {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        setHint("正在切换单摄拍实况（约1~2秒）…")
        AudioServicesPlaySystemSound(1108)

        DispatchQueue.global(qos: .userInitiated).async {
            // 1) 停双摄并解除输出/输入关联（输入也要解除，释放后置摄像头占用）
            if old.isRunning { old.stopRunning() }
            old.beginConfiguration()
            for o in old.outputs { old.removeOutput(o) }
            for i in old.inputs { old.removeInput(i) }
            old.commitConfiguration()

            // 2) 建后置单摄 session，开实况
            do {
                let s = try self.buildLiveSession()
                self.session = s
                s.startRunning()
                var tries = 0
                while !s.isRunning && tries < 40 { usleep(100_000); tries += 1 }

                if s.isRunning, let out = self.livePhotoOutput, out.isLivePhotoCaptureEnabled {
                    // 3) 等 0.4 秒让画质/对焦稳定，再拍实况
                    usleep(400_000)
                    let settings = AVCapturePhotoSettings()
                    settings.photoQualityPrioritization = out.maxPhotoQualityPrioritization
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("nodshot-live-\(UUID().uuidString).mov")
                    self.awaitingLiveMovie = true
                    self.livePendingPhotoData = nil
                    self.livePendingMovieURL = nil
                    settings.livePhotoMovieFileURL = url
                    self.setHint("实况拍摄中…")
                    self.setLiveStatus("实况拍摄中…（照片+动态视频）")
                    out.capturePhoto(with: settings, delegate: self)

                    // 保底：6 秒后实况还没完成就存静帧并切回
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                        guard let self, self.liveCaptureBusy, self.awaitingLiveMovie else { return }
                        if let d = self.livePendingPhotoData { self.save(data: d) }
                        self.awaitingLiveMovie = false
                        self.livePendingPhotoData = nil
                        self.livePendingMovieURL = nil
                        self.setHint("实况处理超时，已存普通照片")
                        self.setLiveStatus("上次实况：处理超时，只存了普通照片（长按不会动）")
                        self.restoreMultiCam()
                    }
                } else {
                    // 单摄也不给实况（极小概率）：直接拍普通照片
                    self.setHint("此设备不支持实况，拍普通照片")
                    self.setLiveStatus("上次实况：单摄也不支持实况（设备限制），存了普通照片")
                    usleep(400_000)
                    if let out = self.livePhotoOutput {
                        let settings = AVCapturePhotoSettings()
                        settings.photoQualityPrioritization = out.maxPhotoQualityPrioritization
                        out.capturePhoto(with: settings, delegate: self)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        self?.restoreMultiCam()
                    }
                }
            } catch {
                self.setHint("实况初始化失败：\(error.localizedDescription)")
                self.restoreMultiCam()
            }
        }
    }

    /// 后置单摄 + 实况照片输出的临时 session
    private func buildLiveSession() throws -> AVCaptureSession {
        guard let rear = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw EngineError(msg: "找不到后置摄像头")
        }
        let s = AVCaptureSession()
        // ⚠️ 必须用 .photo 预设：新建 session 默认是 .high（视频预设），
        //    照片输出在视频预设下 isLivePhotoCaptureSupported 恒为 false（已踩坑）
        //    .photo 预设 = 支持实况 + 照片全分辨率 12MP
        s.sessionPreset = .photo
        s.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: rear)
        guard s.canAddInput(input) else {
            s.commitConfiguration()
            throw EngineError(msg: "无法添加后置摄像头")
        }
        s.addInput(input)
        // ⚠️ 每次新建独立的 PhotoOutput，绝不复用多摄 session 的那个——
        // 同一个 output 挂两个 session 会在 startRunning 时内核断言崩溃（SIGABRT，已踩坑）
        let out = AVCapturePhotoOutput()
        guard s.canAddOutput(out) else {
            s.commitConfiguration()
            throw EngineError(msg: "无法添加照片输出")
        }
        s.addOutput(out)
        s.commitConfiguration()
        // ⚠️ isLivePhotoCaptureSupported 必须在 commitConfiguration 之后查询——
        //    配置块内查询恒为 false（已踩坑：被误判为"设备不支持"）。
        //    苹果官方 AVCam 示例也是提交配置后再开启实况。
        if out.isLivePhotoCaptureSupported {
            out.isLivePhotoCaptureEnabled = true
        }
        self.livePhotoOutput = out
        return s
    }

    /// 实况拍完后切回双摄（点头检测恢复）
    private func restoreMultiCam() {
        DispatchQueue.global(qos: .userInitiated).async {
            if let cur = self.session {
                if cur.isRunning { cur.stopRunning() }
                cur.beginConfiguration()
                for o in cur.outputs { cur.removeOutput(o) }
                for i in cur.inputs { cur.removeInput(i) }
                cur.commitConfiguration()
            }
            DispatchQueue.main.async {
                self.session = nil
                self.livePhotoOutput = nil     // 用完即弃，下次实况再新建
                self.liveCaptureBusy = false
                self.baselineY = nil        // 相机换了，重新标定基线
                self.nodArmed = false       // ⚠️ 必须先复位（抬头/闭嘴）才允许下一次触发，
                self.mouthArmed = false     //    否则嘴还张着就会立刻连拍（已踩坑：一次张嘴出3张）
                self.lastFire = CFAbsoluteTimeGetCurrent()   // 冷却时间重新起算
                self.start()
            }
        }
    }

    private func setHint(_ text: String) {
        DispatchQueue.main.async { if self.hint != text { self.hint = text } }
    }

    private func setLiveStatus(_ text: String) {
        DispatchQueue.main.async { if self.liveStatusText != text { self.liveStatusText = text } }
    }

    private func qualityName(_ q: AVCapturePhotoOutput.QualityPrioritization) -> String {
        switch q {
        case .speed: return "speed"
        case .balanced: return "balanced"
        case .quality: return "quality"
        @unknown default: return String(q.rawValue)
        }
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
            awaitingLiveMovie = false
            setHint("拍照失败：\(error?.localizedDescription ?? "未知错误")")
            if liveCaptureBusy { restoreMultiCam() }   // 实况流程中静帧都失败，直接切回
            return
        }
        let image = UIImage(data: data)
        DispatchQueue.main.async {
            self.lastShot = image
            self.shotCount += 1
            self.hint = self.awaitingLiveMovie ? "已拍第 \(self.shotCount) 张（实况，处理中）"
                                               : "已拍第 \(self.shotCount) 张"
        }

        if awaitingLiveMovie {
            // 照片部分到了；视频部分到了就立即组装实况，没到就等它
            livePendingPhotoData = data
            tryFinishLive()
        } else {
            save(data: data)
        }
    }

    /// 照片 + 视频两部分都到齐 → 组装成实况照片存入相册
    private func tryFinishLive() {
        guard let data = livePendingPhotoData, let url = livePendingMovieURL else { return }
        awaitingLiveMovie = false
        saveLive(photoData: data, movieURL: url)
        livePendingPhotoData = nil
        livePendingMovieURL = nil
        setHint("已存实况照片，长按会动 ✅")
        setLiveStatus("上次实况：成功，相册里长按照片会动")
        if liveCaptureBusy { restoreMultiCam() }        // 单摄实况流程：切回双摄
    }

    // 实况的动态视频处理完成（可能比照片回调先到，也可能后到）
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingLivePhotoToMovieFileAt movieFileURL: URL,
                     duration: CMTime,
                     photoDisplayTime: CMTime,
                     resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        guard awaitingLiveMovie else { return }

        if let error = error {
            // 动态视频确实失败了：保住静帧，报出具体原因
            awaitingLiveMovie = false
            let data = livePendingPhotoData
            livePendingPhotoData = nil
            livePendingMovieURL = nil
            if let data = data { save(data: data) }
            setHint("实况保存失败：\(error.localizedDescription)")
            setLiveStatus("上次实况：动态视频失败（\(error.localizedDescription)），只存了普通照片")
            if liveCaptureBusy { restoreMultiCam() }
            return
        }

        // 视频部分到了；照片部分到了就立即组装实况，没到就等它
        livePendingMovieURL = movieFileURL
        tryFinishLive()
    }

    private func saveLive(photoData: Data, movieURL: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.setHint("没有相册写入权限：设置 > NodShot > 照片")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: photoData, options: nil)
                let opts = PHAssetResourceCreationOptions()
                opts.shouldMoveFile = true
                req.addResource(with: .pairedVideo, fileURL: movieURL, options: opts)
            } completionHandler: { ok, err in
                if !ok { self.setHint("存实况失败：\(err?.localizedDescription ?? "")") }
            }
        }
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
