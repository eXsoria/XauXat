//
//  FullScreenImageView.swift
//  SimpleX (iOS)
//
//  Created by Evgeny on 08/10/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//
// Spec: spec/client/chat-view.md

import SwiftUI
import SimpleXChat
import SwiftyGif
import AVKit

// Spec: spec/client/chat-view.md#FullScreenMediaView
struct FullScreenMediaView: View {
    @EnvironmentObject var m: ChatModel
    @Environment(\.scenePhase) private var scenePhase
    @State var chatItem: ChatItem
    var scrollToItem: ((ChatItem.ID) -> Void)?
    @State var image: UIImage?
    @State var player: AVPlayer? = nil
    @State var url: URL? = nil
    @Binding var showView: Bool
    var restrictToCurrentItem = false
    var allowSave = false
    var onPresented: (() -> Void)? = nil
    @State private var saved = false
    @State private var showNext = false
    @State private var nextImage: UIImage?
    @State private var nextPlayer: AVPlayer?
    @State private var nextURL: URL?
    @State private var scrolling = false
    @State private var offset: CGFloat = 0
    @State private var nextOffset: CGFloat = 0
    @State private var screenCaptured = UIScreen.main.isCaptured

    var body: some View {
        GeometryReader(content: mediaScrollView)
    }

    func mediaScrollView(_ g: GeometryProxy) -> some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            if showNext, let nextImage = nextImage {
                if let image = image {
                    imageView(image).offset(x: offset)
                } else if let player = player, let url = url {
                    videoView(player, url).offset(x: offset)
                }
                imageView(nextImage).offset(x: offset + nextOffset)
            } else if showNext, let nextPlayer = nextPlayer, let nextURL = nextURL {
                if let image = image {
                    imageView(image).offset(x: offset)
                } else if let player = player, let url = url {
                    videoView(player, url).offset(x: offset)
                }
                videoView(nextPlayer, nextURL).offset(x: offset + nextOffset)
            } else {
                ZoomableScrollView {
                    if let image = image {
                        imageView(image)
                    } else if let player = player, let url = url {
                        videoView(player, url)
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if allowSave, let image {
                Button {
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                    saved = true
                } label: {
                    Label(saved ? "Saved" : "Save", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.white)
                }
                .disabled(saved)
                .padding(.top, 18)
                .padding(.trailing, 18)
            }
        }
        .overlay {
            if restrictToCurrentItem && (screenCaptured || scenePhase != .active) {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 10) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 30, weight: .medium))
                        Text("Protected content")
                            .font(.headline)
                        Text("Screen capture is not available for this photo.")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.72))
                    }
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(28)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .onAppear {
            screenCaptured = UIScreen.main.isCaptured
            onPresented?()
            startPlayerAndNotify()
        }
        .onDisappear {
            player?.pause()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            screenCaptured = UIScreen.main.isCaptured
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            if restrictToCurrentItem {
                image = nil
                showView = false
            }
        }
        .gesture(
            DragGesture(minimumDistance: 80)
            .onChanged { gesture in
                let t = gesture.translation
                let w = abs(t.width)
                if t.height > 60 && t.height > w * 2  {
                    showView = false
                    scrollToItem?(chatItem.id)
                } else if !restrictToCurrentItem && w > 60 && w > abs(t.height) * 2 && !scrolling {
                    let previous = t.width > 0
                    scrolling = true
                    if let item = m.nextChatItemData(chatItem.id, previous: previous, map: chatItemImage) {
                        var img: UIImage?
                        var url: URL?
                        (chatItem, img, url) = item
                        nextImage = img
                        nextPlayer?.pause()
                        if let url = url {
                            nextPlayer = VideoPlayerView.getOrCreatePlayer(url, true)
                        } else {
                            nextPlayer = nil
                        }
                        nextURL = url
                        let s = g.size.width
                        var toOffset: CGFloat
                        (toOffset, nextOffset) = previous ? (s, -s) : (-s, s)
                        showNext = true
                        withAnimation(.easeIn(duration: 0.2)) {
                            offset = toOffset
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            image = img
                            player?.pause()
                            self.url = url
                            if let url = url {
                                player = VideoPlayerView.getOrCreatePlayer(url, true)
                                startPlayerAndNotify()
                            } else {
                                player = nil
                            }
                            showNext = false
                            offset = 0
                        }
                    }
                }
            }
            .onEnded { _ in scrolling = false }
        )
    }

    private func imageView(_ img: UIImage) -> some View {
        ZStack {
            Color.black
            if img.imageData == nil {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
            } else {
                SwiftyGif(image: img)
                        .scaledToFit()
            }
        }
        .onTapGesture { showView = false } // this is used in full screen view, onTapGesture works
    }

    private func videoView( _ player: AVPlayer, _ url: URL) -> some View {
        VideoPlayerView(player: player, url: url, showControls: true)
    }

    private func chatItemImage(_ ci: ChatItem) -> (ChatItem, UIImage?, URL?)? {
        if case .image = ci.content.msgContent,
           let img = getLoadedImage(ci.file) {
            return (ci, img, nil)
        }
        // Currently, video support in gallery is not enabled
         /*else if case .video = ci.content.msgContent,
           let url = getLoadedVideo(ci.file) {
            return (ci, nil, url)
        }*/
        return nil
    }

    private func startPlayerAndNotify() {
        if let player = player {
            m.stopPreviousRecPlay = url
            player.play()
        }
    }
}
