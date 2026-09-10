import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    @State private var showClearConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                if engine.queue.isEmpty {
                    ContentUnavailableView(
                        "Queue is empty",
                        systemImage: "list.bullet",
                        description: Text("Swipe a search result to add it here.")
                    )
                } else {
                    ForEach(Array(engine.queue.enumerated()), id: \.element.id) { index, item in
                        QueueRow(item: item, isCurrent: index == engine.currentIndex)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                engine.playNow(item)
                            }
                    }
                    .onMove { source, destination in
                        engine.moveInQueue(from: source, to: destination)
                    }
                    .onDelete { offsets in
                        engine.removeFromQueue(atOffsets: offsets)
                    }
                }
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        if !engine.queue.isEmpty {
                            EditButton()
                        }
                        // Everything except the current track goes, so the
                        // queue stays exactly what the user queued.
                        if engine.queue.count > 1 {
                            Button {
                                showClearConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Clear queue")
                        }
                    }
                }
            }
            .confirmationDialog(
                "Remove every queued song except the current one?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear queue", role: .destructive) {
                    engine.clearQueue()
                }
            }
        }
    }
}

private struct QueueRow: View {
    @EnvironmentObject private var engine: PlayerEngine

    let item: MediaItem
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: item.artworkURL, fallbackSystemImage: item.kind.systemImage)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                Text(item.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isCurrent {
                Image(systemName: engine.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                    .font(.footnote)
                    .foregroundStyle(.tint)
            } else if item.duration > 0 {
                Text(item.formattedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
