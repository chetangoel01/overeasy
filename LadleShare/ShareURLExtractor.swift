import Foundation
import UniformTypeIdentifiers

@MainActor
struct ShareURLExtractor {
    func firstSupportedURL(
        in extensionItems: [NSExtensionItem]
    ) async -> URL? {
        for extensionItem in extensionItems {
            if let text = extensionItem.attributedContentText?.string,
               let url = firstSupportedURL(in: text) {
                return url
            }

            for provider in extensionItem.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(
                    UTType.url.identifier
                ),
                   let item = await loadItem(
                       from: provider,
                       typeIdentifier: UTType.url.identifier
                   ),
                   let url = supportedURL(from: item.value) {
                    return url
                }

                if provider.hasItemConformingToTypeIdentifier(
                    UTType.plainText.identifier
                ),
                   let item = await loadItem(
                       from: provider,
                       typeIdentifier: UTType.plainText.identifier
                   ),
                   let text = string(from: item.value),
                   let url = firstSupportedURL(in: text) {
                    return url
                }
            }
        }

        return nil
    }

    private func loadItem(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async -> LoadedShareItem? {
        await withCheckedContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: typeIdentifier,
                options: nil
            ) { item, error in
                continuation.resume(
                    returning:
                        error == nil
                            ? LoadedShareItem(value: item)
                            : nil
                )
            }
        }
    }

    private func supportedURL(
        from item: (any NSSecureCoding)?
    ) -> URL? {
        if let url = item as? URL {
            return validated(url)
        }
        if let url = item as? NSURL {
            return validated(url as URL)
        }
        if let data = item as? Data,
           let url = URL(
               dataRepresentation: data,
               relativeTo: nil
           ),
           let supported = validated(url) {
            return supported
        }
        if let data = item as? Data,
           let propertyList =
               try? PropertyListSerialization.propertyList(
                   from: data,
                   options: [],
                   format: nil
               ),
           let supported = supportedURL(
               fromPropertyList: propertyList
           ) {
            return supported
        }
        if let text = string(from: item) {
            return firstSupportedURL(in: text)
        }
        return nil
    }

    private func string(
        from item: (any NSSecureCoding)?
    ) -> String? {
        if let string = item as? String {
            return string
        }
        if let string = item as? NSString {
            return string as String
        }
        if let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    private func supportedURL(
        fromPropertyList value: Any
    ) -> URL? {
        if let url = value as? URL {
            return validated(url)
        }
        if let url = value as? NSURL {
            return validated(url as URL)
        }
        if let string = value as? String {
            if let direct = URL(string: string),
               let supported = validated(direct) {
                return supported
            }
            return firstSupportedURL(in: string)
        }
        if let values = value as? [Any] {
            return values.lazy.compactMap {
                supportedURL(fromPropertyList: $0)
            }
            .first
        }
        if let dictionary = value as? [AnyHashable: Any] {
            return dictionary.values.lazy.compactMap {
                supportedURL(fromPropertyList: $0)
            }
            .first
        }
        return nil
    }

    private func firstSupportedURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        var match: URL?
        detector.enumerateMatches(
            in: text,
            options: [],
            range: range
        ) { result, _, stop in
            guard let candidate = result?.url,
                  let supported = validated(candidate) else {
                return
            }
            match = supported
            stop.pointee = true
        }
        return match
    }

    private func validated(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return nil
        }
        return url
    }
}

private struct LoadedShareItem: @unchecked Sendable {
    let value: (any NSSecureCoding)?
}
