import Foundation
import HardwareControllerASRServiceKit

// launchd starts this process on the app's first message and may stop it when
// idle; a crash here never reaches the app or the Device hot path.
let delegate = ASRServiceListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
