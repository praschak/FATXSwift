import SwiftUI
import Foundation
import FATXCore

@MainActor
struct SecurityProbeView: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Drive Security", systemImage: "externaldrive.badge.checkmark").font(.title2.bold())
            Picker("Device", selection: $model.securityTarget) {
                ForEach(model.devices) { device in Text("\(device.name) · \(device.path)").tag(device.path) }
            }.disabled(model.busy).onChange(of: model.securityTarget) { _ in model.securityProbe = nil }
            Text("The disk is unmounted and its USB adapter is temporarily disconnected during each operation. Finish file transfers first.").font(.caption).foregroundStyle(.secondary)
            Button("Inspect Device") { model.inspectDriveSecurity() }.disabled(model.busy || model.securityTarget.isEmpty)
            if let info = model.securityProbe {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Adapter: \(info.adapter) (\(info.usbID))")
                    Text("Model: \(info.model)  ·  Serial: \(info.serial)")
                    Text("Security supported: \(yn(info.supported))  ·  Password enabled: \(yn(info.enabled))  ·  Locked: \(yn(info.locked))")
                    Text("Frozen: \(yn(info.frozen))  ·  Attempts exhausted: \(yn(info.expired))  ·  Level: \(info.enabled ? (info.maximum ? "maximum" : "high") : "–")")
                }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            if let secret = model.securityProbe?.derivedPassword {
                Text("Derived password (private): " + secret.map { String(format: "%02x", $0) }.joined())
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Divider()
            Picker("Credential", selection: $model.securityCredential) {
                Text("ATA password").tag("Password")
                Text("HDD key (hex)").tag("HDD key")
            }.disabled(model.busy)
            if model.securityCredential == "HDD key" {
                if !model.savedKeyNames.isEmpty {
                    HStack {
                        Picker("Saved HDD key", selection: $model.selectedSavedKey) {
                            Text("Enter manually").tag("")
                            ForEach(model.savedKeyNames, id: \.self) { name in Text(name).tag(name) }
                        }.onChange(of: model.selectedSavedKey) { name in model.selectSavedKey(name) }
                        Button("Delete…") { model.deleteSavedKey() }.disabled(model.selectedSavedKey.isEmpty || model.busy)
                    }.disabled(model.busy)
                }
                SecureField("32 hexadecimal characters", text: $model.securityPassword).textFieldStyle(.roundedBorder).disabled(model.busy)
                Toggle("Save HDD key in macOS Keychain after a successful set or unlock", isOn: $model.saveHDDKey).disabled(model.busy)
                if model.saveHDDKey {
                    TextField("Name for this key", text: $model.newKeyName).textFieldStyle(.roundedBorder).disabled(model.busy)
                }
            } else {
                SecureField(model.securityHex ? "Password in hex" : "Password", text: $model.securityPassword).textFieldStyle(.roundedBorder).disabled(model.busy)
                HStack {
                    Toggle("Hex", isOn: $model.securityHex)
                    Toggle("Master password", isOn: $model.securityMaster)
                    Toggle("Maximum security", isOn: $model.securityMaximum)
                }.disabled(model.busy)
            }
            if model.securityCredential != "Password" {
                Toggle("Serial first (legacy alternative)", isOn: $model.securitySerialFirst).disabled(model.busy)
                    .help("The standard derivation uses model followed by serial. Wrong passwords consume attempts.")
            }
            Text("A set password becomes locked after power is removed. Keep your current HDD key and backup safe.").font(.caption).foregroundStyle(.secondary)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).lineLimit(2)
                Spacer()
            }
            Divider()
            HStack {
                Button("Done") { model.showSecurityProbe = false }.disabled(model.busy)
                Spacer()
                if model.securityCredential != "Password" {
                    Button("Show Password…") { model.performSecurity(.derive) }.disabled(model.busy || model.securityProbe == nil)
                }
                Button("Unlock…") { model.performSecurity(.unlock) }.disabled(model.busy || model.securityProbe == nil)
                Button("Remove Password…") { model.performSecurity(.disable) }.disabled(model.busy || model.securityProbe == nil)
                Button("Set Password…") { model.performSecurity(.set) }.disabled(model.busy || model.securityProbe == nil)
            }
        }.padding(24).frame(width: 700).interactiveDismissDisabled(model.busy)
    }
    private func yn(_ value: Bool) -> String { value ? "yes" : "no" }
}
