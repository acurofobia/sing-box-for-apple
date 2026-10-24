/* Derived from SagerNet/sing-box-for-android LocalResolver.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
package io.whitelink.android.vpn

import android.net.DnsResolver
import android.net.Network
import android.os.Build
import android.os.CancellationSignal
import io.nekohasekai.libbox.ExchangeContext
import io.nekohasekai.libbox.LocalDNSTransport
import java.io.IOException
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.UnknownHostException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Only bootstrap names use Android's resolver on the physical network. */
internal class PhysicalResolver(
    private val network: () -> Network?,
    private val current: () -> Boolean,
) : LocalDNSTransport {
    override fun raw(): Boolean = false
    override fun exchange(ctx: ExchangeContext?, message: ByteArray?) {
        throw IOException("raw local DNS exchange unavailable")
    }

    override fun lookup(ctx: ExchangeContext, family: String, domain: String) {
        val physical = network() ?: throw IOException("no underlying network")
        if (!current()) throw IOException("VPN startup cancelled")
        val name = domain.removeSuffix(".")
        if (Build.VERSION.SDK_INT >= 29) {
            val signal = CancellationSignal()
            val future = CompletableFuture<Pair<Collection<InetAddress>, Int>>()
            ctx.onCancel {
                signal.cancel()
                future.completeExceptionally(IOException("DNS lookup cancelled"))
            }
            val callback = object : DnsResolver.Callback<Collection<InetAddress>> {
                override fun onAnswer(answer: Collection<InetAddress>, rcode: Int) {
                    future.complete(answer to rcode)
                }
                override fun onError(error: DnsResolver.DnsException) { future.completeExceptionally(error) }
            }
            val resolver = DnsResolver.getInstance()
            val type = when {
                family.endsWith("4") -> DnsResolver.TYPE_A
                family.endsWith("6") -> DnsResolver.TYPE_AAAA
                else -> null
            }
            try {
                if (type == null) resolver.query(physical, name, DnsResolver.FLAG_NO_RETRY, executor, signal, callback)
                else resolver.query(physical, name, type, DnsResolver.FLAG_NO_RETRY, executor, signal, callback)
                val (answer, rcode) = future.get(10, TimeUnit.SECONDS)
                if (!current()) throw IOException("VPN startup cancelled")
                if (rcode != 0) ctx.errorCode(rcode) else ctx.success(answer.filter {
                    when { family.endsWith("4") -> it is Inet4Address; family.endsWith("6") -> it is Inet6Address; else -> true }
                }.mapNotNull { it.hostAddress }.joinToString("\n"))
            } finally { signal.cancel() }
        } else {
            // On API 24-28 getAllByName has no cancellation API. The bounded
            // worker pool and timeout prevent it blocking the VPN lifecycle.
            val future = CompletableFuture.supplyAsync({ physical.getAllByName(name).toList() }, legacyExecutor)
            ctx.onCancel { future.cancel(true) }
            try {
                val answer = future.get(10, TimeUnit.SECONDS)
                if (!current()) throw IOException("VPN startup cancelled")
                ctx.success(answer.filter {
                    when { family.endsWith("4") -> it is Inet4Address; family.endsWith("6") -> it is Inet6Address; else -> true }
                }.mapNotNull { it.hostAddress }.joinToString("\n"))
            } catch (e: java.util.concurrent.ExecutionException) {
                if (e.cause is UnknownHostException) ctx.errorCode(3) else throw IOException("physical DNS failed")
            } finally { future.cancel(true) }
        }
    }

    companion object {
        private val executor = Executors.newSingleThreadExecutor { Thread(it, "WhiteLink-DNS-callback").apply { isDaemon = true } }
        private val legacyExecutor = java.util.concurrent.ThreadPoolExecutor(0, 2, 30, TimeUnit.SECONDS,
            java.util.concurrent.SynchronousQueue(), { task -> Thread(task, "WhiteLink-DNS-legacy").apply { isDaemon = true } },
            java.util.concurrent.ThreadPoolExecutor.AbortPolicy())

        /** VK/TURN's resolver binding has no ExchangeContext, so observe the
         * service generation while waiting and cancel the Android query on stop. */
        fun resolveIPv4(physical: Network, host: String, current: () -> Boolean): List<String> {
            val signal = CancellationSignal()
            val future: CompletableFuture<Collection<InetAddress>>
            if (Build.VERSION.SDK_INT >= 29) {
                future = CompletableFuture()
                DnsResolver.getInstance().query(physical, host.removeSuffix("."), DnsResolver.TYPE_A,
                    DnsResolver.FLAG_NO_RETRY, executor, signal, object : DnsResolver.Callback<Collection<InetAddress>> {
                        override fun onAnswer(answer: Collection<InetAddress>, rcode: Int) {
                            if (rcode == 0) future.complete(answer) else future.completeExceptionally(IOException("bootstrap DNS failed"))
                        }
                        override fun onError(error: DnsResolver.DnsException) { future.completeExceptionally(IOException("bootstrap DNS failed")) }
                    })
            } else {
                future = CompletableFuture.supplyAsync({ physical.getAllByName(host.removeSuffix(".")).toList() }, legacyExecutor)
            }
            val deadline = android.os.SystemClock.elapsedRealtime() + 10_000
            try {
                while (android.os.SystemClock.elapsedRealtime() < deadline) {
                    if (!current()) throw IOException("bootstrap DNS cancelled")
                    try {
                        val answer = future.get(200, TimeUnit.MILLISECONDS)
                        return answer.filterIsInstance<Inet4Address>().mapNotNull { it.hostAddress }
                    } catch (_: java.util.concurrent.TimeoutException) { }
                }
                throw IOException("bootstrap DNS timeout")
            } finally { signal.cancel(); future.cancel(true) }
        }
    }
}
