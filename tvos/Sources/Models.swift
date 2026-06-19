import Foundation

struct Feed: Decodable {
    let items: [FeedItem]
}

/// One feed video. Extra fields the server may or may not send are optional.
struct FeedItem: Decodable {
    let id: String
    let author: String?
    let nickname: String?
    let avatar: String?
    let verified: Bool?
    let caption: String?
    let cover: String?
    let likes: Int?
    let comments: Int?
    let shares: Int?
    let saves: Int?
    let sound: String?
    let soundCover: String?
    let plays: Int?

    var displayName: String { (nickname?.isEmpty == false ? nickname! : nil) ?? "@\(author ?? "")" }
    var handle: String { author ?? "" }
}

// MARK: - Comments

struct CommentsResponse: Decodable { let comments: [CommentItem] }

struct CommentItem: Decodable {
    let author: String?
    let nickname: String?
    let avatar: String?
    let text: String?
    let likes: Int?
}

// MARK: - Profile

struct ProfileResponse: Decodable {
    let user: ProfileUser?
    let videos: [FeedItem]
}

struct ProfileUser: Decodable {
    let nickname: String?
    let username: String?
    let avatar: String?
    let signature: String?
    let verified: Bool?
    let followers: Int?
    let following: Int?
    let likes: Int?
}

struct VideosResponse: Decodable { let videos: [FeedItem] }
