import Foundation
import Cocoa

struct GitHubRelease: Codable {
    let tagName: String
    let htmlUrl: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case assets
    }
}

struct GitHubAsset: Codable {
    let name: String
    let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}

class UpdateChecker {
    static let shared = UpdateChecker()

    private let repoOwner = "rauchg"
    private let repoName = "typing-stats"
    private let checkInterval: TimeInterval = 3600 // Check every hour

    private var checkTimer: Timer?
    private(set) var availableUpdate: GitHubRelease?
    private(set) var isChecking = false

    var onUpdateAvailable: ((GitHubRelease) -> Void)?
    var onCheckComplete: (() -> Void)?

    private init() {}

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    func startPeriodicChecks() {
        checkForUpdates()

        checkTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkForUpdates()
        }
    }

    func stopPeriodicChecks() {
        checkTimer?.invalidate()
        checkTimer = nil
    }

    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true

        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            isChecking = false
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            defer {
                DispatchQueue.main.async {
                    self?.isChecking = false
                    self?.onCheckComplete?()
                }
            }

            guard let self = self,
                  let data = data,
                  error == nil else {
                return
            }

            do {
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                let latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

                if self.isNewerVersion(latestVersion, than: self.currentVersion) {
                    DispatchQueue.main.async {
                        self.availableUpdate = release
                        self.onUpdateAvailable?(release)
                    }
                }
            } catch {
                print("Failed to parse release: \(error)")
            }
        }.resume()
    }

    private func isNewerVersion(_ new: String, than current: String) -> Bool {
        let newParts = new.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        let maxLength = max(newParts.count, currentParts.count)

        for i in 0..<maxLength {
            let newPart = i < newParts.count ? newParts[i] : 0
            let currentPart = i < currentParts.count ? currentParts[i] : 0

            if newPart > currentPart {
                return true
            } else if newPart < currentPart {
                return false
            }
        }

        return false
    }

    func openReleasePage() {
        if let release = availableUpdate, let url = URL(string: release.htmlUrl) {
            NSWorkspace.shared.open(url)
        }
    }

    func downloadUpdate() {
        guard let release = availableUpdate,
              let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let url = URL(string: asset.browserDownloadUrl) else {
            openReleasePage()
            return
        }

        NSWorkspace.shared.open(url)
    }

    var latestVersionString: String? {
        availableUpdate?.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }
}
