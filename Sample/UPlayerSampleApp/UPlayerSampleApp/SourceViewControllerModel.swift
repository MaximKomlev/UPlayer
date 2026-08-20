//
//  SourceViewControllerModel.swift
//  UPlayer
//
//  Created by Max Komleu on 8/20/26.
//

import UIKit
import Foundation

public enum SourceViewControllerModelType {
    case play
    case preprocess
}

public struct SourceViewControllerModel {

    public struct Item: Hashable {
        public let id: String
        public let title: String
        public let subtitle: String?
        public let url: URL?
        public let type: SourceViewControllerModelType

        public init(id: String = UUID().uuidString,
                    title: String,
                    subtitle: String? = nil,
                    url: URL?,
                    type: SourceViewControllerModelType = .play) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.url = url
            self.type = type
        }
    }

    public let title: String
    public let customURLTitle: String
    public let customURLPlaceholder: String
    public let actionsTitle: String

    public let backButtonTitle: String
    public let doneButtonTitle: String

    public let items: [Item]

    public let initialURL: URL?

    public let textViewHeight: CGFloat
    public let itemHeight: CGFloat

    public init(title: String = "Video List",
                customURLTitle: String = "Custom URL",
                customURLPlaceholder: String = "Enter MPEG-DASH, HLS, or MP4 URL",
                actionsTitle: String = "Available Videos",
                backButtonTitle: String = "Back",
                doneButtonTitle: String = "Done",
                items: [Item],
                initialURL: URL? = nil,
                textViewHeight: CGFloat = 90,
                itemHeight: CGFloat = 64) {
        self.title = title
        self.customURLTitle = customURLTitle
        self.customURLPlaceholder = customURLPlaceholder
        self.actionsTitle = actionsTitle
        self.backButtonTitle = backButtonTitle
        self.doneButtonTitle = doneButtonTitle
        self.items = items
        self.initialURL = initialURL
        self.textViewHeight = textViewHeight
        self.itemHeight = itemHeight
    }
}
