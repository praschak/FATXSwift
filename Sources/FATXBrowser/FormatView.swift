import SwiftUI
import Foundation
import FATXCore

@MainActor
struct FormatView: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Format FATX Device", systemImage: "externaldrive.badge.exclamationmark").font(.title2.bold())
            Text("All existing volumes and files on the selected disk will be erased.").foregroundStyle(.red)
            Picker("Device", selection: $model.formatTarget) {
                ForEach(model.devices) { device in Text("\(device.name) · \(device.path) · \(size(device.size))").tag(device.path) }
            }.disabled(model.busy).onChange(of: model.formatTarget) { _ in model.formatPlan = nil; model.formatConfirmation = "" }
            Picker("Layout", selection: $model.formatProfile) {
                Text("Classic C/E/X/Y/Z + split F/G (LBA48)").tag(FormatProfile.lba48FG)
                Text("Classic C/E/X/Y/Z + one F (LBA48)").tag(FormatProfile.lba48F)
                Text("Retail C/E/X/Y/Z only; extra space unused").tag(FormatProfile.retail)
            }.disabled(model.busy).onChange(of: model.formatProfile) { _ in model.formatPlan = nil; model.formatConfirmation = "" }
            Text("F/G layouts require a patched kernel with partition-table support. Classic layouts support up to 2 TiB with 512-byte logical sectors.").font(.caption).foregroundStyle(.secondary)
            Button("Review Layout") { model.reviewFormat() }.disabled(model.busy || model.formatTarget.isEmpty)
            if let plan = model.formatPlan {
                ScrollView {
                    VStack(spacing: 7) {
                        HStack { Text("Volume").frame(width: 65, alignment: .leading); Text("Size").frame(width: 130, alignment: .trailing); Text("Cluster").frame(width: 90, alignment: .trailing); Text("Offset").frame(maxWidth: .infinity, alignment: .trailing) }.font(.caption.bold())
                        ForEach(plan.volumes, id: \.name) { volume in
                            HStack {
                                Text(volume.name).frame(width: 65, alignment: .leading)
                                Text(size(volume.length)).frame(width: 130, alignment: .trailing)
                                Text("\(volume.bytesPerCluster / 1024) KiB").frame(width: 90, alignment: .trailing)
                                Text("0x" + String(volume.offset, radix: 16)).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }
                }.frame(height: 170)
                Text("Undo journal estimate: \(size(plan.estimatedJournalBytes)). Quick format does not securely erase old file contents.").font(.caption).foregroundStyle(.secondary)
                Text("Creates empty volumes. Import your system/dashboard backup into C/E and complete drive locking separately before installation.").font(.callout)
                TextField("Type \(URL(fileURLWithPath: plan.source).lastPathComponent) to confirm the target", text: $model.formatConfirmation).textFieldStyle(.roundedBorder).disabled(model.busy)
            } else {
                Text("Review the partition sizes before formatting. Retail volumes retain their required 16 KiB clusters.").foregroundStyle(.secondary).frame(height: 150)
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).lineLimit(2)
                Spacer()
            }
            Divider()
            HStack {
                Button("Cancel") { model.showFormat = false }.disabled(model.busy)
                Spacer()
                Button("Erase & Format…", role: .destructive) { model.performFormat() }
                    .disabled(model.busy || model.formatPlan == nil || model.formatConfirmation != URL(fileURLWithPath: model.formatTarget).lastPathComponent)
            }
        }.padding(24).frame(width: 660)
        .interactiveDismissDisabled(model.busy)
    }
    private func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}
