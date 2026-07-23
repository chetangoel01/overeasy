import Foundation
import LadleCore

struct HealthExportMetric: Equatable, Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case calories
        case protein
        case carbohydrates
        case fat
        case saturatedFat
        case fiber
        case sugar
        case sodium

        var displayName: String {
            switch self {
            case .calories:
                "Calories"
            case .protein:
                "Protein"
            case .carbohydrates:
                "Carbohydrates"
            case .fat:
                "Fat"
            case .saturatedFat:
                "Saturated fat"
            case .fiber:
                "Fiber"
            case .sugar:
                "Sugar"
            case .sodium:
                "Sodium"
            }
        }

        var unitSymbol: String {
            switch self {
            case .calories:
                "kcal"
            case .sodium:
                "mg"
            case .protein, .carbohydrates, .fat, .saturatedFat,
                 .fiber, .sugar:
                "g"
            }
        }
    }

    let kind: Kind
    let amount: Decimal

    var id: Kind { kind }
}

struct HealthExportPayload: Equatable, Sendable {
    let recipeTitle: String
    let servings: Decimal
    let isEstimated: Bool
    let metrics: [HealthExportMetric]

    init(
        recipeTitle: String,
        nutrition: Nutrition,
        servings: Decimal
    ) {
        let scaled = nutrition.scaled(toServings: servings)
        self.recipeTitle = recipeTitle
        self.servings = servings
        isEstimated = nutrition.isEstimated
        metrics = [
            scaled.calories.map {
                HealthExportMetric(kind: .calories, amount: $0)
            },
            scaled.proteinGrams.map {
                HealthExportMetric(kind: .protein, amount: $0)
            },
            scaled.carbohydrateGrams.map {
                HealthExportMetric(kind: .carbohydrates, amount: $0)
            },
            scaled.fatGrams.map {
                HealthExportMetric(kind: .fat, amount: $0)
            },
            scaled.saturatedFatGrams.map {
                HealthExportMetric(kind: .saturatedFat, amount: $0)
            },
            scaled.fiberGrams.map {
                HealthExportMetric(kind: .fiber, amount: $0)
            },
            scaled.sugarGrams.map {
                HealthExportMetric(kind: .sugar, amount: $0)
            },
            scaled.sodiumMilligrams.map {
                HealthExportMetric(kind: .sodium, amount: $0)
            },
        ]
        .compactMap { $0 }
    }

    func amount(for kind: HealthExportMetric.Kind) -> Decimal? {
        metrics.first { $0.kind == kind }?.amount
    }
}

enum HealthAuthorizationResult: Equatable, Sendable {
    case authorized
    case denied
}

struct HealthExportReceipt: Equatable, Sendable {
    let payload: HealthExportPayload
    let exportedMetrics: [HealthExportMetric]
}

protocol HealthService: Sendable {
    func requestAuthorization(
        for metrics: [HealthExportMetric.Kind]
    ) async throws -> HealthAuthorizationResult

    func write(
        _ payload: HealthExportPayload
    ) async throws -> HealthExportReceipt
}
