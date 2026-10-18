//
//  CSafeApp.swift — C-SAFE
//  Déchargement sécurisé de cartes caméra · par C-FOCUS (Etienne Chopin)
//  Une seule application pour Mac, iPad et iPhone.
//

import SwiftUI

@main
struct CSafeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                #if os(macOS)
                .frame(minWidth: 560, minHeight: 640)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 820, height: 940)
        #endif
    }
}
