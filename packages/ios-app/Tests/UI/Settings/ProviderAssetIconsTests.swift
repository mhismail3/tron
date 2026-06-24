import Testing
import UIKit

@testable import TronMobile

@Suite("Provider Asset Icons Tests")
struct ProviderAssetIconsTests {

    @Test("all LLM provider brand icons resolve in the asset catalog")
    func brandIconsResolve() {
        for provider in ProviderInfo.modelProviders {
            let image = UIImage(named: provider.assetIcon)
            #expect(image != nil, "Missing asset: \(provider.assetIcon) for provider \(provider.id)")
        }
    }
}
