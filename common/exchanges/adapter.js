// Exchange adapter interface (documentation)
//
// Adapters encapsulate order placement and (eventually) account/trade queries.
// They should be pure modules that read configuration from env or passed options,
// and never mutate global state. All network I/O should be retriable and respect
// rate limits and idempotency keys.
//
// Required method (initial):
// - async placeOrder({ orderId, symbol, side, qty }):
//     Returns an object:
//       {
//         filled: boolean,
//         orderId: string,
//         symbol: string,
//         side: 'buy'|'sell',
//         qty: number,
//         price?: number,    // execution price (if known)
//         notional?: number, // abs(qty)*price
//         fee?: number,      // fees paid for the trade
//         raw?: any          // optional raw response or diagnostic info
//       }
//
// Optional future methods:
// - async getOrder({ orderId })
// - async cancelOrder({ orderId })
// - async fetchBalance()
// - async fetchTrades({ since })
//
// See implementations in this folder for paper, binance, and coinbase stubs.
export {};
