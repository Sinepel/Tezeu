import AppKit

/// Copie complète du presse-papiers (tous les éléments, tous les formats), pour le remettre après le collage.
public struct ClipboardSnapshot: Sendable {
    let items: [[(type: String, data: Data)]]
}

public enum Clipboard {
    public static func snapshot(of pasteboard: NSPasteboard) -> ClipboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type: type.rawValue, data: $0) } }
        }
        return ClipboardSnapshot(items: items)
    }

    public static func restore(_ snapshot: ClipboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = snapshot.items.map { formats in
            let item = NSPasteboardItem()
            for format in formats {
                item.setData(format.data, forType: NSPasteboard.PasteboardType(format.type))
            }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    /// Remplace le contenu par un texte. Rend le `changeCount` qui identifie ce contenu.
    @discardableResult
    public static func setText(_ text: String, on pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }
}
