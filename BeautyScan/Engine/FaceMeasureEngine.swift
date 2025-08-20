import SwiftUI
import AVFoundation
import Vision
import UIKit
import CoreImage
import ImageIO
import Observation

@Observable
final class FaceMeasureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    // MARK: Camera（不需要觸發 UI 觀察）
    @ObservationIgnored private let session = AVCaptureSession()
    @ObservationIgnored private let videoQueue = DispatchQueue(label: "face.measure.camera")
    @ObservationIgnored private var videoOutput: AVCaptureVideoDataOutput?

    // MARK: Vision / CI（同樣不需要被觀察）
    @ObservationIgnored private let seqHandler = VNSequenceRequestHandler()
    @ObservationIgnored private let ciContext = CIContext(options: [CIContextOption.useSoftwareRenderer: true])
    @ObservationIgnored private lazy var ciFaceDetector: CIDetector? = {
        CIDetector(ofType: CIDetectorTypeFace,
                   context: ciContext,
                   options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    }()

    // Observable state properties (for UI)
    var lastFaces: [VNFaceObservation] = []
    var lastImageSize: CGSize = .zero
    private var lastFaceDetectTime: CFTimeInterval = 0
    private let detectInterval: CFTimeInterval = 0.5

    // 只在「Xcode Previews 畫布」才為 true；一般模擬器與真機為 false
    private let isPreviewContext: Bool = {
            #if DEBUG
            ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
            #else
            false
            #endif
        }()


    private func ciFeatures(in cgImage: CGImage) -> [CIFaceFeature] {
        let opts: [String: Any] = [
            CIDetectorImageOrientation: 1,
            CIDetectorMinFeatureSize: 0.15
        ]
        return (ciFaceDetector?.features(in: CIImage(cgImage: cgImage), options: opts) as? [CIFaceFeature]) ?? []
    }
    private func ciFeatures(in pixelBuffer: CVPixelBuffer) -> [CIFaceFeature] {
        let opts: [String: Any] = [
            CIDetectorImageOrientation: 1,
            CIDetectorMinFeatureSize: 0.15
        ]
        return (ciFaceDetector?.features(in: CIImage(cvPixelBuffer: pixelBuffer), options: opts) as? [CIFaceFeature]) ?? []
    }

    private func detectFacesWithCI(cgImage: CGImage) -> [VNFaceObservation] {
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        guard w > 0, h > 0 else { return [] }
        return ciFeatures(in: cgImage).map { f in
            VNFaceObservation(boundingBox: CGRect(x: f.bounds.minX / w,
                                                  y: f.bounds.minY / h,
                                                  width:  f.bounds.width / w,
                                                  height: f.bounds.height / h))
        }
    }

    private func makeMeasuresFromCIFeatures(_ feats: [CIFaceFeature], imgW: CGFloat, imgH: CGFloat) -> [Measure] {
        feats.enumerated().map { (idx, f) in
            var ipdPx: CGFloat?
            var ipLine01: (CGPoint, CGPoint)?
            if f.hasLeftEyePosition && f.hasRightEyePosition {
                let l = f.leftEyePosition, r = f.rightEyePosition
                ipdPx = hypot(r.x - l.x, r.y - l.y)
                ipLine01 = (CGPoint(x: l.x/imgW, y: 1 - l.y/imgH),
                            CGPoint(x: r.x/imgW, y: 1 - r.y/imgH))
            }
            let faceWidthPx = max(f.bounds.width, 1)
            func ratio(_ v: CGFloat?) -> CGFloat? { v.map { $0 / faceWidthPx } }

            var points01: [CGPoint] = []
            if f.hasLeftEyePosition { let p = f.leftEyePosition;  points01.append(.init(x: p.x/imgW, y: 1 - p.y/imgH)) }
            if f.hasRightEyePosition{ let p = f.rightEyePosition; points01.append(.init(x: p.x/imgW, y: 1 - p.y/imgH)) }
            if f.hasMouthPosition   { let p = f.mouthPosition;    points01.append(.init(x: p.x/imgW, y: 1 - p.y/imgH)) }

            return Measure(faceID: idx,
                           imageSize: .init(width: imgW, height: imgH),
                           ipdPx: ipdPx, noseWidthPx: nil, mouthWidthPx: nil, jawLengthPx: nil,
                           ipdRatio: ratio(ipdPx), noseRatio: nil, mouthRatio: nil, jawRatio: nil,
                           points01: points01, measureLines01: ipLine01.map{[$0]} ?? [])
        }
    }

    var measures: [Measure] = []

    // MARK: Process CGImage (photo)
    func process(cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) {
        let imgW = CGFloat(cgImage.width), imgH = CGFloat(cgImage.height)
        print("[Vision] input cg: \(Int(imgW))x\(Int(imgH)) ori: \(orientation.rawValue)")
        lastImageSize = .init(width: imgW, height: imgH)

        if isPreviewContext { // Previews 畫布避免 Vision Code=9
            lastFaces = detectFacesWithCI(cgImage: cgImage)
            let outs = makeMeasuresFromCIFeatures(ciFeatures(in: cgImage), imgW: imgW, imgH: imgH)
            print("[CI] Previews path faces: \(lastFaces.count), measures: \(outs.count)")
            DispatchQueue.main.async { self.measures = Array(outs.prefix(1)) }
            return
        }

        var usedCIRects = false
        let rectReq = VNDetectFaceRectanglesRequest()
        rectReq.revision = VNDetectFaceRectanglesRequest.currentRevision
        if #unavailable(iOS 17) { rectReq.usesCPUOnly = true }
        do {
            try VNImageRequestHandler(cgImage: cgImage, orientation: orientation).perform([rectReq])
            lastFaces = rectReq.results ?? []
            print("[Vision] Rect faces:", lastFaces.count)
        } catch {
            print("[Vision] Rect perform error:", error.localizedDescription)
            usedCIRects = true
            lastFaces = []
        }
        if lastFaces.isEmpty {
            let ci = detectFacesWithCI(cgImage: cgImage)
            if !ci.isEmpty { usedCIRects = true; lastFaces = ci; print("[CI] Fallback faces:", ci.count) }
        }
        guard !lastFaces.isEmpty else { DispatchQueue.main.async { self.measures = [] }; return }

        if usedCIRects {
            let outs = makeMeasuresFromCIFeatures(ciFeatures(in: cgImage), imgW: imgW, imgH: imgH)
            print("[CI] Landmarks via CI. measures:", outs.count)
            DispatchQueue.main.async { self.measures = Array(outs.prefix(1)) }
            return
        }

        guard let biggest = lastFaces.max(by: { a, b in
            (a.faceCaptureQuality ?? 0, area(a)) < (b.faceCaptureQuality ?? 0, area(b))
        }) else { return }

        let lmReq = VNDetectFaceLandmarksRequest { [weak self] req, _ in
            guard let self else { return }
            let results = (req.results as? [VNFaceObservation]) ?? []
            if results.isEmpty {
                let outs = self.makeMeasuresFromCIFeatures(self.ciFeatures(in: cgImage), imgW: imgW, imgH: imgH)
                print("[CI] Fallback landmarks:", outs.count)
                DispatchQueue.main.async { self.measures = Array(outs.prefix(1)) }
                return
            }

            var outs: [Measure] = []
            for (idx, face) in results.enumerated() {
                guard let lms = face.landmarks else { continue }

                func denorm01(_ p: CGPoint, in bb: CGRect) -> CGPoint {
                    CGPoint(x: bb.minX + p.x * bb.width, y: 1 - (bb.minY + p.y * bb.height))
                }
                func imgPx(_ p01: CGPoint) -> CGPoint { .init(x: p01.x * imgW, y: p01.y * imgH) }
                func centroid(_ reg: VNFaceLandmarkRegion2D) -> CGPoint {
                    let pts = (0..<reg.pointCount).map { reg.normalizedPoints[$0] }
                    let sx = pts.reduce(0){$0+$1.x}, sy = pts.reduce(0){$0+$1.y}
                    return .init(x: sx/CGFloat(pts.count), y: sy/CGFloat(pts.count))
                }
                func leftRightMost(_ reg: VNFaceLandmarkRegion2D) -> (CGPoint, CGPoint)? {
                    guard reg.pointCount > 0 else { return nil }
                    var minX: CGFloat = .greatestFiniteMagnitude, maxX: CGFloat = -.greatestFiniteMagnitude
                    var L = CGPoint.zero, R = CGPoint.zero
                    for i in 0..<reg.pointCount {
                        let p = reg.normalizedPoints[i]
                        if p.x < minX { minX = p.x; L = p }
                        if p.x > maxX { maxX = p.x; R = p }
                    }
                    return (L, R)
                }
                func polyLenPx(_ reg: VNFaceLandmarkRegion2D, bb: CGRect) -> CGFloat {
                    guard reg.pointCount > 1 else { return 0 }
                    var sum: CGFloat = 0
                    var prev = imgPx(denorm01(reg.normalizedPoints[0], in: bb))
                    for i in 1..<reg.pointCount {
                        let cur = imgPx(denorm01(reg.normalizedPoints[i], in: bb))
                        sum += hypot(cur.x - prev.x, cur.y - prev.y)
                        prev = cur
                    }
                    return sum
                }

                let bb = face.boundingBox
                let faceW = max(bb.width * imgW, 1)

                var ipdPx: CGFloat?, ipLine01: (CGPoint, CGPoint)?
                if let le = lms.leftEye, let re = lms.rightEye {
                    let cL = centroid(le), cR = centroid(re)
                    let pL01 = denorm01(cL, in: bb), pR01 = denorm01(cR, in: bb)
                    let pL = imgPx(pL01), pR = imgPx(pR01)
                    ipdPx = hypot(pR.x - pL.x, pR.y - pL.y)
                    ipLine01 = (pL01, pR01)
                }

                var noseWidthPx: CGFloat?, noseLine01: (CGPoint, CGPoint)?
                if let nose = lms.nose, let (nL, nR) = leftRightMost(nose) {
                    let pL01 = denorm01(nL, in: bb), pR01 = denorm01(nR, in: bb)
                    let pL = imgPx(pL01), pR = imgPx(pR01)
                    noseWidthPx = hypot(pR.x - pL.x, pR.y - pL.y)
                    noseLine01 = (pL01, pR01)
                }

                var mouthWidthPx: CGFloat?, mouthLine01: (CGPoint, CGPoint)?
                if let lips = lms.outerLips, let (mL, mR) = leftRightMost(lips) {
                    let pL01 = denorm01(mL, in: bb), pR01 = denorm01(mR, in: bb)
                    let pL = imgPx(pL01), pR = imgPx(pR01)
                    mouthWidthPx = hypot(pR.x - pL.x, pR.y - pL.y)
                    mouthLine01 = (pL01, pR01)
                }

                var jawLengthPx: CGFloat?
                if let contour = lms.faceContour {
                    jawLengthPx = polyLenPx(contour, bb: bb)
                }

                func ratio(_ v: CGFloat?) -> CGFloat? { v.map { $0 / faceW } }

                var points01: [CGPoint] = []
                if let le = lms.leftEye, let re = lms.rightEye {
                    points01.append(denorm01(centroid(le), in: bb))
                    points01.append(denorm01(centroid(re), in: bb))
                }
                if let c = lms.faceContour {
                    for i in 0..<c.pointCount { points01.append(denorm01(c.normalizedPoints[i], in: bb)) }
                }

                var lines01: [(CGPoint, CGPoint)] = []
                if let l = ipLine01 { lines01.append(l) }
                if let l = noseLine01 { lines01.append(l) }
                if let l = mouthLine01 { lines01.append(l) }

                outs.append(Measure(faceID: idx,
                                    imageSize: .init(width: imgW, height: imgH),
                                    ipdPx: ipdPx, noseWidthPx: noseWidthPx, mouthWidthPx: mouthWidthPx, jawLengthPx: jawLengthPx,
                                    ipdRatio: ratio(ipdPx), noseRatio: ratio(noseWidthPx), mouthRatio: ratio(mouthWidthPx), jawRatio: ratio(jawLengthPx),
                                    points01: points01, measureLines01: lines01))
            }

            DispatchQueue.main.async { self.measures = Array(outs.prefix(1)) }
        }
        if #unavailable(iOS 17) { lmReq.usesCPUOnly = true }
        lmReq.revision = VNDetectFaceLandmarksRequest.supportedRevisions.min() ?? VNDetectFaceLandmarksRequest.currentRevision
        lmReq.inputFaceObservations = [biggest]
        do {
            try VNImageRequestHandler(cgImage: cgImage, orientation: orientation).perform([lmReq])
        } catch {
            let outs = makeMeasuresFromCIFeatures(ciFeatures(in: cgImage), imgW: imgW, imgH: imgH)
            print("[CI] Fallback landmarks (perform error):", outs.count)
            DispatchQueue.main.async { self.measures = Array(outs.prefix(1)) }
        }
    }

    // MARK: Process CVPixelBuffer (camera)
    func process(pixelBuffer px: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up) {
        let imgW = CGFloat(CVPixelBufferGetWidth(px)), imgH = CGFloat(CVPixelBufferGetHeight(px))
        print("[Vision] input px: \(Int(imgW))x\(Int(imgH)) ori: \(orientation.rawValue)")
        let old = lastImageSize; lastImageSize = .init(width: imgW, height: imgH)
        if old != lastImageSize { lastFaceDetectTime = 0 }

        let now = CACurrentMediaTime()
        if now - lastFaceDetectTime > detectInterval || lastFaces.isEmpty {
            let rectReq = VNDetectFaceRectanglesRequest()
            rectReq.revision = VNDetectFaceRectanglesRequest.currentRevision
            if #unavailable(iOS 17) { rectReq.usesCPUOnly = true }
            do {
                try VNImageRequestHandler(cvPixelBuffer: px, orientation: orientation).perform([rectReq])
                lastFaces = rectReq.results ?? []
                print("[Vision] Rect faces:", lastFaces.count)
                lastFaceDetectTime = now
            } catch { /* keep last */ }
        }

        guard !lastFaces.isEmpty else { DispatchQueue.main.async { self.measures = [] }; return }

        guard let biggest = lastFaces.max(by: { a, b in
            (a.faceCaptureQuality ?? 0, area(a)) < (b.faceCaptureQuality ?? 0, area(b))
        }) else { return }

        let lmReq = VNDetectFaceLandmarksRequest { [weak self] req, _ in
            guard let self else { return }
            let results = (req.results as? [VNFaceObservation]) ?? []
            if results.isEmpty {
                let outs = self.makeMeasuresFromCIFeatures(self.ciFeatures(in: px), imgW: imgW, imgH: imgH)
                print("[CI] Fallback landmarks (px):", outs.count)
                DispatchQueue.main.async { self.measures = Array(outs.prefix(1)) }
                return
            }

            var outs: [Measure] = []
            for (idx, face) in results.enumerated() {
                guard let lms = face.landmarks else { continue }

                func denorm01(_ p: CGPoint, in bb: CGRect) -> CGPoint {
                    CGPoint(x: bb.minX + p.x * bb.width, y: 1 - (bb.minY + p.y * bb.height))
                }
                func imgPx(_ p01: CGPoint) -> CGPoint { .init(x: p01.x * imgW, y: p01.y * imgH) }
                func centroid(_ reg: VNFaceLandmarkRegion2D) -> CGPoint {
                    let pts = (0..<reg.pointCount).map { reg.normalizedPoints[$0] }
                    let sx = pts.reduce(0){$0+$1.x}, sy = pts.reduce(0){$0+$1.y}
                    return .init(x: sx/CGFloat(pts.count), y: sy/CGFloat(pts.count))
                }
                func leftRightMost(_ reg: VNFaceLandmarkRegion2D) -> (CGPoint, CGPoint)? {
                    guard reg.pointCount > 0 else { return nil }
                    var minX: CGFloat = .greatestFiniteMagnitude, maxX: CGFloat = -.greatestFiniteMagnitude
                    var L = CGPoint.zero, R = CGPoint.zero
                    for i in 0..<reg.pointCount {
                        let p = reg.normalizedPoints[i]
                        if p.x < minX { minX = p.x; L = p }
                        if p.x > maxX { maxX = p.x; R = p }
                    }
                    return (L, R)
                }
                func polyLenPx(_ reg: VNFaceLandmarkRegion2D, bb: CGRect) -> CGFloat {
                    guard reg.pointCount > 1 else { return 0 }
                    var sum: CGFloat = 0
                    var prev = imgPx(denorm01(reg.normalizedPoints[0], in: bb))
                    for i in 1..<reg.pointCount {
                        let cur = imgPx(denorm01(reg.normalizedPoints[i], in: bb))
                        sum += hypot(cur.x - prev.x, cur.y - prev.y)
                        prev = cur
                    }
                    return sum
                }

                let bb = face.boundingBox
                let faceW = max(bb.width * imgW, 1)

                var ipdPx: CGFloat?, ipLine01: (CGPoint, CGPoint)?
                if let le = lms.leftEye, let re = lms.rightEye {
                    let cL = centroid(le), cR = centroid(re)
                    let pL01 = denorm01(cL, in: bb), pR01 = denorm01(cR, in: bb)
                    let pL = imgPx(pL01), pR = imgPx(pR01)
                    ipdPx = hypot(pR.x - pL.x, pR.y - pL.y)
                    ipLine01 = (pL01, pR01)
                }

                var noseWidthPx: CGFloat?, noseLine01: (CGPoint, CGPoint)?
                if let nose = lms.nose, let (nL, nR) = leftRightMost(nose) {
                    let pL01 = denorm01(nL, in: bb), pR01 = denorm01(nR, in: bb)
                    let pL = imgPx(pL01), pR = imgPx(pR01)
                    noseWidthPx = hypot(pR.x - pL.x, pR.y - pL.y)
                    noseLine01 = (pL01, pR01)
                }

                var mouthWidthPx: CGFloat?, mouthLine01: (CGPoint, CGPoint)?
                if let lips = lms.outerLips, let (mL, mR) = leftRightMost(lips) {
                    let pL01 = denorm01(mL, in: bb), pR01 = denorm01(mR, in: bb)
                    let pL = imgPx(pL01), pR = imgPx(pR01)
                    mouthWidthPx = hypot(pR.x - pL.x, pR.y - pL.y)
                    mouthLine01 = (pL01, pR01)
                }

                var jawLengthPx: CGFloat?
                if let contour = lms.faceContour {
                    jawLengthPx = polyLenPx(contour, bb: bb)
                }

                func ratio(_ v: CGFloat?) -> CGFloat? { v.map { $0 / faceW } }

                var points01: [CGPoint] = []
                if let le = lms.leftEye, let re = lms.rightEye {
                    points01.append(denorm01(centroid(le), in: bb))
                    points01.append(denorm01(centroid(re), in: bb))
                }
                if let c = lms.faceContour {
                    for i in 0..<c.pointCount { points01.append(denorm01(c.normalizedPoints[i], in: bb)) }
                }

                var lines01: [(CGPoint, CGPoint)] = []
                if let l = ipLine01 { lines01.append(l) }
                if let l = noseLine01 { lines01.append(l) }
                if let l = mouthLine01 { lines01.append(l) }

                outs.append(Measure(faceID: idx,
                                    imageSize: .init(width: imgW, height: imgH),
                                    ipdPx: ipdPx, noseWidthPx: noseWidthPx, mouthWidthPx: mouthWidthPx, jawLengthPx: jawLengthPx,
                                    ipdRatio: ratio(ipdPx), noseRatio: ratio(noseWidthPx), mouthRatio: ratio(mouthWidthPx), jawRatio: ratio(jawLengthPx),
                                    points01: points01, measureLines01: lines01))
            }

            DispatchQueue.main.async { self.measures = Array(outs.prefix(1)) }
        }
        if #unavailable(iOS 17) { lmReq.usesCPUOnly = true }
        lmReq.revision = VNDetectFaceLandmarksRequest.supportedRevisions.min() ?? VNDetectFaceLandmarksRequest.currentRevision
        lmReq.inputFaceObservations = [biggest]
        do {
            try VNImageRequestHandler(cvPixelBuffer: px, orientation: orientation).perform([lmReq])
        } catch {
            let outs = makeMeasuresFromCIFeatures(ciFeatures(in: px), imgW: imgW, imgH: imgH)
            print("[CI] Fallback landmarks (px perform error):", outs.count)
            DispatchQueue.main.async { self.measures = Array(outs.prefix(1)) }
        }
    }

    // Camera lifecycle
    func start() {
        guard session.inputs.isEmpty else { session.startRunning(); return }
        session.beginConfiguration()
        session.sessionPreset = .high

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { return }
        session.addInput(input)

        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(out) { session.addOutput(out) }
        out.connections.first?.isVideoMirrored = true
        self.videoOutput = out

        session.commitConfiguration()
        session.startRunning()
    }

    func stop() { session.stopRunning() }

    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let l = AVCaptureVideoPreviewLayer(session: session)
        l.videoGravity = .resizeAspectFill
        return l
    }

    // Per-frame
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sb) else { return }
        let ori: CGImagePropertyOrientation = connection.isVideoMirrored ? .upMirrored : .up
        self.process(pixelBuffer: px, orientation: ori)
    }

    // 單張臉的量測輸出（像素＋比例）
    struct Measure: Identifiable {
        let id = UUID()
        let faceID: Int
        let imageSize: CGSize
        let ipdPx: CGFloat?
        let noseWidthPx: CGFloat?
        let mouthWidthPx: CGFloat?
        let jawLengthPx: CGFloat?
        let ipdRatio: CGFloat?
        let noseRatio: CGFloat?
        let mouthRatio: CGFloat?
        let jawRatio: CGFloat?
        let points01: [CGPoint]
        let measureLines01: [(CGPoint, CGPoint)]
    }
}

private func area(_ f: VNFaceObservation) -> CGFloat {
    f.boundingBox.width * f.boundingBox.height
}
// 讓 navigationDestination(item:) 可以用 Measure 當 item
extension FaceMeasureEngine.Measure: Hashable {
    static func == (lhs: FaceMeasureEngine.Measure, rhs: FaceMeasureEngine.Measure) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
