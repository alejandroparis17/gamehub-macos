// Convierte una secuencia de PNG (f_<n>.png) en un MP4 H.264 en bucle (los últimos 15 frames se funden con los primeros)
// uso: mkclip <carpeta> <salida.mp4> [fps]
import AVFoundation
import AppKit
import CoreVideo

let args = CommandLine.arguments
guard args.count >= 3 else { print("uso: mkclip <carpeta> <salida.mp4> [fps]"); exit(1) }
let dir = URL(fileURLWithPath: args[1]); let outURL = URL(fileURLWithPath: args[2]); let fps = args.count > 3 ? Int32(args[3])! : 30
let files = (try! FileManager.default.contentsOfDirectory(atPath: dir.path)).filter { $0.hasPrefix("f_") && $0.hasSuffix(".png") }
    .sorted { (Int($0.dropFirst(2).dropLast(4)) ?? 0) < (Int($1.dropFirst(2).dropLast(4)) ?? 0) }
guard files.count > 40 else { print("pocos frames: \(files.count)"); exit(1) }
func load(_ f: String) -> CGImage { let s = CGImageSourceCreateWithURL(dir.appendingPathComponent(f) as CFURL, nil)!; return CGImageSourceCreateImageAtIndex(s, 0, nil)! }
let first = load(files[0]); let W = first.width, H = first.height
try? FileManager.default.removeItem(at: outURL)
let w = try! AVAssetWriter(outputURL: outURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 3_500_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
w.add(input); w.startWriting(); w.startSession(atSourceTime: .zero)

func pixels(_ img: CGImage) -> [UInt8] {
    var d = [UInt8](repeating: 0, count: W * H * 4)
    let ctx = CGContext(data: &d, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H)); return d
}
let N = files.count, X = 15
var frameIndex: Int64 = 0
func write(_ d: [UInt8]) {
    var pb: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    let b = pb!; CVPixelBufferLockBaseAddress(b, []); let base = CVPixelBufferGetBaseAddress(b)!; let bpr = CVPixelBufferGetBytesPerRow(b)
    d.withUnsafeBufferPointer { p in for y in 0..<H { memcpy(base + y * bpr, p.baseAddress! + y * W * 4, W * 4) } }
    CVPixelBufferUnlockBaseAddress(b, [])
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
    adaptor.append(b, withPresentationTime: CMTime(value: frameIndex, timescale: fps)); frameIndex += 1
}
let head = (0..<X).map { pixels(load(files[$0])) }
for i in X..<N {
    var d = pixels(load(files[i]))
    if i >= N - X { // fundido hacia el principio: el bucle no salta
        let k = i - (N - X), t = Double(k + 1) / Double(X + 1); let h = head[k]
        for j in 0..<d.count { d[j] = UInt8(Double(d[j]) * (1 - t) + Double(h[j]) * t) }
    }
    write(d)
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0); w.finishWriting { sem.signal() }; sem.wait()
print("\(outURL.lastPathComponent): \(frameIndex) frames, \(W)x\(H), \(w.status == .completed ? "ok" : "error \(String(describing: w.error))")")
