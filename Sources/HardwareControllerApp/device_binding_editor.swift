import Foundation
import HardwareControllerCore
import SwiftUI

/// Renders one Driver-described Device setup through shared Control editors.
struct DeviceBindingEditor: View {
  let model: AppModel
  let descriptor: DeviceModelDescriptor
  var profileID: UUID?
  var configurationID: UUID?

  var body: some View {
    LazyVGrid(columns: columns, spacing: 14) {
      ForEach(
        Array(descriptor.controls.enumerated()),
        id: \.element.id
      ) { index, control in
        ControlEditorView(
          model: model,
          control: control,
          position: String(format: "%02d", index + 1),
          highlighted: control.visualWeight == .prominent,
          profileID: profileID,
          configurationID: configurationID
        )
      }
    }
  }

  private var columns: [GridItem] {
    Array(
      repeating: GridItem(.flexible(), spacing: 14),
      count: max(1, min(3, descriptor.controls.count))
    )
  }
}
