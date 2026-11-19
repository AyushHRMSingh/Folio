import AppKit
import Combine
import FolioCore
import SwiftUI


struct ChapterDivider: View {
    let chapter: Chapter
    let ink: Color
    var body: some View {
        HStack(spacing: 15) {
            Rectangle().fill(ink.opacity(0.14)).frame(height: 1)
            Text(chapter.name).font(.system(size: 13, weight: .medium)).foregroundStyle(ink.opacity(0.5)).lineLimit(1).fixedSize()
            Rectangle().fill(ink.opacity(0.14)).frame(height: 1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TransitionCard: View {
    @ObservedObject var model: ReaderModel
    let from: Chapter
    let to: Chapter?
    let ink: Color

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 3) {
                Text("FINISHED").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(ink.opacity(0.5))
                Text(from.name).font(.headline).foregroundStyle(ink.opacity(0.85)).multilineTextAlignment(.center)
            }
            if let to {
                Image(systemName: "chevron.compact.down").font(.title2).foregroundStyle(ink.opacity(0.35))
                VStack(spacing: 3) {
                    Text("NEXT").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(ink.opacity(0.5))
                    Text(to.name).font(.title3.weight(.semibold)).foregroundStyle(ink).multilineTextAlignment(.center)
                }
                if model.appendingNext { ProgressView().controlSize(.small).tint(ink) }
                else if !model.prefs.seamlessChapters || model.mode != .webtoon {
                    Button("Continue") { model.goNext() }.buttonStyle(.monoPrimary)
                }
            } else {
                Image(systemName: "checkmark.circle").font(.system(size: 36, weight: .light)).foregroundStyle(ink.opacity(0.8))
                Text("You're all caught up").font(.title3.weight(.semibold)).foregroundStyle(ink)
                Button("Back to \(model.series.title)") { model.close() }.buttonStyle(.mono)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ink.opacity(0.1)))
    }
}

