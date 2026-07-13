import SwiftUI

struct SyncConfigurationView: View {
    @Binding var draft: SyncSettingsPresentation.ConnectionForm
    let isTesting: Bool
    let error: String?
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker(UIStrings.text(zh: "存储类型", en: "Storage Type"), selection: $draft.backend) {
                    ForEach(SyncSettingsPresentation.Backend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.segmented)

                if draft.backend == .webDAV {
                    Section("WebDAV") {
                        TextField("HTTPS URL", text: $draft.webDAVURL)
                        TextField(UIStrings.text(zh: "用户名", en: "Username"), text: $draft.webDAVUsername)
                        SecureField(UIStrings.text(zh: "密码或应用密码", en: "Password or App Password"), text: $draft.webDAVPassword)
                    }
                } else {
                    Section("S3") {
                        TextField("Endpoint", text: $draft.s3Endpoint)
                        TextField("Region", text: $draft.s3Region)
                        TextField("Bucket", text: $draft.s3Bucket)
                        TextField(UIStrings.text(zh: "基础前缀", en: "Base Prefix"), text: $draft.s3Prefix)
                        TextField("Access Key", text: $draft.s3AccessKey)
                        SecureField("Secret Key", text: $draft.s3SecretKey)
                        Toggle("Path-style", isOn: $draft.s3UsesPathStyle)
                    }
                }

                LabeledContent(UIStrings.text(zh: "应用目录", en: "App Path")) {
                    Text("vibeusage/sync/v1/")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button(UIStrings.text(zh: "取消", en: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: onSave) {
                    if isTesting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(UIStrings.text(zh: "正在测试", en: "Testing"))
                        }
                    } else {
                        Label(UIStrings.text(zh: "测试并保存", en: "Test and Save"), systemImage: "checkmark.circle")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isTesting)
            }
            .padding(16)
        }
        .frame(width: 520, height: 500)
    }
}
