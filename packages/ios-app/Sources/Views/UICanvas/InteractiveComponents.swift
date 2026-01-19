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
                        .font(.system(size: 14, weight: .medium))
                }
                Text(component.props.label ?? "Button")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .canvasButtonStyle(component.props.buttonStyle)
        .disabled(component.props.disabled ?? false)
        .opacity(component.props.disabled == true ? 0.5 : 1.0)
    }

    private func handleTap() {
        guard let actionId = component.props.actionId else { return }
        state.handleAction(actionId)
    }
}

// MARK: - Button Style Helper

extension View {
    @ViewBuilder
    func canvasButtonStyle(_ style: String?) -> some View {
        switch style {
        case "secondary":
            self
                .foregroundStyle(.tronEmerald)
                .background(Color.tronSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.tronEmerald.opacity(0.5), lineWidth: 1)
                )
        case "link":
            self
                .foregroundStyle(.tronEmerald)
        case "destructive":
            self
                .foregroundStyle(.white)
                .background(Color.tronError)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        default: // primary
            self
                .foregroundStyle(.black)
                .background(Color.tronEmerald)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

// MARK: - Toggle

struct CanvasToggle: View {
    let component: UICanvasComponent
    let state: UICanvasState

    var body: some View {
        Toggle(isOn: binding) {
            Text(component.props.label ?? "")
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(.tronTextPrimary)
        }
        .tint(.tronEmerald)
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
        VStack(alignment: .leading, spacing: 8) {
            if let label = component.props.label {
                HStack {
                    Text(label)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(.tronTextPrimary)
                    Spacer()
                    if component.props.showValue != false {
                        Text(String(format: "%.1f", binding.wrappedValue))
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }

            Slider(
                value: binding,
                in: minValue...maxValue,
                step: stepValue
            )
            .tint(.tronEmerald)
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
        VStack(alignment: .leading, spacing: 8) {
            if let label = component.props.label {
                Text(label)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronTextSecondary)
            }

            Group {
                if component.props.isSecure == true {
                    SecureField(component.props.placeholder ?? "", text: binding)
                } else {
                    TextField(component.props.placeholder ?? "", text: binding)
                        .keyboardType(keyboardType)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 15, design: .monospaced))
            .foregroundStyle(.tronEmerald)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.tronSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.tronBorder, lineWidth: 1)
            )
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
        VStack(alignment: .leading, spacing: 8) {
            if let label = component.props.label {
                Text(label)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronTextSecondary)
            }

            Picker("", selection: binding) {
                ForEach(options) { option in
                    Text(option.label)
                        .tag(option.value)
                }
            }
            .canvasPickerStyle(component.props.pickerStyle)
            .tint(.tronEmerald)
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
    func canvasPickerStyle(_ style: String?) -> some View {
        switch style {
        case "wheel":
            self.pickerStyle(.wheel)
        case "segmented":
            self
                .pickerStyle(.segmented)
                .padding(4)
                .background(Color.tronSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        case "inline":
            self.pickerStyle(.inline)
        default:
            self.pickerStyle(.menu)
        }
    }
}
