package dev.ravon.server

import com.linecorp.armeria.common.HttpResponse
import com.linecorp.armeria.common.grpc.GrpcSerializationFormats
import com.linecorp.armeria.server.Server
import com.linecorp.armeria.server.docs.DocService
import com.linecorp.armeria.server.grpc.GrpcService
import com.linecorp.armeria.server.healthcheck.HealthCheckService
import org.slf4j.LoggerFactory

/**
 * `ravon-api` — one deployable, one process.
 *
 * Per ADR 0002 and §2.1 of the extraction plan: three Gradle modules, not three services.
 * `02-TARGET-ARCHITECTURE.md` was right that a solo developer cannot run four deployables
 * and wrong that the remedy was to keep business logic in SQL. Module boundaries are
 * enforced by Gradle visibility — a compile error, not a network hop — and because the
 * proto packages are already per-module, splitting one out later is a deployment change
 * with an unchanged contract.
 *
 * ## Why Armeria, and why gRPC-Web
 *
 * The iOS clients use Connect-Swift, which speaks Connect, gRPC and gRPC-Web. Only the
 * latter two work over the stock `URLSessionHTTPClient`; plain `.grpc` needs `ConnectNIO`
 * and a bundled HTTP/2 stack. Armeria serves gRPC, gRPC-Web and Protobuf-JSON by default
 * and does *not* speak Connect. So the pairing is Armeria's gRPC-Web against
 * Connect-Swift's `.grpcWeb` — no Envoy, no extra networking stack on the phone, and iOS
 * keeps `URLSession`'s handling of cellular transitions and background suspension, which
 * matters more than it sounds on a throttled Dushanbe link.
 *
 * gRPC-Web cannot do client-streaming or bidirectional streaming. That is fine and
 * deliberate: streaming is a non-goal because Supabase Realtime already carries every
 * subscription. If that changes, Armeria serves full gRPC on the same port and the client
 * switches — a client-side change.
 */
object Main

private val log = LoggerFactory.getLogger(Main::class.java)

fun main() {
    val port = System.getenv("PORT")?.toIntOrNull() ?: 8080
    val server = newServer(port)

    Runtime.getRuntime().addShutdownHook(
        Thread {
            log.info("shutting down")
            server.stop().join()
        }
    )

    server.start().join()
    log.info("ravon-api listening on :{}", port)
}

fun newServer(port: Int): Server = Server.builder().let { sb ->
    sb.http(port)

    sb.service(
        GrpcService.builder()
            .addService(DispatchServiceImpl())
            // gRPC for anything that speaks HTTP/2 natively, **gRPC-Web for the iOS
            // clients**, and Protobuf-JSON so every RPC is curl-able in development —
            // which recovers most of what the Connect protocol would have given.
            //
            // Listing these explicitly narrows Armeria's default set, so the list must
            // be complete. Omitting PROTO_WEB silently removed the one protocol the
            // phones actually use; `DispatchServiceTest` covers gRPC-Web precisely so
            // that mistake cannot ship.
            .supportedSerializationFormats(
                GrpcSerializationFormats.PROTO,
                GrpcSerializationFormats.PROTO_WEB,
                GrpcSerializationFormats.JSON,
                GrpcSerializationFormats.JSON_WEB,
            )
            .enableUnframedRequests(true)
            // Reflection, so `grpcurl` and Armeria's DocService can introspect the
            // service without a copy of the descriptors.
            .enableHttpJsonTranscoding(false)
            .build()
    )

    // Fly polls this. Cheap, and it is the difference between a failed deploy being
    // obvious and being a mystery.
    sb.service("/health", HealthCheckService.of())
    sb.service("/", { _, _ -> HttpResponse.of("ravon-api") })

    // Browsable RPC explorer. Free with Armeria, and genuinely useful for a solo
    // operator who would otherwise be writing grpcurl invocations from memory.
    sb.serviceUnder("/docs", DocService.builder().build())

    sb.build()
}
