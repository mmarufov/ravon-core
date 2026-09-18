package dev.ravon.dispatch

/**
 * Minimum-cost bipartite matching — the Jonker-Volgenant form of the Hungarian
 * algorithm, O(n²m) with potentials.
 *
 * Port of Sources/RavonCore/Dispatch/HungarianSolver.swift. Verified optimal against
 * brute force on 300 random matrices by [HungarianSolverTest].
 *
 * **Determinism.** There is no RNG and no hash-order dependence here, so the port can be
 * byte-identical to the Swift original — but only if two things are preserved:
 *
 *  1. Both comparisons in the inner search are **strict** `<` over **ascending** `j`, so
 *     the lowest column index wins every tie. Using `<=`, iterating a `HashMap`, or
 *     parallelising the scan changes the matching whenever two edges tie.
 *  2. Arrays are 1-indexed with index 0 as the alternating-tree root, exactly as in the
 *     original.
 *
 * **Negative costs are legal and load-bearing.** [DispatchCostModel]'s credits routinely
 * drive costs below zero; potentials are translation-invariant so the solver is
 * unaffected, and it is what lets a stale order outrank a cheap new one. Do not clamp.
 */
object HungarianSolver {

    /**
     * Sentinel for a pair that must never be matched. Large enough to dominate any real
     * cost, small enough that summing a full matching cannot overflow.
     *
     * Note infeasible pairs are *not* excluded during matching — they are allowed to be
     * matched and then discarded at extraction, which is what stops the solver silently
     * producing an impossible assignment.
     */
    const val FORBIDDEN: Double = 1e9

    /**
     * Solves the rectangular assignment problem.
     *
     * @param cost `cost[i][j]` = cost of assigning row `i` to column `j`. Must be
     *   rectangular. Rows are the scarcer side in practice (couriers).
     * @return `assignment[i]` = column matched to row `i`, or `null` if row `i` is
     *   unmatched (which happens whenever `rows > columns`).
     */
    fun solve(cost: List<DoubleArray>): Array<Int?> {
        val rowCount = cost.size
        if (rowCount == 0 || cost[0].isEmpty()) return emptyArray()
        val columnCount = cost[0].size

        // The algorithm requires rows <= columns. Pad with dummy columns of **zero** cost
        // when there are more couriers than orders; the padding absorbs the surplus
        // couriers and they come back as null. Zero, not FORBIDDEN and not infinity.
        val paddedColumns = maxOf(rowCount, columnCount)
        val matrix = Array(rowCount + 1) { DoubleArray(paddedColumns + 1) }
        for (i in 0 until rowCount) {
            for (j in 0 until paddedColumns) {
                matrix[i + 1][j + 1] = if (j < columnCount) cost[i][j] else 0.0
            }
        }

        val n = rowCount
        val m = paddedColumns
        val inf = Double.POSITIVE_INFINITY
        val u = DoubleArray(n + 1)          // row potentials
        val v = DoubleArray(m + 1)          // column potentials
        val p = IntArray(m + 1)             // p[j] = row matched to column j
        val way = IntArray(m + 1)           // alternating-path predecessor

        for (i in 1..n) {
            p[0] = i
            var j0 = 0
            val minv = DoubleArray(m + 1) { inf }
            val used = BooleanArray(m + 1)

            // Grow an alternating tree until it reaches a free column.
            do {
                used[j0] = true
                val i0 = p[j0]
                var delta = inf
                var j1 = 0
                for (j in 1..m) {
                    if (used[j]) continue
                    val cur = matrix[i0][j] - u[i0] - v[j]
                    if (cur < minv[j]) {          // strict: lowest index wins ties
                        minv[j] = cur
                        way[j] = j0
                    }
                    if (minv[j] < delta) {        // strict: lowest index wins ties
                        delta = minv[j]
                        j1 = j
                    }
                }
                // Re-weight so the tightest edge becomes tight, preserving feasibility.
                for (j in 0..m) {
                    if (used[j]) {
                        u[p[j]] += delta
                        v[j] -= delta
                    } else {
                        minv[j] -= delta
                    }
                }
                j0 = j1
            } while (p[j0] != 0)

            // Augment along the path just found.
            do {
                val j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while (j0 != 0)
        }

        val result = arrayOfNulls<Int>(rowCount)
        for (j in 1..m) {
            val row = p[j]
            if (row < 1 || row > rowCount) continue
            val column = j - 1
            // Drop dummy columns and forbidden pairs.
            if (column >= columnCount || cost[row - 1][column] >= FORBIDDEN) continue
            result[row - 1] = column
        }
        return result
    }

    /** Total cost of a matching, for comparing strategies. */
    fun totalCost(assignment: Array<Int?>, cost: List<DoubleArray>): Double {
        var sum = 0.0
        assignment.forEachIndexed { row, column ->
            if (column != null) sum += cost[row][column]
        }
        return sum
    }
}
