# DicyaninSimulatorInput

Use an iPhone on your desk as a full-body + hand controller for a visionOS app running in the simulator. The phone tracks your body (ARKit body tracking) and fingers (Vision hand pose) and streams head-relative poses over TCP; the visionOS app receives them and drives the existing mock hand-tracking pipeline plus a published body skeleton.

Built from proven pieces:
- Capture: `ARBodyCaptureSession` from DicyaninLabsMoCapRecording (body + Vision hands on iPhone).
- Hand contract: `HandPosePacket` from DicyaninHandTrackingTransport, reused unchanged so `MockHandTrackingController.apply` works as-is.
- Transport pattern: newline-framed JSON over TCP with Bonjour discovery, same as the webcam runner.

## Products

- `DicyaninSimInputTransport`: `SimInputPacket` (body joints in `ARKitBodyJoint.allCases` order + embedded `HandPosePacket`), `SimInputSender`, `SimInputReceiver`. iOS, visionOS, macOS.
- `DicyaninSimInputRunner` (iOS): `SimInputBroadcaster` (capture + broadcast) and `SimInputRunnerView` (camera preview, wireframe overlays, server status).
- `DicyaninSimInputMacRunner` (macOS 14+): `MacSimInputBroadcaster` (webcam + Vision 3D body pose + hand pose, broadcast) and `SimInputMacRunnerView` (preview, overlays, tuning). No iPhone needed: everything runs on the Mac next to the simulator.
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

## Mac webcam runner app

See `Demo/SimInputMacRunnerDemo`. Runs entirely on the Mac: the webcam feeds `VNDetectHumanBodyPose3DRequest` (full 3D body, camera-relative meters) and `VNDetectHumanHandPoseRequest` (21-joint hands), mapped into the same head-relative person frame and broadcast as `SimInputPacket`s on the same port and Bonjour service as the iPhone runner, so the visionOS consumer works with either unchanged.

```swift
@StateObject private var broadcaster = MacSimInputBroadcaster()
var body: some Scene {
    WindowGroup { SimInputMacRunnerView(broadcaster: broadcaster) }
}
```

Info.plist: `NSCameraUsageDescription`, `NSLocalNetworkUsageDescription`, `NSBonjourServices` = `["_dicyaninsiminput._tcp"]`. Sandbox entitlements: camera, network server + client. Generate the project with `xcodegen generate` inside `Demo/SimInputMacRunnerDemo`.

Stand back far enough that the camera sees your whole body for body tracking; hands track at any distance. Body depth comes from Vision's 3D estimate; hand depth is approximated from apparent hand size like the WebcamHandRunner.

## visionOS viewer app

See `Demo/SimInputViewerDemo`: a full demo scene integrating every package output. Control window with Bonjour/manual connect and live status, plus an immersive space containing `BodySkeletonEntity` (body wireframe), `HandGloveView.addHands` gloves driven through `MockHandTrackingController`, and a pinch-reactive target sphere showing gameplay logic on the same input path. Create a visionOS App target, add the `DicyaninSimulatorInput` product plus `DicyaninMockHandTracking` and `DicyaninHandGlove` from DicyaninMockHandTracking, drop the files in, and set Info.plist keys `NSLocalNetworkUsageDescription` and `NSBonjourServices` = `["_dicyaninsiminput._tcp"]`.

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
