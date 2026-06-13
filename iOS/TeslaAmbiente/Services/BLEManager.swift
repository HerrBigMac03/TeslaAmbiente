// MARK: - BLEManager.swift
import Foundation
import CoreBluetooth
import Combine

final class BLEManager: NSObject, ObservableObject {
    @Published var connectionState: BLEConnectionState = .disconnected
    @Published var discoveredPeripherals: [DiscoveredDevice] = []
    @Published var vehicleState: VehicleState = VehicleState()
    @Published var deviceInfo: DeviceInfo = DeviceInfo()
    @Published var lastError: String? = nil
    @Published var otaStatus: OTAState = OTAState()

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var reconnectTimer: Timer?
    private var lastPeripheralID: UUID? = nil
    private var charLEDCommand: CBCharacteristic?
    private var charVehicleStatus: CBCharacteristic?
    private var charFeatureSettings: CBCharacteristic?
    private var charOTAControl: CBCharacteristic?
    private var charOTAData: CBCharacteristic?
    private var charDeviceInfo: CBCharacteristic?
    private var charPresets: CBCharacteristic?
    private var otaFirmwareData: Data?
    private var otaChunkSize = 128
    private var otaCurrentOffset = 0
    private var shouldAutoReconnect = true

    static let shared = BLEManager()
    private override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    struct DiscoveredDevice: Identifiable {
        let id: UUID; let peripheral: CBPeripheral; var rssi: Int
        var name: String { peripheral.name ?? "Tesla Ambiente" }
    }
    struct DeviceInfo {
        var firmwareVersion="?"; var uptime: UInt32=0; var freeHeap: UInt32=0; var espNowOK: UInt32=0; var espNowFail: UInt32=0
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        discoveredPeripherals = []; connectionState = .scanning
        centralManager.scanForPeripherals(withServices:[BLEUUID.service], options:[CBCentralManagerScanOptionAllowDuplicatesKey:false])
        DispatchQueue.main.asyncAfter(deadline:.now()+15) { [weak self] in
            guard let self, case .scanning=self.connectionState else { return }
            self.centralManager.stopScan()
            if self.discoveredPeripherals.isEmpty { self.connectionState = .disconnected }
        }
    }
    func stopScanning() { centralManager.stopScan(); if case .scanning=connectionState { connectionState = .disconnected } }
    func connect(to device: DiscoveredDevice) {
        stopScanning(); connectionState = .connecting; peripheral = device.peripheral
        peripheral?.delegate = self; lastPeripheralID = device.id; centralManager.connect(device.peripheral, options:nil)
    }
    func disconnect() {
        shouldAutoReconnect = false; reconnectTimer?.invalidate()
        if let p=peripheral { centralManager.cancelPeripheralConnection(p) }
        resetCharacteristics(); connectionState = .disconnected
    }
    func sendLEDCommand(_ packet: LedCommandPacket) {
        guard let c=charLEDCommand, let p=peripheral, connectionState.isConnected else { return }
        var pkt=packet; p.writeValue(Data(bytes:&pkt,count:MemoryLayout<LedCommandPacket>.size), for:c, type:.withResponse)
    }
    func sendFeatureSettings(_ s: FeatureSettings) {
        guard let c=charFeatureSettings, let p=peripheral, connectionState.isConnected else { return }
        var pkt=s.buildDashPacket(); p.writeValue(Data(bytes:&pkt,count:MemoryLayout<DashSettingsPacket>.size), for:c, type:.withResponse)
    }
    func requestDeviceInfo() { guard let c=charDeviceInfo, let p=peripheral, connectionState.isConnected else { return }; p.readValue(for:c) }
    func startOTAUpdate(firmwareData: Data, target: OTATarget) {
        guard connectionState.isConnected, let charCtrl=charOTAControl, let p=peripheral else { otaStatus.phase = .failed("Nicht verbunden"); return }
        otaFirmwareData=firmwareData; otaCurrentOffset=0
        otaStatus.phase = .preparing; otaStatus.targetDevice=target; otaStatus.firmwareSize=firmwareData.count
        var ctrlPkt=OTAControlPacket(command:1,target:target.rawValue.utf8.first ?? 0,totalSize:UInt32(firmwareData.count),chunkSize:UInt16(otaChunkSize),checksum:crc32(firmwareData))
        p.writeValue(Data(bytes:&ctrlPkt,count:MemoryLayout<OTAControlPacket>.size), for:charCtrl, type:.withResponse)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [weak self] in self?.sendNextOTAChunk() }
    }
    private func sendNextOTAChunk() {
        guard let data=otaFirmwareData, let c=charOTAData, let p=peripheral, otaCurrentOffset<data.count else { finishOTA(); return }
        let end=min(otaCurrentOffset+otaChunkSize,data.count)
        p.writeValue(data[otaCurrentOffset..<end], for:c, type:.withResponse)
        otaCurrentOffset=end
        otaStatus.phase = .uploading(progress:Double(otaCurrentOffset)/Double(data.count))
    }
    private func finishOTA() {
        guard let c=charOTAControl, let p=peripheral else { return }
        otaStatus.phase = .verifying
        var pkt=OTAControlPacket(command:2,target:0,totalSize:0,chunkSize:0,checksum:0)
        p.writeValue(Data(bytes:&pkt,count:MemoryLayout<OTAControlPacket>.size), for:c, type:.withResponse)
    }
    func abortOTA() {
        if let c=charOTAControl, let p=peripheral {
            var pkt=OTAControlPacket(command:3,target:0,totalSize:0,chunkSize:0,checksum:0)
            p.writeValue(Data(bytes:&pkt,count:MemoryLayout<OTAControlPacket>.size), for:c, type:.withResponse)
        }
        otaFirmwareData=nil; otaStatus.phase = .idle
    }
    private func resetCharacteristics() { charLEDCommand=nil; charVehicleStatus=nil; charFeatureSettings=nil; charOTAControl=nil; charOTAData=nil; charDeviceInfo=nil; charPresets=nil }
    private func scheduleReconnect() {
        guard shouldAutoReconnect, let id=lastPeripheralID else { return }
        reconnectTimer?.invalidate()
        reconnectTimer=Timer.scheduledTimer(withTimeInterval:3.0,repeats:false) { [weak self] _ in
            guard let self else { return }
            if let known=self.centralManager.retrievePeripherals(withIdentifiers:[id]).first {
                self.peripheral=known; self.peripheral?.delegate=self; self.connectionState = .connecting; self.centralManager.connect(known,options:nil)
            } else { self.startScanning() }
        }
    }
    private func parseVehicleStatus(_ data: Data) {
        guard data.count >= MemoryLayout<VehicleStatusBLE>.size else { return }
        var p=VehicleStatusBLE(blinkerLeft:0,blinkerRight:0,gear:0,batterySOC:0,chargingActive:0,vehicleAwake:0,doorFL:0,doorFR:0,doorRL:0,doorRR:0,trunkOpen:0,autopilotActive:0,blindLeft:0,blindRight:0,displayBrightness:0,dashMode:0,mirrorsFolded:0,vehicleCanAgeMs:0)
        _=withUnsafeMutableBytes(of:&p) { data.copyBytes(to:$0) }
        vehicleState.update(from:p)
    }
    private func parseDeviceInfo(_ data: Data) {
        guard data.count >= 16 else { return }
        deviceInfo.uptime=data[0..<4].withUnsafeBytes{$0.load(as:UInt32.self)}
        deviceInfo.freeHeap=data[4..<8].withUnsafeBytes{$0.load(as:UInt32.self)}
        deviceInfo.espNowOK=data[8..<12].withUnsafeBytes{$0.load(as:UInt32.self)}
        deviceInfo.espNowFail=data[12..<16].withUnsafeBytes{$0.load(as:UInt32.self)}
        if data.count>16, let v=String(bytes:data[16...],encoding:.utf8) { deviceInfo.firmwareVersion=v.trimmingCharacters(in:.controlCharacters) }
    }
    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32=0xFFFFFFFF
        for b in data { crc ^= UInt32(b); for _ in 0..<8 { crc = crc&1 != 0 ? (crc>>1)^0xEDB88320 : crc>>1 } }
        return crc^0xFFFFFFFF
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOff: connectionState = .disconnected; lastError="Bluetooth ist ausgeschaltet"
        case .unauthorized: lastError="Bluetooth-Berechtigung fehlt"
        default: break
        }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String:Any], rssi: NSNumber) {
        let d=DiscoveredDevice(id:p.identifier,peripheral:p,rssi:rssi.intValue)
        if !discoveredPeripherals.contains(where:{$0.id==d.id}) { discoveredPeripherals.append(d) }
        else if let i=discoveredPeripherals.firstIndex(where:{$0.id==d.id}) { discoveredPeripherals[i]=d }
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        connectionState = .connected; shouldAutoReconnect=true; reconnectTimer?.invalidate()
        p.discoverServices([BLEUUID.service])
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        connectionState = .failed(error?.localizedDescription ?? "Fehler"); scheduleReconnect()
    }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        resetCharacteristics()
        if shouldAutoReconnect { connectionState = .scanning; scheduleReconnect() } else { connectionState = .disconnected }
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) {
        guard let svc=p.services?.first(where:{$0.uuid==BLEUUID.service}) else { return }
        p.discoverCharacteristics([BLEUUID.ledCommand,BLEUUID.vehicleStatus,BLEUUID.featureSettings,BLEUUID.otaControl,BLEUUID.otaData,BLEUUID.deviceInfo,BLEUUID.presets], for:svc)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        s.characteristics?.forEach { c in
            switch c.uuid {
            case BLEUUID.ledCommand: charLEDCommand=c
            case BLEUUID.vehicleStatus: charVehicleStatus=c; p.setNotifyValue(true,for:c)
            case BLEUUID.featureSettings: charFeatureSettings=c; p.readValue(for:c)
            case BLEUUID.otaControl: charOTAControl=c; p.setNotifyValue(true,for:c)
            case BLEUUID.otaData: charOTAData=c
            case BLEUUID.deviceInfo: charDeviceInfo=c; p.readValue(for:c)
            case BLEUUID.presets: charPresets=c
            default: break
            }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let data=c.value else { return }
        switch c.uuid {
        case BLEUUID.vehicleStatus: parseVehicleStatus(data)
        case BLEUUID.deviceInfo: parseDeviceInfo(data)
        case BLEUUID.otaControl:
            guard data.count >= 3 else { return }
            switch data[0] {
            case 2: otaStatus.phase = .success; otaFirmwareData=nil
            case 3: otaStatus.phase = .failed("Fehlercode: \(data[2])"); otaFirmwareData=nil
            case 4: otaStatus.phase = .verifying
            case 1: otaStatus.phase = .uploading(progress:Double(data[1])/100.0); sendNextOTAChunk()
            default: break
            }
        default: break
        }
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let e=error { lastError="Schreibfehler: \(e.localizedDescription)" }
        if c.uuid==BLEUUID.otaData, error==nil {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.02) { [weak self] in self?.sendNextOTAChunk() }
        }
    }
}