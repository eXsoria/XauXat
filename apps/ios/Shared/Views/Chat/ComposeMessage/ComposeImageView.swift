//
//  ComposeImageView.swift
//  SimpleX
//
//  Created by JRoberts on 11/04/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import SwiftUI
import SimpleXChat

struct ComposeImageView: View {
    @EnvironmentObject var theme: AppTheme
    let images: [String]
    let showsOneTimePhotoControls: Bool
    @Binding var oneTimeView: Bool
    @Binding var allowSave: Bool
    let cancelImage: (() -> Void)
    let cancelEnabled: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                let imgs: [UIImage] = images.compactMap { image in
                    imageFromBase64(image)
                }
                if imgs.count == 0 {
                    ProgressView()
                        .padding(.leading, 12)
                        .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60, alignment: .leading)
                } else {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(imgs, id: \.hash) { img in
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 80, minHeight: 40, maxHeight: 60)
                            }
                        }
                    }
                }
                Spacer()
                if cancelEnabled {
                    Button { cancelImage() } label: {
                        Image(systemName: "multiply")
                    }
                }
            }
            .padding(.vertical, 1)
            .padding(.trailing, 12)

            if showsOneTimePhotoControls {
                VStack(spacing: 8) {
                    Toggle(isOn: $oneTimeView) {
                        Label("One-Time View", systemImage: oneTimeView ? "eye" : "photo")
                            .font(.subheadline.weight(.medium))
                    }
                    .onChange(of: oneTimeView) { enabled in
                        if !enabled { allowSave = false }
                    }

                    if oneTimeView {
                        Toggle("Allow Save", isOn: $allowSave)
                            .font(.subheadline)
                    }
                }
                .foregroundColor(theme.colors.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(theme.appColors.sentMessage)
        .frame(minHeight: 54)
        .frame(maxWidth: .infinity)
    }
}

//struct ComposeImageView: View {
//    @Environment(\.colorScheme) var colorScheme
//    let image: String
//    let cancelImage: (() -> Void)
//
//    var body: some View {
//        if let data = Data(base64Encoded: dropImagePrefix(image)),
//           let uiImage = UIImage(data: data) {
//            HStack(alignment: .center) {
//                ZStack(alignment: .topTrailing) {
//                    Image(uiImage: uiImage)
//                        .resizable()
//                        .scaledToFit()
//                        .cornerRadius(20)
//                        .frame(maxHeight: 150)
//                    Button { cancelImage() } label: {
//                        Image(systemName: "multiply")
//                            .foregroundColor(.white)
//                    }
//                    .padding(8)
//                }
//            }
//            .padding(.top, 8)
//        }
//    }
//}
