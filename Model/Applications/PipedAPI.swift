import AVFoundation
import Foundation
import Siesta
import SwiftyJSON

final class PipedAPI: Service, ObservableObject, VideosAPI {
    @Published var account: Account!

    var anonymousAccount: Account {
        .init(instanceID: account.instance.id, name: "Anonymous", url: account.instance.url)
    }

    init(account: Account? = nil) {
        super.init()

        guard account != nil else {
            return
        }

        setAccount(account!)
    }

    func setAccount(_ account: Account) {
        self.account = account

        configure()
    }

    func configure() {
        configure {
            $0.pipeline[.parsing].add(SwiftyJSONTransformer, contentTypes: ["*/json"])
        }

        configureTransformer(pathPattern("channel/*")) { (content: Entity<JSON>) -> Channel? in
            PipedAPI.extractChannel(content.json)
        }

        configureTransformer(pathPattern("streams/*")) { (content: Entity<JSON>) -> Video? in
            PipedAPI.extractVideo(content.json)
        }

        configureTransformer(pathPattern("trending")) { (content: Entity<JSON>) -> [Video] in
            PipedAPI.extractVideos(content.json)
        }

        configureTransformer(pathPattern("search")) { (content: Entity<JSON>) -> [ContentItem] in
            PipedAPI.extractContentItems(content.json.dictionaryValue["items"]!)
        }

        configureTransformer(pathPattern("suggestions")) { (content: Entity<JSON>) -> [String] in
            content.json.arrayValue.map(String.init)
        }
    }

    func channel(_ id: String) -> Resource {
        resource(baseURL: account.url, path: "channel/\(id)")
    }

    func trending(country: Country, category _: TrendingCategory? = nil) -> Resource {
        resource(baseURL: account.instance.url, path: "trending")
            .withParam("region", country.rawValue)
    }

    func search(_ query: SearchQuery) -> Resource {
        resource(baseURL: account.instance.url, path: "search")
            .withParam("q", query.query)
            .withParam("filter", "")
    }

    func searchSuggestions(query: String) -> Resource {
        resource(baseURL: account.instance.url, path: "suggestions")
            .withParam("query", query.lowercased())
    }

    func video(_ id: Video.ID) -> Resource {
        resource(baseURL: account.instance.url, path: "streams/\(id)")
    }

    var signedIn: Bool { false }

    var subscriptions: Resource? { nil }
    var feed: Resource? { nil }
    var home: Resource? { nil }
    var popular: Resource? { nil }
    var playlists: Resource? { nil }

    func channelSubscription(_: String) -> Resource? { nil }

    func playlistVideo(_: String, _: String) -> Resource? { nil }
    func playlistVideos(_: String) -> Resource? { nil }

    private func pathPattern(_ path: String) -> String {
        "**\(path)"
    }

    private static func extractContentItem(_ content: JSON) -> ContentItem? {
        let details = content.dictionaryValue
        let url: String! = details["url"]?.string

        let contentType: ContentItem.ContentType

        if !url.isNil {
            if url.contains("/playlist") {
                contentType = .playlist
            } else if url.contains("/channel") {
                contentType = .channel
            } else {
                contentType = .video
            }
        } else {
            contentType = .video
        }

        switch contentType {
        case .video:
            if let video = PipedAPI.extractVideo(content) {
                return ContentItem(video: video)
            }

        case .playlist:
            return nil

        case .channel:
            if let channel = PipedAPI.extractChannel(content) {
                return ContentItem(channel: channel)
            }
        }

        return nil
    }

    private static func extractContentItems(_ content: JSON) -> [ContentItem] {
        content.arrayValue.compactMap { PipedAPI.extractContentItem($0) }
    }

    private static func extractChannel(_ content: JSON) -> Channel? {
        let attributes = content.dictionaryValue
        guard let id = attributes["id"]?.stringValue ??
            attributes["url"]?.stringValue.components(separatedBy: "/").last
        else {
            return nil
        }

        let subscriptionsCount = attributes["subscriberCount"]?.intValue ?? attributes["subscribers"]?.intValue

        var videos = [Video]()
        if let relatedStreams = attributes["relatedStreams"] {
            videos = PipedAPI.extractVideos(relatedStreams)
        }

        return Channel(
            id: id,
            name: attributes["name"]!.stringValue,
            thumbnailURL: attributes["thumbnail"]?.url,
            subscriptionsCount: subscriptionsCount,
            videos: videos
        )
    }

    private static func extractVideo(_ content: JSON) -> Video? {
        let details = content.dictionaryValue
        let url = details["url"]?.string

        if !url.isNil {
            guard url!.contains("/watch") else {
                return nil
            }
        }

        let channelId = details["uploaderUrl"]!.stringValue.components(separatedBy: "/").last!

        let thumbnails: [Thumbnail] = Thumbnail.Quality.allCases.compactMap {
            if let url = PipedAPI.buildThumbnailURL(content, quality: $0) {
                return Thumbnail(url: url, quality: $0)
            }

            return nil
        }

        let author = details["uploaderName"]?.stringValue ?? details["uploader"]!.stringValue

        return Video(
            videoID: PipedAPI.extractID(content),
            title: details["title"]!.stringValue,
            author: author,
            length: details["duration"]!.doubleValue,
            published: details["uploadedDate"]?.stringValue ?? details["uploadDate"]!.stringValue,
            views: details["views"]!.intValue,
            description: PipedAPI.extractDescription(content),
            channel: Channel(id: channelId, name: author),
            thumbnails: thumbnails,
            likes: details["likes"]?.int,
            dislikes: details["dislikes"]?.int,
            streams: extractStreams(content)
        )
    }

    private static func extractID(_ content: JSON) -> Video.ID {
        content.dictionaryValue["url"]?.stringValue.components(separatedBy: "?v=").last ??
            extractThumbnailURL(content)!.relativeString.components(separatedBy: "/")[4]
    }

    private static func extractThumbnailURL(_ content: JSON) -> URL? {
        content.dictionaryValue["thumbnail"]?.url! ?? content.dictionaryValue["thumbnailUrl"]!.url!
    }

    private static func buildThumbnailURL(_ content: JSON, quality: Thumbnail.Quality) -> URL? {
        let thumbnailURL = extractThumbnailURL(content)
        guard !thumbnailURL.isNil else {
            return nil
        }

        return URL(string: thumbnailURL!
            .absoluteString
            .replacingOccurrences(of: "hqdefault", with: quality.filename)
            .replacingOccurrences(of: "maxresdefault", with: quality.filename)
        )!
    }

    private static func extractDescription(_ content: JSON) -> String? {
        guard var description = content.dictionaryValue["description"]?.string else {
            return nil
        }

        description = description.replacingOccurrences(
            of: "<br/>|<br />|<br>",
            with: "\n",
            options: .regularExpression,
            range: nil
        )

        description = description.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression,
            range: nil
        )

        return description
    }

    private static func extractVideos(_ content: JSON) -> [Video] {
        content.arrayValue.compactMap(extractVideo(_:))
    }

    private static func extractStreams(_ content: JSON) -> [Stream] {
        var streams = [Stream]()

        if let hlsURL = content.dictionaryValue["hls"]?.url {
            streams.append(Stream(hlsURL: hlsURL))
        }

        guard let audioStream = PipedAPI.compatibleAudioStreams(content).first else {
            return streams
        }

        let videoStreams = PipedAPI.compatibleVideoStream(content)

        videoStreams.forEach { videoStream in
            let audioAsset = AVURLAsset(url: audioStream.dictionaryValue["url"]!.url!)
            let videoAsset = AVURLAsset(url: videoStream.dictionaryValue["url"]!.url!)

            let videoOnly = videoStream.dictionaryValue["videoOnly"]?.boolValue ?? true
            let resolution = Stream.Resolution.from(resolution: videoStream.dictionaryValue["quality"]!.stringValue)

            if videoOnly {
                streams.append(
                    Stream(audioAsset: audioAsset, videoAsset: videoAsset, resolution: resolution, kind: .adaptive)
                )
            } else {
                streams.append(
                    SingleAssetStream(avAsset: videoAsset, resolution: resolution, kind: .stream)
                )
            }
        }

        return streams
    }

    private static func compatibleAudioStreams(_ content: JSON) -> [JSON] {
        content
            .dictionaryValue["audioStreams"]?
            .arrayValue
            .filter { $0.dictionaryValue["format"]?.stringValue == "M4A" }
            .sorted {
                $0.dictionaryValue["bitrate"]?.intValue ?? 0 > $1.dictionaryValue["bitrate"]?.intValue ?? 0
            } ?? []
    }

    private static func compatibleVideoStream(_ content: JSON) -> [JSON] {
        content
            .dictionaryValue["videoStreams"]?
            .arrayValue
            .filter { $0.dictionaryValue["format"] == "MPEG_4" } ?? []
    }
}
