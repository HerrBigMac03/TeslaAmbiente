// MARK: - MainViewModel.swift
import Foundation
import SwiftUI
import Combine

@MainActor
final class MainViewModel: ObservableObject {
    @Published var ledSettings=LEDSettings()
    @Published var featureSettings=FeatureSettings()
    @Published var presets: [LEDPreset]=[]
    @Published var selectedZone: LEDZone = .all
    @Published var showFeedback: FeedbackMessage?=nil
    let ble=BLEManager.shared
    private var cancellables=Set<AnyCancellable>()
    private let settingsKey="led_settings_v1", featuresKey="feature_settings_v1", presetsKey="presets_v1"
    struct FeedbackMessage: Identifiable { let id=UUID(); let message: String; let isError: Bool }
    init() { loadFromDisk(); setupAutoSave() }
    func sendCurrentSettings(to zone: LEDZone?=nil) {
        let t=zone ?? selectedZone; ble.sendLEDCommand(ledSettings.buildPacket(for:t))
        feedback("Gesendet an \(t.displayName)", err:false)
    }
    func turnOff(zone: LEDZone?=nil) { var p=ledSettings.buildPacket(for:zone ?? selectedZone); p.power=0; ble.sendLEDCommand(p) }
    func turnOn(zone: LEDZone?=nil) { var p=ledSettings.buildPacket(for:zone ?? selectedZone); p.power=1; ble.sendLEDCommand(p) }
    func applyPreset(_ p: LEDPreset) { ledSettings.color1=p.color; ledSettings.effect=LEDEffect(rawValue:p.effect) ?? .staticColor; ledSettings.brightness=p.brightness; ledSettings.speed=p.speed; sendCurrentSettings() }
    func saveCurrentAsPreset(name: String) {
        let p=LEDPreset(name:name,color:ledSettings.color1,effect:ledSettings.effect.rawValue,brightness:ledSettings.brightness,speed:ledSettings.speed)
        presets.insert(p,at:0); if presets.count>10 { presets=Array(presets.prefix(10)) }
        savePresets(); feedback("Preset '\(name)' gespeichert",err:false)
    }
    func deletePreset(_ p: LEDPreset) { presets.removeAll{$0.id==p.id}; savePresets() }
    func sendFeatureSettings() { ble.sendFeatureSettings(featureSettings); saveFeatureSettings(); feedback("Einstellungen gespeichert",err:false) }
    func startOTA(firmwareData: Data, target: OTATarget) { ble.startOTAUpdate(firmwareData:firmwareData,target:target) }
    func feedback(_ msg: String, err: Bool) {
        withAnimation { showFeedback=FeedbackMessage(message:msg,isError:err) }
        DispatchQueue.main.asyncAfter(deadline:.now()+2.5) { [weak self] in withAnimation { self?.showFeedback=nil } }
    }
    private func loadFromDisk() {
        if let d=UserDefaults.standard.data(forKey:settingsKey), let v=try? JSONDecoder().decode(LEDSettings.self,from:d) { ledSettings=v }
        if let d=UserDefaults.standard.data(forKey:featuresKey), let v=try? JSONDecoder().decode(FeatureSettings.self,from:d) { featureSettings=v }
        if let d=UserDefaults.standard.data(forKey:presetsKey), let v=try? JSONDecoder().decode([LEDPreset].self,from:d) { presets=v }
    }
    private func setupAutoSave() {
        ledSettings.objectWillChange.debounce(for:.seconds(1),scheduler:RunLoop.main).sink { [weak self] _ in self?.saveLEDSettings() }.store(in:&cancellables)
        featureSettings.objectWillChange.debounce(for:.seconds(1),scheduler:RunLoop.main).sink { [weak self] _ in self?.saveFeatureSettings() }.store(in:&cancellables)
    }
    private func saveLEDSettings() { if let d=try? JSONEncoder().encode(ledSettings) { UserDefaults.standard.set(d,forKey:settingsKey) } }
    private func saveFeatureSettings() { if let d=try? JSONEncoder().encode(featureSettings) { UserDefaults.standard.set(d,forKey:featuresKey) } }
    private func savePresets() { if let d=try? JSONEncoder().encode(presets) { UserDefaults.standard.set(d,forKey:presetsKey) } }
}

@MainActor
final class OTAViewModel: ObservableObject {
    @Published var selectedTarget: OTATarget = .master
    @Published var firmwareURL: URL?=nil; @Published var firmwareData: Data?=nil; @Published var firmwareSize=""
    @Published var isShowingFilePicker=false; @Published var isDeveloperUnlocked=false
    @Published var passwordInput=""; @Published var wrongPassword=false; @Published var isUploading=false
    private let developerPassword="tesla2024"
    let ble=BLEManager.shared
    func checkPassword() {
        if passwordInput==developerPassword { isDeveloperUnlocked=true; wrongPassword=false; passwordInput="" }
        else { wrongPassword=true; DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.passwordInput="" } }
    }
    func loadFirmware(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }; defer { url.stopAccessingSecurityScopedResource() }
        if let d=try? Data(contentsOf:url) { firmwareData=d; firmwareURL=url; firmwareSize=ByteCountFormatter.string(fromByteCount:Int64(d.count),countStyle:.file) }
    }
    func startUpload() { guard let d=firmwareData else { return }; isUploading=true; ble.startOTAUpdate(firmwareData:d,target:selectedTarget) }
    func abortUpload() { ble.abortOTA(); isUploading=false }
    func reset() { firmwareURL=nil; firmwareData=nil; firmwareSize=""; isUploading=false }
    var canStartUpload: Bool { firmwareData != nil && ble.connectionState.isConnected && !isUploading }
}