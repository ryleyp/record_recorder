import Foundation
import AppKit

/// A mounted removable volume (USB flash drive, SD card, external disk).
struct RemovableVolume: Identifiable, Equatable {
    var url: URL
    var name: String
    var id: String { url.path }
}

/// Watches for removable drives so the import sheet can offer them as
/// sources, refreshing on mount/unmount. The Crosley's USB drive is only ever
/// read from — the Mac never presents itself as storage to the player.
@MainActor
final class VolumeWatcher: ObservableObject {
    @Published private(set) var removableVolumes: [RemovableVolume] = []

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            })
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    func refresh() {
        let keys: [URLResourceKey] = [
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
            .volumeNameKey, .volumeIsBrowsableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]) ?? []
        removableVolumes = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable == true else { return nil }
            let isRemovable = values.volumeIsRemovable == true
                || values.volumeIsEjectable == true
                || values.volumeIsInternal == false
            guard isRemovable, url.path != "/" else { return nil }
            return RemovableVolume(url: url, name: values.volumeName ?? url.lastPathComponent)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// True while the file's volume is still mounted (used to fail fast when
    /// a drive is yanked mid-import).
    nonisolated static func volumeIsMounted(for url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
