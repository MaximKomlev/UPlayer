//
//  SourceViewController.swift
//  UPlayer
//
//  Created by Max Komleu on 8/20/26.
//

import UIKit

public protocol SourceViewControllerDelegate: AnyObject {

    func videoSelectionViewController(_ controller: SourceViewController, didSelect item: SourceViewControllerModel.Item?, customURL: URL?)
    func videoSelectionViewControllerDidCancel(_ controller: SourceViewController)
}

final class SourceViewSelectionCell: UICollectionViewCell {

    static let reuseIdentifier = "SourceViewSelectionCell"

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let checkmarkView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 12

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.numberOfLines = 1

        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 2

        checkmarkView.image = UIImage(systemName: "checkmark.circle.fill")
        checkmarkView.tintColor = .systemBlue

        let labelsStack = UIStackView(
            arrangedSubviews: [
                titleLabel,
                subtitleLabel
            ]
        )

        labelsStack.axis = .vertical
        labelsStack.spacing = 2

        let stack = UIStackView(
            arrangedSubviews: [
                labelsStack,
                checkmarkView
            ]
        )

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),

            checkmarkView.widthAnchor.constraint(equalToConstant: 22),
            checkmarkView.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String,
                   subtitle: String?,
                   selected: Bool) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle?.isEmpty != false
        checkmarkView.isHidden = !selected
    }
}

public final class SourceViewController: UIViewController {

    private let model: SourceViewControllerModel

    private var selectedIndex: Int? {
        didSet {
            updateDoneButton()
            collectionView.reloadData()
        }
    }

    public weak var delegate: SourceViewControllerDelegate?

    // MARK: - UI

    private lazy var customURLTitleLabel: UILabel = {
        let label = UILabel()
        label.text = model.customURLTitle
        label.font = .preferredFont(forTextStyle: .headline)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var customURLTextView: UITextView = {
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true

        view.layer.cornerRadius = 10
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.separator.cgColor

        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.keyboardType = .URL

        view.textContainerInset = UIEdgeInsets(top: 10,
                                               left: 10,
                                               bottom: 10,
                                               right: 10)

        view.delegate = self
        view.translatesAutoresizingMaskIntoConstraints = false

        return view
    }()

    private lazy var placeholderLabel: UILabel = {
        let label = UILabel()
        label.text = model.customURLPlaceholder
        label.textColor = .placeholderText
        label.font = .preferredFont(forTextStyle: .body)
        label.numberOfLines = 0
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var actionsTitleLabel: UILabel = {
        let label = UILabel()
        label.text = model.actionsTitle
        label.font = .preferredFont(forTextStyle: .headline)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()

        layout.minimumLineSpacing = 8
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = UIEdgeInsets(
            top: 8,
            left: 16,
            bottom: 16,
            right: 16
        )

        let view = UICollectionView(
            frame: .zero,
            collectionViewLayout: layout
        )

        view.backgroundColor = .systemBackground
        view.dataSource = self
        view.delegate = self
        view.allowsMultipleSelection = false
        view.contentInsetAdjustmentBehavior = .never
        
        view.register(SourceViewSelectionCell.self,
                      forCellWithReuseIdentifier: SourceViewSelectionCell.reuseIdentifier)

        view.translatesAutoresizingMaskIntoConstraints = false

        return view
    }()

    private lazy var doneButton = UIBarButtonItem(title: model.doneButtonTitle,
                                                  style: .done,
                                                  target: self,
                                                  action: #selector(doneButtonPressed))

    // MARK: - Init

    public init(model: SourceViewControllerModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()

        title = model.title
        view.backgroundColor = .systemBackground

        setupNavigation()
        setupViews()
        setupConstraints()
        applyInitialState()
    }
    
    public override func viewWillTransition(to size: CGSize,
                                            with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        coordinator.animate(alongsideTransition: { [weak self] _ in
                self?.collectionView.collectionViewLayout.invalidateLayout()
            },
            completion: { [weak self] _ in
                self?.collectionView.collectionViewLayout.invalidateLayout()
            }
        )
    }
}

private extension SourceViewController {

    func setupNavigation() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: model.backButtonTitle,
            style: .plain,
            target: self,
            action: #selector(backButtonPressed)
        )

        navigationItem.rightBarButtonItem = doneButton
    }

    func setupViews() {
        view.addSubview(customURLTitleLabel)
        view.addSubview(customURLTextView)
        customURLTextView.addSubview(placeholderLabel)

        view.addSubview(actionsTitleLabel)
        view.addSubview(collectionView)
    }

    func setupConstraints() {
        NSLayoutConstraint.activate([
            customURLTitleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            customURLTitleLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            customURLTitleLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            customURLTextView.topAnchor.constraint(equalTo: customURLTitleLabel.bottomAnchor, constant: 8),
            customURLTextView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            customURLTextView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            customURLTextView.heightAnchor.constraint(equalToConstant: model.textViewHeight),
            placeholderLabel.topAnchor.constraint(equalTo: customURLTextView.topAnchor, constant: 10),
            placeholderLabel.leadingAnchor.constraint(equalTo: customURLTextView.leadingAnchor, constant: 14),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: customURLTextView.trailingAnchor, constant: -14),
            actionsTitleLabel.topAnchor.constraint(equalTo: customURLTextView.bottomAnchor, constant: 20),
            actionsTitleLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            actionsTitleLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: actionsTitleLabel.bottomAnchor,constant: 4),
            collectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }

    func applyInitialState() {
        if let initialURL = model.initialURL {
            customURLTextView.text = initialURL.absoluteString
        }

        updatePlaceholder()
        updateDoneButton()
    }
}

extension SourceViewController: UICollectionViewDataSource {

    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        model.items.count
    }

    public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {

        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: SourceViewSelectionCell.reuseIdentifier,
                                                            for: indexPath) as? SourceViewSelectionCell else {
            return UICollectionViewCell()
        }

        let item = model.items[indexPath.item]

        cell.configure(title: item.title,
                       subtitle: item.subtitle ?? item.url?.absoluteString,
                       selected: selectedIndex == indexPath.item)

        return cell
    }
}

extension SourceViewController: UICollectionViewDelegate {

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        selectedIndex = indexPath.item

        customURLTextView.text = ""
        updatePlaceholder()
    }
}

extension SourceViewController: UICollectionViewDelegateFlowLayout {

    public func collectionView(_ collectionView: UICollectionView,
                               layout collectionViewLayout: UICollectionViewLayout,
                               sizeForItemAt indexPath: IndexPath) -> CGSize {

        guard let layout = collectionViewLayout as? UICollectionViewFlowLayout else {
            return CGSize(width: collectionView.bounds.width,
                          height: model.itemHeight)
        }

        let availableWidth = collectionView.bounds.width - layout.sectionInset.left - layout.sectionInset.right

        return CGSize(width: max(0, availableWidth),
                      height: model.itemHeight)
    }
}

private extension SourceViewController {
    
    @objc
    func backButtonPressed() {
        delegate?.videoSelectionViewControllerDidCancel(self)
        close()
    }
    
    @objc
    func doneButtonPressed() {
        let customURL = parsedCustomURL()
        
        let item: SourceViewControllerModel.Item?
        
        if let selectedIndex {
            item = model.items[selectedIndex]
        } else {
            item = nil
        }
        
        close { [weak self] in
            guard let self else {
                return
            }
            
            self.delegate?.videoSelectionViewController(
                self,
                didSelect: item,
                customURL: customURL
            )
        }
    }
    
    func parsedCustomURL() -> URL? {
        let value = customURLTextView.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !value.isEmpty else {
            return nil
        }
        
        return URL(string: value)
    }
    
    func updatePlaceholder() {
        placeholderLabel.isHidden = !customURLTextView.text.isEmpty
    }
    
    func updateDoneButton() {
        doneButton.isEnabled =
        selectedIndex != nil ||
        parsedCustomURL() != nil
    }
    
    func close(completion: (() -> Void)? = nil) {
        if let navigationController,
           navigationController.presentingViewController != nil {
            navigationController.dismiss(animated: true, completion: completion)
            return
        }
        
        if presentingViewController != nil {
            dismiss(animated: true, completion: completion)
            return
        }
        
        if let navigationController {
            navigationController.popViewController(animated: true)
            
            transitionCoordinator?.animate(alongsideTransition: nil,
                completion: { _ in
                    completion?()
                })
            return
        }
        
        completion?()
    }
}

extension SourceViewController: UITextViewDelegate {

    public func textViewDidChange(_ textView: UITextView) {
        updatePlaceholder()

        let value = textView.text
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !value.isEmpty {
            selectedIndex = nil

            collectionView.indexPathsForSelectedItems?.forEach {
                collectionView.deselectItem(at: $0, animated: false)
            }
        }

        updateDoneButton()
    }
}
