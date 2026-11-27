import FolioCore
import SwiftUI

/// The download queue: what's running, what's waiting (drag to reorder) and what failed. Pause, retry, remove.
struct DownloadsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library
    @State private var confirmCancel = false

    private var jobs: [DownloadJob] { library.downloadJobs }
    private var failed: Int { jobs.filter { if case .failed = $0.state { true } else { false } }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, Theme.pad).padding(.top, 8)
            if jobs.isEmpty {
                Text("Nothing downloading. Download chapters from a series page; they wait here until they\u{2019}re saved for offline reading.")
                    .font(.system(size: 15.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.pad).padding(.top, 28)
                Spacer()
            } else {
                List {
                    ForEach(jobs) { j in
                        DownloadRow(library: library, job: j)
                            .listRowInsets(EdgeInsets(top: 0, leading: Theme.pad - 8, bottom: 0, trailing: Theme.pad - 8))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .onMove { library.moveDownloads(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
        .confirmationDialog("Cancel all downloads?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel All", role: .destructive) { library.cancelDownloads() }
        } message: { Text("Chapters already saved stay downloaded. The rest are taken out of the queue.") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Downloads").font(.system(size: 36, weight: .light)).tracking(-1).foregroundStyle(Theme.ink)
                Spacer()
                if !jobs.isEmpty {
                    if library.downloadsPaused { TextAction(title: "Resume") { library.resumeDownloads() } }
                    else if library.downloadsPending > 0 { TextAction(title: "Pause") { library.pauseDownloads() } }
                    if failed > 0 {
                        TextAction(title: "Retry failed") { library.retryFailedDownloads() }
                        TextAction(title: "Clear failed") { library.clearFailedDownloads() }
                    }
                    TextAction(title: "Cancel all", destructive: true) { confirmCancel = true }
                }
            }
            if !jobs.isEmpty {
                Text(summary).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.dim)
            }
        }
    }

    private var summary: String {
        let running = jobs.filter { $0.state == .running }.count
        let waiting = jobs.filter { $0.state == .queued }.count
        var parts: [String] = []
        if library.downloadsPaused { parts.append("paused") }
        if running > 0 { parts.append("\(running) downloading") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if failed > 0 { parts.append("\(failed) failed") }
        if let s = library.downloadSecondsLeft, running + waiting > 0 { parts.append(Self.timeLeft(s)) }
        if waiting > 1 { parts.append("drag to reorder") }
        return parts.joined(separator: " · ")
    }

    static func timeLeft(_ s: Double) -> String {
        if s < 60 { return "under a minute left" }
        let m = Int((s / 60).rounded())
        return m < 60 ? "about \(m) min left" : "about \(m / 60) h \(m % 60) min left"
    }
}

private struct DownloadRow: View {
    @ObservedObject var library: Library
    let job: DownloadJob
    @State private var hover = false

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.seriesTitle).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(job.chapterName).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer(minLength: 16)
            status
            HStack(spacing: 2) {
                if job.state == .queued {
                    IconButton(icon: "arrow.up.to.line", help: "Download next", size: 26) { library.moveDownloadToTop(job.key) }
                }
                if case .failed = job.state {
                    IconButton(icon: "arrow.clockwise", help: "Retry", size: 26) { library.retryDownload(job.key) }
                }
                IconButton(icon: "xmark", help: "Remove from queue", size: 26) { library.removeDownload(job.key) }
            }
            .opacity(hover ? 1 : 0)
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            if job.state == .queued { Button("Download Next") { library.moveDownloadToTop(job.key) } }
            if case .failed = job.state { Button("Retry") { library.retryDownload(job.key) } }
            Button("Remove from Queue") { library.removeDownload(job.key) }
        }
    }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .running:
            HStack(spacing: 10) {
                ProgressView(value: job.total > 0 ? Double(job.done) / Double(job.total) : 0)
                    .progressViewStyle(.linear).tint(Theme.ink).frame(width: 120)
                Text(job.total > 0 ? "\(job.done)/\(job.total)" : "starting")
                    .font(.system(size: 12.5, design: .monospaced).monospacedDigit()).foregroundStyle(Theme.dim).frame(width: 64, alignment: .trailing)
            }
        case .queued:
            Text(library.downloadsPaused ? "paused" : "waiting").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.faint)
        case .failed(let why):
            Text("failed: \(why)").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Color.red.opacity(0.85))
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: 280, alignment: .trailing).help(why)
        }
    }
}
