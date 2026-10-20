//
//  ContentView.swift
//  NotchLyrics
//
//  One panel view. Collapsed and expanded are the same layout, animated
//  by NowPlayingModel instead of swapping screens.
//

import SwiftUI

enum NotchLayout {
    static let collapsedLip: CGFloat = 10
    static let collapsedWing: CGFloat = 48
    static let expandedWidth: CGFloat = 440
    static let expandedHeight: CGFloat = 196
}

struct NotchPanelView: View {
    @ObservedObject var model: NowPlayingModel

    var body: some View {
        let notchHeight = model.notchSize.height
        let corner = model.isExpanded ? 20.0 : 12.0

        ZStack(alignment: .top) {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: corner,
                bottomTrailingRadius: corner,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color.black)

            collapsedContent(notchHeight: notchHeight)
                .opacity(model.isExpanded || !model.hasTrack ? 0 : 1)
                .allowsHitTesting(model.hasTrack && !model.isExpanded)

            expandedContent(notchHeight: notchHeight)
                .opacity(model.isExpanded ? 1 : 0)
                .allowsHitTesting(model.isExpanded)
        }
        .contentShape(Rectangle())
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.28), value: model.isExpanded)
        .animation(.easeInOut(duration: 0.28), value: model.hasTrack)
    }

    private func collapsedContent(notchHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                artworkView(corner: 6)
                    .frame(width: 24, height: 24)
                    .frame(width: NotchLayout.collapsedWing, height: notchHeight)

                Spacer(minLength: 0)

                Button(action: model.playPause) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .offset(x: model.isPlaying ? 0 : 0.6)
                }
                .buttonStyle(.plain)
                .frame(width: NotchLayout.collapsedWing, height: notchHeight)
            }
            Color.clear.frame(height: NotchLayout.collapsedLip)
        }
    }

    private func expandedContent(notchHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    artworkView(corner: 10)
                        .frame(width: 56, height: 56)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.hasTrack ? model.title : "Not playing")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(model.hasTrack ? model.artist : "Play a song in Spotify or Music")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }

                progressBar

                HStack(spacing: 28) {
                    controlButton("backward.end.fill", action: model.previousTrack)
                    controlButton(
                        model.isPlaying ? "pause.fill" : "play.fill",
                        size: 18,
                        action: model.playPause
                    )
                    controlButton("forward.end.fill", action: model.nextTrack)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(4, geo.size.width * model.progress))
            }
        }
        .frame(height: 4)
    }

    private func artworkView(corner: CGFloat) -> some View {
        Group {
            if let artwork = model.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                    Image(systemName: "music.note")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    private func controlButton(_ systemName: String, size: CGFloat = 14, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(!model.hasTrack)
        .opacity(model.hasTrack ? 1 : 0.35)
    }
}

#Preview {
    let model = NowPlayingModel()
    model.hasTrack = true
    model.isExpanded = true
    model.title = "Sunsetz"
    model.artist = "Cigarettes After Sex"
    model.isPlaying = true
    model.duration = 240
    model.position = 80
    return NotchPanelView(model: model)
        .frame(width: 440, height: 196)
}
