import Foundation

/// Minimum-cost bipartite matching — the Jonker-Volgenant form of the Hungarian
/// algorithm, O(n²m) with potentials.
///
/// Dispatch is an assignment problem: given `n` idle couriers and `m` unassigned orders,
/// choose the set of (courier, order) pairs minimising total cost. Greedy nearest-courier
/// is the obvious approach and is provably suboptimal — assigning the closest courier to
/// the first order can strand a second order whose only nearby courier was just consumed.
///
/// This solves the whole batch at once instead.
public enum HungarianSolver {

    /// Sentinel for a pair that must never be matched (courier excluded from an order,
    /// out of range, etc.). Large enough to dominate any real cost, small enough that
    /// summing a full matching cannot overflow.
    public static let forbidden = 1e9

    /// Solves the rectangular assignment problem.
    ///
    /// - Parameter cost: `cost[i][j]` = cost of assigning row `i` to column `j`.
    ///   Must be rectangular. Rows are the scarcer side in practice (couriers).
    /// - Returns: `assignment[i]` = column matched to row `i`, or `nil` if row `i` is
    ///   unmatched (which happens whenever `rows > columns`).
    ///
    /// Pairs at or above ``forbidden`` are treated as unmatchable and returned as `nil`
    /// rather than silently producing an impossible assignment.
    public static func solve(cost: [[Double]]) -> [Int?] {
        let rowCount = cost.count
        guard rowCount > 0, let firstRow = cost.first, !firstRow.isEmpty else { return [] }
        let columnCount = firstRow.count

        // The algorithm below requires rows <= columns. Pad with dummy columns of zero
        // cost when there are more couriers than orders; the padding absorbs the
        // surplus couriers and they come back as `nil`.
        let paddedColumns = max(rowCount, columnCount)
        var matrix = [[Double]](
            repeating: [Double](repeating: 0, count: paddedColumns + 1),
            count: rowCount + 1
        )
        for i in 0..<rowCount {
            for j in 0..<paddedColumns {
                matrix[i + 1][j + 1] = j < columnCount ? cost[i][j] : 0
            }
        }

        let n = rowCount, m = paddedColumns
        let inf = Double.infinity
        var u = [Double](repeating: 0, count: n + 1)   // row potentials
        var v = [Double](repeating: 0, count: m + 1)   // column potentials
        var p = [Int](repeating: 0, count: m + 1)      // p[j] = row matched to column j
        var way = [Int](repeating: 0, count: m + 1)    // alternating-path predecessor

        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = [Double](repeating: inf, count: m + 1)
            var used = [Bool](repeating: false, count: m + 1)

            // Grow an alternating tree until it reaches a free column.
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = inf
                var j1 = 0
                for j in 1...m where !used[j] {
                    let cur = matrix[i0][j] - u[i0] - v[j]
                    if cur < minv[j] {
                        minv[j] = cur
                        way[j] = j0
                    }
                    if minv[j] < delta {
                        delta = minv[j]
                        j1 = j
                    }
                }
                // Re-weight so the tightest edge becomes tight, preserving feasibility.
                for j in 0...m {
                    if used[j] {
                        u[p[j]] += delta
                        v[j] -= delta
                    } else {
                        minv[j] -= delta
                    }
                }
                j0 = j1
            } while p[j0] != 0

            // Augment along the path just found.
            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }

        var result = [Int?](repeating: nil, count: rowCount)
        for j in 1...m {
            let row = p[j]
            guard row >= 1, row <= rowCount else { continue }
            let column = j - 1
            // Drop dummy columns and forbidden pairs.
            guard column < columnCount, cost[row - 1][column] < forbidden else { continue }
            result[row - 1] = column
        }
        return result
    }

    /// Total cost of a matching, for comparing strategies.
    public static func totalCost(of assignment: [Int?], cost: [[Double]]) -> Double {
        var sum = 0.0
        for (row, column) in assignment.enumerated() {
            guard let column else { continue }
            sum += cost[row][column]
        }
        return sum
    }
}
