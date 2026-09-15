import Foundation
#if os(iOS)
import FinanceKit
#endif

/// Whether eligible Apple Wallet financial data can be read on this device.
///
/// FinanceKit's financial-data APIs are iPhone/iPad only, so this is always
/// `false` on macOS. Callers use it to decide whether to offer the Apple Wallet
/// connection option at all.
///
/// - Important: FinanceKit terminates the process — it does not throw — when its
///   APIs are called without the managed `com.apple.developer.financekit`
///   entitlement. Every call is therefore gated on this check, and the iOS
///   entitlements file must be applied to any build that reads Wallet data.
public enum WalletAvailability {
    public static var isSupported: Bool {
        #if os(iOS)
        FinanceStore.isDataAvailable(.financialData)
        #else
        false
        #endif
    }
}
