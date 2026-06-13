// MARK: - AppState.swift
import Foundation
import SwiftUI

class VehicleState: ObservableObject {
    @Published var blinkerLeft=false; @Published var blinkerRight=false
    @Published var gear: Gear = .unknown; @Published var batterySOC=0
    @Published var isCharging=false; @Published var isAwake=false
    @Published var doorFrontLeft=false; @Published var doorFrontRight=false
    @Published var doorRearLeft=false; @Published var doorRearRight=false
    @Published var trunkOpen=false; @Published var autopilotActive=false
    @Published var blindLeft=false; @Published var blindRight=false
    @Published var displayBrightness=100; @Published var dashMode: DashMode = .unknown
    @Published var mirrorsFolded=false; @Published var vehicleCanAgeMs: UInt32 = UInt32.max
    @Published var lastUpdateTime: Date? = nil
    var anyDoorOpen: Bool { doorFrontLeft||doorFrontRight||doorRearLeft||doorRearRight||trunkOpen }
    var canDataFresh: Bool { vehicleCanAgeMs < 10_000 }
    func update(from p: VehicleStatusBLE) {
        blinkerLeft=p.blinkerLeft != 0; blinkerRight=p.blinkerRight != 0
        gear=Gear(rawValue:p.gear) ?? .unknown; batterySOC=Int(p.batterySOC)
        isCharging=p.chargingActive != 0; isAwake=p.vehicleAwake != 0
        doorFrontLeft=p.doorFL != 0; doorFrontRight=p.doorFR != 0
        doorRearLeft=p.doorRL != 0; doorRearRight=p.doorRR != 0
        trunkOpen=p.trunkOpen != 0; autopilotActive=p.autopilotActive != 0
        blindLeft=p.blindLeft != 0; blindRight=p.blindRight != 0
        displayBrightness=Int(p.displayBrightness); dashMode=DashMode(rawValue:p.dashMode) ?? .unknown
        mirrorsFolded=p.mirrorsFolded != 0; vehicleCanAgeMs=p.vehicleCanAgeMs; lastUpdateTime=Date()
    }
}

class LEDSettings: ObservableObject, Codable {
    @Published var selectedZone: LEDZone = .all
    @Published var color1: LEDColor = .teslaRed; @Published var color2: LEDColor = .blue; @Published var color3: LEDColor = .green
    @Published var effect: LEDEffect = .staticColor
    @Published var brightness: UInt8 = 180; @Published var speed: UInt8 = 120; @Published var intensity: UInt8 = 120
    @Published var powerOn: Bool = true
    @Published var ledStart: UInt16 = 0; @Published var ledEnd: UInt16 = 129
    private var _sequence: UInt32 = 1
    var sequence: UInt32 { _sequence += 1; return _sequence }
    enum CodingKeys: String, CodingKey { case color1,color2,color3,effect,brightness,speed,intensity,powerOn,ledStart,ledEnd }
    required init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        color1=try c.decode(LEDColor.self,forKey:.color1); color2=try c.decode(LEDColor.self,forKey:.color2); color3=try c.decode(LEDColor.self,forKey:.color3)
        effect=LEDEffect(rawValue:try c.decode(UInt8.self,forKey:.effect)) ?? .staticColor
        brightness=try c.decode(UInt8.self,forKey:.brightness); speed=try c.decode(UInt8.self,forKey:.speed); intensity=try c.decode(UInt8.self,forKey:.intensity)
        powerOn=try c.decode(Bool.self,forKey:.powerOn); ledStart=try c.decode(UInt16.self,forKey:.ledStart); ledEnd=try c.decode(UInt16.self,forKey:.ledEnd)
    }
    func encode(to e: Encoder) throws {
        var c=e.container(keyedBy:CodingKeys.self)
        try c.encode(color1,forKey:.color1); try c.encode(color2,forKey:.color2); try c.encode(color3,forKey:.color3)
        try c.encode(effect.rawValue,forKey:.effect); try c.encode(brightness,forKey:.brightness)
        try c.encode(speed,forKey:.speed); try c.encode(intensity,forKey:.intensity)
        try c.encode(powerOn,forKey:.powerOn); try c.encode(ledStart,forKey:.ledStart); try c.encode(ledEnd,forKey:.ledEnd)
    }
    init() {}
    func buildPacket(for zone: LEDZone) -> LedCommandPacket {
        LedCommandPacket(magic:0xA7,version:2,target:zone.rawValue.utf8.first ?? UInt8(ascii:"A"),
            power:powerOn ? 1:0,mode:0,effect:effect.rawValue,
            r1:color1.r,g1:color1.g,b1:color1.b,r2:color2.r,g2:color2.g,b2:color2.b,
            r3:color3.r,g3:color3.g,b3:color3.b,brightness:brightness,speed:speed,intensity:intensity,
            progress:0,ledStart:ledStart,ledEnd:ledEnd,sequence:sequence)
    }
}

class FeatureSettings: ObservableObject, Codable {
    @Published var baseColor: LEDColor = .teslaRed; @Published var baseEffect: UInt8=1
    @Published var baseSpeed: UInt8=120; @Published var baseIntensity: UInt8=120
    @Published var manualBrightness: UInt8=120; @Published var autoBrightness=true; @Published var dashPowerOff=false
    @Published var chargeDashEnabled=true; @Published var autopilotDashEnabled=true
    @Published var autopilotColor=LEDColor(r:0,g:70,b:255)
    @Published var blindSpotDashEnabled=true; @Published var blindSpotOnlyWithBlinker=true; @Published var blindSpotDashPercent: UInt8=25
    @Published var dashLedCount: UInt16=122; @Published var doorOpenHighlightEnabled=true
    @Published var welcomeAnimationEnabled=true; @Published var goodbyeAnimationEnabled=true
    @Published var blinkerDashEnabled=false; @Published var blinkerDashPercent: UInt8=25
    enum CodingKeys: String, CodingKey {
        case baseColor,baseEffect,baseSpeed,baseIntensity,manualBrightness,autoBrightness
        case dashPowerOff,chargeDashEnabled,autopilotDashEnabled,autopilotColor
        case blindSpotDashEnabled,blindSpotOnlyWithBlinker,blindSpotDashPercent
        case dashLedCount,doorOpenHighlightEnabled,welcomeAnimationEnabled,goodbyeAnimationEnabled,blinkerDashEnabled,blinkerDashPercent
    }
    required init(from d: Decoder) throws {
        let c=try d.container(keyedBy:CodingKeys.self)
        baseColor=try c.decode(LEDColor.self,forKey:.baseColor); baseEffect=try c.decode(UInt8.self,forKey:.baseEffect)
        baseSpeed=try c.decode(UInt8.self,forKey:.baseSpeed); baseIntensity=try c.decode(UInt8.self,forKey:.baseIntensity)
        manualBrightness=try c.decode(UInt8.self,forKey:.manualBrightness); autoBrightness=try c.decode(Bool.self,forKey:.autoBrightness)
        dashPowerOff=try c.decode(Bool.self,forKey:.dashPowerOff); chargeDashEnabled=try c.decode(Bool.self,forKey:.chargeDashEnabled)
        autopilotDashEnabled=try c.decode(Bool.self,forKey:.autopilotDashEnabled); autopilotColor=try c.decode(LEDColor.self,forKey:.autopilotColor)
        blindSpotDashEnabled=try c.decode(Bool.self,forKey:.blindSpotDashEnabled)
        blindSpotOnlyWithBlinker=try c.decode(Bool.self,forKey:.blindSpotOnlyWithBlinker)
        blindSpotDashPercent=try c.decode(UInt8.self,forKey:.blindSpotDashPercent); dashLedCount=try c.decode(UInt16.self,forKey:.dashLedCount)
        doorOpenHighlightEnabled=try c.decode(Bool.self,forKey:.doorOpenHighlightEnabled)
        welcomeAnimationEnabled=try c.decode(Bool.self,forKey:.welcomeAnimationEnabled)
        goodbyeAnimationEnabled=try c.decode(Bool.self,forKey:.goodbyeAnimationEnabled)
        blinkerDashEnabled=try c.decode(Bool.self,forKey:.blinkerDashEnabled); blinkerDashPercent=try c.decode(UInt8.self,forKey:.blinkerDashPercent)
    }
    func encode(to e: Encoder) throws {
        var c=e.container(keyedBy:CodingKeys.self)
        try c.encode(baseColor,forKey:.baseColor); try c.encode(baseEffect,forKey:.baseEffect)
        try c.encode(baseSpeed,forKey:.baseSpeed); try c.encode(baseIntensity,forKey:.baseIntensity)
        try c.encode(manualBrightness,forKey:.manualBrightness); try c.encode(autoBrightness,forKey:.autoBrightness)
        try c.encode(dashPowerOff,forKey:.dashPowerOff); try c.encode(chargeDashEnabled,forKey:.chargeDashEnabled)
        try c.encode(autopilotDashEnabled,forKey:.autopilotDashEnabled); try c.encode(autopilotColor,forKey:.autopilotColor)
        try c.encode(blindSpotDashEnabled,forKey:.blindSpotDashEnabled); try c.encode(blindSpotOnlyWithBlinker,forKey:.blindSpotOnlyWithBlinker)
        try c.encode(blindSpotDashPercent,forKey:.blindSpotDashPercent); try c.encode(dashLedCount,forKey:.dashLedCount)
        try c.encode(doorOpenHighlightEnabled,forKey:.doorOpenHighlightEnabled); try c.encode(welcomeAnimationEnabled,forKey:.welcomeAnimationEnabled)
        try c.encode(goodbyeAnimationEnabled,forKey:.goodbyeAnimationEnabled); try c.encode(blinkerDashEnabled,forKey:.blinkerDashEnabled)
        try c.encode(blinkerDashPercent,forKey:.blinkerDashPercent)
    }
    init() {}
    func buildDashPacket() -> DashSettingsPacket {
        DashSettingsPacket(packetType:0xC7,version:1,baseR:baseColor.r,baseG:baseColor.g,baseB:baseColor.b,
            baseEffect:baseEffect,baseSpeed:baseSpeed,baseIntensity:baseIntensity,manualBrightness:manualBrightness,
            autoBrightness:autoBrightness ? 1:0,powerOff:dashPowerOff ? 1:0,chargeDashEnabled:chargeDashEnabled ? 1:0,
            autopilotDashEnabled:autopilotDashEnabled ? 1:0,autopilotR:autopilotColor.r,autopilotG:autopilotColor.g,autopilotB:autopilotColor.b,
            blindSpotDashEnabled:blindSpotDashEnabled ? 1:0,blindSpotOnlyWithBlinker:blindSpotOnlyWithBlinker ? 1:0,
            blindSpotDashPercent:blindSpotDashPercent,dashLedCount:dashLedCount,doorOpenHighlightEnabled:doorOpenHighlightEnabled ? 1:0,
            welcomeAnimationEnabled:welcomeAnimationEnabled ? 1:0,goodbyeAnimationEnabled:goodbyeAnimationEnabled ? 1:0,
            blinkerDashEnabled:blinkerDashEnabled ? 1:0,blinkerDashPercent:blinkerDashPercent)
    }
}

struct LEDPreset: Identifiable, Codable {
    var id=UUID(); var name: String; var color: LEDColor; var effect: UInt8; var brightness: UInt8; var speed: UInt8; var createdAt=Date()
}

struct OTAState: Equatable {
    enum Phase: Equatable { case idle,preparing,uploading(progress:Double),verifying,success,failed(String),rollingBack }
    var phase: Phase = .idle; var targetDevice: OTATarget = .master
    var firmwareURL: URL?=nil; var firmwareSize=0; var currentFWVersion="?"
    var isActive: Bool { switch phase { case .idle,.success,.failed: return false; default: return true } }
    var progressValue: Double { if case .uploading(let p)=phase { return p }; return 0 }
}