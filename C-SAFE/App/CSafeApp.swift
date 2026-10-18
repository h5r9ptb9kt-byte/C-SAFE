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
        .defaultSize(width: 430, height: 200)   // la hauteur s'agrandit d'elle-même jusqu'au contenu
        .windowResizability(.contentMinSize)    // largeur réglable à la souris, hauteur jamais plus petite que le contenu
        #endif
    }
}
