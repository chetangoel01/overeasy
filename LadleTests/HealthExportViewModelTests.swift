import LadleCore
import XCTest
@testable import Ladle

@MainActor
final class HealthExportViewModelTests: XCTestCase {
    func testChangingServingsScalesPayloadWithoutRequestingPermission() async {
        let service = FakeHealthService()
        let viewModel = makeViewModel(service: service)

        viewModel.selectedServings = 1.5

        let payload = viewModel.payload
        XCTAssertEqual(payload.servings, 1.5)
        XCTAssertEqual(payload.amount(for: .calories), 780)
        XCTAssertEqual(payload.amount(for: .protein), 33)
        XCTAssertEqual(payload.amount(for: .carbohydrates), 72)
        XCTAssertEqual(payload.amount(for: .fat), 36)
        XCTAssertEqual(payload.amount(for: .sodium), 1_020)

        let snapshot = await service.snapshot()
        XCTAssertTrue(snapshot.authorizationRequests.isEmpty)
        XCTAssertTrue(snapshot.writtenPayloads.isEmpty)
        XCTAssertEqual(viewModel.state, .idle)
    }

    func testDeniedPermissionIsNonfatalAndWritesNothing() async {
        let service = FakeHealthService(authorization: .denied)
        let viewModel = makeViewModel(service: service)

        await viewModel.confirmExport()

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.authorizationRequests.count, 1)
        XCTAssertTrue(snapshot.writtenPayloads.isEmpty)
        XCTAssertEqual(viewModel.state, .denied)
    }

    func testSuccessfulWriteReportsExactlyWhatWasExported() async {
        let service = FakeHealthService()
        let viewModel = makeViewModel(service: service)
        viewModel.selectedServings = 2

        await viewModel.confirmExport()

        let snapshot = await service.snapshot()
        let payload = try? XCTUnwrap(snapshot.writtenPayloads.first)
        let receipt = try? XCTUnwrap(snapshot.receipts.first)

        XCTAssertEqual(snapshot.authorizationRequests.count, 1)
        XCTAssertEqual(
            snapshot.authorizationRequests.first,
            payload?.metrics.map(\.kind)
        )
        XCTAssertEqual(payload?.servings, 2)
        XCTAssertEqual(payload?.amount(for: .calories), 1_040)
        XCTAssertEqual(receipt?.exportedMetrics, payload?.metrics)
        XCTAssertEqual(
            viewModel.state,
            receipt.map(HealthExportState.succeeded)
        )
    }

    func testServiceFailureLeavesExportAvailableForRetry() async {
        let service = FakeHealthService(writeError: FakeHealthError.writeFailed)
        let viewModel = makeViewModel(service: service)

        await viewModel.confirmExport()

        XCTAssertEqual(viewModel.state, .failed)
        XCTAssertTrue(viewModel.canRetry)
    }

    private func makeViewModel(
        service: FakeHealthService
    ) -> HealthExportViewModel {
        HealthExportViewModel(
            recipeTitle: "One-Pot Lemon Orzo with Feta",
            nutrition: Nutrition(
                calories: 520,
                proteinGrams: 22,
                carbohydrateGrams: 48,
                fatGrams: 24,
                saturatedFatGrams: 8,
                fiberGrams: 4,
                sugarGrams: 6,
                sodiumMilligrams: 680,
                servingBasis: 1,
                isEstimated: true
            ),
            service: service
        )
    }
}

private enum FakeHealthError: Error {
    case writeFailed
}

private actor FakeHealthService: HealthService {
    struct Snapshot {
        let authorizationRequests: [[HealthExportMetric.Kind]]
        let writtenPayloads: [HealthExportPayload]
        let receipts: [HealthExportReceipt]
    }

    private let authorization: HealthAuthorizationResult
    private let writeError: Error?

    private var authorizationRequests: [[HealthExportMetric.Kind]] = []
    private var writtenPayloads: [HealthExportPayload] = []
    private var receipts: [HealthExportReceipt] = []

    init(
        authorization: HealthAuthorizationResult = .authorized,
        writeError: Error? = nil
    ) {
        self.authorization = authorization
        self.writeError = writeError
    }

    func requestAuthorization(
        for metrics: [HealthExportMetric.Kind]
    ) async throws -> HealthAuthorizationResult {
        authorizationRequests.append(metrics)
        return authorization
    }

    func write(
        _ payload: HealthExportPayload
    ) async throws -> HealthExportReceipt {
        if let writeError {
            throw writeError
        }
        writtenPayloads.append(payload)
        let receipt = HealthExportReceipt(
            payload: payload,
            exportedMetrics: payload.metrics
        )
        receipts.append(receipt)
        return receipt
    }

    func snapshot() -> Snapshot {
        Snapshot(
            authorizationRequests: authorizationRequests,
            writtenPayloads: writtenPayloads,
            receipts: receipts
        )
    }
}
