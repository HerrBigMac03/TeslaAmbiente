// MARK: - BLEModels.swift
// Tesla Ambiente iOS App
// BLE UUIDs, Paketstrukturen und Enums

import Foundation
import CoreBluetooth

// MARK: - BLE UUIDs
enum BLEUUID {
    static let service          = CBUUID(string: "4FAFC201-1FB5-459E-8FCC-C5C9C331914B")
    static let ledCommand       = CBUUID(string: "BEB5483E-36E1-4688-B7F5-EA07361B26A8")
    static let vehicleStatus    = CBUUID(string: "BEB5483E-36E1-4688-B7F5-EA07361B26A9")
    static let featureSettings  = CBUUID(string: "BEB5483E-36E1-4688-B7F5-EA07361B26AA")
    static let otaControl       = CBUUID(string: "BEB5483E-36E1-4688-B7F5-EA07361B26AB")
    static let otaData          = CBUUID(string: "BEB5483E-36E1-4688-B7F5-EA07361B26AC")
    static let deviceInfo       = CBUUID(string: "BEB5483E-36E1-4688-B7F5-EA07361B26AD")
    static let presets          = CBUUID(string: "BEB5483E-36E1-4688-B7F5-EA07361B26AE")
}

enum LEDZone: String, CaseIterable, Identifiable {
    case all = "A"; case frontLeft = "G"; case frontRight = "F"
    case rearLeft = "R"; case rearRight = "L"; case dashboard = "D"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all: return "Alle Zonen"; case .frontLeft: return "Vorne Links"
        case .frontRight: return "Vorne Rechts"; case .rearLeft: return "Hinten Links"
        case .rearRight: return "Hinten Rechts"; case .dashboard: return "Dashboard"
        }
    }
    var shortName: String {
        switch self {
        case .all: return "Alle"; case .frontLeft: return "VL"; case .frontRight: return "VR"
        case .rearLeft: return "HL"; case .rearRight: return "HR"; case .dashboard: return "Dash"
        }
    }
    var systemIcon: String {
        switch self {
        case .all: return "car.fill"; case .frontLeft: return "rectangle.lefthalf.inset.filled"
        case .frontRight: return "rectangle.righthalf.inset.filled"
        case .rearLeft: return "rectangle.lefthalf.inset.filled.arrow.left"
        case .rearRight: return "rectangle.righthalf.inset.filled.arrow.right"
        case .dashboard: return "gauge.with.needle"
        }
    }
}

enum LEDEffect: UInt8, CaseIterable, Identifiable {
    case off=0,staticColor=1,breathing=2,blink=3,rainbow=4
    case colorWipe=5,scanner=6,theaterChase=7,runningLights=8,sparkle=9
    case fire=10,police=11,progressBar=12,softFade=13,strobe=14
    case meteorRain=15,twoColorFade=16,threeColorFade=17,blindSpot=20
    var id: UInt8 { rawValue }
    var displayName: String {
        switch self {
        case .off: return "Aus"; case .staticColor: return "Statisch"; case .breathing: return "Atmen"
        case .blink: return "Blinken"; case .rainbow: return "Regenbogen"; case .colorWipe: return "Color Wipe"
        case .scanner: return "Scanner"; case .theaterChase: return "Theater Chase"
        case .runningLights: return "Running Lights"; case .sparkle: return "Sparkle"
        case .fire: return "Feuer"; case .police: return "Polizei"; case .progressBar: return "Fortschrittsbalken"
        case .softFade: return "Soft Fade"; case .strobe: return "Strobe"
        case .meteorRain: return "Meteor Rain"; case .twoColorFade: return "2-Farben Fade"
        case .threeColorFade: return "3-Farben Fade"; case .blindSpot: return "Totwinkel"
        }
    }
    var systemIcon: String {
        switch self {
        case .off: return "moon.fill"; case .staticColor: return "circle.fill"
        case .breathing: return "lungs.fill"; case .blink: return "flashlight.on.fill"
        case .rainbow: return "rainbow"; case .colorWipe: return "paintbrush.fill"
        case .scanner: return "eye.fill"; case .theaterChase: return "theatermasks.fill"
        case .runningLights: return "figure.run"; case .sparkle: return "sparkles"
        case .fire: return "flame.fill"; case .police: return "light.beacon.max.fill"
        case .progressBar: return "chart.bar.fill"; case .softFade: return "waveform"
        case .strobe: return "bolt.fill"; case .meteorRain: return "star.fill"
        case .twoColorFade: return "circle.lefthalf.filled"
        case .threeColorFade: return "circle.grid.2x1.fill"
        case .blindSpot: return "eye.trianglebadge.exclamationmark"
        }
    }
    var supportsSpeed: Bool { self != .off && self != .staticColor && self != .progressBar }
    var supportsIntensity: Bool { self == .scanner || self == .sparkle || self == .meteorRain }
}

enum DashMode: UInt8 {
    case off=0,base=1,blinker=2,blind=3,autopilot=4,charging=5,welcome=6,goodbye=7,door=8,unknown=255
    var displayName: String {
        switch self {
        case .off: return "Aus"; case .base: return "Basis"; case .blinker: return "Blinker"
        case .blind: return "Totwinkel"; case .autopilot: return "Autopilot"; case .charging: return "Laden"
        case .welcome: return "Willkommen"; case .goodbye: return "Tschuess"; case .door: return "Tuer offen"
        case .unknown: return "Unbekannt"
        }
    }
}

enum Gear: UInt8 {
    case park=1,reverse=2,neutral=3,drive=4,unknown=7
    var displayName: String {
        switch self { case .park: return "P"; case .reverse: return "R"; case .neutral: return "N"; case .drive: return "D"; case .unknown: return "?" }
    }
}

enum OTATarget: String, CaseIterable, Identifiable {
    case master="master",dashCAN="dash_can",doorFrontLeft="door_fl",doorFrontRight="door_fr",doorRearLeft="door_rl",doorRearRight="door_rr"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .master: return "Master ESP32"; case .dashCAN: return "Dashboard CAN-Bridge"
        case .doorFrontLeft: return "Tuer Vorne Links"; case .doorFrontRight: return "Tuer Vorne Rechts"
        case .doorRearLeft: return "Tuer Hinten Links"; case .doorRearRight: return "Tuer Hinten Rechts"
        }
    }
    var systemIcon: String {
        switch self {
        case .master: return "cpu"; case .dashCAN: return "gauge.with.needle"
        default: return "door.left.hand.closed"
        }
    }
}

enum BLEConnectionState {
    case disconnected, scanning, connecting, connected, failed(String)
    var displayName: String {
        switch self {
        case .disconnected: return "Getrennt"; case .scanning: return "Suche..."
        case .connecting: return "Verbinde..."; case .connected: return "Verbunden"
        case .failed(let e): return "Fehler: \(e)"
        }
    }
    var isConnected: Bool { if case .connected = self { return true }; return false }
}

struct LEDColor: Equatable, Codable {
    var r: UInt8; var g: UInt8; var b: UInt8
    static let red   = LEDColor(r:255,g:0,b:0)
    static let green = LEDColor(r:0,g:255,b:0)
    static let blue  = LEDColor(r:0,g:0,b:255)
    static let white = LEDColor(r:255,g:255,b:255)
    static let off   = LEDColor(r:0,g:0,b:0)
    static let teslaRed   = LEDColor(r:220,g:30,b:30)
    static let teslaBlue  = LEDColor(r:0,g:70,b:255)
    static let teslaAmber = LEDColor(r:255,g:120,b:0)
}

struct LedCommandPacket {
    var magic: UInt8=0xA7; var version: UInt8=2; var target: UInt8
    var power: UInt8; var mode: UInt8; var effect: UInt8
    var r1: UInt8; var g1: UInt8; var b1: UInt8
    var r2: UInt8; var g2: UInt8; var b2: UInt8
    var r3: UInt8; var g3: UInt8; var b3: UInt8
    var brightness: UInt8; var speed: UInt8; var intensity: UInt8; var progress: UInt8
    var ledStart: UInt16; var ledEnd: UInt16; var sequence: UInt32
    func toData() -> Data { var c=self; return Data(bytes:&c,count:MemoryLayout<LedCommandPacket>.size) }
}

struct DashSettingsPacket {
    var packetType: UInt8=0xC7; var version: UInt8=1
    var baseR: UInt8; var baseG: UInt8; var baseB: UInt8
    var baseEffect: UInt8; var baseSpeed: UInt8; var baseIntensity: UInt8
    var manualBrightness: UInt8; var autoBrightness: UInt8; var powerOff: UInt8
    var chargeDashEnabled: UInt8; var autopilotDashEnabled: UInt8
    var autopilotR: UInt8; var autopilotG: UInt8; var autopilotB: UInt8
    var blindSpotDashEnabled: UInt8; var blindSpotOnlyWithBlinker: UInt8; var blindSpotDashPercent: UInt8
    var dashLedCount: UInt16; var doorOpenHighlightEnabled: UInt8
    var welcomeAnimationEnabled: UInt8; var goodbyeAnimationEnabled: UInt8
    var blinkerDashEnabled: UInt8; var blinkerDashPercent: UInt8
    func toData() -> Data { var c=self; return Data(bytes:&c,count:MemoryLayout<DashSettingsPacket>.size) }
}

struct OTAControlPacket {
    var command: UInt8; var target: UInt8; var totalSize: UInt32; var chunkSize: UInt16; var checksum: UInt32
    func toData() -> Data { var c=self; return Data(bytes:&c,count:MemoryLayout<OTAControlPacket>.size) }
}

struct VehicleStatusBLE {
    var blinkerLeft: UInt8; var blinkerRight: UInt8; var gear: UInt8; var batterySOC: UInt8
    var chargingActive: UInt8; var vehicleAwake: UInt8
    var doorFL: UInt8; var doorFR: UInt8; var doorRL: UInt8; var doorRR: UInt8
    var trunkOpen: UInt8; var autopilotActive: UInt8; var blindLeft: UInt8; var blindRight: UInt8
    var displayBrightness: UInt8; var dashMode: UInt8; var mirrorsFolded: UInt8; var vehicleCanAgeMs: UInt32
}