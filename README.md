# DicyaninSimulatorInput

Use an iPhone on your desk as a full-body + hand controller for a visionOS app running in the simulator. The phone tracks your body (ARKit body tracking) and fingers (Vision hand pose) and streams head-relative poses over TCP; the visionOS app receives them and drives the existing mock hand-tracking pipeline plus a published body skeleton.

Built from proven pieces:
- Capture: `ARBodyCaptureSession` from DicyaninLabsMoCapRecording (body + Vision hands on iPhone).
- Hand contract: `HandPosePacket` from DicyaninHandTrackingTransport, reused unchanged so `MockHandTrackingController.apply` works as-is.
- Transport pattern: newline-framed JSON over TCP with Bonjour discovery, same as the webcam runner.

## Products

- `DicyaninSimInputTransport`: `SimInputPacket` (body joints in `ARKitBodyJoint.allCases` order + embedded `HandPosePacket`), `SimInputSender`, `SimInputReceiver`. iOS, visionOS, macOS.
- `DicyaninSimInputRunner` (iOS): `SimInputBroadcaster` (capture + broadcast) and `SimInputRunnerView` (camera preview, wireframe overlays, server status).
- `DicyaninSimulatorInput` (visionOS): `SimulatorInputController.shared` (receive + feed `MockHandTrackingController`) and `BodySkeletonEntity` (ECS-driven debug skeleton).

## iPhone runner app

See `Demo/SimInputRunnerDemo`. Requires a device with ARKit body tracking (A12+, rear camera does the tracking, so prop the phone with the back camera facing you).

```swift
@StateObject private var broadcaster = SimInputBroadcaster()
var body: some Scene {
    WindowGroup { SimInputRunnerView(broadcaster: broadcaster) }
}
```

Info.plist: `NSCameraUsageDescription`, `NSLocalNetworkUsageDescription`, `NSBonjourServices` = `["_dicyaninsiminput._tcp"]`.

## visionOS app (simulator)

```swift
.task {
    #if targetEnvironment(simulator)
    // Same Wi-Fi: Bonjour discovery finds the phone.
    SimulatorInputController.shared.connect(bonjourName: nil)
    // Or by address: SimulatorInputController.shared.connect(host: "192.168.1.23")
    #endif
}
```

Hands then flow through `MockHandTrackingController.shared` exactly like the joystick or webcam inputs (positions, yaw, pinch, full 21-joint skeletons). Body:

```swift
let joints = SimulatorInputController.shared.bodyJoints   // [ARKitBodyJoint: SIMD3<Float>]
content.add(BodySkeletonEntity())                          // debug wireframe
```

Coordinates are head-relative from the tracked person's point of view: x right, y up, negative z in front. The head joint is the origin, so the person maps 1:1 onto the simulated wearer.

## Wire format

Newline-framed compact JSON on TCP port 50674 (Bonjour `_dicyaninsiminput._tcp`). `SimInputPacket`: `h` = `HandPosePacket`, `bj` = 30 body joints as a flat float array, `bt` = body tracked.
