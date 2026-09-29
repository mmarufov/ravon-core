package dev.ravon.server

import com.google.protobuf.Timestamp
import com.linecorp.armeria.client.grpc.GrpcClients
import com.linecorp.armeria.server.Server
import dev.ravon.dispatch.DispatchClock
import dev.ravon.dispatch.DispatchCostModel
import dev.ravon.dispatch.DispatchCourier
import dev.ravon.dispatch.DispatchOrder
import dev.ravon.dispatch.MarketplaceSimulator
import dev.ravon.dispatch.OptimalBatchDispatcher
import dev.ravon.proto.dispatch.v1.AssignRequest
import dev.ravon.proto.dispatch.v1.CourierState
import dev.ravon.proto.dispatch.v1.DispatchServiceGrpcKt
import dev.ravon.proto.dispatch.v1.GeoPoint
import dev.ravon.proto.dispatch.v1.GetOfferRequest
import dev.ravon.proto.dispatch.v1.PendingOrder
import io.grpc.Status
import io.grpc.StatusException
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.TestInstance
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * End-to-end: a real Armeria server, a real client, over the wire.
 *
 * The point is not that the RPC returns *something* — it is that what comes back over the
 * wire is **identical to what the verified engine computes in-process**. The engine is
 * pinned bit-for-bit to the Swift baseline, so proving the transport is lossless extends
 * that guarantee all the way to the client.
 *
 * Both gRPC and gRPC-Web are exercised. gRPC-Web specifically, because that is the
 * protocol the iOS clients will actually use (Connect-Swift's `.grpcWeb` over the stock
 * `URLSession`), and a server that only happened to work over HTTP/2 would be a nasty
 * thing to discover from a phone.
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class DispatchServiceTest {

    private lateinit var server: Server
    private val port get() = server.activeLocalPort()

    @BeforeAll
    fun start() {
        server = newServer(0)
        server.start().join()
    }

    @AfterAll
    fun stop() {
        server.stop().join()
    }

    /**
     * Armeria selects the wire protocol from the URI scheme: `gproto+` is gRPC over
     * HTTP/2, `gproto-web+` is gRPC-Web — the one Connect-Swift uses from iOS.
     */
    private fun client(scheme: String = "gproto") =
        GrpcClients.newClient(
            "$scheme+http://127.0.0.1:$port/",
            DispatchServiceGrpcKt.DispatchServiceCoroutineStub::class.java,
        )

    /** The simulation epoch plus an offset, as a Unix-epoch protobuf Timestamp. */
    private fun refSeconds(offsetMinutes: Double): Timestamp {
        val unix = DispatchClock.toUnixSeconds(MarketplaceSimulator.EPOCH_SECONDS + offsetMinutes * 60)
        return Timestamp.newBuilder()
            .setSeconds(unix.toLong())
            .setNanos(((unix - unix.toLong()) * 1_000_000_000).toInt())
            .build()
    }

    private fun geo(lat: Double, lon: Double) =
        GeoPoint.newBuilder().setLatitude(lat).setLongitude(lon).build()

    /**
     * A small but non-trivial batch: three couriers, three orders, where the greedy
     * choice is not the optimal one. Built by hand rather than from the simulator so the
     * test states its own scenario.
     */
    private fun scenario(): AssignRequest {
        val centreLat = 38.5598
        val centreLon = 68.7870
        val courierIds = List(3) { UUID(0xC0DE, it.toLong()) }
        val orderIds = List(3) { UUID(0x0DDE, it.toLong()) }

        return AssignRequest.newBuilder()
            .setNow(refSeconds(30.0))
            .addAllCouriers(
                courierIds.mapIndexed { i, id ->
                    CourierState.newBuilder()
                        .setCourierId(id.toString())
                        .setLocation(geo(centreLat + 0.005 * i, centreLon + 0.004 * i))
                        .setIdleSince(refSeconds(0.0))
                        .build()
                }
            )
            .addAllOrders(
                orderIds.mapIndexed { i, id ->
                    PendingOrder.newBuilder()
                        .setOrderId(id.toString())
                        .setPickup(geo(centreLat + 0.006 * i, centreLon - 0.003 * i))
                        .setDropoff(geo(centreLat - 0.004 * i, centreLon + 0.006 * i))
                        .setReadyAt(refSeconds(35.0 + i))
                        .setCreatedAt(refSeconds(10.0 * i))
                        .build()
                }
            )
            .build()
    }

    /**
     * The same scenario run through the engine in-process, as the oracle.
     *
     * Converting via [DispatchClock] rather than open-coding the offset is the point:
     * if the wire adapter and the test disagreed about the epoch, the test would pass
     * against its own mistake.
     */
    private fun engineResult() = scenario().let { req ->
        OptimalBatchDispatcher(DispatchCostModel()).assign(
            req.couriersList.map {
                DispatchCourier(
                    id = UUID.fromString(it.courierId),
                    location = dev.ravon.dispatch.GeoPoint(it.location.latitude, it.location.longitude),
                    idleSinceEpochSeconds = DispatchClock.fromUnix(it.idleSince.seconds, it.idleSince.nanos),
                )
            },
            req.ordersList.map {
                DispatchOrder(
                    id = UUID.fromString(it.orderId),
                    pickup = dev.ravon.dispatch.GeoPoint(it.pickup.latitude, it.pickup.longitude),
                    dropoff = dev.ravon.dispatch.GeoPoint(it.dropoff.latitude, it.dropoff.longitude),
                    readyAtEpochSeconds = DispatchClock.fromUnix(it.readyAt.seconds, it.readyAt.nanos),
                    createdAtEpochSeconds = DispatchClock.fromUnix(it.createdAt.seconds, it.createdAt.nanos),
                )
            },
            DispatchClock.fromUnix(req.now.seconds, req.now.nanos),
        )
    }

    private fun expected(): List<Pair<String, String>> =
        engineResult().map { it.courierId.toString() to it.orderId.toString() }

    @Test
    fun `assign over gRPC matches the in-process engine`() = runBlocking {
        val response = client().assign(scenario())
        val got = response.assignmentsList.map { it.courierId to it.orderId }
        assertEquals(expected(), got, "the wire changed the matching")
        assertTrue(got.isNotEmpty(), "scenario should produce assignments")
    }

    /** The protocol the iOS clients actually use. */
    @Test
    fun `assign over gRPC-Web matches the in-process engine`() = runBlocking {
        val response = client("gproto-web").assign(scenario())
        assertEquals(expected(), response.assignmentsList.map { it.courierId to it.orderId })
    }

    /** Costs must survive the wire exactly — the engine is bitwise-pinned, so the transport must be too. */
    @Test
    fun `assignment costs survive the wire bitwise`() = runBlocking {
        val response = client().assign(scenario())
        val engine = engineResult()
        assertEquals(engine.size, response.assignmentsCount)
        response.assignmentsList.forEachIndexed { i, a ->
            assertEquals(
                engine[i].cost.toRawBits(), a.costMinutes.toRawBits(),
                "cost for assignment $i changed crossing the wire",
            )
        }
    }

    /**
     * `now` is required rather than defaulted. A server that quietly read its own clock
     * would make every request non-reproducible, which defeats the reason the cost model
     * is a pure function in the first place.
     */
    @Test
    fun `assign without now is rejected`() = runBlocking {
        val e = runCatching {
            client().assign(scenario().toBuilder().clearNow().build())
        }.exceptionOrNull()
        assertTrue(e is StatusException, "expected a StatusException, got $e")
        assertEquals(Status.Code.INVALID_ARGUMENT, e.status.code)
    }

    @Test
    fun `malformed uuid is rejected as invalid argument`() = runBlocking {
        val bad = scenario().toBuilder()
            .setCouriers(0, scenario().getCouriers(0).toBuilder().setCourierId("not-a-uuid"))
            .build()
        val e = runCatching { client().assign(bad) }.exceptionOrNull()
        assertTrue(e is StatusException)
        assertEquals(Status.Code.INVALID_ARGUMENT, e.status.code)
    }

    /** An empty batch is legal and means "nothing to do", not an error. */
    @Test
    fun `empty batch returns no assignments`() = runBlocking {
        val response = client().assign(
            AssignRequest.newBuilder().setNow(refSeconds(0.0)).build()
        )
        assertTrue(response.assignmentsList.isEmpty())
    }

    /** Declared in the contract, deliberately not implemented yet — and says so. */
    @Test
    fun `get offer reports unimplemented rather than pretending`() = runBlocking {
        val e = runCatching {
            client().getOffer(
                GetOfferRequest.newBuilder()
                    .setCourierId(UUID(0xC0DE, 0).toString())
                    .setLocation(geo(38.5598, 68.7870))
                    .build()
            )
        }.exceptionOrNull()
        assertTrue(e is StatusException)
        assertEquals(
            Status.Code.UNIMPLEMENTED, e.status.code,
            "an empty offer would be indistinguishable from 'nothing available'",
        )
    }
}
