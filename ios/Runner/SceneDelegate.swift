import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate, UIPencilInteractionDelegate {
  private var stylusButtonChannel: FlutterMethodChannel?

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    installPencilInteraction()
  }

  private func installPencilInteraction() {
    guard
      let controller = window?.rootViewController as? FlutterViewController
    else {
      return
    }

    stylusButtonChannel = FlutterMethodChannel(
      name: "nanotateczki/stylus_button",
      binaryMessenger: controller.binaryMessenger
    )

    let interaction = UIPencilInteraction()
    interaction.delegate = self
    controller.view.addInteraction(interaction)
  }

  func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
    switch UIPencilInteraction.preferredTapAction {
    case .switchEraser, .switchPrevious:
      stylusButtonChannel?.invokeMethod("toggleEraser", arguments: [
        "source": "apple_pencil_tap"
      ])
    case .ignore, .showColorPalette:
      break
    @unknown default:
      break
    }
  }
}
