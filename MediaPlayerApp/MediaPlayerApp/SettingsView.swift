import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var registry: SourceRegistry
    @EnvironmentObject private var engine: PlayerEngine

    @State private var invidiousHosts = InvidiousSource.hosts.joined(separator: "\n")
    @State private var showInvidiousHelp = false
    @State private var showYouTubeHelp = false
    @State private var preferProgressive = YouTubeSource.preferProgressiveVideo

    var body: some View {
        Form {
            Section {
                ForEach(registry.all, id: \.id) { source in
                    SourceToggleRow(source: source)
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("Browse searches every enabled source at once and interleaves the results.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { engine.audioOnly },
                    set: { engine.setAudioOnly($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Audio only")
                        Text("Streams just the audio track for videos. Turn this on if you mainly listen to music — far less data, less battery, and it keeps playing with the screen off. Applies to everything you play, and persists between launches.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Listening")
            }

            Section {
                Toggle(isOn: $preferProgressive) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prefer progressive video")
                        Text("Caps quality near 360p but uses a stream format that cannot contain inserted ads. Off by default: HLS gives up to 4K and currently carries no ad markers.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: preferProgressive) { _, newValue in
                    YouTubeSource.preferProgressiveVideo = newValue
                }

                Button("Test the YouTube pipeline") {
                    showYouTubeHelp = true
                }
                .font(.footnote)
            } header: {
                Text("YouTube")
            } footer: {
                Text("Streams are extracted on device — no server, no API key. Ads are absent because the ad-serving player is bypassed entirely, not because anything is blocked.")
            }

            Section {
                TextField(
                    "https://invidious.example.com",
                    text: $invidiousHosts,
                    axis: .vertical
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.callout.monospaced())
                .lineLimit(1...4)

                Button("Save host") {
                    let entries = invidiousHosts
                        .split(whereSeparator: { $0 == "," || $0 == "\n" })
                        .map { InvidiousSource.normalise(String($0)) }
                        .filter { !$0.isEmpty }
                    InvidiousSource.hosts = entries
                    invidiousHosts = entries.joined(separator: "\n")
                    registry.objectWillChange.send()
                }
                .disabled(invidiousHosts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && InvidiousSource.hosts.isEmpty)

                Button("Why isn't this filled in?") {
                    showInvidiousHelp = true
                }
                .font(.footnote)
            } header: {
                Text("Invidious fallback (optional)")
            } footer: {
                Text("Only useful if you run your own Invidious server, as a backup for when on-device extraction breaks. One host per line. Public instances no longer serve their API.")
            }

            Section {
                LabeledContent("Playback speed", value: Formatters.speedLabel(engine.playbackSpeed))
                LabeledContent("Repeat", value: engine.repeatMode.label)
                LabeledContent("Shuffle", value: engine.isShuffled ? "On" : "Off")
                if let remaining = engine.sleepTimerRemaining {
                    LabeledContent("Sleep timer", value: Formatters.duration(remaining))
                }
            } header: {
                Text("Playback")
            }

            Section {
                LabeledContent("Version", value: Self.versionString)
                if let docs = URL(string: "https://docs.invidious.io/installation/") {
                    Link(destination: docs) {
                        Label("Self-host Invidious", systemImage: "book")
                    }
                }
            } header: {
                Text("About")
            } footer: {
                Text("Personal use, not for distribution. Extracting YouTube streams is contrary to YouTube's Terms of Service — worth knowing, and your call. Podcasts and Internet Archive are public catalogues intended for direct access; local files are yours.")
            }
        }
        .navigationTitle("Settings")
        .alert("If YouTube stops working", isPresented: $showYouTubeHelp) {
            Button("OK") {}
        } message: {
            Text("""
            YouTube periodically rotates the client versions it accepts. When \
            playback starts failing, run scripts/probe-youtube.py from the \
            project folder — it tests search, stream extraction, fetching and \
            ad presence separately and tells you which stage broke.

            The fix is usually just bumping the version strings in \
            YouTubeSource.swift (the ClientProfile structs).
            """)
        }
        .alert("Public instances are blocked", isPresented: $showInvidiousHelp) {
            Button("OK") {}
        } message: {
            Text("""
            Every public Invidious instance now either disables its API, returns 401/403, \
            or answers with a bot-check page instead of JSON. An app can't get past those.

            Running your own instance works. Podcasts, Internet Archive, and your own \
            files need no setup and are enabled by default.
            """)
        }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

private struct SourceToggleRow: View {
    @EnvironmentObject private var registry: SourceRegistry
    let source: MediaSource

    var body: some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: source.systemImage)
                        .foregroundStyle(.tint)
                    Text(source.displayName)
                    if !source.isAvailable {
                        Text("Needs setup")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(source.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!source.isAvailable)
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { registry.isEnabled(source) },
            set: { registry.setEnabled($0, for: source) }
        )
    }
}
