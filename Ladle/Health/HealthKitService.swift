import Foundation
import HealthKit

enum HealthKitServiceError: Error {
    case unsupportedMetric
}

final class HealthKitService: HealthService, @unchecked Sendable {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    func requestAuthorization(
        for metrics: [HealthExportMetric.Kind]
    ) async throws -> HealthAuthorizationResult {
        guard HKHealthStore.isHealthDataAvailable() else {
            return .denied
        }

        let requestedTypes = try metrics.map(quantityType)
        try await healthStore.requestAuthorization(
            toShare: Set(requestedTypes),
            read: []
        )

        let isAuthorized = requestedTypes.allSatisfy {
            healthStore.authorizationStatus(for: $0) == .sharingAuthorized
        }
        return isAuthorized ? .authorized : .denied
    }

    func write(
        _ payload: HealthExportPayload
    ) async throws -> HealthExportReceipt {
        let timestamp = Date()
        let samples = try payload.metrics.map { metric in
            let type = try quantityType(for: metric.kind)
            let quantity = HKQuantity(
                unit: unit(for: metric.kind),
                doubleValue: NSDecimalNumber(
                    decimal: metric.amount
                ).doubleValue
            )
            return HKQuantitySample(
                type: type,
                quantity: quantity,
                start: timestamp,
                end: timestamp,
                metadata: [
                    HKMetadataKeyFoodType: payload.recipeTitle,
                ]
            )
        }

        try await healthStore.save(samples)
        return HealthExportReceipt(
            payload: payload,
            exportedMetrics: payload.metrics
        )
    }

    private func quantityType(
        for kind: HealthExportMetric.Kind
    ) throws -> HKQuantityType {
        let identifier: HKQuantityTypeIdentifier
        switch kind {
        case .calories:
            identifier = .dietaryEnergyConsumed
        case .protein:
            identifier = .dietaryProtein
        case .carbohydrates:
            identifier = .dietaryCarbohydrates
        case .fat:
            identifier = .dietaryFatTotal
        case .saturatedFat:
            identifier = .dietaryFatSaturated
        case .fiber:
            identifier = .dietaryFiber
        case .sugar:
            identifier = .dietarySugar
        case .sodium:
            identifier = .dietarySodium
        }

        guard let type = HKObjectType.quantityType(
            forIdentifier: identifier
        ) else {
            throw HealthKitServiceError.unsupportedMetric
        }
        return type
    }

    private func unit(for kind: HealthExportMetric.Kind) -> HKUnit {
        switch kind {
        case .calories:
            .kilocalorie()
        case .sodium:
            .gramUnit(with: .milli)
        case .protein, .carbohydrates, .fat, .saturatedFat,
             .fiber, .sugar:
            .gram()
        }
    }
}
