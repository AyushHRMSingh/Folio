// Sends one debug command to a Folio started with FOLIO_DEBUG=<token>.   usage: debug-send <token> "<command>"
import Foundation
DistributedNotificationCenter.default().postNotificationName(.init("local.folio.debug.\(CommandLine.arguments[1])"), object: CommandLine.arguments[2], userInfo: nil, deliverImmediately: true)
