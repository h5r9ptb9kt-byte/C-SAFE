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
        }
        #if os(macOS)
        .windowResizability(.contentSize)   // la fenêtre s'ouvre pile à la taille du contenu
        #endif
    }
}
