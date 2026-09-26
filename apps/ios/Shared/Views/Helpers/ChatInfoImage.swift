//
//  ChatInfoImage.swift
//  SimpleX
//
//  Created by Evgeny Poberezkin on 05/02/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import SwiftUI
import SimpleXChat

struct ChatInfoImage: View {
    @EnvironmentObject var theme: AppTheme
    @ObservedObject var chat: Chat
    var size: CGFloat
    var color = Color(uiColor: .tertiarySystemGroupedBackground)
    var radiusOverride: Double? = nil

    var body: some View {
        let iconColor = if case .local = chat.chatInfo {
            theme.colors.isLight
                ? Color(red: 23 / 255, green: 19 / 255, blue: 14 / 255)
                : Color(red: 222 / 255, green: 206 / 255, blue: 175 / 255)
        } else {
            color
        }
        return ProfileImage(
            imageStr: chat.chatInfo.image,
            iconName: chatIconName(chat.chatInfo),
            size: size,
            color: iconColor,
            radiusOverride: radiusOverride
        )
    }
}

struct ChatInfoImage_Previews: PreviewProvider {
    static var previews: some View {
        ChatInfoImage(
            chat: Chat(chatInfo: ChatInfo.sampleData.direct, chatItems: []),
            size: 63,
            color:  Color(red: 0.9, green: 0.9, blue: 0.9)
        )
        .previewLayout(.fixed(width: 63, height: 63))
    }
}
