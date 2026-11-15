import SwiftUI

@main
@MainActor
struct SportsLabApp: App {
    @StateObject private var health = HealthKitService()
    @StateObject private var golf = GolfSwingAnalyzer()
    @StateObject private var tennis = TennisShotTracker()
    @StateObject private var climbing = ClimbingLogStore()

    var body: some Scene {
        WindowGroup {
            SportsHubView(
                health: health,
                golf: golf,
                tennis: tennis,
                climbing: climbing
            )
        }
    }
}
