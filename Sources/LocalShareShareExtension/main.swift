import Darwin
import Foundation

@_silgen_name("NSExtensionMain")
private func foundationNSExtensionMain(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

exit(foundationNSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv))
