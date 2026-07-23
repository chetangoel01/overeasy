import Foundation
import LadleCore
import Observation

enum HealthExportState: Equatable {
    case idle
    case exporting
    case denied
    case succeeded(HealthExportReceipt)
    case failed
}

@MainActor
@Observable
final class HealthExportViewModel {
    let recipeTitle: String
    let nutrition: Nutrition

    var selectedServings = 1.0
    private(set) var state: HealthExportState = .idle

    @ObservationIgnored
    private let service: any HealthService

    init(
        recipeTitle: String,
        nutrition: Nutrition,
        service: any HealthService
    ) {
        self.recipeTitle = recipeTitle
        self.nutrition = nutrition
        self.service = service
    }

    var payload: HealthExportPayload {
        HealthExportPayload(
            recipeTitle: recipeTitle,
            nutrition: nutrition,
            servings: Decimal(selectedServings)
        )
    }

    var canRetry: Bool {
        switch state {
        case .denied, .failed:
            true
        case .idle, .exporting, .succeeded:
            false
        }
    }

    func confirmExport() async {
        guard state != .exporting else {
            return
        }

        let payload = payload
        guard !payload.metrics.isEmpty else {
            state = .failed
            return
        }

        state = .exporting
        do {
            let authorization = try await service.requestAuthorization(
                for: payload.metrics.map(\.kind)
            )
            guard authorization == .authorized else {
                state = .denied
                return
            }

            let receipt = try await service.write(payload)
            state = .succeeded(receipt)
        } catch {
            state = .failed
        }
    }

    func resetResult() {
        state = .idle
    }
}
