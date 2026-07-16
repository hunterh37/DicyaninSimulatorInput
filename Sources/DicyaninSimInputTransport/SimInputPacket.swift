import Foundation
import simd
import DicyaninLabsMoCapRecording
import DicyaninHandTrackingTransport

/// One instant of full-body + hand input, head-relative from the tracked
/// person's own point of view: x right, y up, negative z in front. The head
/// joint is the origin, so the visionOS consumer can treat the person as the
/// simulator wearer directly.
///
/// Hands reuse the proven `HandPosePacket` contract from
/// DicyaninHandTrackingTransport unchanged, so existing consumers
/// (`MockHandTrackingController.apply`) work as-is. Body joints are 30
/// positions in `ARKitBodyJoint.allCases` order.
///
/// Encoded as compact JSON, newline-framed on the wire like `HandPoseWire`.
public struct SimInputPacket: Codable, Sendable, Equatable {
    /// Hand state, wire-compatible with the webcam runner packet.
    public var hands: HandPosePacket

    /// Head-relative body joint positions in `ARKitBodyJoint.allCases` order,
    /// or `nil` when no body is tracked this frame.
    public var bodyJoints: [SIMD3<Float>]?
    public var bodyTracked: Bool

    public init(hands: HandPosePacket,
                bodyJoints: [SIMD3<Float>]? = nil,
                bodyTracked: Bool = false) {
        self.hands = hands
        self.bodyJoints = bodyJoints
        self.bodyTracked = bodyTracked
    }

    /// Rebuild the keyed dictionary from the flat wire order.
    public func bodyJointsByID() -> [ARKitBodyJoint: SIMD3<Float>]? {
        guard let bodyJoints, bodyJoints.count >= ARKitBodyJoint.allCases.count else { return nil }
        var out: [ARKitBodyJoint: SIMD3<Float>] = [:]
        for (i, joint) in ARKitBodyJoint.allCases.enumerated() {
            out[joint] = bodyJoints[i]
        }
        return out
    }

    private enum CodingKeys: String, CodingKey {
        case h, bj, bt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hands = try c.decode(HandPosePacket.self, forKey: .h)
        bodyTracked = try c.decodeIfPresent(Bool.self, forKey: .bt) ?? false
        if let flat = try c.decodeIfPresent([Float].self, forKey: .bj),
           flat.count % 3 == 0, !flat.isEmpty {
            bodyJoints = stride(from: 0, to: flat.count, by: 3).map {
                SIMD3(flat[$0], flat[$0 + 1], flat[$0 + 2])
            }
        } else {
            bodyJoints = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hands, forKey: .h)
        try c.encode(bodyTracked, forKey: .bt)
        if let bodyJoints {
            var flat: [Float] = []
            flat.reserveCapacity(bodyJoints.count * 3)
            for j in bodyJoints { flat.append(contentsOf: [j.x, j.y, j.z]) }
            try c.encode(flat, forKey: .bj)
        }
    }
}

public enum SimInputWire {
    /// Default TCP port the iPhone runner serves on and the visionOS app dials.
    public static let defaultPort: UInt16 = 50674

    /// Bonjour service type for zero-config discovery on a LAN.
    public static let bonjourServiceType = "_dicyaninsiminput._tcp"

    private static let encoder = JSONEncoder()

    /// Encode a packet as a single newline-terminated frame.
    public static func frame(_ packet: SimInputPacket) throws -> Data {
        var data = try encoder.encode(packet)
        data.append(0x0A)
        return data
    }

    /// Decode one frame (without the trailing newline).
    public static func decode(_ data: Data) throws -> SimInputPacket {
        try JSONDecoder().decode(SimInputPacket.self, from: data)
    }
}
