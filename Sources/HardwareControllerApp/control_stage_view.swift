import HardwareControllerCore
import HardwareControllerMac
import SwiftUI

struct ControlStageView: View {
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  let model: AppModel
  let device: ConnectedDeviceSnapshot?
  let descriptor: DeviceModelDescriptor

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text((device?.name ?? descriptor.name).uppercased())
            .font(
              .system(
                .caption,
                design: .rounded,
                weight: .bold
              )
            )
            .tracking(1.1)
          Text(
            device != nil
              ? "Use a control to see its live state."
              : "Connect the USB controller. Your mappings are ready."
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
        }

        Spacer()

        if let latency = model.latencyText {
          Label(latency, systemImage: "bolt.fill")
            .font(
              .system(
                .caption2,
                design: .default,
                weight: .semibold
              )
            )
            .foregroundStyle(StudioDesign.accent)
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 16)

      ZStack(alignment: .bottom) {
        RoundedRectangle(cornerRadius: 32, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                Color.black.opacity(0.88),
                Color.black.opacity(0.72),
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .frame(height: 170)
          .overlay(alignment: .top) {
            Capsule()
              .fill(Color.white.opacity(0.06))
              .frame(height: 1)
              .padding(.horizontal, 34)
              .padding(.top, 16)
          }

        HStack(alignment: .bottom, spacing: 11) {
          ForEach(descriptor.controls, id: \.id) { control in
            controlView(control)
          }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
      }
      .padding(.horizontal, 18)
      .padding(.top, 8)
      .padding(.bottom, 18)
    }
    .studioCard(highlighted: device?.activeControls.isEmpty == false)
  }

  private func controlView(
    _ control: ControlDescriptor
  ) -> some View {
    let controlID = control.id
    let pressed =
      device?.pressedControls.contains(controlID)
      == true
    let active =
      device?.activeControls.contains(controlID)
      == true
    let binding = model.binding(
      for: controlID,
      matching:
        device?.matchRule
        ?? DeviceMatchRule(modelID: descriptor.modelID)
    )
    let blocked =
      pressed && binding.action.kind != .noAction
      && !model.canExecute(binding.action.kind)

    return ControlTileView(
      title: control.name,
      actionTitle: binding.action.kind.displayTitle,
      systemImage: binding.action.kind.systemImage,
      pressed: pressed,
      active: active,
      blocked: blocked,
      connected: device != nil,
      width: control.visualWeight == .prominent ? 246 : 154,
      height: control.visualWeight == .prominent ? 138 : 118
    )
    .offset(y: pressed ? 8 : 0)
    .scaleEffect(pressed ? 0.965 : 1)
    .animation(
      reduceMotion
        ? nil
        : .spring(response: 0.16, dampingFraction: 0.78),
      value: pressed
    )
    .onLongPressGesture(
      minimumDuration: .infinity,
      maximumDistance: .infinity,
      pressing: { isPressing in
        model.simulate(
          controlID,
          phase: isPressing ? .pressed : .released
        )
      },
      perform: {}
    )
  }
}

private struct ControlTileView: View {
  let title: String
  let actionTitle: String
  let systemImage: String
  let pressed: Bool
  let active: Bool
  let blocked: Bool
  let connected: Bool
  let width: CGFloat
  let height: CGFloat

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 23, style: .continuous)
        .fill(
          LinearGradient(
            colors: pressed
              ? [
                (blocked
                  ? StudioDesign.warning
                  : StudioDesign.activeBlue).opacity(0.50),
                Color(white: 0.10),
              ]
              : [
                Color(white: 0.20),
                Color(white: 0.08),
              ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .overlay {
          RoundedRectangle(cornerRadius: 23, style: .continuous)
            .strokeBorder(
              active
                ? StudioDesign.accent.opacity(0.82)
                : blocked
                  ? StudioDesign.warning.opacity(0.95)
                  : pressed
                    ? StudioDesign.activeBlue.opacity(0.95)
                    : Color.white.opacity(0.10),
              lineWidth: active ? 1.5 : pressed ? 2.5 : 1
            )
        }

      VStack(spacing: 8) {
        ZStack {
          Circle()
            .fill(
              active
                ? StudioDesign.accent.opacity(0.18)
                : blocked
                  ? StudioDesign.warning.opacity(0.26)
                  : pressed
                    ? StudioDesign.activeBlue.opacity(0.26)
                    : Color.white.opacity(0.06)
            )
          Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(
              active
                ? StudioDesign.accent
                : blocked
                  ? StudioDesign.warning
                  : pressed
                    ? StudioDesign.activeBlue
                    : Color.white.opacity(connected ? 0.92 : 0.42)
            )
        }
        .frame(width: 35, height: 35)

        VStack(spacing: 2) {
          Text(title.uppercased())
            .font(
              .system(
                .caption2,
                design: .rounded,
                weight: .bold
              )
            )
            .tracking(1.2)
          Text(
            pressed
              ? blocked ? "PRESSED · BLOCKED" : "PRESSED"
              : actionTitle
          )
          .font(
            .system(
              .caption,
              design: .default,
              weight: pressed ? .bold : .medium
            )
          )
          .foregroundStyle(
            pressed
              ? blocked
                ? StudioDesign.warning
                : StudioDesign.activeBlue
              : Color.white.opacity(0.56)
          )
          .lineLimit(2)
        }
        .foregroundStyle(Color.white.opacity(0.90))
      }
    }
    .frame(width: width, height: height)
    .shadow(
      color: active
        ? StudioDesign.accent.opacity(0.28)
        : blocked
          ? StudioDesign.warning.opacity(0.34)
          : pressed
            ? StudioDesign.activeBlue.opacity(0.34)
            : Color.black.opacity(0.34),
      radius: active ? 15 : pressed ? 12 : 8,
      y: active ? 6 : 5
    )
    .opacity(connected ? 1 : 0.62)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title) control")
    .accessibilityValue(
      active
        ? "\(actionTitle), active"
        : blocked
          ? "\(actionTitle), pressed, blocked"
          : pressed
            ? "\(actionTitle), pressed"
            : actionTitle
    )
  }
}
