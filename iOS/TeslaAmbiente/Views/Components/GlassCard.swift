// MARK: - GlassCard.swift
import SwiftUI

struct GlassCard<Content: View>: View {
    let content: Content; var padding: CGFloat=16; var cornerRadius: CGFloat=20
    init(padding: CGFloat=16, cornerRadius: CGFloat=20, @ViewBuilder content: ()->Content) { self.padding=padding; self.cornerRadius=cornerRadius; self.content=content() }
    var body: some View {
        content.padding(padding).background(RoundedRectangle(cornerRadius:cornerRadius).fill(.ultraThinMaterial).overlay(RoundedRectangle(cornerRadius:cornerRadius).stroke(LinearGradient(colors:[.white.opacity(0.25),.white.opacity(0.05)],startPoint:.topLeading,endPoint:.bottomTrailing),lineWidth:1)))
    }
}

struct ConnectionDot: View {
    let state: BLEConnectionState; @State private var pulse=false
    var color: Color { switch state { case .connected: return .green; case .scanning: return .orange; case .connecting: return .yellow; case .disconnected: return .gray; case .failed: return .red } }
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.3)).frame(width:18,height:18).scaleEffect(pulse ? 1.6:1.0).animation(.easeInOut(duration:1.0).repeatForever(autoreverses:true),value:pulse)
            Circle().fill(color).frame(width:10,height:10)
        }.onAppear { if case .connected=state { pulse=true }; if case .scanning=state { pulse=true } }
        .onChange(of:state.isConnected) { _,_ in pulse=state.isConnected }
    }
}

struct ColorCircle: View {
    let color: LEDColor; var size: CGFloat=36
    var body: some View {
        Circle().fill(Color(red:Double(color.r)/255,green:Double(color.g)/255,blue:Double(color.b)/255)).frame(width:size,height:size).overlay(Circle().stroke(.white.opacity(0.3),lineWidth:1)).shadow(color:.black.opacity(0.3),radius:4,y:2)
    }
}

struct LabeledSlider: View {
    let label: String; let icon: String; @Binding var value: UInt8; var range: ClosedRange<Double>=0...255; var color: Color = .accentColor
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack { Label(label,systemImage:icon).font(.subheadline.weight(.medium)).foregroundStyle(.secondary); Spacer(); Text("\(value)").font(.subheadline.monospacedDigit()).foregroundStyle(color).frame(width:36,alignment:.trailing) }
            Slider(value:Binding(get:{Double(value)},set:{value=UInt8(clamping:Int($0))}),in:range).tint(color)
        }
    }
}

struct EffectButton: View {
    let effect: LEDEffect; let isSelected: Bool; let action: ()->Void
    var body: some View {
        Button(action:action) {
            VStack(spacing:6) {
                Image(systemName:effect.systemIcon).font(.system(size:22)).symbolRenderingMode(.hierarchical)
                Text(effect.displayName).font(.caption2.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
            }.frame(width:75,height:70).foregroundStyle(isSelected ? .white:.secondary)
            .background(RoundedRectangle(cornerRadius:14).fill(isSelected ? Color.accentColor:Color.secondary.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius:14).stroke(isSelected ? .clear:.secondary.opacity(0.2),lineWidth:1))
        }.buttonStyle(.plain).scaleEffect(isSelected ? 1.03:1.0).animation(.spring(response:0.2),value:isSelected)
    }
}

struct ZoneButton: View {
    let zone: LEDZone; let isSelected: Bool; let action: ()->Void
    var body: some View {
        Button(action:action) {
            VStack(spacing:4) { Image(systemName:zone.systemIcon).font(.system(size:18)); Text(zone.shortName).font(.caption.weight(.semibold)) }
            .frame(width:56,height:56).foregroundStyle(isSelected ? .white:.secondary)
            .background(RoundedRectangle(cornerRadius:12).fill(isSelected ? Color.accentColor:Color.secondary.opacity(0.1)))
        }.buttonStyle(.plain).scaleEffect(isSelected ? 1.05:1.0).animation(.spring(response:0.2),value:isSelected)
    }
}

struct CarDiagramView: View {
    let vehicleState: VehicleState; var size: CGFloat=200
    var body: some View {
        GeometryReader { g in
            let w=g.size.width; let h=g.size.height
            ZStack {
                RoundedRectangle(cornerRadius:w*0.15).stroke(.secondary.opacity(0.5),lineWidth:1.5).padding(.horizontal,w*0.1).padding(.vertical,h*0.05)
                doorDot(x:w*0.1,y:h*0.22,open:vehicleState.doorFrontLeft,label:"VL")
                doorDot(x:w*0.78,y:h*0.22,open:vehicleState.doorFrontRight,label:"VR")
                doorDot(x:w*0.1,y:h*0.62,open:vehicleState.doorRearLeft,label:"HL")
                doorDot(x:w*0.78,y:h*0.62,open:vehicleState.doorRearRight,label:"HR")
                doorDot(x:w*0.4,y:h*0.86,open:vehicleState.trunkOpen,label:"KO")
                if vehicleState.autopilotActive { Image(systemName:"brain.head.profile").foregroundStyle(.blue).font(.system(size:18)).position(x:w*0.5,y:h*0.5) }
                if vehicleState.blindLeft { Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size:14)).position(x:w*0.08,y:h*0.5) }
                if vehicleState.blindRight { Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size:14)).position(x:w*0.92,y:h*0.5) }
            }
        }.frame(width:size,height:size*1.4)
    }
    @ViewBuilder private func doorDot(x: CGFloat,y: CGFloat,open: Bool,label: String) -> some View {
        VStack(spacing:2) { Circle().fill(open ? Color.orange:Color.secondary.opacity(0.3)).frame(width:10,height:10); Text(label).font(.system(size:7,weight:.medium)).foregroundStyle(.secondary) }.position(x:x,y:y)
    }
}

struct FeatureToggleRow: View {
    let title: String; let subtitle: String; let icon: String; @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn:$isOn) { Label { VStack(alignment:.leading,spacing:2) { Text(title).font(.body.weight(.medium)); Text(subtitle).font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName:icon).symbolRenderingMode(.hierarchical).foregroundStyle(.accentColor).frame(width:28) } }
    }
}

struct BatteryView: View {
    let percentage: Int; let isCharging: Bool
    var batteryColor: Color { isCharging ? .green : percentage<15 ? .red : percentage<30 ? .orange : .green }
    var body: some View {
        HStack(spacing:4) {
            ZStack(alignment:.leading) {
                RoundedRectangle(cornerRadius:3).stroke(.secondary.opacity(0.5),lineWidth:1.5).frame(width:36,height:18)
                RoundedRectangle(cornerRadius:2).fill(batteryColor).frame(width:max(2,34*Double(percentage)/100),height:16).padding(.leading,1)
                if isCharging { Image(systemName:"bolt.fill").font(.system(size:10,weight:.bold)).foregroundStyle(.white).frame(width:36,height:18) }
            }
            RoundedRectangle(cornerRadius:1).fill(.secondary.opacity(0.5)).frame(width:3,height:8)
            Text("\(percentage)%").font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(batteryColor)
        }
    }
}

struct LEDColorPicker: View {
    let label: String; @Binding var ledColor: LEDColor
    private var swiftColor: Binding<Color> {
        Binding(get:{Color(red:Double(ledColor.r)/255,green:Double(ledColor.g)/255,blue:Double(ledColor.b)/255)},
                set:{ let r=$0.resolve(in:.init()); ledColor=LEDColor(r:UInt8(clamping:Int(r.red*255)),g:UInt8(clamping:Int(r.green*255)),b:UInt8(clamping:Int(r.blue*255))) })
    }
    var body: some View { HStack { Text(label).font(.body.weight(.medium)); Spacer(); ColorPicker("",selection:swiftColor,supportsOpacity:false).labelsHidden().frame(width:44,height:30) } }
}

extension UInt8 { init(clamping value: Int) { self=UInt8(max(0,min(255,value))) } }