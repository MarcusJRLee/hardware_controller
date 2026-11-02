import SwiftUI
import UIKit

/// Dictate is the workflow; History and Settings stay one tap away.
struct VoiceInputRootView: View {
  @ObservedObject var model: VoiceInputAppModel
  @ObservedObject var modelLibrary: VoiceInputModelLibraryModel
  @ObservedObject var history: VoiceInputHistoryModel
  @ObservedObject var historyAudioPlayer: VoiceInputHistoryAudioPlayerModel
  @Environment(\.openURL) private var openURL

  var body: some View {
    TabView {
      Tab("Dictate", systemImage: "mic") {
        VoiceInputDictateView(
          model: model,
          modelLibrary: modelLibrary,
          openSettings: openSettings
        )
      }
      Tab("History", systemImage: "clock") {
        VoiceInputHistoryView(model: history, audioPlayer: historyAudioPlayer)
      }
      Tab("Settings", systemImage: "gearshape") {
        VoiceInputSettingsView(
          model: model,
          modelLibrary: modelLibrary,
          history: history,
          openSettings: openSettings
        )
      }
    }
    .task {
      await modelLibrary.refresh()
      await history.refresh()
    }
    .task(id: model.snapshot.sequence) {
      if model.snapshot.phase == .ready {
        await history.refresh()
      }
    }
  }

  private func openSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      return
    }
    openURL(url)
  }
}
