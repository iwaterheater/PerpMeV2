#!/usr/bin/env python3
"""
What the dividend-coin launch configs are worth TODAY, and what to seed instead.

    python3 contracts/script/tax-seed-prices.py

Run it on the day AddTaxConfigs goes to a production factory. A config is a
fixed opening price in the pair token, so every seed drifts with its token:
on 2026-09-15 HYPE had fallen from $83.83 to $76.5 since the seeds were
written, and a WHYPE curve opened at $2,739 instead of $3,000.

For every seed in AddTaxConfigs.s.sol it prints:

  - the token's mid price in dollars (buy and sell quotes averaged, so the
    pool's own fee cancels) through the same bridge the routers use;
  - the valuation the CURRENT seed opens at, and the seed that opens at $3,000;
  - what buying the whole curve costs in HYPE at a 3% buy tax, and how much of
    that is the bridge's price impact — or that the bridge cannot deliver it;
  - what share of the token's total supply one graduation locks in its pool
    for good (the LP is burned).

and then the `PairSeed(...)` lines to paste. Read-only: nothing is signed.
"""

from decimal import Decimal
import math
import re
import subprocess
from pathlib import Path

CAST = str(Path.home() / ".foundry/bin/cast")
RPCS = ["https://rpc.hyperliquid.xyz/evm", "https://rpc.hypurrscan.io"]

WHYPE = "0x5555555555555555555555555555555555555555"
USDC = "0xb88339CB7199b77E23DB6E890353E22632Ba630f"
QUOTER = "0x239F11a7A3E08f2B8110D4CA9F6B95d4c8865258"  # PRJX QuoterV2

OPEN_USD = 3000
VIRTUAL_TOKEN_SHARE = 1.073  # VIRTUAL_TOKEN / TOTAL_SUPPLY
FILL_MULTIPLE = 2.8335  # quote raised to sell CURVE_TOKENS, per unit of virtual quote
FEE, TAX = 0.015, 0.03

# The bridge from WHYPE to each pair token, as web/lib/routes.ts has it:
# a list of (fee, token) hops after WHYPE for PRJX V3, or a Solidly pair address.
BRIDGES = {
    "0xa8ddb5cd96b5222afe198316e9a57caa642850d5": [10000],  # wNVDAx
    "0x8e2eed8b8b5e13ea7bf38e50d7821d2c57309072": [10000],  # wSPCXx
    "0xe7e553cd128f0011777323a0b44a7b96ea1cb540": [10000],  # wSPYx
    USDC.lower(): [500],
    "0xb8ce59fc3717ada4c02eadf9682a9e934f625ebb": [500],  # USDT0
    "0x9b498c3c8a0b8cd8ba1d9851d40d186f1872b44e": [3000],  # PURR
    "0x27ec642013bcb3d80ca3706599d3cda04f6f4452": [3000],  # UPUMP
    "0x000000000000780555bd0bca3791f89f9542c2d6": [10000],  # KNTQ
    "0x068f321fa8fb9f0d135f290ef6a3e2813e1c8a29": [3000],  # USOL
    "0x9fdbda0a5e284c32744d2f17ee5c74b284993463": [3000],  # UBTC
    "0xbe6727b535545c67d5caa73dea54865b92cf7907": [3000],  # UETH
    "0xfd739d4e423301ce9385c1fb8850539d657c296d": [100],  # kHYPE
    "0x62d5dd0190376c444a4b2e2e860aa392ec83ed80": [500, USDC, 10000],  # JOFF, via USDC
    "0x555570a286f15ebdfe42b66ede2f724aa1ab5555": "0xa33601b7811dC089CAfEB7C7B97fC4c8271899b2",  # RAM on Ramses
    "0x07c57e32a3c29d5659bda1d3efc2e7bf004e3035": "0x9AA281B23341cE69d4b1500367a43CFc42005538",  # NEST on Nest
}


def call(to, sig, *args):
    for i in range(8):
        r = subprocess.run(
            [CAST, "call", to, sig, *map(str, args), "--rpc-url", RPCS[i % len(RPCS)]],
            capture_output=True,
            text=True,
        )
        if r.returncode == 0:
            return int(r.stdout.strip().split("\n")[0].split(" ")[0])
        if "revert" in r.stderr.lower():
            return None
    raise RuntimeError(f"{to} {sig}: {r.stderr.strip()[:200]}")


def v3_path(tokens_and_fees):
    return "0x" + "".join(x[2:].lower() if isinstance(x, str) else format(x, "06x") for x in tokens_and_fees)


def hops(token, bridge):
    """WHYPE → token as a flat [WHYPE, fee, …, token] list, and its reverse."""
    fwd = [WHYPE]
    for x in bridge:
        fwd.append(x)
    fwd.append(token)
    return fwd, list(reversed(fwd))


def quote_in(token, bridge, amount_in, forward=True):
    """Output of `amount_in` along the bridge, WHYPE→token (forward) or back."""
    if isinstance(bridge, str):
        return call(bridge, "getAmountOut(uint256,address)(uint256)", amount_in, WHYPE if forward else token)
    fwd, rev = hops(token, bridge)
    return call(QUOTER, "quoteExactInput(bytes,uint256)(uint256,uint160[],uint32[],uint256)",
                v3_path(fwd if forward else rev), amount_in)


def hype_to_buy(token, bridge, amount_out):
    """HYPE (wei) that buys `amount_out` of the token, or None if it cannot."""
    if isinstance(bridge, str):
        # Bisection over the pair's own quote, as PerpMeBridge does.
        lo, hi = 0, 20_000 * 10**18
        if (call(bridge, "getAmountOut(uint256,address)(uint256)", hi, WHYPE) or 0) < amount_out:
            return None
        while hi - lo > 10**15:
            mid = (lo + hi) // 2
            if call(bridge, "getAmountOut(uint256,address)(uint256)", mid, WHYPE) >= amount_out:
                hi = mid
            else:
                lo = mid
        return hi
    _, rev = hops(token, bridge)
    return call(QUOTER, "quoteExactOutput(bytes,uint256)(uint256,uint160[],uint32[],uint256)", v3_path(rev), amount_out)


def seeds():
    src = (Path(__file__).parent / "AddTaxConfigs.s.sol").read_text()
    for addr, literal, sym in re.findall(r'PairSeed\((0x[0-9a-fA-F]{40}),\s*([0-9_.e]+),\s*"([^"]+)"\)', src):
        yield addr, literal.replace("_", ""), sym


def main():
    probe = 10**17  # 0.1 HYPE
    hype_usd = call(QUOTER, "quoteExactInputSingle((address,address,uint256,uint24,uint160))(uint256,uint160,uint32,uint256)",
                    f"({WHYPE},{USDC},{probe},500,0)") / 1e6 * 10
    print(f"HYPE ${hype_usd:.2f}\n")
    print(f"{'pair':8}{'price $':>14}{'opens at':>10}{'full fill':>22}{'impact':>8}{'of supply':>11}")
    lines = []
    for addr, literal, sym in seeds():
        dec = call(addr, "decimals()(uint8)")
        supply = call(addr, "totalSupply()(uint256)") / 10**dec
        seed_units = float(literal) / 10**dec
        if addr.lower() == WHYPE:
            price = hype_usd
            fill = seed_units * FILL_MULTIPLE / (1 - FEE - TAX)
            cost = fill
        else:
            bridge = BRIDGES[addr.lower()]
            out = quote_in(addr, bridge, probe)
            back = quote_in(addr, bridge, out, forward=False)
            price = hype_usd * (probe / 1e18) / (out / 10**dec) * math.sqrt(back / probe)
            fill = seed_units * FILL_MULTIPLE / (1 - FEE - TAX)
            wei = hype_to_buy(addr, bridge, int(fill * 10**dec))
            cost = wei / 1e18 if wei else None
        opens = seed_units * price / VIRTUAL_TOKEN_SHARE
        fair = fill * price / hype_usd
        fill_txt = f"{cost:,.1f} HYPE" if cost else "bridge too thin"
        impact = f"{(cost / fair - 1) * 100:.1f}%" if cost else "—"
        print(f"{sym:8}{price:>14,.6g}{opens:>10,.0f}{fill_txt:>22}{impact:>8}{fill / supply * 100:>10.3f}%")
        # Six significant figures: a literal someone can read, and far finer
        # than the day's price moves.
        new_units = Decimal(f"{OPEN_USD * VIRTUAL_TOKEN_SHARE / price:.6g}")
        lines.append(f'PairSeed({addr}, {int(new_units * 10**dec)}, "{sym}");  // ${price:.6g}')
    print("\nSeeds that open at $%d today (wei, in each token's own decimals):" % OPEN_USD)
    print("\n".join(lines))


if __name__ == "__main__":
    main()
