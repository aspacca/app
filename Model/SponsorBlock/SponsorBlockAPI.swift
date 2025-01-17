import Alamofire
import Defaults
import Foundation
import Logging
import SwiftyJSON

final class SponsorBlockAPI: ObservableObject {
    static let categories = ["sponsor", "selfpromo", "intro", "outro", "interaction", "music_offtopic"]

    let logger = Logger(label: "net.yattee.app.sb")

    @Published var videoID: String?
    @Published var segments = [Segment]()

    static func categoryDescription(_ name: String) -> String? {
        guard SponsorBlockAPI.categories.contains(name) else {
            return nil
        }

        switch name {
        case "selfpromo":
            return "Self-promotion"
        case "music_offtopic":
            return "Offtopic in Music Videos"
        default:
            return name.capitalized
        }
    }

    func loadSegments(videoID: String, categories: Set<String>) {
        guard !skipSegmentsURL.isNil, self.videoID != videoID else {
            return
        }

        self.videoID = videoID

        requestSegments(categories: categories)
    }

    private func requestSegments(categories: Set<String>) {
        guard let url = skipSegmentsURL, !categories.isEmpty else {
            return
        }

        AF.request(url, parameters: parameters(categories: categories)).responseJSON { response in
            switch response.result {
            case let .success(value):
                self.segments = JSON(value).arrayValue.map(SponsorBlockSegment.init).sorted { $0.end < $1.end }

                self.logger.info("loaded \(self.segments.count) SponsorBlock segments")
                self.segments.forEach {
                    self.logger.info("\($0.start) -> \($0.end)")
                }
            case let .failure(error):
                self.segments = []

                self.logger.error("failed to load SponsorBlock segments: \(error.localizedDescription)")
            }
        }
    }

    private var skipSegmentsURL: String? {
        let url = Defaults[.sponsorBlockInstance]
        return url.isEmpty ? nil : "\(url)/api/skipSegments"
    }

    private func parameters(categories: Set<String>) -> [String: String] {
        [
            "videoID": videoID!,
            "categories": JSON(Array(categories)).rawString(String.Encoding.utf8)!
        ]
    }
}
