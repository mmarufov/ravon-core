package dev.ravon.server

import com.google.protobuf.Timestamp
import dev.ravon.dispatch.Assignment
import dev.ravon.dispatch.DispatchClock
import dev.ravon.dispatch.DispatchCostModel
import dev.ravon.dispatch.DispatchCourier
import dev.ravon.dispatch.DispatchOrder
import dev.ravon.dispatch.GeoPoint
import dev.ravon.dispatch.OptimalBatchDispatcher
import dev.ravon.proto.dispatch.v1.AssignRequest
import dev.ravon.proto.dispatch.v1.AssignResponse
import dev.ravon.proto.dispatch.v1.DispatchPolicy
import dev.ravon.proto.dispatch.v1.DispatchServiceGrpcKt
import dev.ravon.proto.dispatch.v1.GetOfferRequest
import dev.ravon.proto.dispatch.v1.GetOfferResponse
import io.grpc.Status
import io.grpc.StatusException
import java.util.UUID

/**
 * The wire face of the dispatch engine.
 *
 * Deliberately thin: it converts protobuf to the engine's types, calls
 * [OptimalBatchDispatcher], and converts back. No logic lives here, because the engine is
 * the thing verified bit-for-bit against the recorded Swift baseline and a second copy of
 * any of its rules would be a second thing to drift.
 */
class DispatchServiceImpl : DispatchServiceGrpcKt.DispatchServiceCoroutineImplBase() {

    override suspend fun assign(request: AssignRequest): AssignResponse {
        if (!request.hasNow()) {
            throw StatusException(
                Status.INVALID_ARGUMENT.withDescription(
                    "`now` is required: the cost model is a pure function of " +
                        "(couriers, orders, now), and reading a server clock instead would " +
                        "make a request non-reproducible",
                )
            )
        }

        val nowEpochSeconds = request.now.toReferenceDateSeconds()
        val model = request.policyOrDefault()

        val couriers = request.couriersList.map { c ->
            DispatchCourier(
                id = c.courierId.asUuid("courier_id"),
                location = GeoPoint(c.location.latitude, c.location.longitude),
                idleSinceEpochSeconds = c.idleSince.toReferenceDateSeconds(),
                excludedOrderIds = c.excludedOrderIdsList.map { it.asUuid("excluded_order_ids") }.toSet(),
            )
        }
        val orders = request.ordersList.map { o ->
            DispatchOrder(
                id = o.orderId.asUuid("order_id"),
                pickup = GeoPoint(o.pickup.latitude, o.pickup.longitude),
                dropoff = GeoPoint(o.dropoff.latitude, o.dropoff.longitude),
                readyAtEpochSeconds = o.readyAt.toReferenceDateSeconds(),
                createdAtEpochSeconds = o.createdAt.toReferenceDateSeconds(),
                excludedCourierIds = o.excludedCourierIdsList.map { it.asUuid("excluded_courier_ids") }.toSet(),
            )
        }

        val assignments: List<Assignment> =
            OptimalBatchDispatcher(model).assign(couriers, orders, nowEpochSeconds)

        return AssignResponse.newBuilder()
            .addAllAssignments(
                assignments.map {
                    dev.ravon.proto.dispatch.v1.Assignment.newBuilder()
                        .setCourierId(it.courierId.toString())
                        .setOrderId(it.orderId.toString())
                        .setCostMinutes(it.cost)
                        .build()
                }
            )
            .build()
    }

    /**
     * Declared in the contract, not implemented in Phase 1.
     *
     * The offer projection needs order state — restaurant name, earnings, claim status —
     * which arrives with the order module. Failing loudly with UNIMPLEMENTED is the
     * honest answer; returning an empty offer would look like "nothing available" and be
     * indistinguishable from the real thing.
     */
    override suspend fun getOffer(request: GetOfferRequest): GetOfferResponse {
        throw StatusException(
            Status.UNIMPLEMENTED.withDescription(
                "GetOffer lands with the order module; the offer projection needs order state",
            )
        )
    }

    private fun AssignRequest.policyOrDefault(): DispatchCostModel {
        if (!hasPolicy()) return DispatchCostModel()
        val p: DispatchPolicy = policy
        val d = DispatchCostModel()
        // A zero field means "unset" in proto3, so fall back per-field rather than
        // treating a partially-filled policy as a request for zeros — a zero radius
        // would silently forbid every pair.
        return DispatchCostModel(
            averageSpeedKmh = p.averageSpeedKmh.orDefault(d.averageSpeedKmh),
            maxAssignmentRadiusKm = p.maxAssignmentRadiusKm.orDefault(d.maxAssignmentRadiusKm),
            orderAgeCreditPerMinute = p.orderAgeCreditPerMinute.orDefault(d.orderAgeCreditPerMinute),
            courierIdleCreditPerMinute = p.courierIdleCreditPerMinute.orDefault(d.courierIdleCreditPerMinute),
            maxCreditMinutes = p.maxCreditMinutes.orDefault(d.maxCreditMinutes),
        )
    }

    private fun Double.orDefault(fallback: Double) = if (this == 0.0) fallback else this

    private fun String.asUuid(field: String): UUID =
        try {
            UUID.fromString(this)
        } catch (e: IllegalArgumentException) {
            throw StatusException(
                Status.INVALID_ARGUMENT.withDescription("$field is not a UUID: '$this'")
            )
        }

    private companion object {
        /**
         * Unix instant -> the engine's time base. The offset and the reason for it live
         * in [DispatchClock]; this is only the protobuf adapter.
         */
        fun Timestamp.toReferenceDateSeconds(): Double = DispatchClock.fromUnix(seconds, nanos)
    }
}
