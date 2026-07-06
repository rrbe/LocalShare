import AppKit
import Foundation
import UniformTypeIdentifiers

final class ShareController: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let providers = context.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }

        guard !providers.isEmpty else {
            NSLog("LocalShare share extension received no item providers")
            context.completeRequest(returningItems: nil)
            return
        }

        loadFileURLs(from: providers) { urls in
            guard !urls.isEmpty else {
                NSLog("LocalShare share extension received no file URLs")
                context.completeRequest(returningItems: nil)
                return
            }
            guard let appURL = Self.hostAppURL() else {
                NSLog("LocalShare share extension could not locate host app")
                context.completeRequest(returningItems: nil)
                return
            }

            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config) { _, error in
                if let error {
                    NSLog("LocalShare share extension launch failed: \(error.localizedDescription)")
                }
                context.completeRequest(returningItems: nil)
            }
        }
    }

    private func loadFileURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            guard let typeIdentifier = Self.supportedTypeIdentifier(for: provider) else {
                let types = provider.registeredTypeIdentifiers.joined(separator: ", ")
                NSLog("LocalShare share extension unsupported provider types: \(types)")
                continue
            }
            group.enter()
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                defer { group.leave() }
                if let error {
                    NSLog("LocalShare share extension item load failed: \(error.localizedDescription)")
                    return
                }
                guard let url = Self.fileURL(from: item) else { return }
                lock.lock()
                urls.append(url.standardizedFileURL)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            completion(urls)
        }
    }

    private static func supportedTypeIdentifier(for provider: NSItemProvider) -> String? {
        let identifiers = [
            UTType.fileURL.identifier,
            UTType.url.identifier
        ]
        return identifiers.first { provider.hasItemConformingToTypeIdentifier($0) }
    }

    private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL, url.isFileURL { return url }
        if let url = item as? NSURL, url.isFileURL { return url as URL }
        if let data = item as? Data {
            let url = URL(dataRepresentation: data, relativeTo: nil)
            if url?.isFileURL == true { return url }
        }
        if let string = item as? String, let url = URL(string: string), url.isFileURL {
            return url
        }
        return nil
    }

    private static func hostAppURL() -> URL? {
        var url = Bundle.main.bundleURL
        while url.pathExtension != "app" && url.path != "/" {
            url.deleteLastPathComponent()
        }
        if url.pathExtension == "app" { return url }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "live.ezze.localshare")
    }
}
