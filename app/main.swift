import SwiftUI
import ServiceManagement

let home = FileManager.default.homeDirectoryForCurrentUser.path
let PY = "\(home)/.config/lg-ac/venv/bin/python", HELPER = "\(home)/.config/lg-ac/lgac.py"

struct AC: Identifiable {
    let id: String, name: String, modes: [String], fans: [String]
    var on: Bool, mode: String, fan: String, cur: Double, target: Double
    var powerSave: Bool?, swing: Bool?
}

func fmt(_ v: Double) -> String { v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }

let LAST = "\(home)/.config/lg-ac/last_status.json"
@MainActor final class Store: ObservableObject {
    @Published var acs: [AC] = []
    @Published var sel = 0
    @Published var connected = false
    @Published var updated: Date? = nil
    @Published var busy = false
    @Published var error: String? = nil
    var backoff = 0
    var nextPoll: Task<Void, Never>?
    var debounce: Task<Void, Never>?
    var afterAction: Task<Void, Never>?
    init() {
        if let d = FileManager.default.contents(atPath: LAST) { _ = parse(d) ; updated = (try? FileManager.default.attributesOfItem(atPath: LAST)[.modificationDate]) as? Date }
        schedule(2)
    }
    var cur: AC? { acs.indices.contains(sel) ? acs[sel] : nil }
    var anyOn: AC? { acs.first { $0.on } }
    func schedule(_ sec: Double) {
        nextPoll?.cancel()
        nextPoll = Task { try? await Task.sleep(nanoseconds: UInt64(sec * 1e9)); if !Task.isCancelled { await refresh() } }
    }
    nonisolated static func run(_ args: [String]) async -> Data? {
        await withCheckedContinuation { c in
            DispatchQueue.global().async {
                let p = Process(); p.executableURL = URL(fileURLWithPath: PY); p.arguments = [HELPER] + args
                let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
                do { try p.run() } catch { c.resume(returning: nil); return }
                let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                c.resume(returning: d)
            }
        }
    }
    func errText(_ e: String, _ retry: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return e == "rate_limit" ? "Limite da LG atingido, tentando de novo às \(f.string(from: retry))" : "Erro: \(e) · nova tentativa às \(f.string(from: retry))"
    }
    func parse(_ d: Data) -> String? {
        let j = try? JSONSerialization.jsonObject(with: d)
        if let e = (j as? [String: Any])?["error"] as? String { return e }
        guard let arr = j as? [[String: Any]] else { return "resposta inválida" }
        acs = arr.map { a in
            let s = a["status"] as? [String: Any] ?? [:]
            func g(_ k: String, _ f: String) -> Any? { (s[k] as? [String: Any])?[f] }
            return AC(id: a["id"] as? String ?? "", name: a["name"] as? String ?? "Ar",
                      modes: a["modes"] as? [String] ?? [], fans: a["fans"] as? [String] ?? [],
                      on: (g("operation", "airConOperationMode") as? String) == "POWER_ON",
                      mode: g("airConJobMode", "currentJobMode") as? String ?? "",
                      fan: g("airFlow", "windStrength") as? String ?? "",
                      cur: (g("temperature", "currentTemperature") as? NSNumber)?.doubleValue ?? 0,
                      target: (g("temperature", "targetTemperature") as? NSNumber)?.doubleValue ?? 0,
                      powerSave: g("powerSave", "powerSaveEnabled") as? Bool,
                      swing: g("windDirection", "rotateUpDown") as? Bool)
        }
        return nil
    }
    func refresh() async {
        guard let d = await Store.run(["status"]) else { fail("helper não executou"); return }
        if let e = parse(d) { fail(e); return }
        connected = true; updated = Date(); error = nil; backoff = 0
        schedule(180)
    }
    func fail(_ e: String) {
        connected = false
        let mins = e == "rate_limit" ? min(60.0, 5.0 * pow(2, Double(backoff))) : 3.0
        if e == "rate_limit" { backoff += 1 }
        error = errText(e, Date().addingTimeInterval(mins * 60))
        schedule(mins * 60)
    }
    func send(_ args: [String]) {
        guard let c = cur else { return }
        busy = true
        Task {
            if let d = await Store.run([args[0], c.id] + args.dropFirst()),
               let e = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? String { fail(e) }
            else if backoff == 0 { schedule(3) }
            busy = false
        }
    }
    func setTarget(_ v: Double) {
        guard acs.indices.contains(sel) else { return }
        acs[sel].target = v
        debounce?.cancel()
        debounce = Task { try? await Task.sleep(nanoseconds: 800_000_000); if !Task.isCancelled { send(["temp", String(v)]) } }
    }
}

let MODES: [(String, String, String)] = [("AUTO","Auto","arrow.triangle.2.circlepath"),("COOL","Frio","snowflake"),
    ("AIR_DRY","Seco","drop"),("FAN","Ventilar","fan"),("HEAT","Quente","sun.max")]
let FANS: [(String, String)] = [("AUTO","Auto"),("LOW","Baixa"),("MID","Média"),("HIGH","Alta")]
let blue = Color(red: 0.36, green: 0.78, blue: 1.0)

struct Tile: View {
    let label: String, icon: String?, active: Bool, action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                Text(label).font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(active ? blue : Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(active ? 0 : 0.08)))
            .foregroundStyle(active ? Color.black.opacity(0.85) : .primary)
        }.buttonStyle(.plain)
    }
}

struct Airflow: View {
    let on: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1/30, paused: !on)) { t in
            Canvas { ctx, size in
                guard on else { return }
                let time = t.date.timeIntervalSinceReferenceDate
                for i in 0..<9 {
                    let x = size.width * (0.2 + 0.075 * Double(i))
                    let phase = (time * 0.6 + Double(i) * 0.13).truncatingRemainder(dividingBy: 1)
                    let y = size.height * phase
                    var p = Path(); p.move(to: CGPoint(x: x + phase * 6, y: y)); p.addLine(to: CGPoint(x: x + phase * 10, y: y + 22))
                    ctx.stroke(p, with: .color(.white.opacity(0.35 * (1 - phase))), lineWidth: 1.5)
                }
            }
        }
    }
}

struct Panel: View {
    @ObservedObject var s: Store
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let e = s.error { Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange) }
            if let ac = s.cur { content(ac) } else {
                Text(s.error != nil ? "Sem dados ainda" : "Conectando ao LG ThinQ…").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
            }
            Divider()
            HStack {
                Button { Task { await s.refresh() } } label: { Label(updatedText, systemImage: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(.secondary)
                if s.busy { ProgressView().controlSize(.small) }
                Spacer()
                Menu { Toggle("Abrir ao iniciar sessão", isOn: Binding(get: { loginOn }, set: { v in
                        do { if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
                        loginOn = SMAppService.mainApp.status == .enabled }))
                    Divider(); Button("Sair") { NSApp.terminate(nil) }
                } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }.font(.system(size: 12))
        }
        .padding(16).frame(width: 360)
    }
    var updatedText: String {
        guard let u = s.updated else { return "Atualizando…" }
        let sec = Int(Date().timeIntervalSince(u)); return sec < 60 ? "Atualizado agora" : sec < 3600 ? "Atualizado há \(sec/60) min" : "Atualizado há \(sec/3600) h"
    }
    func statusLine(_ ac: AC) -> String {
        let m = ["COOL":"Resfriando","HEAT":"Aquecendo","AIR_DRY":"Desumidificando","FAN":"Ventilando","AUTO":"Automático"][ac.mode] ?? ac.mode
        return "\(ac.on ? m : "Desligado") · ambiente \(fmt(ac.cur))°"
    }
    @ViewBuilder func content(_ ac: AC) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "air.conditioner.horizontal").font(.system(size: 16)).frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Menu { ForEach(Array(s.acs.enumerated()), id: \.offset) { i, a in Button(a.name) { s.sel = i } } } label: {
                    HStack(spacing: 4) { Text(ac.name).font(.system(size: 14, weight: .semibold)); Image(systemName: "chevron.down").font(.system(size: 9)) }
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                HStack(spacing: 5) { Circle().fill(s.error == nil ? .green : .orange).frame(width: 7, height: 7)
                    Text(s.error == nil ? "Conectado" : "Dados salvos").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer()
            Button { s.send(["power", ac.on ? "off" : "on"]) } label: {
                Image(systemName: "power").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44)
                    .background(Circle().fill(ac.on ? blue : Color.white.opacity(0.12))).foregroundStyle(ac.on ? .black : .primary)
            }.buttonStyle(.plain).help(ac.on ? "Desligar" : "Ligar")
        }
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05))
            if ac.on { RadialGradient(colors: [blue.opacity(0.22), .clear], center: .center, startRadius: 4, endRadius: 140)
                .clipShape(RoundedRectangle(cornerRadius: 12)) }
            VStack(spacing: 0) {
                Image(systemName: "air.conditioner.horizontal").font(.system(size: 40, weight: .light))
                    .foregroundStyle(ac.on ? Color.white : Color.secondary).opacity(ac.on ? 1 : 0.35)
                    .shadow(color: ac.on ? blue.opacity(0.6) : .clear, radius: 8)
                if ac.on { Airflow(on: true).frame(height: 34) } else { Spacer().frame(height: 34) }
            }.padding(.top, 10)
        }.frame(height: 100)
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 2) { Text(fmt(ac.target)).font(.system(size: 44, weight: .light)).monospacedDigit()
                    Text("°C").font(.system(size: 14)).padding(.top, 6) }
                Label(statusLine(ac), systemImage: "thermometer.medium").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            ForEach([("minus", -1.0), ("plus", 1.0)], id: \.0) { icon, d in
                Button { s.setTarget(min(maxT(ac), max(minT(ac), ac.target + d))) } label: {
                    Image(systemName: icon).frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1)))
                }.buttonStyle(.plain)
            }
        }
        HStack {
            Text("\(fmt(minT(ac)))°").font(.system(size: 11)).foregroundStyle(.secondary)
            Slider(value: Binding(get: { s.cur?.target ?? 22 }, set: { s.setTarget(($0 * 2).rounded() / 2) }), in: minT(ac)...maxT(ac)).tint(blue)
            Text("\(fmt(maxT(ac)))°").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        section("Modo")
        HStack(spacing: 6) {
            ForEach(MODES.filter { ac.modes.contains($0.0) }, id: \.0) { m in
                Button { s.send(["mode", m.0]) } label: {
                    VStack(spacing: 4) { Image(systemName: m.2).font(.system(size: 15)); Text(m.1).font(.system(size: 11)) }
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(RoundedRectangle(cornerRadius: 8).fill(ac.mode == m.0 ? blue : Color.white.opacity(0.06)))
                        .foregroundStyle(ac.mode == m.0 ? Color.black.opacity(0.85) : .primary)
                }.buttonStyle(.plain)
            }
        }
        HStack { section("Ventilação"); Spacer(); Text(FANS.first { $0.0 == ac.fan }?.1 ?? "").font(.system(size: 11)).foregroundStyle(.secondary) }
        HStack(spacing: 4) {
            ForEach(FANS.filter { ac.fans.contains($0.0) }, id: \.0) { f in Tile(label: f.1, icon: nil, active: ac.fan == f.0) { s.send(["fan", f.0]) } }
        }.padding(3).background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
        if ac.powerSave != nil || ac.swing != nil {
            section("Recursos")
            HStack(spacing: 6) {
                if let v = ac.powerSave { Tile(label: "Economia", icon: "leaf", active: v) { s.send(["save", v ? "off" : "on"]) } }
                if let v = ac.swing { Tile(label: "Swing", icon: "arrow.up.arrow.down", active: v) { s.send(["swing", v ? "off" : "on"]) } }
            }
        }
    }
    func minT(_ ac: AC) -> Double { ac.mode == "HEAT" ? 16 : 18 }
    func maxT(_ ac: AC) -> Double { 30 }
    func section(_ t: String) -> some View { Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
}

@main struct ArLGApp: App {
    @StateObject var s = Store()
    var body: some Scene {
        MenuBarExtra {
            Panel(s: s)
        } label: {
            if let on = s.anyOn { HStack { Image(systemName: "snowflake"); Text("\(fmt(on.target))°") } }
            else { Image(systemName: "snowflake") }
        }.menuBarExtraStyle(.window)
    }
}
