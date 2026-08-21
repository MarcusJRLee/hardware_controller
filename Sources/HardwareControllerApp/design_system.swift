import SwiftUI

private struct DemoIncreasedContrastKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// Allows deterministic increased-contrast screenshot verification.
  var demoIncreasedContrast: Bool {
    get { self[DemoIncreasedContrastKey.self] }
    set { self[DemoIncreasedContrastKey.self] = newValue }
  }
}

enum StudioDesign {
  static let accent = Color(
    red: 0.18,
    green: 0.82,
    blue: 0.67
  )
  static let activeBlue = Color(
    red: 0.25,
    green: 0.66,
    blue: 0.98
  )
  static let warning = Color(
    red: 0.98,
    green: 0.64,
    blue: 0.24
  )
  static let cornerRadius: CGFloat = 20
  static let compactCornerRadius: CGFloat = 13
}

struct StudioCard: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.demoIncreasedContrast) private var demoIncreasedContrast
  var highlighted = false

  private var usesIncreasedContrast: Bool {
    colorSchemeContrast == .increased || demoIncreasedContrast
  }

  func body(content: Content) -> some View {
    content
      .background {
        RoundedRectangle(
          cornerRadius: StudioDesign.cornerRadius,
          style: .continuous
        )
        .fill(.regularMaterial)
        .overlay {
          RoundedRectangle(
            cornerRadius: StudioDesign.cornerRadius,
            style: .continuous
          )
          .strokeBorder(
            highlighted
              ? StudioDesign.accent.opacity(
                usesIncreasedContrast ? 0.82 : 0.42
              )
              : Color.primary.opacity(
                usesIncreasedContrast
                  ? 0.38
                  : colorScheme == .dark ? 0.12 : 0.08
              ),
            lineWidth:
              usesIncreasedContrast
              ? 2
              : highlighted ? 1.25 : 1
          )
        }
        .shadow(
          color: Color.black.opacity(
            colorScheme == .dark ? 0.22 : 0.08
          ),
          radius: 20,
          y: 8
        )
      }
  }
}

extension View {
  func studioCard(highlighted: Bool = false) -> some View {
    modifier(StudioCard(highlighted: highlighted))
  }
}

struct StatusPill: View {
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.demoIncreasedContrast) private var demoIncreasedContrast

  let title: String
  let systemImage: String
  let color: Color

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(
        .system(
          .caption,
          design: .default,
          weight: .semibold
        )
      )
      .foregroundStyle(color)
      .padding(.horizontal, 11)
      .padding(.vertical, 6)
      .background(
        color.opacity(usesIncreasedContrast ? 0.24 : 0.12),
        in: Capsule()
      )
      .overlay {
        Capsule()
          .strokeBorder(
            color.opacity(usesIncreasedContrast ? 0.75 : 0.22),
            lineWidth: usesIncreasedContrast ? 2 : 1
          )
      }
  }

  private var usesIncreasedContrast: Bool {
    colorSchemeContrast == .increased || demoIncreasedContrast
  }
}
