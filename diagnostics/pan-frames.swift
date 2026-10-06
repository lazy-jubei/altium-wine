import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics

final class Meter: NSObject, SCStreamOutput {
    let region: [Int]
    var previous: UInt64? = nil
    var start = ProcessInfo.processInfo.systemUptime
    var samples = 0
    var changes: [Double] = []
    init(_ r: [Int]) { region = r }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let status = attachments.first?[.status] as? Int,
            status == SCFrameStatus.complete.rawValue,
            let pb = sample.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let row = CVPixelBufferGetBytesPerRow(pb), w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let x0 = max(0, region[0]), y0 = max(0, region[1]), x1 = min(w, region[0]+region[2]), y1 = min(h, region[1]+region[3])
        var hash: UInt64 = 1469598103934665603
        // Sample only interior content, away from the OS cursor, CAD crosshair and status bars.
        for y in stride(from:y0,to:y1,by:3) {
            let p = base.advanced(by:y*row).assumingMemoryBound(to:UInt32.self)
            for x in stride(from:x0,to:x1,by:3) { hash = (hash ^ UInt64(p[x])) &* 1099511628211 }
        }
        let t = ProcessInfo.processInfo.systemUptime-start
        samples += 1
        if let last = previous, hash != last { changes.append(t); print(String(format:"change %.6f",t)); fflush(stdout) }
        previous = hash
    }
}

@main struct Main {
    static func main() async {
        _ = NSApplication.shared
        let a = CommandLine.arguments
        guard (a.count == 7 || a.count == 8), let id = UInt32(a[1]), id > 0,
            let seconds = Double(a[2]), seconds.isFinite, seconds > 5, seconds <= 60,
            a[3...6].allSatisfy({Int($0) != nil}),
            let fps = Int32(a.count == 8 ? a[7] : "120"), fps > 0, fps <= 240 else {
            print("usage: pan-frames WINDOW SECONDS ROI_X ROI_Y ROI_W ROI_H [FPS]; window scaled to 1280px wide")
            exit(2)
        }
        let region = a[3...6].map {Int($0)!}
        guard region[0] >= 0, region[1] >= 0, region[2] > 0, region[3] > 0,
            region.allSatisfy({$0 <= 8192}) else {exit(2)}
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly:true)
            guard let window = content.windows.first(where: {$0.windowID == id}) else { print("window absent"); exit(3) }
            let meter = Meter(region)
            let config = SCStreamConfiguration()
            config.width = 1280
            config.height = Int(1280*window.frame.height/window.frame.width)
            guard region[0] + region[2] <= config.width,
                region[1] + region[3] <= config.height else {exit(2)}
            config.minimumFrameInterval = CMTime(value:1,timescale:fps)
            config.showsCursor = false
            config.queueDepth = 3
            config.pixelFormat = kCVPixelFormatType_32BGRA
            let stream = SCStream(filter:SCContentFilter(desktopIndependentWindow:window),configuration:config,delegate:nil)
            let queue = DispatchQueue(label:"pan-meter")
            try stream.addStreamOutput(meter,type:.screen,sampleHandlerQueue:queue)
            try await stream.startCapture()
            print("capture ready window=\(id) size=\(config.width)x\(config.height) roi=\(meter.region)"); fflush(stdout)
            try await Task.sleep(nanoseconds:UInt64(seconds*1e9))
            try await stream.stopCapture()
            queue.sync {
                print("samples=\(meter.samples) changed=\(meter.changes.count)")
                let ts = meter.changes.filter {$0 >= 1.5 && $0 < seconds-3.5}
                print(String(format:"interior %.3fs changed=%d visible_fps=%.3f",seconds-5,ts.count,Double(ts.count)/(seconds-5)))
            }
        } catch { print("capture error: \(error)"); exit(1) }
    }
}
