//
//  VersionView.swift
//  SimpleXChat
//
//  Created by Evgeny on 22/01/2023.
//  Copyright © 2023 SimpleX Chat. All rights reserved.
//

import SwiftUI
import SimpleXChat

struct VersionView: View {
    @EnvironmentObject var theme: AppTheme
    @State var versionInfo: CoreVersionInfo?

    var body: some View {
        List {
            Section {
                Text("App version: v\(appVersion ?? "?")")
                Text("App build: \(appBuild ?? "?")")
                if let info = versionInfo {
                    Text("Messaging core: v\(info.version)")
                }
            }

            Section("Open source") {
                ExternalLink("Source code and licences", destination: URL(string: "https://github.com/eXsoria/XauXat")!)
            }

            Section {
                NavigationLink {
                    DeveloperView()
                        .navigationTitle("Developer")
                        .modifier(ThemedBackground(grouped: true))
                } label: {
                    Text("Developer")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            do {
                versionInfo = try apiGetVersion()
            } catch let error {
                logger.error("apiGetVersion error: \(responseError(error))")
            }
        }
    }
}

struct VersionView_Previews: PreviewProvider {
    static var previews: some View {
        VersionView()
    }
}
