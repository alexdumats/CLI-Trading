// Paper exchange adapter: simulates fills and basic fees/slippage
// Config via env:
// - PAPER_PRICE_DEFAULT: default notional price for fee calc (e.g., 30000 for BTC-USD)
// - EXCHANGE_FEE_BPS: fee rate in basis points (e.g., 10 = 0.10%)
// - SLIPPAGE_BPS: additional slippage in basis points applied to notional for fee calc (optional)

export function getPaperAdapter() {
  const priceDefault = parseFloat(process.env.PAPER_PRICE_DEFAULT || '30000');
  const feeBps = parseFloat(process.env.EXCHANGE_FEE_BPS || '10'); // 0.10%
  const slippageBps = parseFloat(process.env.SLIPPAGE_BPS || '0');

  const computeFee = ({ qty = 1, price = priceDefault }) => {
    const notional = Math.abs(qty) * price * (1 + slippageBps / 10000);
    const fee = notional * (feeBps / 10000);
    return { fee, notional };
  };

  return {
    async placeOrder({ orderId, symbol, side, qty }) {
      const { fee, notional } = computeFee({ qty });
      // In paper mode we "fill" immediately at the default price
      return {
        filled: true,
        orderId,
        symbol,
        side,
        qty,
        price: priceDefault,
        notional,
        fee,
      };
    },
  };
}
