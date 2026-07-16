import XCTest
import simd
@testable import DicyaninSimInputTransport
import DicyaninLabsMoCapRecording
import DicyaninHandTrackingTransport

final class SimInputPacketTests: XCTestCase {
    private func makeHands() -> HandPosePacket {
        HandPosePacket(
            leftPosition: [-0.2, -0.1, -0.5],
            rightPosition: [0.2, -0.1, -0.5],
            leftYaw: 0.3,
            rightYaw: -0.3,
            isPinching: true,
            leftTracked: true,
            rightTracked: false,
            leftJoints: (0..<HandJointID.count).map { SIMD3(Float($0), 0, -1) },
            rightJoints: nil
        )
    }

    func testRoundTripWithBody() throws {
        let body = ARKitBodyJoint.allCases.enumerated().map { i, _ in
            SIMD3(Float(i) * 0.01, Float(i) * -0.02, Float(i) * 0.03)
        }
        let packet = SimInputPacket(hands: makeHands(), bodyJoints: body, bodyTracked: true)
        let framed = try SimInputWire.frame(packet)
        XCTAssertEqual(framed.last, 0x0A)
        let decoded = try SimInputWire.decode(framed.dropLast())
        XCTAssertEqual(decoded, packet)
        XCTAssertEqual(decoded.bodyJointsByID()?.count, ARKitBodyJoint.allCases.count)
        XCTAssertEqual(decoded.bodyJointsByID()?[.root], body[0])
    }

    func testRoundTripWithoutBody() throws {
        let packet = SimInputPacket(hands: makeHands())
        let decoded = try SimInputWire.decode(SimInputWire.frame(packet).dropLast())
        XCTAssertEqual(decoded, packet)
        XCTAssertNil(decoded.bodyJoints)
        XCTAssertNil(decoded.bodyJointsByID())
        XCTAssertFalse(decoded.bodyTracked)
    }

    func testShortBodyArrayYieldsNoDictionary() {
        let packet = SimInputPacket(hands: makeHands(), bodyJoints: [SIMD3(1, 2, 3)], bodyTracked: true)
        XCTAssertNil(packet.bodyJointsByID())
    }
}
