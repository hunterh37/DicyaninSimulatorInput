import Foundation
import simd
import CoreGraphics
import DicyaninLabsMoCapRecording

#if os(macOS)
import AVFoundation
import Vision

/// One processed webcam frame: mapped body + hands ready for broadcast, plus
/// normalized overlay geometry for the runner UI.
struct MacVisionFrame {
    var bodyJoints: [SIMD3<Float>]?
    var bodyOverlay: [VNHumanBodyPose3DObservation.JointName: CGPoint]
    var hands: [MacDetectedHand]
    var frameSize: CGSize
}

/// Runs `VNDetectHumanBodyPose3DRequest` + `VNDetectHumanHandPoseRequest` on
/// each webcam frame off the main actor and hands mapped results back via
/// `onFrame` (called on `queue`). The 3D body request is the expensive one, so
/// it runs at a reduced cadence and the latest body result is reused between
/// body updates while hands stay per-frame.
final class MacVisionPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "dicyanin.siminput.macvision")

    var onFrame: ((MacVisionFrame) -> Void)?

    // Operator tuning (read on `queue`).
    var mirrored = true
    var horizontalSpan: Float = 0.45
    var verticalSpan: Float = 0.35

    /// Run the 3D body request on every Nth frame.
    private let bodyStride = 2
    private var frameIndex = 0
    private var lastBodyJoints: [SIMD3<Float>]?
    private var lastBodyOverlay: [VNHumanBodyPose3DObservation.JointName: CGPoint] = [:]
    private var lastFrame: MacBodyMapper.Frame?

    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()
    private let bodyRequest = VNDetectHumanBodyPose3DRequest()

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        frameIndex += 1
        let runBody = frameIndex % bodyStride == 0
        var requests: [VNRequest] = [handRequest]
        if runBody { requests.append(bodyRequest) }
        do {
            try handler.perform(requests)
        } catch {
            return
        }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let aspect = CGFloat(w) / CGFloat(max(h, 1))

        if runBody {
            if let body = bodyRequest.results?.first {
                let cameraJoints = MacBodyMapper.cameraJoints(body)
                if let frame = MacBodyMapper.frame(cameraJoints: cameraJoints) {
                    lastFrame = frame
                    lastBodyJoints = MacBodyMapper.mapBody(cameraJoints: cameraJoints, frame: frame)
                } else {
                    lastBodyJoints = nil
                }
                lastBodyOverlay = MacBodyMapper.overlayPoints(body, mirrored: mirrored)
            } else {
                lastBodyJoints = nil
                lastBodyOverlay = [:]
            }
        }

        var hands = (handRequest.results ?? []).compactMap {
            MacHandMapper.map($0, aspect: aspect, mirrored: mirrored,
                              horizontalSpan: horizontalSpan, verticalSpan: verticalSpan)
        }
        hands.sort { $0.headPosition.x < $1.headPosition.x }
        if hands.count == 2 {
            hands[0].isLeft = true
            hands[1].isLeft = false
        }

        onFrame?(MacVisionFrame(
            bodyJoints: lastBodyJoints,
            bodyOverlay: lastBodyOverlay,
            hands: hands,
            frameSize: CGSize(width: w, height: h)))
    }
}
#endif
