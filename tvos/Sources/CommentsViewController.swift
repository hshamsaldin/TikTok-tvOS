import UIKit

/// Read-only comments shown in a right-side panel. Menu closes it.
final class CommentsViewController: UIViewController, UITableViewDataSource {
    private let videoID: String
    private var comments: [CommentItem] = []
    private let table = UITableView()
    private let titleLabel = UILabel()

    init(videoID: String) {
        self.videoID = videoID
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        let panel = UIView()
        panel.backgroundColor = UIColor(white: 0.11, alpha: 1)
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        titleLabel.text = "Comments"
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(titleLabel)

        table.dataSource = self
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 120
        table.register(CommentCell.self, forCellReuseIdentifier: "c")
        table.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(table)

        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.widthAnchor.constraint(equalToConstant: 640),
            titleLabel.topAnchor.constraint(equalTo: panel.safeAreaLayoutGuide.topAnchor, constant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 40),
            table.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            table.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 24),
            table.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -24),
            table.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -24),
        ])
        load()
    }

    private func load() {
        Task { @MainActor in
            comments = await API.comments(videoID)
            titleLabel.text = comments.isEmpty ? "Comments" : "Comments · \(comments.count)"
            table.reloadData()
        }
    }

    func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { comments.count }

    func tableView(_ t: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = t.dequeueReusableCell(withIdentifier: "c", for: ip) as! CommentCell
        cell.configure(comments[ip.row])
        return cell
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { dismiss(animated: true) }
        else { super.pressesBegan(presses, with: event) }
    }
}

final class CommentCell: UITableViewCell {
    private let avatar = AsyncImageView()
    private let author = UILabel()
    private let body = UILabel()
    private let meta = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.layer.cornerRadius = 24
        avatar.clipsToBounds = true
        avatar.backgroundColor = UIColor(white: 0.25, alpha: 1)
        avatar.contentMode = .scaleAspectFill

        author.font = .systemFont(ofSize: 18, weight: .semibold)
        author.textColor = UIColor(white: 1, alpha: 0.7)
        body.font = .systemFont(ofSize: 21)
        body.textColor = .white
        body.numberOfLines = 0
        meta.font = .systemFont(ofSize: 15)
        meta.textColor = UIColor(white: 1, alpha: 0.5)

        let col = UIStackView(arrangedSubviews: [author, body, meta])
        col.axis = .vertical
        col.spacing = 4
        col.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(avatar)
        contentView.addSubview(col)

        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 48),
            avatar.heightAnchor.constraint(equalToConstant: 48),
            avatar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            avatar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            col.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 14),
            col.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            col.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            col.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(_ c: CommentItem) {
        avatar.setImage(c.avatar)
        author.text = "@\(c.author ?? "")"
        body.text = c.text
        meta.text = "♥ \(Format.count(c.likes))"
    }
}
