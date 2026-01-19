import SwiftUI

// MARK: - Button

struct CanvasButton: View {
    let component: UICanvasComponent
    let state: UICanvasState

    var body: some View {
        Button {
            handleTap()
        } label: {
            HStack(spacing: 8) {
                if let iconName = component.props.icon {
                    Image(systemName: iconName)
                }
                Text(component.props.label ?? "Button")
            }
        }
        .buttonStyleForCanvas(component.props.buttonStyle)
        .disabled(component.props.disabled ?? false)
    }

    private func handleTap() {
        guard let actionId = component.props.actionId else { return }
        state.handleAction(actionId)
    }
}

// MARK: - Button Style Helper

extension View {
    @ViewBuilder
    func buttonStyleForCanvas(_ style: String?) -> some View {
        switch style {
        case "secondary":
            self.buttonStyle(.bordered)
        case "link":
            self.buttonStyle(.plain)
        case "destructive":
            self.buttonStyle(.borderedProminent)
                .tint(.red)
        default:
            self.buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Toggle

struct CanvasToggle: View {
    let component: UICanvasComponent
    let state: UICanvasState

    var body: some View {
        Toggle(component.props.label ?? "", isOn: binding)
    }

    private var binding: Binding<Bool> {
        Binding(
            get: {
                guard let bindingId = component.props.bindingId else {
                    return component.props.isOn ?? false
                }
                return state.getBool(for: bindingId, default: component.props.isOn ?? false)
            },
            set: { newValue in
                guard let bindingId = component.props.bindingId else { return }
                state.setValue(newValue, for: bindingId)
            }
        )
    }
}

// MARK: - Slider

struct CanvasSlider: View {
    let component: UICanvasComponent
    let state: UICanvasState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label = component.props.label {
                HStack {
                    Text(label)
                    Spacer()
                    if component.props.showValue != false {
                        Text(String(format: "%.1f", binding.wrappedValue))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }

            Slider(
                value: binding,
                in: minValue...maxValue,
                step: stepValue
            )
        }
    }

    private var binding: Binding<Double> {
        Binding(
            get: {
                guard let bindingId = component.props.bindingId else {
                    return component.props.value ?? minValue
                }
                return state.getDouble(for: bindingId, default: component.props.value ?? minValue)
            },
            set: { newValue in
                guard let bindingId = component.props.bindingId else { return }
                state.setValue(newValue, for: bindingId)
            }
        )
    }

    private var minValue: Double { component.props.min ?? 0 }
    private var maxValue: Double { component.props.max ?? 100 }
    private var stepValue: Double { component.props.step ?? 1 }
}

// MARK: - TextField

struct CanvasTextField: View {
    let component: UICanvasComponent
    let state: UICanvasState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label = component.props.label {
                Text(label)
                    .font(.subheadline)
            }

            if component.props.isSecure == true {
                SecureField(component.props.placeholder ?? "", text: binding)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(component.props.placeholder ?? "", text: binding)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(keyboardType)
            }
        }
    }

    private var binding: Binding<String> {
        Binding(
            get: {
                guard let bindingId = component.props.bindingId else {
                    return component.props.stringValue ?? ""
                }
                return state.getString(for: bindingId, default: component.props.stringValue ?? "")
            },
            set: { newValue in
                guard let bindingId = component.props.bindingId else { return }
                state.setValue(newValue, for: bindingId)
            }
        )
    }

    private var keyboardType: UIKeyboardType {
        switch component.props.keyboardType {
        case "email": return .emailAddress
        case "number": return .numberPad
        case "phone": return .phonePad
        case "url": return .URL
        default: return .default
        }
    }
}

// MARK: - Picker

struct CanvasPicker: View {
    let component: UICanvasComponent
    let state: UICanvasState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label = component.props.label {
                Text(label)
                    .font(.subheadline)
            }

            Picker("", selection: binding) {
                ForEach(options) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyleForCanvas(component.props.pickerStyle)
        }
    }

    private var options: [PickerOption] {
        component.props.options ?? []
    }

    private var binding: Binding<String> {
        Binding(
            get: {
                guard let bindingId = component.props.bindingId else {
                    return component.props.selected ?? options.first?.value ?? ""
                }
                return state.getString(for: bindingId, default: component.props.selected ?? options.first?.value ?? "")
            },
            set: { newValue in
                guard let bindingId = component.props.bindingId else { return }
                state.setValue(newValue, for: bindingId)
            }
        )
    }

}

// MARK: - Picker Style Helper

extension View {
    @ViewBuilder
    func pickerStyleForCanvas(_ style: String?) -> some View {
        switch style {
        case "wheel":
            self.pickerStyle(.wheel)
        case "segmented":
            self.pickerStyle(.segmented)
        default:
            self.pickerStyle(.menu)
        }
    }
}
