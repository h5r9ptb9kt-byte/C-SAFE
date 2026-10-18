//
//  BackgroundCopy.swift — C-SAFE (iPhone / iPad)
//  La copie ne doit jamais s'arrêter : changement d'app, appel, écran verrouillé.
//  - iOS 26 et plus : « tâche longue » Apple (BGContinuedProcessingTask), avec la
//    progression affichée par le système ; elle continue en arrière-plan.
//  - Toujours : l'écran ne se met pas en veille pendant la copie, et un délai
//    d'arrière-plan classique est demandé en plus.
//

#if os(iOS)
import UIKit
import BackgroundTasks

@MainActor
final class BackgroundCopy {
    static let shared = BackgroundCopy()

    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var continued: AnyObject?          // BGContinuedProcessingTask (iOS 26)
    private var timer: Timer?
    private var progress: (() -> (Double, String))?
    private var onExpire: (() -> Void)?
    private(set) var active = false

    /// À appeler au clic sur « Démarrer la copie » (l'app est au premier plan).
    /// Renvoie une phrase pour le journal.
    func begin(title: String, progress: @escaping () -> (Double, String), onExpire: @escaping () -> Void) -> String {
        guard !active else { return "" }
        active = true
        self.progress = progress
        self.onExpire = onExpire
        UIApplication.shared.isIdleTimerDisabled = true
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "Copie C-SAFE") { [weak self] in
            MainActor.assumeIsolated { self?.endClassicTask() }
        }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if let err = submitContinued(title: title) { return "Arrière-plan : " + err }
            return "La copie continue même si tu changes d'app ou si tu reçois un appel."
        }
        #endif
        return "iOS ancien : garde C-SAFE à l'écran pendant la copie."
    }

    func end(success: Bool) {
        guard active else { return }
        active = false
        timer?.invalidate(); timer = nil
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
        }
        #endif
        continued = nil
        progress = nil
        onExpire = nil
        UIApplication.shared.isIdleTimerDisabled = false
        endClassicTask()
    }

    private func endClassicTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private func submitContinued(title: String) -> String? {
        let patterns = (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]) ?? []
        guard let pattern = patterns.first(where: { $0.hasSuffix(".*") }) else { return "identifiant absent" }
        // Un identifiant unique par lancement, enregistré juste avant l'envoi (recommandation Apple)
        let id = String(pattern.dropLast()) + UUID().uuidString.prefix(8)
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let task = task as? BGContinuedProcessingTask, self.active else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.attach(task)
            }
        }
        guard registered else { return "enregistrement refusé" }
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: title, subtitle: "Copie et vérification…")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return nil
        } catch {
            return "refusé par iOS (\(error.localizedDescription))"
        }
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        continued = task
        task.progress.totalUnitCount = 1000
        task.expirationHandler = { [weak self] in
            // Annulation par l'utilisateur (Live Activity) ou par le système
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.onExpire?()
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.progress?() else { return }
                task.progress.completedUnitCount = Int64(max(0, min(1, p.0)) * 999)
                task.updateTitle(task.title, subtitle: p.1)
            }
        }
    }
    #endif
}
#endif
