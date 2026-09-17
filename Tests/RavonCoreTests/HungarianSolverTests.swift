import XCTest
@testable import RavonCore

final class HungarianSolverTests: XCTestCase {

    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Exhaustive optimum by trying every assignment. Only tractable for tiny n, which
    /// is exactly what makes it a trustworthy oracle.
    private func bruteForceOptimum(_ cost: [[Double]]) -> Double {
        let rows = cost.count
        let columns = cost[0].count
        var best = Double.infinity
        var columnIndices = Array(0..<columns)

        func permute(_ chosen: [Int], _ remaining: [Int]) {
            if chosen.count == min(rows, columns) {
                var total = 0.0
                for (row, column) in chosen.enumerated() { total += cost[row][column] }
                best = min(best, total)
                return
            }
            for (offset, column) in remaining.enumerated() {
                var next = remaining
                next.remove(at: offset)
                permute(chosen + [column], next)
            }
        }
        permute([], columnIndices)
        columnIndices = []
        return best
    }

    func test_knownOptimum_squareMatrix() {
        // Greedy picks (0,0)=1 then is forced into (1,1)=100 → 101.
        // The optimum takes (0,1)=2 and (1,0)=3 → 5.
        let cost = [
            [1.0, 2.0],
            [3.0, 100.0],
        ]
        let assignment = HungarianSolver.solve(cost: cost)
        XCTAssertEqual(HungarianSolver.totalCost(of: assignment, cost: cost), 5.0, accuracy: 1e-9)
        XCTAssertEqual(assignment, [1, 0])
    }

    /// The property that matters: the solver's matching must equal the true optimum.
    /// Verified against brute force over 300 random matrices.
    func test_matchesBruteForceOptimum_onRandomMatrices() {
        var rng = SeededRNG(state: 0xD15A7C4)
        for trial in 0..<300 {
            let rows = Int.random(in: 1...5, using: &rng)
            let columns = Int.random(in: rows...6, using: &rng)
            let cost = (0..<rows).map { _ in
                (0..<columns).map { _ in Double(Int.random(in: 0...50, using: &rng)) }
            }
            let assignment = HungarianSolver.solve(cost: cost)
            let solved = HungarianSolver.totalCost(of: assignment, cost: cost)
            let optimal = bruteForceOptimum(cost)
            XCTAssertEqual(
                solved, optimal, accuracy: 1e-9,
                "trial \(trial): solver got \(solved), optimum is \(optimal), cost=\(cost)"
            )
        }
    }

    /// Every row must be matched at most once and every column at most once.
    func test_matchingIsAValidPermutation() {
        var rng = SeededRNG(state: 7)
        for _ in 0..<200 {
            let rows = Int.random(in: 1...6, using: &rng)
            let columns = Int.random(in: 1...6, using: &rng)
            let cost = (0..<rows).map { _ in
                (0..<columns).map { _ in Double(Int.random(in: 0...99, using: &rng)) }
            }
            let assignment = HungarianSolver.solve(cost: cost)
            XCTAssertEqual(assignment.count, rows)
            let used = assignment.compactMap { $0 }
            XCTAssertEqual(Set(used).count, used.count, "a column was assigned to two rows")
            for column in used {
                XCTAssertTrue((0..<columns).contains(column), "column \(column) out of range")
            }
            // With more columns than rows, every row must find a partner.
            if columns >= rows {
                XCTAssertEqual(used.count, rows, "a row went unmatched despite spare columns")
            } else {
                XCTAssertEqual(used.count, columns, "a column went unused despite waiting rows")
            }
        }
    }

    /// Surplus couriers (more rows than columns) must come back unmatched, not matched
    /// to a phantom order.
    func test_surplusRowsAreUnmatched() {
        let cost = [
            [5.0],
            [3.0],
            [9.0],
        ]
        let assignment = HungarianSolver.solve(cost: cost)
        XCTAssertEqual(assignment.compactMap { $0 }.count, 1, "only one order exists")
        XCTAssertEqual(assignment[1], 0, "the cheapest courier should take the only order")
        XCTAssertNil(assignment[0])
        XCTAssertNil(assignment[2])
    }

    /// A forbidden pair must never be selected, even when it is the only option —
    /// better to leave an order unassigned than to dispatch an excluded courier.
    func test_forbiddenPairsAreNeverMatched() {
        let cost = [
            [HungarianSolver.forbidden, 4.0],
            [2.0, HungarianSolver.forbidden],
        ]
        let assignment = HungarianSolver.solve(cost: cost)
        XCTAssertEqual(assignment[0], 1)
        XCTAssertEqual(assignment[1], 0)

        // Courier 0 is banned from the only order → must stay unassigned.
        let impossible = [[HungarianSolver.forbidden]]
        XCTAssertNil(HungarianSolver.solve(cost: impossible)[0])
    }

    func test_emptyInputIsHandled() {
        XCTAssertTrue(HungarianSolver.solve(cost: []).isEmpty)
        XCTAssertTrue(HungarianSolver.solve(cost: [[]]).isEmpty)
    }

    /// Haversine sanity: Dushanbe to Khujand is ~200 km straight-line.
    func test_haversineMatchesKnownDistance() {
        let dushanbe = GeoPoint(latitude: 38.5598, longitude: 68.7870)
        let khujand = GeoPoint(latitude: 40.2833, longitude: 69.6222)
        let distance = dushanbe.distanceKm(to: khujand)
        XCTAssertEqual(distance, 205, accuracy: 15, "got \(distance) km")
        XCTAssertEqual(dushanbe.distanceKm(to: dushanbe), 0, accuracy: 1e-9)
        // Symmetry.
        XCTAssertEqual(distance, khujand.distanceKm(to: dushanbe), accuracy: 1e-9)
    }
}
