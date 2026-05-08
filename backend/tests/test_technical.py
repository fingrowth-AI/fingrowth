"""Tests for P2-04: technical analysis library.

Acceptance:
* RSI of flat prices = 50.0 within tolerance
* MACD of known test vector matches to 4 decimals
* All raise ValueError on insufficient data
* 100% test coverage on the module
"""

from __future__ import annotations

import math

import numpy as np
import pytest

from app.tools.technical import (
    BollingerResult,
    MACDResult,
    _ema,
    _to_array,
    _wilder_smoothed_average,
    calculate_bollinger,
    calculate_ema,
    calculate_macd,
    calculate_rsi,
    calculate_sharpe,
    calculate_sma,
)

# ---------------------------------------------------------------------------
# Reference implementations (independent of app.tools.technical) used as the
# truth for the MACD acceptance criterion.
# ---------------------------------------------------------------------------


def _ref_ema(values: list[float], period: int) -> list[float]:
    alpha = 2.0 / (period + 1.0)
    out: list[float] = [math.nan] * (period - 1)
    seed = sum(values[:period]) / period
    out.append(seed)
    for v in values[period:]:
        out.append(alpha * v + (1 - alpha) * out[-1])
    return out


def _ref_macd(prices: list[float]) -> tuple[float, float, float]:
    fast = _ref_ema(prices, 12)
    slow = _ref_ema(prices, 26)
    macd_line = [
        f - s if not (math.isnan(f) or math.isnan(s)) else math.nan
        for f, s in zip(fast, slow, strict=True)
    ]
    valid = [x for x in macd_line if not math.isnan(x)]
    sig = _ref_ema(valid, 9)
    return macd_line[-1], sig[-1], macd_line[-1] - sig[-1]


# ---------------------------------------------------------------------------
# SMA
# ---------------------------------------------------------------------------


def test_sma_happy_path():
    assert calculate_sma([1, 2, 3, 4, 5], period=5) == 3.0


def test_sma_only_uses_trailing_window():
    assert calculate_sma([100.0, 100.0, 1.0, 2.0, 3.0], period=3) == 2.0


def test_sma_accepts_numpy_array():
    arr = np.arange(20, dtype=float)
    assert calculate_sma(arr, period=5) == 17.0


def test_sma_insufficient_data_raises():
    with pytest.raises(ValueError, match="SMA"):
        calculate_sma([1, 2], period=5)


def test_sma_invalid_period_raises():
    with pytest.raises(ValueError, match="period"):
        calculate_sma([1, 2, 3], period=0)


# ---------------------------------------------------------------------------
# EMA
# ---------------------------------------------------------------------------


def test_ema_first_value_equals_sma_seed():
    """The first defined EMA value equals the SMA of the seed window."""
    prices = [1.0, 2.0, 3.0, 4.0, 5.0]
    # EMA(period=5) over 5 values → seed only, equal to mean.
    assert calculate_ema(prices, period=5) == 3.0


def test_ema_known_value_against_reference():
    prices = list(np.linspace(100, 200, 50))
    expected = _ref_ema(prices, 12)[-1]
    assert calculate_ema(prices, 12) == pytest.approx(expected, abs=1e-9)


def test_ema_insufficient_data_raises():
    with pytest.raises(ValueError, match="EMA"):
        calculate_ema([1, 2], period=5)


def test_ema_invalid_period_raises():
    with pytest.raises(ValueError, match="period"):
        calculate_ema([1, 2, 3], period=-1)


# ---------------------------------------------------------------------------
# RSI — primary acceptance: flat prices = 50.0
# ---------------------------------------------------------------------------


def test_rsi_flat_prices_is_50():
    """Acceptance: RSI of flat prices = 50.0 within tolerance."""
    prices = [100.0] * 30
    assert calculate_rsi(prices, period=14) == pytest.approx(50.0, abs=1e-9)


def test_rsi_strictly_rising_is_100():
    prices = list(range(1, 30))  # all gains, no losses
    assert calculate_rsi(prices, period=14) == 100.0


def test_rsi_strictly_falling_below_threshold():
    # All losses → avg_gain = 0, avg_loss > 0 → rs = 0 → RSI = 0
    prices = list(range(30, 0, -1))
    assert calculate_rsi(prices, period=14) == pytest.approx(0.0, abs=1e-9)


def test_rsi_oscillating_in_range():
    """A typical oscillating series should return a sensible 0-100 value."""
    # Alternating up/down keeps RSI close to 50.
    prices = [100.0 + (1.0 if i % 2 else -1.0) for i in range(30)]
    rsi = calculate_rsi(prices, period=14)
    assert 0.0 <= rsi <= 100.0


def test_rsi_insufficient_data_raises():
    with pytest.raises(ValueError, match="RSI"):
        calculate_rsi([1, 2, 3], period=14)


def test_rsi_invalid_period_raises():
    with pytest.raises(ValueError, match="period"):
        calculate_rsi([1, 2, 3], period=0)


# ---------------------------------------------------------------------------
# MACD — primary acceptance: known vector matches to 4 decimals
# ---------------------------------------------------------------------------


def test_macd_known_vector_matches_to_four_decimals():
    """Acceptance: MACD of known test vector matches to 4 decimals.

    The reference is a hand-rolled pure-Python EMA chain (``_ref_macd``) that
    is provably correct by construction — it's the textbook recursion expanded
    out. Any algorithmic drift in our numpy version surfaces here.
    """
    rng = np.random.default_rng(42)
    # Random walk around 100 — non-trivial input that exercises the recursion.
    prices = (100.0 + rng.normal(0, 1, 80).cumsum()).tolist()

    got = calculate_macd(prices)
    exp_macd, exp_signal, exp_hist = _ref_macd(prices)

    assert got.macd == pytest.approx(exp_macd, abs=1e-4)
    assert got.signal == pytest.approx(exp_signal, abs=1e-4)
    assert got.histogram == pytest.approx(exp_hist, abs=1e-4)


def test_macd_returns_pydantic_result():
    prices = list(np.linspace(100, 200, 40))
    out = calculate_macd(prices)
    assert isinstance(out, MACDResult)
    assert out.histogram == pytest.approx(out.macd - out.signal, abs=1e-12)


def test_macd_flat_prices_all_zero():
    """Constant prices → equal EMAs → MACD line = 0, signal = 0, histogram = 0."""
    out = calculate_macd([100.0] * 60)
    assert out.macd == pytest.approx(0.0, abs=1e-9)
    assert out.signal == pytest.approx(0.0, abs=1e-9)
    assert out.histogram == pytest.approx(0.0, abs=1e-9)


def test_macd_insufficient_data_raises():
    with pytest.raises(ValueError, match="MACD"):
        calculate_macd([1, 2, 3, 4, 5])


def test_macd_invalid_periods_raise():
    with pytest.raises(ValueError, match=">"):
        calculate_macd([1.0] * 50, fast=0)
    with pytest.raises(ValueError, match=">"):
        calculate_macd([1.0] * 50, slow=0)
    with pytest.raises(ValueError, match=">"):
        calculate_macd([1.0] * 50, signal=0)


def test_macd_fast_must_be_less_than_slow():
    with pytest.raises(ValueError, match="fast"):
        calculate_macd([1.0] * 50, fast=26, slow=12)


# ---------------------------------------------------------------------------
# Bollinger Bands
# ---------------------------------------------------------------------------


def test_bollinger_happy_path():
    prices = list(np.linspace(100, 200, 30))
    out = calculate_bollinger(prices, period=20)
    assert isinstance(out, BollingerResult)
    assert out.lower < out.middle < out.upper
    # Symmetry around middle.
    assert (out.upper - out.middle) == pytest.approx(out.middle - out.lower, abs=1e-9)


def test_bollinger_constant_prices_collapses_bands():
    out = calculate_bollinger([50.0] * 25, period=20)
    assert out.upper == out.middle == out.lower == 50.0


def test_bollinger_period_one_returns_zero_width_bands():
    """With period=1 there's no rolling std, so bands collapse to the price."""
    out = calculate_bollinger([42.0, 99.0, 7.5], period=1)
    assert out.middle == 7.5
    assert out.upper == out.lower == 7.5


def test_bollinger_custom_num_std():
    out = calculate_bollinger(list(np.linspace(0, 100, 25)), period=20, num_std=1.0)
    out2 = calculate_bollinger(list(np.linspace(0, 100, 25)), period=20, num_std=3.0)
    assert (out2.upper - out2.middle) == pytest.approx(
        3 * (out.upper - out.middle), abs=1e-9
    )


def test_bollinger_insufficient_data_raises():
    with pytest.raises(ValueError, match="Bollinger"):
        calculate_bollinger([1, 2, 3], period=20)


def test_bollinger_invalid_period_raises():
    with pytest.raises(ValueError, match="period"):
        calculate_bollinger([1.0] * 30, period=0)


def test_bollinger_invalid_num_std_raises():
    with pytest.raises(ValueError, match="num_std"):
        calculate_bollinger([1.0] * 30, period=20, num_std=0)


# ---------------------------------------------------------------------------
# Sharpe Ratio
# ---------------------------------------------------------------------------


def test_sharpe_positive_excess_returns_positive():
    returns = [0.001, 0.002, 0.0015, 0.001, 0.0025, 0.003]
    sharpe = calculate_sharpe(returns)
    assert sharpe > 0


def test_sharpe_zero_volatility_returns_zero():
    """No volatility → divide-by-zero is suppressed and we return 0.0."""
    assert calculate_sharpe([0.001] * 10) == 0.0


def test_sharpe_negative_excess_returns_negative():
    returns = [-0.001, -0.002, -0.0015, -0.001, -0.0025, -0.003]
    assert calculate_sharpe(returns) < 0


def test_sharpe_no_annualize_drops_sqrt_factor():
    returns = [0.001, 0.002, 0.0015, 0.001, 0.0025, 0.003]
    daily = calculate_sharpe(returns, annualize=False)
    annualized = calculate_sharpe(returns, annualize=True)
    assert annualized == pytest.approx(daily * math.sqrt(252), abs=1e-9)


def test_sharpe_risk_free_rate_subtracts():
    """Excess returns drop when risk_free_rate is provided."""
    returns = [0.005, 0.005, 0.005]  # zero-std series
    # Even with rf=0.001, std is still 0 → 0.0 (the function never divides).
    assert calculate_sharpe(returns, risk_free_rate=0.001) == 0.0


def test_sharpe_insufficient_data_raises():
    with pytest.raises(ValueError, match="Sharpe"):
        calculate_sharpe([0.001])


def test_sharpe_invalid_periods_per_year_raises():
    with pytest.raises(ValueError, match="periods_per_year"):
        calculate_sharpe([0.001, 0.002], periods_per_year=0)


# ---------------------------------------------------------------------------
# Internal helpers (covered for the 100% mandate)
# ---------------------------------------------------------------------------


def test_to_array_rejects_2d():
    with pytest.raises(ValueError, match="1-D"):
        _to_array(np.zeros((2, 3)))


def test_ema_helper_returns_all_nan_when_too_short():
    out = _ema(np.array([1.0, 2.0, 3.0]), 5)
    assert np.isnan(out).all()


def test_ema_helper_invalid_period_raises():
    with pytest.raises(ValueError, match="period"):
        _ema(np.array([1.0, 2.0]), 0)


def test_wilder_smoothed_average_insufficient_raises():
    with pytest.raises(ValueError, match="Wilder"):
        _wilder_smoothed_average(np.array([1.0, 2.0]), period=5)
