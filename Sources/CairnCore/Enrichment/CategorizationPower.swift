import Foundation

/// Decides whether the on-device model should do heavy work right now.
///
/// The model is by far the most expensive part of categorization — it heats the
/// device and drains the battery — so it is paused when the device is thermally
/// stressed or in Low Power Mode, and a large backlog can be deferred until the
/// device is on external power. The decision is pure: the caller supplies the
/// environment readings, so it is fully unit-testable.
public enum CategorizationPower {
    public enum Decision: Sendable, Equatable {
        case proceed
        /// The device is hot; defer so it can cool down.
        case pauseThermal
        /// The person asked to conserve power.
        case pauseLowPower
        /// The bulk pass is configured to wait for a charger, and none is connected.
        case pauseBattery
    }

    public static func evaluate(
        thermalState: ProcessInfo.ThermalState,
        isLowPowerMode: Bool,
        isOnExternalPower: Bool,
        requiresExternalPower: Bool
    ) -> Decision {
        if thermalState == .serious || thermalState == .critical {
            return .pauseThermal
        }
        if isLowPowerMode {
            return .pauseLowPower
        }
        if requiresExternalPower, !isOnExternalPower {
            return .pauseBattery
        }
        return .proceed
    }

    public static func canProceed(
        thermalState: ProcessInfo.ThermalState,
        isLowPowerMode: Bool,
        isOnExternalPower: Bool,
        requiresExternalPower: Bool
    ) -> Bool {
        evaluate(
            thermalState: thermalState,
            isLowPowerMode: isLowPowerMode,
            isOnExternalPower: isOnExternalPower,
            requiresExternalPower: requiresExternalPower
        ) == .proceed
    }
}
