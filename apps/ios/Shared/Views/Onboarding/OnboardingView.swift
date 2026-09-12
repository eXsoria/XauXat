//
//  OnboardingStepsView.swift
//  SimpleX (iOS)
//
//  Created by Evgeny on 07/05/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//
// Spec: spec/client/navigation.md

import SwiftUI

// Spec: spec/client/navigation.md#OnboardingView
struct OnboardingView: View {
    var onboarding: OnboardingStage

    var body: some View {
        NavigationView {
            switch onboarding {
            case .step1_SimpleXInfo,
                 .step2_CreateProfile,
                 .step3_CreateSimpleXAddress,
                 .step3_ChooseServerOperators,
                 .step4_SetNotificationsMode,
                 .step4_NetworkCommitments:
                XauXatWelcomeView()
            case .onboardingComplete: EmptyView()
            }
        }
    }
}

func onboardingButtonPlaceholder() -> some View {
    Spacer().frame(height: 40)
}

// Spec: spec/client/navigation.md#onboardingStage
enum OnboardingStage: String, Identifiable {
    case step1_SimpleXInfo
    case step2_CreateProfile
    case step3_CreateSimpleXAddress // deprecated
    case step3_ChooseServerOperators
    case step4_SetNotificationsMode // deprecated
    case step4_NetworkCommitments
    case onboardingComplete

    public var id: Self { self }
}

struct OnboardingStepsView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView(onboarding: .step1_SimpleXInfo)
    }
}
