# Exchange Adapters (Design & Wiring)

This document describes the adapter interface and how to configure the Trade Executor to use a specific exchange. The goal is to swap between paper and real exchanges via environment variables, with idempotent order handling and reconciliation.

Adapter interface (common/exchanges/adapter.js)

- placeOrder({ orderId, symbol, side, qty }) → { filled, orderId, symbol, side, qty, price?, notional?, fee?, raw? }
- Future: getOrder, cancelOrder, fetchBalance, fetchTrades

Adapters

- Paper (common/exchanges/paper.js)
  - Fills immediately at PAPER_PRICE_DEFAULT.
  - Fee calculation: EXCHANGE_FEE_BPS (bps), optional SLIPPAGE_BPS.
  - Exec status includes price/fee; profit defaults to PROFIT_PER_TRADE - fee in scaffold.
- Binance (common/exchanges/binance.js) — stub
  - Reads BINANCE_API_KEY/SECRET or \*\_FILE.
  - placeOrder currently returns a stub result; implement signed REST calls when going live.
- Coinbase (common/exchanges/coinbase.js) — stub
  - Reads COINBASE_API_KEY/SECRET/PASSPHRASE or \*\_FILE.
  - placeOrder currently returns a stub result.

Trade Executor selection

- EXCHANGE=paper|binance|coinbase
- PROFIT_PER_TRADE (scaffold profit baseline)
- PAPER_PRICE_DEFAULT, EXCHANGE_FEE_BPS, SLIPPAGE_BPS (paper)

Order idempotency & state

- Redis hash key: exec:orders:<orderId>
- Fields: orderId, symbol, side, qty, received_ts, last_status (JSON), price, fee
- On receiving a duplicate or a message after terminal status, ignore and log order_duplicate_skip.

Reconciliation (future)

- Background job fetches trades from exchange and compares to exec:orders; mismatches generate notify.events and/or Jira tickets.

Security and secrets

- Use Docker secrets for API keys; prefer \*\_FILE env pointing to mounted files.
- Restrict the executor’s network to only required exchange endpoints; TLS required.

Testing

- Unit test fee/slippage math (paper). Integration tests with mock HTTP for real adapters.
