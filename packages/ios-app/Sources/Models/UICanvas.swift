import Foundation

// MARK: - Canvas Status

/// Status of a UI canvas rendering
enum UICanvasStatus: Equatable {
    case rendering
    case complete
    case error(String)
}

// MARK: - Canvas Data

/// Data for a single UI canvas instance
struct UICanvasData: Identifiable {
    let id: String
    let canvasId: String
    let title: String?
    let toolCallId: String
    var status: UICanvasStatus
    var partialJSON: String
    var parsedRoot: UICanvasComponent?
    var state: [String: AnyCodable]

    init(
        canvasId: String,
        title: String?,
        toolCallId: String,
        status: UICanvasStatus = .rendering,
        partialJSON: String = "",
        parsedRoot: UICanvasComponent? = nil,
        state: [String: AnyCodable] = [:]
    ) {
        self.id = canvasId
        self.canvasId = canvasId
        self.title = title
        self.toolCallId = toolCallId
        self.status = status
        self.partialJSON = partialJSON
        self.parsedRoot = parsedRoot
        self.state = state
    }
}

extension UICanvasData: Equatable {
    static func == (lhs: UICanvasData, rhs: UICanvasData) -> Bool {
        lhs.id == rhs.id &&
        lhs.canvasId == rhs.canvasId &&
        lhs.title == rhs.title &&
        lhs.toolCallId == rhs.toolCallId &&
        lhs.status == rhs.status &&
        lhs.partialJSON == rhs.partialJSON &&
        lhs.parsedRoot == rhs.parsedRoot
        // Note: state comparison excluded due to [String: AnyCodable] limitations
    }
}

// MARK: - Component Types

/// All valid component tags
enum UICanvasComponentTag: String, Codable, CaseIterable {
    // Layout
    case vstack = "VStack"
    case hstack = "HStack"
    case zstack = "ZStack"
    case scrollView = "ScrollView"
    case spacer = "Spacer"
    case divider = "Divider"
    // Content
    case text = "Text"
    case icon = "Icon"
    case image = "Image"
    // Interactive
    case button = "Button"
    case toggle = "Toggle"
    case slider = "Slider"
    case textField = "TextField"
    case picker = "Picker"
    // Data
    case list = "List"
    case progressView = "ProgressView"
    case badge = "Badge"
    // Structural
    case section = "Section"
    case card = "Card"
}

// MARK: - Component Model

/// A recursive component model for UI rendering
struct UICanvasComponent: Equatable, Identifiable {
    let id: UUID
    let tag: UICanvasComponentTag
    let props: UICanvasProps
    let children: UICanvasChildren

    init(tag: UICanvasComponentTag, props: UICanvasProps = UICanvasProps(), children: UICanvasChildren = .none) {
        self.id = UUID()
        self.tag = tag
        self.props = props
        self.children = children
    }
}

/// Children can be: none, text content, or array of components
enum UICanvasChildren: Equatable {
    case none
    case text(String)
    case components([UICanvasComponent])
}

// MARK: - Component Props

/// Unified props container for all component types
struct UICanvasProps {
    // Layout
    var spacing: Double?
    var alignment: String?
    var axis: String?
    var minLength: Double?

    // Text
    var style: String?
    var weight: String?
    var color: String?
    var lineLimit: Int?

    // Icon/Image
    var name: String?
    var systemName: String?
    var data: String?
    var size: Double?
    var width: Double?
    var height: Double?
    var contentMode: String?

    // Interactive
    var label: String?
    var actionId: String?
    var bindingId: String?
    var isOn: Bool?
    var value: Double?
    var min: Double?
    var max: Double?
    var step: Double?
    var showValue: Bool?
    var placeholder: String?
    var stringValue: String?
    var isSecure: Bool?
    var keyboardType: String?
    var options: [PickerOption]?
    var selected: String?
    var disabled: Bool?
    var icon: String?
    var buttonStyle: String?
    var pickerStyle: String?

    // Data
    var items: [AnyCodable]?
    var itemKey: String?
    var tint: String?
    var progressStyle: String?
    var text: String?

    // Structural
    var header: String?
    var footer: String?
    var padding: Double?
    var cardStyle: String?

    init() {}
}

extension UICanvasProps: Equatable {
    static func == (lhs: UICanvasProps, rhs: UICanvasProps) -> Bool {
        // Compare all simple properties
        lhs.spacing == rhs.spacing &&
        lhs.alignment == rhs.alignment &&
        lhs.axis == rhs.axis &&
        lhs.minLength == rhs.minLength &&
        lhs.style == rhs.style &&
        lhs.weight == rhs.weight &&
        lhs.color == rhs.color &&
        lhs.lineLimit == rhs.lineLimit &&
        lhs.name == rhs.name &&
        lhs.systemName == rhs.systemName &&
        lhs.data == rhs.data &&
        lhs.size == rhs.size &&
        lhs.width == rhs.width &&
        lhs.height == rhs.height &&
        lhs.contentMode == rhs.contentMode &&
        lhs.label == rhs.label &&
        lhs.actionId == rhs.actionId &&
        lhs.bindingId == rhs.bindingId &&
        lhs.isOn == rhs.isOn &&
        lhs.value == rhs.value &&
        lhs.min == rhs.min &&
        lhs.max == rhs.max &&
        lhs.step == rhs.step &&
        lhs.showValue == rhs.showValue &&
        lhs.placeholder == rhs.placeholder &&
        lhs.stringValue == rhs.stringValue &&
        lhs.isSecure == rhs.isSecure &&
        lhs.keyboardType == rhs.keyboardType &&
        lhs.options == rhs.options &&
        lhs.selected == rhs.selected &&
        lhs.disabled == rhs.disabled &&
        lhs.icon == rhs.icon &&
        lhs.buttonStyle == rhs.buttonStyle &&
        lhs.pickerStyle == rhs.pickerStyle &&
        lhs.itemKey == rhs.itemKey &&
        lhs.tint == rhs.tint &&
        lhs.progressStyle == rhs.progressStyle &&
        lhs.text == rhs.text &&
        lhs.header == rhs.header &&
        lhs.footer == rhs.footer &&
        lhs.padding == rhs.padding &&
        lhs.cardStyle == rhs.cardStyle
        // Note: items comparison excluded due to AnyCodable array
    }
}

/// Picker option for Picker component
struct PickerOption: Equatable, Codable, Identifiable {
    var id: String { value }
    let label: String
    let value: String
}

// MARK: - JSON Decoding

extension UICanvasComponent {
    /// Decode from JSON dictionary (from server)
    static func decode(from dict: [String: Any]) -> UICanvasComponent? {
        guard let tagString = dict["$tag"] as? String,
              let tag = UICanvasComponentTag(rawValue: tagString) else {
            return nil
        }

        // Parse props
        var props = UICanvasProps()
        if let propsDict = dict["$props"] as? [String: Any] {
            // Layout
            props.spacing = propsDict["spacing"] as? Double
            props.alignment = propsDict["alignment"] as? String
            props.axis = propsDict["axis"] as? String
            props.minLength = propsDict["minLength"] as? Double

            // Text
            props.style = propsDict["style"] as? String
            props.weight = propsDict["weight"] as? String
            props.color = propsDict["color"] as? String
            props.lineLimit = propsDict["lineLimit"] as? Int

            // Icon/Image
            props.name = propsDict["name"] as? String
            props.systemName = propsDict["systemName"] as? String
            props.data = propsDict["data"] as? String
            props.size = propsDict["size"] as? Double
            props.width = propsDict["width"] as? Double
            props.height = propsDict["height"] as? Double
            props.contentMode = propsDict["contentMode"] as? String

            // Interactive
            props.label = propsDict["label"] as? String
            props.actionId = propsDict["actionId"] as? String
            props.bindingId = propsDict["bindingId"] as? String
            props.isOn = propsDict["isOn"] as? Bool
            props.value = propsDict["value"] as? Double
            props.min = propsDict["min"] as? Double
            props.max = propsDict["max"] as? Double
            props.step = propsDict["step"] as? Double
            props.showValue = propsDict["showValue"] as? Bool
            props.placeholder = propsDict["placeholder"] as? String
            props.stringValue = propsDict["value"] as? String
            props.isSecure = propsDict["isSecure"] as? Bool
            props.keyboardType = propsDict["keyboardType"] as? String
            props.selected = propsDict["selected"] as? String
            props.disabled = propsDict["disabled"] as? Bool
            props.icon = propsDict["icon"] as? String
            props.buttonStyle = propsDict["style"] as? String
            props.pickerStyle = propsDict["style"] as? String

            // Parse picker options
            if let optionsArray = propsDict["options"] as? [[String: String]] {
                props.options = optionsArray.compactMap { optDict in
                    guard let label = optDict["label"], let value = optDict["value"] else { return nil }
                    return PickerOption(label: label, value: value)
                }
            }

            // Data
            if let itemsArray = propsDict["items"] as? [Any] {
                props.items = itemsArray.map { AnyCodable($0) }
            }
            props.itemKey = propsDict["itemKey"] as? String
            props.tint = propsDict["tint"] as? String
            props.progressStyle = propsDict["style"] as? String

            // Badge
            props.text = propsDict["text"] as? String

            // Structural
            props.header = propsDict["header"] as? String
            props.footer = propsDict["footer"] as? String
            props.padding = propsDict["padding"] as? Double
            props.cardStyle = propsDict["style"] as? String
        }

        // Parse children
        let children: UICanvasChildren
        if let childrenString = dict["$children"] as? String {
            children = .text(childrenString)
        } else if let childrenArray = dict["$children"] as? [[String: Any]] {
            let decodedChildren = childrenArray.compactMap { UICanvasComponent.decode(from: $0) }
            children = .components(decodedChildren)
        } else {
            children = .none
        }

        return UICanvasComponent(tag: tag, props: props, children: children)
    }

    /// Decode from JSON data
    static func decode(from data: Data) -> UICanvasComponent? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return decode(from: dict)
    }
}
