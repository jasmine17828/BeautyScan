import SwiftUI
import PhotosUI
import AVFoundation

struct PhotoTestView: View {
    @Bindable var engine: FaceMeasureEngine
    @State private var pickedItem: PhotosPickerItem?
    @State private var uiImage: UIImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { _ in
                if let uiImage, let cg = uiImage.cgImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .overlay(
                            ZStack {
                                PhotoOverlay(measures: engine.measures,
                                             imageSize: CGSize(width: cg.width, height: cg.height))
                                FaceBoxesOverlay(engine: engine)
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    CameraPlaceholderView()
                }
            }

            HStack(spacing: 8) {
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Label("選擇照片", systemImage: "photo.fill.on.rectangle.fill")
                        .padding(10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                // 放在 PhotoTestView 裡（Button 的 action 換成這段）
                Button {
                    if let cg = loadSampleFaceCG() {
                        self.uiImage = UIImage(cgImage: cg)
                        engine.process(cgImage: cg, orientation: .up)
                        print("[Sample] loaded SampleFace")
                    } else {
                        print("[Sample] SampleFace not found in Assets or bundle (jpg/jpeg/JPG/png)")
                    }
                } label: {
                    Label("載入範例", systemImage: "sparkles")
                        .padding(10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 64)
            .onChange(of: pickedItem) { _, newValue in
                Task {
                    guard let item = newValue else { return }
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data),
                       let cg = image.normalizedCGForVision() {
                        self.uiImage = UIImage(cgImage: cg)
                        engine.process(cgImage: cg, orientation: .up)
                    }
                }
            }
        }
    }
}

struct PhotoOverlay: View {
    let measures: [FaceMeasureEngine.Measure]
    let imageSize: CGSize

    var body: some View {
        GeometryReader { geo in
            let fit = fittedRect(forImage: imageSize, in: geo.size)
            Canvas { ctx, _ in
                var path = Path()

                func map(_ p01: CGPoint) -> CGPoint {
                    CGPoint(x: fit.minX + p01.x * fit.width,
                            y: fit.minY + p01.y * fit.height)
                }

                for m in measures {
                    for (a01, b01) in m.measureLines01 {
                        path.move(to: map(a01))
                        path.addLine(to: map(b01))
                    }
                    for p01 in m.points01 {
                        let p = map(p01)
                        path.addEllipse(in: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5))
                    }
                }

                ctx.stroke(path, with: .color(.blue), lineWidth: 3)
            }
        }
    }

    private func fittedRect(forImage img: CGSize, in view: CGSize) -> CGRect {
        guard img.width > 0 && img.height > 0 && view.width > 0 && view.height > 0 else { return .zero }
        let scale = min(view.width / img.width, view.height / img.height)
        let w = img.width * scale, h = img.height * scale
        return CGRect(x: (view.width - w) * 0.5, y: (view.height - h) * 0.5, width: w, height: h)
    }
}

struct FaceBoxesOverlay: View {
    @Bindable var engine: FaceMeasureEngine
    var body: some View {
        GeometryReader { geo in
            let imgSize = engine.lastImageSize
            let viewRect = CGRect(origin: .zero, size: geo.size)
            let fitted = AVMakeRect(aspectRatio: imgSize, insideRect: viewRect)
            ZStack {
                ForEach(Array(engine.lastFaces.enumerated()), id: \.offset) { _, face in
                    let r = map(face.boundingBox, into: fitted)
                    Path { p in p.addRect(r) }
                        .stroke(.blue, lineWidth: 3)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func map(_ norm: CGRect, into fitted: CGRect) -> CGRect {
        let x = fitted.origin.x + norm.minX * fitted.width
        let y = fitted.origin.y + (1.0 - norm.maxY) * fitted.height
        let w = norm.width * fitted.width
        let h = norm.height * fitted.height
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

struct CameraPlaceholderView: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [.gray.opacity(0.6), .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 12) {
                Image(systemName: "camera.on.rectangle")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Camera unavailable in Preview/Simulator")
                    .foregroundStyle(.white)
                    .font(.headline)
                Text("Run on a real device to see the live feed.")
                    .foregroundStyle(.white.opacity(0.8))
                    .font(.subheadline)
            }
        }
    }
}
// 嘗試從 Assets（UIImage(named:)）或 bundle 檔案抓 SampleFace，回傳 Vision-ready 的 CGImage
fileprivate func loadSampleFaceCG() -> CGImage? {
    // 優先從 Assets 讀（Image Set 名稱：SampleFace）
    if let img = UIImage(named: "SampleFace"),
       let cg = img.normalizedCGForVision() {
        return cg
    }
    // 再從 Bundle 根目錄用常見副檔名嘗試
    let exts = ["jpg", "jpeg", "JPG", "png"]
    for ext in exts {
        if let url = Bundle.main.url(forResource: "SampleFace", withExtension: ext),
           let data = try? Data(contentsOf: url),
           let ui = UIImage(data: data),
           let cg = ui.normalizedCGForVision() {
            return cg
        }
    }
    return nil
}
