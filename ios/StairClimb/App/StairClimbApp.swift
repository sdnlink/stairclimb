import SwiftUI

@main
@MainActor
struct StairClimbApp: App {
    @StateObject private var model = LocalAppModel(
        reader: HealthStepReader(), vault: IdentityVault(store: KeychainStore()))
    @StateObject private var social = SocialModel(
        vault: NetworkVault(store: KeychainStore(service: "cn.stairclimb.network-identity", account: "server")))

    var body: some Scene {
        WindowGroup { AppShell(local: model, social: social) }
    }
}
