#!/usr/bin/env python3
"""Keep a gateway WebSocket connection alive for local AMP runs."""

import asyncio
import logging
import os
import signal
import ssl
import sys

try:
    import websockets
except ImportError:
    print(
        "Missing dependency: websockets. Install with: pip3 install websockets",
        file=sys.stderr,
    )
    sys.exit(1)


AMP_WS_URL = os.environ.get("AMP_WS_URL", "")
AMP_GATEWAY_API_KEY = os.environ.get("AMP_GATEWAY_API_KEY", "")
RECONNECT_SECONDS = int(os.environ.get("AMP_WS_RECONNECT_SECONDS", "5"))


def build_ssl_context() -> ssl.SSLContext:
    # Local AMP uses a self-signed cert on the internal HTTPS endpoint.
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


async def run_connector(stop_event: asyncio.Event) -> None:
    ssl_ctx = build_ssl_context()
    log = logging.getLogger("gateway-connector")

    while not stop_event.is_set():
        try:
            log.info("Connecting to AMP: %s", AMP_WS_URL)
            async with websockets.connect(
                AMP_WS_URL,
                additional_headers={"api-key": AMP_GATEWAY_API_KEY},
                ssl=ssl_ctx,
                ping_interval=20,
                ping_timeout=10,
            ) as ws:
                log.info("Gateway ACTIVE: WebSocket connected")
                while not stop_event.is_set():
                    try:
                        msg = await asyncio.wait_for(ws.recv(), timeout=30)
                        if msg:
                            log.debug("Server message: %s", msg)
                    except TimeoutError:
                        continue
                    except websockets.ConnectionClosed:
                        log.warning("WebSocket closed by server; reconnecting")
                        break
        except Exception as exc:
            log.error("Connector error: %s", exc)

        if stop_event.is_set():
            break

        await asyncio.sleep(RECONNECT_SECONDS)


async def main() -> int:
    if not AMP_WS_URL:
        print("AMP_WS_URL is required", file=sys.stderr)
        return 1
    if not AMP_GATEWAY_API_KEY:
        print("AMP_GATEWAY_API_KEY is required", file=sys.stderr)
        return 1

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )

    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()

    def _stop() -> None:
        stop_event.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, _stop)

    await run_connector(stop_event)
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
