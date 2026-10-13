//
//  UserProfile.swift
//  SimpleX
//
//  Created by Evgeny Poberezkin on 31/01/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import SwiftUI
import SimpleXChat

struct UserProfile: View {
    @Environment(\.colorScheme) private var colorScheme

    var onSaved: () -> Void = {}
    @EnvironmentObject var chatModel: ChatModel
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var ss: SaveableSettings
    @AppStorage(DEFAULT_PROFILE_IMAGE_CORNER_RADIUS) private var radius = defaultProfileImageCorner
    @State private var profile = Profile(displayName: "", fullName: "")
    @State private var currentProfileHash: Int?
    @State private var loaded = false
    @State private var shortDescr = ""
    @State private var description = ""
    // Modals
    @State private var showChooseSource = false
    @State private var showImagePicker = false
    @State private var showTakePhoto = false
    @State private var chosenImage: UIImage? = nil
    @State private var imageToEdit: UIImage? = nil
    @State private var showAvatarEditor = false
    @State private var alert: UserProfileAlert?
    @FocusState private var focusDisplayName

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {

                // MARK: Profile image

                EditProfileImage(
                    profileImage: $profile.image,
                    iconName: "person.crop.circle.fill",
                    showChooseSource: $showChooseSource
                )
                .padding(.top, 18)
                .padding(.bottom, 34)

                // MARK: Profile fields

                VStack(spacing: 0) {
                    HStack {
                        TextField("Enter your name…", text: $profile.displayName)
                            .focused($focusDisplayName)
                            .foregroundStyle(xauXatPrimary)

                        if !validDisplayName(profile.displayName) {
                            Button {
                                alert = .invalidNameError(
                                    validName: mkValidName(profile.displayName)
                                )
                            } label: {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .frame(minHeight: 44)
                    .padding(.horizontal, 20)

                    xauXatDivider

                    if let user = chatModel.currentUser, showFullName(user) {
                        TextField(
                            "Full name (optional)",
                            text: $profile.fullName
                        )
                        .foregroundStyle(xauXatPrimary)
                        .frame(minHeight: 44)
                        .padding(.horizontal, 20)

                        xauXatDivider
                    }

                    HStack {
                        TextField("Bio", text: $shortDescr)
                            .foregroundStyle(xauXatPrimary)

                        if !bioFitsLimit() {
                            Button {
                                showAlert(
                                    NSLocalizedString(
                                        "Bio too large",
                                        comment: "alert title"
                                    )
                                )
                            } label: {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .frame(minHeight: 44)
                    .padding(.horizontal, 20)

                    xauXatDivider

                    NavigationLink {
                        ProfileDescriptionEditor(description: $description)
                            .navigationTitle("Description")
                            .modifier(ThemedBackground(grouped: true))
                    } label: {
                        HStack {
                            Text(
                                description
                                    .trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    )
                                    .isEmpty
                                    ? "Add description"
                                    : "Edit description"
                            )
                            .foregroundStyle(xauXatPrimary)

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(
                                    xauXatSecondary.opacity(0.45)
                                )
                        }
                        .frame(minHeight: 44)
                        .padding(.horizontal, 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(
                    xauXatSurface,
                    in: RoundedRectangle(
                        cornerRadius: 12,
                        style: .continuous
                    )
                )
                .padding(.horizontal, 20)

                Text(
                    "Your profile is stored on your device and shared only with your contacts. Relay servers cannot see your profile."
                )
                .font(.footnote)
                .foregroundStyle(xauXatSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 8)

                // MARK: Actions

                VStack(spacing: 0) {
                    Button(action: getCurrentProfile) {
                        HStack {
                            Text("Reset")
                                .foregroundStyle(
                                    resetDisabled
                                        ? xauXatSecondary.opacity(0.45)
                                        : xauXatAccent
                                )

                            Spacer()
                        }
                        .frame(minHeight: 44)
                        .padding(.horizontal, 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(resetDisabled)

                    xauXatDivider

                    Button(action: saveProfile) {
                        HStack {
                            Text("Save")
                                .foregroundStyle(
                                    canSaveProfile
                                        ? xauXatAccent
                                        : xauXatSecondary.opacity(0.45)
                                )

                            Spacer()
                        }
                        .frame(minHeight: 44)
                        .padding(.horizontal, 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSaveProfile)
                }
                .background(
                    xauXatSurface,
                    in: RoundedRectangle(
                        cornerRadius: 12,
                        style: .continuous
                    )
                )
                .padding(.horizontal, 20)
                .padding(.top, 30)

                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
        }
        .background(
            xauXatBackground
                .ignoresSafeArea()
        )
        .tint(xauXatAccent)
        // Lifecycle
        .onAppear {
            // load once — returning from the description editor re-fires onAppear and would discard edits
            if !loaded {
                getCurrentProfile()
                loaded = true
            }
        }
        .onChange(of: editSnapshot) { _ in updateProfileSaver() }
        .onChange(of: chosenImage) { image in
            guard let image else { return }
            imageToEdit = image

            if showImagePicker {
                showImagePicker = false
            } else if !showTakePhoto {
                showAvatarEditor = true
            }
        }
        .onChange(of: showImagePicker) { isPresented in
            if !isPresented, imageToEdit != nil {
                showAvatarEditor = true
            }
        }
        .onChange(of: showTakePhoto) { isPresented in
            if !isPresented, imageToEdit != nil {
                showAvatarEditor = true
            }
        }
        // Modals
        .confirmationDialog(
            "Profile image",
            isPresented: $showChooseSource,
            titleVisibility: .visible
        ) {
            Button("Take picture") {
                showTakePhoto = true
            }

            Button("Choose from library") {
                showImagePicker = true
            }

            if UIPasteboard.general.hasImages {
                Button("Paste image") {
                    chosenImage = UIPasteboard.general.image
                }
            }
        }
        .fullScreenCover(isPresented: $showTakePhoto) {
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                CameraImagePicker(image: $chosenImage)
            }
        }
        .sheet(isPresented: $showImagePicker) {
            LibraryImagePicker(image: $chosenImage) { didSelectImage in
                if !didSelectImage {
                    await MainActor.run {
                        showImagePicker = false
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showAvatarEditor) {
            if let imageToEdit {
                XauXatAvatarEditor(
                    image: imageToEdit,
                    onCancel: {
                        showAvatarEditor = false
                        chosenImage = nil
                        self.imageToEdit = nil
                    },
                    onConfirm: { croppedImage in
                        showAvatarEditor = false
                        chosenImage = nil
                        self.imageToEdit = nil

                        Task {
                            let resized = await resizeImageToStrSize(
                                croppedImage,
                                maxDataSize: 12500
                            )
                            await MainActor.run {
                                profile.image = resized
                            }
                        }
                    }
                )
            }
        }
        .alert(item: $alert) { a in
            userProfileAlert(a, $profile.displayName)
        }
    }

    private var xauXatDivider: some View {
        Rectangle()
            .fill(xauXatSecondary.opacity(0.18))
            .frame(height: 0.5)
            .padding(.leading, 20)
    }

    private var xauXatBackground: Color {
        colorScheme == .dark
            ? Color(red: 29 / 255, green: 29 / 255, blue: 30 / 255)
            : Color(red: 244 / 255, green: 240 / 255, blue: 232 / 255)
    }

    private var xauXatSurface: Color {
        colorScheme == .dark
            ? Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255)
            : Color.white
    }

    private var xauXatPrimary: Color {
        colorScheme == .dark
            ? Color.white
            : Color(red: 23 / 255, green: 19 / 255, blue: 14 / 255)
    }

    private var xauXatSecondary: Color {
        colorScheme == .dark
            ? Color(red: 139 / 255, green: 135 / 255, blue: 127 / 255)
            : Color(red: 105 / 255, green: 97 / 255, blue: 88 / 255)
    }

    private var xauXatAccent: Color {
        colorScheme == .dark
            ? Color(red: 222 / 255, green: 206 / 255, blue: 175 / 255)
            : Color(red: 23 / 255, green: 19 / 255, blue: 14 / 255)
    }

    private var resetDisabled: Bool {
        currentProfileHash == profile.hashValue &&
        (profile.shortDescr ?? "") == shortDescr.trimmingCharacters(in: .whitespaces) &&
        (profile.description ?? "") == description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func showFullName(_ user: User) -> Bool {
        user.profile.fullName != "" && user.profile.fullName != user.profile.displayName
    }

    private func bioFitsLimit() -> Bool {
        chatJsonLength(shortDescr) <= MAX_BIO_LENGTH_BYTES
    }

    private var canSaveProfile: Bool {
        (
            currentProfileHash != profile.hashValue ||
            (chatModel.currentUser?.profile.shortDescr ?? "") != shortDescr.trimmingCharacters(in: .whitespaces) ||
            (chatModel.currentUser?.profile.description ?? "") != description.trimmingCharacters(in: .whitespacesAndNewlines)
        ) &&
        profile.displayName.trimmingCharacters(in: .whitespaces) != "" &&
        validDisplayName(profile.displayName) &&
        bioFitsLimit()
    }

    private func saveProfile() {
        focusDisplayName = false
        Task {
            do {
                profile.displayName = profile.displayName.trimmingCharacters(in: .whitespaces)
                profile.shortDescr = shortDescr.trimmingCharacters(in: .whitespaces)
                let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
                profile.description = d.isEmpty ? nil : d
                if let (newProfile, _) = try await apiUpdateProfile(profile: profile) {
                    await MainActor.run {
                        chatModel.updateCurrentUser(newProfile)
                        getCurrentProfile()
                        // onChange(editSnapshot) won't fire when saved values equal typed, so clear the pending dismiss-save here
                        ss.profileSave = nil
                        onSaved()
                    }
                } else {
                    alert = .duplicateUserError
                }
            } catch {
                logger.error("UserProfile apiUpdateProfile error: \(responseError(error))")
            }
        }
    }

    private func getCurrentProfile() {
        if let user = chatModel.currentUser {
            profile = fromLocalProfile(user.profile)
            currentProfileHash = profile.hashValue
            shortDescr = profile.shortDescr ?? ""
            description = profile.description ?? ""
        }
    }

    private var editSnapshot: [String] {
        [profile.displayName, profile.fullName, profile.image ?? "", shortDescr, description]
    }

    private func updateProfileSaver() {
        guard loaded, canSaveProfile else {
            ss.profileSave = nil
            return
        }
        var edited = profile
        edited.displayName = profile.displayName.trimmingCharacters(in: .whitespaces)
        edited.shortDescr = shortDescr.trimmingCharacters(in: .whitespaces)
        let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.description = d.isEmpty ? nil : d
        ss.profileSave = {
            Task {
                do {
                    if let (newProfile, _) = try await apiUpdateProfile(profile: edited) {
                        await MainActor.run { ChatModel.shared.updateCurrentUser(newProfile) }
                    }
                } catch {
                    logger.error("UserProfile save on dismiss error: \(responseError(error))")
                }
            }
        }
    }
}


struct EditProfileImage: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var theme: AppTheme
    @AppStorage(DEFAULT_PROFILE_IMAGE_CORNER_RADIUS) private var radius = defaultProfileImageCorner

    private var xauXatImageControlColor: Color {
        colorScheme == .dark
            ? Color(
                red: 222 / 255,
                green: 206 / 255,
                blue: 175 / 255
            )
            : Color(
                red: 23 / 255,
                green: 19 / 255,
                blue: 14 / 255
            )
    }
    @Binding var profileImage: String?
    var iconName: String
    @Binding var showChooseSource: Bool

    var body: some View {
        Group {
            if profileImage != nil {
                ZStack(alignment: .bottomTrailing) {
                    ZStack(alignment: .topTrailing) {
                        ProfileImage(
                            imageStr: profileImage,
                            size: 160,
                            radiusOverride: 50
                        )
                        .onTapGesture { showChooseSource = true }
                        overlayButton("multiply", edge: .top) { profileImage = nil }
                    }
                    overlayButton("camera", edge: .bottom) { showChooseSource = true }
                }
            } else {
                ZStack(alignment: .center) {
                    ProfileImage(
                        imageStr: profileImage,
                        iconName: iconName,
                        size: 160,
                        radiusOverride: 50
                    )
                    editImageButton(
                        color: xauXatImageControlColor
                    ) {
                        showChooseSource = true
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .contentShape(Rectangle())
    }

    private func overlayButton(
        _ systemName: String,
        edge: Edge.Set,
        action: @escaping () -> Void
    ) -> some View {
        Image(systemName: systemName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 12)
            .foregroundColor(xauXatImageControlColor)
            .padding(6)
            .frame(width: 36, height: 36, alignment: .center)
            .background(radius >= 20 ? Color.clear : theme.colors.background.opacity(0.5))
            .clipShape(Circle())
            .contentShape(Circle())
            .padding([.trailing, edge], -12)
            .onTapGesture(perform: action)
    }
}

func editImageButton(
    color: Color? = nil,
    action: @escaping () -> Void
) -> some View {
    Button {
        action()
    } label: {
        Image(systemName: "camera")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 48)
            .if(color != nil) { view in
                view.foregroundColor(color)
            }
    }
}

struct ProfileDescriptionEditor: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var description: String
    @FocusState private var keyboardVisible: Bool

    private var background: Color {
        colorScheme == .dark
            ? Color.black
            : Color(red: 244 / 255, green: 240 / 255, blue: 232 / 255)
    }

    private var surface: Color {
        colorScheme == .dark
            ? Color(red: 29 / 255, green: 29 / 255, blue: 30 / 255)
            : Color.white
    }

    private var primary: Color {
        colorScheme == .dark
            ? Color.white
            : Color(red: 23 / 255, green: 19 / 255, blue: 14 / 255)
    }

    private var secondary: Color {
        colorScheme == .dark
            ? Color(red: 139 / 255, green: 135 / 255, blue: 127 / 255)
            : Color(red: 105 / 255, green: 97 / 255, blue: 88 / 255)
    }

    private var accent: Color {
        colorScheme == .dark
            ? Color(red: 222 / 255, green: 206 / 255, blue: 175 / 255)
            : Color(red: 23 / 255, green: 19 / 255, blue: 14 / 255)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("DESCRIPTION")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(secondary)
                    .padding(.leading, 4)

                Group {
                    if #available(iOS 16.0, *) {
                        TextField(
                            "Enter description (optional)",
                            text: $description,
                            axis: .vertical
                        )
                        .lineLimit(6...12)
                        .focused($keyboardVisible)
                    } else {
                        ZStack(alignment: .topLeading) {
                            if description.isEmpty {
                                Text("Enter description (optional)")
                                    .foregroundStyle(secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 8)
                            }

                            TextEditor(text: $description)
                                .focused($keyboardVisible)
                                .background(Color.clear)
                                .frame(minHeight: 130)
                        }
                    }
                }
                .font(.system(size: 16))
                .foregroundStyle(primary)
                .tint(accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    surface,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
        }
        .background(background.ignoresSafeArea())
        .tint(accent)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                keyboardVisible = true
            }
        }
    }
}
